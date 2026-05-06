# fw/Makefile - Phase 0 firmware build
#
# Output: fw/boot.hex (32-bit-word memh format, one word per line) consumed
# by rtl/boot_rom.v via $readmemh.

CROSS    := riscv32-unknown-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump

CFLAGS   := -march=rv32imc -mabi=ilp32 -nostdlib -nostartfiles -Os \
            -ffunction-sections -fdata-sections
LDFLAGS  := -T link.ld -Wl,--gc-sections

ELF      := boot_phase0.elf
BIN      := boot_phase0.bin
HEX      := boot.hex
LST      := boot_phase0.lst

.PHONY: all clean
all: $(HEX)

$(ELF): boot_phase0.S link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) boot_phase0.S -o $@
	$(OBJDUMP) -d $@ > $(LST)

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

# Convert raw binary into 32-bit-word hex, one word per line, little-endian.
# $readmemh wants pure hex words — no @addr, no comments. Pad output to 16 KiB
# (4096 words) so unfilled boot ROM cells are deterministic zeros.
$(HEX): $(BIN)
	python3 -c 'import sys; \
data = open("$<", "rb").read(); \
data = data + b"\x00" * ((4 - len(data) % 4) % 4); \
words = [int.from_bytes(data[i:i+4], "little") for i in range(0, len(data), 4)]; \
words += [0] * (4096 - len(words)); \
open("$@", "w").write("\n".join("%08x" % w for w in words) + "\n")'

clean:
	rm -f $(ELF) $(BIN) $(HEX) $(LST)
