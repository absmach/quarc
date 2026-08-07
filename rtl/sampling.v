`default_nettype none
`timescale 1ns/1ps

// sampling.v - ML-KEM (FIPS 203) coefficient sampling: SampleNTT + SamplePolyCBD
//
// Byte-oriented input (fed from the SHAKE/SHA3 core on the keccak c2 client):
//   mode 0 (SampleNTT): consume XOF bytes in 3-byte groups, emit up to two
//                       12-bit coefficients per group (rejecting those >= q).
//   mode 1 (CBD):       consume exactly 64*eta bytes, then emit 256 coefficients
//                       from the centered binomial distribution.
// Each accepted coefficient pulses coeff_valid_o; done_o asserts after 256.

module sampling (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_i,
    input  wire        mode_i,        // 0 = SampleNTT, 1 = CBD
    input  wire [1:0]  eta_i,         // CBD eta: 2 or 3

    input  wire [7:0]  byte_i,
    input  wire        byte_valid_i,
    output wire        byte_ready_o,

    output reg  [11:0] coeff_o,
    output reg         coeff_valid_o,
    output reg         done_o
);

    localparam Q = 12'd3329;

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_NTT      = 3'd1;
    localparam [2:0] S_NTT_D1   = 3'd2;
    localparam [2:0] S_NTT_D2   = 3'd3;
    localparam [2:0] S_CBD_IN   = 3'd4;
    localparam [2:0] S_CBD_OUT  = 3'd5;

    reg [2:0]  st;
    reg [8:0]  ncoeff;         // accepted coefficient count
    reg [7:0]  gbuf [0:2];     // SampleNTT 3-byte group
    reg [1:0]  gcnt;           // bytes collected in current group
    reg [10:0] cbd_wr;         // CBD bytes collected (max 192)
    reg [1535:0] cbd_buf;      // CBD bit stream (byte i at bits [8i +: 8])
    reg [8:0]  cbd_i;          // CBD coefficient index

    wire [11:0] ntt_d1 = gbuf[0] | ((gbuf[1] & 12'h00F) << 8);
    wire [11:0] ntt_d2 = (gbuf[1] >> 4) | (gbuf[2] << 4);

    // byte_ready is combinational on the accept state (no registered lag)
    assign byte_ready_o = (st == S_NTT) || (st == S_CBD_IN);

    function [2:0] pop3(input [2:0] x);
        begin
            pop3 = x[0] + x[1] + x[2];
        end
    endfunction

    // 64*eta = eta << 6 (the whole polynomial's byte count)
    wire [10:0] cbd_total = {3'b0, eta_i, 6'd0};

    // coefficient i of CBD uses stream bits [2*eta*i +: 2*eta]; extract a byte
    wire [15:0] cbd_shift = {7'b0, eta_i, 1'b0} * cbd_i;   // 2*eta*i (max 1530)
    wire [7:0]  cbd_x     = cbd_buf[cbd_shift +: 8];
    reg  [2:0]  lo_cnt, hi_cnt;
    always @(*) begin
        case (eta_i)
            2'd2: begin
                lo_cnt = pop3({1'b0, cbd_x[1:0]});
                hi_cnt = pop3({1'b0, cbd_x[3:2]});
            end
            default: begin
                lo_cnt = pop3(cbd_x[2:0]);
                hi_cnt = pop3(cbd_x[5:3]);
            end
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            ncoeff        <= 9'd0;
            gcnt          <= 2'd0;
            cbd_wr        <= 11'd0;
            cbd_i         <= 9'd0;
            coeff_valid_o <= 1'b0;
            coeff_o       <= 12'd0;
            done_o        <= 1'b0;
        end else begin
            coeff_valid_o <= 1'b0;
            done_o        <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (start_i) begin
                        ncoeff        <= 9'd0;
                        gcnt          <= 2'd0;
                        cbd_wr        <= 11'd0;
                        cbd_i         <= 9'd0;
                        st <= mode_i ? S_CBD_IN : S_NTT;
                    end
                end

                // ---------------- SampleNTT ----------------
                S_NTT: begin
                    if (byte_valid_i) begin
                        gbuf[gcnt] <= byte_i;
                        if (gcnt == 2'd2) begin
                            gcnt <= 2'd0;
                            st <= S_NTT_D1;
                        end else begin
                            gcnt <= gcnt + 2'd1;
                        end
                    end
                end

                S_NTT_D1: begin
                    coeff_o       <= ntt_d1;
                    coeff_valid_o <= (ntt_d1 < Q);
                    if (ntt_d1 < Q) begin
                        if (ncoeff == 9'd255) begin
                            done_o <= 1'b1;
                            st     <= S_IDLE;
                        end else begin
                            ncoeff <= ncoeff + 9'd1;
                            st     <= S_NTT_D2;
                        end
                    end else begin
                        st <= S_NTT_D2;
                    end
                end

                S_NTT_D2: begin
                    coeff_o       <= ntt_d2;
                    coeff_valid_o <= (ntt_d2 < Q);
                    if (ntt_d2 < Q) begin
                        if (ncoeff == 9'd255) begin
                            done_o <= 1'b1;
                            st     <= S_IDLE;
                        end else begin
                            ncoeff <= ncoeff + 9'd1;
                            st     <= S_NTT;
                        end
                    end else begin
                        st <= S_NTT;
                    end
                end

                // ---------------- CBD ----------------
                S_CBD_IN: begin
                    if (byte_valid_i) begin
                        cbd_buf[8*cbd_wr +: 8] <= byte_i;
                        if (cbd_wr == cbd_total - 11'd1) begin
                            cbd_i  <= 9'd0;
                            st     <= S_CBD_OUT;
                        end
                        cbd_wr <= cbd_wr + 11'd1;
                    end
                end

                S_CBD_OUT: begin
                    coeff_o       <= (lo_cnt >= hi_cnt) ? (lo_cnt - hi_cnt)
                                     : (lo_cnt + 12'd3329 - hi_cnt);
                    coeff_valid_o <= 1'b1;
                    if (cbd_i == 9'd255) begin
                        done_o <= 1'b1;
                        st     <= S_IDLE;
                    end
                    cbd_i <= cbd_i + 9'd1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
