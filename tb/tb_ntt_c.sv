// tb_ntt_c.sv - NTT client-port test
//
// Drives the NTT engine entirely through the client port (c_*), the path the
// ML-KEM controller will use: stream coefficients in, run forward NTT, poll
// STATUS, stream results out, compare against the reference KAT.

`timescale 1ns/1ps

module tb_ntt_c;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        bus_req, bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ack;

    reg        c_req, c_we;
    reg [7:0]  c_addr;
    reg [31:0] c_wdata;
    wire [31:0] c_rdata;
    wire        c_ack, irq_done;

    ntt dut (
        .clk(clk), .rst_n(rst_n),
        .bus_req(bus_req), .bus_we(bus_we),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack),
        .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata),
        .c_rdata(c_rdata), .c_ack(c_ack), .irq_done(irq_done)
    );

    integer failures = 0;
    integer tests    = 0;

    reg [11:0] poly_a [0:255];
    reg [11:0] expo   [0:255];
    reg [11:0] got    [0:255];

    task c_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            c_req = 1'b1; c_we = 1'b1;
            c_addr = addr; c_wdata = data;
            @(negedge clk);
            c_req = 1'b0; c_we = 1'b0;
        end
    endtask

    task c_read;
        input  [7:0]  addr;
        output [31:0] val;
        begin
            @(negedge clk);
            c_req = 1'b1; c_we = 1'b0; c_addr = addr;
            @(posedge clk);
            @(negedge clk);
            val = c_rdata;
            c_req = 1'b0;
        end
    endtask

    task c_wait_done;
        reg [31:0] st;
        integer t;
        begin
            t = 0;
            repeat (200000) begin
                c_read(8'h04, st);
                if (st[1] == 1'b1) return;
                t = t + 1;
            end
            $display("[%0t] FAIL: timeout waiting NTT done", $time);
            failures = failures + 1;
        end
    endtask

    task c_run_fwd;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1)
                c_write(8'h08, {20'h0, poly_a[i]});
            c_write(8'h00, {29'b0, 3'd1});                 // op=1, go=0
            c_write(8'h00, {27'b0, 1'b1, 1'b0, 3'd1});      // op=1, go=1 (bit 4)
            c_wait_done;
            for (i = 0; i < 256; i = i + 1) begin
                @(negedge clk);
                c_req = 1'b1; c_we = 1'b0; c_addr = 8'h08;
                @(posedge clk);
                @(negedge clk);
                got[i] = c_rdata[11:0];
                c_req = 1'b0;
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        bus_req = 0; bus_we = 0; bus_addr = 8'h0; bus_wdata = 32'h0;
        c_req = 0; c_we = 0; c_addr = 8'h0; c_wdata = 32'h0;
        #20; rst_n = 1'b1;
        #20;

        $readmemh("kat/ntt_in1.txt", poly_a);
        $readmemh("kat/ntt_fwd1.txt", expo);
        c_run_fwd;

        tests = tests + 1;
        begin
            integer k, mism;
            mism = 0;
            for (k = 0; k < 256; k = k + 1)
                if (got[k] !== expo[k]) mism = mism + 1;
            if (mism == 0) $display("PASS: forward NTT via client port matches");
            else begin
                $display("FAIL: forward NTT via client port mismatch (%0d)", mism);
                failures = failures + 1;
            end
        end

        if (failures == 0) $display("PASS: client-port NTT path verified");
        else $display("FAIL: %0d/%0d test groups failed", failures, tests);
        $finish;
    end

endmodule
