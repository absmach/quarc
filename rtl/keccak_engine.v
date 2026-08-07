// keccak_engine.v - shared Keccak-f[1600] permutation engine
//
// One keccak_f1600 instance, arbitrated between four clients (client 0 gets
// highest priority, then clients 1, 2, 3). Each client pulses `req`
// with the state to permute; the engine latches it, runs the 24-round
// permutation and pulses `done` with the result. Clients must hold their
// request until done.

`default_nettype none
`timescale 1ns/1ps

module keccak_engine (
    input  wire clk,
    input  wire rst_n,

    // client 0 (SHA-3)
    input  wire            c0_req,
    input  wire [1599:0]   c0_state_in,
    output reg             c0_done,
    output reg  [1599:0]   c0_state_out,

    // client 1 (DRBG)
    input  wire            c1_req,
    input  wire [1599:0]   c1_state_in,
    output reg             c1_done,
    output reg  [1599:0]   c1_state_out,

    // client 2 (ML-KEM sampling)
    input  wire            c2_req,
    input  wire [1599:0]   c2_state_in,
    output reg             c2_done,
    output reg  [1599:0]   c2_state_out,

    // client 3 (ML-KEM hashing)
    input  wire            c3_req,
    input  wire [1599:0]   c3_state_in,
    output reg             c3_done,
    output reg  [1599:0]   c3_state_out
);

    reg               busy;
    reg [1:0]         active;        // 0 = client 0, 1 = client 1, 2 = client 2, 3 = client 3
    reg               c0_pending;
    reg               c1_pending;
    reg               c2_pending;
    reg               c3_pending;
    reg [1599:0]      c0_cap;
    reg [1599:0]      c1_cap;
    reg [1599:0]      c2_cap;
    reg [1599:0]      c3_cap;

    reg               perm_start;
    reg [1599:0]      perm_state;
    wire              perm_done;
    wire [1599:0]     perm_out;

    keccak_f1600 u_keccak (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (perm_start),
        .state_in (perm_state),
        .state_out(perm_out),
        .done     (perm_done)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            active     <= 2'b0;
            c0_pending <= 1'b0;
            c1_pending <= 1'b0;
            c2_pending <= 1'b0;
            c3_pending <= 1'b0;
            c0_cap     <= 1600'b0;
            c1_cap     <= 1600'b0;
            c2_cap     <= 1600'b0;
            c3_cap     <= 1600'b0;
            perm_start <= 1'b0;
            perm_state <= 1600'b0;
            c0_done    <= 1'b0;
            c1_done    <= 1'b0;
            c2_done    <= 1'b0;
            c3_done    <= 1'b0;
            c0_state_out <= 1600'b0;
            c1_state_out <= 1600'b0;
            c2_state_out <= 1600'b0;
            c3_state_out <= 1600'b0;
        end else begin
            // default: clear done pulses and the one-cycle start pulse
            c0_done    <= 1'b0;
            c1_done    <= 1'b0;
            c2_done    <= 1'b0;
            c3_done    <= 1'b0;
            perm_start <= 1'b0;

            // latch requests and capture state at the request edge
            if (c0_req) begin
                c0_pending <= 1'b1;
                c0_cap     <= c0_state_in;
            end
            if (c1_req) begin
                c1_pending <= 1'b1;
                c1_cap     <= c1_state_in;
            end
            if (c2_req) begin
                c2_pending <= 1'b1;
                c2_cap     <= c2_state_in;
            end
            if (c3_req) begin
                c3_pending <= 1'b1;
                c3_cap     <= c3_state_in;
            end

            if (!busy) begin
                if (c0_pending) begin
                    active     <= 2'b00;
                    busy       <= 1'b1;
                    perm_state <= c0_cap;
                    perm_start <= 1'b1;
                    c0_pending <= 1'b0;
                end else if (c1_pending) begin
                    active     <= 2'b01;
                    busy       <= 1'b1;
                    perm_state <= c1_cap;
                    perm_start <= 1'b1;
                    c1_pending <= 1'b0;
                end else if (c2_pending) begin
                    active     <= 2'b10;
                    busy       <= 1'b1;
                    perm_state <= c2_cap;
                    perm_start <= 1'b1;
                    c2_pending <= 1'b0;
                end else if (c3_pending) begin
                    active     <= 2'b11;
                    busy       <= 1'b1;
                    perm_state <= c3_cap;
                    perm_start <= 1'b1;
                    c3_pending <= 1'b0;
                end
            end else if (perm_done) begin
                busy       <= 1'b0;
                if (active == 2'b00) begin
                    c0_done      <= 1'b1;
                    c0_state_out <= perm_out;
                end else if (active == 2'b01) begin
                    c1_done      <= 1'b1;
                    c1_state_out <= perm_out;
                end else if (active == 2'b10) begin
                    c2_done      <= 1'b1;
                    c2_state_out <= perm_out;
                end else begin
                    c3_done      <= 1'b1;
                    c3_state_out <= perm_out;
                end
            end
        end
    end

endmodule

`default_nettype wire
