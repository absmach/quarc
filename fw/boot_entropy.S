// boot_entropy.S - Phase 2 firmware test
// Enables the TRNG, harvests 8 random words, reseeds the SHAKE-256 DRBG,
// generates 32 bytes, checks they are non-zero, and prints "ENT OK\r\n"
// or "ENT FAIL\r\n" over UART.

    .section .text.init
    .globl _start
    // Ibex boots at boot_addr[31:8]||0x80 == 0x80.
    .org 0x80

#define TRNG_BASE    0x10000500
#define TRNG_CTRL    0x00
#define TRNG_STATUS  0x04
#define TRNG_RANDOM  0x08

#define DRBG_BASE    0x10000500
#define DRBG_CTRL    0x20
#define DRBG_STATUS  0x24
#define DRBG_OUT     0x28
#define DRBG_ENTROPY 0x34

#define UART_BASE    0x20000100
#define UART_TX_DATA 0x00
#define UART_STATUS  0x04
#define UART_TXBUSY  0x01

_start:
    li      sp, 0x00018000
    li      s0, TRNG_BASE
    li      s1, DRBG_BASE
    li      s2, UART_BASE

    // enable TRNG
    li      a0, 1
    sw      a0, TRNG_CTRL(s0)

    // harvest 8 random words -> DRBG entropy
    li      t2, 8
1:  // poll TRNG STATUS[0] = ready
    lw      t0, TRNG_STATUS(s0)
    andi    t0, t0, 1
    beqz    t0, 1b
    lw      t0, TRNG_RANDOM(s0)     // RANDOM (clears ready)
    sw      t0, DRBG_ENTROPY(s1)    // ENTROPY_IN word
    addi    t2, t2, -1
    bnez    t2, 1b

    // DRBG reseed
    li      a0, 2
    sw      a0, DRBG_CTRL(s1)
1:  lw      t0, DRBG_STATUS(s1)
    andi    t0, t0, 2               // done
    beqz    t0, 1b

    // DRBG generate 32 bytes
    li      a0, (32 << 8) | 1
    sw      a0, DRBG_CTRL(s1)
1:  lw      t0, DRBG_STATUS(s1)
    andi    t0, t0, 2               // done
    beqz    t0, 1b

    // read 8 output words; OR them together
    li      t2, 8
    li      t3, 0
2:  lw      t0, DRBG_OUT(s1)
    or      t3, t3, t0
    addi    t2, t2, -1
    bnez    t2, 2b
    beqz    t3, fail                // all-zero output = FAIL

    // "ENT OK\r\n"
    li      a0, 'E'; jal ra, putc
    li      a0, 'N'; jal ra, putc
    li      a0, 'T'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'O'; jal ra, putc
    li      a0, 'K'; jal ra, putc
    li      a0, '\r'; jal ra, putc
    li      a0, '\n'; jal ra, putc
    j       hang

fail:
    li      a0, 'E'; jal ra, putc
    li      a0, 'N'; jal ra, putc
    li      a0, 'T'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'F'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, 'I'; jal ra, putc
    li      a0, 'L'; jal ra, putc
    li      a0, '\r'; jal ra, putc
    li      a0, '\n'; jal ra, putc

hang:
    wfi
    j       hang

// putc: send byte in a0 to UART. Spins until tx_busy clears. Clobbers t0.
putc:
1:  lw      t0, UART_STATUS(s2)
    andi    t0, t0, UART_TXBUSY
    bnez    t0, 1b
    sb      a0, UART_TX_DATA(s2)
    ret

    .size _start, . - _start
