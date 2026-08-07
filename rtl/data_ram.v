`default_nettype none
`timescale 1ns/1ps

// data_ram.v - 16 KiB word-addressed Data RAM at 0x0001_4000
//
// Mirrors the boot_rom read interface (rvalid one cycle after req, registered
// rdata) and supports byte-enable writes. Not present in Phase 0-3 (firmware
// used no data memory); required from Phase 4 onward.

module data_ram (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg         rvalid,
    output reg  [31:0] rdata
);
    reg [31:0] mem [0:4095];

    // BRAM-like zero-init (matches FPGA behaviour; iverilog regs default to X)
    integer i;
    initial for (i = 0; i < 4096; i = i + 1) mem[i] = 32'h0;

    always @(posedge clk) begin
        if (we) begin
            if (be[0]) mem[addr[13:2]][7:0]   <= wdata[7:0];
            if (be[1]) mem[addr[13:2]][15:8]  <= wdata[15:8];
            if (be[2]) mem[addr[13:2]][23:16] <= wdata[23:16];
            if (be[3]) mem[addr[13:2]][31:24] <= wdata[31:24];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rvalid <= 1'b0;
            rdata  <= 32'h0;
        end else begin
            rvalid <= req;
            if (req)
                rdata <= mem[addr[13:2]];
            else
                rdata <= 32'h0;
        end
    end

endmodule

`default_nettype wire
