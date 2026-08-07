// tb_sha3.sv - SHA-3 / SHAKE wrapper testbench
//
// Drives the sha3 MMIO interface through absorb -> pad -> permute -> squeeze
// and checks DATA_OUT against reference digests for all four modes.

`timescale 1ns/1ps

module tb_sha3;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        bus_req;
    reg        bus_we;
    reg [7:0]  bus_addr;
    reg [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire        bus_ack;
    wire        irq_done;

    wire        perm_req;
    wire [1599:0] perm_state_in;
    wire        perm_done;
    wire [1599:0] perm_state_out;

    sha3 dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .bus_req  (bus_req),
        .bus_we   (bus_we),
        .bus_addr (bus_addr),
        .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .bus_ack  (bus_ack),
        .irq_done (irq_done),
        .perm_req      (perm_req),
        .perm_state_in (perm_state_in),
        .perm_done     (perm_done),
        .perm_state_out(perm_state_out)
    );

    keccak_engine u_keccak (
        .clk(clk), .rst_n(rst_n),
        .c0_req(perm_req), .c0_state_in(perm_state_in),
        .c0_done(perm_done), .c0_state_out(perm_state_out),
        .c1_req(1'b0), .c1_state_in(1600'b0), .c1_done(), .c1_state_out(),
        .c2_req(1'b0), .c2_state_in(1600'b0), .c2_done(), .c2_state_out()
    );

    reg [7:0]  msg_bytes [0:255];
    reg [9:0]  msg_len;
    reg [7:0]  exp_digest [0:63];
    integer    exp_len;

    integer failures = 0;
    integer tests    = 0;

    // ------------------------------------------------------------------
    // Bus helpers (negedge-driven; DUT samples on posedge)
    // ------------------------------------------------------------------
    task bus_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            bus_req   = 1'b1;
            bus_we    = 1'b1;
            bus_addr  = addr;
            bus_wdata = data;
            @(negedge clk);
            bus_req   = 1'b0;
            bus_we    = 1'b0;
        end
    endtask

    task bus_read;
        input  [7:0]  addr;
        output [31:0] val;
        begin
            @(negedge clk);
            bus_req  = 1'b1;
            bus_we   = 1'b0;
            bus_addr = addr;
            @(posedge clk);        // DUT latches registered reads here
            @(negedge clk);        // bus_rdata now reflects the latched value
            val = bus_rdata;
            bus_req  = 1'b0;
        end
    endtask

    task wait_status;
        input [1:0] bit_idx;
        input       want;
        reg [31:0] st;
        integer t;
        begin
            t = 0;
            repeat (200000) begin
                bus_read(8'h04, st);
                if (st[bit_idx] == want) return;
                t = t + 1;
            end
            $display("[%0t] FAIL: timeout waiting STATUS[%0d]=%0d", $time, bit_idx, want);
            failures = failures + 1;
        end
    endtask

    task write_message;
        integer i, nwords;
        reg [31:0] word;
        begin
            nwords = (msg_len + 3) / 4;
            for (i = 0; i < nwords; i = i + 1) begin
                word = 32'h0;
                if (i*4+0 < msg_len) word[7:0]   = msg_bytes[i*4+0];
                if (i*4+1 < msg_len) word[15:8]  = msg_bytes[i*4+1];
                if (i*4+2 < msg_len) word[23:16] = msg_bytes[i*4+2];
                if (i*4+3 < msg_len) word[31:24] = msg_bytes[i*4+3];
                bus_write(8'h0C, word);
            end
        end
    endtask

    task check_digest;
        reg [31:0] rd [0:63];
        reg [31:0] rdata;
        integer i, nwords;
        integer mism;
        begin
            mism = 0;
            nwords = (exp_len + 3) / 4;
            for (i = 0; i < nwords; i = i + 1) begin
                bus_read(8'h10, rdata);
                rd[i] = rdata;
                if (i*4+0 < exp_len && rdata[7:0]   !== exp_digest[i*4+0]) mism = mism + 1;
                if (i*4+1 < exp_len && rdata[15:8]  !== exp_digest[i*4+1]) mism = mism + 1;
                if (i*4+2 < exp_len && rdata[23:16] !== exp_digest[i*4+2]) mism = mism + 1;
                if (i*4+3 < exp_len && rdata[31:24] !== exp_digest[i*4+3]) mism = mism + 1;
            end
            if (mism != 0) begin
                $display("[%0t] FAIL (test %0d): digest mismatch, %0d bytes differ", $time, tests, mism);
                $write("  got: ");
                for (i = 0; i < nwords; i = i + 1) $write("%08x ", rd[i]);
                $write("\n");
                failures = failures + 1;
            end else begin
                $display("[%0t] PASS (test %0d): digest matches", $time, tests);
            end
        end
    endtask

    task do_test;
        input [1:0] mode;
        input [9:0] out_len;
        integer i;
        reg [31:0] st;
        begin
            tests = tests + 1;
            bus_write(8'h08, {30'b0, mode});          // MODE
            bus_write(8'h14, msg_len);                 // LEN
            write_message;
            bus_write(8'h00, 32'h1);                   // absorb_start
            wait_status(1, 1'b1);                      // absorb_done
            bus_write(8'h18, out_len);                 // SQUEEZE_LEN
            bus_write(8'h00, 32'h2);                   // squeeze_start
            wait_status(2, 1'b1);                      // squeeze_done
            check_digest;
        end
    endtask

    task load_exp;
        input [63:0] d0, d1, d2, d3;                   // up to 32 bytes
        begin
            exp_len = 32;
            exp_digest[0]=d0[63:56]; exp_digest[1]=d0[55:48]; exp_digest[2]=d0[47:40]; exp_digest[3]=d0[39:32];
            exp_digest[4]=d0[31:24]; exp_digest[5]=d0[23:16]; exp_digest[6]=d0[15:8]; exp_digest[7]=d0[7:0];
            exp_digest[8]=d1[63:56]; exp_digest[9]=d1[55:48]; exp_digest[10]=d1[47:40]; exp_digest[11]=d1[39:32];
            exp_digest[12]=d1[31:24]; exp_digest[13]=d1[23:16]; exp_digest[14]=d1[15:8]; exp_digest[15]=d1[7:0];
            exp_digest[16]=d2[63:56]; exp_digest[17]=d2[55:48]; exp_digest[18]=d2[47:40]; exp_digest[19]=d2[39:32];
            exp_digest[20]=d2[31:24]; exp_digest[21]=d2[23:16]; exp_digest[22]=d2[15:8]; exp_digest[23]=d2[7:0];
            exp_digest[24]=d3[63:56]; exp_digest[25]=d3[55:48]; exp_digest[26]=d3[47:40]; exp_digest[27]=d3[39:32];
            exp_digest[28]=d3[31:24]; exp_digest[29]=d3[23:16]; exp_digest[30]=d3[15:8]; exp_digest[31]=d3[7:0];
        end
    endtask

    task load_exp64;                                    // 64-byte digest (SHA3-512)
        input [63:0] d0, d1, d2, d3, d4, d5, d6, d7;
        begin
            exp_len = 64;
            load_exp(d0, d1, d2, d3);
            exp_digest[32]=d4[63:56]; exp_digest[33]=d4[55:48]; exp_digest[34]=d4[47:40]; exp_digest[35]=d4[39:32];
            exp_digest[36]=d4[31:24]; exp_digest[37]=d4[23:16]; exp_digest[38]=d4[15:8]; exp_digest[39]=d4[7:0];
            exp_digest[40]=d5[63:56]; exp_digest[41]=d5[55:48]; exp_digest[42]=d5[47:40]; exp_digest[43]=d5[39:32];
            exp_digest[44]=d5[31:24]; exp_digest[45]=d5[23:16]; exp_digest[46]=d5[15:8]; exp_digest[47]=d5[7:0];
            exp_digest[48]=d6[63:56]; exp_digest[49]=d6[55:48]; exp_digest[50]=d6[47:40]; exp_digest[51]=d6[39:32];
            exp_digest[52]=d6[31:24]; exp_digest[53]=d6[23:16]; exp_digest[54]=d6[15:8]; exp_digest[55]=d6[7:0];
            exp_digest[56]=d7[63:56]; exp_digest[57]=d7[55:48]; exp_digest[58]=d7[47:40]; exp_digest[59]=d7[39:32];
            exp_digest[60]=d7[31:24]; exp_digest[61]=d7[23:16]; exp_digest[62]=d7[15:8]; exp_digest[63]=d7[7:0];
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        integer i;
        $dumpfile("build/tb_sha3.vcd");
        $dumpvars(0, tb_sha3);

        rst_n = 1'b0;
        bus_req = 1'b0; bus_we = 1'b0; bus_addr = 8'h0; bus_wdata = 32'h0;
        #20 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- Test 1: SHA3-256("") ----
        msg_len = 0;
        load_exp(64'ha7ffc6f8bf1ed766, 64'h51c14756a061d662, 64'hf580ff4de43b49fa, 64'h82d80a4b80f8434a);
        do_test(2'd0, 10'd32);

        // ---- Test 2: SHA3-256("abc") ----
        msg_len = 3;
        msg_bytes[0] = "a"; msg_bytes[1] = "b"; msg_bytes[2] = "c";
        load_exp(64'h3a985da74fe225b2, 64'h045c172d6bd390bd, 64'h855f086e3e9d525b, 64'h46bfe24511431532);
        do_test(2'd0, 10'd32);

        // ---- Test 3: SHA3-256("hello") ----
        msg_len = 5;
        msg_bytes[0]="h"; msg_bytes[1]="e"; msg_bytes[2]="l"; msg_bytes[3]="l"; msg_bytes[4]="o";
        load_exp(64'h3338be694f50c5f3, 64'h38814986cdf06864, 64'h53a888b84f424d79, 64'h2af4b9202398f392);
        do_test(2'd0, 10'd32);

        // ---- Test 4: SHA3-256(137 bytes) - multi-block ----
        msg_len = 137;
        for (i = 0; i < 137; i = i + 1) msg_bytes[i] = (i*7) & 8'hff;
        load_exp(64'h328e173469e331b0, 64'h25dda12fbccbe0d0, 64'h76084af1a7b1d0bb, 64'h1bad27ad738b6677);
        do_test(2'd0, 10'd32);

        // ---- Test 5: SHA3-512("") ----
        msg_len = 0;
        load_exp64(64'ha69f73cca23a9ac5, 64'hc8b567dc185a756e, 64'h97c982164fe25859, 64'he0d1dcc1475c80a6,
                   64'h15b2123af1f5f94c, 64'h11e3e9402c3ac558, 64'hf500199d95b6d3e3, 64'h01758586281dcd26);
        do_test(2'd1, 10'd64);

        // ---- Test 6: SHA3-512("abc") ----
        msg_len = 3;
        msg_bytes[0] = "a"; msg_bytes[1] = "b"; msg_bytes[2] = "c";
        load_exp64(64'hb751850b1a57168a, 64'h5693cd924b6b096e, 64'h08f621827444f70d, 64'h884f5d0240d2712e,
                   64'h10e116e9192af3c9, 64'h1a7ec57647e39340, 64'h57340b4cf408d5a5, 64'h6592f8274eec53f0);
        do_test(2'd1, 10'd64);

        // ---- Test 7: SHAKE-128("") 32B ----
        msg_len = 0;
        load_exp(64'h7f9c2ba4e88f827d, 64'h616045507605853e, 64'hd73b8093f6efbc88, 64'heb1a6eacfa66ef26);
        do_test(2'd2, 10'd32);

        // ---- Test 8: SHAKE-128("abc") 32B ----
        msg_len = 3;
        msg_bytes[0] = "a"; msg_bytes[1] = "b"; msg_bytes[2] = "c";
        load_exp(64'h5881092dd818bf5c, 64'hf8a3ddb793fbcba7, 64'h4097d5c526a6d35f, 64'h97b83351940f2cc8);
        do_test(2'd2, 10'd32);

        // ---- Test 9: SHAKE-256("") 32B ----
        msg_len = 0;
        load_exp(64'h46b9dd2b0ba88d13, 64'h233b3feb743eeb24, 64'h3fcd52ea62b81b82, 64'hb50c27646ed5762f);
        do_test(2'd3, 10'd32);

        // ---- Test 10: SHAKE-256("abc") 32B ----
        msg_len = 3;
        msg_bytes[0] = "a"; msg_bytes[1] = "b"; msg_bytes[2] = "c";
        load_exp(64'h483366601360a877, 64'h1c6863080cc4114d, 64'h8db44530f8f1e1ee, 64'h4f94ea37e78b5739);
        do_test(2'd3, 10'd32);

        // ---- Test 11: SHAKE-256(137 bytes) 32B - multi-block ----
        msg_len = 137;
        for (i = 0; i < 137; i = i + 1) msg_bytes[i] = (i*7) & 8'hff;
        load_exp(64'h358818a7eb8bcb8f, 64'hdfb180ba91b4da12, 64'heb4b5cbab54db7d1, 64'h45b319e588bcda9c);
        do_test(2'd3, 10'd32);

        #10;
        if (failures == 0)
            $display("PASS: %0d/%0d SHA-3/SHAKE tests passed", tests, tests);
        else
            $display("FAIL: %0d SHA-3/SHAKE checks failed", failures);
        $finish;
    end

endmodule
