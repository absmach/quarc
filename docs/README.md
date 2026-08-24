# Quarc — Documentation

Everything you need to understand, build, and bring up the Quarc post-quantum
Secure Element lives in this `docs/` folder.

> _"A post-quantum Secure Element with hardware-accelerated ML-KEM and ML-DSA,
> securing IoT devices today and anchoring trust for TEEs tomorrow."_

---

## Where do I start?

| I want to…                                        | Read this                                                              | Time      |
| ------------------------------------------------- | ---------------------------------------------------------------------- | --------- |
| Understand what Quarc is and why it exists        | [`prd.md`](prd.md) §1–§3 (overview → threat model)                     | ~20 min   |
| Know exactly what gets built, phase by phase       | [`implementation-plan.md`](implementation-plan.md) ("How to Use" + Phase overview) | ~30 min |
| **Run the project's self-test on my machine**      | [Guide 1](guides/beaglev-fire-bringup.md) §1 (no hardware needed!)     | ~5 min    |
| Bring up a BeagleV-Fire board from scratch         | [Guide 1](guides/beaglev-fire-bringup.md) (follow top to bottom)        | ~1 h      |
| Build & flash the FPGA gateware                    | [Guide 2](guides/gateware-build-flash.md) §2–§5 (follow top to bottom)  | half a day |
| Check current progress / what's blocked            | [Status dashboard](#current-status) below                              | 2 min     |

**Suggested order for newcomers:** PRD (what & why) → Implementation Plan (how)
→ Guide 1 (bring up hardware) → Guide 2 (build/flash/benchmark).

---

## Document map

| Document                                             | What it covers                                                                                   |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| [`prd.md`](prd.md)                                   | **Product Requirements v1.1** — product definition, objectives, threat model, architecture, security policy, functional/non-functional requirements, design decisions, test strategy, development phases, glossary |
| [`implementation-plan.md`](implementation-plan.md)    | **Implementation Plan v1.0** — phase-by-phase build plan (Phase 0–8) written for automated execution: repo structure, memory map, register maps, per-phase tasks with acceptance criteria |
| [`guides/beaglev-fire-bringup.md`](guides/beaglev-fire-bringup.md) | **Guide 1 — Board Bring-Up**: host self-test → SoC simulation → cape gateware layout → MMIO map → on-board KAT → checklist |
| [`guides/gateware-build-flash.md`](guides/gateware-build-flash.md) | **Guide 2 — Build / Flash / Verify / Benchmark**: container setup, FlexNet license fix, Libero build, flashing, on-board verification, benchmarks, silicon timing investigation (§6.4), rollback |

Related material outside `docs/`:

- [`../README.md`](../README.md) — repo overview, architecture, quick build commands.
- [`../boards/beaglev-fire/gateware/`](../boards/beaglev-fire/gateware/) — cape HDL, build config (`QUARC-CAPE.yaml`), HSS/MSS patches, APB testbench.
- [`../rtl/`](../rtl/) — shared RTL (`sha3.v`, `ntt.v`, `keccak.v`, …).
- [`../fw/mlkem_sw.c`](../fw/mlkem_sw.c) + [`../tools/board/`](../tools/board/) — firmware and board-side test/bench tools.
- [`../kat/`](../kat/) — NIST KAT vectors (gitignored; download separately — see root README).

---

## Current status

**One-line summary:** the Step 1 crypto fabric is built, flashed, and proven on
silicon for SHA-3 and the NTT butterflies; the last blocker before end-to-end
ML-KEM-on-hardware is an NTT basemul **timing violation** (details in
[Guide 2 §6.4](guides/gateware-build-flash.md)).

### Implementation phases

| Phase | Title                                | Status                                                            |
| ----- | ------------------------------------ | ----------------------------------------------------------------- |
| 0     | Repository & build foundation        | ✅ Done                                                           |
| 1     | Keccak / SHA-3 / SHAKE engine        | ✅ Done — RTL sim + **silicon verified** (`sha3_256("abc")` correct) |
| 2     | Entropy system (TRNG + DRBG)         | ⏸ Deferred (Step 1 runs KATs only; needed before real keygen)      |
| 3     | NTT engine                           | 🟡 RTL done & sim-verified; **silicon timing closure open** (basemul −6.3 ns, see Guide 2 §6.4) |
| 4     | ML-KEM-768                           | 🟡 Software path passes (host KAT); hardware path blocked by Phase 3 timing |
| 5–8   | ML-DSA-65, security policy, SPI/host, secure boot | ⬜ Not started                                       |

### Board verification checklist (Step 1)

| Check                                            | Result                                     |
| ------------------------------------------------ | ------------------------------------------ |
| Host self-test (`tools/host_test`)               | ✅ `HOST KAT: PASS`                        |
| Cape gateware builds in Libero                   | ✅ `mpfs_bitstream.spi` exported           |
| Flash + reboot into Quarc gateware               | ✅ ID reads `"QUAR"`                       |
| SHA-3 data path on silicon                       | ✅ Correct & deterministic                 |
| Forward/inverse NTT on silicon                   | ✅ 256/256 coefficients correct            |
| Basemul on silicon                               | ❌ 2/128 pairs wrong — timing violation    |
| Full ML-KEM KAT on board (`MLKEM SW OK`)         | ❌ Blocked by basemul timing               |

---

## Conventions used in these documents

- Commands are shown in fenced blocks and are meant to be copy-pasted.
  Blocks marked `# on the board` run on the BeagleV-Fire over SSH; everything
  else runs on your Linux host.
- Every guide step states what you should **see** when it succeeds, so you can
  tell immediately whether to continue or jump to Troubleshooting.
- The two guides reference each other by section number (e.g. "see Guide 2 §6.4").
