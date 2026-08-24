# BeagleV-Fire Quarc Gateware: Build, Flash & Verification Guide

This document is a complete, end-to-end record of building the **Quarc Step 1 crypto
cape** gateware for the BeagleV-Fire (Microchip PolarFire SoC `MPFS025T-FCVG484E`),
flashing it to the board, and verifying it on the target. It includes the toolchain
environment, the full list of issues encountered (and their fixes), the exact commands
used, and benchmark results comparing the fabric against the CPU.

> **Related docs:** [`docs/README.md`](../README.md) — documentation index ·
> [`Guide 1: beaglev-fire-bringup.md`](beaglev-fire-bringup.md) — board bring-up
> (KAT self-test, MMIO map, checklist) · [`prd.md`](../prd.md) · [`implementation-plan.md`](../implementation-plan.md).

> **Status (2026-08-20):** All build/flash steps verified end-to-end. The gateware builds,
> flashes, and boots on the board; fabric ID/status registers verified. On silicon:
> SHA-3 correct and deterministic, forward/inverse NTT 256/256 correct.
> **Open item:** NTT basemul fails 2/128 pairs nondeterministically — root-caused to a
> setup-timing violation on the chained-modq path (§6.4). Full ML-KEM KAT on hardware
> waits on timing closure (§7.5).

---

## 1. Overview

| Item             | Value                                                                    |
| ---------------- | ------------------------------------------------------------------------ |
| Board            | BeagleV-Fire (PolarFire SoC `MPFS025T`, package `FCVG484`, `EXT` range)  |
| Host machine     | AMD Ryzen 7 5700U, Arch Linux (kernel 6.18.44-1-lts)                     |
| Build container  | `libero2204` — Ubuntu 22.04 (distrobox, shares host `/home/rodneyosodo`) |
| Libero           | `Libero_SoC_2026.1`, Synplify Pro Y-2026.03M                             |
| License daemons  | FlexNet **v11.19.6.0** (`lmgrd`, `actlmgrd`, `snpslmd`, `saltd`)         |
| Gateware repo    | `github.com/ubieda/beaglevfire-gateware` (fork)                          |
| Config           | `custom-fpga-design/quarc.yaml` (`CAPE_OPTION:QUARC`)                    |
| Top-level design | `QUARC_D833AF506FC7DB70459A187B`                                         |
| Cape fabric      | APB window @ `0x4110_0000` (SHA-3 @ `0x4110_0000`, NTT @ `0x4110_0800`)  |
| Board OS         | Debian Trixie, kernel `6.12.48-linux4microchip+fpga`                     |

The Quarc cape adds a hardware crypto fabric (Keccak-f[1600] SHA-3/SHAKE + ML-KEM NTT)
reachable from the PolarFire hard RISC-V cores over the cape APB window at physical
address `0x4110_0000`.

---

## 1.1 What has been done (status)

- [x] **License server fixed** — FlexNet v11.19.6.0 daemons under `lmgrd` serve
      `synplifypro_actel` (was: `snpslmd` exit 52 "restricted zone"). §3.
- [x] **Gateware builds** — HSS + MSS + cape synthesize, place & route, and export
      `mpfs_bitstream.spi` + `mpfs_dtbo.spi`. §4.
- [x] **Build blockers fixed and documented** — `.vh` include, P9 cape-header pins,
      32-bit `zcat`, 32-bit `fpbitgen_bin`. §4.3–§4.6.
- [x] **Flashed to the board** via the official `update-gateware.sh`; board reboots into
      the Quarc gateware. §5.
- [x] **Fabric verified live** — `QUARC_ID` = `0x51554152` ("QUAR"), `VER` = `0x00010000`,
      SHA3/NTT status machines run, fabric clock 50 MHz. §6.1–§6.2.
- [x] **Cape RTL proven correct** — `tb_apb_quarc.sv` passes 269/269 (SHA3-256 digest +
      256-coefficient NTT KAT) under iverilog. §6.3.
- [x] **Host KAT harness verified** — `tools/host_test` prints `HOST KAT: PASS` (ML-KEM SW OK).
- [x] **Software baselines measured** — SHA3-256 3.87 MB/s, NTT 79.9 µs (C, `-O2`). §7.2.
- [x] **Bitstream rebuilt & re-flashed from this repo (2026-08-19)** — incl. the
      keccak async-reset fix (`keccak_engine.v`/`keccak.v`: synchronous `rst_n` →
      async, validated deterministic on silicon with soft-reset recovery). §6.3.
- [x] **Silicon data-path verification (partial)** — SHA-3 correct; forward/inverse NTT
      256/256 correct; **basemul fails 2/128 pairs nondeterministically**. §6.4.
- [ ] **NTT basemul timing closure** — root cause confirmed: −16.5 ns setup violation on
      the chained-modq path at the 18.781 ns cape clock; first pipelining attempt improved
      to −6.3 ns but Synplify re-merged the stages. Need retiming off / `syn_preserve`,
      rebuild, re-flash, then `verify_quarc_cape.sh` must print `MLKEM SW OK`. §6.4.
- [ ] **Measured hardware benchmarks** — projected figures only (§7.3); need the timing
      closure above plus an IRQ-driven driver.

## 1.2 The flow at a glance

```
 host (Arch Linux)                    container                    board (BeagleV-Fire)
 ─────────────────                    ─────────                    ────────────────────
 distrobox enter libero2204  ──►  Libero: synth → P&R ──►  scp artifacts ──►  update-gateware.sh
      │                            export .spi/.dtbo                                │
      ▼                                                                             ▼
 edit cape HDL in the fork    ◄────── iterate ◄──────────────  reboot → probe "QUAR" → quarc_kat
```

The six commands that matter (detailed in the sections that follow):

| # | Action                          | Command (host unless noted)                                   | Section |
| - | ------------------------------- | ------------------------------------------------------------- | ------- |
| 1 | Start the license daemons       | `lmgrd -c …` (one-time per boot; §3.3 script)                 | §3.3    |
| 2 | Launch the build                | `distrobox enter libero2204 -- /tmp/run_build.sh`             | §4.2    |
| 3 | Collect the artifacts           | `work/…/LinuxProgramming/{mpfs_bitstream.spi,mpfs_dtbo.spi}`  | §4.7    |
| 4 | Copy to board + flash           | `scp` then `update-gateware.sh` on the board                  | §5.1    |
| 5 | Verify fabric is live           | `sudo ./devmem_probe 0x41100F00` on the board                 | §6.2    |
| 6 | Run the ML-KEM KAT              | `sudo ./quarc_kat` on the board                               | §6.3    |

If a step fails, jump straight to §10 (troubleshooting checklist) or the
per-section "Issue:" notes — every blocker hit during the real build is
documented with its fix.

---

## 2. Host / Container Environment

The build container is a **distrobox** Ubuntu 22.04 box named `libero2204`. It shares the
host's home directory and network namespace:

```
/home/rodneyosodo   -> /home/rodneyosodo   (bind mount, same directory)
/etc/resolv.conf    -> /etc/resolv.conf    (host tailscale DNS)
/etc/hosts          -> /etc/hosts
hostname            = elgon (same on host and container)
```

Get into it:

```bash
docker exec -it libero2204 bash
# root for privileged fixes:
docker exec -it -u root libero2204 bash
```

### 2.1 Required tools inside the container

Installed during bring-up (32-bit runtime for Libero's 32-bit binaries):

```bash
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y \
  libc6-i386 libstdc++6:i386 zlib1g:i386 \
  libx11-6:i386 libxext6:i386 libxrender1:i386 \
  libxt6:i386 libsm6:i386 libice6:i386
```

> These are required because Microchip ships some tools (e.g. `fpbitgen_bin`,
> `zcat`) as 32-bit ELF binaries needing `/lib/ld-linux.so.2` and 32-bit X11/C++ libs.

---

## 3. License Server Setup (the big blocker)

### 3.1 Symptom

Synopsys `snpslmd` exited with:

```
snpslmd: can't initialize:
EXITING DUE TO SIGNAL 52 Exit reason 20
You are attempting to run the license server on a non-privileged domain/zone
```

so Synplify synthesis could not check out `synplifypro_actel` (`FlexNet -5,21`).

### 3.2 Root cause

`snpslmd`'s **zone / cloud-detection** policy rejected the host. Extensive
investigation (strace of every file open, netlink route/addr dumps, DNS metadata probes)
showed the daemon does **not** read container markers (no `/.dockerenv`, cgroup, DMI,
`/sys/devices/virtual/net` in the traced path). The rejection was tied to the _combination_
of the daemon build and how it was launched:

- The stock `snpslmd` shipped inside Libero 2026.1 was **SCL_2021.12 / FlexNet
  v11.16.4**, which enforces the zone check.
- When launched **standalone** (even from the host), it exited 52.
- When launched by **`lmgrd`** with the **FlexNet v11.19.6.0** daemon bundle, it logs
  `Running on Hypervisor: Not determined - treat as Physical` and runs fine.

### 3.3 Fix

1. Download the FlexNet daemon bundle required by Libero v2024.2+:
   `Linux_Licensing_Daemon_11.19.6.0_64-bit.tar.gz`
   (Microchip licensing downloads page; link supplied in the license e-mail).

2. Replace the daemons in `LicenseDaemons/` — this is the directory the
   `DAEMON`/`VENDOR` lines in `License.dat` point to, and the one `lmgrd` actually
   spawns:

   ```bash
   DEST=/home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons
   SRC=/tmp/opencode/daemons-11.19
   cp $SRC/snpslmd   $DEST/snpslmd.bin
   cp $SRC/actlmgrd  $DEST/actlmgrd
   cp $SRC/saltd     $DEST/saltd
   cp $SRC/lmgrd     $DEST/lmgrd
   cp $SRC/lmutil    $DEST/lmutil
   cp $SRC/lmstat    $DEST/lmstat
   ```

   > Note: `Designer/bin64/` also ships daemons, but lmgrd uses the paths in
   > `License.dat`. Only the `LicenseDaemons/` set needs to be v11.19 for the server
   > to work (verified: `lmstat` reports `snpslmd: UP v11.19.6`).

3. Make the `VENDOR snpslmd` wrapper simply exec the v11.19 binary
   (the old v11.16 `getdents64` lock-file bug and the LD_PRELOAD shim are no longer
   needed):

   ```bash
   sudo tee /home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons/snpslmd >/dev/null <<'EOF'
   #!/bin/sh
   exec /home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons/snpslmd.bin "$@"
   EOF
   sudo chmod 755 /home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons/snpslmd
   ```

4. Edit `License.dat` header (hostname + daemon paths):

   ```
   SERVER elgon a8934ac9c23b 1702
   DAEMON actlmgrd  /home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons/actlmgrd
   DAEMON saltd /home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons/saltd
   VENDOR snpslmd  /home/rodneyosodo/microchip/Libero_SoC_2026.1/LicenseDaemons/snpslmd
   ```

5. Start lmgrd and confirm:
   ```bash
   cd /home/rodneyosodo/microchip/license
   nohup /home/rodneyosodo/microchip/Libero_SoC_2026.1/Libero_SoC/Designer/bin64/lmgrd \
     -c License.dat -l lmgrd.log >/dev/null 2>&1 &
   export LM_LICENSE_FILE=1702@elgon
   lmutil lmstat -a -c 1702@elgon
   # expect: snpslmd: UP v11.19.6, "Users of synplifypro_actel: (Total of 1 ...)"
   ```

The `lmgrd.log` confirms the daemon now treats the host as physical:

```
(snpslmd) Running on Hypervisor: Not determined - treat as Physical
(snpslmd) Server started on elgon for: SSST SCL_WAN_DISABLE ... synplifypro_actel
```

### 3.4 Debugging artifacts (for reference)

- Full strace of the failing daemon: `/home/rodneyosodo/.tmp-zone-full.log`
- The daemon reads: `/etc/hosts`, `/etc/resolv.conf`, `/proc/net/dev`, netlink
  `RTM_GETADDR`/`RTM_GETROUTE`, `/proc/sys/vm/*`, `/proc/cpuinfo`, `/proc/meminfo`,
  `/proc/sysvipc/*`, and does a DNS PTR query for `254.169.254.169.in-addr.arpa`
  (cloud-metadata reverse lookup). It never touches container markers.

---

## 4. Building the Gateware

### 4.1 Configuration

`custom-fpga-design/quarc.yaml` selects the Quarc cape and the HSS/MSS sources:

```yaml
HSS:
  type: git
  link: https://github.com/polarfire-soc/hart-software-services.git
  branch: next
  commit: 4bea7e24f3e5ef1de360a80b0a27abb1eb6134e0
  patches: { common: [...], variants: { default: [...] } }
  make_clean: 1
MSS:
  type: git
  local: sources/FPGA-design/mss.bundle
  branch: default
  patches:
    common:
      - 0001-Copy-.vh-include-files-to-project-hdl-dir.patch
    variants:
      default: []
gateware:
  type: sources
  build-args: "M2_OPTION:NONE CAPE_OPTION:QUARC"
```

### 4.2 Build runner

`/tmp/run_build.sh` sets the environment and runs the builder:

```bash
#!/bin/bash
set -x
export HOME=/home/rodneyosodo USER=rodneyosodo
export PATH=/opt/riscv/riscv-unknown-elf-gcc:/opt/riscv/riscv64-unknown-elf/bin:...:$PATH
export SC_INSTALL_DIR=/home/rodneyosodo/microchip
export FPGENPROG=.../Designer/bin64/fpgenprog
export LD_LIBRARY_PATH=.../Designer/lib64:.../Designer/lib
export LM_LICENSE_FILE=1702@elgon
export GIT_CONFIG_GLOBAL=/home/rodneyosodo/.tmp-gitconfig
# Xvfb :99 for the Libero GUI
# design-version prompt: printf "\n" |  (auto-increment)
cd /home/rodneyosodo/gw-beaglevfire-gateware
printf "\n" | python3 build-bitstream.py custom-fpga-design/quarc.yaml 2>&1 | tee build.log
```

Run it inside the container:

```bash
docker exec -u rodneyosodo -e HOME=/home/rodneyosodo -e DISPLAY=:99 \
  -e LD_LIBRARY_PATH=... -e LM_LICENSE_FILE=1702@elgon \
  -e GIT_CONFIG_GLOBAL=/home/rodneyosodo/.tmp-gitconfig \
  -d libero2204 bash -c 'cd /home/rodneyosodo/gw-beaglevfire-gateware && /tmp/run_build.sh quarc.yaml > build.log 2>&1; echo done > build.done'
```

The full pipeline (HSS compile → MSS config → Libero project gen → **synthesis** →
place & route → timing → **bitstream export**) takes ~30–40 min on the Ryzen 7 5700U.

### 4.3 Issue: `ntt_zetas.vh` include not found

Symptom (during Synplify `compiler` step):

```
@E: Can't open file ntt_zetas.vh
```

Cause: `hdl_source.tcl` (in the MSS repo) imports `*.v` files from the cape HDL
directory into the Libero project, but the `` `include "ntt_zetas.vh" `` file was not
copied. The MSS repo is reset on every build (`git reset --hard` + `git clean -fdx`),
so an inline edit is lost.

Fix: ship it as an **MSS git patch** so the builder applies it every run.

`patches/mss/0001-Copy-.vh-include-files-to-project-hdl-dir.patch`:

```diff
--- a/scripts/hdl_source.tcl
+++ b/scripts/hdl_source.tcl
@@ -34,6 +34,10 @@ foreach file [glob ... "CAPE" $cape_option "HDL" "*.v"]] {
     import_files -convert_EDN_to_HDL 0 -library {work} -hdl_source $file
 }

+foreach file [glob -nocomplain -type f [file join $current_dir "script_support" "components" "CAPE" $cape_option "HDL" "*.vh"]] {
+    file copy -force $file [file join $project_dir "hdl" [file tail $file]]
+}
+
 build_design_hierarchy
```

Notes:

- The MSS repo files use **CRLF** line endings; the patch must preserve them or the
  whole file diffs. `git format-patch` produced a minimal 4-line patch.
- The builder's global git config must tolerate CRLF context lines:
  `~/.tmp-gitconfig` gains:
  ```ini
  [apply]
      whitespace = fix
  ```
  (Otherwise `git am` fails with "patch does not apply" on the CRLF context.)

### 4.4 Issue: cape-header P9 pins not present (place & route)

Symptom (P&R, after the synthesis fix):

```
PDCPF-01: Port name doesn't exist in the netlist ... [set_io -port_name P9[19] ...]
PDCPF-01: Port name doesn't exist in the netlist ... [set_io -port_name P9[20] ...]
```

Cause: the shared `base_design.pdc` constrains cape-header pins A10/A11
(`P9[19]`/`P9[20]`, the MSS I2C0 SCL/SDA). Other capes create the `P9[20:19]` pad bus
and delete the scalar `P9_19`/`P9_20` ports; the QUARC `ADD_CAPE.tcl` did not, so those
top-level ports floated and the PDC targets didn't exist.

Fix in `sources/FPGA-design/script_support/components/CAPE/QUARC/ADD_CAPE.tcl`
(mirrors the reference `NONE` cape):

```tcl
# The Quarc cape uses no cape-header I/O. The shared base_design.pdc constrains
# cape-header pins A10/A11 (P9[19]/P9[20]), so expose the P9[20:19] pad bus and
# wire it to the MSS I2C0 so the base PDC resolves.
sd_create_bus_port -sd_name ${sd_name} -port_name {P9} -port_direction {INOUT} \
    -port_range {[20:19]} -port_is_pad {1}
sd_create_pin_slices -sd_name ${sd_name} -pin_name {P9} -pin_slices {[20] [19]}
sd_delete_ports -sd_name ${sd_name} -port_names {P9_19}
sd_delete_ports -sd_name ${sd_name} -port_names {P9_20}
sd_connect_pins -sd_name ${sd_name} -pin_names {"P9[19]" "BVF_RISCV_SUBSYSTEM:I2C0_SCL"}
sd_connect_pins -sd_name ${sd_name} -pin_names {"P9[20]" "BVF_RISCV_SUBSYSTEM:I2C0_SDA"}
```

> This file lives in the tracked gateware repo (not a reset submodule), so the edit
> persists across builds.

### 4.5 Issue: router `zcat` not found

Symptom (P&R router):

```
sh: 1: /.../Designer/am/exe/zcat: not found
```

Cause: Libero's `zcat` is a 32-bit ELF requiring `/lib/ld-linux.so.2`, missing in the
container. Fix (do the proper thing and add 32-bit runtime, then the binary works):

```bash
sudo apt-get install -y libc6-i386
```

(With the loader installed the original `zcat` runs. If you still need a substitute,
`cp /usr/bin/zcat .../am/exe/zcat` also works.)

### 4.6 Issue: `export_bitstream_file` → `fpbitgen_bin` 32-bit libs

Symptom:

```
.../binfp/fpbitgen: 56: .../binfp/fpbitgen_bin: not found
```

Cause: `fpbitgen_bin` is a 32-bit binary needing the 32-bit loader **and** 32-bit X11,
C++ and zlib. Fix:

```bash
sudo dpkg --add-architecture i386 && sudo apt-get update
sudo apt-get install -y libx11-6:i386 libxext6:i386 libxrender1:i386 \
  libxt6:i386 libsm6:i386 libice6:i386 libstdc++6:i386 zlib1g:i386
```

The `fpbitgen` wrapper (via `actel_setup_vars_nomotif`) prepends `Designer/libfp`
(32-bit) and `/usr/lib/i386-linux-gnu` to `LD_LIBRARY_PATH`; with the system 32-bit
libraries present the export succeeds:

```
Exporting Bitstream File(s) Finished ... (Elapsed time 00:00:23)
```

### 4.7 Build outputs

```
bitstream/LinuxProgramming/mpfs_bitstream.spi   (2,380,032 B  raw SPI bitstream)
bitstream/LinuxProgramming/mpfs_dtbo.spi        (5,166 B      MCHP DTBO container)
bitstream/LinuxProgramming/mpfs_bitstream_spi.digest
bitstream/FlashProExpress/QUARC_D833AF506FC7DB70459A187B.job
bitstream/DirectC/QUARC_D833AF506FC7DB70459A187B.dat
```

`mpfs_dtbo.spi` is the "MCHP" container holding the individual `.dtbo` overlays:
`adc-mmc`, `base`, `miv-ihc`, `quarc-cape` (592 B), `pcie`.

---

## 5. Flashing the Board

The board boots: **SPI NOR flash (`mtd0`, 16 MB) → HSS → U-Boot (`beaglev_fire.itb`
from SD) → Linux**. The SPI flash layout:

| Offset       | Contents                                             |
| ------------ | ---------------------------------------------------- |
| `0x00000000` | 16-byte boot header (`00 00 00 00                    | <bitstream ptr> | ...`) |
| `0x00000400` | `mpfs_dtbo.spi` (MCHP device-tree-overlay container) |
| `0x005ff000` | `mpfs_bitstream.spi` (the FPGA bitstream)            |

The **supported** flashing path is the board's own `update-gateware.sh`, which uses the
kernel `mpfs-auto-update` firmware interface so HSS coordinates the layout and
checksums. Do **not** hand-write raw `mtd_debug` writes for production — use this.

### 5.1 One-line official flash

```bash
# copy the two artifacts to the board
scp bitstream/LinuxProgramming/mpfs_bitstream.spi beagle@192.168.100.33:/home/beagle/
scp bitstream/LinuxProgramming/mpfs_dtbo.spi       beagle@192.168.100.33:/home/beagle/

# on the board, install + trigger the official updater (auto-reboots)
ssh beagle@192.168.100.33
sudo cp /home/beagle/mpfs_bitstream.spi /lib/firmware/
sudo cp /home/beagle/mpfs_dtbo.spi       /lib/firmware/
sudo bash /usr/share/microchip/gateware/update-gateware.sh
# -> "FPGA update ready. Rebooting."  (board reboots itself)
```

`/usr/share/microchip/gateware/update-gateware.sh` (kernel 6.12 path) does, in order:

1. `flash_erase /dev/mtd0 0 16` — erase the boot-header + DTBO area (64 KB)
2. `echo 1 > /sys/class/firmware/mpfs-auto-update/loading`
3. `cat /lib/firmware/mpfs_dtbo.spi > .../mpfs-auto-update/data` — kernel/HSS writes DTBO
4. `dd if=/dev/zero of=/dev/mtd0 count=1 bs=4` — golden-image marker
5. `cat /lib/firmware/mpfs_bitstream.spi > .../mpfs-auto-update/data` — kernel/HSS writes
   the bitstream
6. `reboot` — HSS reprograms the FPGA between Linux shutdown and restart

There is a `change-gateware.sh` helper (`/usr/share/beagleboard/gateware/change-gateware.sh
<gateware-option>`) that wraps this for the pre-installed gateware options.

### 5.2 Fallback: raw SPI writes (debug only)

If the firmware interface is unavailable (e.g. older 6.1 kernels use
`update-gateware-6-1.sh` with `mtd_debug` at `0x400`), the equivalent manual sequence is:

```bash
# back up first!
sudo dd if=/dev/mtd0 of=/home/beagle/flash_backup.bin bs=4096

# erase the header+dtbo region and rewrite header + dtbo + bitstream
sudo flash_erase /dev/mtd0 0 4          # blocks 0..3 (0x0..0x4000)
printf '\x00\x00\x00\x00\x00\xf4\x5f\x00\x00\x00\x00\x00\xff\xff\xff\xff' > /tmp/hdr.bin
sudo mtd_debug write /dev/mtd0 0 16 /tmp/hdr.bin
sudo mtd_debug write /dev/mtd0 $((0x400)) $(stat -c%s mpfs_dtbo.spi) mpfs_dtbo.spi
# erase bitstream region, then write it
sudo flash_erase /dev/mtd0 $((0x5ff000)) $((0x246000/0x1000))
sudo mtd_debug write /dev/mtd0 $((0x5ff000)) $(stat -c%s mpfs_bitstream.spi) mpfs_bitstream.spi
```

> ⚠️ **Caution:** probing arbitrary fabric addresses with `/dev/mem` while the fabric is
> not yet configured can hang the PolarFire CPU (it stalls the bus). Only read the Quarc
> window **after** the bitstream is confirmed loaded.

---

## 6. Verification on the Board

### 6.1 Device tree overlay

After reboot the Quarc node is live under the fabric bus:

```bash
ls /proc/device-tree/fabric-bus@40000000/
#   gpio@41100000  gpio@41200000  gpio@44000000  quarc-crypto@41100000  ...
cat /proc/device-tree/fabric-bus@40000000/quarc-crypto@41100000/compatible
#   quarc,quarc-crypto
```

### 6.2 Fabric ID / status registers (verified working)

`read1.py` (see below) reads a single 32-bit word from `/dev/mem`:

```bash
sudo python3 read1.py 0x41100F00   # QUARC_ID  -> 0x51554152  ("QUAR")
sudo python3 read1.py 0x41100F04   # QUARC_VER -> 0x00010000  (v1.0)
sudo python3 read1.py 0x41100004   # sha3 STATUS -> 0x00000001 (ready)
```

```python
# read1.py
import mmap, os, struct, sys
def r32(addr):
    PAGE = addr & ~0xFFF; off = addr & 0xFFF
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=PAGE)
    raw = m[off:off+4]; m.close()
    return struct.unpack('<I', raw)[0] if len(raw) == 4 else -1
print("0x%08x = 0x%08x" % (int(sys.argv[1],16), r32(int(sys.argv[1],16))))
```

Verified values:

| Register                    | Address       | Value        | Meaning                            |
| --------------------------- | ------------- | ------------ | ---------------------------------- |
| `QUARC_ID`                  | `0x4110_0F00` | `0x51554152` | ASCII **"QUAR"** — fabric identity |
| `QUARC_VER`                 | `0x4110_0F04` | `0x00010000` | gateware v1.0                      |
| `sha3 STATUS`               | `0x4110_0004` | `0x00000001` | bit0 = ready                       |
| `sha3 STATUS` after absorb  |               | `0x00000003` | bit1 = absorb_done                 |
| `sha3 STATUS` after squeeze |               | `0x00000007` | bit2 = squeeze_done                |
| `fabric-clk3` rate          | sysfs         | 50 MHz       | cape fabric clock                  |

The SHA-3 control state machine demonstrably runs (absorb/squeeze complete, meaning the
Keccak engine executes its 24 rounds), and the APB register reads work.

### 6.3 SHA-3 / NTT data-path read-back (RESOLVED: stale bitstream replaced 2026-08-19)

Driving the data path through **raw `/dev/mem`**:

- `DATA_OUT` (`sha3` @ `0x4110_0010`) read back **all zeros** after squeeze.
- `NTT COEFF` read-back returned values that **do not match** the software Kyber NTT
  reference (0/256 match).
- The repo's canonical check, `tools/board/quarc_kat` (`fw/mlkem_sw.c -DBVF_MMIO`),
  prints `MLKEM SW FAIL` against the currently flashed fabric.

**However, the RTL is proven correct:** the cape's own testbench
(`boards/beaglev-fire/gateware/tb_apb_quarc.sv`) drives the exact APB setup-edge
protocol and passes **269/269 checks** under iverilog, including the full SHA3-256
digest of `{01,02,03,04}` and the 256-coefficient forward-NTT KAT:

```
$ iverilog -g2012 -I boards/.../QUARC/HDL -o /tmp/tb.vvp \
      boards/.../QUARC/HDL/{CAPE.v,apb_quarc.v,sha3.v,ntt.v,keccak.v,keccak_engine.v} \
      boards/beaglev-fire/gateware/tb_apb_quarc.sv
$ vvp /tmp/tb.vvp
PASS      sha3 STATUS: 00000001
PASS sha3 digest word: cbbd6d96
...
PASS      ntt fwd out: 000009e9
CAPE APB TEST: PASS
```

Since the control path works (ID = "QUAR", absorb/squeeze status transitions fire,
`perm_done` pulses) but the compute data path disagrees with the (correct) RTL, the
conclusion was that the **bitstream then in the board's SPI NOR did not match the
repo's cape RTL**. **This is now resolved:** the gateware was rebuilt from the repo
(local Libero, §4) and re-flashed (`full_asyncfix.bin`, 2026-08-19). On-silicon results:

- **SHA-3: correct.** `sha3_256("abc")` prefix `0xA75D983A` read back LE bytes
  `3a 98 5d a7`; deterministic across runs; recovers after a soft reset.
- **Forward NTT: perfect.** 256/256 coefficients match the software reference.
- **Basemul (PointwiseMul): nondeterministic errors — see §6.4**, the one remaining
  data-path defect, root-caused to a setup-timing violation on the chained-modq path.

The registered APB read-handshake caveat stands: raw `mmap` reads on `/dev/mem` must be
driven with APB setup-edge timing — which is why the repo ships `fw/mlkem_sw.c`
(`-DBVF_MMIO`) and `tb_apb_quarc.sv` as the sanctioned accessors.

### 6.4 OPEN: NTT basemul silicon failures = setup-timing violation on the chained modq path

After the §6.3 rebuild/reflash, per-op probes on the board
(`/home/beagle/probe_ntt.txt`) isolated the failing operation:

| Operation                    | Result on silicon                          |
| ---------------------------- | ------------------------------------------ |
| SHA-3 (`sha3_256("abc")`)    | correct, deterministic                     |
| Forward NTT (256 coeff)      | **256/256 match — perfect**                |
| Inverse NTT                  | correct                                    |
| **Basemul / PointwiseMul**   | **2/128 pairs wrong**, error pairs vary run-to-run |

Forward NTT uses a *single* `modq` per butterfly and is flawless; basemul chains
*two* `modq`s (`modq(a1·b1)` → `·zeta` → `modq`) plus `addq`. The Libero timing report
(`work/libero/designer/QUARC_D833AF506FC7DB70459A187B/max_report.json`) confirms why:

- Worst setup slack **−16.519 ns** at the cape clock (PLL OUT3 / FIC3, constraint
  **18.781 ns**): minimum period required **35.165 ns** over **45 logic levels**,
  path `modq_3.p_8_mulonly_0[23:0] → wd_fsm[9]`.
- **620/1000 reported paths negative** (612 inside `u_ntt`) — the violation is
  systematic, not marginal.
- A path that fails setup by −16 ns samples metastable/garbage data — exactly the
  observed "a few wrong coefficients, different each run" signature. Simulation
  (zero-delay or unit-delay) cannot catch this, which is why every KAT passed in
  iverilog while silicon failed.

**Fix attempt #1 (2026-08-20): FSM pipelining of the basemul datapath.**
`ntt.v` was restructured to split the chain across cycles — new registers
`m_p0/m_p1/m_q0/m_q1` (products, one `modq` deep), `m_p1z` (`modq(m_p1·zeta)`),
and MUL phases extended ph3→ph7 (latch products → zeta-multiply → write ca →
write cb → settle). Validated in simulation: `tb_apb_quarc.sv` PASS plus a dedicated
4-group hardware-KAT testbench (`/tmp/tb_ntt_bm.sv`: fwd1, fwd2, inv, basemul — 4/4).

**Result: improved but NOT closed.** Rebuild `max_report.json` (design version 9944):

| Metric                  | Before pipeline | After pipeline |
| ----------------------- | --------------- | -------------- |
| Worst setup slack       | −16.519 ns      | **−6.315 ns**  |
| Required min period     | 35.165 ns       | 30.858 ns      |
| Worst path logic levels | 45              | 42             |

The worst path (`widx[2] → wd_fsm[10]`, slack −6.315 ns) still traverses both MACC
chains (`modq_0.p_2_mulonly` → `WideMult_*` → `modq_0.un2_r_mulonly`) and the `addq`
into `wd_fsm` **in one OUT3 cycle**: Synplify merged/re-shared the new pipeline
registers back into the combinational cone (the regs exist as capture endpoints —
168 paths end at `m_p1[..]/m_p1z[..]` — but no top-1000 path *launches* from them).
The fixed sources are synced into this repo (`rtl/ntt.v` and the board-gateware copy,
md5 `f8871591…`); they are functionally correct but do not yet meet timing.

**Next steps (in order):**

1. Stop Synplify from collapsing the pipeline: either disable register retiming /
   balancing for the synthesis run, or protect the stages with `syn_preserve`
   attributes (or an equivalent structural barrier the retimer cannot cross).
   Alternative: pre-register `zeta_sel` (currently combinational from `widx` through
   the `zget` ROM mux) so no `widx → zeta → multiply` path exists at all.
2. Rebuild (§4), confirm `max_report.json` shows OUT3 worst slack ≥ 0.
3. Build the full image, flash (§5), re-run the probes + `quarc_kat`:
   basemul must report 0/128 and the KAT must print `MLKEM SW OK`.
4. Then proceed to the benchmarks (§7.5).

Artifacts: pre-fix flash backup `/home/beagle/mtd0_pre_asyncfix_backup.bin`;
flashed image `/home/beagle/full_asyncfix.bin`
(md5 `505301f8ba372ee80a7ef49611f50207`); probe logs `/home/beagle/probe_ntt.txt`,
`probe_sha3.txt`.

---

## 7. Benchmarks

Measured on the board (PolarFire SoC `MPFS025T`, 4× RV64GC application cores ~625 MHz,
Debian Trixie kernel 6.12.48). The CPU figures are **measured and reproducible**; the
hardware figures remain **projected from the RTL** until the NTT basemul timing
violation is closed (§6.4) — SHA-3 and forward-NTT data paths are already proven on
silicon (§6.3), but `quarc_kat` cannot pass end-to-end until basemul is fixed.

### 7.1 What the numbers mean (and what they don't)

The only numbers that can be *honestly* published today are the CPU software baselines
and the fabric MMIO access cost. The "hardware" rows are fabric-bound projections from
the verified RTL (keccak = 24 rounds at 1 round/clock = 26 cycles/perm; NTT = 896
butterflies × 4 cycles = 3,584 cycles), using the on-board `fabric-clk3` = 50 MHz.

> **Earlier bogus figure:** a first attempt measured "SHA3 hardware" at ~32 ms/op by
> re-opening `/dev/mem` on every read in Python (106 µs per read). That is an artifact of
> the measurement harness, not the fabric. The real single-mmap access cost is ~9 ns.

### 7.2 Measured (board, reproducible)

| Metric                                                      | Value        | Notes                                   |
| ----------------------------------------------------------- | ------------ | --------------------------------------- |
| Fabric register read (single mmap, `-DBVF_MMIO` style)      | **0.009 µs** | ~112k reads/s; 4 KiB page at 0x4110_0000 |
| Fabric register write (single mmap)                          | 0.008 µs     | ~123k writes/s                          |
| **SW SHA3-256 (C, `-O2`)** 64 B                             | 34.7 µs      | 1.85 MB/s                               |
| **SW SHA3-256 (C, `-O2`)** 1 KiB                            | 274.2 µs     | 3.73 MB/s                               |
| **SW SHA3-256 (C, `-O2`)** 4 KiB                            | 1059.5 µs    | 3.87 MB/s                               |
| **SW ML-KEM NTT-256 (C, `-O2`)**                             | 79.9 µs      | 12.5k ops/s                             |
| Cape fabric clock (`fabric-clk3`, from sysfs)                | 50 MHz       | read from `/sys/kernel/debug/clk`       |

### 7.3 Projected hardware (fabric-bound, RTL-derived)

| Operation              | HW (fabric-bound) | SW (C)   | **Speedup** |
| ---------------------- | ----------------- | -------- | ----------- |
| SHA3-256, 64 B         | 1.0 µs            | 34.7 µs  | **33×**     |
| SHA3-256, 256 B        | 1.6 µs            | 68.8 µs  | **44×**     |
| SHA3-256, 1 KiB        | 4.7 µs            | 274.2 µs | **59×**     |
| SHA3-256, 4 KiB        | 16.6 µs           | 1059.5 µs| **64×**     |
| ML-KEM NTT-256 (fwd)   | 71.7 µs           | 79.9 µs  | **1.1×**    |

Derivation: `fabric-clk3` = 50 MHz → 20 ns/cycle. Keccak-f[1600] = 24 rounds + start/done
≈ 26 cycles = 0.52 µs. SHA3-256 rate = 136 B/block; a message of length `L` needs
`⌈L/136⌉+1` absorb blocks + 1 squeeze permutation. NTT = 896 butterflies × 4
phases/butterfly = 3,584 cycles = 71.7 µs.

### 7.4 Why the NTT speedup is only ~1.1× (and why that's fine)

The fabric clock (50 MHz) is ~12× slower than the 625 MHz RV64 core, and the NTT is a
single-port, 4-cycle/butterfly serial engine — so a raw transform cannot beat the CPU by
much. The ML-KEM-768 win comes from **offloading the many SHA3/SHAKE permutations**
(keygen/encaps/decaps each run dozens to hundreds of them) at 33–64×, and from freeing
the CPU to run other work concurrently. The NTT is the smaller contributor.

### 7.5 What must happen before real silicon numbers

1. Close the NTT basemul timing violation (§6.4): protect the pipeline stages from
   Synplify retiming (or pre-register `zeta_sel`), rebuild, confirm OUT3 slack ≥ 0.
2. Re-flash and re-run `tools/board/verify_quarc_cape.sh`; it must print `MLKEM SW OK`.
3. Benchmark with a driver that issues one request and blocks on an IRQ (the cape
   exposes `irq_done`), not a STATUS-polling loop — this is what turns the projected
   numbers into measured ones.

### 7.6 Reproduction commands

```bash
# on the board, from a checkout of this repo:
cd tools/board
make                        # builds devmem_probe, quarc_kat, bench_sha3, bench_ntt

sudo ./devmem_probe 0x41100F00 2   # ID "QUAR" @ 0x4110_0F00, VER @ 0x4110_0F04
sudo ./quarc_kat                   # expects "MLKEM SW OK" against the fabric
sudo ./verify_quarc_cape.sh        # one-shot post-flash bring-up check

./bench_sha3                      # SW SHA3-256 baseline (C, -O2)
./bench_ntt                       # SW ML-KEM NTT-256 baseline (C, -O2)
```

The `bench_sha3` / `bench_ntt` sources are self-contained C references (no hardware
needed) and are the numbers quoted in §7.2.

---

## 8. Rollback / Recovery

A full pre-flash image is saved at:

- Host: `/tmp/opencode/beaglev-fire-flash-backup.bin` (16 MB)
- Board: `/home/beagle/flash_full_backup.bin`, `/home/beagle/mtd0_bitstream_backup.bin`

To restore the stock gateware, either re-run the official updater with the stock
`mpfs_bitstream.spi`/`mpfs_dtbo.spi` from `/usr/share/beagleboard/gateware/default/`, or
write back the backup image with `flashcp`:

```bash
sudo flashcp /home/beagle/flash_full_backup.bin /dev/mtd0
```

---

## 9. File Manifest

Paths are relative to this repository (`absmach/quarc`) unless noted.

| Path                                                                                            | Purpose                                                         |
| ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `docs/guides/beaglev-fire-bringup.md`                                                           | Guide 1: bring-up doc (KAT self-test, MMIO map, checklist)      |
| `boards/beaglev-fire/gateware/QUARC-CAPE.yaml`                                                  | build config; drop into fork as `custom-fpga-design/quarc.yaml` |
| `boards/beaglev-fire/gateware/sources/FPGA-design/script_support/components/CAPE/QUARC/`        | cape HDL + `ADD_CAPE.tcl` + constraints + dtso                  |
| `boards/beaglev-fire/gateware/patches/hss/*.patch`                                              | HSS patches `0001`–`0005` (incl. GCC-16 fixes)                  |
| `boards/beaglev-fire/gateware/patches/mss/0001-Copy-.vh-include-files-to-project-hdl-dir.patch` | `.vh` copy fix for Synplify                                     |
| `boards/beaglev-fire/gateware/tb_apb_quarc.sv`                                                  | 269-check APB cape testbench (iverilog)                         |
| `tools/board/devmem_probe.c` + `Makefile`                                                       | fabric MMIO probe (`QUAR` ID check)                             |
| `tools/board/quarc_kat` (builds `fw/mlkem_sw.c -DBVF_MMIO`)                                     | ML-KEM-768 KAT against the fabric                               |
| `tools/board/bench_sha3.c`, `bench_ntt.c`                                                      | SW SHA3-256 / NTT-256 baselines (self-contained, §7.2 figures)  |
| `tools/board/verify_quarc_cape.sh`                                                              | one-shot post-flash bring-up check                              |
| `fw/mlkem_sw.c`, `fw/mlkem_kat.h`                                                               | ML-KEM-768 software firmware (MMIO coprocessor drivers)         |
| `kat/ntt_in1.txt`, `kat/ntt_fwd1.txt`                                                           | NTT KAT pair for `tb_apb_quarc.sv` (gitignored, local)          |
| `~/.tmp-gitconfig` (host)                                                                       | build git config (`apply.whitespace = fix`)                     |
| `/tmp/run_build.sh` (container)                                                                 | environment + build runner                                      |

Fork-deployment target layout (in `openbeagle.org/beaglev-fire/gateware`):

| Fork path                                                   | Source                                                 |
| ----------------------------------------------------------- | ------------------------------------------------------ |
| `custom-fpga-design/quarc.yaml`                             | `boards/beaglev-fire/gateware/QUARC-CAPE.yaml`         |
| `sources/FPGA-design/script_support/components/CAPE/QUARC/` | `boards/beaglev-fire/gateware/sources/.../CAPE/QUARC/` |
| `patches/hss/*.patch`, `patches/mss/*.patch`                | `boards/beaglev-fire/gateware/patches/`                |

---

## 10. Troubleshooting Checklist

- **`snpslmd` exit 52** → daemons must be FlexNet **v11.19.6.0** and launched by
  `lmgrd` (not standalone). Check `lmstat -a` shows `snpslmd: UP`.
- **`Can't open file ntt_zetas.vh`** → the MSS patch is applied; confirm
  `work/libero/hdl/ntt_zetas.vh` exists after `Generate Libero project`.
- **`PDCPF-01 ... P9[19]`** → QUARC `ADD_CAPE.tcl` must create the `P9[20:19]` pad bus
  (see §4.4).
- **`zcat: not found` / `fpbitgen_bin: not found`** → 32-bit runtime missing; install
  the `:i386` packages from §2.1.
- **Fabric reads hang the CPU** → only probe the Quarc window (`0x41100000`) after the
  bitstream is confirmed loaded (ID register reads "QUAR").
- **Board not reachable** → the `mpfs-auto-update` flow reboots the board; wait ~1 min.
