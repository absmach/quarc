# Host-side ML-KEM KAT self-test harness.
#
# Builds fw/mlkem_sw.c (the exact SoC firmware) against software models of the
# sha3 / ntt coprocessors so the full ML-KEM-768 KAT self-test can run on any
# host CPU - including the BeagleV-Fire's hard RISC-V cores. See
# boards/beaglev-fire.md for the board bring-up instructions.

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
CPPFLAGS = -DHOST_TEST -I../../fw

HOST_SRCS = host_emu.c ../../fw/mlkem_sw.c

mlkem_kek: $(HOST_SRCS)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(HOST_SRCS)

run: mlkem_kek
	./mlkem_kek

clean:
	rm -f mlkem_kek

.PHONY: run clean
