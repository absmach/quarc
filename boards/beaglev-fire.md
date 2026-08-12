# BeagleV-Fire (PolarFire MPFS025T) — Step 1 Bring-Up Test

How to bring up the Quarc **Step 1** partition on a BeagleV-Fire board from a
Linux host: SSH in, run the ML-KEM-768 KAT self-test against the hardware MMIO
firmware, and program the Step 1 gateware into the PolarFire fabric.

## Step 1 partition (two-step C/FPGA split)

Step 1 puts the post-quantum crypto in **C** on the BeagleV-Fire's hard
RISC-V cores. The PolarFire fabric carries only the sponge and the polynomial
engine plus SoC plumbing:

| In fabric (MPFS025T)           | Runs on the hard cores (RV64GC)        |
| ------------------------------ | -------------------------------------- |
| `keccak.v` + `keccak_engine.v` | `mlkem_sw.c` — full ML-KEM-768         |
| `sha3.v` (SHA3-256/512, SHAKE) | KAT self-test (`main()` / `host_main`) |
| `ntt.v` (NTT/invNTT/basemul)   |                                        |
| `uart.v`, `timer.v`            |                                        |
| `boot_rom.v`, `data_ram.v`     |                                        |

Hardware ML-KEM/ML-DSA controllers, KUE/keystore/lifecycle/rollback/SPI and
(for this bring-up) TRNG/DRBG are **not** instantiated. ML-KEM is validated
through the software path: `tools/host_test` on any host, and
`sim-mlkem-sw-soc` in simulation, then the same `mlkem_sw.c` against the real
fabric over MMIO.

### MMIO bases driven by `fw/mlkem_sw.c`

The firmware uses raw MMIO (`put32`/`get32`) into the fabric. On the Ibex SoC
these are absolute addresses; on the BeagleV-Fire they must be re-pointed at
the window where the MSS exposes the fabric peripherals.

| Peripheral | Base (Ibex SoC) | Base (BeagleV-Fire) | Registers                                          |
| ---------- | --------------- | ------------------- | -------------------------------------------------- |
| sha3       | `0x1000_0000`   | `0x4110_0000`       | CTRL, STATUS, MODE, DATA_IN, DATA_OUT, LEN, SQ_LEN |
| ntt        | `0x1000_0800`   | `0x4110_0800`       | CTRL, STATUS, COEFF                                |
| uart       | `0x2000_0100`   | (Linux console)     | TX_DATA, STATUS (TXBUSY=1)                         |

On the BeagleV-Fire, the cape APB slave sits at `0x4110_0000` inside the MSS
FIC3 window (`0x4xxx_xxxx`). `fw/mlkem_sw.c` overrides its base `#define`s to
these addresses; the `ID` word (`0x4110_0F00` = `0x5155_4152`, `"QUAR"`) is a
read-only gateware-identity check the harness can probe before running KAT.

Buffer sizes at the SoC instantiation (`rtl/bus.v`, `u_sha3`) are
`MSG_MAX=2560` / `OUT_MAX=1024`, which cover the largest software workload:
1184-byte `H(ek)` absorb, 1120-byte `J(z||c)` absorb, and 768-byte SampleNTT
squeeze. The `sha3.v` module defaults (512/256) apply only to standalone
instantiations, not the SoC.

## Prerequisites

- Linux host with `cc`, `make`, and (for the SoC simulation) `sv2v`,
  `iverilog`, and `riscv32-unknown-elf-gcc`.
- BeagleV-Fire reachable over SSH (`ssh beagle@192.168.100.33`, password
  `beagletemppwd`; sudo via `echo beagletemppwd | sudo -S`). Verified against
  a Debian 13 (Trixie) riscv64 image, kernel 6.12.48-linux4microchip+fpga.

## 1. Host-side self-test (no hardware required)

This is the fast gate: it compiles the **exact** `fw/mlkem_sw.c` firmware
against software models of the sha3/ntt coprocessors
(`tools/host_test/host_emu.c`) and runs the full FIPS 203 ML-KEM-768 KAT.

```
cd tools/host_test
make run
```

Expected output:

```
MLKEM SW OK
HOST KAT: PASS
```

Any byte mismatch prints `MLKEM SW FAIL` and exits non-zero. `make clean`
removes the `mlkem_kek` binary. `make -n run` shows the compile line
(`cc -DHOST_TEST -I../../fw -O2 -Wall -Wextra`).

## 2. SoC-level self-test (Ibex in simulation)

Boots `fw/boot_mlkem_sw.hex` (crt0.S + `mlkem_sw.c`) on the full Ibex SoC and
checks the UART output for the pass banner. This is the Step 1 acceptance
check that the MMIO protocol and the firmware agree before touching silicon.

```
make sim-mlkem-sw-soc
```

`tb/tb_mlkem_sw_soc.sv` must observe `MLKEM SW OK` on the UART. (Requires the
riscv32 toolchain, `sv2v`, and `iverilog`; `build/ibex.v` is produced
automatically.)

## 3. Build the Step 1 gateware and check the fit

```
make synth-step1
```

Measured on the current tree (ECP5 `synth_ecp5` as a fabric-fit proxy):

| Resource      | Step 1 (bring-up) | MPFS025T |
| ------------- | ----------------- | -------- |
| LUT4          | 18,954            | 23,040   |
| TRELLIS_FF    | 10,554            | —        |
| DP16KD (BRAM) | 32                | —        |

Fits the 23k-logic-element MPFS025T with margin. Restore `trng.v`/`drbg.v`
for real (non-KAT) keygen.

## 4. BeagleV-Fire board bring-up

The Step 1 crypto fabric is wrapped as a **cape** for the board's gateware
builder. The cape exposes the fabric behind a single APB slave window
(`0x4110_0000`, 4 KiB) that the hard RISC-V cores drive from Linux via
`/dev/mem` — the same access the `tools/board/devmem_probe.c` probe validated
against the stock PWM registers.

The cape lives in `boards/beaglev-fire/gateware/` and mirrors the component
layout the BeagleV-Fire gateware builder expects:

```
boards/beaglev-fire/gateware/
├── QUARC-CAPE.yaml                       # build-args: CAPE_OPTION:QUARC
└── sources/FPGA-design/script_support/components/CAPE/QUARC/
    ├── ADD_CAPE.tcl                      # BIF + MSS wiring, instantiates CAPE
    ├── constraints/mpfs-beaglev-fire/cape.pdc  # no cape-header pins (empty)
    ├── device-tree-overlays/quarc-cape.dtso    # reserves 0x4110_0000 window
    └── HDL/
        ├── CAPE.v                        # cape top: APB slave only
        ├── apb_quarc.v                   # APB3 <-> crypto bus bridge
        ├── sha3.v ntt.v keccak.v keccak_engine.v ntt_zetas.vh
```

The layout follows the gateware repo's current `main`, which (since the
v2022.3-era mirror used for bring-up) auto-globs `HDL/*.v`, expects the cape
constraints at `constraints/<board>/cape.pdc` (`board = mpfs-beaglev-fire` for
openbeagle CI fork builds), gathers the overlay from `device-tree-overlays/`,
and has the cape `ADD_CAPE.tcl` sourced from the MSS recursive build with a
`MSS_INT_F2M[58:0]` bus (sliced, unused bits GND-tied) instead of the old
`MSS_INT_F2M_A/B/C` pins.

Cape window register map (`paddr[11:0]`):

| Offset    | Access | Content                       |
| --------- | ------ | ----------------------------- |
| `0x0000`–`0x001F` | sha3 | CTRL, STATUS, MODE, DATA_IN, DATA_OUT, LEN, SQ_LEN, IRQ_EN |
| `0x0800`–`0x081F` | ntt  | CTRL, STATUS, COEFF           |
| `0x0F00`  | RO     | `ID` = `0x5155_4152` (`"QUAR"`) |
| `0x0F04`  | RO     | `VER` = `0x0001_0000`         |

The bridge strobes the peripherals on the APB setup phase (`psel && !penable`)
so each transfer commits once, and drives `PRDATA` combinationally from the
peripherals' read bus; the synchronous `DATA_OUT`/`COEFF` reads are latched on
the setup edge and are stable through the access phase.

### 4.1 Build the Step 1 gateware (cape bitstream)

The recommended path needs no local Libero: the openbeagle GitLab CI builds a
bitstream for every yaml in `custom-fpga-design/` on their Libero runner
(v2024.2/v2025.2). This is the flow described in the BeagleBoard docs
("Customize BeagleV-Fire Cape Gateware Using Verilog").

1. Fork `openbeagle.org/beaglev-fire/gateware` (new GitLab users must be
   manually approved before they can fork — request via the forum thread linked
   in the docs).
2. Add the cape and the build config to the fork:
   ```
   cp -r boards/beaglev-fire/gateware/sources/FPGA-design/script_support/components/CAPE/QUARC \
      <fork>/sources/FPGA-design/script_support/components/CAPE/QUARC
   cp boards/beaglev-fire/gateware/QUARC-CAPE.yaml <fork>/custom-fpga-design/quarc.yaml
   ```
   The yaml mirrors current `main`'s `my_custom_fpga_design.yaml` (pinned HSS
   with patches + `MSS: local: sources/FPGA-design/mss.bundle`), only with
   `CAPE_OPTION:QUARC`. The CI passes `BOARD:mpfs-beaglev-fire` for forks, so
   the cape constraint must live under `constraints/mpfs-beaglev-fire/`.
3. Commit and push. The `build-job` runner produces an artifact containing
   `artifacts/bitstreams/quarc/LinuxProgramming/{mpfs_bitstream.spi,mpfs_dtbo.spi}`
   (the `quarc` name follows the yaml filename; `mpfs_dtbo.spi` includes
   `quarc-cape.dtso`).
4. (Optional, for local iteration) With Microchip Libero SoC v2022.3–v2025.2
   installed, the same cape builds locally:
   ```
   cd <fork>/sources/FPGA-design
   libero SCRIPT:BUILD_BVF_GATEWARE.tcl "SCRIPT_ARGS: M2_OPTION:NONE CAPE_OPTION:QUARC BOARD:mpfs-beaglev-fire ONLY_CREATE_DESIGN"
   ```
   Drop `ONLY_CREATE_DESIGN` to run the full synth/place/route and export the
   `LinuxProgramming` bitstreams.
   **Note:** the cape `ADD_CAPE.tcl` is written against current `main`'s
   template but is untested against a real Libero run yet — expect MSS
   connection tweaks on first build.
   **Note:** before the Libero run, the cape bridge is validated in simulation
   with `boards/beaglev-fire/gateware/tb_apb_quarc.sv` (run `iverilog` against
   `.../CAPE/QUARC/HDL/`; 269 checks: ID/VER, SHA3-256 digest, and the
   256-coefficient NTT
   forward KAT through the APB setup-edge read path).

### 4.2 Program the board

1. Download the CI artifact (`build-job:archive`), unzip, and scp the per-design
   `LinuxProgramming` dir to the board:
   `scp -r artifacts/bitstreams/quarc/LinuxProgramming beagle@<ip>:~/`
2. On the board:
   ```
   echo beagletemppwd | sudo -S /usr/share/beagleboard/gateware/change-gateware.sh ~/LinuxProgramming
   sudo reboot
   ```
   This re-flashes the SPI NOR (`/dev/mtd0`) via the firmware-loader sysfs
   node (`/sys/class/firmware/mpfs-auto-update/`) and repacks the DT overlays
   (`mpfs_dtbo.spi` includes `quarc-cape.dtso`).
3. Verify the gateware is live:
   ```
   sudo devmem2 0x41100F00 w     # expect 0x51554152  ("QUAR")
   sudo devmem2 0x41100F04 w     # expect 0x00010000
   ```
   (`devmem2` may need `apt install devmem2`, or use `tools/board/devmem_probe.c`.)

### 4.3 Build and run the ML-KEM KAT self-test on the hard cores

`fw/mlkem_sw.c` drives the sha3/ntt coprocessors over MMIO. For the board it
is built with `-DBVF_MMIO`, which
- redirects `put32`/`get32` through an `mmap` of `/dev/mem` (the two fabric
  bases share the single 4 KiB page at `0x4110_0000`), and
- re-bases `SHA3_BASE`/`NTT_BASE` to `0x4110_0000` / `0x4110_0800`, and
- routes the banner to stdout instead of the SoC UART.

The self-test is `main()` (`mlkem_self_test`): keygen → encaps → decaps
against the FIPS 203 KATs in `fw/mlkem_kat.h`, then prints

```
MLKEM SW OK
```

Build on the board (or cross-compile with `CC=riscv64-linux-gnu-gcc`) and run
as root:

```
cd tools/board
make
sudo ./devmem_probe 0x41100000 8      # expect "QUAR" ID at 0x41100F00 (words 15-16)
sudo ./quarc_kat
```

`MLKEM SW OK` exercises the full algorithm against the real cape fabric: every
SHA3/SHAKE squeeze the KAT needs fits the cape sizing (max absorb 1184 B
`H(ek)`, max squeeze 768 B SampleNTT; `MSG_MAX 2560` / `OUT_MAX 1024`), and
the NTT driver follows the pointer-reset protocol (`CTRL` write before each
fresh polynomial load) that `tb_apb_quarc.sv` validates.

A `MLKEM SW FAIL` means a firmware/MMIO bug or a fabric image that does not
match the buffers described in Section 1.

### 4.4 Expected bring-up checklist

- [ ] `make run` in `tools/host_test` prints `HOST KAT: PASS` (Section 1).
- [ ] `make sim-mlkem-sw-soc` prints `MLKEM SW OK` in simulation (Section 2).
- [ ] `make synth-step1` reports the Section 3 fit.
- [ ] Quarc cape builds in Libero (`CAPE_OPTION:QUARC`) and exports
      `mpfs_bitstream.spi` + `mpfs_dtbo.spi`.
- [ ] `change-gateware.sh` re-flashes the board and it reboots into the
      Quarc gateware (`0x4110_0F00` reads `"QUAR"`).
- [ ] Board harness run prints `MLKEM SW OK`.
