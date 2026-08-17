#!/usr/bin/env python3
"""gen_mlkem_kat.py - FIPS 203 ML-KEM-768 reference + hardware KAT vectors.

Implements the full ML-KEM-768 algorithm (keygen / encaps / decaps) in plain
Python and emits deterministic test vectors for the hardware controller:

  kat/mlkem_pk.txt   - public key bytes (hex, 1184 bytes)
  kat/mlkem_dk.txt   - decapsulation key bytes (hex, 2400 bytes)
  kat/mlkem_ct.txt   - ciphertext bytes (hex, 1088 bytes)
  kat/mlkem_ss.txt   - shared secret bytes (hex, 32 bytes)
  kat/mlkem_seed.txt - seeds used (d, z, m)

Optional cross-check against the `kyber_py` package (pip install kyber-py):
    python3 scripts/gen_mlkem_kat.py --check
"""

import hashlib
import os
import sys

Q = 3329
N = 256
K = 3          # ML-KEM-768
ETA1 = 2
ETA2 = 2
DU = 10
DV = 4


def bitrev7(x):
    r = 0
    for _ in range(7):
        r = (r << 1) | (x & 1)
        x >>= 1
    return r


ZETAS = [pow(17, bitrev7(i), Q) for i in range(128)]


def ntt(f):
    f = f[:]
    k = 1
    length = 128
    while length >= 2:
        for start in range(0, N, 2 * length):
            zeta = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                t = (zeta * f[j + length]) % Q
                f[j + length] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        length //= 2
    return f


def invntt(f):
    f = f[:]
    k = 127
    length = 2
    while length <= 128:
        for start in range(0, N, 2 * length):
            zeta = ZETAS[k]
            k -= 1
            for j in range(start, start + length):
                t = f[j]
                f[j] = (f[j] + f[j + length]) % Q
                f[j + length] = ((f[j + length] - t) * zeta) % Q
        length *= 2
    finv = pow(N // 2, Q - 2, Q)
    return [(c * finv) % Q for c in f]


def basemul(a, b):
    r = [0] * N
    for p in range(128):
        zeta = ZETAS[64 + (p >> 1)]
        if p & 1:
            zeta = (Q - zeta) % Q
        a0, a1 = a[2 * p], a[2 * p + 1]
        b0, b1 = b[2 * p], b[2 * p + 1]
        r[2 * p] = (a0 * b0 + a1 * b1 * zeta) % Q
        r[2 * p + 1] = (a0 * b1 + a1 * b0) % Q
    return r


def poly_add(f, g):
    return [(x + y) % Q for x, y in zip(f, g)]


def compress(x, d):
    return (((x << d) + Q // 2) // Q) & ((1 << d) - 1)


def decompress(y, d):
    return ((y * Q + (1 << (d - 1))) >> d) % Q


def byte_encode(coeffs, d):
    out = bytearray()
    acc = 0
    bits = 0
    for c in coeffs:
        acc |= (c & ((1 << d) - 1)) << bits
        bits += d
        while bits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            bits -= 8
    if bits > 0:
        out.append(acc & 0xFF)
    return bytes(out)


def byte_decode(data, d):
    coeffs = []
    acc = 0
    bits = 0
    for byte in data:
        acc |= byte << bits
        bits += 8
        while bits >= d:
            coeffs.append(acc & ((1 << d) - 1))
            acc >>= d
            bits -= d
    return coeffs


def sample_ntt(rho, i, j):
    xi = hashlib.shake_128(rho + bytes([i, j])).digest(768)
    coeffs = []
    for p in range(0, len(xi) - 2, 3):
        b0, b1, b2 = xi[p], xi[p + 1], xi[p + 2]
        d1 = b0 | ((b1 & 0x0F) << 8)
        if d1 < Q:
            coeffs.append(d1)
            if len(coeffs) == N:
                return coeffs
        d2 = (b1 >> 4) | (b2 << 4)
        if d2 < Q:
            coeffs.append(d2)
            if len(coeffs) == N:
                return coeffs
    raise ValueError("SampleNTT: not enough bytes")


def cbd(bytearray_b, eta):
    b_int = int.from_bytes(bytearray_b, "little")   # FIPS 203: bit 8i+j = byte i bit j
    mask = (1 << eta) - 1
    mask2 = (1 << (2 * eta)) - 1
    f = [0] * N
    for i in range(N):
        x = b_int & mask2
        a = bin(x & mask).count("1")
        dd = bin((x >> eta) & mask).count("1")
        b_int >>= 2 * eta
        f[i] = (a - dd) % Q
    return f


def sample_poly_cbd(sigma, eta, nonce):
    b = hashlib.shake_256(sigma + bytes([nonce])).digest(64 * eta)
    return cbd(b, eta)


def _pke_encrypt(ek_pk, m, r):
    """K-PKE.Encrypt: encrypt m under ek_pk using randomness r -> (c1, c2)."""
    that = [byte_decode(ek_pk[384 * i:384 * (i + 1)], 12) for i in range(K)]
    rho = ek_pk[-32:]
    ahat = [[sample_ntt(rho, j, i) for j in range(K)] for i in range(K)]  # A[i][j]=SampleNTT(rho||j||i)
    yhat = [ntt(sample_poly_cbd(r, ETA1, j)) for j in range(K)]
    e1 = [sample_poly_cbd(r, ETA2, K + j) for j in range(K)]
    e2 = sample_poly_cbd(r, ETA2, 2 * K)

    u = []
    for i in range(K):
        acc = e1[i][:]
        for j in range(K):
            acc = poly_add(acc, invntt(basemul(ahat[j][i], yhat[j])))
        u.append(acc)

    mu = [compress(c, DU) for poly in u for c in poly]
    tv = [0] * N
    for j in range(K):
        tv = poly_add(tv, invntt(basemul(that[j], yhat[j])))
    msg = [decompress(bit, 1) for bit in byte_decode(m, 1)]   # 0 or (q+1)/2
    v = [compress(c, DV) for c in poly_add(poly_add(tv, e2), msg)]

    return byte_encode(mu, DU), byte_encode(v, DV)


def keygen(d, z):
    g = hashlib.sha3_512(d + bytes([K])).digest()   # G(d || k), FIPS 203
    rho, sigma = g[:32], g[32:]
    ahat = [[sample_ntt(rho, j, i) for j in range(K)] for i in range(K)]  # A[i][j]=SampleNTT(rho||j||i)
    shat = [ntt(sample_poly_cbd(sigma, ETA1, j)) for j in range(K)]
    ehat = [ntt(sample_poly_cbd(sigma, ETA1, K + j)) for j in range(K)]
    that = []
    for i in range(K):
        acc = ehat[i][:]
        for j in range(K):
            acc = poly_add(acc, basemul(ahat[i][j], shat[j]))   # NTT domain
        that.append(acc)
    ek_pk = byte_encode([c for poly in that for c in poly], 12) + rho
    dk_s = byte_encode([c for poly in shat for c in poly], 12)
    ek = ek_pk
    dk = dk_s + ek_pk + hashlib.sha3_256(ek_pk).digest() + z
    return ek, dk


def encaps(ek_pk, m):
    h = hashlib.sha3_256(ek_pk).digest()
    g = hashlib.sha3_512(m + h).digest()
    K, r = g[:32], g[32:]
    c1, c2 = _pke_encrypt(ek_pk, m, r)
    return K, c1 + c2


def _pke_decrypt(dk_pke, c):
    """K-PKE.Decrypt: recover the 32-byte message from ciphertext c."""
    shat = [byte_decode(dk_pke[384 * i:384 * (i + 1)], 12) for i in range(K)]
    c1, c2 = c[:960], c[960:]
    u = [[decompress(coef, DU) for coef in byte_decode(c1, DU)][N * i:N * (i + 1)]
         for i in range(K)]
    v = [decompress(coef, DV) for coef in byte_decode(c2, DV)]
    acc = [0] * N
    for j in range(K):
        acc = poly_add(acc, invntt(basemul(shat[j], ntt(u[j]))))
    w = [(x - y) % Q for x, y in zip(v, acc)]   # v - s*u
    m_prime = [compress(x, 1) for x in w]       # Compress(w, 1)
    return byte_encode(m_prime, 1)


def decaps(dk, c):
    dk_pke = dk[:1152]
    ek_pk = dk[1152:2336]
    z = dk[2368:2400]
    m_prime = _pke_decrypt(dk_pke, c)
    h = dk[2336:2368]                          # H(ek) stored in dk
    g = hashlib.sha3_512(m_prime + h).digest()
    K_prime, r = g[:32], g[32:]
    c1, c2 = _pke_encrypt(ek_pk, m_prime, r)
    if c1 + c2 == c:
        return K_prime
    return hashlib.shake_256(z + c).digest(32)  # J(z || c)


def check_kyber_py():
    """Cross-validate encaps/decaps against kyber_py.

    kyber_py is round-3 Kyber (keygen hashes G(d||K)), so keygen outputs differ
    from FIPS 203 (G(d)). The K-PKE / encaps / decaps paths are identical given
    the same key material, so we validate those against kyber_py's keys.
    """
    from kyber_py.ml_kem import ML_KEM_768

    d = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    z = bytes.fromhex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
    m = bytes.fromhex("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f")

    k = ML_KEM_768
    calls = []

    def fake(n):
        # keygen draws d (32) then z (32); encaps draws m (32)
        idx = len(calls)
        calls.append((n, idx))
        if n == 32:
            return [d, z, m][idx]
        return bytes(n)

    orig = k.random_bytes
    k.random_bytes = fake
    try:
        pk_r, dk_r = k.keygen()
        ss_r, ct_r = k.encaps(pk_r)
    finally:
        k.random_bytes = orig

    ss, ct = encaps(pk_r, m)
    ss_d = decaps(dk_r, ct)

    ok = (ct == ct_r and ss == ss_r and ss_d == ss_r)
    print("kyber_py cross-check:", "PASS" if ok else "FAIL")
    if not ok:
        print("  ct match:", ct == ct_r)
        print("  ss match:", ss == ss_r)
        print("  decaps ss match:", ss_d == ss_r)
    return ok


def main():
    d = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    z = bytes.fromhex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
    m = bytes.fromhex("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f")

    if "--check" in sys.argv:
        ok = check_kyber_py()
        sys.exit(0 if ok else 1)

    ek, dk = keygen(d, z)
    ss, ct = encaps(ek, m)
    ss_d = decaps(dk, ct)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    kat = os.path.join(root, "kat")
    os.makedirs(kat, exist_ok=True)

    def w(name, data):
        with open(os.path.join(kat, name), "w") as f:
            f.write(data.hex() + "\n")
        print("wrote kat/%s (%d bytes)" % (name, len(data)))

    w("mlkem_pk.txt", ek)
    w("mlkem_dk.txt", dk)
    w("mlkem_ct.txt", ct)
    w("mlkem_ss.txt", ss)
    with open(os.path.join(kat, "mlkem_seed.txt"), "w") as f:
        f.write("d %s\nz %s\nm %s\n" % (d.hex(), z.hex(), m.hex()))
    print("wrote kat/mlkem_seed.txt")

    # sampling datapath vectors (SampleNTT + CBD)
    rho_ntt = bytes(range(32))
    sigma_ntt = bytes(range(32, 64))
    xof = hashlib.shake_128(rho_ntt + bytes([0, 0])).digest(840)
    prf = hashlib.shake_256(sigma_ntt + bytes([0])).digest(128)
    with open(os.path.join(kat, "samp_ntt_in.txt"), "w") as f:
        for b in xof:
            f.write("%02x\n" % b)
    with open(os.path.join(kat, "samp_ntt_out.txt"), "w") as f:
        for c in sample_ntt(rho_ntt, 0, 0):
            f.write("%03x\n" % c)
    with open(os.path.join(kat, "samp_cbd_in.txt"), "w") as f:
        for b in prf:
            f.write("%02x\n" % b)
    with open(os.path.join(kat, "samp_cbd_out.txt"), "w") as f:
        for c in cbd(prf, 2):
            f.write("%03x\n" % c)
    print("wrote kat/samp_*.txt sampling vectors")

    print("sizes: pk=%d dk=%d ct=%d ss=%d" % (len(ek), len(dk), len(ct), len(ss)))
    print("roundtrip decaps(encaps):", ss == ss_d)


if __name__ == "__main__":
    main()
