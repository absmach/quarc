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

| Peripheral | Base (Ibex SoC) | Registers                                          |
| ---------- | --------------- | -------------------------------------------------- |
| sha3       | `0x1000_0000`   | CTRL, STATUS, MODE, DATA_IN, DATA_OUT, LEN, SQ_LEN |
| ntt        | `0x1000_0800`   | CTRL, STATUS, COEFF                                |
| uart       | `0x2000_0100`   | TX_DATA, STATUS (TXBUSY=1)                         |

Buffer sizes at the SoC instantiation (`rtl/bus.v`, `u_sha3`) are
`MSG_MAX=2560` / `OUT_MAX=1024`, which cover the largest software workload:
1184-byte `H(ek)` absorb, 1120-byte `J(z||c)` absorb, and 768-byte SampleNTT
squeeze. The `sha3.v` module defaults (512/256) apply only to standalone
instantiations, not the SoC.

## Prerequisites

- Linux host with `cc`, `make`, and (for the SoC simulation) `sv2v`,
  `iverilog`, and `riscv32-unknown-elf-gcc`.
- BeagleV-Fire reachable over SSH (`ssh quarc@<ip>`).

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

The steps below assume the fabric image and the firmware are built on the
host and moved over SSH. Board-side details (fabric MMIO window in the MSS
address map, physical UART routing, boot loader flow) are board bring-up work
and are marked **[TODO]** where the repo has no pinned-down recipe yet.

### 4.1 Program the Step 1 gateware into the PolarFire fabric

1. Run `make synth-step1` on the host (Section 3) and take the netlist /
   resource report to the PolarFire flow.
2. **[TODO]** Constrain and place: no PolarFire PDC pin constraints or
   Libero project live in the repo yet — only `boards/ulx3s.lpf` (ECP5).
   Create `boards/beaglev-fire.pdc` mapping `clk_25mhz`, `uart_tx`, `uart_rx`
   and the fabric-MMIO AXI bridge to the MPFS025T pins.
3. **[TODO]** Map the fabric peripherals into the MSS address space so the
   hard cores can reach `sha3`/`ntt`/`uart` (the base addresses in the table
   above, or a re-pointed window).
4. Program the fabric image (Libero bitstream/SSB flow, or the board's
   `mpfs`-based loader) and reboot.

### 4.2 Build and run the ML-KEM KAT self-test on the hard cores

`mlkem_sw.c` is written for a bare-metal target and hardcodes the Ibex SoC
MMIO bases. Two ways to run it on the board:

- **Bare-metal / second stage** — compile with the RISC-V GNU toolchain
  (`riscv64-unknown-elf-gcc -march=rv64gc -mabi=lp64d`, no libc) and run from
  the hard-core boot path. Override the three base `#define`s at the top of
  `fw/mlkem_sw.c` to the fabric window from step 4.1.3, keep the algorithm
  unchanged. The firmware comment describes this override point.
- **Userspace harness** — map the fabric MMIO window with `mmap`/`/dev/mem`
  and provide `host_put32`/`host_get32` shims (`-DHOST_TEST`), reusing
  `host_emu.c`'s access pattern. This exercises the same self-test code
  without a bare-metal boot chain.

Either way the self-test is `main()` (`mlkem_self_test`): keygen → encaps →
decaps against the FIPS 203 KATs in `fw/mlkem_kat.h`, then prints

```
MLKEM SW OK
```

over the UART at 115200 baud. A `MLKEM SW FAIL` means a firmware/MMIO bug or
a fabric image that does not match the buffers described in Section 1.

### 4.3 Expected bring-up checklist

- [ ] `make run` in `tools/host_test` prints `HOST KAT: PASS` (Section 1).
- [ ] `make sim-mlkem-sw-soc` prints `MLKEM SW OK` in simulation (Section 2).
- [ ] `make synth-step1` reports the Section 3 fit.
- [ ] Fabric image programs and boots on the board.
- [ ] Board run prints `MLKEM SW OK` on the UART.
