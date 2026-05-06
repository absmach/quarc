// uart.v - 8N1 UART transmitter and receiver
// Base address: 0x2000_0100
//
// Registers (8-bit local offset):
//   0x00  TX_DATA   WO  write byte to transmit
//   0x04  STATUS    RO  [0]=tx_busy [1]=rx_ready [2]=rx_overflow
//   0x08  RX_DATA   RO  read received byte (clears rx_ready)
//   0x0C  BAUD_DIV  WO  baud rate divisor (clk_freq / baud_rate)
//                       default: 25_000_000 / 115_200 = 217

`default_nettype none
`timescale 1ns/1ps

module uart #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer BAUD_RATE = 115_200
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

    // Pins
    output reg         uart_tx,
    input  wire        uart_rx,

    // RX-byte-ready interrupt
    output wire        irq_rx
);

    localparam integer DEFAULT_DIV = CLK_FREQ / BAUD_RATE;

    // ── Programmable baud divisor ────────────────────────────────────────────
    reg [15:0] baud_div;

    // ── Transmit FSM ─────────────────────────────────────────────────────────
    // States: idle -> start -> 8 data bits -> stop -> idle.
    // Implemented as a counter from 0..9 (start=0, data=1..8, stop=9).
    reg        tx_busy;
    reg [3:0]  tx_phase;     // 0..9, 10 = done
    reg [9:0]  tx_shift;     // {stop=1, data[7:0], start=0}
    reg [15:0] tx_baud_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            uart_tx     <= 1'b1;
            tx_busy     <= 1'b0;
            tx_phase    <= 4'd10;
            tx_shift    <= 10'h3FF;
            tx_baud_cnt <= 16'd0;
        end else begin
            if (!tx_busy) begin
                uart_tx <= 1'b1;
                if (bus_req && bus_we && bus_addr[7:0] == 8'h00) begin
                    tx_shift    <= {1'b1, bus_wdata[7:0], 1'b0};
                    tx_phase    <= 4'd0;
                    tx_baud_cnt <= baud_div - 16'd1;
                    tx_busy     <= 1'b1;
                    uart_tx     <= 1'b0; // start bit
                end
            end else begin
                if (tx_baud_cnt == 16'd0) begin
                    tx_baud_cnt <= baud_div - 16'd1;
                    tx_phase    <= tx_phase + 4'd1;
                    if (tx_phase == 4'd9) begin
                        tx_busy <= 1'b0;
                        uart_tx <= 1'b1;
                    end else begin
                        tx_shift <= {1'b1, tx_shift[9:1]};
                        uart_tx  <= tx_shift[1];
                    end
                end else begin
                    tx_baud_cnt <= tx_baud_cnt - 16'd1;
                end
            end
        end
    end

    // ── Receive FSM ──────────────────────────────────────────────────────────
    // Synchronise RX line, then sample at mid-bit (baud_div/2 offset).
    reg rx_sync_0, rx_sync_1;
    always @(posedge clk) begin
        if (!rst_n) {rx_sync_1, rx_sync_0} <= 2'b11;
        else        {rx_sync_1, rx_sync_0} <= {rx_sync_0, uart_rx};
    end
    wire rx_in = rx_sync_1;

    reg        rx_busy;
    reg [3:0]  rx_phase;     // 0=start sample, 1..8=data, 9=stop, 10=done
    reg [7:0]  rx_shift;
    reg [15:0] rx_baud_cnt;
    reg [7:0]  rx_data;
    reg        rx_ready;
    reg        rx_overflow;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_busy     <= 1'b0;
            rx_phase    <= 4'd0;
            rx_shift    <= 8'h0;
            rx_baud_cnt <= 16'd0;
            rx_data     <= 8'h0;
            rx_ready    <= 1'b0;
            rx_overflow <= 1'b0;
        end else begin
            // rx_ready cleared by reading RX_DATA
            if (bus_req && !bus_we && bus_addr[7:0] == 8'h08) begin
                rx_ready <= 1'b0;
            end

            if (!rx_busy) begin
                if (!rx_in) begin
                    // Start bit detected; sample at mid-bit
                    rx_busy     <= 1'b1;
                    rx_phase    <= 4'd0;
                    rx_baud_cnt <= (baud_div >> 1) - 16'd1;
                end
            end else begin
                if (rx_baud_cnt == 16'd0) begin
                    rx_baud_cnt <= baud_div - 16'd1;
                    if (rx_phase == 4'd0) begin
                        // Mid of start bit; verify it's still low
                        if (rx_in) begin
                            rx_busy <= 1'b0; // false start
                        end else begin
                            rx_phase <= 4'd1;
                        end
                    end else if (rx_phase <= 4'd8) begin
                        rx_shift <= {rx_in, rx_shift[7:1]};
                        rx_phase <= rx_phase + 4'd1;
                    end else begin
                        // Stop bit
                        if (rx_in) begin
                            // Frame OK
                            rx_data <= rx_shift;
                            if (rx_ready)
                                rx_overflow <= 1'b1;
                            rx_ready <= 1'b1;
                        end
                        rx_busy <= 1'b0;
                    end
                end else begin
                    rx_baud_cnt <= rx_baud_cnt - 16'd1;
                end
            end
        end
    end

    assign irq_rx = rx_ready;

    // ── Bus interface ────────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (!rst_n) begin
            baud_div <= DEFAULT_DIV[15:0];
        end else if (bus_req && bus_we) begin
            case (bus_addr[7:0])
                8'h0C: baud_div <= bus_wdata[15:0];
                default: ;
            endcase
        end
    end

    always @(*) begin
        bus_ack   = bus_req;
        bus_rdata = 32'h0;
        case (bus_addr[7:0])
            8'h04: bus_rdata = {29'b0, rx_overflow, rx_ready, tx_busy};
            8'h08: bus_rdata = {24'b0, rx_data};
            8'h0C: bus_rdata = {16'b0, baud_div};
            default: bus_rdata = 32'h0;
        endcase
    end

endmodule

`default_nettype wire
