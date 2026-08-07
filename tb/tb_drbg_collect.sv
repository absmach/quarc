// tb_drbg_collect.sv - generate a long DRBG output sequence for SP 800-22
//
// Seeds the DRBG, generates NUM_GENS * 32 bytes, and writes each 32-bit word
// as a hex line to build/drbg_bits.txt for scripts/run_sp80022.py.

`timescale 1ns/1ps

module tb_drbg_collect;

    parameter integer NUM_GENS = 4000;   // 4000 * 256 bits = 1,024,000 bits

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        bus_req, bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ack, irq_done;

    wire        perm_req;
    wire [1599:0] perm_state_in;
    wire        perm_done;
    wire [1599:0] perm_state_out;

    drbg dut (
        .clk(clk), .rst_n(rst_n),
        .bus_req(bus_req), .bus_we(bus_we),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack), .irq_done(irq_done),
        .perm_req(perm_req), .perm_state_in(perm_state_in),
        .perm_done(perm_done), .perm_state_out(perm_state_out)
    );

    keccak_engine u_keccak (
        .clk(clk), .rst_n(rst_n),
        .c0_req(perm_req), .c0_state_in(perm_state_in),
        .c0_done(perm_done), .c0_state_out(perm_state_out),
        .c1_req(1'b0), .c1_state_in(1600'b0), .c1_done(), .c1_state_out(),
        .c2_req(1'b0), .c2_state_in(1600'b0), .c2_done(), .c2_state_out(),
        .c3_req(1'b0), .c3_state_in(1600'b0), .c3_done(), .c3_state_out()
    );

    integer fd;

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
                bus_read(8'h24, st);
                if (st[1] == 1'b1) return;
                t = t + 1;
            end
            $display("[%0t] FAIL: timeout waiting DRBG done", $time);
            $finish;
        end
    endtask

    initial begin
        integer i, w;
        reg [31:0] rdata;
        $dumpfile("build/tb_drbg_collect.vcd");
        $dumpvars(0, tb_drbg_collect);

        rst_n = 1'b0;
        bus_req = 1'b0; bus_we = 1'b0; bus_addr = 8'h0; bus_wdata = 32'h0;
        #20 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        fd = $fopen("build/drbg_bits.txt", "w");

        // seed with fixed entropy (8 words)
        bus_write(8'h34, 32'h17ba5d00);
        bus_write(8'h34, 32'h8b2ed174);
        bus_write(8'h34, 32'hffa245e8);
        bus_write(8'h34, 32'h7316b95c);
        bus_write(8'h34, 32'he78a2dd0);
        bus_write(8'h34, 32'h5bfea144);
        bus_write(8'h34, 32'hcf7215b8);
        bus_write(8'h34, 32'h43e6892c);
        bus_write(8'h20, 32'h2);   // reseed
        wait_done;

        for (i = 0; i < NUM_GENS; i = i + 1) begin
            bus_write(8'h20, {16'h0, 8'd32, 7'b0, 1'b1});   // generate 32 bytes
            wait_done;
            for (w = 0; w < 8; w = w + 1) begin
                bus_read(8'h28, rdata);
                $fwrite(fd, "%08x\n", rdata);
            end
            // refresh entropy and reseed before the 1000-call limit
            if ((i % 900) == 899) begin
                bus_write(8'h34, 32'h12345678 + i);
                bus_write(8'h34, 32'h9abcdef0 + i);
                bus_write(8'h34, 32'h0fedcba9 + i);
                bus_write(8'h34, 32'h10203040 + i);
                bus_write(8'h34, 32'h50607080 + i);
                bus_write(8'h34, 32'h90a0b0c0 + i);
                bus_write(8'h34, 32'hd0e0f000 + i);
                bus_write(8'h34, 32'h0a0b0c0d + i);
                bus_write(8'h20, 32'h2);   // reseed
                wait_done;
            end
        end

        $fclose(fd);
        $display("PASS: collected %0d DRBG words to build/drbg_bits.txt", NUM_GENS*8);
        $finish;
    end

endmodule
