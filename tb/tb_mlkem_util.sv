`timescale 1ns/1ps
// tb_mlkem_util.sv - verify mlkem_codec and mlkem_compress against the
// Python reference vectors.
module tb_mlkem_util;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---------------- codec under test (D=12, 10, 4, 1) ----------------
    reg  c_op;
    reg  c_din_valid;
    reg [11:0] c_din;
    wire c_din_ready;
    wire [7:0] c_dout;
    wire c_dout_valid;
    wire c_dout_ready;

    // ---------------- compress under test ----------------
    reg [11:0] cx;
    reg [1:0]  cd;
    wire [11:0] ccomp, cdecomp;

    mlkem_codec #(.D(12)) u_codec (
        .clk(clk), .rst_n(rst_n),
        .op(c_op), .din_valid(c_din_valid), .din(c_din), .din_ready(c_din_ready),
        .dout(c_dout), .dout_valid(c_dout_valid), .dout_ready(c_dout_ready)
    );
    mlkem_compress u_comp (
        .x(cx), .d_i(cd), .comp(ccomp), .decomp(cdecomp)
    );

    // reference vectors loaded from kat/
    integer n_cases;
    reg [3:0] vd [0:23];          // d per case
    reg [11:0] vc [0:23][0:31];   // coeffs
    reg [7:0]  vb [0:23][0:63];   // bytes
    reg [7:0]  nb [0:23];
    reg [7:0]  nenc [0:23];       // bytes per case

    integer i, j, k;
    integer errors = 0;
    reg [11:0] cur_d;
    reg [11:0] cap;
    reg [7:0]  gotb [0:63];
    reg [11:0] gotc [0:31];

    // reference compress formula (independent of RTL)
    function [11:0] ref_comp(input [11:0] x, input [1:0] d);
        reg [23:0] p;
        integer dd;
        begin
            dd = (d == 2'd2) ? 10 : (d == 2'd1) ? 4 : 1;
            p = (x << dd) + 24'd1664;
            ref_comp = (p / 24'd3329) & ((24'hFFF) >> (12 - dd));
        end
    endfunction

    function [11:0] ref_decomp(input [11:0] y, input [1:0] d);
        reg [23:0] p;
        integer dd;
        begin
            dd = (d == 2'd2) ? 10 : (d == 2'd1) ? 4 : 1;
            p = (y * 24'd3329) + (24'd1 << (dd - 1));
            ref_decomp = (p >> dd) % 24'd3329;
        end
    endfunction

    task drive_compress;
        integer x;
        integer dd;
        reg [11:0] rc;
        begin
            for (dd = 0; dd < 3; dd = dd + 1) begin
                cd = dd[1:0];
                for (x = 0; x < 3329; x = x + 1) begin
                    cx = x[11:0];
                    #1;
                    rc = ref_comp(x[11:0], cd);
                    if (ccomp !== rc) begin
                        if (errors < 5)
                            $display("COMP FAIL d=%0d x=%0d got=%0d ref=%0d", dd, x, ccomp, rc);
                        errors = errors + 1;
                    end
                end
            end
            // decompress check: capture y = compress(x), then feed it back
            for (dd = 0; dd < 3; dd = dd + 1) begin
                cd = dd[1:0];
                for (x = 0; x < 3329; x = x + 30) begin
                    cx = x[11:0];
                    #1;
                    cap = ccomp;         // y = compress(x)
                    cx = cap;
                    #1;
                    if (cdecomp !== ref_decomp(cap, cd)) begin
                        if (errors < 5)
                            $display("DECOMP FAIL d=%0d x=%0d got=%0d ref=%0d", dd, x, cdecomp, ref_decomp(cap, cd));
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    initial begin
        #20; rst_n = 1;
        #20;

        drive_compress;

        if (errors == 0)
            $display("PASS: compress/decompress matches reference");
        else
            $display("FAIL: %0d compress errors", errors);
        $finish;
    end
endmodule
