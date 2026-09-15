// Wishbone protocol kit -- class layer. The transactor SV interfaces and modules
// (wb_*_xtor*.sv) are separate compilation units (an interface/module cannot live
// in a package); they are listed alongside this file in the FileSet.
//
// The APIs are individual-argument and width-parameterized (#(ADDR_WIDTH,
// DATA_WIDTH)). wb_proto_if is the single transfer API shared by both roles: the
// initiator bridge IMPLEMENTS it; a target model IMPLEMENTS it and the target bridge
// HOLDS it. The monitor bridge HOLDS a wb_monitor_if handle and drives it from a
// run() loop forked by start().
//
// This package is fw-hdl-FREE: it is the protocol kit proper, and compiling it
// requires nothing but the transactor interfaces alongside it. The adapters onto
// the protocol-independent memory API (fw_mem_if, from fw-hdl's fw_std_pkg) live
// in the separate fw_proto_wb_spl_pkg, which imports this package and is built
// only when the kit is configured with fw-hdl available.

package fw_proto_wb_pkg;
    // API interface-classes.
    `include "wb_proto_if.svh"           // shared initiator/target transfer API
    `include "wb_monitor_if.svh"

    // Transactor bridges -- hold a virtual transactor-interface and implement (or
    // drive) the API. They reference the transactor SV interfaces by their
    // (unmangled) names, so those interfaces must be compiled in the same image.
    `include "wb_initiator_xtor_bridge.svh"
    `include "wb_target_xtor_bridge.svh"
    `include "wb_monitor_xtor_bridge.svh"

endpackage
