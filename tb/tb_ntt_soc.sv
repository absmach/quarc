// tb_ntt_soc.sv - SoC-level NTT test
//
// Boots the full SoC with the boot_ntt firmware (fills the NTT engine with
// all-ones, runs forward + inverse NTT through the MMIO at 0x1000_0800, and
// verifies the round-trip) and checks the UART for "NTT OK\r\n".

`timescale 1ns/1ps

module tb_ntt_soc;

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

    // Load the NTT self-test firmware into the boot ROM.
    defparam dut.u_bus.u_boot_rom.ROM_FILE = "fw/boot_ntt.hex";

    // ── UART monitor (115200 8N1) ────────────────────────────────────────────
    localparam real BIT_NS = 1.0e9 / 115200.0;

    reg [7:0] rx_buf [0:15];
    integer   rx_count = 0;
    integer   result = -1;   // 0 = FAIL, 1 = PASS

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
            // check for "NTT OK" or "NTT FAIL"
            if (rx_count >= 6 &&
                rx_buf[(rx_count-6) % 16] == "N" &&
                rx_buf[(rx_count-5) % 16] == "T" &&
                rx_buf[(rx_count-4) % 16] == "T" &&
                rx_buf[(rx_count-3) % 16] == " " &&
                rx_buf[(rx_count-2) % 16] == "O" &&
                rx_buf[(rx_count-1) % 16] == "K") begin
                result = 1;
                $display("[%0t] PASS: NTT firmware test passed", $time);
                $finish;
            end
            if (rx_count >= 8 &&
                rx_buf[(rx_count-8) % 16] == "N" &&
                rx_buf[(rx_count-7) % 16] == "T" &&
                rx_buf[(rx_count-6) % 16] == "T" &&
                rx_buf[(rx_count-5) % 16] == " " &&
                rx_buf[(rx_count-4) % 16] == "F" &&
                rx_buf[(rx_count-3) % 16] == "A" &&
                rx_buf[(rx_count-2) % 16] == "I" &&
                rx_buf[(rx_count-1) % 16] == "L") begin
                result = 0;
                $display("[%0t] FAIL: NTT firmware test failed", $time);
                $finish;
            end
        end
    end

    // ── Watchdog ─────────────────────────────────────────────────────────────
    initial begin
        #200_000_000;   // 200 ms (two full NTT passes + UART)
        if (result < 0)
            $display("[%0t] FAIL: timed out before NTT result", $time);
        $finish;
    end

endmodule
