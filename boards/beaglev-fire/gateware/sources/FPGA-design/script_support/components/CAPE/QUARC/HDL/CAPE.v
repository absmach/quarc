// CAPE.v - BeagleV-Fire cape top: APB slave to the Quarc Step 1 crypto fabric
//
// This is the Cape module the Libero flow instantiates (see ADD_CAPE.tcl).
// It exposes only the APB slave interface plus PCLK/PRESETN; the Quarc cape
// uses no cape-header I/O, GPIO, or fabric interrupts. All logic lives in
// apb_quarc (bridge + sha3 + ntt + keccak_engine).

`default_nettype none
`timescale 1ns/1ps

module CAPE(
    // Inputs
    APB_SLAVE_SLAVE_PADDR,
    APB_SLAVE_SLAVE_PENABLE,
    APB_SLAVE_SLAVE_PSEL,
    APB_SLAVE_SLAVE_PWDATA,
    APB_SLAVE_SLAVE_PWRITE,
    PCLK,
    PRESETN,
    // Outputs
    APB_SLAVE_SLAVE_PRDATA
);

    input  [31:0] APB_SLAVE_SLAVE_PADDR;
    input         APB_SLAVE_SLAVE_PENABLE;
    input         APB_SLAVE_SLAVE_PSEL;
    input  [31:0] APB_SLAVE_SLAVE_PWDATA;
    input         APB_SLAVE_SLAVE_PWRITE;
    input         PCLK;
    input         PRESETN;
    output [31:0] APB_SLAVE_SLAVE_PRDATA;

    apb_quarc u_apb_quarc (
        .pclk    (PCLK),
        .presetn (PRESETN),
        .psel    (APB_SLAVE_SLAVE_PSEL),
        .penable (APB_SLAVE_SLAVE_PENABLE),
        .pwrite  (APB_SLAVE_SLAVE_PWRITE),
        .paddr   (APB_SLAVE_SLAVE_PADDR),
        .pwdata  (APB_SLAVE_SLAVE_PWDATA),
        .prdata  (APB_SLAVE_SLAVE_PRDATA)
    );

endmodule
`default_nettype wire
