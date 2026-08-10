# Quarc — Post-Quantum Secure Element

> _"A post-quantum Secure Element with hardware-accelerated ML-KEM and ML-DSA, securing IoT devices today and anchoring trust for TEEs tomorrow."_

**Status:** DRAFT — Internal Only | **Classification:** Proprietary & Confidential

---

## What Is Quarc

Quarc is a post-quantum Secure Element (SE): a cryptographic coprocessor targeting the [ULX3S](https://radiona.org/ulx3s/) open-hardware FPGA board (Lattice ECP5-85K). It integrates with a host MCU via SPI, provides hardware-accelerated post-quantum cryptographic operations (ML-KEM-768 and ML-DSA-65 per NIST FIPS 203/204), stores device keys with hardware-enforced usage policy, and serves as the hardware root of trust for IoT devices.

Quarc is the answer to the question: _what does a TROPIC01-class SE look like after the PQC transition?_

### Why PQC Now

Every SE shipping today — Infineon SLx9, NXP SE050, Microchip ATECC608, TROPIC01 — relies on classical cryptography (ECC, RSA) broken by Shor's algorithm on a cryptographically relevant quantum computer. NIST finalised ML-KEM (FIPS 203), ML-DSA (FIPS 204), and SLH-DSA (FIPS 205) in 2024. Migration timelines project mandatory PQC adoption in critical infrastructure by 2030. IoT devices deployed today will outlive that window.

No shipping SE today provides hardware-accelerated PQC. Quarc addresses that gap.

---

## v1 Primary Use Case

**PQC-authenticated firmware OTA update for an IoT gateway**, entirely on the ULX3S + onboard ESP32:

```
1. Factory: Quarc generates ML-DSA keypair in slot 0 (device identity)
2. Factory: Device verification key registered with update server
3. Field:   Update server signs new firmware with its ML-DSA key
4. Field:   Host initiates encrypted session (CHANNEL_INIT — Noise IK + ML-KEM hybrid)
5. Field:   Host sends firmware + server signature (FW_UPDATE)
6. Field:   Quarc verifies ML-DSA signature, checks rollback counter
7. Field:   Quarc flashes verified firmware, increments rollback counter
8. Field:   Host requests device attestation (DSA_SIGN over device state)
9. Field:   Update server verifies attestation using registered key
```

---

## Architecture

```
Host MCU (STM32 / ESP32)
    │
    │ SPI — Noise IK encrypted channel (ML-KEM-768 + X25519 hybrid)
    ▼
┌────────────────────────────────────────────────────┐
│                 QUARC SoC (ECP5-85K)               │
│                                                    │
│  Boot ROM (immutable, synthesis-time loaded)       │
│    → TRNG startup health test                      │
│    → PMP configure + lock (8 regions)              │
│    → ML-DSA verify firmware + rollback check       │
│    → jump to firmware                              │
│                                                    │
│  Ibex RV32IMC  ←→  Wishbone-lite bus (~200 lines)  │
│       │                                            │
│  [Crypto]           [Memory]       [Peripherals]   │
│  Keccak engine      IRAM (BRAM)    UART (dev only) │
│   (shared: SHA-3,   DRAM (BRAM)   Timer/WDT        │
│    DRBG, ML-KEM    Boot ROM       Lifecycle reg    │
│    via MMIO)        Data RAM       Rollback ctr    │
│  SHA-3 wrapper                     GPIO            │
│  NTT engine (MMIO)                                │
│  TRNG + DRBG                                       │
└────────────────────────────────────────────────────┘

Hardware ML-KEM/ML-DSA controllers, KUE, keystore, and SPI slave are
**not in the Step 1 fabric** — ML-KEM runs in C (`fw/mlkem_sw.c`) over the
SHA-3 + NTT MMIO engines (see two-step plan below).
```

**Key invariant (Step 2 fabric):** Firmware never reads key bytes. The Key Usage Enforcer (KUE) DMA's key material directly from the key store into crypto engine internal registers. PMP Region 3 blocks all firmware access to the key store at the hardware level.

> Step 1 note: the key store and KUE are **not** in the Step 1 fabric (ML-KEM
> runs in C). In Step 1, ML-KEM decapsulation keys live in firmware memory;
> the key-store/KUE boundary is enforced once Step 2 hardware lands.

### Module LUT Budget (measured)

**Measured synthesis (`build/synth.log`, after ML-KEM hardware controller landed):**

```
149,551  LUT4          ← exceeds BOTH target devices
 58,901  TRELLIS_FF
 22      DP16KD
 23      MULT18X18D
```

That total excludes `mldsa.v`, `kue.v`, `keystore.v`, `lifecycle.v`,
`rollback.v`, and `spi_slave.v` (not yet in the synthesis), so the full
hardware path is even larger. The single biggest driver is the full-width
1600-bit Keccak-f[1600] permutation plus the hardware ML-KEM controller
(`mlkem.v` + `sampling.v` + `shake_sampler.v` + codec/compress).

> Earlier budget tables (~23.2k LUTs) were a projection from a pre-ML-KEM
> PnR run and are obsolete. The design as originally conceived does **not** fit
> the 84k ECP5-85K, let alone the 23k PolarFire MPFS025T.

**Measured Step 1 bring-up build (`build/synth_step1_v4.log`):** after removing
the hardware ML-KEM controller (`mlkem.v`, `sampling.v`, `shake_sampler.v`,
codec/compress) and — for the initial bring-up — the TRNG/DRBG clients, the
ECP5 synthesis fits the 23k BeagleV-Fire with margin:

```
 18,832  LUT4          ← fits MPFS025T 23k LEs (Step 1 bring-up)
 10,554  TRELLIS_FF
 32      DP16KD
 17      MULT18X18D
```

The KAT self-test firmware (`fw/mlkem_sw.c`, fixed seeds) does not touch the
TRNG/DRBG MMIO, so the bring-up build omits them; they are restored once a
device with more budget is available (ULX3S, or when the ML-KEM software path
needs real keygen/encaps on the BeagleV-Fire).

### Two-step deployment plan (C / FPGA partition)

Because the full hardware crypto path exceeds every current target, Quarc is
partitioned in two steps. Step 1 is the 23k-lane (BeagleV-Fire), Step 2 is the
84k-lane (ULX3S) which moves crypto back into fabric.

#### Step 1 — BeagleV-Fire, PolarFire MPFS025T (23k LEs) — crypto in C

Minimal fabric; the PQ algorithms run as firmware over MMIO coprocessors.

| On FPGA (RTL)                       | In C (`fw/*.c`)                     |
| ----------------------------------- | ----------------------------------- |
| Keccak-f[1600] (`keccak_engine.v`)  | ML-KEM-768 algorithm (`mlkem_sw.c`) |
| SHA-3/SHAKE wrapper (`sha3.v`)      | ML-KEM K-PKE encode/decode          |
| NTT/iNTT + basemul (`ntt.v`)        | CBD sampling                        |
| TRNG + DRBG (`trng.v`, `drbg.v`)    | keygen/encaps/decaps orchestration  |
| Ibex RV32IMC soft core              | boot/secure-boot                    |
| Wishbone bus, UART, timer, ROM, RAM | drivers, Noise channel, dispatcher  |
| Lifecycle + rollback counters       | command handlers                    |

> Bring-up note: the initial Step 1 build for board testing drops the
> `trng.v`/`drbg.v` row above (KAT self-test uses fixed seeds) to fit 23k;
> they return for real keygen. See "Module LUT Budget (measured)".

Hardware ML-KEM controller (`mlkem.v`), sampling datapath (`sampling.v`,
`shake_sampler.v`), ML-DSA controller (`mldsa.v`), KUE, keystore, and SPI slave
are **not** instantiated at this step — `mlkem_sw.c` drives `sha3.v` + `ntt.v`
over MMIO instead.

#### Step 2 — ULX3S, ECP5-85K (84k LUTs) — move crypto back into fabric

With 84k LUTs, hardware accelerators return and C shrinks to a thin driver.

| On FPGA (RTL)                            | In C (`fw/*.c`)           |
| ---------------------------------------- | ------------------------- |
| All of Step 1, **plus:**                 | Boot/secure-boot          |
| ML-KEM controller (`mlkem.v` + sampling) | Command dispatch (thin)   |
| ML-DSA controller (`mldsa.v`)            | Noise channel, drivers    |
| KUE + keystore (BRAM)                    | No ML-KEM algorithm logic |
| SPI slave (`spi_slave.v`)                |                           |

Hardware ML-DSA and the hardware ML-KEM datapath are the main consumers of the
extra ~60k LUTs. Full security stack (KUE, keystore, SPI host channel, ML-DSA)
is a Phase 5–7 concern, still in progress.

---

## Repository Structure

```
quarc/
├── Makefile
├── boards/
│   └── ulx3s.lpf          # ULX3S ECP5-85K pin constraints
├── ibex/                  # Git submodule — do not edit
│   └── rtl/               # Ibex SystemVerilog sources
├── rtl/                   # ALL Quarc RTL — Verilog 2005 only
│   ├── top.v              # SoC top-level
│   ├── bus.v              # Wishbone-lite bus + address decoder
│   ├── boot_rom.v         # Immutable boot ROM
│   ├── data_ram.v         # 16 KiB Data RAM (0x0001_4000)
│   ├── keccak.v           # Keccak-f[1600] permutation
│   ├── keccak_engine.v    # Shared permutation engine (SHA-3 + DRBG clients)
│   ├── sha3.v             # SHA-3/SHAKE wrapper
│   ├── ntt.v              # Shared NTT/iNTT engine (q=3329, q=8380417)
│   ├── mlkem.v            # ML-KEM-768 controller
│   ├── mldsa.v            # ML-DSA-65 controller
│   ├── trng.v             # TRNG (ring oscillators + SP 800-90B health tests)
│   ├── drbg.v             # SHAKE-256 DRBG
│   ├── kue.v              # Key Usage Enforcer
│   ├── keystore.v         # Key store controller (BRAM-backed, DMA-only)
│   ├── lifecycle.v        # Device lifecycle state machine
│   ├── rollback.v         # Monotonic anti-rollback counter
│   ├── spi_slave.v        # SPI slave interface
│   ├── uart.v             # UART debug (disabled in production bitstream)
│   └── timer.v            # RISC-V mtime/mtimecmp + 100ms watchdog
├── tb/                    # Testbenches (SystemVerilog allowed here)
├── formal/                # SymbiYosys formal verification (.sby files)
├── fw/                    # Firmware — bare metal C, no OS
│   ├── Makefile
│   ├── link.ld
│   ├── startup.S
│   ├── main.c
│   ├── cmd.c / cmd.h      # SPI command dispatcher (14 commands)
│   ├── kue.c / kue.h      # KUE driver
│   ├── crypto.c / crypto.h
│   ├── lifecycle.c
│   ├── noise.c / noise.h  # Noise Protocol IK (hybrid ML-KEM + X25519)
│   ├── aes_gcm.c          # AES-256-GCM channel encryption
│   └── hal.h              # Hardware register map
├── kat/                   # NIST Known Answer Test vectors
│   ├── sha3/
│   ├── mlkem768/
│   ├── mldsa65/
│   ├── aes_gcm/
│   └── drbg/
├── scripts/
│   ├── run_kat.py         # KAT runner
│   ├── run_sp80022.py     # NIST SP 800-22 statistical tests
│   ├── gen_fw_header.py   # Generate signed firmware header
│   ├── integration_test.py
│   ├── ota_demo.py        # v1 use case end-to-end demo
│   └── soak_test.py       # 24-hour continuous soak test
└── build/                 # Generated — gitignored
```

---

## Memory Map

```
0x0000_0000  16KB   Boot ROM         R-X  PMP Region 0 (locked)
0x0000_4000  64KB   Firmware IRAM    R-X  PMP Region 1 (locked)
0x0001_4000  16KB   Data RAM         RW   PMP Region 2 (locked)
0x0002_0000   4KB   Key store        ---  PMP Region 3 (NO ACCESS from firmware)
0x1000_0000  256B   Keccak/SHAKE MMIO     PMP Region 4
0x1000_0800  256B   NTT MMIO
0x1000_0200  256B   ML-KEM MMIO
0x1000_0300  256B   ML-DSA MMIO
0x1000_0400  256B   KUE MMIO
0x1000_0500  256B   TRNG/DRBG MMIO
0x2000_0000  256B   SPI slave MMIO        PMP Region 5
0x2000_0100  256B   UART MMIO
0x2000_0200  256B   Timer/WDT MMIO
0x3000_0000   32B   Lifecycle register    PMP Region 6
0x3000_0100   32B   Rollback counter      PMP Region 7 (R only)
```

---

## SPI Command Set

All commands require an established Noise IK session (except `CHANNEL_INIT`). All commands are lifecycle-gated in hardware.

| ID   | Command         | Description                                                                 |
| ---- | --------------- | --------------------------------------------------------------------------- |
| 0x01 | `PING`          | Liveness check; returns firmware version, lifecycle state, TRNG health      |
| 0x02 | `GET_RANDOM`    | Return up to 64 bytes from DRBG                                             |
| 0x10 | `KEM_KEYGEN`    | Generate ML-KEM-768 keypair; dk stored in slot                              |
| 0x11 | `KEM_ENCAP`     | Encapsulate with provided ek; return ciphertext + shared secret             |
| 0x12 | `KEM_DECAP`     | Decapsulate using slot dk (KUE enforces DECAP_ONLY)                         |
| 0x20 | `DSA_KEYGEN`    | Generate ML-DSA-65 keypair; sk stored in slot                               |
| 0x21 | `DSA_SIGN`      | Sign message hash using slot sk (KUE enforces SIGN_ONLY)                    |
| 0x22 | `DSA_VERIFY`    | Verify signature using provided vk                                          |
| 0x30 | `STORE_KEY`     | Import key into slot (encrypted via channel)                                |
| 0x40 | `GET_STATUS`    | Lifecycle state, TRNG health, boot status, slot occupancy, rollback counter |
| 0x50 | `SECURE_ERASE`  | Destroy all key material                                                    |
| 0x60 | `FW_UPDATE`     | Deliver firmware (ML-DSA verified + rollback checked before flash)          |
| 0x70 | `SET_LIFECYCLE` | Advance lifecycle state (one-way)                                           |
| 0x80 | `CHANNEL_INIT`  | Initiate Noise IK handshake                                                 |

---

## Device Lifecycle

```
MANUFACTURING ──→ PROVISIONED ──→ LOCKED
      │                               │
      └───────────────────────────→ RMA
```

State transitions are enforced in RTL — one-way, irreversible, not firmware-writable.

---

## Security Properties

| Property                                 | Mechanism                                                                    |
| ---------------------------------------- | ---------------------------------------------------------------------------- |
| Key material never leaves trust boundary | KUE DMA-only; PMP Region 3 blocks firmware; bus decoder formally verified    |
| Firmware cannot read key bytes           | Hardware key usage policy (KUE RTL), not firmware convention                 |
| Boot integrity                           | ML-DSA signature verified by Boot ROM before any firmware executes           |
| Anti-rollback                            | Monotonic counter in Boot ROM address space; firmware cannot write           |
| Entropy assurance                        | TRNG with SP 800-90B RCT + APT in RTL; hard halt on failure                  |
| Quantum resistance                       | ML-KEM-768 (FIPS 203) + ML-DSA-65 (FIPS 204) for all new operations          |
| Channel security                         | Noise IK with ML-KEM + X25519 hybrid; AES-256-GCM; forward secrecy           |
| NTT residual leakage                     | Scratchpad zeroed in RTL after every operation; OP_DONE gated on zeroization |
| Lifecycle integrity                      | RTL state machine; no backward transition possible                           |

---

## Toolchain

100% open-source. No Vivado, no Quartus.

| Tool                                                           | Purpose                                        |
| -------------------------------------------------------------- | ---------------------------------------------- |
| [sv2v](https://github.com/zachjs/sv2v)                         | Convert Ibex SystemVerilog → Verilog for Yosys |
| [Yosys](https://yosyshq.net/yosys/)                            | RTL synthesis (`synth_ecp5 -abc9`)             |
| [nextpnr-ecp5](https://github.com/YosysHQ/nextpnr)             | Place and route                                |
| [ecppack](https://github.com/YosysHQ/prjtrellis)               | Bitstream generation                           |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | Program ULX3S                                  |
| [Icarus Verilog](http://iverilog.icarus.com/)                  | Functional simulation                          |
| [Verilator](https://verilator.org/)                            | Fast regression simulation                     |
| [SymbiYosys](https://symbiyosys.readthedocs.io/)               | Formal verification (BMC + k-induction)        |
| [GTKWave](http://gtkwave.sourceforge.net/)                     | Waveform viewer                                |
| riscv32-unknown-elf-gcc                                        | Firmware compiler (`march=rv32imc`)            |

Install everything via [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build).

---

## Build

```bash
# One-time: fetch Ibex submodule
git submodule update --init --recursive

# Simulation (individual module)
make sim-keccak
make sim-ntt
make sim-mlkem
make sim-mldsa

# Full SoC simulation
make sim

# Synthesis (reports LUT count)
make synth

# Place and route (reports Fmax)
make pnr

# Generate bitstream
make bitstream

# Program ULX3S
make prog

# Formal verification (all targets)
make formal

# Individual formal target
make formal-bus_decoder
make formal-kue_policy

# KAT vectors
python3 scripts/run_kat.py --suite sha3
python3 scripts/run_kat.py --suite mlkem768
python3 scripts/run_kat.py --suite mldsa65

# TRNG statistical tests
python3 scripts/run_sp80022.py

# Clean build artifacts
make clean
```

---

## Development Phases

Status legend: 🟢 verified · 🟡 code complete, awaiting verification · 🔵 in progress · ⚪ not started

| Phase               | Deliverable                            | Key Exit Gate                           | Status                                                                           |
| ------------------- | -------------------------------------- | --------------------------------------- | -------------------------------------------------------------------------------- |
| 0 — Foundation      | Ibex boots on ULX3S, UART "QUARC v0"   | Physical board test                     | 🟢 sim + synth + PnR verified (26.9 MHz)                                         |
| 1 — Keccak          | SHA-3/SHAKE engine                     | 100% NIST SHA-3 KAT + SymbiYosys proof  | 🟢 72/72 KAT, formal BMC, bus-wired, firmware self-test passes                   |
| 2 — Entropy         | TRNG + SHAKE-256 DRBG                  | SP 800-22 pass + DRBG KAT               | 🟢 RCT/APT health, formal BMC, DRBG KAT, SoC firmware test, SP 800-22 17/17 PASS |
| 3 — NTT             | Shared NTT/iNTT engine                 | NTT(iNTT(p))==p + zeroization formal    | 🟢 bus-wired, firmware round-trip passes, KAT 4/4, 2.5k LUTs; formal pending     |
| 4 — ML-KEM          | ML-KEM-768 + KUE integration           | 100% FIPS 203 KAT + KUE rejection tests | ⚪ not started                                                                   |
| 5 — ML-DSA          | ML-DSA-65 + hardware rejection sampler | 100% FIPS 204 KAT + timing at 50 MHz    | ⚪ not started                                                                   |
| 6 — Security Policy | KUE, PMP, lifecycle, rollback formal   | All 6 SymbiYosys proofs pass            | ⚪ not started                                                                   |
| 7 — SPI + Channel   | Noise IK, AES-GCM, all 14 commands     | Encrypted session end-to-end            | ⚪ not started                                                                   |
| 8 — Integration     | Secure boot, 24h soak, OTA demo        | All PRD v1.1 Section 9.5 criteria       | ⚪ not started                                                                   |

---

## Performance Targets (50 MHz on ECP5-85K)

| Operation         | Quarc target | pqm4 baseline (M4 @ 168 MHz) | Min speedup |
| ----------------- | ------------ | ---------------------------- | ----------- |
| ML-KEM-768 KeyGen | < 0.5 ms     | ~1.5 ms                      | ≥ 3×        |
| ML-KEM-768 Encaps | < 0.5 ms     | ~1.7 ms                      | ≥ 3×        |
| ML-KEM-768 Decaps | < 0.5 ms     | ~1.8 ms                      | ≥ 3×        |
| ML-DSA-65 KeyGen  | < 2 ms       | ~6 ms                        | ≥ 3×        |
| ML-DSA-65 Sign    | < 5 ms       | ~12 ms                       | ≥ 2×        |
| ML-DSA-65 Verify  | < 2 ms       | ~5 ms                        | ≥ 2×        |

---

## Formal Verification Targets

- **Bus decoder** — no address maps to two slaves; no unmapped access returns data; key store always returns bus_err
- **Keccak** — `done` asserts exactly 24 cycles after `start`
- **TRNG health** — RCT triggers within 13 cycles of stuck-bit fault; `health_fail` cannot be cleared without reset
- **PMP config** — `boot_complete` never asserts before all PMP LOCK bits set
- **KUE policy** — SIGN_ONLY slot cannot be used for DECAP; NO_EXPORT key bytes never appear on bus_rdata
- **Lifecycle FSM** — state never decreases; RMA state is absorbing

---

## RTL Coding Conventions

- **Verilog 2005 only** in `rtl/` — no SystemVerilog constructs (Ibex is the sole exception, lives in `ibex/`)
- One module per file, max 500 lines per file
- No `initial` blocks in synthesizable RTL
- No `$display`, `$finish`, `$dumpvars` in synthesizable RTL
- No FPGA-specific primitives in core logic — inferred only
- All constants via `parameter` — no magic numbers
- Module hierarchy max depth: 4 levels

---

## v1 Acknowledged Limitations

- **No OTP** — key store is BRAM-backed; keys are lost on power cycle. OTP planned for v2.
- **No PUF** — device identity is software-provisioned in v1. PUF planned for v2.
- **No side-channel masking** — constant-time and no secret-dependent addressing required; Boolean masking deferred to v2.
- **No physical tamper resistance** — FPGA cannot implement active shields or voltage glitch detection. ASIC path in v2+.
- **Trust boundary is logical** — on the ULX3S FPGA prototype, the boundary is an RTL boundary, not a physical one.

---

## Roadmap

- **v2 — Hardened SE:** PUF, real OTP/NVM, tamper detection, side-channel countermeasures (Boolean masking), SLH-DSA, Common Criteria EAL4+ path
- **v3 — TEE Root of Trust:** PQC attestation for AMD SEV-SNP / Intel TDX / Arm CCA; sealing keys; PCIe/I3C interface
- **ASIC:** No RTL rewrite required (P5 principle). 40nm or 22nm FD-SOI. FIPS 140-3 Level 3.

### FPGA targets

| Board        | FPGA                                   | Flow                           | Partition                                                                             | Status                                                                                              |
| ------------ | -------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| BeagleV-Fire | Microchip PolarFire MPFS025T (23k LEs) | Microchip Libero (PDC pins)    | Step 1: crypto in C (`mlkem_sw.c` over sha3+ntt MMIO); no hw ML-KEM/ML-DSA controller | Planned — fabric kept minimal to fit 23k; SE driven by SoC RISC-V cores (Linux) over AXI/SPI bridge |
| ULX3S        | Lattice ECP5-85K (84k LUTs)            | yosys + nextpnr-ecp5 + ecppack | Step 2: move ML-KEM/ML-DSA/KUE/keystore/SPI back into fabric; C becomes thin driver   | Primary dev target; bitstream builds, 27 MHz                                                        |

For the BeagleV-Fire (Step 1), the SE runs in the PolarFire fabric and is driven
by the SoC's own RISC-V cores (Linux) over an AXI/SPI bridge, replacing the
external-MCU host of the ULX3S setup. ML-KEM runs in C on the fabric soft core,
so the fabric footprint stays under the 23k-LUT budget. When the ULX3S is
available (Step 2), the 84k LUTs absorb the hardware crypto controllers and the
C layer reverts to orchestration.

---

## IP and Licensing

Quarc is **closed commercial IP**. The synthesizable path uses only permissive-licensed components (MIT, ISC, BSD, Apache 2.0). No GPL or LGPL in the synthesis path. GPL tools (Icarus, GTKWave, GCC) apply only to the tool binaries themselves — not to RTL or firmware produced by them.

---

_Quarc Secure Element // v1.0 // 2025 // Proprietary & Confidential_
