// tb_sampling.sv - ML-KEM sampling datapath test (SampleNTT + CBD)
//
// Feeds XOF/PRF byte streams to the sampling module and checks the 256 output
// coefficients against the FIPS 203 reference KAT.

`timescale 1ns/1ps

module tb_sampling;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        start_i, mode_i;
    reg [1:0]  eta_i;
    reg [7:0]  byte_i;
    reg        byte_valid_i;
    wire       byte_ready_o;
    wire [11:0] coeff_o;
    wire       coeff_valid_o, done_o;

    sampling dut (
        .clk(clk), .rst_n(rst_n),
        .start_i(start_i), .mode_i(mode_i), .eta_i(eta_i),
        .byte_i(byte_i), .byte_valid_i(byte_valid_i), .byte_ready_o(byte_ready_o),
        .coeff_o(coeff_o), .coeff_valid_o(coeff_valid_o), .done_o(done_o)
    );

    reg [7:0] ntt_bytes [0:839];
    reg [11:0] ntt_exp [0:255];
    reg [7:0] cbd_bytes [0:127];
    reg [11:0] cbd_exp [0:255];

    integer failures = 0;
    integer n, k;

    task feed_and_collect;
        input integer nbytes;
        input integer mode;
        reg [11:0] got [0:255];
        integer mism, i, n, guard;
        begin
            i = 0; n = 0; guard = 0; byte_valid_i = 0;

            // start
            @(negedge clk); start_i = 1; mode_i = mode; eta_i = 2;
            @(negedge clk); start_i = 0;

            while (!done_o && guard < 30000) begin
                @(negedge clk);
                guard = guard + 1;
                // transfer detection for the byte offered at the last posedge
                if (byte_valid_i && dut.byte_ready_o)
                    i = i + 1;
                // offer the next byte (stable at the upcoming posedge)
                if (i < nbytes) begin
                    byte_i = (mode == 0) ? ntt_bytes[i] : cbd_bytes[i];
                    byte_valid_i = 1;
                end else begin
                    byte_valid_i = 0;
                end
                // collect accepted coefficients (pulse is stable during the cycle)
                if (dut.coeff_valid_o && n < 256) begin
                    got[n] = dut.coeff_o;
                    n = n + 1;
                end
            end
            byte_valid_i = 0;

            mism = 0;
            for (k = 0; k < 256; k = k + 1) begin
                if (mode == 0) begin
                    if (got[k] !== ntt_exp[k]) mism = mism + 1;
                end
                else begin if (got[k] !== cbd_exp[k]) mism = mism + 1; end
            end
            if (mism == 0 && n == 256)
                $display("PASS: mode %0d sampling matches (%0d coeffs)", mode, n);
            else begin
                $display("FAIL: mode %0d sampling mismatch (%0d/%0d, got %0d)", mode, mism, 256, n);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        $readmemh("kat/samp_ntt_in.txt", ntt_bytes);
        $readmemh("kat/samp_ntt_out.txt", ntt_exp);
        $readmemh("kat/samp_cbd_in.txt", cbd_bytes);
        $readmemh("kat/samp_cbd_out.txt", cbd_exp);

        rst_n = 0; start_i = 0; byte_valid_i = 0; byte_i = 0; mode_i = 0; eta_i = 0;
        #20; rst_n = 1; #20;

        feed_and_collect(840, 0);   // SampleNTT
        feed_and_collect(128, 1);   // CBD eta=2

        if (failures == 0) $display("PASS: sampling datapath verified");
        else $display("FAIL: %0d sampling checks failed", failures);
        $finish;
    end

endmodule
