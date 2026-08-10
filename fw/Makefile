# fw/Makefile - firmware builds
#
# Outputs 32-bit-word memh files (one word per line) consumed by
# rtl/boot_rom.v via $readmemh:
#   boot.hex          default firmware (boot_phase0.S, banner)
#   boot_sha3.hex     Phase 1 SHA-3 self-test (boot_sha3.S)
#   boot_mlkem_sw.hex software ML-KEM-768 (crt0.S + mlkem_sw.c)

CROSS    := riscv32-unknown-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump

CFLAGS   := -march=rv32imc -mabi=ilp32 -nostdlib -nostartfiles -Os \
            -ffunction-sections -fdata-sections -fno-builtin
LDFLAGS  := -T link.ld -Wl,--gc-sections

# Convert raw binary into 32-bit-word hex, one word per line, little-endian.
# $readmemh wants pure hex words. Pad to 32 KiB (8192 words) so unfilled boot
# ROM cells are deterministic zeros.
BIN2HEX := python3 -c 'import sys; \
data = open(sys.argv[1], "rb").read(); \
data = data + b"\x00" * ((4 - len(data) % 4) % 4); \
words = [int.from_bytes(data[i:i+4], "little") for i in range(0, len(data), 4)]; \
words += [0] * (8192 - len(words)); \
open(sys.argv[2], "w").write("\n".join("%08x" % w for w in words) + "\n")'

.PHONY: all clean
all: boot.hex boot_sha3.hex boot_entropy.hex boot_ntt.hex boot_ram.hex boot_mlkem.hex boot_mlkem_sw.hex

build/boot_%.elf: boot_%.S link.ld
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@
	$(OBJDUMP) -d $@ > build/boot_$*.lst

# C firmware: crt0.S + C sources
build/boot_mlkem_sw.elf: crt0.S mlkem_sw.c mlkem_kat.h link.ld
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) crt0.S mlkem_sw.c -o $@
	$(OBJDUMP) -d $@ > build/boot_mlkem_sw.lst

build/boot_%.bin: build/boot_%.elf
	$(OBJCOPY) -O binary $< $@

boot.hex: build/boot_phase0.bin
	$(BIN2HEX) $< $@

boot_%.hex: build/boot_%.bin
	$(BIN2HEX) $< $@

clean:
	rm -rf build boot.hex boot_*.hex
