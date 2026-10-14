// ======================================================================
// REQUIRED back-to-back SIMULATION test for the Wishbone kit (design §8a).
//
// Wires a full INITIATOR transactor directly to a full TARGET transactor over one
// shared Wishbone bus, with a MONITOR passively tapping it -- exercising the
// COMPLETE stack (class API -> bridge -> xtor_if FIFOs -> core -> pins and back).
// Classic ACK/ERR WB (D2). Individual-argument, width-parameterized class layer:
//   - the driver holds a wb_proto_if handle (the initiator bridge);
//   - the slave model implements wb_proto_if; the observer implements wb_monitor_if;
//   - the target/monitor bridges hold those handles and run() loops forked by start().
//
// Run:  dfm run wb-proto      (expect: [wb_proto] PASS; any failure exits nonzero)
// ======================================================================
`include "fw_proto_wb_macros.svh"

module wb_proto_tb;
    import fw_proto_wb_pkg::*;

    localparam logic [31:0] ERR_ADR = 32'hE000_0000;  // slave always returns ERR

    // --------------------------------------------------------------
    // Driver: holds the initiator API handle; runs the stimulus and checks
    // round-trip integrity inline. Counts errors + completed transfers.
    // --------------------------------------------------------------
    class driver;
        wb_proto_if #(32, 32) wb;
        int unsigned errors;
        int unsigned n_xfers;          // completed transfers (for the monitor check)

        function new(wb_proto_if #(32, 32) wb);
            this.wb = wb;
        endfunction

        task automatic wr(input logic [31:0] adr, input logic [31:0] dat);
            automatic logic [31:0] dat_r;
            automatic logic        err;
            wb.access(adr, dat, 4'hf, 1'b1, dat_r, err);
            n_xfers++;
            if (err) begin
                $display("FAIL: write @0x%08h unexpectedly err", adr); errors++;
            end
        endtask

        task automatic rd(input logic [31:0] adr, output logic [31:0] dat, output bit err);
            wb.access(adr, 32'h0, 4'hf, 1'b0, dat, err);
            n_xfers++;
        endtask

        task automatic rd_chk(input logic [31:0] adr, input logic [31:0] exp);
            automatic logic [31:0] got; automatic bit e;
            rd(adr, got, e);
            if (e) begin
                $display("FAIL: read @0x%08h err", adr); errors++;
            end else if (got !== exp) begin
                $display("FAIL: read @0x%08h got 0x%08h exp 0x%08h", adr, got, exp); errors++;
            end else
                $display("[driver] read  @0x%08h = 0x%08h OK", adr, got);
        endtask

        task run();
            errors = 0; n_xfers = 0;
            // single writes then read-back (with master throttle = backpressure)
            for (int i = 0; i < 6; i++) begin
                wr(32'h0000_0100 + 4*i, 32'hA000_0000 + i);
                #13ns;
            end
            for (int i = 0; i < 6; i++)
                rd_chk(32'h0000_0100 + 4*i, 32'hA000_0000 + i);
            // ERR termination propagates
            begin
                automatic logic [31:0] got; automatic bit e;
                rd(ERR_ADR, got, e);
                if (!e) begin $display("FAIL: expected ERR @0x%08h", ERR_ADR); errors++; end
                else $display("[driver] ERR  @0x%08h OK", ERR_ADR);
            end
        endtask
    endclass

    // --------------------------------------------------------------
    // Slave memory model: implements wb_proto_if directly. Associative-array
    // memory with a fixed latency (slave wait-states) and an ERR hook.
    // --------------------------------------------------------------
    class mem_slave implements wb_proto_if #(32, 32);
        logic [31:0] mem [logic [31:0]];

        virtual task access(
                input  [31:0] adr,
                input  [31:0] dat_w,
                input  [3:0]  sel,
                input         we,
                output [31:0] dat_r,
                output        err);
            dat_r = 32'h0;
            err   = 1'b0;
            #11ns;                              // slave latency (wait states)
            if (adr == ERR_ADR)      err   = 1'b1;
            else if (we)             mem[adr] = dat_w;
            else                     dat_r = mem.exists(adr) ? mem[adr] : 32'h0;
        endtask
    endclass

    // --------------------------------------------------------------
    // Observer: implements wb_monitor_if directly. Counts every observed phase.
    // --------------------------------------------------------------
    class observer implements wb_monitor_if #(32, 32);
        int unsigned n_seen;

        virtual function void observe(
                input [31:0] adr,
                input [31:0] dat,
                input [3:0]  sel,
                input        we,
                input        err);
            n_seen++;
        endfunction
    endclass

    // --------------------------------------------------------------
    // Signal-level setup: the three transactor modules on one shared WB bus.
    // Wishbone has TWO unidirectional data buses: wb_dat_w (master->slave write)
    // and wb_dat_r (slave->master read). The whole bus is declared/connected
    // from `WB_WIRES / `WB_CONNECT (fw_proto_wb_macros.svh) -- empty port-prefix
    // because the kit modules expose bare WB pin names.
    // --------------------------------------------------------------
    logic clock = 1'b0;
    logic reset = 1'b1;

    `WB_WIRES(wb_, 32, 32)

    always #5ns clock = ~clock;

    wb_initiator_xtor init_xtor (
        .clock(clock), .reset(reset),
        `WB_CONNECT(, wb_)
    );
    wb_target_xtor targ_xtor (
        .clock(clock), .reset(reset),
        `WB_CONNECT(, wb_)
    );
    wb_monitor_xtor mon_xtor (
        .clock(clock), .reset(reset),
        `WB_CONNECT(, wb_)
    );

    // The kit's reusable protocol-invariant checker (the same module the formal
    // proof uses). Its synthesizable immediate asserts run here; its concurrent
    // SVA layer also runs when compiled with -DWB_PROTO_SVA.
    wb_proto_checker #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) u_chk (
        .clock(clock), .reset(reset),
        `WB_CONNECT(, wb_)
    );

    initial begin
        automatic driver                            drv;
        automatic mem_slave                         slv;
        automatic observer                          obs;
        automatic wb_initiator_xtor_bridge #(32,32) ibr;
        automatic wb_target_xtor_bridge    #(32,32) tbr;
        automatic wb_monitor_xtor_bridge   #(32,32) mbr;
        automatic int errors = 0;

        reset = 1'b1;
        repeat (4) @(posedge clock);
        reset = 1'b0;
        @(posedge clock);

        // Build the bridges + models and wire them by handle.
        ibr = new(init_xtor.u_if);
        slv = new();
        obs = new();
        tbr = new(targ_xtor.u_if, slv);   // target bridge holds the slave model
        mbr = new(mon_xtor.u_if,  obs);   // monitor bridge holds the observer
        drv = new(ibr);                   // driver holds the initiator bridge (wb_proto_if)

        // Launch the background service loops, then run the driver.
        ibr.start();
        tbr.start();
        mbr.start();
        drv.run();

        // Drain: let the last observed phase propagate to the monitor FIFO.
        repeat (20) @(posedge clock);

        errors = drv.errors;
        if (obs.n_seen != drv.n_xfers) begin
            $display("FAIL: monitor saw %0d phases, expected %0d", obs.n_seen, drv.n_xfers);
            errors++;
        end else
            $display("[monitor] observed %0d phases OK", obs.n_seen);

        // $fatal, not $display + $finish: the exit status is the verdict
        // (`dfm run wb-proto` and CI read nothing else), and $finish exits 0.
        if (errors != 0) $fatal(1, "[wb_proto] FAIL (%0d errors)", errors);
        $display("[wb_proto] PASS");
        $finish;
    end

    // Watchdog so a broken handshake fails fast instead of hanging.
    initial begin
        #200us;
        $fatal(1, "[wb_proto] TIMEOUT");
    end
endmodule
