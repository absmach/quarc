// keystore.v - BRAM-backed key store, accessible only to the KUE
// STUB: full implementation lands in Phase 4.

`default_nettype none
`timescale 1ns/1ps

module keystore (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        kue_req,
    input  wire        kue_we,
    input  wire [11:0] kue_addr,
    input  wire [31:0] kue_wdata,
    output reg  [31:0] kue_rdata
);

    always @(posedge clk) begin
        if (!rst_n) kue_rdata <= 32'h0;
        else        kue_rdata <= 32'h0;
    end

    wire unused = &{1'b0, kue_req, kue_we, kue_addr, kue_wdata};

endmodule

`default_nettype wire
