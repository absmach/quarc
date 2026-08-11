// apb_quarc.v - APB3 slave bridge exposing the Quarc Step 1 crypto fabric
//
// BeagleV-Fire cape gateware: the PolarFire MSS hard RISC-V cores reach the
// Quarc fabric coprocessors through the cape APB window (FIC3, physical base
// 0x4110_0000, 4 KiB decode). Within the window (paddr[11:0]):
//
//   0x0000 .. 0x001F  sha3   (see rtl/sha3.v register map)
//   0x0800 .. 0x081F  ntt    (see rtl/ntt.v register map)
//   0x0F00            ID     (RO) 32'h5155_4152  ("QUAR")
//   0x0F04            VER    (RO) gateware version
//
// Protocol. The peripheral bus strobe (bus_req) is derived from the APB setup
// phase (psel && !penable) so a transfer commits exactly once, on the setup
// edge. PRDATA is driven combinationally from the peripherals' read bus; the
// synchronous DATA_OUT / COEFF read words are latched by the peripherals on
// that same setup edge, so they are stable for the whole access phase and
// sampled by the master at the access edge. Writes also land on the setup
// edge, once per transfer.

`default_nettype none
`timescale 1ns/1ps

module apb_quarc (
    input  wire        pclk,
    input  wire        presetn,
    // APB slave
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata
);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    localparam [31:0] QUARC_ID  = 32'h51554152;   // "QUAR"
    localparam [31:0] QUARC_VER = 32'h00010000;   // 1.0

    // ------------------------------------------------------------------
    // APB decode
    // ------------------------------------------------------------------
    wire        setup   = psel && !penable;              // capture strobe
    wire        sel_sha3 = psel && (paddr[11:8] == 4'h0); // 0x0000-0x01FF
    wire        sel_ntt  = psel && (paddr[11:8] == 4'h8); // 0x0800-0x09FF
    wire        sel_id   = psel && (paddr[11:8] == 4'hF); // 0x0F00 block
    wire [31:0] id_rdata = (paddr[7:0] == 8'h00) ? QUARC_ID  :
                           (paddr[7:0] == 8'h04) ? QUARC_VER : 32'h0;

    // ------------------------------------------------------------------
    // SHA-3 / SHAKE sponge (client 0 of the shared Keccak engine)
    // ------------------------------------------------------------------
    wire        sha3_perm_req;
    wire [1599:0] sha3_perm_state_in;
    wire        sha3_perm_done;
    wire [1599:0] sha3_perm_state_out;
    wire [31:0] sha3_rdata;

    sha3 #(
        .OUT_MAX (1024),          // >= 768-byte SampleNTT squeeze
        .MSG_MAX (2560)           // >= 1184-byte H(ek), 1120-byte J(z||c)
    ) u_sha3 (
        .clk          (pclk),
        .rst_n        (presetn),
        .bus_req      (setup && sel_sha3),
        .bus_we       (pwrite),
        .bus_addr     (paddr[7:0]),
        .bus_wdata    (pwdata),
        .bus_rdata    (sha3_rdata),
        .bus_ack      (),
        .irq_done     (),
        .perm_req     (sha3_perm_req),
        .perm_state_in (sha3_perm_state_in),
        .perm_done    (sha3_perm_done),
        .perm_state_out(sha3_perm_state_out)
    );

    // ------------------------------------------------------------------
    // Shared Keccak-f[1600] permutation engine (client 0 only)
    // ------------------------------------------------------------------
    keccak_engine u_keccak (
        .clk         (pclk),
        .rst_n       (presetn),
        .c0_req      (sha3_perm_req),
        .c0_state_in (sha3_perm_state_in),
        .c0_done     (sha3_perm_done),
        .c0_state_out(sha3_perm_state_out),
        .c1_req      (1'b0),
        .c1_state_in (1600'b0),
        .c1_done     (),
        .c1_state_out()
    );

    // ------------------------------------------------------------------
    // NTT / inverse NTT / basemul engine (client port unused)
    // ------------------------------------------------------------------
    wire [31:0] ntt_rdata;

    ntt u_ntt (
        .clk       (pclk),
        .rst_n     (presetn),
        .bus_req   (setup && sel_ntt),
        .bus_we    (pwrite),
        .bus_addr  (paddr[7:0]),
        .bus_wdata (pwdata),
        .bus_rdata (ntt_rdata),
        .bus_ack   (),
        .c_req     (1'b0), .c_we(1'b0), .c_addr(8'h00), .c_wdata(32'h0),
        .c_rdata   (), .c_ack()
    );

    // ------------------------------------------------------------------
    // Read data mux
    // ------------------------------------------------------------------
    assign prdata = sel_sha3 ? sha3_rdata :
                    sel_ntt  ? ntt_rdata  :
                    sel_id   ? id_rdata   : 32'h0;

endmodule
`default_nettype wire
