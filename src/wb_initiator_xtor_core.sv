`include "wb_xtor_macros.svh"

// ----------------------------------------------------------------------------
// Wishbone Initiator core transactor (pure module, signal-level ports)
//
// Bridges a ready/valid request/response stream (interface side) to the classic
// Wishbone initiator protocol (protocol side). Single outstanding request.
//   - req_* : RV target port    (interface -> core) { adr, dat, we, sel(byte-en) }
//   - rsp_* : RV initiator port  (core -> interface) { dat, err }
//
// Migrated from fwvip-wb (authoritative transactor API). Classic single-
// outstanding WB: terminates on ACK or ERR (no RTY, no CYC-hold).
// ----------------------------------------------------------------------------
module wb_initiator_xtor_core #(
        parameter int ADDR_WIDTH = 32,
        parameter int DATA_WIDTH = 32,
        parameter int REQ_WIDTH  = (ADDR_WIDTH + DATA_WIDTH + (DATA_WIDTH/8) + 1),
        parameter int RSP_WIDTH  = (DATA_WIDTH + 1)
    ) (
        input  wire                     clock,
        input  wire                     reset,

        // Wishbone initiator (protocol) signals
        output wire [ADDR_WIDTH-1:0]    adr,
        output wire [DATA_WIDTH-1:0]    dat_w,
        input  wire [DATA_WIDTH-1:0]    dat_r,
        output wire                     cyc,
        input  wire                     err,
        output wire [DATA_WIDTH/8-1:0]  sel,
        output wire                     stb,
        input  wire                     ack,
        output wire                     we,

        // RV request channel (FIFO drives, core accepts)
        input  wire [REQ_WIDTH-1:0]     req_dat,
        input  wire                     req_valid,
        output wire                     req_ready,

        // RV response channel (core drives, FIFO accepts)
        output wire [RSP_WIDTH-1:0]     rsp_dat,
        output wire                     rsp_valid,
        input  wire                     rsp_ready
    );

    typedef `WB_INITIATOR_REQ_S(ADDR_WIDTH, DATA_WIDTH) req_s;
    typedef `WB_INITIATOR_RSP_S(ADDR_WIDTH, DATA_WIDTH) rsp_s;

    // Unpack request vector into struct
    req_s req_u;
    always_comb begin
        req_u = req_s'(req_dat);
    end

    // Registered Wishbone request outputs -- latched when a request is accepted
    // (state 0 -> 1). Holding them in flops (rather than combinationally tracking
    // req_dat) keeps adr/dat_w/sel/we glitch-free and stable for the entire bus
    // phase, independent of when the HVL next updates req_dat. Matches the
    // canonical lean BFM pattern.
    reg [ADDR_WIDTH-1:0]    adr_r;
    reg [DATA_WIDTH-1:0]    dat_w_r;
    reg [DATA_WIDTH/8-1:0]  sel_r;
    reg                     we_r;
    assign adr   = adr_r;
    assign dat_w = dat_w_r;
    assign sel   = sel_r;
    assign we    = we_r;

    // Pack response { dat, err }
    rsp_s rsp_u;
    always_comb begin
        rsp_u.dat = dat_r;
        rsp_u.err = err;
    end
    assign rsp_dat = rsp_u;

    wire term = ack || err;

    bit state;

    // STB/CYC are asserted only in the BUS phase (state 1). Deliberately NOT
    // extended into state 0 on req_valid: the FSM always passes through a state-0
    // (STB-low) cycle between phases, which (a) frames each Wishbone phase for the
    // protocol checker and (b) gives the target the !active_cycle it needs to re-arm
    // (avoids re-capturing the same phase). Matches the canonical lean BFM pattern.
    assign stb   = (state == 1);
    assign cyc   = (state == 1);

    // req_ready must be LOW during reset: state is held at 0 by reset, so without
    // the !reset gate the HVL request() would see req_ready=1 and believe a request
    // issued during reset was accepted -- but the reset branch never latches it, so
    // the bus phase never launches and response() hangs. Gating by !reset makes a
    // request issued during reset simply wait out reset (the documented behavior).
    assign req_ready = (state == 0) && !reset;
    assign rsp_valid = (term && state == 1);

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state        <= 1'b0;
            adr_r        <= '0;
            dat_w_r      <= '0;
            sel_r        <= '0;
            we_r         <= 1'b0;
        end else begin
            if (state == 0) begin
                if (req_valid) begin
                    // Accept the request: latch its fields, launch the bus phase
                    adr_r   <= req_u.adr;
                    dat_w_r <= req_u.dat;
                    sel_r   <= req_u.sel;
                    we_r    <= req_u.we;
                    state   <= 1'b1;
                end
            end else begin
                if (term) begin
                    state <= 1'b0;
                end
            end
        end
    end

endmodule
