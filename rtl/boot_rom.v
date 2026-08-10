// boot_rom.v - Synthesis-time Verilog ROM
// Dual read port: the instruction port serves code, the data port serves
// .rodata/.data constants (C firmware needs to read initialized data through
// the data bus). Read-only: writes are rejected by the bus decoder.
//
// $readmemh expects a 32-bit-wide hex file with one word per line, addressed
// by word index (addr[14:2] for 32 KiB / 4 = 8192 entries).

`default_nettype none
`timescale 1ns/1ps

module boot_rom #(
    parameter         ROM_FILE = "fw/boot.hex",
    parameter integer DEPTH    = 8192           // 32 KiB / 4 bytes
) (
    input  wire        clk,
    input  wire        rst_n,

    // Instruction port
    input  wire        instr_req,
    input  wire [31:0] instr_addr,
    output reg         instr_rvalid,
    output reg  [31:0] instr_rdata,

    // Data port
    input  wire        data_req,
    input  wire [31:0] data_addr,
    output reg         data_rvalid,
    output reg  [31:0] data_rdata
);

    reg [31:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(ROM_FILE, mem);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            instr_rvalid <= 1'b0;
            instr_rdata  <= 32'h0;
        end else begin
            instr_rvalid <= instr_req;
            if (instr_req)
                instr_rdata <= mem[instr_addr[14:2]];
            else
                instr_rdata <= 32'h0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            data_rvalid <= 1'b0;
            data_rdata  <= 32'h0;
        end else begin
            data_rvalid <= data_req;
            if (data_req)
                data_rdata <= mem[data_addr[14:2]];
            else
                data_rdata <= 32'h0;
        end
    end

endmodule

`default_nettype wire
