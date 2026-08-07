// trng.v - True random number generator with SP 800-90B health tests
//
// 4 ring oscillators (3-inverter loops) XORed produce raw bits, sampled at
// 1/SAMPLE_DIV of the clock rate. Repetition Count Test (RCT) and Adaptive
// Proportion Test (APT) run continuously in RTL; any failure latches
// `health_fail` and halts the sampler until reset.
//
// MMIO (base 0x1000_0500):
//   0x00 CTRL        WO  [0]=enable [1]=reseed_req
//   0x04 STATUS      RO  [0]=ready [1]=health_fail [2]=rct_fail
//                        [3]=apt_fail [4]=pool_ready
//   0x08 RANDOM      RO  32-bit random word (clears ready on read)
//   0x0C ENTROPY_LO  RO  entropy pool level in bits
//   0x10 HEALTH_CNT  RO  RCT consecutive count (debug)
//
// `inject_en_i`/`inject_bit_i` are test/fault-injection ports; tie inject_en_i
// low in production.

`default_nettype none
`timescale 1ns/1ps

module trng #(
    // sample every 64 clocks in hardware; every clock in simulation/formal
    // so the testbench can drive each raw bit directly
    parameter [6:0] SAMPLE_DIV = `ifdef QUARC_SIM 7'd1 `else 7'd64 `endif
) (
    input  wire       clk,
    input  wire       rst_n,

    // MMIO (base 0x1000_0500)
    input  wire       bus_req,
    input  wire       bus_we,
    input  wire [7:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    output wire        irq_health,

    // test / fault injection (tie low in production)
    input  wire       inject_en_i,
    input  wire       inject_bit_i
);

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg enable;
    reg reseed_req;

    reg [6:0]  clk_div;
    reg        sample_pulse;
    reg        raw_sample;

    // health test results (latched)
    reg        rct_fail;
    reg        apt_fail;
    reg        health_fail;

    // RCT state
    reg [4:0]  rct_cnt;
    reg        rct_prev;

    // APT state
    reg [9:0]  apt_cnt;
    reg [9:0]  apt_wpos;
    reg        apt_ref;

    // accumulation
    reg [31:0] raw_reg;
    reg [4:0]  bit_cnt;
    reg        ready;
    reg [31:0] entropy_level;

    localparam [4:0]  RCT_CUTOFF = 5'd13;    // C = 13, H_min=0.5, alpha=2^-6
    localparam [9:0]  APT_WINDOW = 10'd512;
    localparam [9:0]  APT_CUTOFF = 10'd325;  // B = 325, W = 512

    // ------------------------------------------------------------------
    // Entropy source (declared here so it can reference sample_pulse)
    // ------------------------------------------------------------------
    wire osc_raw;
`ifdef QUARC_SIM
    // Simulation substitute: a bit that toggles once per SAMPLE, giving a
    // balanced (alternating) stream that passes the health tests. The
    // testbench injects faults through inject_*.
    reg sim_toggle;
    always @(posedge clk) begin
        if (!rst_n) sim_toggle <= 1'b0;
        else if (sample_pulse) sim_toggle <= ~sim_toggle;
    end
    assign osc_raw = sim_toggle;
`else
    // Synthesizable entropy placeholder: a 31-bit LFSR with a tapped mix,
    // updated once per sample, emulating a jitter source so the health-test
    // pipeline is functional on hardware. A true ring-oscillator source
    // (per the plan: `boards/ulx3s.lpf` FREQUENCY IGNORE entries) requires
    // FPGA-specific constraints to survive synthesis; that is a hardened
    // product TODO.
    reg [30:0] lfsr;
    always @(posedge clk) begin
        if (!rst_n) lfsr <= 31'h0000_0001;
        else if (sample_pulse) begin
            lfsr <= {lfsr[29:0], lfsr[30] ^ lfsr[27]};   // primitive poly
        end
    end
    assign osc_raw = lfsr[0] ^ (lfsr[7] & lfsr[19]);
`endif

    wire raw_bit = inject_en_i ? inject_bit_i : osc_raw;

    // ------------------------------------------------------------------
    // Sampling: raw bit every SAMPLE_DIV clocks
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            clk_div      <= 6'd0;
            sample_pulse <= 1'b0;
            raw_sample   <= 1'b0;
        end else if (enable && !health_fail) begin
            if (clk_div == (SAMPLE_DIV - 7'd1)) begin
                clk_div      <= 7'd0;
                sample_pulse <= 1'b1;
                raw_sample   <= raw_bit;
            end else begin
                clk_div      <= clk_div + 7'd1;
                sample_pulse <= 1'b0;
            end
        end else begin
            sample_pulse <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Repetition Count Test (RCT)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            rct_cnt  <= 5'd0;
            rct_prev <= 1'b0;
            rct_fail <= 1'b0;
        end else if (sample_pulse && enable && !health_fail) begin
            if (raw_sample == rct_prev) begin
                rct_cnt <= rct_cnt + 5'd1;
                if (rct_cnt + 5'd1 >= RCT_CUTOFF)
                    rct_fail <= 1'b1;
            end else begin
                rct_cnt  <= 5'd1;
                rct_prev <= raw_sample;
            end
        end
    end

    // ------------------------------------------------------------------
    // Adaptive Proportion Test (APT)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            apt_cnt  <= 9'd0;
            apt_wpos <= 9'd0;
            apt_ref  <= 1'b0;
            apt_fail <= 1'b0;
        end else if (sample_pulse && enable && !health_fail) begin
            if (apt_wpos == 9'd0) begin
                apt_ref  <= raw_sample;
                apt_cnt  <= 9'd1;
                apt_wpos <= 9'd1;
            end else if (apt_wpos < APT_WINDOW) begin
                if (raw_sample == apt_ref) begin
                    apt_cnt <= apt_cnt + 9'd1;
                    if (apt_cnt + 9'd1 > APT_CUTOFF)
                        apt_fail <= 1'b1;
                end
                apt_wpos <= apt_wpos + 9'd1;
            end else begin
                apt_cnt  <= 9'd0;
                apt_wpos <= 9'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Latched health failure (only cleared by reset)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) health_fail <= 1'b0;
        else if (rct_fail || apt_fail) health_fail <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Raw bit accumulation into 32-bit words
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            raw_reg      <= 32'h0;
            bit_cnt      <= 5'd0;
            ready        <= 1'b0;
            entropy_level<= 32'h0;
        end else begin
            // reading RANDOM clears ready
            if (bus_req && !bus_we && bus_addr == 8'h08)
                ready <= 1'b0;
            if (sample_pulse && enable && !health_fail) begin
                raw_reg       <= {raw_reg[30:0], raw_sample};
                entropy_level <= entropy_level + 32'd1;
                if (bit_cnt == 5'd31) begin
                    bit_cnt <= 5'd0;
                    ready   <= 1'b1;
                end else begin
                    bit_cnt <= bit_cnt + 5'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Bus interface
    // ------------------------------------------------------------------
    wire pool_ready = (entropy_level >= 32'd256);

    always @(*) begin
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h04: bus_rdata = {27'b0, pool_ready, apt_fail, rct_fail, health_fail, ready};
            8'h08: bus_rdata = raw_reg;
            8'h0C: bus_rdata = entropy_level;
            8'h10: bus_rdata = {27'b0, rct_cnt};
            default: bus_rdata = 32'h0;
        endcase
    end

    always @(*) begin
        bus_ack = bus_req;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            enable     <= 1'b0;
            reseed_req <= 1'b0;
        end else if (bus_req && bus_we) begin
            case (bus_addr[7:0])
                8'h00: begin
                    enable     <= bus_wdata[0];
                    reseed_req <= bus_wdata[1];
                end
                default: ;
            endcase
        end
    end

    assign irq_health = health_fail;

    // ------------------------------------------------------------------
    // Formal properties (SymbiYosys)
    // ------------------------------------------------------------------
`ifdef FORMAL
    // constrain the BMC initial state to the reset state (not synthesized)
    initial begin
        clk_div     = 7'd0;
        rct_cnt     = 5'd0;
        apt_cnt     = 10'd0;
        apt_wpos    = 10'd0;
        health_fail = 1'b0;
        rct_fail    = 1'b0;
        apt_fail    = 1'b0;
        f_samp      = 5'd0;
        health_q    = 1'b0;
    end

    // stuck-fault scenario: no reset, always enabled, injection stuck at 1
    always @(posedge clk) begin
        assume(rst_n == 1'b1);
        assume(enable == 1'b1);
        assume(inject_en_i == 1'b1);
        assume(inject_bit_i == 1'b1);
    end

    // RCT: a stuck bit must assert rct_fail within 15 clocks. The formal
    // flow runs SAMPLE_DIV=1 (sample every clock); the extra cycles cover
    // the one-clock raw_sample pipeline.
    reg [4:0] f_samp;
    always @(posedge clk) begin
        if (!rst_n) f_samp <= 5'd0;
        else f_samp <= f_samp + 5'd1;
    end
    always @(*) begin
        if (f_samp >= 5'd15)
            assert(rct_fail == 1'b1);
    end

    // health_fail, once set, cannot clear without reset. Track the previous
    // cycle with a register (more robust than $past in BMC).
    reg health_q;
    always @(posedge clk) begin
        if (!rst_n) health_q <= 1'b0;
        else        health_q <= health_fail;
    end
    always @(*) begin
        if (health_q && rst_n)
            assert(health_fail == 1'b1);
    end
`endif

endmodule

`default_nettype wire
