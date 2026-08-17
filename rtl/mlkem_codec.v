`default_nettype none
`timescale 1ns/1ps

// mlkem_codec.v - ML-KEM byte_encode / byte_decode bit-packer
//
// Parameter D is the coefficient bit-width (12, 10, 4, 1).
//   op=0 (encode): feed coefficients -> byte stream (little-endian bit pack)
//   op=1 (decode): feed bytes        -> coefficient stream
// Streaming valid/ready handshake, one coefficient or byte per accepted cycle.

module mlkem_codec #(
    parameter integer D = 12
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        op,        // 0 = encode, 1 = decode
    input  wire        din_valid,
    input  wire [11:0] din,      // coefficient (encode) or byte (decode)
    output reg         din_ready,
    output reg  [11:0] dout,      // byte (encode) or coefficient (decode)
    output reg         dout_valid,
    output wire        dout_ready   // downstream accepts (always-ready here)
);

    assign dout_ready = 1'b1;

    reg [31:0] acc;
    reg [4:0]  bits;
    reg [4:0]  step;       // sub-state for the multi-emit loop

    localparam [11:0] MASK = (1 << D) - 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            acc <= 32'h0;
            bits <= 5'd0;
            step <= 5'd0;
            din_ready <= 1'b1;
            dout_valid <= 1'b0;
            dout <= 12'h0;
        end else begin
            din_ready <= 1'b0;
            dout_valid <= 1'b0;

            if (step == 5'd0) begin
                din_ready <= 1'b1;
                if (din_valid) begin
                    if (op == 1'b0) begin
                        // encode: pack a coefficient into the accumulator
                        acc  <= acc | ({32'd0, din} << bits);
                        bits <= bits + D;
                        step <= 5'd1;
                    end else begin
                        // decode: push a byte into the accumulator
                        acc  <= acc | ({24'd0, din} << bits);
                        bits <= bits + 5'd8;
                        step <= 5'd1;
                    end
                end
            end else if (step == 5'd1) begin
                if (op == 1'b0) begin
                    // encode: emit bytes while >= 8 bits available
                    if (bits >= 5'd8) begin
                        dout       <= acc[7:0];
                        dout_valid <= 1'b1;
                        acc        <= acc >> 8;
                        bits       <= bits - 5'd8;
                    end else begin
                        step <= 5'd0;
                    end
                end else begin
                    // decode: emit coefficients while >= D bits available
                    if (bits >= D) begin
                        dout       <= acc & MASK;
                        dout_valid <= 1'b1;
                        acc        <= acc >> D;
                        bits       <= bits - D;
                    end else begin
                        step <= 5'd0;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
