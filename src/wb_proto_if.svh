// Wishbone access API -- the canonical individual-argument, width-parameterized
// transfer interface shared by BOTH roles (initiator and target use the identical
// signature, so one interface serves both):
//   - INITIATOR (master): the wb_initiator_xtor_bridge IMPLEMENTS it; a driver
//     calls access() to issue a transfer and block until its response returns.
//   - TARGET (slave): a model IMPLEMENTS it; the wb_target_xtor_bridge calls
//     access() for each captured request to obtain the response to drive back.
//   adr/dat_w/sel/we : the request (write data on we=1)
//   dat_r/err        : the response (read data + ERR; ACK implicit on !err)
// Latency-insensitive: a transfer completes on ack, after any number of cycles.
(* fw_latency_insensitive *)
interface class wb_proto_if #(
        parameter int ADDR_WIDTH = 32,
        parameter int DATA_WIDTH = 32);

    pure virtual task access(
            input  [ADDR_WIDTH-1:0]      adr,
            input  [DATA_WIDTH-1:0]      dat_w,
            input  [(DATA_WIDTH/8)-1:0]  sel,
            input                        we,
            output [DATA_WIDTH-1:0]      dat_r,
            output                       err);

endclass
