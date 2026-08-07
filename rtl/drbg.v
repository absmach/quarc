// drbg.v - SHAKE-256 deterministic random bit generator
//
// Custom SP 800-90A-style construction built on the SHAKE-256 sponge:
//   state  S : 256 bits (32 bytes)
//   shake  B : first 136 bytes of SHAKE-256(X)
//   GENERATE(n) : out = B(S)[0:n];  S = B(S)[32:64];  reseed_cnt++
//   RESEED(entropy): S = B(S ^ entropy)[0:32]; reseed_cnt = 0
//   forced reseed when reseed_cnt reaches 1000 (DRBG halts if generate is
//   attempted while reseed is needed).
//
// MMIO (base 0x1000_0520):
//   0x20 DRBG_CTRL    WO [0]=generate [1]=reseed [2]=reset; [15:8]=byte_count
//   0x24 DRBG_STATUS  RO [0]=ready [1]=done [2]=reseed_needed [3]=halted
//   0x28 DRBG_OUT     RO 32-bit output word (auto-advance)
//   0x2C DRBG_COUNT   RO reseed counter
//   0x34 ENTROPY_IN   WO 32-bit entropy word (8 writes = 32 bytes for reseed)

`default_nettype none
`timescale 1ns/1ps

module drbg (
    input  wire       clk,
    input  wire       rst_n,

    // MMIO (base 0x1000_0520)
    input  wire       bus_req,
    input  wire       bus_we,
    input  wire [7:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    output wire        irq_done
);

    localparam [2:0] IDLE   = 3'd0;
    localparam [2:0] ABSORB = 3'd1;
    localparam [2:0] PERMUTE= 3'd2;
    localparam [2:0] OUTPUT = 3'd3;

    localparam [31:0] RESEED_LIMIT = 32'd1000;

    reg [2:0]    fsm;
    reg [255:0]  drbg_state;
    reg [255:0]  entropy_reg;
    reg [2:0]    ent_wr;        // entropy word write pointer
    reg [31:0]   reseed_cnt;
    reg [7:0]    out_buf [0:135];
    reg [7:0]    out_rd;
    reg [7:0]    byte_count;
    reg          reseed_phase;
    reg          ready, done, reseed_needed, halted;

    // sponge + keccak
    reg [1599:0] sponge;
    reg          permute_start;
    wire         permute_done;
    wire [1599:0] sponge_nxt;

    // one-cycle command pulses
    reg          gen_req, reseed_req, soft_reset;
    reg          read_out_q;    // delayed DRBG_OUT read (bus latency)

    keccak_f1600 u_keccak (
        .clk(clk), .rst_n(rst_n),
        .start(permute_start),
        .state_in(sponge),
        .state_out(sponge_nxt),
        .done(permute_done)
    );

    // absorb input: state (or state^entropy for reseed), then pad
    // byte 32 |= 0x1F, byte 135 |= 0x80 (SHAKE-256, rate 136)
    wire [255:0] absorb_in = reseed_phase ? (drbg_state ^ entropy_reg) : drbg_state;
    wire [1599:0] sponge_input = {1344'b0, absorb_in};
    wire [1599:0] sponge_pad   = (1600'h1F << 256) | (1600'h80 << 1080);
    wire [1599:0] sponge_abs   = sponge_input | sponge_pad;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            fsm           <= IDLE;
            drbg_state    <= 256'b0;
            entropy_reg   <= 256'b0;
            ent_wr        <= 3'd0;
            reseed_cnt    <= 32'd0;
            out_rd        <= 8'd0;
            byte_count    <= 8'd0;
            reseed_phase  <= 1'b0;
            ready         <= 1'b1;
            done          <= 1'b0;
            reseed_needed <= 1'b0;
            halted        <= 1'b0;
            sponge        <= 1600'b0;
            permute_start <= 1'b0;
            gen_req       <= 1'b0;
            reseed_req    <= 1'b0;
            soft_reset    <= 1'b0;
            read_out_q    <= 1'b0;
        end else begin
            gen_req    <= 1'b0;
            reseed_req <= 1'b0;
            soft_reset <= 1'b0;

            // delayed output read advance
            read_out_q <= bus_req && !bus_we && (bus_addr == 8'h28);
            if (read_out_q)
                out_rd <= out_rd + 4;

            // bus writes
            if (bus_req && bus_we) begin
                case (bus_addr[7:0])
                    8'h20: begin
                        if (bus_wdata[0]) gen_req    <= 1'b1;
                        if (bus_wdata[1]) reseed_req <= 1'b1;
                        if (bus_wdata[2]) soft_reset <= 1'b1;
                        byte_count <= bus_wdata[15:8];
                    end
                    8'h34: begin
                        entropy_reg[ent_wr*32 +: 32] <= bus_wdata;
                        ent_wr                        <= ent_wr + 3'd1;
                    end
                    default: ;
                endcase
            end

            if (soft_reset) begin
                fsm           <= IDLE;
                drbg_state    <= 256'b0;
                reseed_cnt    <= 32'd0;
                out_rd        <= 8'd0;
                byte_count    <= 8'd0;
                ready         <= 1'b1;
                done          <= 1'b0;
                reseed_needed <= 1'b0;
                halted        <= 1'b0;
                sponge        <= 1600'b0;
                permute_start <= 1'b0;
            end else begin
                case (fsm)
                    IDLE: begin
                        ready <= 1'b1;
                        if (gen_req) begin
                            done <= 1'b0;
                            if (reseed_needed) begin
                                halted <= 1'b1;
                            end else begin
                                ready        <= 1'b0;
                                reseed_phase <= 1'b0;
                                out_rd       <= 8'd0;
                                fsm          <= ABSORB;
                            end
                        end else if (reseed_req) begin
                            ready        <= 1'b0;
                            done         <= 1'b0;
                            reseed_phase <= 1'b1;
                            ent_wr       <= 3'd0;
                            out_rd       <= 8'd0;
                            fsm          <= ABSORB;
                        end
                    end

                    ABSORB: begin
                        sponge        <= sponge_abs;
                        permute_start <= 1'b1;
                        fsm           <= PERMUTE;
                    end

                    PERMUTE: begin
                        permute_start <= 1'b0;
                        if (permute_done) begin
                            sponge <= sponge_nxt;
                            fsm    <= OUTPUT;
                        end
                    end

                    OUTPUT: begin
                        if (reseed_phase) begin
                            drbg_state    <= sponge[255:0];
                            reseed_cnt    <= 32'd0;
                            reseed_needed <= 1'b0;
                            halted        <= 1'b0;
                            done          <= 1'b1;
                            fsm           <= IDLE;
                        end else begin
                            drbg_state <= sponge[511:256];
                            reseed_cnt <= reseed_cnt + 32'd1;
                            if (reseed_cnt + 32'd1 >= RESEED_LIMIT)
                                reseed_needed <= 1'b1;
                            done <= 1'b1;
                            fsm  <= IDLE;
                        end
                    end

                    default: fsm <= IDLE;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Output buffer: fixed-position copies from the sponge (no muxes).
    // ------------------------------------------------------------------
    genvar gox;
    generate
        for (gox = 0; gox < 136; gox = gox + 1) begin : g_out
            always @(posedge clk) begin
                if (!rst_n)
                    out_buf[gox] <= 8'h00;
                else if (fsm == OUTPUT && !reseed_phase && gox < byte_count)
                    out_buf[gox] <= sponge[8*gox +: 8];
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Bus interface
    // ------------------------------------------------------------------
    reg [31:0] out_wrd_q;
    always @(posedge clk) begin
        if (!rst_n) out_wrd_q <= 32'h0;
        else if (bus_req && !bus_we && bus_addr == 8'h28)
            out_wrd_q <= {out_buf[out_rd+3], out_buf[out_rd+2],
                          out_buf[out_rd+1], out_buf[out_rd]};
    end

    always @(*) begin
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h24: bus_rdata = {28'b0, halted, reseed_needed, done, ready};
            8'h28: bus_rdata = out_wrd_q;
            8'h2C: bus_rdata = reseed_cnt;
            default: bus_rdata = 32'h0;
        endcase
    end

    always @(*) begin
        bus_ack = bus_req;
    end

    assign irq_done = done;

endmodule

`default_nettype wire
