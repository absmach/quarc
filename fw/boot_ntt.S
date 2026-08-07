// boot_ntt.S - Phase 3 firmware test
// Fills the NTT engine with all-ones, runs the forward NTT, then the inverse
// NTT in place (the forward result stays in the engine's own RAM), verifies
// the round-trip restores all-ones, and prints "NTT OK\r\n" or "NTT FAIL\r\n".

    .section .text.init
    .globl _start

#define NTT_BASE    0x10000800
#define NTT_CTRL    0x00
#define NTT_STATUS  0x04
#define NTT_COEFF   0x08

#define UART_BASE    0x20000100
#define UART_TX_DATA 0x00
#define UART_STATUS  0x04
#define UART_TXBUSY  0x01

_start:
    li      sp, 0x00018000
    li      s0, NTT_BASE
    li      s1, UART_BASE

    // ---- load all-ones polynomial (256 coefficients of 1)
    li      t0, 256
    li      t1, 1
1:  sw      t1, NTT_COEFF(s0)
    addi    t0, t0, -1
    bnez    t0, 1b

    // ---- forward NTT: op=1, go=1 -> 0x11
    li      a0, 0x11
    sw      a0, NTT_CTRL(s0)
    jal     ra, wait_ntt

    // ---- inverse NTT (result already in engine RAM): op=2, go=1 -> 0x12
    li      a0, 0x12
    sw      a0, NTT_CTRL(s0)
    jal     ra, wait_ntt

    // ---- read back; verify every coefficient == 1
    li      t0, 256
    li      t4, 0
2:  lw      t1, NTT_COEFF(s0)
    addi    t1, t1, -1
    or      t4, t4, t1
    addi    t0, t0, -1
    bnez    t0, 2b
    beqz    t4, ok

    // "NTT FAIL\r\n"
    li      a0, 'N'; jal ra, putc
    li      a0, 'T'; jal ra, putc
    li      a0, 'T'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'F'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, 'I'; jal ra, putc
    li      a0, 'L'; jal ra, putc
    j       done_print

ok:
    // "NTT OK\r\n"
    li      a0, 'N'; jal ra, putc
    li      a0, 'T'; jal ra, putc
    li      a0, 'T'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'O'; jal ra, putc
    li      a0, 'K'; jal ra, putc

done_print:
    li      a0, '\r'; jal ra, putc
    li      a0, '\n'; jal ra, putc

hang:
    wfi
    j       hang

// wait_ntt: poll NTT_STATUS[1] (done). Clobbers t0.
wait_ntt:
3:  lw      t0, NTT_STATUS(s0)
    andi    t0, t0, 2
    beqz    t0, 3b
    ret

// putc: send byte in a0 to UART. Spins until tx_busy clears. Clobbers t0.
putc:
4:  lw      t0, UART_STATUS(s1)
    andi    t0, t0, UART_TXBUSY
    bnez    t0, 4b
    sb      a0, UART_TX_DATA(s1)
    ret

    .size _start, . - _start
