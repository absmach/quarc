// tb_shake_sampler.sv - ML-KEM polynomial generation (SHAKE -> SampleNTT / CBD)
//
// Drives shake_sampler (keccak c2 + sha3 + sampling) to generate one
// polynomial per call and checks the 256 coefficients against the KAT:
//   mode 0 (XOF):  SampleNTT(rho, 0, 0)
//   mode 1 (PRF):  CBD(SHAKE256(sigma || 0), eta=2)

`timescale 1ns/1ps

module tb_shake_sampler;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n;
    reg        start_i, mode_i;
    reg [1:0]  eta_i;
    reg [255:0] seed_i;
    reg [7:0]  x0_i, x1_i;
    wire [11:0] coeff_o;
    wire       coeff_valid_o, done_o;

    wire       perm_req;
    wire [1599:0] perm_state_in;
    wire       perm_done;
    wire [1599:0] perm_state_out;

    shake_sampler dut (
        .clk(clk), .rst_n(rst_n),
        .perm_req(perm_req), .perm_state_in(perm_state_in),
        .perm_done(perm_done), .perm_state_out(perm_state_out),
        .start_i(start_i), .mode_i(mode_i), .eta_i(eta_i),
        .seed_i(seed_i), .x0_i(x0_i), .x1_i(x1_i),
        .coeff_o(coeff_o), .coeff_valid_o(coeff_valid_o), .done_o(done_o)
    );

    keccak_engine u_keccak (
        .clk(clk), .rst_n(rst_n),
        .c0_req(1'b0), .c0_state_in(1600'b0), .c0_done(), .c0_state_out(),
        .c1_req(1'b0), .c1_state_in(1600'b0), .c1_done(), .c1_state_out(),
        .c2_req(perm_req), .c2_state_in(perm_state_in),
        .c2_done(perm_done), .c2_state_out(perm_state_out)
    );

    reg [11:0] ntt_exp [0:255];
    reg [11:0] cbd_exp [0:255];
    reg [11:0] got [0:255];

    integer failures = 0;
    integer n, k, guard;

    task run_poly;
        input integer mode;
        integer mism;
        begin
            // start the module
            @(negedge clk); start_i = 1; @(negedge clk); start_i = 0;
            // collect 256 coeffs
            n = 0; guard = 0;
            while (n < 256 && guard < 1000000) begin
                @(negedge clk);
                guard = guard + 1;
                if (dut.coeff_valid_o) begin
                    got[n] = dut.coeff_o;
                    n = n + 1;
                end
            end
            // wait for the module to finish
            guard = 0;
            while (!dut.done_o && guard < 200000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            // compare
            mism = 0;
            for (k = 0; k < 256; k = k + 1) begin
                if (mode == 0) begin if (got[k] !== ntt_exp[k]) mism = mism + 1; end
                else begin if (got[k] !== cbd_exp[k]) mism = mism + 1; end
            end
            if (mism == 0) begin
                $display("PASS: mode %0d polynomial matches (%0d coeffs)", mode, n);
            end else begin
                $display("FAIL: mode %0d polynomial mismatch (%0d/%0d)", mode, mism, 256);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        $readmemh("kat/samp_ntt_out.txt", ntt_exp);
        $readmemh("kat/samp_cbd_out.txt", cbd_exp);

        rst_n = 0; start_i = 0; mode_i = 0; eta_i = 0; x0_i = 0; x1_i = 0; seed_i = 0;
        #20; rst_n = 1;
        #20;

        // mode 0 (XOF): SampleNTT(rho, 0, 0)  -- seed = rho (0x00..0x1F)
        seed_i = 256'h1F1E1D1C_1B1A1918_17161514_13121110_0F0E0D0C_0B0A0908_07060504_03020100;
        x0_i = 8'h00; x1_i = 8'h00;
        mode_i = 0;
        run_poly(0);

        // mode 1 (PRF): CBD(SHAKE256(sigma || 0), eta=2) -- seed = sigma (0x20..0x3F)
        seed_i = 256'h3F3E3D3C_3B3A3938_37363534_33323130_2F2E2D2C_2B2A2928_27262524_23222120;
        x0_i = 8'h00;
        eta_i = 2;
        mode_i = 1;
        run_poly(1);

        if (failures == 0) $display("PASS: shake_sampler verified");
        else $display("FAIL: %0d polynomial checks failed", failures);
        $finish;
    end

endmodule
