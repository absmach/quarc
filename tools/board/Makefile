# tools/board/Makefile - BeagleV-Fire bring-up tools
#
#   make devmem_probe   probe a fabric MMIO window via /dev/mem
#   make quarc_kat      ML-KEM-768 KAT self-test against the Quarc cape
#                       (fw/mlkem_sw.c built with -DBVF_MMIO, fabric MMIO
#                       bases 0x4110_0000 / 0x4110_0800)
#
# Both build on the board with the distro GCC (Debian riscv64) and run with
# sudo. Cross-compile from a Linux host with:
#   make CC=riscv64-linux-gnu-gcc

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra

.PHONY: all clean

all: devmem_probe quarc_kat

devmem_probe: devmem_probe.c
	$(CC) $(CFLAGS) -o $@ $<

quarc_kat: ../../fw/mlkem_sw.c
	$(CC) $(CFLAGS) -DBVF_MMIO -I../../fw -o $@ ../../fw/mlkem_sw.c

clean:
	rm -f devmem_probe quarc_kat
