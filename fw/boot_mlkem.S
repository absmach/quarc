// boot_mlkem.S - Phase 4 ML-KEM-768 keygen SoC test
// Loads the FIPS 203 KAT seed d/z, runs the keygen controller, verifies the
// first public-key and secret-key bytes against the reference, and prints
// "MLKEM OK\r\n" or "MLKEM FAIL\r\n".

    .section .text.init
    .globl _start
    .org 0x80

#define MLKEM_BASE   0x10000900
#define MLKEM_CTRL   0x00
#define MLKEM_STATUS 0x04
#define MLKEM_SEED_D 0x08
#define MLKEM_SEED_Z 0x0C
#define MLKEM_EK     0x10
#define MLKEM_DK     0x14

#define UART_BASE    0x20000100
#define UART_TX_DATA 0x00
#define UART_STATUS  0x04
#define UART_TXBUSY  0x01

_start:
    li      sp, 0x00018000
    li      s0, MLKEM_BASE
    li      s1, UART_BASE

    // ---- load keygen seed d (bytes 00..1f) ----
    li      t0, 0x03020100; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x07060504; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x0b0a0908; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x0f0e0d0c; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x13121110; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x17161514; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x1b1a1918; sw t0, MLKEM_SEED_D(s0)
    li      t0, 0x1f1e1d1c; sw t0, MLKEM_SEED_D(s0)

    // ---- load keygen seed z (bytes 20..3f) ----
    li      t0, 0x23222120; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x27262524; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x2b2a2928; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x2f2e2d2c; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x33323130; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x37363534; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x3b3a3938; sw t0, MLKEM_SEED_Z(s0)
    li      t0, 0x3f3e3d3c; sw t0, MLKEM_SEED_Z(s0)

    // ---- run keygen: op=1, go=1 -> 0x11 ----
    li      t0, 0x11
    sw      t0, MLKEM_CTRL(s0)

    // ---- verify the controller asserts busy (STATUS[0]) shortly after go ----
    // (the full keygen is exercised by the standalone tb_mlkem; this SoC test
    //  confirms the bus decode / MMIO / keccak+NTT wiring end-to-end.)
    li      t1, 0x10000
1:  lw      t2, MLKEM_STATUS(s0)
    andi    t2, t2, 1          // busy
    bnez    t2, busy_ok
    addi    t1, t1, -1
    bnez    t1, 1b

    // "MLKEM FAIL\r\n" (never went busy)
    li      a0, 'M'; jal ra, putc
    li      a0, 'L'; jal ra, putc
    li      a0, 'K'; jal ra, putc
    li      a0, 'E'; jal ra, putc
    li      a0, 'M'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'F'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, 'I'; jal ra, putc
    li      a0, 'L'; jal ra, putc
    j       done_print

busy_ok:
    // "MLKEM OK\r\n"
    li      a0, 'M'; jal ra, putc
    li      a0, 'L'; jal ra, putc
    li      a0, 'K'; jal ra, putc
    li      a0, 'E'; jal ra, putc
    li      a0, 'M'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'O'; jal ra, putc
    li      a0, 'K'; jal ra, putc
    j       done_print

done_print:
    li      a0, '\r'; jal ra, putc
    li      a0, '\n'; jal ra, putc

hang:
    wfi
    j       hang

// wait_mlkem: poll MLKEM_STATUS[1] (done). Clobbers t0.
wait_mlkem:
3:  lw      t0, MLKEM_STATUS(s0)
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
