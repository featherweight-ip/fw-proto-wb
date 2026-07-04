---
name: fw-proto-wb
description: >
  Use this skill to USE the Featherweight-HDL Wishbone B3 protocol library
  (package `wb.proto`, in fw-proto-wb) from an application or testbench: how to
  reference the package from a dv-flow build relative to $IVPM_PACKAGES, instance
  the master/slave/monitor transactors on a Wishbone bus, drive and service
  transfers through the class-level APIs (`wb_initiator_if` / `wb_target_if` /
  `wb_monitor_if`), and use the protocol-independent `std_mem_if` adapters. This
  is the CONSUMER guide; to BUILD a new protocol kit see the `fw-proto-kit` skill.
---

# Using the Wishbone (wb.proto) protocol library

The `wb.proto` package (in `fw-proto-wb`) bridges class-level **APIs** to the
signal-level **Wishbone B3** bus. A component written against an API never touches
pins — a *transactor* does. You instance the transactor module(s) on your bus,
wrap them in *bridges*, and `connect()` your components' ports/exports to them.

Three roles, each with an API and a transactor module:

| Role | Module | API (`#(wb_req_t, wb_rsp_t)`) | You provide / consume |
| --- | --- | --- | --- |
| **initiator** (master) | `wb_initiator_xtor` | `wb_initiator_if` — `xfer(rsp, req)` | hold a `fw_port`, call `xfer` |
| **target** (slave) | `wb_target_xtor` | `wb_target_if` — `access(rsp, req)` | implement via `` `FW_WB_TARGET_IMP `` |
| **monitor** | `wb_monitor_xtor` | `wb_monitor_if` — `observe(xfer)` | implement via `` `FW_WB_MONITOR_IMP `` |

Higher-level, protocol-independent option: the **`std_mem_if`** adapters
(`wb_to_std`, `std_to_wb`) let your code talk `read`/`write` and never mention
Wishbone — see "std adapters" below.

All payloads are packed structs from `wb_types_pkg` (32-bit fixed: `WB_AW=32`,
`WB_DW=32`, `WB_SW=4`):
```systemverilog
wb_req_t : { adr, dat /*write data*/, sel, we, cyc_hold }   // cyc_hold=1 chains block/RMW
wb_rsp_t : { dat /*read data*/, err, rty }                  // ACK implicit: completed && !err && !rty
wb_xfer_t: { req, rsp }                                       // one observed phase (monitor)
```

## 1. Reference the package from your dv-flow build

Import `wb.proto` **relative to `$IVPM_PACKAGES`**, and depend on its one
exported task, **`wb.proto.files`** (the kit sources + the fw modeling library it
pulls in transitively). `wb.proto.files` is the only `export`ed task — it is what
consumers reference; the kit's own `wb-proto` / `wb-std` / `fv` tasks are internal
test gates, not for consumers.

```yaml
# your app's flow.yaml
package:
  name: myapp
  imports:
  - ${{ env.IVPM_PACKAGES }}/fw-proto-wb       # loads package wb.proto (+ fw-hdl)
  tasks:
  - name: tb
    uses: std.FileSet
    with: { type: systemVerilogSource, include: [my_tb.sv], incdirs: ['.'] }
  - name: img
    uses: hdlsim.vlt.SimImage
    needs: [wb.proto.files, tb]                 # <-- the kit's exported source task
    with: { top: [my_tb] }
  - root: run
    uses: hdlsim.vlt.SimRun
    needs: [img]
```
Run with `$IVPM_PACKAGES` set and the tools on `PATH`:
```bash
export IVPM_PACKAGES=<…>/packages
export PATH=$IVPM_PACKAGES/python/bin:$IVPM_PACKAGES/verilator/bin:$PATH
dfm run myapp.run
```
You do **not** import `fw-hdl` yourself — `wb.proto` imports it (also relative to
`$IVPM_PACKAGES`) and `wb.proto.files` carries it in.

## 2. Instance the transactors on a Wishbone bus

Wishbone has **two unidirectional data buses**: `dat_m2s` (master→slave write data)
and `dat_s2m` (slave→master read data). Wire one initiator to one target; tap with
a monitor if you want to observe.

```systemverilog
logic clk = 0, rst = 1;
bit [31:0] adr, dat_m2s, dat_s2m;
bit [3:0]  sel;
bit        we, cyc, stb, ack, err, rty;
always #5ns clk = ~clk;

wb_initiator_xtor ix (
    .clock(clk), .reset(rst),
    .adr_o(adr), .dat_o(dat_m2s), .sel_o(sel), .we_o(we), .cyc_o(cyc), .stb_o(stb),
    .dat_i(dat_s2m), .ack_i(ack), .err_i(err), .rty_i(rty));
wb_target_xtor tx (
    .clock(clk), .reset(rst),
    .adr_i(adr), .dat_i(dat_m2s), .sel_i(sel), .we_i(we), .cyc_i(cyc), .stb_i(stb),
    .dat_o(dat_s2m), .ack_o(ack), .err_o(err), .rty_o(rty));
// optional passive monitor (drives nothing):
wb_monitor_xtor mx (
    .clock(clk), .reset(rst),
    .adr(adr), .dat_w(dat_m2s), .dat_r(dat_s2m), .sel(sel), .we(we),
    .cyc(cyc), .stb(stb), .ack(ack), .err(err), .rty(rty));
```
Reach each module's `u_if` (e.g. `ix.u_if`) to bind a bridge's virtual interface.

## 3. Build bridges and connect the APIs

A **bridge** wraps a transactor's `u_if` and carries the API. Build bridges in a
component's `connect()`; connect ports to exports.

```systemverilog
import fw_pkg::*; import wb_types_pkg::*; import wb_proto_pkg::*;
// initiator: your driver holds a port; connect it to the initiator bridge's export
wb_initiator_bridge #(wb_req_t, wb_rsp_t) ibr = new("ibr", this, ix.u_if);
drv.out.connect(ibr.exp);
// target: a bridge (a port) that calls into your model's export
wb_target_bridge #(wb_req_t, wb_rsp_t) tbr = new("tbr", this, tx.u_if);
tbr.connect(mdl.in);
// then start the target (and monitor) sampling loops:  fork tbr.run(); join_none
```

## 4. Use the APIs

**Initiator (drive transfers).** Hold a port, resolve the API, call `xfer` —
outputs lead, so it reads `rsp = xfer(req)`:
```systemverilog
class driver extends fw_component;
    fw_port #(wb_initiator_if #(wb_req_t, wb_rsp_t)) out;
    function void build(); out = new("out", this); endfunction
    task run();
        wb_initiator_if #(wb_req_t, wb_rsp_t) api = out.get_if();
        wb_req_t req; wb_rsp_t rsp;
        req = '{adr:32'h40, dat:32'hbeef, sel:4'hf, we:1'b1, cyc_hold:1'b0};
        api.xfer(rsp, req);                     // WRITE (blocks until ACK/ERR/RTY)
        req = '{adr:32'h40, dat:32'h0, sel:4'hf, we:1'b0, cyc_hold:1'b0};
        api.xfer(rsp, req);                     // READ -> rsp.dat (== 0xbeef)
        if (rsp.err) /* bus error */;  if (rsp.rty) /* retry */;
    endtask
endclass
```
Block/RMW: set `cyc_hold=1` on every transfer except the last of the run; the
master keeps `CYC` asserted across the chain.

**Target (service transfers).** PROVIDE the API with the macro; implement
`<NAME>_access` — outputs lead (`rsp = access(req)`):
```systemverilog
class model extends fw_component;
    logic [31:0] mem [logic [31:0]];
    `FW_WB_TARGET_IMP(wb_req_t, wb_rsp_t, model, in);     // export member `in`
    function void build(); in = new(this); endfunction
    task in_access(output wb_rsp_t rsp, input wb_req_t req);
        rsp = '{dat:32'h0, err:1'b0, rty:1'b0};
        if (req.we) mem[req.adr] = req.dat;               // honor req.sel for sub-word
        else        rsp.dat = mem.exists(req.adr) ? mem[req.adr] : 32'h0;
        // set rsp.err / rsp.rty to terminate with ERR / RTY
    endtask
endclass
```

**Monitor (observe phases).** PROVIDE `wb_monitor_if`; `observe` is a non-blocking
function called once per completed phase:
```systemverilog
class observer extends fw_component;
    wb_xfer_t seen[$];
    `FW_WB_MONITOR_IMP(wb_xfer_t, observer, mon);
    function void build(); mon = new(this); endfunction
    function void mon_observe(input wb_xfer_t x); seen.push_back(x); endfunction
endclass
```

## std adapters — talk read/write, not Wishbone

To keep app/model code protocol-independent, use the `std_mem_if` adapters:
- **`wb_to_std`** (initiator side) PROVIDES `std_mem_if` (`read`/`write`, with
  RTY-retry + ERR-escalation) over a Wishbone initiator. Wire: your driver's
  `std_mem_if` port → `wb_to_std.std`; `wb_to_std.wb` → `wb_initiator_bridge.exp`.
- **`std_to_wb`** (target side) backs a Wishbone slave with any `std_mem_if`
  model. Wire: `wb_target_bridge.connect(std_to_wb.tgt)`; `std_to_wb.mem` → model.

`std_mem_if` methods (outputs lead): `write(output bit err, input addr, data, strb)`
and `read(output data, output bit err, input addr)`.

## Complete minimal example (validated)

A driver that writes then reads one word against a memory model. This is the
`my_tb.sv` that the flow.yaml in §1 runs (`dfm run myapp.run` → `[myapp] PASS`).

```systemverilog
module my_tb;
  import fw_pkg::*; import wb_types_pkg::*; import wb_proto_pkg::*;

  class driver extends fw_component;
    fw_port #(wb_initiator_if #(wb_req_t, wb_rsp_t)) out;  int errors;
    function new(string n, fw_component p); super.new(n,p); endfunction
    function void build(); out = new("out", this); endfunction
    task run();
      wb_initiator_if #(wb_req_t, wb_rsp_t) api = out.get_if();
      wb_req_t req; wb_rsp_t rsp;
      req = '{adr:32'h40, dat:32'hbeef, sel:4'hf, we:1'b1, cyc_hold:1'b0};
      api.xfer(rsp, req);
      req = '{adr:32'h40, dat:32'h0, sel:4'hf, we:1'b0, cyc_hold:1'b0};
      api.xfer(rsp, req);
      if (rsp.dat !== 32'hbeef) errors++;
    endtask
  endclass

  class model extends fw_component;
    logic [31:0] mem [logic [31:0]];
    `FW_WB_TARGET_IMP(wb_req_t, wb_rsp_t, model, in);
    function new(string n, fw_component p); super.new(n,p); endfunction
    function void build(); in = new(this); endfunction
    task in_access(output wb_rsp_t rsp, input wb_req_t req);
      rsp = '{dat:32'h0, err:1'b0, rty:1'b0};
      if (req.we) mem[req.adr] = req.dat;
      else rsp.dat = mem.exists(req.adr) ? mem[req.adr] : 32'h0;
    endtask
  endclass

  class top extends fw_component;
    driver drv; model mdl;
    wb_target_bridge #(wb_req_t, wb_rsp_t) tbr;
    virtual wb_initiator_xtor_if vi; virtual wb_target_xtor_if vt;
    function new(string n, fw_component p); super.new(n,p); endfunction
    function void build(); drv=new("drv",this); mdl=new("mdl",this); drv.build(); mdl.build(); endfunction
    function void connect();
      wb_initiator_bridge #(wb_req_t, wb_rsp_t) ibr = new("ib", this, vi);
      drv.out.connect(ibr.exp);
      tbr = new("tb", this, vt); tbr.connect(mdl.in);
    endfunction
  endclass

  logic clk=0, rst=1; bit [31:0] adr,dm,ds; bit [3:0] sel; bit we,cyc,stb,ack,err,rty;
  always #5ns clk=~clk;
  wb_initiator_xtor ix(.clock(clk),.reset(rst),.adr_o(adr),.dat_o(dm),.sel_o(sel),.we_o(we),.cyc_o(cyc),.stb_o(stb),.dat_i(ds),.ack_i(ack),.err_i(err),.rty_i(rty));
  wb_target_xtor    tx(.clock(clk),.reset(rst),.adr_i(adr),.dat_i(dm),.sel_i(sel),.we_i(we),.cyc_i(cyc),.stb_i(stb),.dat_o(ds),.ack_o(ack),.err_o(err),.rty_o(rty));
  initial begin
    automatic top t;
    rst=1; repeat(4) @(posedge clk); rst=0; @(posedge clk);
    t=new("t",null); t.vi=ix.u_if; t.vt=tx.u_if; t.build(); t.connect();
    fork t.tbr.run(); join_none
    t.drv.run();
    repeat(20) @(posedge clk);
    if (t.drv.errors==0) $display("[myapp] PASS"); else $display("[myapp] FAIL (%0d)", t.drv.errors);
    $finish;
  end
  initial begin #100us; $fatal(1,"timeout"); end
endmodule
```

## dfm tasks reference

- **`wb.proto.files`** — the kit's `export`ed source FileSet (kit + fw-hdl). This
  is the ONLY task a consumer references (`needs: [wb.proto.files, <your tb>]`).
- The kit's own gates (not for consumers, but useful to run when validating the
  kit itself): `wb.proto.wb-proto` (back-to-back sim), `wb.proto.wb-std` (std
  adapter stack), `wb.proto.fv` (back-to-back formal proof).

## Gotchas

- **Outputs-first APIs:** `xfer(rsp, req)` / `access(rsp, req)` — pass the response
  handle first.
- **Two data buses:** wire `dat_o`(master)→`dat_i`(slave) and
  `dat_o`(slave)→`dat_i`(master) as separate nets; don't tie them together.
- **Registered slave:** the kit's slave always inserts ≥1 wait state (it's clocked
  — a true zero-wait async slave is out of scope).
- **Start the target loop:** the target/monitor bridges are active — `fork
  tbr.run(); join_none` (and `mbr.run()`), or nothing services the bus.
- **Set `$IVPM_PACKAGES`** before `dfm run`; the kit's import of fw-hdl resolves
  through it at load time.
