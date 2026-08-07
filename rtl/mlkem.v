`default_nettype none
`timescale 1ns/1ps

// mlkem.v - ML-KEM-768 keygen controller
//
// MMIO (base 0x1000_0900):
//   0x00 CTRL        [0] op (1=keygen)  [4] go
//   0x04 STATUS      [0] busy [1] done
//   0x08 SEED_D      streaming 32-byte keygen seed d
//   0x0C SEED_Z      streaming 32-byte keygen seed z
//   0x10 EK          streaming public-key byte read (1184 B)
//   0x14 DK          streaming secret-key byte read (2400 B)
//
// Uses keccak c3 (sha3: G/H hashes) and c2 (shake_sampler: polynomials),
// and drives the NTT engine's client port.

module mlkem (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output wire        bus_ack,
    output wire        irq_done,

    output wire        h_req,
    output wire [1599:0] h_state_in,
    input  wire        h_done,
    input  wire [1599:0] h_state_out,

    output wire        s_req,
    output wire [1599:0] s_state_in,
    input  wire        s_done,
    input  wire [1599:0] s_state_out,

    output reg         n_req,
    output reg         n_we,
    output reg  [7:0]  n_addr,
    output reg  [31:0] n_wdata,
    input  wire [31:0] n_rdata,
    input  wire        n_ack
);

    localparam K = 3;

    // ---------------- hash sha3 (G/H) on c3 ----------------
    reg         gh_req, gh_we;
    reg  [7:0]  gh_addr;
    reg  [31:0] gh_wdata;
    wire [31:0] gh_rdata;

    sha3 #(.OUT_MAX(1024), .MSG_MAX(2048)) u_hash (
        .clk(clk), .rst_n(rst_n),
        .bus_req(gh_req), .bus_we(gh_we), .bus_addr(gh_addr),
        .bus_wdata(gh_wdata), .bus_rdata(gh_rdata), .bus_ack(), .irq_done(),
        .perm_req(h_req), .perm_state_in(h_state_in),
        .perm_done(h_done), .perm_state_out(h_state_out)
    );

    // ---------------- shake_sampler (polynomials) on c2 ----------------
    reg        ss_start, ss_mode;
    reg [1:0]  ss_eta;
    reg [255:0] ss_seed;
    reg [7:0]  ss_x0, ss_x1;
    wire [11:0] ss_coeff;
    wire       ss_coeff_valid, ss_done;

    shake_sampler u_samp (
        .clk(clk), .rst_n(rst_n),
        .perm_req(s_req), .perm_state_in(s_state_in),
        .perm_done(s_done), .perm_state_out(s_state_out),
        .start_i(ss_start), .mode_i(ss_mode), .eta_i(ss_eta),
        .seed_i(ss_seed), .x0_i(ss_x0), .x1_i(ss_x1),
        .coeff_o(ss_coeff), .coeff_valid_o(ss_coeff_valid), .done_o(ss_done)
    );

    // ---------------- coefficient memory ----------------
    // A^[i][j]: 0 + (i*3+j)*256     (9 polys)
    // s^[j]:    2304 + j*256         (3 polys)
    // t^[i]:    3072 + i*256         (3 polys; init with e^ then accumulate)
    reg [11:0] cmem [0:3839];
    reg [11:0] cmem_wd;
    reg [12:0] cmem_wa, cmem_ra;
    reg        cmem_we;
    wire [11:0] cmem_rd = cmem[cmem_ra];

    always @(posedge clk) begin
        if (cmem_we)
            cmem[cmem_wa] <= cmem_wd;
    end

    // ---------------- seeds / key buffers ----------------
    reg [255:0] d_buf, z_buf;
    reg [7:0] rho_b [0:31];
    reg [7:0] sigma_b [0:31];
    reg [7:0] g_out [0:63];
    reg [5:0] g_out_idx;
    reg [7:0] ekh_buf [0:31];

    wire [255:0] seed_rho, seed_sigma;
    genvar gr;
    generate
        for (gr = 0; gr < 32; gr = gr + 1) begin : seed_asm
            assign seed_rho[8*gr +: 8]   = rho_b[gr];
            assign seed_sigma[8*gr +: 8] = sigma_b[gr];
        end
    endgenerate

    // ---------------- output byte buffers ----------------
    reg [7:0] ek_buf [0:1183];
    reg [7:0] dk_buf [0:2399];
    reg [11:0] ek_rd, dk_rd;

    // ---------------- hash op context ----------------
    reg        h_msg;       // 0 = d||k (G), 1 = ek (H)
    reg [2:0]  h_mode;
    reg [11:0] h_len;
    reg [9:0]  h_sqlen;
    reg        h_out_ek;    // 1 = output into ekh_buf, 0 = g_out
    reg [31:0] h_word;
    reg [7:0]  h_byte;
    reg [10:0] h_wcnt;      // message word counter
    reg [6:0]  h_ocnt;      // output byte counter

    // ---------------- sampling context ----------------
    reg [12:0] ss_dst;      // cmem write base (A^ region)
    reg        ss_to_ntt;   // route coeffs into NTT instead of cmem
    reg [11:0] ss_cnt;

    // ---------------- NTT op context ----------------
    reg [1:0]  n_op;
    reg [12:0] n_src;       // cmem source base for a-region load
    reg [12:0] n_dst;       // cmem destination base for result
    reg        n_acc;       // accumulate result into cmem[dst+idx]
    reg [9:0]  n_idx;
    reg [11:0] n_old;       // previous t value for accumulate
    reg [1:0]  task_q;      // 1=s^ fwd, 2=e^ fwd, 3=matrix basemul

    // ---------------- encode context ----------------
    reg [12:0] enc_base;
    reg        enc_dst;     // 0 = ek_buf, 1 = dk_buf
    reg [11:0] enc_off;
    reg [7:0]  enc_cnt;     // pair counter 0..127
    reg [11:0] enc_c0;
    reg [23:0] enc_acc;
    reg [10:0] cp_cnt;      // copy counter (1184 bytes)

    // ---------------- main FSM ----------------
    localparam [5:0] S_IDLE     = 6'd0;
    localparam [5:0] S_H_CFG    = 6'd1;  // write mode
    localparam [5:0] S_H_CFG2   = 6'd2;  // write len
    localparam [5:0] S_H_CFG3   = 6'd3;  // write sqlen
    localparam [5:0] S_H_MSG    = 6'd4;  // stream message words
    localparam [5:0] S_H_ABSGO  = 6'd5;
    localparam [5:0] S_H_ABS    = 6'd6;  // start absorb
    localparam [5:0] S_H_ABSW   = 6'd6;  // poll absorb
    localparam [5:0] S_H_SQ     = 6'd8;  // start squeeze
    localparam [5:0] S_H_SQW    = 6'd9;  // poll squeeze
    localparam [5:0] S_H_RD     = 6'd10;  // read output word
    localparam [5:0] S_H_ST     = 6'd11; // store output bytes
    localparam [5:0] S_AG       = 6'd12; // A^ gen setup
    localparam [5:0] S_AGN      = 6'd13; // next A^ poly
    localparam [5:0] S_SAMP     = 6'd14; // run sampler
    localparam [5:0] S_SAMPD    = 6'd15; // sampler finished
    localparam [5:0] S_SG       = 6'd16; // s^ gen setup
    localparam [5:0] S_SGN      = 6'd17;
    localparam [5:0] S_EG       = 6'd18; // e^ gen setup
    localparam [5:0] S_EGN      = 6'd19;
    localparam [5:0] S_TSTART   = 6'd20; // basemul: reset NTT, load a
    localparam [5:0] S_TA       = 6'd21; // load a from cmem
    localparam [5:0] S_TB       = 6'd22; // load b from cmem
    localparam [5:0] S_NGO      = 6'd23; // CTRL go
    localparam [5:0] S_NW       = 6'd24; // poll done
    localparam [5:0] S_NR       = 6'd25; // read result to cmem
    localparam [5:0] S_NR2      = 6'd26;
    localparam [5:0] S_TE       = 6'd27; // matrix loop end
    localparam [5:0] S_ENC      = 6'd28; // encode one poly
    localparam [5:0] S_ENC1     = 6'd29;
    localparam [5:0] S_ENC2     = 6'd30;
    localparam [5:0] S_ENC3     = 6'd31; // poly end
    localparam [5:0] S_ERHO     = 6'd32; // copy rho into ek
    localparam [5:0] S_ERHO_W   = 6'd33;
    localparam [5:0] S_ENCS     = 6'd34; // encode s^ into dk
    localparam [5:0] S_ENCS2    = 6'd35;
    localparam [5:0] S_ECP      = 6'd36; // copy ek into dk
    localparam [5:0] S_ECP_W    = 6'd37;
    localparam [5:0] S_H2       = 6'd38; // H(ek)
    localparam [5:0] S_EZ       = 6'd39; // copy z into dk
    localparam [5:0] S_EZ_W     = 6'd40;
    localparam [5:0] S_SG_END   = 6'd42;
    localparam [5:0] S_EG_END   = 6'd43;
    localparam [5:0] S_TA_NEXT  = 6'd44;
    localparam [5:0] S_ENC_NEXT = 6'd45;
    localparam [5:0] S_ENC_S    = 6'd46;
    localparam [5:0] S_H_RD2    = 6'd48;
    localparam [5:0] S_H_CAP    = 6'd49;
    localparam [5:0] S_NR3      = 6'd51;
    localparam [5:0] S_EKH_W    = 6'd53;
    localparam [5:0] S_GSPLIT   = 6'd55;
    localparam [5:0] S_DONE     = 6'd56;

    reg [5:0]  st;
    reg [7:0]  i, j;
    reg        busy_q, done_q;
    reg        abs_started;
    reg        poll_setup;
    reg        nw_busy;
    reg        go_r;
    reg [4:0]  op_in;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; i <= 8'd0; j <= 8'd0;
            busy_q <= 1'b0; done_q <= 1'b0; abs_started <= 1'b0; poll_setup <= 1'b0; nw_busy <= 1'b0;
            h_msg <= 1'b0; h_mode <= 3'd0; h_len <= 12'd0; h_sqlen <= 12'd0;
            h_out_ek <= 1'b0; h_word <= 32'h0; h_byte <= 8'd0; h_wcnt <= 11'd0; h_ocnt <= 7'd0;
            ss_dst <= 13'd0; ss_to_ntt <= 1'b0; ss_cnt <= 12'd0;
            ss_start <= 1'b0; ss_mode <= 1'b0; ss_eta <= 2'd0;
            ss_seed <= 256'h0; ss_x0 <= 8'h0; ss_x1 <= 8'h0;
            n_op <= 2'd0; n_src <= 13'd0; n_dst <= 13'd0; n_acc <= 1'b0;
            n_idx <= 10'd0; n_old <= 12'd0; task_q <= 2'd0;
            n_req <= 1'b0; n_we <= 1'b0; n_addr <= 8'h0; n_wdata <= 32'h0;
            enc_base <= 13'd0; enc_dst <= 1'b0; enc_off <= 12'd0; enc_cnt <= 8'd0;
            enc_c0 <= 12'd0; enc_acc <= 24'h0; cp_cnt <= 11'd0;
            cmem_we <= 1'b0; cmem_wa <= 13'd0; cmem_wd <= 12'd0; cmem_ra <= 13'd0;
            gh_req <= 1'b0; gh_we <= 1'b0; gh_addr <= 8'h0; gh_wdata <= 32'h0;
            ek_rd <= 12'd0; dk_rd <= 12'd0;
        end else begin
            cmem_we <= 1'b0;
            n_req <= 1'b0;
            ss_start <= 1'b0;
            done_q <= 1'b0;
            gh_req <= 1'b0;

            case (st)
                // ----------------------------------------------------------
                S_IDLE: begin
                    if (go_r && op_in == 5'd1) begin
                        busy_q <= 1'b1;
                        h_msg <= 1'b0; h_mode <= 3'd1; h_len <= 12'd33; h_sqlen <= 12'd64;
                        h_out_ek <= 1'b0; h_wcnt <= 11'd0; h_ocnt <= 7'd0; h_byte <= 8'd0;
                        st <= S_H_CFG;
                    end
                end

                // ---- hash: write mode / len / sqlen ----
                S_H_CFG:  begin gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h08; gh_wdata <= {29'b0, h_mode}; st <= S_H_CFG2; end
                S_H_CFG2: begin gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h14; gh_wdata <= {22'b0, h_len};  st <= S_H_CFG3; end
                S_H_CFG3: begin gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h18; gh_wdata <= {22'b0, h_sqlen}; h_wcnt <= 11'd0; st <= S_H_MSG; end

                // ---- hash: stream message words ----
                S_H_MSG: begin
                    if (h_msg) begin
                        gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h0C;
                        gh_wdata <= {ek_buf[4*h_wcnt+3], ek_buf[4*h_wcnt+2], ek_buf[4*h_wcnt+1], ek_buf[4*h_wcnt]};
                    end else begin
                        case (h_wcnt[3:0])
                            4'd0: gh_wdata <= d_buf[31:0];
                            4'd1: gh_wdata <= d_buf[63:32];
                            4'd2: gh_wdata <= d_buf[95:64];
                            4'd3: gh_wdata <= d_buf[127:96];
                            4'd4: gh_wdata <= d_buf[159:128];
                            4'd5: gh_wdata <= d_buf[191:160];
                            4'd6: gh_wdata <= d_buf[223:192];
                            4'd7: gh_wdata <= d_buf[255:224];
                            default: gh_wdata <= 32'h3;  // byte 32 = k
                        endcase
                        gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h0C;
                    end
                    if (h_wcnt >= (h_msg ? 11'd295 : 11'd8)) begin
                        st <= S_H_ABSGO;
                    end else begin
                        h_wcnt <= h_wcnt + 11'd1;
                    end
                end

                // ---- hash: absorb ----
                S_H_ABSGO: begin
                    gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h00; gh_wdata <= 32'h1;
                    h_ocnt <= 7'd0;
                    abs_started <= 1'b0;
                    poll_setup <= 1'b0;
                    st <= S_H_ABS;
                end

                S_H_ABS: begin
                    gh_req <= 1'b1; gh_we <= 1'b0; gh_addr <= 8'h04;
                    if (!poll_setup) begin
                        // skip the stale STATUS-read cycle (address was CTRL in S_H_ABSGO)
                        poll_setup <= 1'b1;
                    end else if (!abs_started) begin
                        // wait for absorb_done to go low (new absorb actually running)
                        if (!gh_rdata[1]) abs_started <= 1'b1;
                    end else begin
                        // wait for absorb to complete (ready && absorb_done)
                        if (gh_rdata[1:0] == 2'b11) begin
                            gh_req <= 1'b1; gh_we <= 1'b1; gh_addr <= 8'h00; gh_wdata <= 32'h2;
                            h_ocnt <= 7'd0;
                            st <= S_H_SQ;
                        end
                    end
                end

                // ---- hash: squeeze ----
                S_H_SQ: begin
                    gh_req <= 1'b1; gh_we <= 1'b0; gh_addr <= 8'h04;
                    if (gh_rdata[2]) begin
                        st <= S_H_RD;
                    end
                end

                S_H_RD: begin
                    gh_req <= 1'b1; gh_we <= 1'b0; gh_addr <= 8'h10;
                    st <= S_H_RD2;
                end

                S_H_RD2: begin
                    st <= S_H_CAP;
                end

                S_H_CAP: begin
                    h_word <= gh_rdata;
                    h_byte <= 8'd0;
                    st <= S_H_ST;
                end

                // ---- hash: store output bytes ----
                S_H_ST: begin
                    if (h_out_ek) begin
                        case (h_byte)
                            8'd0: ekh_buf[h_ocnt*4 + 8'd0] <= h_word[7:0];
                            8'd1: ekh_buf[h_ocnt*4 + 8'd1] <= h_word[15:8];
                            8'd2: ekh_buf[h_ocnt*4 + 8'd2] <= h_word[23:16];
                            default: ekh_buf[h_ocnt*4 + 8'd3] <= h_word[31:24];
                        endcase
                    end else begin
                        case (h_byte)
                            8'd0: g_out[h_ocnt*4 + 8'd0] <= h_word[7:0];
                            8'd1: g_out[h_ocnt*4 + 8'd1] <= h_word[15:8];
                            8'd2: g_out[h_ocnt*4 + 8'd2] <= h_word[23:16];
                            default: g_out[h_ocnt*4 + 8'd3] <= h_word[31:24];
                        endcase
                    end
                    h_byte <= h_byte + 8'd1;
                    if (h_byte == 8'd3) begin
                        if (h_ocnt == (h_sqlen[7:0] >> 2) - 7'd1) begin
                            if (h_msg) begin
                                // H(ek) done -> dk tail: ekh || z
                                cp_cnt <= 11'd0;
                                st <= S_EKH_W;
                            end else begin
                                // G done -> split g_out into rho/sigma (next cycle)
                                st <= S_GSPLIT;
                            end
                        end else begin
                            h_ocnt <= h_ocnt + 7'd1;
                            st <= S_H_RD;
                        end
                    end
                end

                S_GSPLIT: begin
                    for (j = 0; j < 8; j = j + 1) begin
                        rho_b[4*j]   <= g_out[4*j];
                        rho_b[4*j+1] <= g_out[4*j+1];
                        rho_b[4*j+2] <= g_out[4*j+2];
                        rho_b[4*j+3] <= g_out[4*j+3];
                        sigma_b[4*j]   <= g_out[32+4*j];
                        sigma_b[4*j+1] <= g_out[32+4*j+1];
                        sigma_b[4*j+2] <= g_out[32+4*j+2];
                        sigma_b[4*j+3] <= g_out[32+4*j+3];
                    end
                    st <= S_AG;
                end

                // ----------------------------------------------------------
                // A^ generation: A^[i][j] = SampleNTT(rho, j, i)  (9 polys -> cmem)
                // ----------------------------------------------------------
                S_AG: begin
                    i <= 8'd0; j <= 8'd0;
                    ss_mode <= 1'b0; ss_seed <= seed_rho; ss_to_ntt <= 1'b0;
                    st <= S_AGN;
                end

                S_AGN: begin
                    ss_dst <= (i*3 + j) * 10'd256;
                    ss_x0 <= j; ss_x1 <= i;
                    ss_cnt <= 12'd0;
                    ss_start <= 1'b1;
                    st <= S_SAMP;
                end

                // ---- sampler run: route coeffs ----
                S_SAMP: begin
                    if (ss_coeff_valid) begin
                        if (ss_to_ntt) begin
                            n_req <= 1'b1; n_we <= 1'b1; n_addr <= 8'h08; n_wdata <= ss_coeff;
                        end else begin
                            cmem_we <= 1'b1; cmem_wa <= ss_dst + ss_cnt; cmem_wd <= ss_coeff;
                        end
                        ss_cnt <= ss_cnt + 12'd1;
                    end
                    if (ss_done) st <= S_SAMPD;
                end

                S_SAMPD: begin
                    if (ss_cnt >= 12'd256) begin
                        if (ss_to_ntt) begin
                            // NTT already loaded (a-region); run the op
                            st <= S_NGO;
                        end else begin
                            // A^ poly stored to cmem; advance
                            if (j == 8'd2) begin
                                if (i == 8'd2) st <= S_SG;
                                else begin i <= i + 8'd1; j <= 8'd0; st <= S_AGN; end
                            end else begin
                                j <= j + 8'd1;
                                st <= S_AGN;
                            end
                        end
                    end
                end

                // ----------------------------------------------------------
                // s^ generation: s^[j] = NTT(CBD(sigma, j))  (3 polys)
                // ----------------------------------------------------------
                S_SG: begin
                    j <= 8'd0;
                    ss_mode <= 1'b1; ss_eta <= 2'd2; ss_seed <= seed_sigma;
                    ss_to_ntt <= 1'b1;
                    n_op <= 2'd1; n_acc <= 1'b0; task_q <= 2'd1;
                    st <= S_SGN;
                end

                S_SGN: begin
                    ss_x0 <= j;
                    ss_cnt <= 12'd0;
                    n_dst <= 12'd2304 + j*10'd256;
                    n_addr <= 8'h00; n_wdata <= {29'b0, n_op}; n_req <= 1'b1; n_we <= 1'b1;  // reset wr_ptr
                    ss_start <= 1'b1;
                    st <= S_SAMP;
                end

                S_SG_END: begin
                    if (j == 8'd2) st <= S_EG;
                    else begin j <= j + 8'd1; st <= S_SGN; end
                end

                // ----------------------------------------------------------
                // e^ generation: e^[j] = NTT(CBD(sigma, k+j)); t^[j] = e^[j]
                // ----------------------------------------------------------
                S_EG: begin
                    j <= 8'd0;
                    n_dst <= 13'd3072;
                    st <= S_EGN;
                end

                S_EGN: begin
                    ss_x0 <= K + j;
                    ss_cnt <= 12'd0;
                    n_op <= 2'd1; n_acc <= 1'b0; task_q <= 2'd2;
                    n_dst <= 13'd3072 + j*10'd256;
                    n_addr <= 8'h00; n_wdata <= {29'b0, n_op}; n_req <= 1'b1; n_we <= 1'b1;  // reset wr_ptr
                    ss_start <= 1'b1;
                    st <= S_SAMP;
                end

                S_EG_END: begin
                    if (j == 8'd2) st <= S_TSTART;
                    else begin j <= j + 8'd1; st <= S_EGN; end
                end

                // ----------------------------------------------------------
                // matrix product: t^[i] = sum_j A^[i][j] o s^[j] + e^[i]
                // ----------------------------------------------------------
                S_TSTART: begin
                    i <= 8'd0; j <= 8'd0;
                    n_op <= 2'd3; task_q <= 2'd3;
                    st <= S_TA_NEXT;
                end

                S_TA_NEXT: begin
                    // reset NTT pointers and load a-region from cmem A^[i][j]
                    n_addr <= 8'h00; n_wdata <= {29'b0, n_op}; n_req <= 1'b1;
                    n_src <= (i*3 + j) * 10'd256;
                    n_idx <= 10'd0;
                    cmem_ra <= (i*3 + j) * 10'd256;   // pre-read A^[i][j][0]
                    st <= S_TA;
                end

                S_TA: begin
                    n_req <= 1'b1; n_we <= 1'b1; n_addr <= 8'h08; n_wdata <= cmem_rd;
                    cmem_ra <= n_src + n_idx + 10'd1;
                    if (n_idx >= 10'd255) begin
                        n_idx <= 10'd0;
                        cmem_ra <= 12'd2304 + j*10'd256;   // pre-read s^[j][0]
                        st <= S_TB;
                    end else begin
                        n_idx <= n_idx + 10'd1;
                    end
                end

                S_TB: begin
                    n_req <= 1'b1; n_we <= 1'b1; n_addr <= 8'h08; n_wdata <= cmem_rd;
                    cmem_ra <= 12'd2304 + j*10'd256 + n_idx + 10'd1;
                    if (n_idx >= 10'd255) begin
                        n_dst <= 13'd3072 + i*10'd256;
                        n_acc <= 1'b1;
                        st <= S_NGO;
                    end else begin
                        n_idx <= n_idx + 10'd1;
                    end
                end

                // ---- NTT op: CTRL go, wait done, read result ----
                S_NGO: begin
                    n_addr <= 8'h00; n_wdata <= 32'h10 | {29'b0, n_op}; n_req <= 1'b1;
                    n_idx <= 10'd0;
                    nw_busy <= 1'b0;
                    st <= S_NW;
                end

                S_NW: begin
                    n_addr <= 8'h04; n_req <= 1'b1; n_we <= 1'b0;
                    if (!nw_busy) begin
                        // wait for the op to actually start (busy high)
                        if (n_rdata[0]) nw_busy <= 1'b1;
                    end else if (n_rdata[1]) begin
                        cmem_ra <= n_dst;
                        st <= S_NR;
                    end
                end

                S_NR: begin
                    // issue read for coeff n_idx (data valid two cycles later)
                    n_addr <= 8'h08; n_req <= 1'b1; n_we <= 1'b0;
                    n_old <= cmem_rd;   // capture old t (accumulate case)
                    st <= S_NR2;
                end

                S_NR2: begin
                    // the NTT latches rd_data_q at this cycle; wait for it
                    st <= S_NR3;
                end

                S_NR3: begin
                    // n_rdata now holds coeff n_idx; old t was captured in S_NR
                    if (n_acc) begin
                        cmem_wa <= n_dst + n_idx;
                        cmem_wd <= (n_old + n_rdata >= 12'd3329) ? (n_old + n_rdata - 12'd3329) : (n_old + n_rdata);
                    end else begin
                        cmem_wa <= n_dst + n_idx;
                        cmem_wd <= n_rdata;
                    end
                    cmem_we <= 1'b1;
                    if (n_idx >= 10'd255) begin
                        if (task_q == 2'd1) st <= S_SG_END;
                        else if (task_q == 2'd2) st <= S_EG_END;
                        else st <= S_TE;
                    end else begin
                        n_idx <= n_idx + 10'd1;
                        cmem_ra <= n_dst + n_idx + 10'd1;
                        st <= S_NR;
                    end
                end

                S_TE: begin
                    if (j == 8'd2) begin
                        if (i == 8'd2) st <= S_ENC;
                        else begin i <= i + 8'd1; j <= 8'd0; st <= S_TA_NEXT; end
                    end else begin
                        j <= j + 8'd1;
                        st <= S_TA_NEXT;
                    end
                end

                // ----------------------------------------------------------
                // byte-encode: 2 coeffs (24 bits) -> 3 bytes
                // ----------------------------------------------------------
                S_ENC: begin
                    // encode t^[j] into ek_buf (j = 0..2)
                    j <= 8'd0;
                    st <= S_ENC_NEXT;
                end

                S_ENC_NEXT: begin
                    enc_base <= 13'd3072 + j*10'd256;
                    enc_dst <= 1'b0;
                    enc_off <= j * 12'd384;
                    enc_cnt <= 8'd0;
                    cmem_ra <= 13'd3072 + j*10'd256;
                    st <= S_ENC1;
                end

                S_ENC1: begin
                    enc_c0 <= cmem_rd;
                    cmem_ra <= enc_base + (enc_cnt*2 + 8'd1);
                    st <= S_ENC2;
                end

                S_ENC2: begin
                    enc_acc <= {cmem_rd, 12'd0} | {12'd0, enc_c0};
                    st <= S_ENC3;
                end

                S_ENC3: begin
                    if (enc_dst == 1'b0) begin
                        ek_buf[enc_off] <= enc_acc[7:0];
                        ek_buf[enc_off+1] <= enc_acc[15:8];
                        ek_buf[enc_off+2] <= enc_acc[23:16];
                    end else begin
                        dk_buf[enc_off] <= enc_acc[7:0];
                        dk_buf[enc_off+1] <= enc_acc[15:8];
                        dk_buf[enc_off+2] <= enc_acc[23:16];
                    end
                    if (enc_cnt == 8'd127) begin
                        if (enc_dst == 1'b0) begin
                            if (j == 8'd2) st <= S_ERHO;
                            else begin j <= j + 8'd1; st <= S_ENC_NEXT; end
                        end else begin
                            if (j == 8'd2) st <= S_ECP;
                            else begin j <= j + 8'd1; st <= S_ENC_S; end
                        end
                    end else begin
                        enc_cnt <= enc_cnt + 8'd1;
                        enc_off <= enc_off + 12'd3;
                        cmem_ra <= enc_base + ((enc_cnt+8'd1)*2);
                        st <= S_ENC1;
                    end
                end

                // ---- copy rho into ek_buf[1152:1183] ----
                S_ERHO: begin
                    cp_cnt <= 11'd0;
                    st <= S_ERHO_W;
                end

                S_ERHO_W: begin
                    ek_buf[1152 + cp_cnt] <= rho_b[cp_cnt];
                    if (cp_cnt == 11'd31) st <= S_ENCS;
                    else cp_cnt <= cp_cnt + 11'd1;
                end

                // ---- encode s^[j] into dk_buf ----
                S_ENCS: begin
                    j <= 8'd0;
                    st <= S_ENC_S;
                end

                S_ENC_S: begin
                    enc_base <= 12'd2304 + j*10'd256;
                    enc_dst <= 1'b1;
                    enc_off <= j * 12'd384;
                    enc_cnt <= 8'd0;
                    cmem_ra <= 12'd2304 + j*10'd256;
                    st <= S_ENC1;
                end

                // ---- copy ek into dk_buf[1152:2335] ----
                S_ECP: begin
                    cp_cnt <= 11'd0;
                    st <= S_ECP_W;
                end

                S_ECP_W: begin
                    dk_buf[1152 + cp_cnt] <= ek_buf[cp_cnt];
                    if (cp_cnt == 11'd1183) begin
                        // H(ek) = SHA3-256 -> ekh_buf (32 B)
                        h_msg <= 1'b1; h_mode <= 3'd0; h_len <= 12'd1184; h_sqlen <= 12'd32;
                        h_out_ek <= 1'b1; h_wcnt <= 11'd0; h_ocnt <= 7'd0; h_byte <= 8'd0;
                        st <= S_H_CFG;
                    end else begin
                        cp_cnt <= cp_cnt + 11'd1;
                    end
                end

                // ---- copy ekh_buf[0:31] into dk_buf[2336:2367] ----
                S_EKH_W: begin
                    dk_buf[2336 + cp_cnt] <= ekh_buf[cp_cnt];
                    if (cp_cnt == 11'd31) st <= S_EZ;
                    else cp_cnt <= cp_cnt + 11'd1;
                end

                // ---- copy z into dk_buf[2368:2399] ----
                S_EZ: begin
                    cp_cnt <= 11'd0;
                    st <= S_EZ_W;
                end

                S_EZ_W: begin
                    dk_buf[2368 + cp_cnt] <= z_buf[8*cp_cnt +: 8];
                    if (cp_cnt == 11'd31) st <= S_DONE;
                    else cp_cnt <= cp_cnt + 11'd1;
                end

                S_DONE: begin
                    busy_q <= 1'b0;
                    done_q <= 1'b1;
                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // ---------------- MMIO / streaming ports ----------------
    reg [4:0]  sd_wr, sz_wr;

    always @(posedge clk) begin
        if (!rst_n) begin
            go_r <= 1'b0; op_in <= 5'd0; sd_wr <= 5'd0; sz_wr <= 5'd0;
            ek_rd <= 12'd0; dk_rd <= 12'd0;
        end else begin
            go_r <= 1'b0;
            if (bus_req && bus_we) begin
                case (bus_addr[7:0])
                    8'h00: begin op_in <= bus_wdata[2:0]; go_r <= bus_wdata[4]; end
                endcase
            end
            if (bus_req && bus_we && bus_addr == 8'h08) begin
                case (sd_wr)
                    5'd0: d_buf[31:0] <= bus_wdata;
                    5'd1: d_buf[63:32] <= bus_wdata;
                    5'd2: d_buf[95:64] <= bus_wdata;
                    5'd3: d_buf[127:96] <= bus_wdata;
                    5'd4: d_buf[159:128] <= bus_wdata;
                    5'd5: d_buf[191:160] <= bus_wdata;
                    5'd6: d_buf[223:192] <= bus_wdata;
                    5'd7: d_buf[255:224] <= bus_wdata;
                endcase
                sd_wr <= sd_wr + 5'd1;
            end
            if (bus_req && bus_we && bus_addr == 8'h0C) begin
                case (sz_wr)
                    5'd0: z_buf[31:0] <= bus_wdata;
                    5'd1: z_buf[63:32] <= bus_wdata;
                    5'd2: z_buf[95:64] <= bus_wdata;
                    5'd3: z_buf[127:96] <= bus_wdata;
                    5'd4: z_buf[159:128] <= bus_wdata;
                    5'd5: z_buf[191:160] <= bus_wdata;
                    5'd6: z_buf[223:192] <= bus_wdata;
                    5'd7: z_buf[255:224] <= bus_wdata;
                endcase
                sz_wr <= sz_wr + 5'd1;
            end
            if (bus_req && !bus_we && bus_addr == 8'h10) ek_rd <= ek_rd + 12'd1;
            if (bus_req && !bus_we && bus_addr == 8'h14) dk_rd <= dk_rd + 12'd1;
        end
    end

    always @(*) begin
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h04: bus_rdata = {30'b0, done_q, busy_q};
            8'h10: bus_rdata = {24'b0, ek_buf[ek_rd]};
            8'h14: bus_rdata = {24'b0, dk_buf[dk_rd]};
            default: bus_rdata = 32'h0;
        endcase
    end

    assign bus_ack  = bus_req;
    assign irq_done = done_q;

endmodule

`default_nettype wire
