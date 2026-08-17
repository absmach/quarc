`default_nettype none
`timescale 1ns/1ps

// mlkem_compress.v - ML-KEM Compress / Decompress
//
//   compress(x, d)   = (((x << d) + Q/2) // Q) & ((1 << d) - 1)
//   decompress(y, d) = ((y * Q + 2^(d-1)) >> d) % Q
//
// d selects the bit width (1, 4 or 10) via the 2-bit d_i input.
// compress uses a combinational restoring division by Q (3329).

module mlkem_compress (
    input  wire [11:0] x,
    input  wire [1:0]  d_i,        // 0->1, 1->4, 2->10
    output reg  [11:0] comp,
    output reg  [11:0] decomp
);

    localparam [11:0] Q = 12'd3329;

    // restore-divide p (up to 24 bits) by Q, 24-bit quotient (top bits zero)
    function [23:0] div_q;
        input [23:0] p;
        reg [24:0] r;
        integer i;
        begin
            r = 25'd0;
            for (i = 23; i >= 0; i = i - 1) begin
                r = (r << 1) | p[i];
                if (r >= 25'd3329) begin
                    r = r - 25'd3329;
                    div_q[i] = 1'b1;
                end else begin
                    div_q[i] = 1'b0;
                end
            end
        end
    endfunction

    wire [23:0] shift;
    wire [3:0]  mask;

    assign shift = (d_i == 2'd2) ? (x << 10) :
                   (d_i == 2'd1) ? (x << 4)  :
                                   (x << 1);
    assign mask  = (d_i == 2'd2) ? 4'd10   :
                   (d_i == 2'd1) ? 4'd4    :
                                   4'd1;

    reg [23:0] qfull;
    always @(*) begin
        qfull = div_q(shift + 24'd1664);
        comp  = qfull[11:0] & ((12'hFFF) >> (12 - mask));
    end

    // decompress: y is the low `mask` bits of x; multiply by Q and shift
    reg [23:0] yq;
    always @(*) begin
        case (d_i)
            2'd2: yq = (x[9:0] * Q);
            2'd1: yq = (x[3:0] * Q);
            default: yq = (x[0:0] * Q);
        endcase
    end

    always @(*) begin
        case (d_i)
            2'd2: decomp = ((yq + 24'd512) >> 10) % Q;
            2'd1: decomp = ((yq + 24'd8) >> 4) % Q;
            default: decomp = ((yq + 24'd1) >> 1) % Q;
        endcase
    end

endmodule

`default_nettype wire
