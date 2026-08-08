`timescale 1ns/1ps
// tb_mlkem_codec.sv - verify byte_encode/byte_decode for D in {12,10,4,1}
// against vectors from the reference bit-packers.
module tb_mlkem_codec;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg op;
    reg [11:0] din;
    reg din_valid;
    wire r12, r10, r4, r1;
    wire [11:0] o12, o10, o4, o1;
    wire v12, v10, v4, v1;

    mlkem_codec #(.D(12)) u12 (.clk(clk), .rst_n(rst_n), .op(op), .din_valid(din_valid),
        .din(din), .din_ready(r12), .dout(o12), .dout_valid(v12));
    mlkem_codec #(.D(10)) u10 (.clk(clk), .rst_n(rst_n), .op(op), .din_valid(din_valid),
        .din(din), .din_ready(r10), .dout(o10), .dout_valid(v10));
    mlkem_codec #(.D(4))  u4  (.clk(clk), .rst_n(rst_n), .op(op), .din_valid(din_valid),
        .din(din), .din_ready(r4), .dout(o4), .dout_valid(v4));
    mlkem_codec #(.D(1))  u1  (.clk(clk), .rst_n(rst_n), .op(op), .din_valid(din_valid),
        .din(din), .din_ready(r1), .dout(o1), .dout_valid(v1));

    integer i, k, c;
    integer errors = 0;
    reg [11:0] ref_c [0:31];
    reg [7:0]  ref_b [0:63];
    reg [3:0]  cur_d;
    integer    n_out;       // expected outputs per case
    reg        phase;       // 0 = encode, 1 = decode
    integer    got_n;       // outputs captured

    reg [11:0] exp_seq [0:511];
    integer    exp_n;

    // concurrent output checker
    always @(posedge clk) begin
        if (cur_d != 4'd0) begin
            case (cur_d)
                4'd12: if (v12) begin
                    if (exp_n < 512 && o12 !== exp_seq[exp_n]) begin
                        if (errors < 5)
                            $display("%s FAIL d=12 out %0d got %02h ref %03x", phase ? "DEC" : "ENC", exp_n, o12, exp_seq[exp_n]);
                        errors = errors + 1;
                    end
                    exp_n = exp_n + 1;
                end
                4'd10: if (v10) begin
                    if (exp_n < 512 && o10 !== exp_seq[exp_n]) begin
                        if (errors < 5)
                            $display("%s FAIL d=10 out %0d got %02h ref %03x", phase ? "DEC" : "ENC", exp_n, o10, exp_seq[exp_n]);
                        errors = errors + 1;
                    end
                    exp_n = exp_n + 1;
                end
                4'd4: if (v4) begin
                    if (exp_n < 512 && o4 !== exp_seq[exp_n]) begin
                        if (errors < 5)
                            $display("%s FAIL d=4 out %0d got %02h ref %03x", phase ? "DEC" : "ENC", exp_n, o4, exp_seq[exp_n]);
                        errors = errors + 1;
                    end
                    exp_n = exp_n + 1;
                end
                4'd1: if (v1) begin
                    if (exp_n < 512 && o1 !== exp_seq[exp_n]) begin
                        if (errors < 5)
                            $display("%s FAIL d=1 out %0d got %02h ref %03x", phase ? "DEC" : "ENC", exp_n, o1, exp_seq[exp_n]);
                        errors = errors + 1;
                    end
                    exp_n = exp_n + 1;
                end
            endcase
        end
    end

    function ready_sel;
        begin
            case (cur_d)
                4'd12: ready_sel = r12;
                4'd10: ready_sel = r10;
                4'd4:  ready_sel = r4;
                default: ready_sel = r1;
            endcase
        end
    endfunction

    task feed_din(input integer n, input integer dw);
        integer f;
        begin
            for (f = 0; f < n; f = f + 1) begin
                @(negedge clk);
                while (!ready_sel()) @(negedge clk);
                din = (dw == 8) ? {4'b0, ref_b[f]} : ref_c[f];
                din_valid = 1;
                @(posedge clk);
                @(negedge clk);
                din_valid = 0;
            end
        end
    endtask

    task run_case(input [3:0] d);
        integer nb;
        begin
            case (d)
                4'd12: begin nb = 48; $readmemh("kat/codec_c_12.mem", ref_c); $readmemh("kat/codec_b_12.mem", ref_b); end
                4'd10: begin nb = 40; $readmemh("kat/codec_c_10.mem", ref_c); $readmemh("kat/codec_b_10.mem", ref_b); end
                4'd4:  begin nb = 16; $readmemh("kat/codec_c_4.mem",  ref_c); $readmemh("kat/codec_b_4.mem",  ref_b); end
                default: begin nb = 4; $readmemh("kat/codec_c_1.mem",  ref_c); $readmemh("kat/codec_b_1.mem",  ref_b); end
            endcase

            // reset all codecs
            rst_n = 0;
            #30;
            rst_n = 1;
            #30;

            // ---- encode ----
            phase = 0;
            op = 0;
            cur_d = d;
            for (i = 0; i < 64; i = i + 1) exp_seq[i] = {4'b0, ref_b[i]};
            exp_n = 0;
            feed_din(32, 12);
            while (exp_n < nb) @(posedge clk);
            cur_d = 4'd0;
            @(posedge clk);
            #20;

            // ---- reset accumulator, then decode ----
            rst_n = 0;
            #30;
            rst_n = 1;
            #30;
            phase = 1;
            op = 1;
            cur_d = d;
            for (i = 0; i < 32; i = i + 1) exp_seq[i] = ref_c[i];
            exp_n = 0;
            feed_din(nb, 8);
            while (exp_n < 32) @(posedge clk);
            cur_d = 4'd0;
            @(posedge clk);
            #20;
        end
    endtask

    initial begin
        #20; rst_n = 1;
        #20;
        run_case(4'd12);
        run_case(4'd10);
        run_case(4'd4);
        run_case(4'd1);
        if (errors == 0)
            $display("PASS: byte_encode/byte_decode match reference (12/10/4/1)");
        else
            $display("FAIL: %0d codec errors", errors);
        $finish;
    end
endmodule
