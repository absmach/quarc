// lifecycle.v - Lifecycle state machine (MANUFACTURING -> PROVISIONED -> LOCKED -> RMA)
// STUB: full implementation lands in Phase 6.

`default_nettype none
`timescale 1ns/1ps

module lifecycle (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    output wire [1:0]  state
);

    assign state = 2'b00; // MANUFACTURING

    always @(*) begin
        bus_rdata = {30'b0, state};
        bus_ack   = bus_req;
    end

    wire unused = &{1'b0, rst_n, bus_we, bus_addr, bus_wdata};

endmodule

`default_nettype wire
