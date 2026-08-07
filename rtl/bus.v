// quarc_bus.v - Wishbone-lite system bus and peripheral instantiation
// Phase 0: Boot ROM (instr port), UART + timer (data port). All other
// peripherals are stubs returning bus_err for data accesses.
//
// Address map enforced here:
//   0x0000_0000 .. 0x0000_3FFF   Boot ROM        (R-X)
//   0x0000_4000 .. 0x0001_3FFF   Firmware IRAM   (Phase 1+)
//   0x0001_4000 .. 0x0001_7FFF   Data RAM        (Phase 1+)
//   0x0002_0000 .. 0x0002_0FFF   Key store       (Phase 4+)
//   0x1000_0000 .. 0x1000_05FF   Crypto MMIO     (Phase 1+)
//   0x2000_0000 .. 0x2000_00FF   SPI slave       (Phase 7)
//   0x2000_0100 .. 0x2000_01FF   UART
//   0x2000_0200 .. 0x2000_02FF   Timer / WDT
//   0x3000_0000 .. 0x3000_001F   Lifecycle       (Phase 6)
//   0x3000_0100 .. 0x3000_011F   Rollback ctr    (Phase 6)
//
// Bus protocol (Ibex memory interface):
//   * master asserts req (with addr/we/be/wdata)
//   * slave asserts gnt the same cycle (always grant in Phase 0)
//   * slave asserts rvalid exactly one cycle later, with rdata for reads
//   * data_err follows the same timing as rvalid

`default_nettype none
`timescale 1ns/1ps

module quarc_bus (
    input  wire        clk,
    input  wire        rst_n,

    // Ibex instruction port
    input  wire        instr_req,
    input  wire [31:0] instr_addr,
    output wire        instr_gnt,
    output reg         instr_rvalid,
    output reg  [31:0] instr_rdata,

    // Ibex data port
    input  wire        data_req,
    input  wire        data_we,
    input  wire [3:0]  data_be,
    input  wire [31:0] data_addr,
    input  wire [31:0] data_wdata,
    output wire        data_gnt,
    output reg         data_rvalid,
    output reg  [31:0] data_rdata,
    output reg         data_err,

    // Interrupts to Ibex
    output wire        irq_timer,
    output wire        irq_external,

    // Pins
    output wire        uart_tx,
    input  wire        uart_rx,
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,
    input  wire        spi_cs_n,
    output reg  [2:0]  led
);

    // ── Always-grant ─────────────────────────────────────────────────────────
    assign instr_gnt = instr_req;
    assign data_gnt  = data_req;

    // ── Instruction port: route to Boot ROM ──────────────────────────────────
    wire        rom_instr_req   = instr_req && (instr_addr[31:16] == 16'h0000);
    wire        rom_instr_rvalid;
    wire [31:0] rom_instr_rdata;

    boot_rom u_boot_rom (
        .clk    (clk),
        .req    (rom_instr_req),
        .addr   (instr_addr),
        .rvalid (rom_instr_rvalid),
        .rdata  (rom_instr_rdata)
    );

    // Track unmapped instruction fetches: deliver a bubble (rvalid+rdata=0)
    // one cycle later so Ibex doesn't hang. Real fault handling lands in
    // Phase 6 with PMP.
    reg instr_unmapped_q;
    always @(posedge clk) begin
        if (!rst_n)
            instr_unmapped_q <= 1'b0;
        else
            instr_unmapped_q <= instr_req && (instr_addr[31:16] != 16'h0000);
    end

    always @(*) begin
        instr_rvalid = rom_instr_rvalid || instr_unmapped_q;
        instr_rdata  = rom_instr_rvalid ? rom_instr_rdata : 32'h0000_0013; // NOP (addi x0,x0,0)
    end

    // ── Data port decode ─────────────────────────────────────────────────────
    // High-level decode by addr[31:24]:
    //   0x10 -> crypto region (Keccak/SHA-3 at 0x1000_0000)
    //   0x20 -> peripheral region (SPI/UART/Timer)
    //   else -> bus_err
    // Within each region, addr[15:8] selects the device.
    wire data_crypto_sel = (data_addr[31:24] == 8'h10);
    wire data_periph_sel = (data_addr[31:24] == 8'h20);
    wire uart_sel        = data_periph_sel && (data_addr[15:8] == 8'h01);
    wire timer_sel       = data_periph_sel && (data_addr[15:8] == 8'h02);
    wire spi_sel         = data_periph_sel && (data_addr[15:8] == 8'h00);
    wire sha3_sel        = data_crypto_sel && (data_addr[15:8] == 8'h00);
    wire trng_sel        = data_crypto_sel && (data_addr[15:8] == 8'h05) && (data_addr[7:5] == 3'b000);
    wire drbg_sel        = data_crypto_sel && (data_addr[15:8] == 8'h05) && (data_addr[7:5] == 3'b001);
    wire ntt_sel         = data_crypto_sel && (data_addr[15:8] == 8'h08);
    wire data_ram_sel    = (data_addr[31:16] == 16'h0001) && (data_addr[15:14] == 2'b01);

    // Local 8-bit register offset for each peripheral
    wire [7:0] periph_addr = data_addr[7:0];

    // ── UART ─────────────────────────────────────────────────────────────────
    wire        uart_ack;
    wire [31:0] uart_rdata;
    wire        uart_irq;

    uart u_uart (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_req   (data_req && uart_sel),
        .bus_we    (data_we),
        .bus_addr  (periph_addr),
        .bus_wdata (data_wdata),
        .bus_rdata (uart_rdata),
        .bus_ack   (uart_ack),
        .uart_tx   (uart_tx),
        .uart_rx   (uart_rx),
        .irq_rx    (uart_irq)
    );

    // ── Timer ────────────────────────────────────────────────────────────────
    wire        timer_ack;
    wire [31:0] timer_rdata;
    wire        timer_irq;
    wire        wdt_rst;

    timer u_timer (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_req   (data_req && timer_sel),
        .bus_we    (data_we),
        .bus_addr  (periph_addr),
        .bus_wdata (data_wdata),
        .bus_rdata (timer_rdata),
        .bus_ack   (timer_ack),
        .timer_irq (timer_irq),
        .wdt_rst   (wdt_rst)
    );

    assign irq_timer    = timer_irq;

    // Shared Keccak engine client wires (declared before use)
    wire             sha3_perm_req, drbg_perm_req;
    wire [1599:0]    sha3_perm_state_in, drbg_perm_state_in;
    wire             sha3_perm_done, drbg_perm_done;
    wire [1599:0]    sha3_perm_state_out, drbg_perm_state_out;

    // NTT wires (declared before use in irq_external)
    wire        ntt_ack;
    wire [31:0] ntt_rdata;
    wire        ntt_irq;

    // ── SHA-3 / SHAKE (base 0x1000_0000) ─────────────────────────────────────
    wire        sha3_ack;
    wire [31:0] sha3_rdata;
    wire        sha3_irq;

    sha3 u_sha3 (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_req   (data_req && sha3_sel),
        .bus_we    (data_we),
        .bus_addr  (data_addr[7:0]),
        .bus_wdata (data_wdata),
        .bus_rdata (sha3_rdata),
        .bus_ack   (sha3_ack),
        .irq_done  (sha3_irq),
        .perm_req       (sha3_perm_req),
        .perm_state_in  (sha3_perm_state_in),
        .perm_done      (sha3_perm_done),
        .perm_state_out (sha3_perm_state_out)
    );

    // ── TRNG (base 0x1000_0500) ──────────────────────────────────────────────
    wire        trng_ack;
    wire [31:0] trng_rdata;
    wire        trng_irq;

    trng u_trng (
        .clk         (clk),
        .rst_n       (rst_n),
        .bus_req     (data_req && trng_sel),
        .bus_we      (data_we),
        .bus_addr    (data_addr[7:0]),
        .bus_wdata   (data_wdata),
        .bus_rdata   (trng_rdata),
        .bus_ack     (trng_ack),
        .irq_health  (trng_irq),
        .inject_en_i (1'b0),
        .inject_bit_i(1'b0)
    );

    // ── DRBG (base 0x1000_0520) ──────────────────────────────────────────────
    wire        drbg_ack;
    wire [31:0] drbg_rdata;
    wire        drbg_irq;

    drbg u_drbg (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_req   (data_req && drbg_sel),
        .bus_we    (data_we),
        .bus_addr  (data_addr[7:0]),
        .bus_wdata (data_wdata),
        .bus_rdata (drbg_rdata),
        .bus_ack   (drbg_ack),
        .irq_done  (drbg_irq),
        .perm_req       (drbg_perm_req),
        .perm_state_in  (drbg_perm_state_in),
        .perm_done      (drbg_perm_done),
        .perm_state_out (drbg_perm_state_out)
    );

    assign irq_external = uart_irq | sha3_irq | trng_irq | drbg_irq | ntt_irq;

    // ── NTT (base 0x1000_0800) ───────────────────────────────────────────────
    ntt u_ntt (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_req   (data_req && ntt_sel),
        .bus_we    (data_we),
        .bus_addr  (data_addr[7:0]),
        .bus_wdata (data_wdata),
        .bus_rdata (ntt_rdata),
        .bus_ack   (ntt_ack),
        .c_req     (1'b0), .c_we(1'b0), .c_addr(8'h0), .c_wdata(32'h0),
        .c_rdata   (), .c_ack(),
        .irq_done  (ntt_irq)
    );

    // ── Shared Keccak engine (client 0 = SHA-3, client 1 = DRBG, client 2 = ML-KEM) ─
    keccak_engine u_keccak (
        .clk        (clk),
        .rst_n      (rst_n),
        .c0_req      (sha3_perm_req),
        .c0_state_in (sha3_perm_state_in),
        .c0_done     (sha3_perm_done),
        .c0_state_out(sha3_perm_state_out),
        .c1_req      (drbg_perm_req),
        .c1_state_in (drbg_perm_state_in),
        .c1_done     (drbg_perm_done),
        .c1_state_out(drbg_perm_state_out),
        .c2_req      (1'b0),
        .c2_state_in (1600'b0),
        .c2_done     (),
        .c2_state_out()
    );

    // ── Data RAM (0x0001_4000, 16 KiB) ────────────────────────────────────────
    wire        ram_rvalid;
    wire [31:0] ram_rdata;

    data_ram u_data_ram (
        .clk    (clk),
        .rst_n  (rst_n),
        .req    (data_req && data_ram_sel),
        .we     (data_we),
        .be     (data_be),
        .addr   (data_addr),
        .wdata  (data_wdata),
        .rvalid (ram_rvalid),
        .rdata  (ram_rdata)
    );

    // ── SPI slave (stub for Phase 0) ─────────────────────────────────────────
    // Tie outputs so the pins are driven; module gets implemented in Phase 7.
    assign spi_miso = 1'b0;
    wire   spi_unused = &{1'b0, spi_sck, spi_mosi, spi_cs_n};

    // ── Data response mux ────────────────────────────────────────────────────
    // Latch which device responded so we can mux rdata one cycle later.
    reg uart_sel_q, timer_sel_q, spi_sel_q, sha3_sel_q, trng_sel_q, drbg_sel_q, ntt_sel_q, ram_sel_q, unmapped_q, was_read_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            uart_sel_q  <= 1'b0;
            timer_sel_q <= 1'b0;
            spi_sel_q   <= 1'b0;
            sha3_sel_q  <= 1'b0;
            trng_sel_q  <= 1'b0;
            drbg_sel_q  <= 1'b0;
            ntt_sel_q   <= 1'b0;
            ram_sel_q   <= 1'b0;
            unmapped_q  <= 1'b0;
            was_read_q  <= 1'b0;
        end else if (data_req) begin
            uart_sel_q  <= uart_sel;
            timer_sel_q <= timer_sel;
            spi_sel_q   <= spi_sel;
            sha3_sel_q  <= sha3_sel;
            trng_sel_q  <= trng_sel;
            drbg_sel_q  <= drbg_sel;
            ntt_sel_q   <= ntt_sel;
            ram_sel_q   <= data_ram_sel;
            unmapped_q  <= !data_periph_sel && !data_crypto_sel && !data_ram_sel;
            was_read_q  <= !data_we;
        end else begin
            uart_sel_q  <= 1'b0;
            timer_sel_q <= 1'b0;
            spi_sel_q   <= 1'b0;
            sha3_sel_q  <= 1'b0;
            trng_sel_q  <= 1'b0;
            drbg_sel_q  <= 1'b0;
            ntt_sel_q   <= 1'b0;
            ram_sel_q   <= 1'b0;
            unmapped_q  <= 1'b0;
            was_read_q  <= 1'b0;
        end
    end

    reg data_req_q;
    always @(posedge clk) begin
        if (!rst_n) data_req_q <= 1'b0;
        else        data_req_q <= data_req;
    end

    always @(*) begin
        data_rvalid = data_req_q;
        data_err    = unmapped_q;
        if (uart_sel_q && was_read_q)
            data_rdata = uart_rdata;
        else if (timer_sel_q && was_read_q)
            data_rdata = timer_rdata;
        else if (sha3_sel_q && was_read_q)
            data_rdata = sha3_rdata;
        else if (trng_sel_q && was_read_q)
            data_rdata = trng_rdata;
        else if (drbg_sel_q && was_read_q)
            data_rdata = drbg_rdata;
        else if (ntt_sel_q && was_read_q)
            data_rdata = ntt_rdata;
        else if (ram_sel_q && was_read_q)
            data_rdata = ram_rdata;
        else if (spi_sel_q && was_read_q)
            data_rdata = 32'h0; // stub
        else
            data_rdata = 32'h0;
    end

    // Touch the ack signals so synth doesn't warn — they're not used in Phase 0
    // because we always rvalid one cycle after req.
    wire ack_unused = &{1'b0, uart_ack, timer_ack, sha3_ack, trng_ack, drbg_ack, ntt_ack};

    // ── LEDs ─────────────────────────────────────────────────────────────────
    // led[0]: heartbeat from timer IRQ (toggled in firmware via memory write)
    // led[1]: UART activity blink
    // led[2]: reserved
    // For Phase 0 hardware bring-up we drive a free-running heartbeat off the
    // 25 MHz clock so the board shows life even if firmware stalls.
    reg [23:0] heartbeat;
    always @(posedge clk) begin
        if (!rst_n) heartbeat <= 24'd0;
        else        heartbeat <= heartbeat + 24'd1;
    end
    always @(*) begin
        led[0] = heartbeat[23];     // ~1.5 Hz at 25 MHz
        led[1] = ~uart_tx;          // dim during idle (uart_tx idles high)
        led[2] = wdt_rst;           // pulse on watchdog timeout
    end

endmodule

`default_nettype wire
