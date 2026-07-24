// ----------------------------------------------------------------------------
// Wishbone Monitor transactor interface (SV, signal-level RV ports)
//
// Thin, FIFO-less bridge from the blocking task API (HVL side) to the core's
// ready/valid observed-transaction channel -- the passive mirror of
// wb_target_xtor_if's wait_req():
//   - wait_txn() : SINK -- drive mon_ready, await an observed beat, capture it
//
// FIFO-less by design (like the initiator/target kits): the core holds ONE
// observed beat as a pipeline register and asserts mon_valid; wait_txn() keeps
// mon_ready asserted so it consumes one beat PER CYCLE, matching a 0-wait-state
// master that terminates one beat per cycle. A passive monitor cannot back-
// pressure the bus, so keeping up (not buffering) is the correct contract: the
// HVL consumer must re-arm within the same time step (its analysis write is
// zero-time), which the UVM monitor loop does. An egress FIFO here only masks a
// slow drain -- and a slow drain silently drops beats a monitor must not miss.
// ----------------------------------------------------------------------------

interface wb_monitor_xtor_if #(
        parameter int ADDR_WIDTH = 32,
        parameter int DATA_WIDTH = 32,
        parameter int MON_WIDTH  = (ADDR_WIDTH + DATA_WIDTH + (DATA_WIDTH/8) + 1 + 1)
    ) (
        input  wire                     clock,
        input  wire                     reset,

        // RV observed-transaction channel: core sources, interface accepts.
        input  wire [MON_WIDTH-1:0]     mon_dat,
        input  wire                     mon_valid,
        output reg                      mon_ready
    );

    typedef struct packed {
        bit [ADDR_WIDTH-1:0]      adr;
        bit [DATA_WIDTH-1:0]      dat;   // write data on WE=1, read data on WE=0
        bit                       we;
        bit [(DATA_WIDTH/8)-1:0]  sel;
        bit                       err;
    } mon_s;

    initial mon_ready = 1'b0;

    // Wait for the next observed Wishbone transaction (SINK of the mon channel).
    // Holds mon_ready asserted across the wait, so consecutive (back-to-back)
    // beats are each accepted on their own cycle -- no FIFO, no dropped beats.
    //
    // POST-test loop (do/while): a passive monitor is UNPACED -- mon_valid can
    // already be high on entry (the bus ran ahead), so a pre-test `while` would
    // return in zero time without advancing the clock and spin. The do/while
    // guarantees exactly one clock edge per accepted beat (a transfer happens on
    // the cycle mon_valid && mon_ready), so back-to-back beats consume 1/cycle.
    task automatic wait_txn(
            output [ADDR_WIDTH-1:0]     adr,
            output [DATA_WIDTH-1:0]     dat,
            output [(DATA_WIDTH/8)-1:0] sel,
            output                      we,
            output                      err);
        mon_s r;
        mon_ready <= 1'b1;
        do begin
            @(posedge clock);
        end while (!(mon_valid && mon_ready));
        r   = mon_dat;
        adr = r.adr;
        dat = r.dat;
        sel = r.sel;
        we  = r.we;
        err = r.err;
        mon_ready <= 1'b0;
    endtask

    // Kept for API compatibility with the UVM/example consumers.
    task wait_reset();
        if (reset) @(negedge reset);
        @(posedge clock);
    endtask

endinterface
