// boot_rom.v - Synthesis-time Verilog ROM
// Phase 0: contents are a minimal banner program that prints "QUARC v0\r\n"
// over UART and then loops. Real secure-boot content arrives in Phase 6.
//
// $readmemh expects a 32-bit-wide hex file with one word per line, addressed
// by word index (addr[13:2] for 16 KiB / 4 = 4096 entries).

`default_nettype none
`timescale 1ns/1ps

module boot_rom #(
    parameter         ROM_FILE = "fw/boot.hex",
    parameter integer DEPTH    = 4096           // 16 KiB / 4 bytes
) (
    input  wire        clk,
    input  wire        req,
    input  wire [31:0] addr,
    output reg         rvalid,
    output reg  [31:0] rdata
);

    reg [31:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(ROM_FILE, mem);
    end

    always @(posedge clk) begin
        rvalid <= req;
        if (req)
            rdata <= mem[addr[13:2]];
        else
            rdata <= 32'h0;
    end

endmodule

`default_nettype wire
