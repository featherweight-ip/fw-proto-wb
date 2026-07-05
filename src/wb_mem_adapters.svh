// Wishbone <-> fw_mem_if adapters -- bridge the protocol-independent memory API
// (fw_mem_if, from fw-hdl's fw_std_pkg) to the Wishbone transactor bridges. Pure
// class-layer logic: no new transactor, interface, or pins. These re-introduce a
// dependency on fw-hdl (fw_component / fw_export / fw_mem_if), so the kit's core
// transactor layer is no longer fully fw-hdl-free once this file is compiled in.
//
// One fw_mem_if read/write becomes one Wishbone `access()` on wb_proto_if; the new
// transactor API terminates a transfer with a single `err` bit (ACK implicit,
// no RTY), so there is no retry loop.
//
// Fixed 32-bit widths (WB_AW=WB_DW=32) declared EXPLICITLY as `logic [31:0]` /
// `logic [3:0]`, matching the model's fw_port#(fw_mem_if#(logic[31:0], ...))
// specialization exactly -- a bare/parameterized form would mangle to a
// different simulator type and fail to connect.

// Initiator-side: PROVIDES fw_mem_if (the DMA engine's master port connects to
// `mem`) and drives each read/write onto Wishbone through a wb_proto_if handle
// (a wb_initiator_xtor_bridge). Mirror of the retired wb_to_std.
//   Wire: <engine>.mifN.connect(wb_mem_initiator.mem) ;  the bridge over the
//         wb_initiator_xtor's u_if is handed in at construction.
class wb_mem_initiator extends fw_component;
    wb_proto_if #(32, 32) m_wb;                                       // WB initiator bridge
    `FW_MEM_IMP(logic [31:0], logic [31:0], logic [3:0], wb_mem_initiator, mem);

    function new(string name, fw_component parent, wb_proto_if #(32, 32) wb);
        super.new(name, parent);
        m_wb = wb;
        mem  = new(this);
    endfunction

    virtual task mem_write(output bit err, input logic [31:0] addr,
                           input logic [31:0] data, input logic [3:0] strb);
        automatic logic [31:0] dr;
        m_wb.access(addr, data, strb, 1'b1, dr, err);
    endtask

    virtual task mem_read(output logic [31:0] data, output bit err,
                          input logic [31:0] addr);
        m_wb.access(addr, 32'h0, 4'hf, 1'b0, data, err);
    endtask
endclass

// Target-side: IMPLEMENTS wb_proto_if (so a wb_target_xtor_bridge can call it for
// each captured request) and services each request by calling a model that
// provides fw_mem_if (e.g. the DMA register-file host port). Mirror of the retired
// std_to_wb -- but a plain class (the target bridge holds a wb_proto_if directly,
// no fw_port/fw_export needed on this side).
//   Wire: new wb_target_xtor_bridge(u_slv.u_if, wb_mem_target) ; then start() it.
class wb_mem_target implements wb_proto_if #(32, 32);
    fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) m_mem;       // backing memory model

    function new(fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) mem);
        m_mem = mem;
    endfunction

    virtual task access(
            input  [31:0] adr,
            input  [31:0] dat_w,
            input  [3:0]  sel,
            input         we,
            output [31:0] dat_r,
            output        err);
        automatic bit e;
        if (we) begin
            m_mem.write(e, adr, dat_w, sel);
            dat_r = 32'h0;
        end else begin
            m_mem.read(dat_r, e, adr);
        end
        err = e;
    endtask
endclass

// TLM connector: an fw_export #(wb_proto_if) that an engine master port connects
// to, whose access() redirects to a REGISTERED wb_proto_if client (the responder
// the testbench registers). The TLM analogue of wb_target_xtor_bridge -- there the
// converter polls a signal FIFO and calls the client; here the engine calls
// access() directly (a method call, no bus) and we forward it to the SAME client.
// So one responder (any wb_proto_if implementer, e.g. a sequence implementing
// access) serves both the TLM and the signal (WB) paths, only the connector
// differs. The client is set after construction (set_client), e.g. from the UVM
// env's connect_phase once the responder exists.
class wb_proto_client_export #(int unsigned ADDR_WIDTH = 32,
                               int unsigned DATA_WIDTH = 32)
        extends fw_export #(wb_proto_if #(ADDR_WIDTH, DATA_WIDTH))
        implements wb_proto_if #(ADDR_WIDTH, DATA_WIDTH);
    wb_proto_if #(ADDR_WIDTH, DATA_WIDTH) client;

    function new(string name, fw_component parent);
        super.new(name, parent, null);   // set_imp(this) AFTER super.new: passing
        set_imp(this);                    // `this` INTO it segfaults Verilator
    endfunction

    function void set_client(wb_proto_if #(ADDR_WIDTH, DATA_WIDTH) c);
        client = c;
    endfunction

    virtual task access(
            input  [ADDR_WIDTH-1:0]      adr,
            input  [DATA_WIDTH-1:0]      dat_w,
            input  [(DATA_WIDTH/8)-1:0]  sel,
            input                        we,
            output [DATA_WIDTH-1:0]      dat_r,
            output                       err);
        client.access(adr, dat_w, sel, we, dat_r, err);
    endtask
endclass
