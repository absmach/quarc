`timescale 1ns/1ps
module tb_mlkem;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg        bus_req, bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire       bus_ack, irq_done;

    wire h_req, s_req, n_ack;
    wire [1599:0] h_state_in, s_state_in;
    wire h_done, s_done, n_req, n_we;
    wire [1599:0] h_state_out, s_state_out;
    wire [7:0] n_addr;
    wire [31:0] n_wdata, n_rdata;

    keccak_engine u_eng (
        .clk(clk), .rst_n(rst_n),
        .c0_req(1'b0), .c0_state_in(1600'b0), .c0_done(), .c0_state_out(),
        .c1_req(1'b0), .c1_state_in(1600'b0), .c1_done(), .c1_state_out(),
        .c2_req(s_req), .c2_state_in(s_state_in), .c2_done(s_done), .c2_state_out(s_state_out),
        .c3_req(h_req), .c3_state_in(h_state_in), .c3_done(h_done), .c3_state_out(h_state_out),
        .c4_req(1'b0), .c4_state_in(1600'b0), .c4_done(), .c4_state_out(),
        .c5_req(1'b0), .c5_state_in(1600'b0), .c5_done(), .c5_state_out()
    );

    ntt u_ntt (
        .clk(clk), .rst_n(rst_n),
        .bus_req(1'b0), .bus_we(1'b0), .bus_addr(8'h0), .bus_wdata(32'h0),
        .bus_rdata(), .bus_ack(), .irq_done(),
        .c_req(n_req), .c_we(n_we), .c_addr(n_addr), .c_wdata(n_wdata),
        .c_rdata(n_rdata), .c_ack(n_ack)
    );

    mlkem u_dut (
        .clk(clk), .rst_n(rst_n),
        .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack), .irq_done(irq_done),
        .h_req(h_req), .h_state_in(h_state_in), .h_done(h_done), .h_state_out(h_state_out),
        .s_req(s_req), .s_state_in(s_state_in), .s_done(s_done), .s_state_out(s_state_out),
        .n_req(n_req), .n_we(n_we), .n_addr(n_addr), .n_wdata(n_wdata),
        .n_rdata(n_rdata), .n_ack(n_ack)
    );

    task wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk);
            bus_req = 1; bus_we = 1; bus_addr = a; bus_wdata = d;
            @(posedge clk);
            @(negedge clk);
            bus_req = 0; bus_we = 0;
        end
    endtask

    task rd(input [7:0] a, output [31:0] d);
        begin
            @(negedge clk);
            bus_req = 1; bus_we = 0; bus_addr = a;
            @(posedge clk);
            d = bus_rdata;   // capture at the posedge, before the read pointer advances
            @(negedge clk);
            bus_req = 0;
        end
    endtask


    integer i, k;
    reg [31:0] v;
    reg [7:0]  got_ek [0:1183];
    reg [7:0]  got_dk [0:2399];
    reg [7:0]  ref_ek [0:1183];
    reg [7:0]  ref_dk [0:2399];
    reg        ok;
    initial begin
        $dumpfile("build/tb_mlkem.vcd");
        $dumpvars(0, tb_mlkem);
        #20; rst_n = 1;
        #20;

        $readmemh("kat/mlkem_pk.mem", ref_ek);
        $readmemh("kat/mlkem_dk.mem", ref_dk);

        // load d seed (bytes 00..1f) -> little-endian words
        wr(8'h08, 32'h03020100);
        wr(8'h08, 32'h07060504);
        wr(8'h08, 32'h0b0a0908);
        wr(8'h08, 32'h0f0e0d0c);
        wr(8'h08, 32'h13121110);
        wr(8'h08, 32'h17161514);
        wr(8'h08, 32'h1b1a1918);
        wr(8'h08, 32'h1f1e1d1c);

        // load z seed (bytes 20..3f)
        wr(8'h0C, 32'h23222120);
        wr(8'h0C, 32'h27262524);
        wr(8'h0C, 32'h2b2a2928);
        wr(8'h0C, 32'h2f2e2d2c);
        wr(8'h0C, 32'h33323130);
        wr(8'h0C, 32'h37363534);
        wr(8'h0C, 32'h3b3a3938);
        wr(8'h0C, 32'h3f3e3d3c);

        // trigger keygen
        wr(8'h00, 32'h00000011);

        // watchdog: print FSM state every 200k cycles, abort at 4M
        fork
            begin
                while (!u_dut.done_q) begin
                    repeat (200000) @(posedge clk);
                    $display("[watchdog] st=%0d i=%0d j=%0d hmsg=%b hmode=%0d hlen=%0d sqd=%b absd=%b fsm=%0d",
                             u_dut.st, u_dut.i, u_dut.j, u_dut.h_msg, u_dut.h_mode, u_dut.h_len,
                             u_dut.u_hash.squeeze_done, u_dut.u_hash.absorb_done, u_dut.u_hash.fsm);
                end
            end
            begin
                while (!u_dut.done_q) begin
                    repeat (4000000) @(posedge clk);
                    $display("TIMEOUT watchdog fired, state=%0d", u_dut.st);
                    $finish;
                end
            end
        join_none

        // wait for done
        while (!u_dut.done_q) @(posedge clk);
        @(posedge clk);

        // read ek
        for (i = 0; i < 1184; i = i + 1) begin
            rd(8'h10, v);
            got_ek[i] = v[7:0];
        end
        // read dk
        for (i = 0; i < 2400; i = i + 1) begin
            rd(8'h14, v);
            got_dk[i] = v[7:0];
        end

        // compare
        ok = 1;
        for (i = 0; i < 1184; i = i + 1)
            if (got_ek[i] !== ref_ek[i]) begin
                $display("EK mismatch at %0d: got %02h ref %02h", i, got_ek[i], ref_ek[i]);
                ok = 0;
                if (i > 20) i = 1184;
            end
        for (i = 0; i < 2400; i = i + 1)
            if (got_dk[i] !== ref_dk[i]) begin
                $display("DK mismatch at %0d: got %02h ref %02h", i, got_dk[i], ref_dk[i]);
                ok = 0;
                if (i > 20) i = 2400;
            end

        if (ok)
            $display("PASS: ML-KEM-768 keygen matches reference (ek+dk)");
        else
            $display("FAIL: keygen mismatch");

        $finish;
    end
endmodule
