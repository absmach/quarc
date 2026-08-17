// tb_keccak.sv - Keccak-f[1600] permutation testbench
//
// Applies known input states and checks that `done` pulses exactly 24 cycles
// after `start` and that `state_out` matches reference vectors in kat/.
//
// `start`/`state_in` are driven on the clock NEGedge so they are stable when
// the DUT samples on the following posedge (race-free in Icarus). The round
// count is measured as the number of clock edges while the DUT is busy, which
// is immune to edge-alignment ambiguity.

`timescale 1ns/1ps

module tb_keccak;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg            rst_n;
    reg            start;
    reg  [1599:0]  state_in;
    wire [1599:0]  state_out;
    wire           done;

    keccak_f1600 dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .state_in (state_in),
        .state_out(state_out),
        .done     (done)
    );

    // Reference vectors from kat/
    reg [1599:0] vec_zero_out [0:0];   // permute(0)
    reg [1599:0] vec_count [0:1];      // permute(lane[i]=i): [0]=input, [1]=output

    integer failures = 0;
    integer cyc;

    initial begin
        $dumpfile("build/tb_keccak.vcd");
        $dumpvars(0, tb_keccak);

        rst_n = 1'b0;
        start = 1'b0;
        state_in = 1600'b0;

        #20 rst_n = 1'b1;
        repeat (2) @(posedge clk);   // settle past the post-reset edge

        $readmemh("kat/keccak_f1600_zero.dat",  vec_zero_out);
        $readmemh("kat/keccak_f1600_count.dat", vec_count);

        // ------------------------------------------------------------------
        // Test 1: all-zero state -> vec_zero_out[0]
        // ------------------------------------------------------------------
        @(negedge clk);
        state_in = 1600'b0;
        start    = 1'b1;
        @(negedge clk);
        start    = 1'b0;

        cyc = 0;
        while (!done) begin
            @(posedge clk);
            if (dut.busy) cyc = cyc + 1;   // count busy (round) edges
            if (cyc > 30) begin
                $display("[%0t] FAIL (test 1): timeout waiting for done", $time);
                failures = failures + 1;
                break;
            end
        end
        if (cyc != 24) begin
            $display("[%0t] FAIL (test 1): done after %0d rounds, expected 24", $time, cyc);
            failures = failures + 1;
        end
        if (state_out !== vec_zero_out[0]) begin
            $display("[%0t] FAIL (test 1): state_out mismatch", $time);
            $display("  got  %h", state_out);
            $display("  want %h", vec_zero_out[0]);
            failures = failures + 1;
        end else begin
            $display("[%0t] PASS (test 1): permute(0) matches, %0d rounds", $time, cyc);
        end
        @(posedge clk);
        if (done !== 1'b0) begin
            $display("[%0t] FAIL (test 1): done did not deassert", $time);
            failures = failures + 1;
        end

        // ------------------------------------------------------------------
        // Test 2: lane[i] = i -> vec_count[1]
        // ------------------------------------------------------------------
        @(negedge clk);
        state_in = vec_count[0];
        start    = 1'b1;
        @(negedge clk);
        start    = 1'b0;

        cyc = 0;
        while (!done) begin
            @(posedge clk);
            if (dut.busy) cyc = cyc + 1;
            if (cyc > 30) begin
                $display("[%0t] FAIL (test 2): timeout waiting for done", $time);
                failures = failures + 1;
                break;
            end
        end
        if (cyc != 24) begin
            $display("[%0t] FAIL (test 2): done after %0d rounds, expected 24", $time, cyc);
            failures = failures + 1;
        end
        if (state_out !== vec_count[1]) begin
            $display("[%0t] FAIL (test 2): state_out mismatch", $time);
            $display("  got  %h", state_out);
            $display("  want %h", vec_count[1]);
            failures = failures + 1;
        end else begin
            $display("[%0t] PASS (test 2): permute(lane=i) matches, %0d rounds", $time, cyc);
        end
        @(posedge clk);
        if (done !== 1'b0) begin
            $display("[%0t] FAIL (test 2): done did not deassert", $time);
            failures = failures + 1;
        end

        #10;
        if (failures == 0)
            $display("PASS: 2/2 Keccak-f[1600] tests passed");
        else
            $display("FAIL: %0d Keccak-f[1600] checks failed", failures);
        $finish;
    end

endmodule
