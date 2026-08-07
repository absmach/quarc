#!/usr/bin/env python3
"""run_sp80022.py - NIST SP 800-22 statistical test suite on DRBG output.

Reads the 32-bit words collected by `make drbg-collect` (build/drbg_bits.txt),
concatenates them into a bit string, and runs the SP 800-22 tests. A test
passes when its p-value >= 0.01.

Usage:
    python3 scripts/run_sp80022.py            # full suite on DRBG bits
    python3 scripts/run_sp80022.py --bits n   # use only the first n bits
"""

import argparse
import math
import os
import sys
from fractions import Fraction

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

try:
    from scipy.special import erfc, gammaincc
except ImportError:
    sys.exit("scipy required")


def load_bits(n=None):
    path = os.path.join(ROOT, "build", "drbg_bits.txt")
    if not os.path.exists(path):
        sys.exit("run `make drbg-collect` first (missing %s)" % path)
    bits = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            w = int(line, 16)
            bits.extend((w >> i) & 1 for i in range(32))
            if n and len(bits) >= n:
                break
    return bits[:n] if n else bits


# ---------------------------------------------------------------------------
# Test 1: Frequency (Monobit)
# ---------------------------------------------------------------------------
def monobit(bits):
    n = len(bits)
    s = sum(1 if b else -1 for b in bits)
    s_obs = abs(s) / math.sqrt(n)
    p = erfc(s_obs / math.sqrt(2.0))
    return p


# ---------------------------------------------------------------------------
# Test 2: Frequency within a Block
# ---------------------------------------------------------------------------
def block_frequency(bits, m=128):
    n = len(bits)
    N = n // m
    chi = 0.0
    for i in range(N):
        block = bits[i * m:(i + 1) * m]
        pi = sum(block) / m
        chi += (pi - 0.5) ** 2
    chi *= 4.0 * m
    return gammaincc(N / 2.0, chi / 2.0)


# ---------------------------------------------------------------------------
# Test 3: Runs
# ---------------------------------------------------------------------------
def runs(bits):
    n = len(bits)
    pi = sum(bits) / n
    if abs(pi - 0.5) >= 2.0 / math.sqrt(n):
        return 0.0
    r = 1 + sum(1 for i in range(1, n) if bits[i] != bits[i - 1])
    num = abs(r - 2 * n * pi * (1 - pi))
    den = 2 * math.sqrt(2 * n) * pi * (1 - pi)
    return erfc(num / den)


# ---------------------------------------------------------------------------
# Test 4: Longest Run of Ones in a Block
# ---------------------------------------------------------------------------
def longest_run(bits):
    n = len(bits)
    if n < 128:
        m = 8
    elif n < 6272:
        m = 128
    else:
        m = 10000
    if m == 8:
        M = [1, 2, 3, 4]
        pi = [0.2148, 0.3672, 0.2305, 0.1875]
    elif m == 128:
        M = [4, 5, 6, 7, 8, 9]
        pi = [0.1174, 0.2430, 0.2493, 0.1752, 0.1027, 0.1124]
    else:
        M = [10, 11, 12, 13, 14, 15, 16]
        pi = [0.0882, 0.2092, 0.2483, 0.1933, 0.1208, 0.0675, 0.0727]
    K = len(pi) - 1
    v = [0] * (K + 1)
    N = n // m
    for i in range(N):
        block = bits[i * m:(i + 1) * m]
        longest = cur = 0
        for b in block:
            if b:
                cur += 1
                longest = max(longest, cur)
            else:
                cur = 0
        if longest <= M[0]:
            v[0] += 1
        elif longest >= M[K]:
            v[K] += 1
        else:
            v[longest - M[0]] += 1
    chi = sum(v[j] ** 2 / (N * pi[j]) for j in range(K + 1)) - N
    return gammaincc(K / 2.0, chi / 2.0)


# ---------------------------------------------------------------------------
# Test 5: Binary Matrix Rank
# ---------------------------------------------------------------------------
def _binary_rank(rows):
    rows = [list(r) for r in rows]
    rank = 0
    cols = len(rows[0])
    for col in range(cols):
        piv = None
        for r in range(rank, len(rows)):
            if rows[r][col]:
                piv = r
                break
        if piv is None:
            continue
        rows[rank], rows[piv] = rows[piv], rows[rank]
        for r in range(len(rows)):
            if r != rank and rows[r][col]:
                rows[r] = [a ^ b for a, b in zip(rows[r], rows[rank])]
        rank += 1
        if rank == len(rows):
            break
    return rank


def matrix_rank(bits):
    n = len(bits)
    rows = n // (32 * 32)
    if rows == 0:
        return None
    f_32 = f_31 = f_30 = 0
    for r in range(rows):
        m = [[bits[(r * 1024) + i * 32 + j] for j in range(32)] for i in range(32)]
        rank = _binary_rank(m)
        if rank == 32:
            f_32 += 1
        elif rank == 31:
            f_31 += 1
        elif rank == 30:
            f_30 += 1
    p32, p31, p30 = 0.2888, 0.5776, 0.1336
    chi = ((f_32 - rows * p32) ** 2) / (rows * p32) + \
          ((f_31 - rows * p31) ** 2) / (rows * p31) + \
          ((f_30 - rows * p30) ** 2) / (rows * p30)
    return math.exp(-chi / 2.0)


# ---------------------------------------------------------------------------
# Test 6: Discrete Fourier Transform (Spectral)
# ---------------------------------------------------------------------------
def dft(bits):
    import numpy as np
    n = len(bits)
    X = np.array([1 - 2 * b for b in bits], dtype=float)
    if n > 100000:
        F = np.fft.rfft(X)
        mag = np.abs(F)
    else:
        F = np.fft.fft(X)
        mag = np.abs(F[:n // 2])
    thresh = math.sqrt(2.995732274 * n)
    n0 = int(np.sum(mag < thresh))
    n0_exp = 0.95 * n / 2.0
    n1_exp = 0.05 * n / 2.0
    d = (n0 - n0_exp) ** 2 / n0_exp + ((n / 2 - n0) - n1_exp) ** 2 / n1_exp
    return erfc(math.sqrt(d / 2.0))


# ---------------------------------------------------------------------------
# Test 7: Non-overlapping Template Matching
# ---------------------------------------------------------------------------
def _matches(bits, pos, template):
    return all(bits[pos + i] == template[i] for i in range(len(template)))


def non_overlapping_template(bits, template):
    n = len(bits)
    m = len(template)
    N = n // m
    if N == 0:
        return None
    block_size = n // N
    counts = []
    for i in range(N):
        block = bits[i * block_size:(i + 1) * block_size]
        c = 0
        pos = 0
        while pos <= block_size - m:
            if _matches(block, pos, template):
                c += 1
                pos += m
            else:
                pos += 1
        counts.append(c)
    mu = (block_size - m + 1) / (2.0 ** m)
    sigma2 = block_size * (1.0 / (2.0 ** m) - (2 * m - 1) / (2.0 ** (2 * m)))
    chi = sum((c - mu) ** 2 / sigma2 for c in counts)
    return gammaincc(N / 2.0, chi / 2.0)


# ---------------------------------------------------------------------------
# Test 8: Overlapping Template Matching
# ---------------------------------------------------------------------------
def overlapping_template(bits, m=9, M=1032):
    n = len(bits)
    K = 5
    N = n // M
    if N < 1:
        return None
    block_size = M
    v = [0] * (K + 1)
    if m == 9:
        pi = [0.364091, 0.185659, 0.139381, 0.100571, 0.0704323, 0.139865]
    else:
        lamb = (block_size - m + 1) / (2.0 ** m)
        eta = lamb / 2.0
        pi = [math.exp(-eta) * eta ** k / math.factorial(k) for k in range(K)]
        pi.append(1 - sum(pi))
    pattern = (1 << m) - 1
    mask = pattern
    for i in range(N):
        block = bits[i * block_size:(i + 1) * block_size]
        window = 0
        count = 0
        for j in range(block_size):
            window = ((window << 1) | block[j]) & mask
            if j >= m - 1 and window == pattern:
                count += 1
        if count <= 4:
            v[count] += 1
        else:
            v[K] += 1
    chi = sum((v[k] ** 2 / (N * pi[k]) if pi[k] > 0 else 0.0)
              for k in range(K + 1)) - N
    return gammaincc(K / 2.0, chi / 2.0)


# ---------------------------------------------------------------------------
# Test 9: Maurer's Universal
# ---------------------------------------------------------------------------
def universal(bits):
    n = len(bits)
    L = 7
    Q = 1280
    K = n // L - Q
    if K <= 0:
        return None
    table = {}
    for i in range(Q):
        seg = bits[i * L:(i + 1) * L]
        seg_i = int("".join(map(str, seg)), 2)
        table[seg_i] = i + 1
    s = 0.0
    for j in range(K):
        seg = bits[(Q + j) * L:(Q + j + 1) * L]
        seg_i = int("".join(map(str, seg)), 2)
        d = Q + j + 1 - table.get(seg_i, 0)
        table[seg_i] = Q + j + 1
        s += math.log2(d)
    f = s / K
    exp = 6.1962507
    var = 3.125
    c = 0.7 - 0.8 / L + (4 + 32 / L) * (K ** (-3.0 / L)) / 15
    sigma = c * math.sqrt(var / K)
    return erfc(abs(f - exp) / (math.sqrt(2) * sigma))


# ---------------------------------------------------------------------------
# Test 10: Linear Complexity
# ---------------------------------------------------------------------------
def _berlekamp_massey(seq):
    n = len(seq)
    c = [0] * n
    b = [0] * n
    c[0] = b[0] = 1
    l = 0
    m = 1
    for i in range(n):
        d = seq[i]
        for j in range(1, l + 1):
            d ^= c[j] & seq[i - j]
        if d:
            t = list(c)
            for j in range(n - m):
                if b[j]:
                    c[j + m] ^= 1
            if 2 * l <= i:
                l = i + 1 - l
                b = t
                m = 1
            else:
                m += 1
        else:
            m += 1
    return l


def linear_complexity(bits, m=500):
    n = len(bits)
    N = n // m
    if N == 0:
        return None
    mu = m / 2.0 + (9 + (-1) ** (m + 1)) / 36.0 - (m / 3.0 + 2.0 / 9.0) / (2.0 ** m)
    v = [0] * 6
    for i in range(N):
        seq = bits[i * m:(i + 1) * m]
        L = _berlekamp_massey(seq)
        t = (-1) ** m * (L - mu) + 2.0 / 9.0
        if t <= -2.5:
            v[0] += 1
        elif t <= -1.5:
            v[1] += 1
        elif t <= -0.5:
            v[2] += 1
        elif t <= 0.5:
            v[3] += 1
        elif t <= 1.5:
            v[4] += 1
        else:
            v[5] += 1
    pi = [0.010417, 0.03125, 0.125, 0.5, 0.25, 0.08333]
    chi = sum(v[k] ** 2 / (N * pi[k]) for k in range(6)) - N
    return gammaincc(2.5, chi / 2.0)


# ---------------------------------------------------------------------------
# Test 11: Serial
# ---------------------------------------------------------------------------
def serial(bits, m=16):
    n = len(bits)
    padded = bits + bits[:m - 1]
    p = [0.0] * (m + 1)
    for mm in (m, m - 1, m - 2):
        counts = {}
        for i in range(n):
            pat = padded[i:i + mm]
            key = int("".join(map(str, pat)), 2) if mm else 0
            counts[key] = counts.get(key, 0) + 1
        p[mm] = (2.0 ** mm) / n * sum(c * c for c in counts.values()) - n
    del1 = p[m] - p[m - 1]
    del2 = p[m] - 2 * p[m - 1] + p[m - 2]
    p1 = gammaincc(2.0 ** (m - 2), del1 / 2.0)
    p2 = gammaincc(2.0 ** (m - 3), del2 / 2.0)
    return p1, p2


# ---------------------------------------------------------------------------
# Test 12: Approximate Entropy
# ---------------------------------------------------------------------------
def approximate_entropy(bits, m=10):
    n = len(bits)
    phis = []
    for mm in (m, m + 1):
        padded = bits + bits[:mm - 1]
        counts = {}
        for i in range(n):
            pat = padded[i:i + mm]
            key = int("".join(map(str, pat)), 2) if mm else 0
            counts[key] = counts.get(key, 0) + 1
        phi = sum(c / n * math.log(c / n) for c in counts.values())
        phis.append(phi)
    apen = phis[0] - phis[1]
    chi = 2 * n * (math.log(2) - apen)
    return gammaincc(2.0 ** (m - 1), chi / 2.0)


# ---------------------------------------------------------------------------
# Test 13: Cumulative Sums
# ---------------------------------------------------------------------------
def _cusum_p(z, n):
    def phi(x):
        return 0.5 * erfc(-x / math.sqrt(2.0))
    s1 = 0.0
    for k in range(int(math.floor((-n / z + 1) / 4)), int(math.floor((n / z - 1) / 4)) + 1):
        s1 += phi((4 * k + 1) * z / math.sqrt(n)) - phi((4 * k - 1) * z / math.sqrt(n))
    s2 = 0.0
    for k in range(int(math.floor((-n / z - 3) / 4)), int(math.floor((n / z - 1) / 4)) + 1):
        s2 += phi((4 * k + 3) * z / math.sqrt(n)) - phi((4 * k + 1) * z / math.sqrt(n))
    return 1 - s1 + s2


def cumulative_sums(bits):
    n = len(bits)
    z = 0
    run = 0
    for b in bits:
        run += 1 if b else -1
        z = max(z, abs(run))
    p1 = _cusum_p(z, n)
    z2 = 0
    run = 0
    for b in reversed(bits):
        run += 1 if b else -1
        z2 = max(z2, abs(run))
    p2 = _cusum_p(z2, n)
    return p1, p2


# ---------------------------------------------------------------------------
# Test 14/15: Random Excursions (+ variant)
# ---------------------------------------------------------------------------
def _walk(bits):
    x = 0
    for b in bits:
        x += 1 if b else -1
        yield x


def _cycles(bits):
    cycles = []
    cur = []
    for x in _walk(bits):
        if x == 0:
            cycles.append(cur)
            cur = []
        else:
            cur.append(x)
    return cycles


def random_excursions(bits):
    if max(abs(x) for x in _walk(bits)) < 4:
        return None
    cycles = _cycles(bits)
    J = len(cycles)
    if J == 0:
        return None
    pi = {
        1: [0.5, 0.25, 0.125, 0.0625, 0.0312, 0.0312],
        2: [0.75, 0.0625, 0.0468, 0.0352, 0.0264, 0.0791],
        3: [0.8333, 0.0278, 0.0231, 0.0193, 0.0161, 0.0804],
        4: [0.875, 0.0156, 0.0137, 0.0120, 0.0105, 0.0733],
    }
    pmin = 1.0
    for s in (1, -1, 2, -2, 3, -3, 4, -4):
        cnt = [0] * 6
        for c in cycles:
            v = c.count(s)
            if v >= 5:
                cnt[5] += 1
            else:
                cnt[v] += 1
        chi = 0.0
        for j in range(6):
            expected = J * pi[abs(s)][j]
            chi += (cnt[j] - expected) ** 2 / expected
        p = gammaincc(3.0, chi / 2.0)
        pmin = min(pmin, p)
    return pmin


def random_excursions_variant(bits):
    cycles = _cycles(bits)
    J = len(cycles)
    if J == 0:
        return None
    all_visits = []
    for c in cycles:
        all_visits.extend(c)
    pmin = 1.0
    for s in list(range(-9, 0)) + list(range(1, 10)):
        xi = all_visits.count(s)
        den = math.sqrt(2.0 * J * (4 * abs(s) - 2))
        p = erfc(abs(xi - J) / den) if den > 0 else 1.0
        pmin = min(pmin, p)
    return pmin


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=None, help="only use first N bits")
    args = ap.parse_args()

    bits = load_bits(args.bits)
    n = len(bits)
    print("loaded %d bits" % n)

    results = []

    def report(name, pval):
        if pval is None:
            results.append((name, None, "SKIP"))
            print("%-38s SKIP (insufficient data)" % name)
        else:
            pvals = pval if isinstance(pval, tuple) else (pval,)
            ok = all(p is not None and p >= 0.01 for p in pvals)
            results.append((name, pvals, "PASS" if ok else "FAIL"))
            print("%-38s %s  (p=%.4f%s)" % (name, "PASS" if ok else "FAIL",
                  pvals[0], "" if len(pvals) == 1 else " ..."))

    report("Frequency (Monobit)", monobit(bits))
    report("Block Frequency (m=128)", block_frequency(bits))
    report("Runs", runs(bits))
    report("Longest Run of Ones", longest_run(bits))
    report("Binary Matrix Rank", matrix_rank(bits))
    report("Discrete Fourier Transform (spectral)", dft(bits))
    report("Non-overlapping Template (000000001)", non_overlapping_template(bits, [0] * 8 + [1]))
    report("Overlapping Template (m=9)", overlapping_template(bits))
    report("Maurer's Universal (L=7)", universal(bits))
    report("Linear Complexity (m=500)", linear_complexity(bits))
    s1, s2 = serial(bits)
    report("Serial (m=16) p1", s1)
    report("Serial (m=16) p2", s2)
    report("Approximate Entropy (m=10)", approximate_entropy(bits))
    c1, c2 = cumulative_sums(bits)
    report("Cumulative Sums (forward)", c1)
    report("Cumulative Sums (reverse)", c2)
    report("Random Excursions", random_excursions(bits))
    report("Random Excursions Variant", random_excursions_variant(bits))

    passed = sum(1 for _, pv, st in results if st == "PASS")
    failed = sum(1 for _, pv, st in results if st == "FAIL")
    print("\nSP 800-22: %d PASS, %d FAIL, %d SKIP of %d tests"
          % (passed, failed, len(results) - passed - failed, len(results)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
