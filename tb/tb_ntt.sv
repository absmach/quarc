// tb_ntt.sv - ML-KEM NTT engine testbench
//
// Loads reference polynomials from kat/, runs forward/inverse NTT and
// basemul through the engine MMIO, and checks each output coefficient.

`timescale 1ns/1ps

module tb_ntt;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        bus_req, bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ack, irq_done;

    ntt dut (
        .clk(clk), .rst_n(rst_n),
        .bus_req(bus_req), .bus_we(bus_we),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack),
        .c_req(1'b0), .c_we(1'b0), .c_addr(8'h0), .c_wdata(32'h0),
        .c_rdata(), .c_ack(), .irq_done(irq_done)
    );

    integer failures = 0;
    integer tests    = 0;

    reg [11:0] poly_a [0:255];
    reg [11:0] poly_b [0:255];
    reg [11:0] expo   [0:255];
    reg [11:0] got    [0:255];

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
            @(negedge clk);
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
                bus_read(8'h04, st);
                if (st[1] == 1'b1) return;   // done
                t = t + 1;
            end
            $display("[%0t] FAIL: timeout waiting NTT done", $time);
            failures = failures + 1;
        end
    endtask

    task load_poly;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1)
                bus_write(8'h08, {20'h0, poly_a[i]});
        end
    endtask

    task load_poly_hi;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1)
                bus_write(8'h08, {20'h0, poly_b[i]});
        end
    endtask

    task run_op;
        input [2:0] op;
        begin
            bus_write(8'h00, {29'b0, op});                    // set op (go=0)
            bus_write(8'h00, {27'b0, 1'b1, 1'b0, op});         // go [4]
            wait_done;
        end
    endtask

    task read_result;
        reg [31:0] v;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                bus_read(8'h08, v);
                got[i] = v[11:0];
            end
        end
    endtask

    task check_result;
        input [31:0] tag;
        integer i, mism;
        begin
            tests = tests + 1;
            mism = 0;
            for (i = 0; i < 256; i = i + 1) begin
                if (got[i] !== expo[i]) begin
                    if (mism < 5)
                        $display("[%0t] FAIL %0d: coeff %0d got %03x want %03x",
                                 $time, tag, i, got[i], expo[i]);
                    mism = mism + 1;
                end
            end
            if (mism == 0) begin
                $display("[%0t] PASS (%0d): all 256 coefficients match", $time, tag);
            end else begin
                $display("[%0t] FAIL (%0d): %0d/256 coefficients mismatch", $time, tag, mism);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_ntt.vcd");
        $dumpvars(0, tb_ntt);

        rst_n = 1'b0;
        bus_req = 1'b0; bus_we = 1'b0; bus_addr = 8'h0; bus_wdata = 32'h0;
        #20;
        rst_n = 1'b1;
        #20;

        $readmemh("kat/ntt_in1.txt", poly_a);
        $readmemh("kat/ntt_in2.txt", poly_b);
        $readmemh("kat/ntt_fwd1.txt", expo);

        // ---- forward NTT of poly 1
        load_poly;
        run_op(3'd1);
        read_result;
        check_result(1);

        // ---- forward NTT of poly 2
        $readmemh("kat/ntt_in2.txt", poly_a);
        $readmemh("kat/ntt_fwd2.txt", expo);
        load_poly;
        run_op(3'd1);
        read_result;
        check_result(2);

        // ---- inverse NTT of fwd1 should give back poly 1
        $readmemh("kat/ntt_fwd1.txt", poly_a);
        $readmemh("kat/ntt_in1.txt", expo);
        load_poly;
        run_op(3'd2);
        read_result;
        check_result(3);

        // ---- basemul(fwd1, fwd2) -> mul.txt
        $readmemh("kat/ntt_fwd1.txt", poly_a);
        $readmemh("kat/ntt_fwd2.txt", poly_b);
        $readmemh("kat/ntt_mul.txt", expo);
        load_poly;
        load_poly_hi;
        run_op(3'd3);
        read_result;
        check_result(4);

        $display("------------------------------------------------");
        if (failures == 0)
            $display("PASS: %0d/4 NTT test groups passed", tests);
        else
            $display("FAIL: %0d of %0d NTT test groups failed", failures, tests);
        $finish;
    end

endmodule
