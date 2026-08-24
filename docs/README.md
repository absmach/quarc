# Quarc documentation

| Document                                                         | Contents                                                                                   |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [prd.md](prd.md)                                                 | Product requirements: objectives, threat model, security policy, test strategy             |
| [implementation-plan.md](implementation-plan.md)                 | Phase-by-phase build plan (Phase 0–8) with acceptance criteria, register maps              |
| [architecture.md](architecture.md)                               | SoC diagram, memory map, SPI command set, measured LUT budgets, toolchain, RTL conventions |
| [guides/beaglev-fire-bringup.md](guides/beaglev-fire-bringup.md) | Board bring-up: host self-test, cape layout, MMIO map, on-board KAT                        |
| [guides/gateware-build-flash.md](guides/gateware-build-flash.md) | Gateware build, flashing, verification, benchmarks, timing investigation                   |

Read the PRD first if you want the why; the implementation plan for the how;
the guides when you have a board in front of you.

## Current status

The Step 1 crypto fabric is built, flashed, and proven on silicon for SHA-3
and the NTT butterflies. The one blocker before end-to-end ML-KEM on hardware
is an NTT basemul setup-timing violation, documented in
[Guide 2 §6.4](guides/gateware-build-flash.md).

Status legend: ✅ verified · 🟡 code complete, awaiting verification · ⚪ not started

| Phase               | Deliverable                            | Key Exit Gate                           | Status                                                                                                                                                         |
| ------------------- | -------------------------------------- | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0 — Foundation      | Ibex boots on ULX3S, UART "QUARC v0"   | Physical board test                     | ✅ sim + synth + PnR verified (26.9 MHz)                                                                                                                       |
| 1 — Keccak          | SHA-3/SHAKE engine                     | 100% NIST SHA-3 KAT + SymbiYosys proof  | ✅ 72/72 KAT, formal BMC, bus-wired, firmware self-test passes; **silicon verified**                                                                           |
| 2 — Entropy         | TRNG + SHAKE-256 DRBG                  | SP 800-22 pass + DRBG KAT               | ✅ RCT/APT health, formal BMC, DRBG KAT, SoC firmware test, SP 800-22 17/17 PASS _(deferred from Step 1 bring-up build)_                                       |
| 3 — NTT             | Shared NTT/iNTT engine                 | NTT(iNTT(p))==p + zeroization formal    | 🟡 bus-wired, firmware round-trip passes, KAT 4/4, 2.5k LUTs; **basemul silicon timing open** ([Guide 2 §6.4](guides/gateware-build-flash.md)); formal pending |
| 4 — ML-KEM          | ML-KEM-768 + KUE integration           | 100% FIPS 203 KAT + KUE rejection tests | 🟡 software path (`mlkem_sw.c`) verified (host KAT PASS); hardware-controller increment not started                                                            |
| 5 — ML-DSA          | ML-DSA-65 + hardware rejection sampler | 100% FIPS 204 KAT + timing at 50 MHz    | ⚪ not started                                                                                                                                                 |
| 6 — Security Policy | KUE, PMP, lifecycle, rollback formal   | All 6 SymbiYosys proofs pass            | ⚪ not started                                                                                                                                                 |
| 7 — SPI + Channel   | Noise IK, AES-GCM, all 14 commands     | Encrypted session end-to-end            | ⚪ not started                                                                                                                                                 |
| 8 — Integration     | Secure boot, 24h soak, OTA demo        | All PRD v1.1 Section 9.5 criteria       | ⚪ not started                                                                                                                                                 |

### Board verification checklist (Step 1)

| Check                                    | Result                                  |
| ---------------------------------------- | --------------------------------------- |
| Host self-test (`tools/host_test`)       | ✅ `HOST KAT: PASS`                     |
| Cape gateware builds in Libero           | ✅ `mpfs_bitstream.spi` exported        |
| Flash + reboot into Quarc gateware       | ✅ ID reads `"QUAR"`                    |
| SHA-3 data path on silicon               | ✅ Correct & deterministic              |
| Forward/inverse NTT on silicon           | ✅ 256/256 coefficients correct         |
| Basemul on silicon                       | ❌ 2/128 pairs wrong — timing violation |
| Full ML-KEM KAT on board (`MLKEM SW OK`) | ❌ Blocked by basemul timing            |

## Related material outside `docs/`

- [`../README.md`](../README.md) — repo overview and quick start.
- [`../boards/beaglev-fire/gateware/`](../boards/beaglev-fire/gateware/) — cape HDL, build config (`QUARC-CAPE.yaml`), HSS/MSS patches, APB testbench.
- [`../rtl/`](../rtl/) — shared RTL (`sha3.v`, `ntt.v`, `keccak.v`, …).
- [`../fw/mlkem_sw.c`](../fw/mlkem_sw.c) + [`../tools/board/`](../tools/board/) — firmware and board-side test/bench tools.
- [`../kat/`](../kat/) — NIST KAT vectors (gitignored; download separately — see root README).
