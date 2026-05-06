// keccak.v - Keccak-f[1600] permutation
// STUB: full implementation lands in Phase 1.

`default_nettype none
`timescale 1ns/1ps

module keccak_f1600 (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           start,
    input  wire  [1599:0] state_in,
    output reg   [1599:0] state_out,
    output reg            done
);

    always @(posedge clk) begin
        if (!rst_n) begin
            state_out <= 1600'b0;
            done      <= 1'b0;
        end else begin
            state_out <= state_in;
            done      <= start;
        end
    end

endmodule

`default_nettype wire
