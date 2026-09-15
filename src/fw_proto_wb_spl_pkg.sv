// Wishbone protocol kit -- fw-hdl standard-platform layer (SPL).
//
// Everything in the kit that depends on fw-hdl lives HERE, and nowhere else.
// fw_proto_wb_pkg (the API interface-classes and the transactor bridges) is
// fw-hdl-free and compiles standalone; this package sits on top of it and adds
// the adapters between Wishbone and fw-hdl's protocol-independent memory API
// (fw_mem_if, from fw_std_pkg).
//
// The split exists so the kit can be consumed two ways from one source tree:
//   fw.proto.wb.class  -- fw_proto_wb_pkg only, no fw-hdl anywhere in the image
//   fw.proto.wb.spl    -- this package on top, requires fw-hdl (declared by the
//                         `use-fw-hdl` config, which is also what makes the
//                         fw-hdl import resolvable in the first place)
//
// Consumers that want the adapters import fw_proto_wb_spl_pkg INSTEAD of
// fw_proto_wb_pkg: this package re-exports the kit's API classes, so a single
// import gets both layers.
`include "fw_std_macros.svh"                  // FW_MEM_IMP (from fw-hdl std)

package fw_proto_wb_spl_pkg;
    import fw_hdl_pkg::*;                      // fw_component / fw_port / fw_export
    import fw_std_pkg::*;                      // fw_mem_if
    export fw_std_pkg::*;                      // re-export fw_mem_if to consumers

    import fw_proto_wb_pkg::*;                 // wb_proto_if + the *_xtor_bridge classes
    export fw_proto_wb_pkg::*;                 // ...re-exported: one import gets both layers

    // Protocol-independent memory-access adapters (fw_mem_if <-> wb_proto_if).
    `include "wb_mem_adapters.svh"

endpackage
