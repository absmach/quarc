// rollback.v - Monotonic anti-rollback counter
// STUB: full implementation lands in Phase 6. v1 is BRAM-backed (loses
// state on power cycle); OTP backing arrives in v2.

`default_nettype none
`timescale 1ns/1ps

module rollback (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    input  wire        increment
);

    reg [31:0] counter;
    reg [31:0] fw_version;

    always @(posedge clk) begin
        if (!rst_n) begin
            counter    <= 32'd0;
            fw_version <= 32'd0;
        end else if (increment) begin
            counter <= counter + 32'd1;
        end
    end

    always @(*) begin
        bus_rdata = 32'h0;
        bus_ack   = bus_req;
        case (bus_addr[7:0])
            8'h00: bus_rdata = counter;
            8'h04: bus_rdata = fw_version;
            default: bus_rdata = 32'h0;
        endcase
    end

    wire unused = &{1'b0, bus_we, bus_wdata};

endmodule

`default_nettype wire
