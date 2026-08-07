// tb_drbg.sv - SHAKE-256 DRBG testbench
//
// Drives the DRBG MMIO through a reseed / generate sequence and checks the
// output words against the reference vectors in kat/drbg.txt.

`timescale 1ns/1ps

module tb_drbg;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        bus_req, bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ack, irq_done;

    drbg dut (
        .clk(clk), .rst_n(rst_n),
        .bus_req(bus_req), .bus_we(bus_we),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack), .irq_done(irq_done)
    );

    integer failures = 0;
    integer tests    = 0;

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
            @(posedge clk);       // DUT latches registered reads here
            @(negedge clk);       // bus_rdata reflects the latched value
            val = bus_rdata;
            bus_req = 1'b0;
        end
    endtask

    task wait_done;
        reg [31:0] st;
        integer t;
        begin
            t = 0;
            repeat (200000) begin
                bus_read(8'h24, st);
                if (st[1] == 1'b1) return;   // done
                t = t + 1;
            end
            $display("[%0t] FAIL: timeout waiting DRBG done", $time);
            failures = failures + 1;
        end
    endtask

    task reseed_entropy;
        input [31:0] e0, e1, e2, e3, e4, e5, e6, e7;
        begin
            bus_write(8'h34, e0);
            bus_write(8'h34, e1);
            bus_write(8'h34, e2);
            bus_write(8'h34, e3);
            bus_write(8'h34, e4);
            bus_write(8'h34, e5);
            bus_write(8'h34, e6);
            bus_write(8'h34, e7);
            bus_write(8'h20, 32'h2);   // reseed

            wait_done;
        end
    endtask

    task check_gen;
        input [15:0] nbytes;
        input [31:0] w0, w1, w2, w3, w4, w5, w6, w7,
                     w8, w9, w10, w11, w12, w13, w14, w15;
        reg [31:0] exp [0:15];
        reg [31:0] rdata;
        integer i, nw, mism;
        begin
            tests = tests + 1;
            mism = 0;
            exp[0]=w0; exp[1]=w1; exp[2]=w2; exp[3]=w3;
            exp[4]=w4; exp[5]=w5; exp[6]=w6; exp[7]=w7;
            exp[8]=w8; exp[9]=w9; exp[10]=w10; exp[11]=w11;
            exp[12]=w12; exp[13]=w13; exp[14]=w14; exp[15]=w15;
            nw = (nbytes + 3) / 4;

            bus_write(8'h20, {16'h0, nbytes[7:0], 7'b0, 1'b1});  // generate + byte_count
            wait_done;

            for (i = 0; i < nw; i = i + 1) begin
                bus_read(8'h28, rdata);
                if (rdata !== exp[i]) begin
                    mism = mism + 1;
                    $display("[%0t] FAIL: word %0d got %08h want %08h", $time, i, rdata, exp[i]);
                end
            end
            if (mism == 0) begin
                $display("[%0t] PASS (generate %0d bytes): output matches", $time, nbytes);
            end else begin
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_drbg.vcd");
        $dumpvars(0, tb_drbg);

        rst_n = 1'b0;
        bus_req = 1'b0; bus_we = 1'b0; bus_addr = 8'h0; bus_wdata = 32'h0;
        #20 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // seed with entropy E1
        reseed_entropy(32'h17ba5d00, 32'h8b2ed174, 32'hffa245e8, 32'h7316b95c,
                       32'he78a2dd0, 32'h5bfea144, 32'hcf7215b8, 32'h43e6892c);

        // generate 32 bytes
        check_gen(16'd32,
                  32'hc50f1205, 32'h0a010221, 32'h0fcb13e7, 32'hc9d8216e,
                  32'ha74f8c8f, 32'h692c41f5, 32'he9ec9922, 32'h9676d730,
                  32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0);

        // generate 16 bytes
        check_gen(16'd16,
                  32'h27bfaf20, 32'h7e851ee3, 32'h22ecc062, 32'h4fc178dc,
                  32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0,
                  32'h0, 32'h0, 32'h0, 32'h0);

        // reseed with entropy E2
        reseed_entropy(32'hf54ea700, 32'h91ea439c, 32'h2d86df38, 32'hc9227bd4,
                       32'h65be1770, 32'h015ab30c, 32'h9df64fa8, 32'h3992eb44);

        // generate 64 bytes
        check_gen(16'd64,
                  32'h3f4fd600, 32'h638ba3e2, 32'ha4667406, 32'h74133a84,
                  32'h2ac263f8, 32'hf78e91c7, 32'h50df1f93, 32'he544cb24,
                  32'h322c713d, 32'h26b2eaf6, 32'h61ee83c7, 32'h6a02f5f4,
                  32'hdf56692a, 32'h02b24159, 32'h40f66164, 32'h203c1aa9);

        // generate 32 bytes
        check_gen(16'd32,
                  32'hb76affd0, 32'h8d198fc5, 32'h87c3932b, 32'hb685bc35,
                  32'hc8e45472, 32'h80f4fa0e, 32'h8f03aa38, 32'h38ad5c4a,
                  32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0);

        #10;
        if (failures == 0)
            $display("PASS: %0d/%0d DRBG tests passed", tests, tests);
        else
            $display("FAIL: %0d DRBG checks failed", failures);
        $finish;
    end

endmodule
