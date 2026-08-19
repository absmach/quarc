# Quarc — Documentation

Markdown documentation for the Quarc post-quantum Secure Element project.
All documents below live in this `doc/` folder; canonical copies of the PRD and
implementation plan also live at the repo root (`prd.md`, `implementation-plan.md`)
for discoverability.

| Document | Title | What it covers |
| -------- | ----- | -------------- |
| [`README.md`](README.md) | Documentation index (this file) | How the docs are organized; reading order |
| [`prd.md`](prd.md) | Product Requirements Document v1.1 | Requirements, threat model, security properties, LUT budget, two-step partition (Step 1 = BeagleV-Fire / MPFS025T, Step 2 = ULX3S / ECP5-85K) |
| [`implementation-plan.md`](implementation-plan.md) | Implementation Plan v1.0 | Phase-by-phase build plan for an automated coding agent, register maps, acceptance criteria |
| [`beaglev-fire-bringup.md`](beaglev-fire-bringup.md) | BeagleV-Fire Step 1 Bring-Up | Board bring-up: host KAT harness, SoC simulation, cape gateware layout, MMIO map, board tooling, checklist |
| [`BEAGLEV-FIRE-GATEWARE-BUILD-FLASH-GUIDE.md`](BEAGLEV-FIRE-GATEWARE-BUILD-FLASH-GUIDE.md) | BeagleV-Fire Build/Flash/Verify Guide | End-to-end record: toolchain, license-daemon fix, build blockers and fixes, flashing, verification, benchmarks |

## Reading order

1. **New to the project** → `prd.md` (what and why), then `implementation-plan.md` (how it's built).
2. **Working on the BeagleV-Fire** → `beaglev-fire-bringup.md` (canonical bring-up) and `BEAGLEV-FIRE-GATEWARE-BUILD-FLASH-GUIDE.md` (full process with benchmark numbers).

## Canonical sources

- `prd.md` here is the same content as the repo-root `prd.md`.
- `implementation-plan.md` here is the same content as the repo-root `implementation-plan.md`.
- `beaglev-fire-bringup.md` mirrors `boards/beaglev-fire.md` (the board-side doc).
- The build/flash guide is the only detailed record of the 2026-08-18 gateware build,
  the FlexNet v11.19 daemon fix, and the projected hardware benchmarks.

## Related (outside `doc/`)

- [`../README.md`](../README.md) — project overview, architecture, build/run instructions.
- [`../boards/beaglev-fire.md`](../boards/beaglev-fire.md) — board bring-up doc (source of `doc/beaglev-fire-bringup.md`).
- [`../boards/beaglev-fire/gateware/`](../boards/beaglev-fire/gateware/) — cape HDL, build config, patches, testbench.
- [`../tools/board/`](../tools/board/) — `devmem_probe`, `quarc_kat`, `bench_sha3`, `bench_ntt`, `verify_quarc_cape.sh`.
- [`../kat/`](../kat/) — NIST KAT vectors (gitignored; download separately — see `../README.md`).
