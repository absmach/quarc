// tb_sha3_soc.sv - SoC-level SHA-3 test
//
// Boots the full SoC with the boot_sha3 firmware (computes SHA3-256("abc")
// through the MMIO at 0x1000_0000) and checks the UART for "SHA3 OK\r\n".

`timescale 1ns/1ps

module tb_sha3_soc;

    // 25 MHz clock -> 40 ns period
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg [2:0] led_unused;

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

    // Load the SHA-3 self-test firmware into the boot ROM.
    defparam dut.u_bus.u_boot_rom.ROM_FILE = "fw/boot_sha3.hex";

    // ── UART monitor (115200 8N1) ────────────────────────────────────────────
    localparam real BIT_NS = 1.0e9 / 115200.0;

    reg [7:0] rx_buf [0:15];
    integer   rx_count = 0;
    integer   result = -1;   // 0 = FAIL, 1 = PASS

    initial begin
        $dumpfile("build/tb_sha3_soc.vcd");
        $dumpvars(0, tb_sha3_soc);
    end

    initial begin
        byte b;
        integer i;
        forever begin
            @(negedge uart_tx);
            #(BIT_NS * 1.5);
            b = 8'h00;
            for (i = 0; i < 8; i++) begin
                b[i] = uart_tx;
                #(BIT_NS);
            end
            rx_buf[rx_count % 16] = b;
            rx_count++;
            $display("[%0t] uart byte %0d: 0x%02h '%s'", $time, rx_count, b,
                     (b >= 8'h20 && b < 8'h7f) ? string'(b) : " ");
            // check for "SHA3 OK" or "SHA3 FAIL"
            if (rx_count >= 7 &&
                rx_buf[(rx_count-7) % 16] == "S" &&
                rx_buf[(rx_count-6) % 16] == "H" &&
                rx_buf[(rx_count-5) % 16] == "A" &&
                rx_buf[(rx_count-4) % 16] == "3" &&
                rx_buf[(rx_count-3) % 16] == " " &&
                rx_buf[(rx_count-2) % 16] == "O" &&
                rx_buf[(rx_count-1) % 16] == "K") begin
                result = 1;
                $display("[%0t] PASS: SHA-3 firmware test passed", $time);
                $finish;
            end
            if (rx_count >= 9 &&
                rx_buf[(rx_count-9) % 16] == "S" &&
                rx_buf[(rx_count-8) % 16] == "H" &&
                rx_buf[(rx_count-7) % 16] == "A" &&
                rx_buf[(rx_count-6) % 16] == "3" &&
                rx_buf[(rx_count-5) % 16] == " " &&
                rx_buf[(rx_count-4) % 16] == "F" &&
                rx_buf[(rx_count-3) % 16] == "A" &&
                rx_buf[(rx_count-2) % 16] == "I" &&
                rx_buf[(rx_count-1) % 16] == "L") begin
                result = 0;
                $display("[%0t] FAIL: SHA-3 firmware test failed", $time);
                $finish;
            end
        end
    end

    // ── Watchdog ─────────────────────────────────────────────────────────────
    initial begin
        #100_000_000;   // 100 ms
        if (result < 0)
            $display("[%0t] FAIL: timed out before SHA-3 result", $time);
        $finish;
    end

endmodule
