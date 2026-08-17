// boot_ram.S - Data RAM firmware test
// Writes a 256-word pattern to Data RAM at 0x14000, reads it back, verifies
// it, then exercises byte-enable stores, and prints "RAM OK\r\n" or
// "RAM FAIL\r\n".

    .section .text.init
    .globl _start
    // Ibex boots at boot_addr[31:8]||0x80 == 0x80 (see ibex_if_stage PC_BOOT),
    // so the real entry point must sit at offset 0x80.
    .org 0x80
_start:

#define RAM_BASE     0x00014000
#define UART_BASE    0x20000100
#define UART_TX_DATA 0x00
#define UART_STATUS  0x04
#define UART_TXBUSY  0x01

_start:
    li      sp, 0x00018000
    li      s0, RAM_BASE
    li      s1, UART_BASE

    // ---- write 256 words: value = 0xDEAD0000 | index
    li      t0, 256
    li      t1, 0
1:  li      t2, 0xDEAD0000
    or      t2, t2, t1
    sw      t2, 0(s0)
    addi    s0, s0, 4
    addi    t1, t1, 1
    addi    t0, t0, -1
    bnez    t0, 1b

    // ---- read back and verify each word
    li      s0, RAM_BASE
    li      t0, 256
    li      t1, 0
2:  lw      t2, 0(s0)
    li      t3, 0xDEAD0000
    or      t3, t3, t1
    bne     t2, t3, fail
    addi    s0, s0, 4
    addi    t1, t1, 1
    addi    t0, t0, -1
    bnez    t0, 2b

    // ---- byte-enable test: three byte stores then read the word
    li      s0, RAM_BASE
    li      t2, 0x11223344
    sb      t2, 0x400(s0)       // 0x44
    srli    t2, t2, 8
    sb      t2, 0x401(s0)       // 0x33
    srli    t2, t2, 8
    sb      t2, 0x402(s0)       // 0x22
    lw      t2, 0x400(s0)
    li      t3, 0x00223344
    bne     t2, t3, fail

    // ---- halfword test: sh then read
    li      t2, 0xABCD
    sh      t2, 0x404(s0)
    lw      t2, 0x404(s0)
    li      t3, 0x0000ABCD
    bne     t2, t3, fail

    // "RAM OK\r\n"
    li      a0, 'R'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, 'M'; jal ra, putc
    li      a0, ' '; jal ra, putc
    li      a0, 'O'; jal ra, putc
    li      a0, 'K'; jal ra, putc
    li      a0, '\r'; jal ra, putc
    li      a0, '\n'; jal ra, putc
    j       hang

fail:
    li      a0, 'R'; jal ra, putc
    li      a0, 'A'; jal ra, putc
    li      a0, 'M'; jal ra, putc
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

putc:
1:  lw      t0, UART_STATUS(s1)
    andi    t0, t0, UART_TXBUSY
    bnez    t0, 1b
    sb      a0, UART_TX_DATA(s1)
    ret

    .size _start, . - _start
