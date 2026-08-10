// crt0.S - C runtime for Quarc firmware
// Sets up the stack, zeroes .bss, copies .data from ROM (LMA) to DRAM (VMA)
// and calls main. C programs are linked into the 32 KiB boot ROM.
//
// The bus maps the ROM region on the data port (read-only) so .rodata and
// .data initialisers stored in the ROM are readable by the program.

    .section .text.init
    .globl _start
    // Ibex boots at boot_addr[31:8]||0x80 == 0x80.
    .org 0x80

    .globl _start
_start:
    // stack grows down from the top of DRAM (0x0001_4000 + 32 KiB)
    li      sp, 0x0001C000

    // zero .bss
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b

    // copy .data from LMA (ROM) to VMA (DRAM)
2:  la      t0, __data_lma
    la      t1, __data_start
    la      t2, __data_end
3:  bgeu    t1, t2, 4f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       3b

4:  jal     main

hang:
    wfi
    j       hang

    .size _start, . - _start
