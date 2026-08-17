/* link.ld - Quarc firmware linker script
 *
 * Code and read-only data live in the 32 KiB Boot ROM. Initialised .data is
 * stored in the ROM (LMA) and copied to DRAM by crt0.S; .bss is zeroed.
 */

OUTPUT_ARCH(riscv)
OUTPUT_FORMAT("elf32-littleriscv")
ENTRY(_start)

MEMORY
{
    BOOTROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    DRAM    (rwx) : ORIGIN = 0x00014000, LENGTH = 32K
}

SECTIONS
{
    .text.init : ALIGN(4) {
        KEEP(*(.text.init))
    } > BOOTROM

    .text : ALIGN(4) {
        *(.text*)
    } > BOOTROM

    .rodata : ALIGN(4) {
        *(.rodata*)
        *(.srodata*)
    } > BOOTROM

    /* Initialised data: stored in the ROM image, copied to DRAM by crt0. */
    __data_lma = LOADADDR(.data);
    .data : ALIGN(4) {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        __data_end = .;
    } > DRAM AT> BOOTROM

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
    } > DRAM

    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) }
}
