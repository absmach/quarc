// trng.v - Ring-oscillator TRNG with SP 800-90B health tests
// STUB: full implementation lands in Phase 2.

`default_nettype none
`timescale 1ns/1ps

module trng (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    output wire        health_fail
);

    assign health_fail = 1'b0;

    always @(*) begin
        bus_rdata = 32'h0;
        bus_ack   = bus_req;
    end

    wire unused = &{1'b0, rst_n, bus_we, bus_addr, bus_wdata};

endmodule

`default_nettype wire
