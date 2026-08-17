// tb_mlkem_sw_soc.sv - SoC-level software ML-KEM test
//
// Boots the full SoC with the C firmware (crt0.S + mlkem_sw.c) that runs the
// full ML-KEM-768 keygen/encaps/decaps in software, driving the sha3 and ntt
// coprocessors over MMIO, and checks the UART for "MLKEM SW OK\r\n".

`timescale 1ns/1ps

module tb_mlkem_sw_soc;

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

    // Load the software ML-KEM self-test firmware into the boot ROM.
    defparam dut.u_bus.u_boot_rom.ROM_FILE = "fw/boot_mlkem_sw.hex";

    // ── UART monitor (115200 8N1) ────────────────────────────────────────────
    localparam real BIT_NS = 1.0e9 / 115200.0;

    reg [7:0] rx_buf [0:31];
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
            rx_buf[rx_count % 32] = b;
            rx_count++;
            // check for "MLKEM SW OK"
            if (rx_count >= 11 &&
                rx_buf[(rx_count-11) % 32] == "M" &&
                rx_buf[(rx_count-10) % 32] == "L" &&
                rx_buf[(rx_count-9)  % 32] == "K" &&
                rx_buf[(rx_count-8)  % 32] == "E" &&
                rx_buf[(rx_count-7)  % 32] == "M" &&
                rx_buf[(rx_count-6)  % 32] == " " &&
                rx_buf[(rx_count-5)  % 32] == "S" &&
                rx_buf[(rx_count-4)  % 32] == "W" &&
                rx_buf[(rx_count-3)  % 32] == " " &&
                rx_buf[(rx_count-2)  % 32] == "O" &&
                rx_buf[(rx_count-1)  % 32] == "K") begin
                result = 1;
                $display("[%0t] PASS: software ML-KEM firmware test passed", $time);
                $finish;
            end
            // check for "MLKEM SW FAIL"
            if (rx_count >= 13 &&
                rx_buf[(rx_count-13) % 32] == "M" &&
                rx_buf[(rx_count-12) % 32] == "L" &&
                rx_buf[(rx_count-11) % 32] == "K" &&
                rx_buf[(rx_count-10) % 32] == "E" &&
                rx_buf[(rx_count-9)  % 32] == "M" &&
                rx_buf[(rx_count-8)  % 32] == " " &&
                rx_buf[(rx_count-7)  % 32] == "S" &&
                rx_buf[(rx_count-6)  % 32] == "W" &&
                rx_buf[(rx_count-5)  % 32] == " " &&
                rx_buf[(rx_count-4)  % 32] == "F" &&
                rx_buf[(rx_count-3)  % 32] == "A" &&
                rx_buf[(rx_count-2)  % 32] == "I" &&
                rx_buf[(rx_count-1)  % 32] == "L") begin
                result = 0;
                $display("[%0t] FAIL: software ML-KEM firmware test failed", $time);
                $finish;
            end
        end
    end

    // ── Watchdog ─────────────────────────────────────────────────────────────
    initial begin
        #2_000_000_000;   // 2 s (software keygen+encaps+decaps + UART)
        if (result < 0) begin
            $display("[%0t] FAIL timed out", $time);
        end
        $finish;
    end

endmodule
