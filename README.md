# Quarc

A post-quantum Secure Element for IoT: hardware-accelerated ML-KEM-768 and
ML-DSA-65 (FIPS 203/204), hardware-enforced key policy, and secure boot — the
hardware root of trust for connected devices, built on open FPGA tooling.

> _"A TROPIC01-class Secure Element after the PQC transition."_

## Features

- **Post-quantum crypto** — ML-KEM-768 + ML-DSA-65 per NIST FIPS 203/204
- **Hardware key policy** — keys never leave the trust boundary; usage enforced in RTL (KUE), not firmware
- **Secure boot** — ML-DSA-verified firmware with monotonic anti-rollback
- **Encrypted host channel** — Noise IK (ML-KEM + X25519 hybrid) over SPI, AES-256-GCM
- **True entropy** — TRNG with SP 800-90B health tests in RTL; SHAKE-256 DRBG
- **Open toolchain** — Yosys / nextpnr / SymbiYosys; no Vivado, no Quartus

## Status

| Phase | Deliverable                               | Status                                       |
| :---: | ----------------------------------------- | -------------------------------------------- |
|  0–2  | Foundation, Keccak/SHA-3, entropy         | ✅ verified                                  |
|   3   | NTT engine                                | 🟡 sim-verified; silicon timing closure open |
|   4   | ML-KEM-768                                | 🟡 software path passes full KAT             |
|  5–8  | ML-DSA, security policy, SPI, integration | ⚪ not started                               |

Running today: full ML-KEM-768 KAT against the fabric on a BeagleV-Fire
(SHA-3 and NTT butterflies verified on silicon) — details in the
[status dashboard](docs/README.md).

## Quick Start

```bash
# 1. Clone (with Ibex submodule)
git clone <repo-url> quarc && cd quarc
git submodule update --init --recursive

# 2. Run the host self-test — no hardware required
cd tools/host_test && make run
#   → expect: HOST KAT: PASS

# 3. Simulate / build
make sim        # full SoC simulation
make synth      # synthesis + LUT report
```

Bring up real hardware (build gateware → flash → verify → benchmark):
see [Guide 1](docs/guides/beaglev-fire-bringup.md).

## Documentation

All documentation lives in [`docs/`](docs/README.md):

| Document                                                                | What it covers                                      |
| ----------------------------------------------------------------------- | --------------------------------------------------- |
| [Product Requirements](docs/prd.md)                                     | Goals, threat model, security policy, phases        |
| [Implementation Plan](docs/implementation-plan.md)                      | Phase-by-phase tasks with acceptance criteria       |
| [Architecture & Technical Reference](docs/architecture.md)              | SoC diagram, memory map, command set, budgets       |
| [Guide 1 — Board Bring-Up](docs/guides/beaglev-fire-bringup.md)         | Host test → flash → on-board KAT                    |
| [Guide 2 — Build / Flash / Verify](docs/guides/gateware-build-flash.md) | Toolchain setup, Libero build, flashing, benchmarks |
| [Status Dashboard](docs/README.md)                                      | Current progress, what's blocked                    |

## Contributing

Internal project — see [`docs/implementation-plan.md`](docs/implementation-plan.md)
for how work is structured, and the RTL conventions in
[`docs/architecture.md`](docs/architecture.md) before submitting changes.

## License

The synthesizable path uses only permissive-licensed components (MIT, ISC, BSD, Apache 2.0); no GPL
or LGPL in the synthesis path.
