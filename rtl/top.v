// quarc_top.v - Quarc SoC top-level
// Instantiates Ibex and the system bus. The bus instantiates all peripherals.
// Phase 0: Boot ROM + UART + timer functional. Other peripherals are stubs.

`default_nettype none
`timescale 1ns/1ps

module quarc_top (
    input  wire       clk_25mhz,
    input  wire       uart_rx,
    output wire       uart_tx,
    input  wire       spi_sck,
    input  wire       spi_mosi,
    output wire       spi_miso,
    input  wire       spi_cs_n,
    output wire [2:0] led
);

    // Clock and reset
    // Phase 0 uses 25 MHz directly; PLL boost to 50 MHz arrives in Phase 1+.
    wire clk = clk_25mhz;

    // Power-on reset: hold rst_n low for 32 cycles after configuration.
    reg [4:0] por_cnt = 5'd0;
    reg       rst_n   = 1'b0;
    always @(posedge clk) begin
        if (por_cnt != 5'd31) begin
            por_cnt <= por_cnt + 5'd1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // Ibex instruction bus
    wire        instr_req;
    wire [31:0] instr_addr;
    wire        instr_gnt;
    wire        instr_rvalid;
    wire [31:0] instr_rdata;

    // Ibex data bus
    wire        data_req;
    wire        data_we;
    wire [3:0]  data_be;
    wire [31:0] data_addr;
    wire [31:0] data_wdata;
    wire        data_gnt;
    wire        data_rvalid;
    wire [31:0] data_rdata;
    wire        data_err;

    // Interrupts
    wire        irq_timer;
    wire        irq_external;

    // Ibex core
    // After sv2v conversion, struct-typed ports become flat bit vectors:
    //   prim_ram_1p_pkg::ram_1p_cfg_t      -> [11:0]   (cfg_en, test, cfg[3:0]) x2
    //   prim_ram_1p_pkg::ram_1p_cfg_rsp_t  -> [0:0]
    //   ibex_mubi_t                        -> [3:0]    (IbexMuBiOn = 4'b0101)
    // Unused outputs are left unconnected.
    ibex_top u_ibex (
        .clk_i                     (clk),
        .rst_ni                    (rst_n),

        .test_en_i                 (1'b0),
        .scan_rst_ni               (1'b1),

        .ram_cfg_icache_tag_i      (12'b0),
        .ram_cfg_rsp_icache_tag_o  (),
        .ram_cfg_icache_data_i     (12'b0),
        .ram_cfg_rsp_icache_data_o (),

        .hart_id_i                 (32'h0000_0000),
        .boot_addr_i               (32'h0000_0000), // Boot from ROM at 0x0

        .instr_req_o               (instr_req),
        .instr_gnt_i               (instr_gnt),
        .instr_rvalid_i            (instr_rvalid),
        .instr_addr_o              (instr_addr),
        .instr_rdata_i             (instr_rdata),
        .instr_rdata_intg_i        (7'b0),
        .instr_err_i               (1'b0),

        .data_req_o                (data_req),
        .data_gnt_i                (data_gnt),
        .data_rvalid_i             (data_rvalid),
        .data_we_o                 (data_we),
        .data_be_o                 (data_be),
        .data_addr_o               (data_addr),
        .data_wdata_o              (data_wdata),
        .data_wdata_intg_o         (),
        .data_rdata_i              (data_rdata),
        .data_rdata_intg_i         (7'b0),
        .data_err_i                (data_err),

        .irq_software_i            (1'b0),
        .irq_timer_i               (irq_timer),
        .irq_external_i            (irq_external),
        .irq_fast_i                (15'b0),
        .irq_nm_i                  (1'b0),

        .scramble_key_valid_i      (1'b0),
        .scramble_key_i            (128'b0),
        .scramble_nonce_i          (64'b0),
        .scramble_req_o            (),

        .debug_req_i               (1'b0),
        .crash_dump_o              (),
        .double_fault_seen_o       (),

        .fetch_enable_i            (4'b0101), // IbexMuBiOn
        .alert_minor_o             (),
        .alert_major_internal_o    (),
        .alert_major_bus_o         (),
        .core_sleep_o              (),

        .lockstep_cmp_en_o         (),

        .data_req_shadow_o         (),
        .data_we_shadow_o          (),
        .data_be_shadow_o          (),
        .data_addr_shadow_o        (),
        .data_wdata_shadow_o       (),
        .data_wdata_intg_shadow_o  (),
        .instr_req_shadow_o        (),
        .instr_addr_shadow_o       ()
    );

    // System bus + peripherals
    quarc_bus u_bus (
        .clk          (clk),
        .rst_n        (rst_n),
        // Ibex instruction port
        .instr_req    (instr_req),
        .instr_addr   (instr_addr),
        .instr_gnt    (instr_gnt),
        .instr_rvalid (instr_rvalid),
        .instr_rdata  (instr_rdata),
        // Ibex data port
        .data_req     (data_req),
        .data_we      (data_we),
        .data_be      (data_be),
        .data_addr    (data_addr),
        .data_wdata   (data_wdata),
        .data_gnt     (data_gnt),
        .data_rvalid  (data_rvalid),
        .data_rdata   (data_rdata),
        .data_err     (data_err),
        // Interrupts back to Ibex
        .irq_timer    (irq_timer),
        .irq_external (irq_external),
        // External pins
        .uart_tx      (uart_tx),
        .uart_rx      (uart_rx),
        .spi_sck      (spi_sck),
        .spi_mosi     (spi_mosi),
        .spi_miso     (spi_miso),
        .spi_cs_n     (spi_cs_n),
        .led          (led)
    );

endmodule

`default_nettype wire
