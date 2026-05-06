// spi_slave.v - SPI slave to host MCU (mode 0, 8 MHz max in v1)
// STUB: full implementation lands in Phase 7.

`default_nettype none
`timescale 1ns/1ps

module spi_slave (
    input  wire        clk,
    input  wire        rst_n,
    // Bus
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    // Pins
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,
    input  wire        spi_cs_n,
    // Interrupt
    output wire        irq_rx
);

    assign spi_miso = 1'b0;
    assign irq_rx   = 1'b0;

    always @(*) begin
        bus_rdata = 32'h0;
        bus_ack   = bus_req;
    end

    wire unused = &{1'b0, rst_n, bus_we, bus_addr, bus_wdata,
                    spi_sck, spi_mosi, spi_cs_n};

endmodule

`default_nettype wire
