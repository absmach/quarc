#!/usr/bin/env python3
"""gen_kat.py - generate Keccak/SHA-3 known-answer vectors.

Regenerates the (deterministic) test vectors used by tb_keccak.sv, tb_sha3.sv
and scripts/run_kat.py:

    kat/keccak_f1600_zero.dat   Keccak-f[1600] permutation of the zero state
    kat/keccak_f1600_count.dat  Keccak-f[1600] permutation of lane[i]=i
    kat/sha3/*.txt              SHA3-256/512, SHAKE-128/256 digests (hashlib)

Run `make kat` (or `python3 scripts/gen_kat.py`) after a fresh clone.
"""

import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KAT = os.path.join(ROOT, "kat")
SHA3 = os.path.join(KAT, "sha3")

MASK = (1 << 64) - 1

RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
      0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
      0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]

RHO = {(0, 0): 0, (1, 0): 1, (2, 0): 62, (3, 0): 28, (4, 0): 27,
       (0, 1): 36, (1, 1): 44, (2, 1): 6, (3, 1): 55, (4, 1): 20,
       (0, 2): 3, (1, 2): 10, (2, 2): 43, (3, 2): 25, (4, 2): 39,
       (0, 3): 41, (1, 3): 45, (2, 3): 15, (3, 3): 21, (4, 3): 8,
       (0, 4): 18, (1, 4): 2, (2, 4): 61, (3, 4): 56, (4, 4): 14}


def rotl(v, n):
    n &= 63
    return ((v << n) | (v >> (64 - n))) & MASK if n else v


def keccak_f(lanes):
    a = {(i % 5, i // 5): lanes[i] for i in range(25)}
    for rnd in range(24):
        c = [a[(x, 0)] ^ a[(x, 1)] ^ a[(x, 2)] ^ a[(x, 3)] ^ a[(x, 4)] for x in range(5)]
        d = [c[(x - 1) % 5] ^ rotl(c[(x + 1) % 5], 1) for x in range(5)]
        for (x, y) in a:
            a[(x, y)] ^= d[x]
        b = {}
        for (x, y) in list(a):
            b[(y, (2 * x + 3 * y) % 5)] = rotl(a[(x, y)], RHO[(x, y)])
        a = b
        nb = {}
        for x in range(5):
            for y in range(5):
                nb[(x, y)] = (a[(x, y)] ^ ((~a[((x + 1) % 5, y)]) & a[((x + 2) % 5, y)])) & MASK
        a = nb
        a[(0, 0)] ^= RC[rnd]
    return [a[(i % 5, i // 5)] for i in range(25)]


def state_to_hex(lanes):
    total = 0
    for i in range(25):
        total |= lanes[i] << (i * 64)
    return format(total, "0400x")


def gen_permutation_vectors():
    os.makedirs(KAT, exist_ok=True)
    with open(os.path.join(KAT, "keccak_f1600_zero.dat"), "w") as f:
        f.write(state_to_hex(keccak_f([0] * 25)) + "\n")
    lanes = [i & MASK for i in range(25)]
    with open(os.path.join(KAT, "keccak_f1600_count.dat"), "w") as f:
        f.write(state_to_hex(lanes) + "\n")
        f.write(state_to_hex(keccak_f(lanes)) + "\n")


def gen_sha3_vectors():
    os.makedirs(SHA3, exist_ok=True)
    messages = [b""]
    messages += [bytes([0x61 + i]) for i in range(3)]
    messages += [bytes(range(i)) for i in range(1, 5)]
    messages += [b"abc", b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"]
    messages += [bytes((i * 7) % 256 for i in range(n)) for n in (8, 16, 31, 64, 135, 136, 137, 200)]

    def write(name, func):
        with open(os.path.join(SHA3, name), "w") as f:
            for m in messages:
                f.write(f"{len(m)} {m.hex()} {func(m).hex()}\n")

    write("sha3_256.txt", lambda m: hashlib.sha3_256(m).digest())
    write("sha3_512.txt", lambda m: hashlib.sha3_512(m).digest())
    write("shake128.txt", lambda m: hashlib.shake_128(m).digest(32))
    write("shake256.txt", lambda m: hashlib.shake_256(m).digest(32))


def gen_drbg_vectors():
    """Generate the SHAKE-256 DRBG reference sequence (kat/drbg.txt)."""
    os.makedirs(KAT, exist_ok=True)

    def shake_block(x):
        return hashlib.shake_256(x).digest(136)

    s = bytes(32)                                   # reset state
    e1 = bytes((i * 0x5D) & 0xFF for i in range(32))
    e2 = bytes((i * 0xA7) & 0xFF for i in range(32))

    def generate(n):
        nonlocal s
        b = shake_block(s)
        out = b[:n]
        s = b[32:64]
        return out

    def reseed(e):
        nonlocal s
        x = bytes(a ^ b for a, b in zip(s, e))
        s = shake_block(x)[:32]

    steps = []
    reseed(e1); steps.append(("reseed", e1))
    steps.append(("gen", 32, generate(32)))
    steps.append(("gen", 16, generate(16)))
    reseed(e2); steps.append(("reseed", e2))
    steps.append(("gen", 64, generate(64)))
    steps.append(("gen", 32, generate(32)))

    with open(os.path.join(KAT, "drbg.txt"), "w") as f:
        for st in steps:
            if st[0] == "reseed":
                f.write("reseed %s\n" % st[1].hex())
            else:
                f.write("gen %d %s\n" % (st[1], st[2].hex()))


def main():
    gen_permutation_vectors()
    gen_sha3_vectors()
    gen_drbg_vectors()
    print("generated KAT vectors in", KAT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
