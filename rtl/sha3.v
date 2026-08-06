// sha3.v - SHA-3 / SHAKE wrapper around keccak_f1600
//
// Memory-mapped sponge (base 0x1000_0000):
//   0x00 CTRL          WO  [0]=absorb_start [1]=squeeze_start [2]=soft_reset
//   0x04 STATUS        RO  [0]=ready [1]=absorb_done [2]=squeeze_done [3]=error
//   0x08 MODE          WO  [2:0] 0=SHA3-256 1=SHA3-512 2=SHAKE-128 3=SHAKE-256
//   0x0C DATA_IN       WO  32-bit absorb word (byte buffer, LSB first)
//   0x10 DATA_OUT      RO  32-bit squeeze word (LSB first, auto-advance)
//   0x14 LEN           WO  absorb byte count
//   0x18 SQUEEZE_LEN   WO  number of output bytes requested
//   0x1C IRQ_EN        WO  [0]=absorb_done_irq [1]=squeeze_done_irq
//
// Flow: set MODE, write LEN and the message via DATA_IN, pulse CTRL[0].
// Absorb pads (SHA3 0x06 / SHAKE 0x1F, then 0x80) and permutes. When
// STATUS[1] sets, write SQUEEZE_LEN, pulse CTRL[1], then read DATA_OUT.

`default_nettype none
`timescale 1ns/1ps

module sha3 (
    input  wire        clk,
    input  wire        rst_n,
    // Bus interface (base 0x1000_0000)
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    // Interrupt
    output wire        irq_done
);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    localparam [2:0] IDLE            = 3'd0;
    localparam [2:0] ABSORB          = 3'd1;
    localparam [2:0] ABSORB_PERMUTE  = 3'd2;
    localparam [2:0] SQUEEZE         = 3'd3;
    localparam [2:0] SQUEEZE_PERMUTE = 3'd4;

    localparam [9:0] MSG_MAX  = 10'd512;
    localparam [9:0] OUT_MAX  = 10'd256;

    // ------------------------------------------------------------------
    // Registers / signals
    // ------------------------------------------------------------------
    reg [2:0]   fsm;
    reg [1:0]   mode;
    reg [9:0]   len;
    reg [9:0]   squeeze_len;
    reg [1:0]   irq_en;

    reg [9:0]   b;              // block index during absorb
    reg [8:0]   j;              // byte index within current block
    reg [9:0]   nblocks;
    reg [9:0]   out_pos;        // squeeze byte counter
    reg [9:0]   msg_wr;         // DATA_IN buffer write pointer (bytes)
    reg [9:0]   out_rd;         // DATA_OUT buffer read pointer (bytes)

    reg [1599:0] state;
    reg         permute_start;
    wire        permute_done;
    wire [1599:0] state_nxt;

    reg [7:0]   msg_buf [0:MSG_MAX-1];
    reg [7:0]   out_buf [0:OUT_MAX-1];

    reg         ready, absorb_done, squeeze_done, error;

    // one-cycle command pulses from CTRL writes
    reg         absorb_start_req;
    reg         squeeze_start_req;
    reg         soft_reset;

    // delayed DATA_OUT read request: the bus returns rdata one cycle after
    // the request, so the buffer pointer must advance one cycle later too,
    // otherwise the read would skip to the next word.
    reg         read_data_out_q;

    // ------------------------------------------------------------------
    // Rate (bytes per permutation) and domain-separation pad byte
    // ------------------------------------------------------------------
    wire [8:0] rate = (mode == 2'd1) ? 9'd72  :      // SHA3-512
                      (mode == 2'd2) ? 9'd168 :      // SHAKE-128
                                      9'd136;        // SHA3-256 / SHAKE-256
    wire [7:0] pad  = mode[1] ? 8'h1F : 8'h06;       // SHAKE vs SHA3

    // global byte position in the sponge input for absorb
    wire [11:0] gpos   = b*rate + j;
    // byte to XOR in during absorb: message, pad, or 0
    wire [7:0]  absorb_byte = (gpos < len)        ? msg_buf[gpos] :
                              (gpos == len)       ? pad           :
                                                   8'h00;
    // 0x80 terminator at the very end of the final block
    wire [7:0]  absorb_byte_p = (b == nblocks-1 && j == rate-1) ?
                                (absorb_byte | 8'h80) : absorb_byte;

    // ------------------------------------------------------------------
    // Keccak-f[1600] permutation
    // ------------------------------------------------------------------
    keccak_f1600 u_keccak (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (permute_start),
        .state_in (state),
        .state_out(state_nxt),
        .done     (permute_done)
    );

    // ------------------------------------------------------------------
    // Bus interface
    // ------------------------------------------------------------------
    always @(*) begin
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h04: bus_rdata = {28'b0, error, squeeze_done, absorb_done, ready};
            8'h10: bus_rdata = {out_buf[out_rd+3], out_buf[out_rd+2],
                                out_buf[out_rd+1], out_buf[out_rd]};
            default: bus_rdata = 32'h0;
        endcase
    end

    always @(*) begin
        bus_ack = bus_req;
    end

    // ------------------------------------------------------------------
    // Core FSM
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            fsm             <= IDLE;
            mode            <= 2'd0;
            len             <= 10'd0;
            squeeze_len     <= 10'd0;
            irq_en          <= 2'd0;
            b               <= 10'd0;
            j               <= 9'd0;
            nblocks         <= 10'd0;
            out_pos         <= 10'd0;
            msg_wr          <= 10'd0;
            out_rd          <= 10'd0;
            state           <= 1600'b0;
            permute_start   <= 1'b0;
            ready           <= 1'b1;
            absorb_done     <= 1'b0;
            squeeze_done    <= 1'b0;
            error           <= 1'b0;
            absorb_start_req<= 1'b0;
            squeeze_start_req<= 1'b0;
            soft_reset      <= 1'b0;
        end else begin
            // default: pulses clear
            absorb_start_req  <= 1'b0;
            squeeze_start_req <= 1'b0;
            soft_reset        <= 1'b0;

            // latch the DATA_OUT read request; advance out_rd one cycle later
            read_data_out_q <= bus_req && !bus_we && (bus_addr == 8'h10);
            if (read_data_out_q)
                out_rd <= out_rd + 4;

            // ---- bus writes ----
            if (bus_req && bus_we) begin
                case (bus_addr[7:0])
                    8'h00: begin
                        if (bus_wdata[0]) absorb_start_req   <= 1'b1;
                        if (bus_wdata[1]) squeeze_start_req  <= 1'b1;
                        if (bus_wdata[2]) soft_reset         <= 1'b1;
                    end
                    8'h08: mode        <= bus_wdata[2:0];
                    8'h0C: begin
                        msg_buf[msg_wr]   <= bus_wdata[7:0];
                        msg_buf[msg_wr+1] <= bus_wdata[15:8];
                        msg_buf[msg_wr+2] <= bus_wdata[23:16];
                        msg_buf[msg_wr+3] <= bus_wdata[31:24];
                        msg_wr            <= msg_wr + 4;
                    end
                    8'h14: len         <= bus_wdata[9:0];
                    8'h18: squeeze_len <= bus_wdata[9:0];
                    8'h1C: irq_en      <= bus_wdata[1:0];
                    default: ;
                endcase
            end

            if (soft_reset) begin
                fsm           <= IDLE;
                b             <= 10'd0;
                j             <= 9'd0;
                nblocks       <= 10'd0;
                out_pos       <= 10'd0;
                msg_wr        <= 10'd0;
                out_rd        <= 10'd0;
                state         <= 1600'b0;
                permute_start <= 1'b0;
                ready         <= 1'b1;
                absorb_done   <= 1'b0;
                squeeze_done  <= 1'b0;
                error         <= 1'b0;
            end else begin
                case (fsm)
                    IDLE: begin
                        ready <= 1'b1;
                        if (absorb_start_req) begin
                            ready       <= 1'b0;
                            msg_wr      <= 10'd0;
                            out_rd      <= 10'd0;
                            b           <= 10'd0;
                            j           <= 9'd0;
                            nblocks     <= (len / rate) + 1;
                            state       <= 1600'b0;
                            absorb_done <= 1'b0;
                            squeeze_done<= 1'b0;
                            error       <= 1'b0;
                            fsm         <= ABSORB;
                        end else if (squeeze_start_req) begin
                            if (!absorb_done) begin
                                error <= 1'b1;
                            end else begin
                                ready         <= 1'b0;
                                out_pos       <= 10'd0;
                                out_rd        <= 10'd0;
                                squeeze_done  <= 1'b0;
                                error         <= 1'b0;
                                fsm           <= SQUEEZE;
                            end
                        end
                    end

                    ABSORB: begin
                        // XOR current byte into the sponge state
                        state[8*j +: 8] <= state[8*j +: 8] ^ absorb_byte_p;
                        if (j == rate - 1) begin
                            j             <= 9'd0;
                            permute_start <= 1'b1;
                            fsm           <= ABSORB_PERMUTE;
                        end else begin
                            j <= j + 1;
                        end
                    end

                    ABSORB_PERMUTE: begin
                        permute_start <= 1'b0;
                        if (permute_done) begin
                            state <= state_nxt;
                            if (b == nblocks - 1) begin
                                absorb_done <= 1'b1;
                                fsm         <= IDLE;
                            end else begin
                                b   <= b + 1;
                                fsm <= ABSORB;
                            end
                        end
                    end

                    SQUEEZE: begin
                        if (out_pos >= squeeze_len) begin
                            squeeze_done <= 1'b1;
                            fsm          <= IDLE;
                        end else begin
                            out_buf[out_pos] <= state[8*(out_pos % rate) +: 8];
                            out_pos          <= out_pos + 1;
                            if ((out_pos % rate) == rate - 1) begin
                                // block boundary: permute if more output needed
                                if (out_pos + 1 < squeeze_len) begin
                                    permute_start <= 1'b1;
                                    fsm           <= SQUEEZE_PERMUTE;
                                end
                            end
                        end
                    end

                    SQUEEZE_PERMUTE: begin
                        permute_start <= 1'b0;
                        if (permute_done) begin
                            state <= state_nxt;
                            fsm   <= SQUEEZE;
                        end
                    end

                    default: fsm <= IDLE;
                endcase
            end
        end
    end

    assign irq_done = (irq_en[0] & absorb_done) | (irq_en[1] & squeeze_done);

endmodule

`default_nettype wire
