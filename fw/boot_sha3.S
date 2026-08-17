// boot_sha3.S - Phase 1 firmware test
// Computes SHA3-256("abc") through the MMIO (0x1000_0000), compares the
// digest to the expected constant, and prints "SHA3 OK\r\n" or "SHA3 FAIL\r\n"
// over UART. Pure immediate program: no .rodata (the data port does not map
// the boot ROM region), no stack pushes.

    .section .text.init
    .globl _start
    // Ibex boots at boot_addr[31:8]||0x80 == 0x80.
    .org 0x80

#define SHA3_BASE   0x10000000
#define CTRL        0x00
#define STATUS      0x04
#define MODE        0x08
#define DATA_IN     0x0C
#define DATA_OUT    0x10
#define LEN_REG     0x14
#define SQ_LEN      0x18

#define UART_BASE    0x20000100
#define UART_TX_DATA 0x00
#define UART_STATUS  0x04
#define UART_TXBUSY  0x01

_start:
    li      sp, 0x00018000
    li      s0, SHA3_BASE
    li      s1, UART_BASE

    // MODE = SHA3-256
    li      a0, 0
    sw      a0, MODE(s0)
    // LEN = 3
    li      a0, 3
    sw      a0, LEN_REG(s0)
    // DATA_IN = "abc" (little-endian word)
    li      a0, 0x00636261
    sw      a0, DATA_IN(s0)
    // CTRL = absorb_start
    li      a0, 1
    sw      a0, CTRL(s0)

    // poll STATUS[1] = absorb_done
1:  lw      t0, STATUS(s0)
    andi    t0, t0, 0x02
    beqz    t0, 1b

    // SQUEEZE_LEN = 32, CTRL = squeeze_start
    li      a0, 32
    sw      a0, SQ_LEN(s0)
    li      a0, 2
    sw      a0, CTRL(s0)

    // poll STATUS[2] = squeeze_done
1:  lw      t0, STATUS(s0)
    andi    t0, t0, 0x04
    beqz    t0, 1b

    // compare 8 output words against SHA3-256("abc") =
    // 3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532
    lw      t0, DATA_OUT(s0)
    li      t1, 0xa75d983a
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0xb225e24f
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0x2d175c04
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0xbd90d36b
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0x6e085f85
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0x5b529d3e
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0x45e2bf46
    bne     t0, t1, fail
    lw      t0, DATA_OUT(s0)
    li      t1, 0x32154311
    bne     t0, t1, fail

    // PASS: "SHA3 OK\r\n"
    li      a0, 'S'; jal ra, putc
    li      a0, 'H'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, '3'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'O'; jal ra, putc
    li      a0, 'K'; jal ra, putc
    li      a0, '\r'; jal ra, putc
    li      a0, '\n'; jal ra, putc
    j       hang

fail:
    // "SHA3 FAIL\r\n"
    li      a0, 'S'; jal ra, putc
    li      a0, 'H'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, '3'; jal ra, putc
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
1:  lw      t0, UART_STATUS(s1)
    andi    t0, t0, UART_TXBUSY
    bnez    t0, 1b
    sb      a0, UART_TX_DATA(s1)
    ret

    .size _start, . - _start
