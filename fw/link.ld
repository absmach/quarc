/* link.ld - Quarc firmware linker script
 *
 * Phase 0 places everything in Boot ROM (16 KiB at 0x0000_0000). DRAM and
 * IRAM regions are declared so later phases can link bigger firmware
 * without needing a new script.
 */

OUTPUT_ARCH(riscv)
OUTPUT_FORMAT("elf32-littleriscv")
ENTRY(_start)

MEMORY
{
    BOOTROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    IRAM    (rx)  : ORIGIN = 0x00004000, LENGTH = 64K
    DRAM    (rwx) : ORIGIN = 0x00014000, LENGTH = 16K
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

    /* Data sections are reserved here for future phases. Phase 0 has no
     * .data / .bss because the firmware is a pure-immediate program. */
    .data : ALIGN(4) {
        *(.data*)
        *(.sdata*)
    } > DRAM

    .bss (NOLOAD) : ALIGN(4) {
        *(.bss*)
        *(.sbss*)
        *(COMMON)
    } > DRAM

    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) }
}
