// keccak.v - Keccak-f[1600] permutation
//
// Iterative: one round per clock, 24 cycles per permutation. `done` pulses
// exactly 24 clock cycles after `start`. All round logic is combinational
// between registered states (no inter-round paths).
//
// Lane packing: lane index i = x + 5*y. A lane occupies state[ i*64 +: 64 ].
// Message/state bytes enter lane (x,0) first, LSB-first, matching the
// Keccak reference implementation.

`default_nettype none
`timescale 1ns/1ps

module keccak_f1600 (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           start,        // Pulse to begin permutation
    input  wire  [1599:0] state_in,     // Full 1600-bit state input
    output wire  [1599:0] state_out,   // Full 1600-bit state output
    output reg            done          // Pulse when permutation complete
);

    localparam [4:0] NUM_ROUNDS = 5'd24;

    // ------------------------------------------------------------------
    // rho: per-lane rotation offsets, indexed by lane x + 5*y
    // ------------------------------------------------------------------
    function [63:0] rotl64;
        input [63:0] v;
        input [5:0]  n;
        begin
            rotl64 = (n == 6'd0) ? v : ((v << n) | (v >> (64 - n)));
        end
    endfunction

    function [5:0] rho_offset;
        input [2:0] x;
        input [2:0] y;
        begin
            case (x + 5*y)
                5'd0:  rho_offset = 6'd0;
                5'd1:  rho_offset = 6'd1;
                5'd2:  rho_offset = 6'd62;
                5'd3:  rho_offset = 6'd28;
                5'd4:  rho_offset = 6'd27;
                5'd5:  rho_offset = 6'd36;
                5'd6:  rho_offset = 6'd44;
                5'd7:  rho_offset = 6'd6;
                5'd8:  rho_offset = 6'd55;
                5'd9:  rho_offset = 6'd20;
                5'd10: rho_offset = 6'd3;
                5'd11: rho_offset = 6'd10;
                5'd12: rho_offset = 6'd43;
                5'd13: rho_offset = 6'd25;
                5'd14: rho_offset = 6'd39;
                5'd15: rho_offset = 6'd41;
                5'd16: rho_offset = 6'd45;
                5'd17: rho_offset = 6'd15;
                5'd18: rho_offset = 6'd21;
                5'd19: rho_offset = 6'd8;
                5'd20: rho_offset = 6'd18;
                5'd21: rho_offset = 6'd2;
                5'd22: rho_offset = 6'd61;
                5'd23: rho_offset = 6'd56;
                5'd24: rho_offset = 6'd14;
                default: rho_offset = 6'd0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // iota: round constants RC[round]
    // ------------------------------------------------------------------
    function [63:0] rc_iota;
        input [4:0] rnd;
        begin
            case (rnd)
                5'd0:  rc_iota = 64'h0000000000000001;
                5'd1:  rc_iota = 64'h0000000000008082;
                5'd2:  rc_iota = 64'h800000000000808A;
                5'd3:  rc_iota = 64'h8000000080008000;
                5'd4:  rc_iota = 64'h000000000000808B;
                5'd5:  rc_iota = 64'h0000000080000001;
                5'd6:  rc_iota = 64'h8000000080008081;
                5'd7:  rc_iota = 64'h8000000000008009;
                5'd8:  rc_iota = 64'h000000000000008A;
                5'd9:  rc_iota = 64'h0000000000000088;
                5'd10: rc_iota = 64'h0000000080008009;
                5'd11: rc_iota = 64'h000000008000000A;
                5'd12: rc_iota = 64'h000000008000808B;
                5'd13: rc_iota = 64'h800000000000008B;
                5'd14: rc_iota = 64'h8000000000008089;
                5'd15: rc_iota = 64'h8000000000008003;
                5'd16: rc_iota = 64'h8000000000008002;
                5'd17: rc_iota = 64'h8000000000000080;
                5'd18: rc_iota = 64'h000000000000800A;
                5'd19: rc_iota = 64'h800000008000000A;
                5'd20: rc_iota = 64'h8000000080008081;
                5'd21: rc_iota = 64'h8000000000008080;
                5'd22: rc_iota = 64'h0000000080000001;
                5'd23: rc_iota = 64'h8000000080008008;
                default: rc_iota = 64'h0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Sequential state
    // ------------------------------------------------------------------
    reg [1599:0] state_r;
    reg [4:0]    round_r;
    reg          busy;

    // ------------------------------------------------------------------
    // Combinational round datapath
    // ------------------------------------------------------------------
    wire [63:0] lane [0:24];
    wire [63:0] col_c [0:4];
    wire [63:0] dtheta [0:4];
    wire [63:0] after_theta [0:24];
    wire [63:0] after_pi [0:24];
    wire [63:0] after_chi [0:24];
    wire [63:0] rc;
    wire [1599:0] next_state;

    genvar gi, gx, gy;

    generate
        // extract lanes from registered state
        for (gi = 0; gi < 25; gi = gi + 1) begin : g_lane
            assign lane[gi] = state_r[gi*64 +: 64];
        end

        // theta: column parity + diffusion
        for (gx = 0; gx < 5; gx = gx + 1) begin : g_theta
            assign col_c[gx] = lane[gx] ^ lane[gx+5] ^ lane[gx+10] ^ lane[gx+15] ^ lane[gx+20];
            assign dtheta[gx] = col_c[(gx+4)%5] ^ {col_c[(gx+1)%5][62:0], col_c[(gx+1)%5][63]};
            for (gy = 0; gy < 5; gy = gy + 1) begin : g_theta_apply
                assign after_theta[gx + 5*gy] = lane[gx + 5*gy] ^ dtheta[gx];
            end
        end

        // rho + pi: rotate each lane, then move to lane (y, (2x+3y) mod 5)
        for (gx = 0; gx < 5; gx = gx + 1) begin : g_pi_x
            for (gy = 0; gy < 5; gy = gy + 1) begin : g_pi_y
                localparam integer DEST = gy + 5*((2*gx + 3*gy) % 5);
                localparam integer ROT  = rho_offset(gx, gy);
                assign after_pi[DEST] = rotl64(after_theta[gx + 5*gy], ROT);
            end
        end

        // chi: nonlinear lane mixing (reads original lanes only)
        for (gx = 0; gx < 5; gx = gx + 1) begin : g_chi_x
            for (gy = 0; gy < 5; gy = gy + 1) begin : g_chi_y
                assign after_chi[gx + 5*gy] = after_pi[gx + 5*gy]
                    ^ (~after_pi[((gx+1)%5) + 5*gy] & after_pi[((gx+2)%5) + 5*gy]);
            end
        end

        // iota + repack to flat state
        assign rc = rc_iota(round_r);
        for (gi = 0; gi < 25; gi = gi + 1) begin : g_out
            assign next_state[gi*64 +: 64] = (gi == 0) ? (after_chi[gi] ^ rc) : after_chi[gi];
        end
    endgenerate

    // ------------------------------------------------------------------
    // Control: one round per cycle, 24 cycles total
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state_r   <= 1600'b0;
            round_r   <= 5'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else if (start) begin
            state_r   <= state_in;
            round_r   <= 5'd0;
            busy      <= 1'b1;
            done      <= 1'b0;
        end else if (busy) begin
            state_r   <= next_state;
            if (round_r == (NUM_ROUNDS - 5'd1)) begin
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                round_r <= round_r + 5'd1;
            end
        end else begin
            done <= 1'b0;
        end
    end

    // state_out is the final permutation result; `state_r` holds it once
    // `done` pulses and does not change afterwards.
    assign state_out = state_r;

    // ------------------------------------------------------------------
    // Formal properties (SymbiYosys)
    // ------------------------------------------------------------------
`ifdef FORMAL
    // constrain the BMC initial state to the reset state (not synthesized)
    initial begin
        busy    = 1'b0;
        done    = 1'b0;
        round_r = 5'd0;
        f_cnt   = 5'd0;
    end

    reg [4:0] f_cnt;
    always @(posedge clk) begin
        if (!rst_n)
            f_cnt <= 5'd0;
        else if (start)
            f_cnt <= 5'd1;
        else if (f_cnt != 5'd0 && f_cnt < 5'd26)
            f_cnt <= f_cnt + 5'd1;
    end

    always @(*) begin
        // done asserts exactly 24 cycles after start
        if (f_cnt == 5'd25)
            assert(done == 1'b1);
        // and never earlier
        if (f_cnt >= 5'd1 && f_cnt <= 5'd24)
            assert(done == 1'b0);
    end
`endif

endmodule

`default_nettype wire
