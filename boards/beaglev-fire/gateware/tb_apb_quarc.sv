// tb_apb_quarc.sv - APB3 master smoke test for the BeagleV-Fire Quarc cape
//
// Drives the apb_quarc bridge exactly as the PolarFire MSS FIC3 APB master
// would, and validates:
//   * ID / VER read-only registers at 0x0F00 / 0x0F04
//   * combinational STATUS read (sha3, 0x004)
//   * full SHA3-256 of {01,02,03,04} through the synchronous DATA_OUT
//     read path (0x010) - the timing-risk area of the bridge
//   * the ntt COEFF synchronous write/read path (0x808) with the repo's own
//     forward-NTT KAT pair kat/ntt_in1.txt -> kat/ntt_fwd1.txt (256 coeffs)
//
// Run with (from the repo root, so kat/ resolves):
//   iverilog -g2012 -I boards/.../QUARC/HDL -o /tmp/tb_apb_quarc.vvp \
//       boards/.../QUARC/HDL/{CAPE.v,apb_quarc.v,sha3.v,ntt.v,keccak.v,keccak_engine.v} \
//       boards/beaglev-fire/gateware/tb_apb_quarc.sv
//   vvp /tmp/tb_apb_quarc.vvp     # expect "CAPE APB TEST: PASS"
//
// Note: iverilog 12.0 rejects 'return'/'break' in tasks and 'expect' is a
// reserved word in -g2012 mode; the code avoids all three.
//
// Note: the ntt COEFF port keeps its own wr_ptr/rd_ptr, which only reset on a
// CTRL write. Any COEFF traffic before a fresh polynomial load must be
// followed by a CTRL write (op=0, go=0) or the load shifts by one.

`default_nettype none
`timescale 1ns/1ps

module tb_apb_quarc;

    reg        clk = 1'b0;
    reg        presetn = 1'b0;
    // APB master side
    reg        psel = 1'b0;
    reg        penable = 1'b0;
    reg        pwrite = 1'b0;
    reg  [31:0] paddr = 32'h0;
    reg  [31:0] pwdata = 32'h0;
    wire [31:0] prdata;

    always #5 clk = ~clk;   // 10 ns period

    apb_quarc dut (
        .pclk    (clk),
        .presetn (presetn),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (prdata)
    );

    integer fails = 0;

    // Standard 3-state APB transfer with an idle cycle in between.
    task apb_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk); psel <= 1'b1; penable <= 1'b0;
                           paddr <= addr; pwrite <= 1'b1; pwdata <= data;
            @(posedge clk); penable <= 1'b1;
            @(posedge clk); psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
        end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk); psel <= 1'b1; penable <= 1'b0;
                           paddr <= addr; pwrite <= 1'b0; pwdata <= 32'h0;
            @(posedge clk); penable <= 1'b1;
            @(posedge clk); data = prdata;   // combinational, stable in access phase
            @(posedge clk); psel <= 1'b0; penable <= 1'b0;
        end
    endtask

    task check(input [127:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("FAIL %s: got %08x exp %08x @t=%0t", what, got, exp, $time);
            end else begin
                $display("PASS %s: %08x", what, got);
            end
        end
    endtask

    // Poll a sha3/ntt status register until a bit asserts (timeout guard).
    task wait_status(input [31:0] addr, input [31:0] bitmask);
        integer i; reg [31:0] v;
        begin
            v = 0;
            for (i = 0; i < 40000; i = i + 1) begin
                apb_read(addr, v);
                if (v & bitmask) i = 40000;
            end
            if (!(v & bitmask)) begin
                fails = fails + 1;
                $display("FAIL wait_status timeout addr=%08x bit=%08x", addr, bitmask);
            end
        end
    endtask

    integer i; reg [31:0] v;
    reg [31:0] exp [0:7];
    reg [11:0] poly_a [0:255];
    reg [31:0] expo  [0:255];

    initial begin
        exp[0] = 32'hcbbd6d96; exp[1] = 32'h8f34e0d0;
        exp[2] = 32'hcecb1caa; exp[3] = 32'he7b8625a;
        exp[4] = 32'h95080d3b; exp[5] = 32'hb86d665d;
        exp[6] = 32'h03b34322; exp[7] = 32'h0295bdd9;

        // reset
        repeat (3) @(posedge clk);
        presetn <= 1'b1;
        repeat (3) @(posedge clk);

        // --- ID / VER (back-to-back, psel held high) ---
        apb_read(32'h4110_0F00, v); check("ID", v, 32'h51554152);
        apb_read(32'h4110_0F04, v); check("VER", v, 32'h00010000);

        // --- sha3 STATUS after reset: ready=1 ---
        apb_read(32'h4110_0004, v); check("sha3 STATUS", v, 32'h00000001);

        // --- sha3 wrong-device decode returns 0 ---
        apb_read(32'h4110_0100, v); check("unmapped", v, 32'h00000000);

        // --- SHA3-256 of {01,02,03,04} ---
        apb_write(32'h4110_0008, 32'h00000000);   // MODE = SHA3-256
        apb_write(32'h4110_0014, 32'h00000004);   // LEN = 4
        apb_write(32'h4110_000C, 32'h04030201);   // DATA_IN (bytes 01 02 03 04, LSB first)
        apb_write(32'h4110_0000, 32'h00000001);   // CTRL[0] absorb_start
        wait_status(32'h4110_0004, 32'h00000002); // until absorb_done
        apb_write(32'h4110_0018, 32'h00000020);   // SQUEEZE_LEN = 32
        apb_write(32'h4110_0000, 32'h00000002);   // CTRL[1] squeeze_start
        wait_status(32'h4110_0004, 32'h00000004); // until squeeze_done
        for (i = 0; i < 8; i = i + 1) begin
            apb_read(32'h4110_0010, v);           // DATA_OUT word i
            check("sha3 digest word", v, exp[i]);
        end

        // --- ntt forward NTT of kat/ntt_in1.txt -> kat/ntt_fwd1.txt ---
        // (same KAT pair tb_ntt.sv uses; load all 256 coefficients so the
        // transform sees no x-init RAM, then read all 256 back)
        $readmemh("kat/ntt_in1.txt", poly_a);
        $readmemh("kat/ntt_fwd1.txt", expo);
        apb_write(32'h4110_0800, 32'h00000000);   // CTRL: op=0, go=0 (reset wr/rd ptrs)
        for (i = 0; i < 256; i = i + 1)
            apb_write(32'h4110_0808, {20'h0, poly_a[i]});   // COEFF auto-increment
        apb_write(32'h4110_0800, 32'h00000001);   // CTRL: op=1 (fwd), go=0 (reset ptrs again)
        apb_write(32'h4110_0800, 32'h00000011);   // CTRL: go=1
        wait_status(32'h4110_0804, 32'h00000002); // until done
        for (i = 0; i < 256; i = i + 1) begin
            apb_read(32'h4110_0808, v);           // COEFF auto-increment
            check("ntt fwd out", v, expo[i]);
        end

        if (fails == 0) $display("CAPE APB TEST: PASS");
        else            $display("CAPE APB TEST: FAIL (%0d)", fails);
        $finish;
    end

endmodule
`default_nettype wire
