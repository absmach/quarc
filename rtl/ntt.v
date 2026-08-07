`default_nettype none
`timescale 1ns/1ps

// ntt.v - ML-KEM (FIPS 203) NTT / inverse-NTT / basemul engine, q = 3329
//
// MMIO (base 0x1000_0800):
//   0x00  CTRL    [2:0] op (1=forward NTT, 2=inverse NTT, 3=basemul), [4] go
//                 Any CTRL write resets the streaming coefficient pointers.
//   0x04  STATUS  [0] busy, [1] done (cleared on next go)
//   0x08  COEFF   streaming 12-bit coefficient port. Each write stores one
//                 coefficient (low 12 bits) at the auto-incrementing write
//                 pointer; each read returns one coefficient and advances the
//                 read pointer.
//
// Layout: coefficients 0..255 hold the active polynomial (for basemul: A);
//         256..511 hold the second operand B for basemul. Results overwrite
//         0..255.
//
// The forward/inverse transform uses one butterfly per 4-5 cycles with a
// single 12x12 multiplier; zetas come from an embedded 128-entry ROM.

module ntt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output wire        bus_ack,
    output wire        irq_done
);
    localparam [11:0] Q     = 12'd3329;
    localparam [11:0] F_INV = 12'd3303;      // 128^-1 mod q

    localparam [2:0] OP_FWD = 3'd1;
    localparam [2:0] OP_INV = 3'd2;
    localparam [2:0] OP_MUL = 3'd3;

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_RUN   = 2'd1;
    localparam [1:0] ST_SCALE = 2'd2;
    localparam [1:0] ST_DONE  = 2'd3;

    `include "ntt_zetas.vh"

    // ---------------- coefficient RAM: 512 x 12, 2R/1W ----------------
    reg [11:0] ram [0:511];
    reg [8:0]  ra;
    reg [8:0]  rb;
    wire [8:0] wa;
    wire       we;
    wire [11:0] wd;
    wire [11:0] ra_d = ram[ra];
    wire [11:0] rb_d = ram[rb];
    always @(posedge clk)
        if (we) ram[wa] <= wd;

    // ---------------- registers ----------------
    reg [2:0]  op;
    reg        busy;
    reg        done;
    reg [1:0]  st;
    reg [9:0]  widx;
    reg [2:0]  ph;
    reg [11:0] a, b;
    reg [11:0] a0, a1, b0, b1;
    reg [11:0] ca, cb;
    reg [11:0] zeta_sel;
    reg [8:0]  addr_a, addr_b;
    reg        we_fsm;
    reg [8:0]  wa_fsm;
    reg [11:0] wd_fsm;
    reg [2:0]  op_in;
    reg        go_r;
    reg [9:0]  wr_ptr;
    reg [9:0]  rd_ptr;

    wire coeff_wr = bus_req && bus_we && (bus_addr == 8'h08);
    wire coeff_rd = bus_req && !bus_we && (bus_addr == 8'h08);

    // ---------------- work-item decode (combinational) ----------------
    wire [6:0] L  = widx[9:7];
    wire [6:0] jl = widx[6:0];

    // forward NTT: len = 128>>L, blocks = 2^L, block = jl>>(7-L), j = jl & (len-1)
    wire [7:0] flen   = 8'd128 >> L;
    wire [6:0] fblock = jl >> (7 - L);
    wire [8:0] fstart = fblock << (8 - L);
    wire [8:0] f_ja   = fstart + (jl & (flen - 1));
    wire [8:0] f_jb   = f_ja + flen;

    // inverse NTT: len = 2<<L, blocks = 64>>L, block = jl>>(L+1), j = jl & (len-1)
    wire [7:0] ilen   = 8'd2 << L;
    wire [6:0] iblock = jl >> (L + 1);
    wire [8:0] istart = iblock << (L + 2);
    wire [8:0] i_ja   = istart + (jl & (ilen - 1));
    wire [8:0] i_jb   = i_ja + ilen;

    // basemul: pair p = widx, a at 2p/2p+1, b at 256+2p/256+2p+1
    wire [8:0] m_a0 = {1'b0, widx[7:0]} << 1;
    wire [8:0] m_a1 = m_a0 | 9'd1;
    wire [8:0] m_b0 = 9'd256 + m_a0;
    wire [8:0] m_b1 = 9'd256 + m_a1;

    function [6:0] cumf(input [2:0] lv);
        case (lv)
            3'd0:   cumf = 7'd0;
            3'd1:   cumf = 7'd1;
            3'd2:   cumf = 7'd3;
            3'd3:   cumf = 7'd7;
            3'd4:   cumf = 7'd15;
            3'd5:   cumf = 7'd31;
            default: cumf = 7'd63;
        endcase
    endfunction

    function [7:0] cumi(input [2:0] lv);
        case (lv)
            3'd0:   cumi = 8'd0;
            3'd1:   cumi = 8'd64;
            3'd2:   cumi = 8'd96;
            3'd3:   cumi = 8'd112;
            3'd4:   cumi = 8'd120;
            3'd5:   cumi = 8'd124;
            default: cumi = 8'd126;
        endcase
    endfunction

    always @(*) begin
        case (op)
            OP_FWD: zeta_sel = zget(cumf(L) + fblock + 1);
            OP_INV: zeta_sel = zget(127 - (cumi(L) + iblock));
            OP_MUL: begin
                zeta_sel = zget(64 + widx[7:1]);     // 64 + (p >> 1)
                if (widx[0]) zeta_sel = Q - zeta_sel; // odd pairs negate
            end
            default: zeta_sel = 12'h0;
        endcase
    end

    always @(*) begin
        case (op)
            OP_FWD: begin addr_a = f_ja; addr_b = f_jb; end
            OP_INV: begin addr_a = i_ja; addr_b = i_jb; end
            OP_MUL: begin addr_a = m_a0; addr_b = m_a1; end
            default: begin addr_a = 9'd0; addr_b = 9'd0; end
        endcase
    end

    // ---------------- modular arithmetic ----------------
    function [11:0] modq(input [23:0] p);
        reg [36:0] prod;
        reg [12:0] m;
        reg [23:0] r;
        begin
            prod = p * 24'd5039;              // floor(2^24/q)
            m    = prod[36:24];
            r    = p - m * 24'd3329;
            if (r >= 24'd3329) r = r - 24'd3329;
            if (r >= 24'd3329) r = r - 24'd3329;
            modq = r[11:0];
        end
    endfunction

    function [11:0] addq(input [11:0] x, input [11:0] y);
        reg [12:0] s;
        begin
            s = x + y;
            if (s >= 13'd3329) s = s - 13'd3329;
            addq = s[11:0];
        end
    endfunction

    function [11:0] subq(input [11:0] x, input [11:0] y);
        reg [12:0] s;
        begin
            s = x + 13'd3329 - y;
            if (s >= 13'd3329) s = s - 13'd3329;
            subq = s[11:0];
        end
    endfunction

    // ---------------- datapath (combinational) ----------------
    wire [11:0] fwd_t  = modq(zeta_sel * b);
    wire [11:0] inv_t  = modq(zeta_sel * subq(b, a));
    wire [11:0] m_p0   = modq(a0 * b0);
    wire [11:0] m_p1   = modq(a1 * b1);
    wire [11:0] m_p1z  = modq(m_p1 * zeta_sel);
    wire [11:0] m_q0   = modq(a0 * b1);
    wire [11:0] m_q1   = modq(a1 * b0);
    wire [11:0] scale_t = modq(ra_d * F_INV);

    always @(*) begin
        case (op)
            OP_FWD: begin ca = addq(a, fwd_t); cb = subq(a, fwd_t); end
            OP_INV: begin ca = addq(a, b);     cb = inv_t;          end
            OP_MUL: begin ca = addq(m_p0, m_p1z); cb = addq(m_q0, m_q1); end
            default: begin ca = 12'h0;         cb = 12'h0;          end
        endcase
    end

    // ---------------- control FSM ----------------
    wire [9:0] run_total  = (op == OP_MUL) ? 10'd128 : 10'd896;
    wire [9:0] last_widx  = run_total - 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= ST_IDLE;
            busy   <= 1'b0;
            done   <= 1'b0;
            widx   <= 10'd0;
            ph     <= 3'd0;
            we_fsm <= 1'b0;
            wa_fsm <= 9'd0;
            wd_fsm <= 12'd0;
            a <= 12'd0; b <= 12'd0;
            a0 <= 12'd0; a1 <= 12'd0; b0 <= 12'd0; b1 <= 12'd0;
            ra <= 9'd0; rb <= 9'd0;
        end else begin
            we_fsm <= 1'b0;
            case (st)
                ST_IDLE: begin
                    if (go_r) begin
                        op   <= op_in;
                        busy <= 1'b1;
                        done <= 1'b0;
                        widx <= 10'd0;
                        ph   <= 3'd0;
                        st   <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    case (ph)
                        3'd0: begin
                            ra <= addr_a;
                            rb <= addr_b;
                            ph <= 3'd1;
                        end
                        3'd1: begin
                            if (op == OP_MUL) begin
                                a0 <= ra_d;
                                a1 <= rb_d;
                                ra <= m_b0;
                                rb <= m_b1;
                                ph <= 3'd2;
                            end else begin
                                a  <= ra_d;
                                b  <= rb_d;
                                ph <= 3'd2;
                            end
                        end
                        3'd2: begin
                            if (op == OP_MUL) begin
                                b0 <= ra_d;
                                b1 <= rb_d;
                                ph <= 3'd3;
                            end else begin
                                we_fsm <= 1'b1;
                                wa_fsm <= addr_a;
                                wd_fsm <= ca;
                                ph     <= 3'd3;
                            end
                        end
                        3'd3: begin
                            if (op == OP_MUL) begin
                                we_fsm <= 1'b1;
                                wa_fsm <= addr_a;
                                wd_fsm <= ca;
                                ph     <= 3'd4;
                            end else begin
                                we_fsm <= 1'b1;
                                wa_fsm <= addr_b;
                                wd_fsm <= cb;
                                if (widx == last_widx) begin
                                    if (op == OP_INV) begin
                                        widx <= 10'd0;
                                        ph   <= 3'd0;
                                        st   <= ST_SCALE;
                                    end else begin
                                        st   <= ST_DONE;
                                    end
                                end else begin
                                    widx <= widx + 10'd1;
                                    ph   <= 3'd0;
                                end
                            end
                        end
                        3'd4: begin   // mul: second write
                            we_fsm <= 1'b1;
                            wa_fsm <= addr_b;
                            wd_fsm <= cb;
                            if (widx == 10'd127) begin
                                st <= ST_DONE;
                            end else begin
                                widx <= widx + 10'd1;
                                ph   <= 3'd0;
                            end
                        end
                        default: ph <= 3'd0;
                    endcase
                end

                ST_SCALE: begin
                    case (ph)
                        3'd0: begin
                            ra <= widx[8:0];
                            ph <= 3'd1;
                        end
                        3'd1: begin
                            we_fsm <= 1'b1;
                            wa_fsm <= widx[8:0];
                            wd_fsm <= scale_t;
                            ph     <= 3'd2;
                        end
                        3'd2: begin
                            if (widx == 10'd255) begin
                                st <= ST_DONE;
                            end else begin
                                widx <= widx + 10'd1;
                                ph   <= 3'd0;
                            end
                        end
                        default: ph <= 3'd0;
                    endcase
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= ST_IDLE;
                end
                default: st <= ST_IDLE;
            endcase
        end
    end

    // ---------------- RAM write mux ----------------
    assign we = busy ? we_fsm : coeff_wr;
    assign wa = busy ? wa_fsm : wr_ptr;
    assign wd = busy ? wd_fsm : bus_wdata[11:0];

    // ---------------- bus interface ----------------
    reg [11:0] rd_data_q;
    reg        read_coeff_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_in        <= 3'd0;
            go_r         <= 1'b0;
            wr_ptr       <= 10'd0;
            rd_ptr       <= 10'd0;
            rd_data_q    <= 12'd0;
            read_coeff_q <= 1'b0;
        end else begin
            go_r         <= 1'b0;
            read_coeff_q <= coeff_rd;
            if (coeff_rd) rd_data_q <= ram[rd_ptr];
            if (read_coeff_q) rd_ptr <= rd_ptr + 10'd1;
            if (bus_req && bus_we) begin
                case (bus_addr[7:0])
                    8'h00: begin
                        op_in  <= bus_wdata[2:0];
                        go_r   <= bus_wdata[4];
                        wr_ptr <= 10'd0;
                        rd_ptr <= 10'd0;
                    end
                    default: ;
                endcase
            end
            if (coeff_wr) wr_ptr <= wr_ptr + 10'd1;
        end
    end

    always @(*) begin
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h04: bus_rdata = {30'b0, done, busy};   // [0]=busy [1]=done
            8'h08: bus_rdata = {20'b0, rd_data_q};
            default: bus_rdata = 32'h0;
        endcase
    end

    assign bus_ack  = bus_req;
    assign irq_done = done;

endmodule

`default_nettype wire
