# Quarc

Quarc is a post-quantum Secure Element for IoT. It runs ML-KEM-768 and
ML-DSA-65 (NIST FIPS 203/204) in FPGA fabric, keeps key material out of
firmware reach, and verifies every boot image against a monotonic rollback
counter. Built entirely with open tooling (Yosys, nextpnr, SymbiYosys);
no Vivado, no Quartus.

## Features

- ML-KEM-768 and ML-DSA-65 per FIPS 203/204
- Key usage enforced in RTL, not firmware convention
- Secure boot with anti-rollback
- Noise IK host channel (ML-KEM + X25519 hybrid, AES-256-GCM)
- TRNG with SP 800-90B health tests, SHAKE-256 DRBG

## Status

| Phase | Deliverable                               | Status                                    |
| :---: | ----------------------------------------- | ----------------------------------------- |
|  0–2  | Foundation, Keccak/SHA-3, entropy         | verified                                  |
|   3   | NTT engine                                | sim-verified; basemul timing closure open |
|   4   | ML-KEM-768                                | software path passes the full KAT         |
|  5–8  | ML-DSA, security policy, SPI, integration | not started                               |

The full ML-KEM-768 KAT currently runs against the fabric on a BeagleV-Fire;
SHA-3 and the NTT butterflies are verified on silicon. Details in the
[status dashboard](docs/README.md).

## Quick start

```bash
git clone <repo-url> quarc && cd quarc
git submodule update --init --recursive

# host self-test, no hardware needed
cd tools/host_test && make run    # expect: HOST KAT: PASS

# simulation and synthesis
make sim      # full SoC simulation
make synth    # synthesis + LUT report
```

To bring up real hardware, follow [Guide 1](docs/guides/beaglev-fire-bringup.md).

## Documentation

All documentation is under [`docs/`](docs/README.md):

- [Product requirements](docs/prd.md)
- [Implementation plan](docs/implementation-plan.md)
- [Architecture reference](docs/architecture.md)
- [Guide 1: board bring-up](docs/guides/beaglev-fire-bringup.md)
- [Guide 2: gateware build, flash, verify](docs/guides/gateware-build-flash.md)

## License

Open source under two licenses:

- **Apache-2.0** (`LICENSE`) — firmware, tools, scripts, testbenches, documentation
- **CERN Open Hardware Licence v2 - Permissive** (`LICENSE-HARDWARE`) — all RTL and gateware (`rtl/`, `boards/*/gateware`)

Both are permissive; the synthesis path uses only MIT/ISC/BSD/Apache-2.0
components (no GPL/LGPL).
