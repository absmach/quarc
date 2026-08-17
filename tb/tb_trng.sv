// tb_trng.sv - TRNG health-test testbench
//
// Samples every clock (SAMPLE_DIV=1) so the testbench controls each raw bit:
// 1) RCT: a stuck bit for >=13 samples -> rct_fail + health_fail.
// 2) APT: a 90%-biased stream (9 ones / 1 zero) -> apt_fail + health_fail.
// 3) Normal (balanced) operation -> no health_fail, 32-bit words accumulate.

`timescale 1ns/1ps

module tb_trng;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        bus_req, bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ack, irq_health;

    reg        inject_en_i, inject_bit_i;

    trng #(.SAMPLE_DIV(7'd1)) dut (
        .clk(clk), .rst_n(rst_n),
        .bus_req(bus_req), .bus_we(bus_we),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack), .irq_health(irq_health),
        .inject_en_i(inject_en_i), .inject_bit_i(inject_bit_i)
    );

    integer failures = 0;

    task bus_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            bus_req = 1'b1; bus_we = 1'b1;
            bus_addr = addr; bus_wdata = data;
            @(negedge clk);
            bus_req = 1'b0; bus_we = 1'b0;
        end
    endtask

    task bus_read;
        input  [7:0]  addr;
        output [31:0] val;
        begin
            @(negedge clk);
            bus_req = 1'b1; bus_we = 1'b0; bus_addr = addr;
            @(posedge clk);
            val = bus_rdata;
            @(negedge clk);
            bus_req = 1'b0;
        end
    endtask

    // polls STATUS until bit `idx` == `want`; returns 1 on success
    task wait_health_bit;
        input [1:0] idx;
        input       want;
        output      ok;
        reg [31:0] st;
        integer t;
        begin
            ok = 1'b0;
            t = 0;
            repeat (100000) begin
                bus_read(8'h04, st);
                if (st[idx] == want) begin
                    ok = 1'b1;
                    return;
                end
                t = t + 1;
            end
            $display("[%0t] FAIL: timeout waiting STATUS[%0d]=%0d", $time, idx, want);
            failures = failures + 1;
        end
    endtask

    task reset_chip;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            inject_en_i = 1'b0;
            inject_bit_i = 1'b0;
            bus_write(8'h00, 32'h1);   // enable
        end
    endtask

    initial begin
        integer i;
        reg ok;
        $dumpfile("build/tb_trng.vcd");
        $dumpvars(0, tb_trng);

        rst_n = 1'b0;
        bus_req = 1'b0; bus_we = 1'b0; bus_addr = 8'h0; bus_wdata = 32'h0;
        inject_en_i = 1'b0; inject_bit_i = 1'b0;
        #20 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        // Test 1: RCT - stuck bit for >=13 samples
        // ------------------------------------------------------------------
        bus_write(8'h00, 32'h1);   // enable
        inject_en_i  = 1'b1;
        inject_bit_i = 1'b1;
        wait_health_bit(2, 1'b1, ok);   // STATUS[2] = rct_fail
        if (ok && irq_health === 1'b1) begin
            $display("[%0t] PASS (RCT): rct_fail + irq on stuck bit", $time);
        end else begin
            $display("[%0t] FAIL (RCT): rct_fail/irq not observed", $time);
            failures = failures + 1;
        end

        // ------------------------------------------------------------------
        // Test 2: APT - 90% biased stream (9 ones / 1 zero), runs < 13
        // ------------------------------------------------------------------
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        inject_en_i  = 1'b0;
        inject_bit_i = 1'b0;
        // Inject a '1' BEFORE enabling so the APT reference bit is 1; the
        // 9-ones/1-zero pattern then gives ~90% ones, exceeding the cutoff.
        inject_en_i  = 1'b1;
        inject_bit_i = 1'b1;
        bus_write(8'h00, 32'h1);   // enable (re-asserted after reset)
        for (i = 0; i < 700; i = i + 1) begin
            @(posedge clk);
            inject_bit_i = (i % 10 < 9) ? 1'b1 : 1'b0;
        end
        inject_en_i = 1'b0;        // stop injecting so no post-loop stuck run
        wait_health_bit(3, 1'b1, ok);   // STATUS[3] = apt_fail
        if (ok) begin
            $display("[%0t] PASS (APT): apt_fail on biased stream", $time);
        end else begin
            $display("[%0t] FAIL (APT): apt_fail not observed", $time);
            failures = failures + 1;
        end

        // ------------------------------------------------------------------
        // Test 3: normal (balanced) operation -> no health_fail, word ready
        // ------------------------------------------------------------------
        reset_chip;
        // sim source = balanced toggle (inject disabled)
        wait_health_bit(0, 1'b1, ok);   // STATUS[0] = ready (32-bit word)
        if (!ok) begin
            $display("[%0t] FAIL (normal): word never became ready", $time);
            failures = failures + 1;
        end else begin
            begin : check_health
                reg [31:0] st;
                bus_read(8'h04, st);
                if (st[1] === 1'b1) begin
                    $display("[%0t] FAIL (normal): health_fail asserted without fault", $time);
                    failures = failures + 1;
                end else begin
                    $display("[%0t] PASS (normal): no health_fail, word ready", $time);
                end
            end
        end

        #10;
        if (failures == 0)
            $display("PASS: TRNG health tests passed");
        else
            $display("FAIL: %0d TRNG checks failed", failures);
        $finish;
    end

endmodule
