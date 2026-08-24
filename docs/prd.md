# QUARC — Post-Quantum Secure Element

## Product Requirements Document v1.1 — 2025

### PROPRIETARY & CONFIDENTIAL

---

> **"Quarc is a post-quantum Secure Element with hardware-accelerated ML-KEM and ML-DSA, securing IoT devices today and anchoring trust for TEEs tomorrow."**

---

## Document Metadata

| Field              | Value                                                                                                                                                                                              |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Document           | Quarc PRD v1.1                                                                                                                                                                                     |
| Status             | DRAFT — Internal Only                                                                                                                                                                              |
| Classification     | Proprietary & Confidential                                                                                                                                                                         |
| FPGA Board         | ULX3S — Lattice ECP5-85K (84K LUTs) + BeagleV-Fire — PolarFire MPFS025T (23k LEs, Step 1)                                                                                                          |
| CPU                | Ibex RV32IMC (Apache 2.0, via sv2v + Yosys)                                                                                                                                                        |
| HDL Language       | Verilog 2005 (all Quarc RTL) + sv2v for Ibex CPU only                                                                                                                                              |
| Toolchain          | Yosys + nextpnr + sv2v + SymbiYosys + Icarus — 100% open source                                                                                                                                    |
| Build System       | GNU Make — single Makefile                                                                                                                                                                         |
| IP License Model   | Commercial closed IP — permissive OSS components only (MIT/ISC/BSD/Apache 2.0)                                                                                                                     |
| PQC Standards      | FIPS 203 ML-KEM-768 \| FIPS 204 ML-DSA-65                                                                                                                                                          |
| Comparable Product | TROPIC01 by Tropic Square — extended with PQC                                                                                                                                                      |
| Changelog          | v1.1: PMP policy table, hardware key usage enforcement, device lifecycle model, secure boot rollback protection, NTT zeroization, entropy budgeting, bus protocol definition, concrete v1 use case |

---

## Table of Contents

1. [Product Overview](#1-product-overview)
2. [Objectives](#2-objectives)
3. [Threat Model](#3-threat-model)
4. [System Architecture](#4-system-architecture)
5. [Security Policy](#5-security-policy)
6. [Functional Requirements](#6-functional-requirements)
7. [Non-Functional Requirements](#7-non-functional-requirements)
8. [Key Design Decisions](#8-key-design-decisions)
9. [Test and Verification Strategy](#9-test-and-verification-strategy)
10. [Development Phases](#10-development-phases)
11. [Toolchain Reference](#11-toolchain-reference)
12. [Risks and Mitigations](#12-risks-and-mitigations)
13. [Future Roadmap](#13-future-roadmap)
14. [Glossary](#14-glossary)

---

## 1. Product Overview

### 1.1 Background and Motivation

Every Secure Element shipping today — Infineon SLx9, NXP SE050, Microchip ATECC608, and TROPIC01 — relies entirely on classical cryptography: ECC (P-256, Ed25519), RSA, and AES. These algorithms are broken by Shor's algorithm running on a cryptographically relevant quantum computer (CRQC).

NIST finalised its Post-Quantum Cryptography standards in 2024: ML-KEM (FIPS 203), ML-DSA (FIPS 204), and SLH-DSA (FIPS 205). Migration timelines from NIST, ENISA (EU), and BSI (Germany) project mandatory PQC adoption in critical infrastructure by 2030. IoT devices deployed today have operational lifetimes exceeding that window.

No shipping SE product today provides hardware-accelerated PQC. Software PQC on a Cortex-M4 takes 1.5–12ms per operation — acceptable for some cases but a bottleneck for high-frequency device identity operations. Hardware acceleration brings this under 0.5ms.

TROPIC01 by Tropic Square demonstrates that an open-architecture, auditable, RISC-V based SE is commercially viable. Quarc extends that category into the post-quantum era.

### 1.2 What Quarc Is

Quarc is a post-quantum Secure Element: a cryptographic coprocessor that integrates with a host MCU or gateway via SPI, provides hardware-accelerated PQC operations (ML-KEM and ML-DSA), securely stores device keys and credentials, and serves as the hardware root of trust for the device. It is the answer to the question: what does a TROPIC01-class SE look like after the PQC transition?

### 1.3 What Quarc Is Not

- Not a clone of TROPIC01 — different crypto subsystem, same market positioning
- Not open-source — closed commercial IP built on permissive-licensed open components
- Not OpenTitan — deliberately lean, no SystemVerilog, no Bazel, fully open toolchain
- Not a finished product in v1 — v1 is an FPGA prototype proving architecture and PQC correctness
- Not a general-purpose MCU — Quarc is a cryptographic coprocessor, not a compute platform

### 1.4 Concrete v1 Use Case

**PQC-authenticated firmware OTA update for an IoT gateway.** This is Quarc's primary v1 demonstration scenario and exercises every v1 capability end-to-end:

```
1. Factory: Quarc generates ML-DSA keypair in slot 0 (device identity)
2. Factory: Quarc's verification key registered with update server
3. Field:   Update server generates new firmware, signs with its ML-DSA key
4. Field:   Host MCU initiates Quarc session (CHANNEL_INIT — Noise IK + ML-KEM hybrid)
5. Field:   Host sends firmware image + server signature to Quarc (FW_UPDATE)
6. Field:   Quarc verifies server signature using ML-DSA, checks rollback counter
7. Field:   Quarc flashes verified firmware, increments rollback counter
8. Field:   Host MCU requests device attestation (DSA_SIGN over device state)
9. Field:   Update server verifies device attestation using registered key
```

This scenario is achievable entirely on the ULX3S 85K with the onboard ESP32 as the host MCU. No external hardware required.

### 1.5 Competitive Positioning

| Feature                   | TROPIC01      | OpenTitan     | ATECC608    | Quarc v1                            |
| ------------------------- | ------------- | ------------- | ----------- | ----------------------------------- |
| CPU                       | Ibex (SV)     | Ibex (SV)     | None        | **Ibex RV32IMC (SV+sv2v)**          |
| HDL                       | SystemVerilog | SystemVerilog | N/A         | **Verilog 2005 + sv2v (Ibex only)** |
| Open toolchain            | No            | No            | N/A         | **Yes — Yosys/nextpnr**             |
| Classical crypto HW       | ECC + AES     | ECC + AES     | ECC + AES   | AES + hybrid mode                   |
| PQC hardware accel.       | None          | None          | None        | **ML-KEM-768 + ML-DSA-65**          |
| Hybrid PQC mode           | No            | No            | No          | **Yes (v1)**                        |
| Hardware key usage policy | Yes           | Yes           | Yes         | **Yes (v1 — HW enforced)**          |
| Device lifecycle model    | Yes           | Yes           | Partial     | **Yes (v1)**                        |
| Tamper resistance         | Full (ASIC)   | Full (ASIC)   | Full (ASIC) | Stub hooks (v1 FPGA)                |
| PUF                       | Yes           | Yes           | Yes         | v2                                  |
| TEE RoT roadmap           | No            | Yes           | No          | **Yes (v2+)**                       |

---

## 2. Objectives

### 2.1 Primary Objectives (v1)

- Hardware-accelerated ML-KEM-768: keygen, encapsulation, decapsulation
- Hardware-accelerated ML-DSA-65: keygen, sign, verify
- Shared NTT engine reused across both PQC algorithms — core architectural differentiator
- Keccak/SHA-3/SHAKE engine as the shared cryptographic primitive foundation
- TRNG with mandatory NIST SP 800-90B health tests; hard halt on failure
- SHAKE-256 based DRBG with automatic reseed and entropy budgeting
- Hardware-enforced key usage policy — crypto engines read keys directly, firmware never sees key bytes
- PMP configured and locked by Boot ROM before firmware executes — explicit region table
- Device lifecycle state machine — MANUFACTURING → PROVISIONED → LOCKED → RMA
- Command authorisation enforced per lifecycle state
- Secure key storage with monotonic use counters and hardware usage policy
- ML-DSA signed firmware boot with anti-rollback monotonic counter
- NTT scratchpad zeroization after every PQC operation
- SPI host interface with Noise Protocol encrypted channel (hybrid ML-KEM + X25519)
- Ibex RV32IMC control plane — bare metal C firmware, no OS
- 100% open-source toolchain: Yosys, nextpnr-ecp5, sv2v, SymbiYosys, Icarus, openFPGALoader
- Target platform: ULX3S ECP5-85K — open hardware board
- All PQC accelerators validated against NIST Known Answer Tests (KATs)

### 2.2 Secondary Objectives (v1)

- Achieve >= 3x speedup vs software PQC on Cortex-M4 (pqm4 benchmark baseline)
- Hybrid PQC + classical mode: ML-KEM + X25519, ML-DSA + Ed25519 simultaneously
- Host SDK in C targeting STM32 and ESP32 as test host MCUs
- Formal verification of bus decoder, Keccak core, PMP configuration logic via SymbiYosys
- Two-step fabric partition fits its target: Step 1 (BeagleV-Fire MPFS025T, 23k) with crypto in C, Step 2 (ULX3S ECP5-85K, 84k) with hardware accelerators. See README § "Two-step deployment plan". (The original `< 15,000 LUT` target was based on an obsolete estimate; the measured full-hardware design is ~150k LUT4 and requires the 84k part.)
- Clock frequency >= 50 MHz achieved by nextpnr without timing relaxation
- Complete v1 use case demo: PQC firmware OTA on ULX3S + ESP32

### 2.3 Explicitly Out of Scope (v1)

- Production-grade PUF — deferred to v2
- Physical tamper detection (active shield, laser detector) — FPGA cannot implement these
- Side-channel masking — deferred to v2 (constant-time and no secret-dependent addressing required in v1)
- Common Criteria or FIPS 140 certification
- ASIC implementation
- SLH-DSA hash-based signatures — deferred to v2
- TEE attestation protocol — deferred to v2
- Real OTP / NVM — simulated with BRAM in v1, explicitly acknowledged
- Fault injection resistance — deferred to v2 (invalid input fuzzing in v1 test plan)

---

## 3. Threat Model

Every security requirement in this PRD is grounded in this threat model. A requirement without a corresponding threat is a feature, not a security requirement.

### 3.1 Protected Assets

- **A1** — Device private keys: ML-DSA signing key, ML-KEM decapsulation key
- **A2** — Device identity: X.509 certificate, attestation binding
- **A3** — Session secrets: symmetric keys derived from key exchange
- **A4** — Firmware integrity: authenticated boot image
- **A5** — Entropy: TRNG output and DRBG state
- **A6** — Device lifecycle state: MANUFACTURING / PROVISIONED / LOCKED / RMA

### 3.2 Threat Actors

| Actor                   | Capability                      | Goal                              | v1 Scope                                 |
| ----------------------- | ------------------------------- | --------------------------------- | ---------------------------------------- |
| Remote attacker         | Software exploits via SPI API   | Extract keys via firmware vuln    | **In scope — primary threat**            |
| Malicious host firmware | Arbitrary SPI commands          | Abuse SE API beyond authorization | **In scope — lifecycle + command authz** |
| Quantum attacker        | CRQC with Shor's algorithm      | Break classical key exchange      | **In scope — PQC primary motivation**    |
| Passive physical        | SPI bus sniffing, power trace   | Key recovery from channel/power   | Channel encrypted; power analysis v2     |
| Active physical         | Fault injection, voltage glitch | Bypass security checks            | Out of scope — v2+                       |
| Supply chain            | Malicious component insertion   | Hardware backdoor                 | Architectural only in v1                 |
| Compromised firmware    | Firmware exploited post-boot    | Extract key bytes from registers  | **In scope — hardware key usage policy** |

### 3.3 Trust Boundary

On the ULX3S FPGA prototype, the trust boundary is a logical RTL boundary — not a physical one. This is an acknowledged v1 limitation.

**Inside the trust boundary:**

- Ibex CPU execution context and firmware memory (protected by PMP, configured by Boot ROM)
- Crypto subsystem: Keccak, NTT, ML-KEM, ML-DSA, TRNG, DRBG
- Key store memory region (BRAM, accessible only to crypto engines via DMA — not firmware)
- Bus address decoder (enforces memory protection — formally verified)
- Boot ROM (immutable — synthesis-time loaded Verilog ROM)

**Outside the trust boundary — treated as untrusted:**

- SPI bus and host MCU — all communication encrypted and authenticated
- External QSPI Flash — firmware is signature-verified and rollback-checked before execution
- FPGA JTAG port — disabled in production bitstream
- UART debug interface — disabled in production bitstream
- Firmware itself — firmware orchestrates but never accesses raw key bytes

### 3.4 Security Properties Required

- **Confidentiality** — private key material never leaves the trust boundary in plaintext, never accessible to firmware as raw bytes
- **Integrity** — all firmware ML-DSA verified before execution; rollback counter enforced; no bypass possible
- **Authenticity** — device identity cryptographically bound to hardware-generated key
- **Forward secrecy** — host channel uses ephemeral key exchange per session
- **Quantum resistance** — all new crypto operations use NIST PQC standards
- **Entropy assurance** — TRNG health-tested per SP 800-90B; failure halts the device
- **Fail-secure** — any internal fault causes halt and error assertion, not silent degradation
- **Lifecycle integrity** — device lifecycle state transitions are one-way and tamper-evident

---

## 4. System Architecture

### 4.1 Design Principles

| ID  | Principle                                  | Detail                                                                                                                                           |
| --- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| P1  | **Crypto-first, CPU-second**               | Ibex orchestrates; it does not do crypto. All heavy math is in hardware accelerators.                                                            |
| P2  | **Lean by design**                         | Every module justifies its presence. Complexity is a security liability. Unused logic is removed.                                                |
| P3  | **Verilog 2005 only in synthesizable RTL** | No SystemVerilog in Quarc RTL. Ibex is the only SV component; sv2v converts it.                                                                  |
| P4  | **Open-source toolchain throughout**       | Yosys, nextpnr, sv2v, SymbiYosys, Icarus. No Vivado, no Quartus, no proprietary EDA tools ever.                                                  |
| P5  | **FPGA-first, ASIC-ready**                 | Synthesizable without FPGA primitives in core modules. ASIC port requires no RTL rewrite.                                                        |
| P6  | **Own critical IP**                        | Entropy, PQC engines, bus, key store — proprietary Verilog. CPU core is permissive OSS.                                                          |
| P7  | **Correctness before integration**         | Every accelerator passes 100% NIST KAT vectors in simulation before SoC integration.                                                             |
| P8  | **Permissive licenses only**               | MIT, ISC, BSD, Apache 2.0 in the synthesizable path. Zero GPL or LGPL.                                                                           |
| P9  | **Hardware enforces policy**               | Key usage, memory isolation, and lifecycle state are enforced in RTL — not in firmware. Firmware that is compromised cannot escalate privileges. |

### 4.2 SoC Architecture

```
Host MCU / Gateway (STM32, ESP32, any)
    |
    | SPI — encrypted Noise Protocol channel (ML-KEM + X25519 hybrid)
    |
    v
+------------------------------------------------------------+
|                    QUARC SoC (ECP5-85K)                    |
|                                                            |
|  Boot ROM (immutable)                                      |
|    → TRNG startup test                                     |
|    → PMP configure + lock (before firmware)               |
|    → ML-DSA verify firmware + rollback check              |
|    → jump to firmware                                      |
|                                                            |
|  Ibex RV32IMC  ←→  System Bus (Wishbone-lite, ~200 lines) |
|       |                                                    |
|  [Crypto Engine]     [Memory]          [Peripherals]       |
|  Keccak/SHAKE        IRAM (BRAM)       SPI slave           |
|  NTT engine          DRAM (BRAM)       UART (dev only)     |
|  ML-KEM ctrl         Boot ROM          Timer/WDT           |
|  ML-DSA ctrl         Key store ←─────── DMA only          |
|  TRNG + DRBG         (BRAM, HW access) Lifecycle reg       |
|  Key Usage Enforcer  Rollback counter  GPIO                |
+------------------------------------------------------------+

Key store access rule:
  Firmware:       NEVER reads key bytes — issues commands only
  Crypto engines: DMA key material directly from key store
  Bus decoder:    key store region blocked from firmware address space
```

### 4.3 Bus Architecture

Single-master Wishbone-lite bus. Ibex is the only bus master. All peripherals are bus slaves.

**Protocol:**

- Signals: `cyc`, `stb`, `we`, `adr[31:0]`, `dat_w[31:0]`, `dat_r[31:0]`, `ack`, `err`
- Handshake: valid/ready — transaction completes when `stb & ack`
- Wait states: slaves assert `ack` when ready; Ibex stalls via `stb` hold
- Atomicity: all transactions are single-word (32-bit); multi-word ops are firmware-sequenced
- Error: `err` asserted on unmapped access, key store access from wrong context, or locked region write

**DMA for crypto engines:**

- NTT and ML-KEM/DSA controllers DMA polynomial data directly from BRAM scratchpad
- DMA is internal to the crypto subsystem — not via the main bus
- Ibex initiates an operation by writing to a control register; engine signals completion via interrupt
- Key material DMA from key store to engine registers is internal and never visible on main bus

**Formal verification targets for bus:**

- No address maps to two simultaneous slaves
- No unmapped access returns data (only `err`)
- Key store region inaccessible from firmware bus transactions
- Lifecycle register write only accepted in correct lifecycle state

### 4.4 Module Inventory and LUT Budget

> **Status:** The LUT estimates below date from the original single-partition
> plan and are **obsolete**. Measured synthesis after the ML-KEM hardware
> controller (`build/synth.log`) is **149,551 LUT4 + 58,901 FF** — the full
> hardware path exceeds both the ECP5-85K (84k) and PolarFire MPFS025T (23k).
> Quarc therefore uses a **two-step partition**: Step 1 (BeagleV-Fire, 23k)
> keeps crypto in C (`fw/mlkem_sw.c` over the SHA-3 + NTT MMIO engines) with a
> minimal fabric; Step 2 (ULX3S, 84k) returns the hardware ML-KEM/ML-DSA
> controllers, KUE, keystore, and SPI slave to fabric. See README § "Two-step
> deployment plan" for the authoritative partition. The table below documents
> the _estimated_ per-module cost for the Step 2 (hardware-accelerated) fabric.
> **Step 1 bring-up build** (ML-KEM + TRNG/DRBG removed, `build/synth_step1_v4.log`)
> measures **18,832 LUT4 + 10,554 FF** and fits the 23k MPFS025T.

| Module                   | Est. LUTs        | Source           | Notes                                                           |
| ------------------------ | ---------------- | ---------------- | --------------------------------------------------------------- |
| Ibex RV32IMC             | ~3,500           | Apache 2.0 (OSS) | Control plane only. Not on crypto path. Synthesised via sv2v.   |
| System Bus               | ~200             | Proprietary      | Custom Wishbone-lite + formal verification.                     |
| Keccak/SHAKE engine      | ~10,200          | Proprietary      | Shared by all consumers. Full-width 1600-bit round.             |
| NTT engine (shared)      | ~3,000           | Proprietary      | Parameterised for q=3329 and q=8380417.                         |
| ML-KEM-768 controller    | ~1,500+          | Proprietary      | State machine. Drives NTT and Keccak engines.                   |
| ML-DSA-65 controller     | ~2,000+          | Proprietary      | State machine. Rejection sampler. Drives NTT.                   |
| Key Usage Enforcer       | ~200             | Proprietary      | HW policy engine. Enforces SIGN/DECAP/NO-EXPORT per slot.       |
| TRNG                     | ~300             | Proprietary      | Ring oscillator. SP 800-90B RCT + APT health tests.             |
| DRBG (SHAKE-256)         | ~200             | Proprietary      | Auto-reseed from TRNG. Entropy budgeting enforced.              |
| SPI slave                | ~400             | Proprietary      | Mode 0/3. Command framing. 10 MHz target.                       |
| Key store controller     | ~200 + BRAM      | Proprietary      | BRAM-backed. DMA-only access from crypto engines.               |
| Boot ROM                 | ~100 + BRAM      | Proprietary      | Verilog ROM. PMP config. ML-DSA root key. Rollback counter.     |
| Lifecycle state machine  | ~150             | Proprietary      | 4-state FSM. One-way transitions. HW enforced.                  |
| Rollback counter         | ~100             | Proprietary      | Monotonic. BRAM-backed (v1). OTP in v2.                         |
| UART debug               | ~200             | OSS (permissive) | Disabled in production bitstream.                               |
| Timer + WDT              | ~150             | Proprietary      | RISC-V mtime/mtimecmp + 100ms watchdog.                         |
| IRAM / DRAM              | BRAM only        | Inferred         | Separate address regions. No FPGA primitives.                   |
| **TOTAL (Step 2, est.)** | **~23,000+ LUT** |                  | Full-hardware path. Does NOT fit MPFS025T (23k); fits ECP5-85K. |

---

## 5. Security Policy

> This section defines the policies enforced in hardware. These are not firmware conventions — they are RTL-level invariants. Firmware cannot override them.

### 5.1 PMP Region Layout

The Boot ROM configures and locks all PMP regions **before** jumping to firmware. Firmware cannot reconfigure PMP after boot. This is the critical distinction from firmware-configured PMP — a compromised firmware cannot escape its sandbox.

| Region | Address Range      | Permissions     | Locked by       | Notes                                                                            |
| ------ | ------------------ | --------------- | --------------- | -------------------------------------------------------------------------------- |
| 0      | Boot ROM           | R-X             | Boot ROM itself | Immutable. Firmware cannot write or re-execute.                                  |
| 1      | Firmware IRAM      | R-X             | Boot ROM        | Execute-only for firmware. No self-modification.                                 |
| 2      | Data RAM           | RW              | Boot ROM        | Firmware stack and heap. No execute.                                             |
| 3      | Key store          | ---             | Boot ROM        | **No access from M-mode firmware.** Crypto engines access via internal DMA only. |
| 4      | Crypto engine MMIO | RW              | Boot ROM        | Control registers only. Key bytes never appear here.                             |
| 5      | SPI / UART / GPIO  | RW              | Boot ROM        | Peripheral access.                                                               |
| 6      | Lifecycle register | RW (restricted) | Boot ROM        | Write only accepted per lifecycle state machine.                                 |
| 7      | Rollback counter   | R only          | Boot ROM        | Firmware can read. Cannot write directly — only Boot ROM increments.             |

**Boot sequence:**

```
Power on
  → TRNG health test (halt if fail)
  → Configure PMP regions 0–7
  → Set PMP LOCK bits on all regions
  → Load firmware from QSPI Flash into IRAM
  → ML-DSA.Verify(root_vk, fw_hash, fw_sig) — halt if fail
  → Check fw_version >= rollback_counter — halt if fail
  → Jump to firmware entry point
```

### 5.2 Hardware Key Usage Policy

This is the mechanism that makes Quarc an SE rather than a crypto accelerator. Firmware never reads key bytes. The Key Usage Enforcer (KUE) is a small RTL state machine that sits between the key store and the crypto engines.

**Key slot policy register (per slot, set at provisioning, hardware-enforced):**

| Policy Bit            | Meaning                                               | Enforced By |
| --------------------- | ----------------------------------------------------- | ----------- |
| `SIGN_ONLY`           | Slot may only be used for ML-DSA signing              | KUE RTL     |
| `DECAP_ONLY`          | Slot may only be used for ML-KEM decapsulation        | KUE RTL     |
| `NO_EXPORT`           | Key material never leaves key store in any form       | KUE RTL     |
| `NO_OVERWRITE`        | Slot cannot be overwritten once provisioned           | KUE RTL     |
| `COUNTER_LIMIT[15:0]` | Maximum use count — KUE blocks operation when reached | KUE RTL     |

**Operation flow (example: DSA_SIGN with slot 0):**

```
Firmware writes: KUE_CMD = {SIGN, slot=0, hash_ptr=...}
KUE checks:      slot 0 policy == SIGN_ONLY? → yes, proceed
KUE action:      DMA key bytes from key store → ML-DSA engine internal registers
                 (key bytes never appear on main bus)
KUE increments:  slot 0 use counter
ML-DSA engine:   performs signing using internal key registers
ML-DSA engine:   returns signature to output buffer (not key bytes)
KUE:             zeroises engine internal key registers after operation
Firmware reads:  signature from output buffer
```

If firmware attempts to read key store memory directly — blocked by PMP (Region 3, no access). If firmware attempts to use slot 0 for DECAP — blocked by KUE policy check. Both checks are in RTL and cannot be bypassed by firmware.

### 5.3 Device Lifecycle Model

The lifecycle state machine is implemented in RTL. State transitions are one-way — there is no mechanism to return to a previous state. The current state is reflected in the `GET_STATUS` response.

```
MANUFACTURING ──→ PROVISIONED ──→ LOCKED
      │                               │
      └──────────────────────────────→ RMA
```

**State definitions and command permissions:**

| Command         | MANUFACTURING | PROVISIONED   | LOCKED   | RMA |
| --------------- | ------------- | ------------- | -------- | --- |
| `PING`          | ✓             | ✓             | ✓        | ✓   |
| `GET_STATUS`    | ✓             | ✓             | ✓        | ✓   |
| `GET_RANDOM`    | ✓             | ✓             | ✓        | ✗   |
| `KEM_KEYGEN`    | ✓             | ✓             | ✗        | ✗   |
| `KEM_ENCAP`     | ✗             | ✓             | ✓        | ✗   |
| `KEM_DECAP`     | ✗             | ✓             | ✓        | ✗   |
| `DSA_KEYGEN`    | ✓             | ✓             | ✗        | ✗   |
| `DSA_SIGN`      | ✗             | ✓             | ✓        | ✗   |
| `DSA_VERIFY`    | ✓             | ✓             | ✓        | ✗   |
| `STORE_KEY`     | ✓             | ✓             | ✗        | ✗   |
| `FW_UPDATE`     | ✓             | ✓             | ✗        | ✗   |
| `SECURE_ERASE`  | ✗             | ✓             | ✓        | ✓   |
| `CHANNEL_INIT`  | ✓             | ✓             | ✓        | ✗   |
| `SET_LIFECYCLE` | ✓ (→PROV)     | ✓ (→LOCK/RMA) | ✓ (→RMA) | ✗   |

**Transition rules:**

- `MANUFACTURING → PROVISIONED`: triggered by `SET_LIFECYCLE` command; requires at least one key slot provisioned and device root key set
- `PROVISIONED → LOCKED`: triggered by `SET_LIFECYCLE`; no key import or firmware update possible after this
- `PROVISIONED → RMA`: triggered by `SET_LIFECYCLE`; followed by `SECURE_ERASE`; device returns to eraseable state
- `LOCKED → RMA`: triggered by `SET_LIFECYCLE`; followed by `SECURE_ERASE`

### 5.4 Secure Boot Anti-Rollback

Firmware rollback allows an attacker to downgrade to a vulnerable firmware version. Anti-rollback enforcement is in the Boot ROM — not firmware.

**Rollback counter:**

- 32-bit monotonic counter stored in BRAM (v1) / OTP (v2)
- Stored in Boot ROM address space — firmware cannot write to it
- Boot ROM reads counter and compares against firmware version field in firmware header
- If `fw_version < rollback_counter` → halt unconditionally
- If `fw_version >= rollback_counter` → boot proceeds
- After successful boot and firmware confirmation signal: Boot ROM increments counter to `fw_version`
- Counter can only increase — hardware enforced

**Firmware header format (32-byte prefix, ML-DSA signature covers full image including header):**

```
[0:3]   magic       = 0x51415243  ("QARC")
[4:7]   fw_version  = monotonic integer, must be >= rollback_counter
[8:11]  fw_length   = length of firmware image in bytes
[12:15] reserved
[16:31] reserved
[32..]  firmware image
[end-2420..end]  ML-DSA-65 signature (2420 bytes) over bytes [0..end-2420]
```

### 5.5 NTT Scratchpad Zeroization

After every PQC operation (ML-KEM or ML-DSA), the NTT engine scratchpad BRAM is zeroed before the operation is signalled as complete. This prevents residual polynomial coefficient leakage between operations.

**Zeroization sequence:**

```
PQC operation completes
  → NTT controller asserts ZEROIZE signal
  → Counter walks through all scratchpad addresses: write 0x00000000
  → After all addresses zeroed: assert OP_DONE interrupt to Ibex
  → Firmware may now issue next command
```

Zeroization is an RTL requirement — firmware cannot skip it. The OP_DONE interrupt fires only after zeroization completes.

### 5.6 Entropy Budget

PQC algorithms are entropy-hungry. The DRBG tracks entropy consumption per operation and enforces reseed policy.

| Operation              | Entropy consumed              | Source                |
| ---------------------- | ----------------------------- | --------------------- |
| ML-KEM-768 KeyGen      | 64 bytes                      | DRBG (seed from TRNG) |
| ML-KEM-768 Encaps      | 32 bytes                      | DRBG                  |
| ML-DSA-65 KeyGen       | 32 bytes                      | DRBG                  |
| ML-DSA-65 Sign         | 32 bytes (rho' randomisation) | DRBG                  |
| Session key (Noise IK) | 32 bytes                      | DRBG                  |

**DRBG policy:**

- Reseed from TRNG every 1000 DRBG requests or every 10 minutes (whichever comes first)
- Reseed also triggered when DRBG entropy estimate drops below 128-bit security level
- If TRNG unavailable during required reseed: halt — do not continue with stale DRBG state
- Entropy pool size: 256 bits minimum before any PQC operation is permitted

---

## 6. Functional Requirements

### 6.1 ML-KEM Engine — FIPS 203, ML-KEM-768

The ML-KEM engine implements lattice-based key encapsulation. All polynomial arithmetic is hardware-accelerated. Software firmware only issues commands and reads results.

#### 6.1.1 Required Operations

- `ML-KEM.KeyGen` — generate encapsulation key (ek) and decapsulation key (dk)
- `ML-KEM.Encaps(ek)` — produce shared secret K and ciphertext c
- `ML-KEM.Decaps(dk, c)` — recover shared secret K from ciphertext c

#### 6.1.2 Hardware Accelerated

- NTT and inverse NTT over Zq, q=3329 (via shared NTT engine)
- Coefficient-wise polynomial multiplication in NTT domain
- Barrett reduction for modular arithmetic
- SHAKE-128 and SHAKE-256 (via shared Keccak engine)
- Rejection sampler for uniform polynomial generation
- Centred Binomial Distribution (CBD) sampler

#### 6.1.3 Security Requirements

- Decapsulation key (dk) stored in key store with `DECAP_ONLY | NO_EXPORT` policy — never accessible to firmware
- NTT scratchpad zeroed after every operation (Section 5.5)
- No secret-dependent memory addressing in any operation path
- 100% of NIST FIPS 203 KAT vectors must pass before hardware integration

---

### 6.2 ML-DSA Engine — FIPS 204, ML-DSA-65

The ML-DSA engine implements lattice-based digital signatures. The rejection sampling loop is hardware-accelerated to avoid variable-time execution.

#### 6.2.1 Required Operations

- `ML-DSA.KeyGen` — generate verification key (vk) and signing key (sk)
- `ML-DSA.Sign(sk, M)` — produce signature sigma over message M
- `ML-DSA.Verify(vk, M, sigma)` — verify signature; return accept or reject

#### 6.2.2 Hardware Accelerated

- NTT and inverse NTT over Zq, q=8380417 (shared NTT engine, parameterised)
- Rejection sampling for masking vector y — hardware loop, no timing leak
- SHAKE-256 (via shared Keccak engine)
- Power2Round and MakeHint/UseHint operations

#### 6.2.3 Security Requirements

- Signing key (sk) stored in key store with `SIGN_ONLY | NO_EXPORT` policy — never accessible to firmware
- NTT scratchpad zeroed after every operation (Section 5.5)
- No secret-dependent memory addressing
- Rejection sampling loop is hardware-accelerated — not implemented in firmware
- 100% of NIST FIPS 204 KAT vectors must pass before hardware integration

---

### 6.3 Shared NTT Engine

The NTT engine is the most critical piece of custom RTL in Quarc. Shared between ML-KEM and ML-DSA via synthesis-time parameterisation.

- Supports q=3329 (ML-KEM) and q=8380417 (ML-DSA) — selected via parameter input register
- Iterative butterfly architecture — area-efficient, deterministic latency
- Constant-time operation — no data-dependent branching in any path
- No secret-dependent memory addressing in coefficient scratchpad access
- Coefficient scratchpad via EBR BRAM — polynomials DMA'd in/out
- Scratchpad zeroed after every operation before OP_DONE asserted (Section 5.5)
- Formally verified for functional correctness via SymbiYosys before integration

---

### 6.4 Keccak / SHA-3 / SHAKE Engine

Keccak is the dependency of everything. Built first, verified first.

- Keccak-f[1600] permutation — single shared instance
- SHA3-256 and SHA3-512 modes
- SHAKE-128 and SHAKE-256 XOF modes
- Streaming interface — absorb arbitrary-length input, squeeze arbitrary-length output
- Validated against NIST SHA-3 KAT vectors — all modes, all lengths
- Consumers: ML-KEM, ML-DSA, DRBG, host channel MAC, boot ROM hash

---

### 6.5 Entropy System

Entropy failure is catastrophic. The system is conservative by design. No fallback mode. Failure halts.

#### 6.5.1 TRNG

- Ring oscillator based — minimum 4 independent oscillators XOR'd
- NIST SP 800-90B mandatory health tests in RTL:
  - Repetition Count Test (RCT) — detects stuck bit
  - Adaptive Proportion Test (APT) — detects bias and correlation
- Minimum entropy design target: H_min >= 0.5 bits per raw sample
- Startup behaviour: device blocks ALL operations until entropy pool passes health tests and fills to 256-bit minimum
- TRNG failure response: hard halt, all outputs tri-stated, error flag asserted on SPI
- No silent fallback to PRNG-only mode under any condition

#### 6.5.2 DRBG

- SHAKE-256 based DRBG (per NIST SP 800-90A)
- Seeded from TRNG on startup; reseeded per policy in Section 5.6
- Entropy budget tracked per operation (Section 5.6)
- Halt if reseed required but TRNG unavailable

---

### 6.6 Secure Key Storage

#### 6.6.1 Key Slots

- 8 key slots minimum (configurable at synthesis time via parameter)
- Each slot holds: key material, key type tag, usage policy flags (Section 5.2), monotonic use counter
- BRAM-backed in v1 — keys lost on power cycle; acknowledged v1 limitation
- **No access from firmware or SPI interface — crypto engines access via internal DMA only**
- PMP Region 3 enforces this at hardware level (Section 5.1)
- Key Usage Enforcer validates policy before every operation (Section 5.2)

#### 6.6.2 Key Lifecycle

- Provisioning: keys generated internally (preferred) or injected via encrypted host channel
- Key hierarchy: Device Root Key (DRK) — slot 0, `SIGN_ONLY | NO_EXPORT | NO_OVERWRITE` — derives attestation identity
- Revocation: slot zeroed by KUE, `NO_OVERWRITE` cleared only by `SECURE_ERASE` of full device
- Destruction: `SECURE_ERASE` command zeroes all BRAM regions — requires PROVISIONED or LOCKED state

#### 6.6.3 v1 Limitations — Explicitly Acknowledged

- No OTP — silicon OTP required for persistent key storage in production (keys lost on power cycle)
- No PUF — device identity is software-provisioned in v1; PUF planned for v2
- BRAM is not physically tamper-resistant — acknowledged FPGA prototype limitation

---

### 6.7 Host Interface

#### 6.7.1 Physical Layer

- SPI slave — mode 0 and mode 3 supported
- Maximum SPI clock: 10 MHz (v1); 25 MHz stretch goal
- CS# active low, byte-framed commands
- Command/response model — no streaming

#### 6.7.2 Encrypted Channel — Noise Protocol IK (Hybrid PQC)

The host channel uses the Noise Protocol Framework pattern IK. Key exchange upgraded to hybrid PQC.

- Device static key: ML-DSA-65 keypair (device identity and authentication)
- Ephemeral key exchange: ML-KEM-768 + X25519 (hybrid — both must agree)
- Shared secret: `KDF(ML-KEM_shared_secret || X25519_shared_secret)`
- Channel encryption: AES-256-GCM
- Per-command MAC: HMAC-SHA-256
- Forward secrecy: new ephemeral keypair per session
- Replay protection: 64-bit nonce, strictly monotonic

#### 6.7.3 Command Set

All commands are subject to lifecycle state enforcement (Section 5.3). Commands rejected by lifecycle state return `ERR_LIFECYCLE`. Commands that violate key usage policy return `ERR_KEY_POLICY`.

| Command         | Description                                                                            | Lifecycle        |
| --------------- | -------------------------------------------------------------------------------------- | ---------------- |
| `PING`          | Liveness check — returns firmware version, device status, lifecycle state, TRNG health | All              |
| `GET_RANDOM`    | Return N bytes (max 64) from DRBG output                                               | MFG, PROV, LOCK  |
| `KEM_KEYGEN`    | Generate ML-KEM-768 keypair, store dk in slot with policy, return ek                   | MFG, PROV        |
| `KEM_ENCAP`     | Encapsulate using provided ek — return ciphertext and shared secret                    | PROV, LOCK       |
| `KEM_DECAP`     | Decapsulate using dk in slot (KUE enforces DECAP_ONLY) — return shared secret          | PROV, LOCK       |
| `DSA_KEYGEN`    | Generate ML-DSA-65 keypair, store sk in slot with policy, return vk                    | MFG, PROV        |
| `DSA_SIGN`      | Sign message hash using sk in slot (KUE enforces SIGN_ONLY)                            | PROV, LOCK       |
| `DSA_VERIFY`    | Verify signature using provided vk — return accept/reject                              | MFG, PROV, LOCK  |
| `STORE_KEY`     | Import key into slot with specified policy — encrypted via channel                     | MFG, PROV        |
| `GET_STATUS`    | Return: lifecycle state, TRNG health, boot status, slot occupancy, rollback counter    | All              |
| `SECURE_ERASE`  | Destroy all key material — device returns to eraseable state                           | PROV, LOCK, RMA  |
| `FW_UPDATE`     | Deliver firmware image — ML-DSA verified + rollback checked before flash               | MFG, PROV        |
| `SET_LIFECYCLE` | Advance lifecycle state (one-way)                                                      | Per table in 5.3 |
| `CHANNEL_INIT`  | Initiate Noise IK handshake — first command in any session                             | MFG, PROV, LOCK  |

---

### 6.8 Secure Boot

- Boot ROM (Verilog ROM, synthesis-time loaded) contains: TRNG startup test, PMP configuration, ML-DSA device root public key, rollback counter logic, bootloader stub
- **Boot ROM configures and locks all PMP regions before loading firmware** (Section 5.1)
- Power-on sequence: TRNG health test → PMP configure+lock → load firmware → ML-DSA verify → rollback check → jump
- `ML-DSA.Verify(root_vk, fw_hash, fw_sig)` must return accept — halt if fail
- Rollback check: `fw_version >= rollback_counter` — halt if fail (Section 5.4)
- Firmware hash computed over entire image before signature check — no TOCTOU
- On any boot failure: halt unconditionally — no fallback, no retry, no execution

---

### 6.9 Firmware

- Runs on Ibex RV32IMC — bare metal C, no OS, no RTOS
- Compiled: `riscv32-unknown-elf-gcc`, `march=rv32imc`, `-Os`
- Responsibilities: command parsing, accelerator orchestration, lifecycle transitions, error handling, watchdog service
- Firmware size target: < 64KB
- **Firmware never reads key bytes** — issues commands to KUE only
- Watchdog must be serviced every 100ms — firmware hang causes hardware reset

---

## 7. Non-Functional Requirements

### 7.1 Performance Targets

| Operation         | Quarc target @ 50 MHz | pqm4 baseline (M4 @ 168 MHz) | Min speedup                         |
| ----------------- | --------------------- | ---------------------------- | ----------------------------------- |
| ML-KEM-768 KeyGen | < 0.5 ms              | ~1.5 ms                      | >= 3x                               |
| ML-KEM-768 Encaps | < 0.5 ms              | ~1.7 ms                      | >= 3x                               |
| ML-KEM-768 Decaps | < 0.5 ms              | ~1.8 ms                      | >= 3x                               |
| ML-DSA-65 KeyGen  | < 2 ms                | ~6 ms                        | >= 3x                               |
| ML-DSA-65 Sign    | < 5 ms                | ~12 ms                       | >= 2x                               |
| ML-DSA-65 Verify  | < 2 ms                | ~5 ms                        | >= 2x                               |
| Keccak 1 block    | < 0.1 ms              | ~0.3 ms                      | >= 3x                               |
| NTT zeroization   | < 0.1 ms              | N/A                          | Must not dominate operation latency |

> Note: pqm4 baselines from the pqm4 benchmark suite on STM32F4 at 168 MHz. 50 MHz is conservative for ECP5.

### 7.2 Resource Budget

- Total LUT target: fits Step 2 target (ECP5-85K, 84k LUT4) with hardware accelerators; Step 1 (BeagleV-Fire, 23k) uses crypto-in-C partition. Original `< 15,000` target is obsolete (measured full-hardware design ~150k LUT4).
- EBR BRAM: < 50% of available 3744 Kbits on ECP5-85K
- Fmax: >= 50 MHz with nextpnr-ecp5, timing constraints enforced, no relaxation

### 7.3 Security Requirements

- No plaintext private key material ever present on the system bus at any time
- No plaintext private key material accessible to firmware — KUE enforces in RTL
- All key store memory regions inaccessible from firmware — PMP Region 3 + bus decoder
- Bus decoder formally verified: no unmapped access; no key store access from firmware context
- TRNG failure causes hard halt — no silent PRNG fallback
- Watchdog causes hard reset if not serviced within 100ms
- JTAG disabled in production bitstream
- UART debug disabled in production bitstream
- NTT, polynomial operations, samplers: constant-time, no data-dependent branching
- No secret-dependent memory addressing anywhere in the crypto path
- Rejection sampling loop in ML-DSA hardware-accelerated
- NTT scratchpad zeroed after every operation before OP_DONE

### 7.4 Auditability Requirements

- One Verilog module per file — no monolithic files
- Maximum module line count: 500 lines
- Every module has a header comment: purpose, inputs/outputs, assumptions, limitations
- No FPGA-specific primitives in core logic — inferred only
- No `initial` blocks in synthesizable RTL
- No `$display`, `$finish`, `$dumpvars` in synthesizable RTL
- All constants named with `parameter` — no magic numbers
- Module hierarchy max depth: 4 levels

### 7.5 Toolchain and Build Requirements

- 100% open-source: Yosys, nextpnr-ecp5, sv2v, ecppack, openFPGALoader
- 100% open-source simulation: Icarus Verilog, Verilator
- 100% open-source formal: SymbiYosys
- Build system: GNU Make — single Makefile, reproducible
- No FuseSoC, no CMake, no Bazel

---

## 8. Key Design Decisions

> These decisions are locked for v1. Revisiting them requires a formal PRD amendment.

| Decision              | Chosen                       | Rejected                    | Rationale                                                                            |
| --------------------- | ---------------------------- | --------------------------- | ------------------------------------------------------------------------------------ |
| HDL language          | Verilog 2005 (Quarc RTL)     | SystemVerilog               | Yosys native for all Quarc logic. sv2v handles Ibex only.                            |
| CPU core              | Ibex RV32IMC (via sv2v)      | PicoRV32 (no PMP)           | SE-proven. Hardware PMP mandatory for Boot ROM isolation policy.                     |
| FPGA family           | Lattice ECP5                 | Xilinx Artix-7              | Full open-source P&R. Xilinx requires proprietary Vivado.                            |
| FPGA board            | ULX3S 85K                    | OrangeCrab                  | 84K LUTs, open hardware, onboard ESP32 as test host.                                 |
| Bus                   | Custom Wishbone-lite         | AXI4, TileLink              | ~200 lines, formally verifiable, single-master, fully owned.                         |
| Key access model      | Hardware DMA only (KUE)      | Firmware-readable registers | Firmware compromise cannot expose key bytes. This is the SE/accelerator distinction. |
| PMP configuration     | Boot ROM configures + locks  | Firmware configures         | Compromised firmware cannot reconfigure memory isolation.                            |
| Lifecycle enforcement | RTL state machine            | Firmware flag               | Hardware lifecycle cannot be bypassed by compromised firmware.                       |
| Rollback protection   | Boot ROM enforced counter    | Firmware check              | Firmware cannot skip its own downgrade check.                                        |
| NTT zeroization       | RTL-enforced, blocks OP_DONE | Firmware responsibility     | Firmware cannot forget to zeroize. Timing side-channel closed in hardware.           |
| PQC parameters        | ML-KEM-768, ML-DSA-65        | Level 1 / Level 5           | NIST security level 3. Balanced area/security.                                       |
| Host channel          | Noise IK + hybrid KEM        | TLS 1.3, custom             | Proven SE channel pattern. Hybrid = quantum resistance + classical compat.           |
| Firmware environment  | Bare metal C                 | FreeRTOS, Zephyr            | Minimum attack surface. Deterministic timing.                                        |
| Build system          | GNU Make                     | CMake, Bazel                | Universal, readable, zero dependencies.                                              |
| IP licensing          | Permissive only              | GPL, LGPL                   | Commercial product. No copyleft obligations.                                         |
| NTT architecture      | Iterative butterfly          | Parallel / unrolled         | Area-efficient. Formally verifiable. Constant latency.                               |

---

## 9. Test and Verification Strategy

### 9.1 Verification Levels

- **Module simulation** — every RTL module has a dedicated Icarus Verilog testbench
- **Known Answer Tests (KATs)** — all crypto modules verified against official NIST vectors
- **Security policy simulation** — KUE policy violations, PMP violations, lifecycle rejections all simulated
- **Invalid input fuzzing** — malformed SPI commands, invalid slot references, boundary conditions
- **Integration simulation** — full SoC with software SPI master driving command protocol
- **Formal verification** — SymbiYosys on bus decoder, Keccak, TRNG health, PMP config logic, KUE policy engine
- **Hardware-in-loop** — final validation on physical ULX3S with onboard ESP32

### 9.2 KAT Requirements — Mandatory Before Integration

| Module             | KAT Source             | Pass Criterion                               |
| ------------------ | ---------------------- | -------------------------------------------- |
| Keccak/SHA-3/SHAKE | NIST SHA-3 KAT vectors | 100% pass all modes                          |
| ML-KEM-768         | NIST FIPS 203 KAT      | 100% pass keygen, encaps, decaps             |
| ML-DSA-65          | NIST FIPS 204 KAT      | 100% pass keygen, sign, verify               |
| AES-256-GCM        | NIST CAVS / ACVTS      | 100% pass encrypt and decrypt                |
| DRBG (SHAKE-256)   | NIST SP 800-90A KAT    | 100% pass generate with reseed               |
| TRNG health tests  | Injected fault test    | RCT and APT trigger halt on injected failure |

### 9.3 Formal Verification Targets

- Bus decoder: no address maps to two slaves; no unmapped access returns data; key store inaccessible from firmware bus context
- Keccak engine: output matches reference for all absorbed inputs up to bound
- TRNG health logic: RCT and APT thresholds trigger halt correctly
- PMP configuration logic: all regions locked before jump-to-firmware signal asserted
- KUE policy engine: SIGN_ONLY slot cannot be used for DECAP; NO_EXPORT slot never emits key bytes to bus; COUNTER_LIMIT blocks operation when reached
- Lifecycle state machine: no transition back to earlier state; SET_LIFECYCLE only accepted in correct states

### 9.4 Security Simulation Tests

- **KUE policy violation**: attempt DECAP with SIGN_ONLY slot → expect `ERR_KEY_POLICY`
- **Lifecycle violation**: attempt `FW_UPDATE` in LOCKED state → expect `ERR_LIFECYCLE`
- **PMP violation**: firmware attempts to read key store address → expect bus `err` + halt
- **Rollback attack**: load firmware with version < rollback_counter → expect boot halt
- **Invalid Noise handshake**: tampered session key → expect channel drop
- **TRNG failure injection**: force RCT failure → expect device halt within health test window
- **Zeroization verification**: read NTT scratchpad after operation via debug interface → expect all zeros

### 9.5 v1 Success Criteria — All Must Pass

- [ ] ML-KEM-768 full round trip (keygen → encaps → decaps) correct on hardware
- [ ] ML-DSA-65 full round trip (keygen → sign → verify) correct on hardware
- [ ] 100% NIST KAT pass for Keccak, ML-KEM-768, ML-DSA-65, AES-256-GCM, DRBG
- [ ] Hardware-generated randomness passes NIST SP 800-22 statistical test suite
- [ ] SPI command protocol correct on all 14 commands across all applicable lifecycle states
- [ ] Encrypted host channel: Noise IK handshake, session, AES-GCM all working
- [ ] Secure boot: unsigned firmware rejected; signed firmware accepted; rollback rejected
- [ ] KUE policy violations correctly rejected in simulation and hardware
- [ ] Lifecycle state transitions correct and irreversible
- [ ] NTT scratchpad verified zero after every operation
- [ ] PMP regions locked by Boot ROM before firmware entry (formal proof)
- [ ] Ibex firmware executes without fault for 24-hour continuous soak
- [ ] Total LUT count fits Step 2 target (ECP5-85K, 84k LUT4) with hardware accelerators; Step 1 (BeagleV-Fire, 23k) uses crypto-in-C partition. Original `< 15,000` target is obsolete.
- [ ] Clock frequency >= 50 MHz
- [ ] SymbiYosys formal proofs pass for bus decoder, Keccak, KUE, PMP config, lifecycle FSM
- [ ] v1 use case demo (Section 1.4) runs end-to-end on ULX3S + ESP32

---

## 10. Development Phases

> Each phase must pass its exit criteria before the next begins. No exceptions.

| Phase                      | Weeks | Deliverables                                                                                                            | Exit Criteria                                                                             |
| -------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| **0 — Foundation**         | 1–2   | Ibex (via sv2v) on ECP5-85K. UART hello world. Memory map + PMP region table defined. Bus skeleton. Boot ROM stub.      | Ibex boots. UART correct. Bitstream programs via openFPGALoader. PMP table in spec.       |
| **1 — Keccak**             | 3–5   | Keccak/SHAKE RTL. Icarus testbench. NIST KAT runner. SymbiYosys formal. Memory-mapped interface.                        | 100% NIST SHA-3 KAT pass. Formal proof complete. Accessible from Ibex.                    |
| **2 — Entropy**            | 5–7   | TRNG ring oscillator RTL. SP 800-90B RCT + APT in RTL. SHAKE DRBG with entropy budgeting.                               | SP 800-22 pass. Health test halts on injected failure. Entropy budget counter functional. |
| **3 — NTT Engine**         | 7–10  | NTT/iNTT iterative butterfly. Parameterised q=3329. Scratchpad BRAM. Zeroization RTL. Constant-time. SymbiYosys formal. | NTT(iNTT(poly)) == poly. Formally verified. Zeroization verified in simulation.           |
| **4 — ML-KEM**             | 10–14 | ML-KEM-768 controller. Keygen/Encaps/Decaps. KUE integration (DECAP_ONLY policy). Firmware driver.                      | 100% FIPS 203 KAT pass. KUE policy rejection confirmed in simulation.                     |
| **5 — ML-DSA**             | 13–17 | NTT reparameterised q=8380417. ML-DSA-65 controller. HW rejection sampler. KUE integration (SIGN_ONLY).                 | 100% FIPS 204 KAT pass. KUE policy rejection confirmed.                                   |
| **6 — Security Policy**    | 16–20 | KUE full RTL. PMP Boot ROM configuration. Lifecycle FSM. Rollback counter. SymbiYosys formal on all policy modules.     | All formal proofs pass. Security simulation tests pass (Section 9.4).                     |
| **7 — SPI + Channel**      | 19–23 | SPI slave RTL. Noise IK + hybrid ML-KEM + X25519. AES-256-GCM channel. Host SDK in C.                                   | Full encrypted session. Forward secrecy confirmed. Lifecycle-gated commands working.      |
| **8 — Boot + Integration** | 22–26 | Secure boot ROM (PMP + ML-DSA + rollback). Full SoC integration. 24h soak. v1 use case demo.                            | All Section 9.5 criteria pass. v1 demo runs on ULX3S + ESP32.                             |

---

## 11. Toolchain Reference

| Tool                    | Purpose                    | License         | Notes                                                                          |
| ----------------------- | -------------------------- | --------------- | ------------------------------------------------------------------------------ |
| sv2v                    | SV to Verilog conversion   | MIT             | Converts Ibex SV to Verilog before Yosys. Single Makefile step, deterministic. |
| Yosys                   | RTL synthesis              | ISC             | `synth_ecp5 -abc9`. Native Verilog 2005.                                       |
| nextpnr-ecp5            | Place and route            | ISC             | Project Trellis backend. Timing-driven.                                        |
| ecppack                 | Bitstream generation       | MIT             | Part of Project Trellis.                                                       |
| openFPGALoader          | FPGA programming           | Apache 2.0      | Programs ULX3S natively.                                                       |
| Icarus Verilog          | Functional simulation      | GPL (sim only)  | `iverilog` + `vvp`. GTKWave for waveforms.                                     |
| Verilator               | Fast regression simulation | LGPL (sim only) | C++ compiled. 10–100x faster than Icarus.                                      |
| SymbiYosys              | Formal verification        | ISC             | BMC and k-induction. All policy module targets.                                |
| GTKWave                 | Waveform viewer            | GPL (viewer)    | VCD/FST debug.                                                                 |
| riscv32-unknown-elf-gcc | Firmware compiler          | GPL (compiler)  | `march=rv32imc`. Bare metal.                                                   |
| GNU Make                | Build orchestration        | GPL (tool)      | Single Makefile.                                                               |
| OSS CAD Suite           | All-in-one installer       | Various         | YosysHQ. Installs entire toolchain.                                            |

> GPL applies only to the tools themselves — not to RTL or firmware produced by them.

### Makefile Structure

```makefile
# Ibex SV sources — converted to Verilog via sv2v (one step, cached)
IBEX_SV     = $(wildcard ibex/rtl/*.sv)
IBEX_V      = build/ibex.v

# All Quarc RTL is plain Verilog 2005
QUARC_SRCS  = rtl/top.v rtl/bus.v rtl/keccak.v rtl/ntt.v \
              rtl/mlkem.v rtl/mldsa.v rtl/trng.v rtl/drbg.v \
              rtl/spi.v rtl/uart.v rtl/keystore.v rtl/kue.v \
              rtl/lifecycle.v rtl/rollback.v \
              rtl/boot_rom.v rtl/timer.v

ALL_SRCS    = $(IBEX_V) $(QUARC_SRCS)

$(IBEX_V): $(IBEX_SV)
	mkdir -p build
	sv2v $(IBEX_SV) -w $(IBEX_V)

sim: $(IBEX_V)
	iverilog -o sim.vvp $(ALL_SRCS) tb/tb_top.v && vvp sim.vvp

synth: $(IBEX_V)
	yosys -p "synth_ecp5 -abc9 -json build/quarc.json" $(ALL_SRCS)

pnr: synth
	nextpnr-ecp5 --85k --json build/quarc.json \
	             --lpf boards/ulx3s.lpf \
	             --textcfg build/quarc.config

bitstream: pnr
	ecppack build/quarc.config build/quarc.bit

prog: bitstream
	openFPGALoader -b ulx3s build/quarc.bit

formal:
	sby -f formal/bus_decoder.sby
	sby -f formal/keccak.sby
	sby -f formal/trng_health.sby
	sby -f formal/pmp_config.sby
	sby -f formal/kue_policy.sby
	sby -f formal/lifecycle_fsm.sby
```

---

## 12. Risks and Mitigations

| Risk                                  | Likelihood | Impact   | Mitigation                                                                                                  |
| ------------------------------------- | ---------- | -------- | ----------------------------------------------------------------------------------------------------------- |
| NTT engine area exceeds budget        | Medium     | High     | Iterative architecture. 13.7K of 15K estimate. Scratchpad size tunable.                                     |
| nextpnr timing failure at 50 MHz      | Medium     | Medium   | 50 MHz conservative for ECP5. Pipeline NTT critical path if needed. `-abc9`.                                |
| TRNG entropy quality insufficient     | Low        | Critical | Conservative H_min. Multiple oscillators. SP 800-90B in RTL. Entropy budgeting enforced.                    |
| ML-DSA rejection sampling timing leak | Medium     | High     | Hardware loop. Constant iteration count. Verified by simulation.                                            |
| BRAM key store lost on power cycle    | Certain    | Low (v1) | Acknowledged limitation. OTP planned for v2.                                                                |
| KUE policy bypass via bus timing      | Low        | Critical | KUE formally verified. Bus `err` on any policy violation. No race condition in single-master bus.           |
| PMP misconfiguration in Boot ROM      | Low        | Critical | Boot ROM is synthesis-time Verilog ROM — cannot be modified at runtime. PMP config formally verified (sby). |
| Rollback counter reset attack         | Low        | High     | Counter is Boot ROM address space — PMP blocks firmware write. Increment is RTL logic, not firmware.        |
| Noise Protocol implementation error   | Medium     | High     | Reference test vectors. C firmware implementation. Independent code review.                                 |
| Lifecycle FSM bypass                  | Low        | High     | FSM formally verified. State register in hardware — not firmware-writable memory.                           |
| Zeroization incomplete before OP_DONE | Low        | Medium   | OP_DONE interrupt gated on zeroization complete signal in RTL. Cannot be bypassed.                          |
| Scope creep in v1                     | High       | Medium   | PRD is scope lock. Section 2.3 is the explicit out-of-scope list.                                           |

---

## 13. Future Roadmap

> v1 proves the architecture. Roadmap is contingent on v1 success criteria passing.

### 13.1 v2 — Hardened SE

- PUF — device identity rooted in silicon entropy; fuzzy extractor for PUF-derived keys
- Real OTP / NVM — persistent key storage
- Tamper detection: voltage glitch, temperature, EMP (ASIC)
- Active shield (ASIC only)
- Side-channel countermeasures: Boolean masking on NTT, randomised execution order
- Memory address scrambling and on-the-fly encryption for key store
- SLH-DSA hash-based signatures
- Common Criteria EAL4+ certification path
- Hardware security module (HSM) form factor

### 13.2 v3 — TEE Root of Trust

- PQC attestation: ML-DSA-signed attestation reports for confidential computing platforms
- Sealing keys: derive keys bound to firmware measurement (PCR-style)
- Secure provisioning protocol with ML-KEM encrypted key injection
- Migration keys: quantum-safe key migration between devices
- Platform interface: PCIe or I3C for server/TEE integration
- Integration targets: AMD SEV-SNP, Intel TDX, Arm CCA

### 13.3 ASIC Path

- FPGA prototype validates RTL — ASIC port requires no core rewrite (P5)
- ASIC additions: standard cell library, DFT, physical design, tamper mesh
- Technology node: 40nm or 22nm FD-SOI
- Certification: FIPS 140-3 Level 3, Common Criteria EAL5+

---

## 14. Glossary

| Term           | Definition                                                                                                                                      |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CRQC           | Cryptographically Relevant Quantum Computer — a quantum computer capable of running Shor's algorithm to break RSA and ECC                       |
| DRBG           | Deterministic Random Bit Generator — a cryptographic PRNG seeded from a TRNG, per NIST SP 800-90A                                               |
| DRK            | Device Root Key — the master signing key in slot 0; SIGN_ONLY, NO_EXPORT, NO_OVERWRITE                                                          |
| EBR            | Embedded Block RAM — dedicated SRAM blocks in the Lattice ECP5 FPGA fabric                                                                      |
| ECP5           | Lattice Semiconductor ECP5 FPGA family — fully open-source toolchain (Yosys/nextpnr/Project Trellis)                                            |
| FIPS 203       | US Federal Information Processing Standard 203 — specifies ML-KEM                                                                               |
| FIPS 204       | US Federal Information Processing Standard 204 — specifies ML-DSA                                                                               |
| Ibex           | Small 32-bit RISC-V CPU core by lowRISC (Apache 2.0). Quarc's control plane. Synthesised via sv2v + Yosys. SE-proven in OpenTitan and TROPIC01. |
| KAT            | Known Answer Test — NIST-published test vector for cryptographic validation                                                                     |
| KUE            | Key Usage Enforcer — Quarc's RTL policy engine that enforces per-slot key usage restrictions and prevents firmware from reading key bytes       |
| ML-DSA         | Module Lattice Digital Signature Algorithm (FIPS 204) — post-quantum signatures, also known as Dilithium                                        |
| ML-KEM         | Module Lattice Key Encapsulation Mechanism (FIPS 203) — post-quantum key exchange, also known as Kyber                                          |
| NTT            | Number Theoretic Transform — the FFT analogue over a finite field; core mathematical operation in lattice-based PQC                             |
| Noise Protocol | Framework for building secure channel protocols with formal security proofs. Pattern IK used for SE host channel.                               |
| PMP            | Physical Memory Protection — RISC-V hardware extension present in Ibex; configured and locked by Boot ROM before firmware executes              |
| PQC            | Post-Quantum Cryptography — cryptographic algorithms believed to resist attacks by quantum computers                                            |
| PUF            | Physically Unclonable Function — a circuit producing a unique response derived from manufacturing variations                                    |
| RoT            | Root of Trust — the hardware component that all subsequent security in the system depends upon                                                  |
| SE             | Secure Element — a tamper-resistant microprocessor that stores secrets and performs crypto in isolation                                         |
| SPI            | Serial Peripheral Interface — synchronous serial protocol for host MCU to Quarc communication                                                   |
| sv2v           | SystemVerilog-to-Verilog converter (MIT license). Converts Ibex RTL for Yosys synthesis. Deterministic, open source.                            |
| TEE            | Trusted Execution Environment — isolated compute environment (e.g. AMD SEV-SNP, Intel TDX, Arm CCA)                                             |
| TRNG           | True Random Number Generator — generates randomness from physical entropy source (ring oscillators)                                             |
| ULX3S          | Open hardware FPGA board by Radiona.org featuring Lattice ECP5-85K and full open-source tool support                                            |
| Wishbone       | Open-source hardware bus standard. Quarc uses a simplified Wishbone-compatible single-master bus.                                               |
| XOF            | Extendable Output Function — hash variant producing arbitrary-length output (SHAKE-128, SHAKE-256)                                              |

---

_Quarc Secure Element // PRD v1.1 // 2025 // Proprietary & Confidential_
