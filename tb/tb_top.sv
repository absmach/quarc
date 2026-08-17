// tb_top.sv - Phase 0 SoC testbench
//
// Brings up quarc_top with a 25 MHz clock, listens on uart_tx, decodes the
// 8N1 stream at 115_200 baud, and checks that the boot ROM emits "QUARC v0\r\n".

`timescale 1ns/1ps

module tb_top;

    // 25 MHz clock -> 40 ns period
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg [2:0] led_unused;

    // External pins
    wire uart_tx;
    reg  uart_rx   = 1'b1;
    reg  spi_sck   = 1'b0;
    reg  spi_mosi  = 1'b0;
    wire spi_miso;
    reg  spi_cs_n  = 1'b1;
    wire [2:0] led;

    quarc_top dut (
        .clk_25mhz (clk),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
        .spi_sck   (spi_sck),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso),
        .spi_cs_n  (spi_cs_n),
        .led       (led)
    );

    // ── UART monitor (115200 8N1) ────────────────────────────────────────────
    // Bit period at 115200 baud = 1/115200 s = 8.681 us = 8681 ns.
    localparam real BIT_NS = 1.0e9 / 115200.0;

    string  rx_string = "";
    integer rx_count  = 0;
    integer expect_len;
    reg [7:0] expected [0:9];

    initial begin
        expected[0] = "Q"; expected[1] = "U"; expected[2] = "A"; expected[3] = "R"; expected[4] = "C";
        expected[5] = " "; expected[6] = "v"; expected[7] = "0"; expected[8] = 8'h0d; expected[9] = 8'h0a;
        expect_len = 10;
    end

    initial begin
        $dumpfile("build/sim.vcd");
        $dumpvars(0, tb_top);
    end

    // Decode uart_tx — wait for start bit, sample mid-bit for 8 data bits
    initial begin
        byte b;
        forever begin
            // Wait for start bit (falling edge)
            @(negedge uart_tx);
            // Move to middle of start bit
            #(BIT_NS * 1.5);
            b = 8'h00;
            for (int i = 0; i < 8; i++) begin
                b[i] = uart_tx;
                #(BIT_NS);
            end
            // We are now somewhere in the stop bit; consume it.
            // (no need to wait — falling edge of next start handles it.)
            rx_string = {rx_string, string'(b)};
            $display("[%0t] uart byte %0d: 0x%02h '%s'",
                     $time, rx_count, b,
                     (b >= 8'h20 && b < 8'h7f) ? string'(b) :
                     (b == 8'h0d ? "\\r" : (b == 8'h0a ? "\\n" : "?")));
            if (b !== expected[rx_count]) begin
                $display("[%0t] FAIL byte %0d: expected 0x%02h got 0x%02h",
                         $time, rx_count, expected[rx_count], b);
                $finish;
            end
            rx_count++;
            if (rx_count >= expect_len) begin
                $display("[%0t] PASS: UART emitted QUARC v0\\r\\n", $time);
                $finish;
            end
        end
    end

    // ── Watchdog: bail out if we never see the banner ────────────────────────
    initial begin
        #50_000_000; // 50 ms in ns
        $display("[%0t] FAIL: timed out before banner observed (got: '%s')",
                 $time, rx_string);
        $finish;
    end

endmodule
