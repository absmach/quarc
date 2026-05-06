// timer.v - RISC-V machine-mode timer (mtime/mtimecmp) + watchdog
// Base address: 0x2000_0200
//
// Registers (8-bit local offset):
//   0x00  MTIME_LO     RW  mtime[31:0]
//   0x04  MTIME_HI     RW  mtime[63:32]
//   0x08  MTIMECMP_LO  RW  mtimecmp[31:0]
//   0x0C  MTIMECMP_HI  RW  mtimecmp[63:32]
//   0x10  WDT_LOAD     WO  write any value to reset watchdog
//   0x14  WDT_CTRL     WO  [0]=enable watchdog
//   0x18  WDT_PERIOD   WO  watchdog timeout in clock cycles
//                          default: 25_000_000 / 10 = 2_500_000 (100 ms @ 25 MHz)
//
// timer_irq asserts whenever mtime >= mtimecmp.
// wdt_rst pulses high for one cycle on watchdog timeout.

`default_nettype none
`timescale 1ns/1ps

module timer #(
    parameter integer CLK_FREQ        = 25_000_000,
    parameter integer WDT_DEFAULT     = 2_500_000  // 100 ms @ 25 MHz
) (
    input  wire        clk,
    input  wire        rst_n,

    // Bus
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,

    // Outputs
    output wire        timer_irq,
    output reg         wdt_rst
);

    // ── mtime / mtimecmp ─────────────────────────────────────────────────────
    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    always @(posedge clk) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            // Free-running counter
            mtime <= mtime + 64'd1;

            if (bus_req && bus_we) begin
                case (bus_addr[7:0])
                    8'h00: mtime[31:0]     <= bus_wdata;
                    8'h04: mtime[63:32]    <= bus_wdata;
                    8'h08: mtimecmp[31:0]  <= bus_wdata;
                    8'h0C: mtimecmp[63:32] <= bus_wdata;
                    default: ;
                endcase
            end
        end
    end

    assign timer_irq = (mtime >= mtimecmp);

    // ── Watchdog ─────────────────────────────────────────────────────────────
    reg [31:0] wdt_period;
    reg [31:0] wdt_count;
    reg        wdt_enable;

    always @(posedge clk) begin
        if (!rst_n) begin
            wdt_period <= WDT_DEFAULT[31:0];
            wdt_count  <= WDT_DEFAULT[31:0];
            wdt_enable <= 1'b0;
            wdt_rst    <= 1'b0;
        end else begin
            wdt_rst <= 1'b0;

            if (bus_req && bus_we) begin
                case (bus_addr[7:0])
                    8'h10: wdt_count  <= wdt_period;            // kick
                    8'h14: wdt_enable <= bus_wdata[0];
                    8'h18: begin
                        wdt_period <= bus_wdata;
                        wdt_count  <= bus_wdata;                 // also reload
                    end
                    default: ;
                endcase
            end else if (wdt_enable) begin
                if (wdt_count == 32'd0) begin
                    wdt_rst   <= 1'b1;
                    wdt_count <= wdt_period;
                end else begin
                    wdt_count <= wdt_count - 32'd1;
                end
            end
        end
    end

    // ── Bus read mux ─────────────────────────────────────────────────────────
    always @(*) begin
        bus_ack   = bus_req;
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h00: bus_rdata = mtime[31:0];
            8'h04: bus_rdata = mtime[63:32];
            8'h08: bus_rdata = mtimecmp[31:0];
            8'h0C: bus_rdata = mtimecmp[63:32];
            default: bus_rdata = 32'h0;
        endcase
    end

endmodule

`default_nettype wire
