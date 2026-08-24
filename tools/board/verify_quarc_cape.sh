#!/bin/sh
# verify_quarc_cape.sh - post-flash bring-up check for the Quarc cape.
#
# Run on the BeagleV-Fire after programming the QUARC gateware and rebooting
# (see docs/guides/beaglev-fire-bringup.md section 4.2):
#
#   sudo ./verify_quarc_cape.sh
#
# 1. Reads the cape ID/VER registers through the FIC3 APB window:
#       ID  @ 0x4110_0F00 = 0x5155_4152 ("QUAR")
#       VER @ 0x4110_0F04 = 0x0001_0000
# 2. Runs the ML-KEM-768 KAT self-test against the fabric (fw/mlkem_sw.c,
#    built with -DBVF_MMIO; MMIO bases 0x4110_0000 / 0x4110_0800).
#
# Exit status 0 = cape is live and the ML-KEM self-test PASSes.

set -u
cd "$(dirname "$0")" || exit 1

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
check() { [ "$1" = "$2" ] || fail "$3"; }

echo "== Quarc cape bring-up check =="

# Build the tools if the binaries are missing (distro GCC on the board).
make >/dev/null 2>&1 || fail "make devmem_probe/quarc_kat"

[ -x ./devmem_probe ] || fail "devmem_probe missing"

# 1. Cape ID/VER (rw/ro registers in the FIC3 window).
probe=$(./devmem_probe 0x41100F00 2 2>&1) || fail "devmem_probe 0x41100F00 failed"
ID=$(printf '%s\n' "$probe" | sed -n 's/.*41100f00\] = 0x\([0-9a-f]*\).*/\1/p')
VER=$(printf '%s\n' "$probe" | sed -n 's/.*41100f04\] = 0x\([0-9a-f]*\).*/\1/p')

check "$ID" "51554152" "cape ID @ 0x41100F00 = '$ID', expected 51554152 (\"QUAR\")"
check "$VER" "00010000" "cape VER @ 0x41100F04 = '$VER', expected 00010000"
echo "PASS: cape ID 0x$ID (QUAR), VER 0x$VER"

# 2. ML-KEM-768 KAT self-test against the fabric.
[ -x ./quarc_kat ] || fail "quarc_kat missing"
out=$(./quarc_kat 2>&1) || true
printf '%s\n' "$out" | tail -3
printf '%s\n' "$out" | grep -q "MLKEM SW OK" || fail "ML-KEM KAT did not pass"

echo "PASS: MLKEM SW OK"
echo "== Quarc cape bring-up check: ALL PASS =="
