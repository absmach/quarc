`default_nettype none
`timescale 1ns/1ps

// shake_sampler.v - ML-KEM polynomial generation: SHAKE -> SampleNTT / CBD
//
// Generates one polynomial from a 32-byte seed:
//   mode 0 (XOF): SHAKE128(seed || x0 || x1) -> SampleNTT (256 NTT-domain coeffs)
//   mode 1 (PRF): SHAKE256(seed || x0)       -> CBD(eta)  (256 coeffs)
// Uses the keccak engine client 2 and the sampling datapath. Emits 256
// coefficients then pulses done_o.

module shake_sampler (
    input  wire        clk,
    input  wire        rst_n,

    output wire        perm_req,
    output wire [1599:0] perm_state_in,
    input  wire        perm_done,
    input  wire [1599:0] perm_state_out,

    input  wire        start_i,
    input  wire        mode_i,        // 0 = XOF, 1 = PRF
    input  wire [1:0]  eta_i,         // CBD eta (PRF mode)
    input  wire [255:0] seed_i,
    input  wire [7:0]  x0_i,
    input  wire [7:0]  x1_i,

    output wire [11:0] coeff_o,
    output wire        coeff_valid_o,
    output reg         done_o
);

    // ---------------- sha3 wrapper (SHAKE/SHA3 core on client 2) ----------------
    reg         s_req, s_we;
    reg [7:0]   s_addr;
    reg [31:0]  s_wdata;
    wire [31:0] s_rdata;
    wire        s_done;

    sha3 #(.OUT_MAX(1024)) u_sha3 (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_req   (s_req),
        .bus_we    (s_we),
        .bus_addr  (s_addr),
        .bus_wdata (s_wdata),
        .bus_rdata (s_rdata),
        .bus_ack   (),
        .irq_done  (s_done),
        .perm_req      (perm_req),
        .perm_state_in (perm_state_in),
        .perm_done     (perm_done),
        .perm_state_out(perm_state_out)
    );

    // ---------------- sampling datapath ----------------
    reg         samp_start, samp_mode;
    reg [7:0]   samp_byte;
    reg         byte_pending;     // a byte is being offered, not yet consumed
    wire        samp_byte_valid = byte_pending;
    reg         samp_done_q;
    reg         absorb_started;   // absorb_done went low (absorb actually running)
    reg         poll_setup;       // skip the first STATUS-read cycle (stale rdata)
    wire        samp_byte_ready;
    wire [11:0] samp_coeff;
    wire        samp_coeff_valid, samp_done;

    sampling u_samp (
        .clk(clk), .rst_n(rst_n),
        .start_i(samp_start), .mode_i(samp_mode), .eta_i(eta_i),
        .byte_i(samp_byte), .byte_valid_i(samp_byte_valid), .byte_ready_o(samp_byte_ready),
        .coeff_o(samp_coeff), .coeff_valid_o(samp_coeff_valid), .done_o(samp_done)
    );

    assign coeff_o       = samp_coeff;
    assign coeff_valid_o = samp_coeff_valid;

    // ---------------- control FSM ----------------
    localparam [3:0] S_IDLE     = 4'd0;
    localparam [3:0] S_WR_REG   = 4'd1;
    localparam [3:0] S_WR_MSG   = 4'd2;
    localparam [3:0] S_ABS_GO   = 4'd3;
    localparam [3:0] S_ABS_POLL = 4'd4;
    localparam [3:0] S_SQ_GO    = 4'd5;
    localparam [3:0] S_SQ_POLL  = 4'd6;
    localparam [3:0] S_RD_GO    = 4'd7;
    localparam [3:0] S_RD_CAP   = 4'd8;
    localparam [3:0] S_RD_DATA  = 4'd9;
    localparam [3:0] S_FEED     = 4'd10;
    localparam [3:0] S_DONE     = 4'd12;

    reg [3:0]  st;
    reg [3:0]  sub;
    reg [1:0]  sq_go;
    reg [31:0] msgw [0:8];       // 9 message words (little-endian)
    reg [10:0] sqlen;            // squeeze byte count
    reg [11:0] sq_words;         // words to read (sqlen/4)
    reg [11:0] word_cnt;
    reg [1:0]  byt;
    reg [31:0] cur_word;
    reg [31:0] st_rdata;         // captured sha3 read data


    wire [31:0] seed_w [0:7];
    assign seed_w[0] = seed_i[31:0];
    assign seed_w[1] = seed_i[63:32];
    assign seed_w[2] = seed_i[95:64];
    assign seed_w[3] = seed_i[127:96];
    assign seed_w[4] = seed_i[159:128];
    assign seed_w[5] = seed_i[191:160];
    assign seed_w[6] = seed_i[223:192];
    assign seed_w[7] = seed_i[255:224];

    always @(posedge clk) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            sub           <= 4'd0;
            sq_go         <= 2'd0;
            absorb_started <= 1'b0;
            poll_setup     <= 1'b0;
            word_cnt      <= 12'd0;
            byt           <= 2'd0;
            cur_word      <= 32'h0;
            st_rdata      <= 32'h0;
            done_o        <= 1'b0;
            samp_done_q   <= 1'b0;
            s_req         <= 1'b0;
            s_we          <= 1'b0;
            samp_start     <= 1'b0;
            samp_mode      <= 1'b0;
        end else begin
            s_req         <= 1'b0;
            s_we          <= 1'b0;
            done_o        <= 1'b0;
            samp_start     <= 1'b0;
            byte_pending   <= 1'b0;
            if (samp_done) samp_done_q <= 1'b1;

            case (st)
                S_IDLE: begin
                    if (start_i) begin
                        for (sub = 0; sub < 8; sub = sub + 1) msgw[sub] <= seed_w[sub];
                        if (mode_i) begin
                            msgw[8] <= {24'h0, x0_i};
                            sqlen   <= {3'b0, eta_i, 6'd0};      // 64*eta
                        end else begin
                            msgw[8] <= {16'h0, x1_i, x0_i};
                            sqlen   <= 11'd840;
                        end
                        samp_mode <= mode_i;
                        samp_start <= 1'b1;
                        sub       <= 4'd0;
                        st        <= S_WR_REG;
                    end
                end

                S_WR_REG: begin
                    case (sub)
                        4'd0: begin s_req <= 1'b1; s_we <= 1'b1; s_addr <= 8'h08; s_wdata <= mode_i ? 32'd3 : 32'd2; end
                        4'd1: begin s_req <= 1'b1; s_we <= 1'b1; s_addr <= 8'h14; s_wdata <= mode_i ? 32'd33 : 32'd34; end
                        4'd2: begin s_req <= 1'b1; s_we <= 1'b1; s_addr <= 8'h18; s_wdata <= {21'b0, sqlen}; end
                    endcase
                    sub <= sub + 4'd1;
                    if (sub == 4'd3) begin
                        sub      <= 4'd0;
                        sq_words <= (sqlen >> 2) + 11'd0;
                        st       <= S_WR_MSG;
                    end
                end

                S_WR_MSG: begin
                    s_req  <= 1'b1;
                    s_we   <= 1'b1;
                    s_addr <= 8'h0C;
                    s_wdata <= msgw[sub];
                    sub <= sub + 4'd1;
                    if (sub == 4'd8) begin
                        sub <= 4'd0;
                        st  <= S_ABS_GO;
                    end
                end

                S_ABS_GO: begin
                    s_req <= 1'b1; s_we <= 1'b1; s_addr <= 8'h00; s_wdata <= 32'h1;
                    absorb_started <= 1'b0;
                    poll_setup     <= 1'b0;
                    st <= S_ABS_POLL;
                end

                S_ABS_POLL: begin
                    s_req <= 1'b1; s_we <= 1'b0; s_addr <= 8'h04;
                    if (!poll_setup) begin
                        poll_setup <= 1'b1;     // skip the stale-read cycle
                    end else begin
                        // absorb_done must first go low (new absorb running),
                        // then high (completed) with the sha3 back in IDLE
                        if (!s_rdata[1]) absorb_started <= 1'b1;
                        if (absorb_started && s_rdata[1:0] == 2'b11) st <= S_SQ_GO;
                    end
                end

                S_SQ_GO: begin
                    // hold squeeze_start for two cycles so the sha3 catches it
                    s_req <= 1'b1; s_we <= 1'b1; s_addr <= 8'h00; s_wdata <= 32'h2;
                    if (sq_go == 2'd1) begin
                        sq_go <= 2'd0;
                        st    <= S_SQ_POLL;
                    end else begin
                        sq_go <= sq_go + 2'd1;
                    end
                end

                S_SQ_POLL: begin
                    s_req <= 1'b1; s_we <= 1'b0; s_addr <= 8'h04;
                    if (s_rdata[2]) begin
                        word_cnt <= 12'd0;
                        byt      <= 2'd0;
                        st       <= S_RD_GO;
                    end
                end

                S_RD_GO: begin
                    if (samp_done) st <= S_DONE;
                    else begin
                        s_req <= 1'b1; s_we <= 1'b0; s_addr <= 8'h10;
                        st <= S_RD_CAP;
                    end
                end

                S_RD_CAP: begin
                    // the sha3 latches out_wrd_q at this posedge; capture next
                    if (samp_done) st <= S_DONE;
                    else st <= S_RD_DATA;
                end

                S_RD_DATA: begin
                    // out_wrd_q now holds the word; capture it
                    if (samp_done) st <= S_DONE;
                    else begin
                        cur_word <= s_rdata;
                        byt      <= 2'd0;
                        st       <= S_FEED;
                    end
                end

                S_FEED: begin
                    if (samp_done) begin
                        st <= S_DONE;
                    end else if (byte_pending) begin
                        // byte is valid; consume it when the sampler is ready
                        if (samp_byte_ready) begin
                            byte_pending <= 1'b0;
                            if (byt == 2'd3) begin
                                word_cnt <= word_cnt + 12'd1;
                                byt       <= 2'd0;
                                if (word_cnt == sq_words - 12'd1) st <= S_DONE;
                                else st <= S_RD_GO;
                            end else begin
                                byt <= byt + 2'd1;
                            end
                        end
                    end else begin
                        // present the next byte
                        samp_byte <= cur_word[byt*8 +: 8];
                        byte_pending <= 1'b1;
                    end
                end

                S_DONE: begin
                    // wait for the sampling module to finish
                    if (samp_done_q || samp_done) begin
                        samp_done_q <= 1'b0;
                        done_o <= 1'b1;
                        st     <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
