// boot_phase0.S - Phase 0 banner firmware
// Boots from 0x0000_0000, prints "QUARC v0\r\n" over the UART, then loops.
// Pure assembly: no .rodata, no stack pushes (the data port only maps
// the peripheral region in Phase 0), no interrupt handlers.

    .section .text.init
    .globl _start

#define UART_BASE    0x20000100
#define UART_TX_DATA 0x00
#define UART_STATUS  0x04
#define UART_TXBUSY  0x01

_start:
    // Set up stack pointer to top of (planned) Data RAM. Not used in Phase 0
    // because we never call into a function that pushes — but conventional.
    li      sp, 0x00018000

    // Cache UART base address in s0 (callee-saved across our local putc).
    li      s0, UART_BASE

    li      a0, 'Q'
    jal     ra, putc
    li      a0, 'U'
    jal     ra, putc
    li      a0, 'A'
    jal     ra, putc
    li      a0, 'R'
    jal     ra, putc
    li      a0, 'C'
    jal     ra, putc
    li      a0, ' '
    jal     ra, putc
    li      a0, 'v'
    jal     ra, putc
    li      a0, '0'
    jal     ra, putc
    li      a0, '\r'
    jal     ra, putc
    li      a0, '\n'
    jal     ra, putc

hang:
    wfi
    j       hang

// putc: send byte in a0 to UART. Spins until tx_busy clears.
// Clobbers t0.
putc:
1:  lw      t0, UART_STATUS(s0)
    andi    t0, t0, UART_TXBUSY
    bnez    t0, 1b
    sb      a0, UART_TX_DATA(s0)
    ret

    .size _start, . - _start
