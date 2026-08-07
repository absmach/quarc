// tb_keccak_c2.sv - Keccak engine 3-client arbitration test
//
// Requests a permutation from all three clients (SHA-3, DRBG, ML-KEM) with
// the same input state and checks each receives the correct 24-round output.

`timescale 1ns/1ps

module tb_keccak_c2;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        c0_req, c1_req, c2_req, c3_req;
    reg [1599:0] c0_in, c1_in, c2_in, c3_in;
    wire       c0_done, c1_done, c2_done, c3_done;
    wire [1599:0] c0_out, c1_out, c2_out, c3_out;

    keccak_engine dut (
        .clk(clk), .rst_n(rst_n),
        .c0_req(c0_req), .c0_state_in(c0_in), .c0_done(c0_done), .c0_state_out(c0_out),
        .c1_req(c1_req), .c1_state_in(c1_in), .c1_done(c1_done), .c1_state_out(c1_out),
        .c2_req(c2_req), .c2_state_in(c2_in), .c2_done(c2_done), .c2_state_out(c2_out),
        .c3_req(c3_req), .c3_state_in(c3_in), .c3_done(c3_done), .c3_state_out(c3_out)
    );

    reg [1599:0] state;
    reg [1599:0] exp_val;
    integer i, w;
    integer failures = 0;

    task load_kats;
        begin
            state  = 1600'b0;
            exp_val = 1600'heaf1ff7b5ceca24975f644e97f30a13b16f53526e70465c21841f924a2c509e4940c7922ae3a26148c3ee88a1ccf32c8b87c5a554fd00ecb613670957bc4661164befef28cc970f205e5635a21d9ae6101f22f1a11a5569f43b831cd0347c82681a57c16dbcf555fa9a6e6260d712103eb5aa93f2317d63530935ab7d08ffc64ad30a6f71b19059c8c5bda0cd6192e7690fee5a0a44647c4ff97a42d7f8e6fd48b284e056253d057bd1547306f80494dd598261ea65aa9ee84d5ccf933c0478af1258f7940e1dde7;
        end
    endtask

    initial begin
        $dumpfile("build/tb_keccak_c2.vcd");
        $dumpvars(0, tb_keccak_c2);
        c0_req = 0; c1_req = 0; c2_req = 0; c3_req = 0;
        c0_in = 1600'b0; c1_in = 1600'b0; c2_in = 1600'b0; c3_in = 1600'b0;
        rst_n = 0;
        #20; rst_n = 1;
        #20;

        load_kats;

        // pulse all four requests across a posedge so the engine latches them
        c0_req = 1; c1_req = 1; c2_req = 1; c3_req = 1;
        c0_in = state; c1_in = state; c2_in = state; c3_in = state;
        @(posedge clk);
        @(negedge clk);
        c0_req = 0; c1_req = 0; c2_req = 0; c3_req = 0;

        // wait for the last client (c3) to finish
        i = 0;
        while (!c3_done && i < 1000) begin
            @(posedge clk);
            i = i + 1;
        end
        @(posedge clk);

        if (c0_out === exp_val) $display("PASS: c0 output matches");
        else begin $display("FAIL: c0 output mismatch"); failures = failures + 1; end
        if (c1_out === exp_val) $display("PASS: c1 output matches");
        else begin $display("FAIL: c1 output mismatch"); failures = failures + 1; end
        if (c2_out === exp_val) $display("PASS: c2 output matches");
        else begin $display("FAIL: c2 output mismatch"); failures = failures + 1; end
        if (c3_out === exp_val) $display("PASS: c3 output matches");
        else begin $display("FAIL: c3 output mismatch"); failures = failures + 1; end

        if (failures == 0) $display("PASS: all 4 clients permuted correctly");
        else $display("FAIL: %0d client(s) mismatched", failures);
        $finish;
    end

endmodule
