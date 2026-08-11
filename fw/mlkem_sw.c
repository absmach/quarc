#include "mlkem_kat.h"

#ifdef HOST_DEBUG
#include <stdio.h>
#endif

// mlkem_sw.c - Software ML-KEM-768 (FIPS 203) for the Quarc SoC
//
// Implements the full keygen / encaps / decaps in C for the split architecture
// (Keccak + NTT in fabric, ML-KEM in software). Drives the sha3 coprocessor
// (0x1000_0000, SHA3-256/512 + SHAKE-128/256) and the ntt coprocessor
// (0x1000_0800, NTT/invNTT/basemul) over MMIO. Verifies against the FIPS 203
// KATs embedded in mlkem_kat.h and prints "MLKEM SW OK" / "MLKEM SW FAIL".
//
// The same file compiles for the BeagleV-Fire hard RISC-V cores (RV64GC) by
// overriding the MMIO bases (see BVF_MMIO below) and keeping the algorithm
// unchanged.

#ifdef BVF_MMIO
// BeagleV-Fire cape build: the Quarc crypto fabric lives in the FIC3 APB
// window (sha3 @ 0x4110_0000, ntt @ 0x4110_0800) and is reached from Linux
// through /dev/mem.
#define SHA3_BASE     0x41100000u
#define NTT_BASE      0x41100800u
#else
#define SHA3_BASE     0x10000000u
#define NTT_BASE      0x10000800u
#endif
#define SHA3_CTRL     0x00
#define SHA3_STATUS   0x04
#define SHA3_MODE     0x08
#define SHA3_DATA_IN  0x0C
#define SHA3_DATA_OUT 0x10
#define SHA3_LEN      0x14
#define SHA3_SQ_LEN   0x18

#define NTT_CTRL      0x00
#define NTT_STATUS    0x04
#define NTT_COEFF     0x08

#define UART_BASE     0x20000100u
#define UART_TX_DATA  0x00
#define UART_STATUS   0x04
#define UART_TXBUSY   0x01

#define Q      3329
#define N      256
#define K      3
#define ETA1   2
#define ETA2   2
#define DU     10
#define DV     4

#define SHA3_256_MODE   0
#define SHA3_512_MODE   1
#define SHAKE128_MODE   2
#define SHAKE256_MODE   3

#define NTT_OP_FWD  1
#define NTT_OP_INV  2
#define NTT_OP_MUL  3

typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;

// ---------------------------------------------------------------------------
// MMIO access
// ---------------------------------------------------------------------------
#ifdef BVF_MMIO
// BeagleV-Fire build: 32-bit MMIO through an mmap of /dev/mem. Both fabric
// bases share one 4 KiB page (0x4110_0000), so a single mapping suffices.
// Run as root (sudo) to open /dev/mem. Requires root, so we check at entry.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

static volatile uint8_t *bvf_mem = (volatile uint8_t *)0;
static int               bvf_fd  = -1;

static int bvf_open(void)
{
    uintptr_t page = (uintptr_t)(SHA3_BASE & ~0xFFFu);
    if (bvf_mem) return 0;                    // already mapped
    bvf_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (bvf_fd < 0) return -1;
    bvf_mem = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED,
                   bvf_fd, (off_t)page);
    if (bvf_mem == MAP_FAILED) {
        bvf_mem = (volatile uint8_t *)0;
        close(bvf_fd);
        bvf_fd = -1;
        return -1;
    }
    return 0;
}

static inline void put32(u32 addr, u32 val)
{
    *(volatile u32 *)(bvf_mem + ((uintptr_t)addr - (uintptr_t)(SHA3_BASE & ~0xFFFu))) = val;
}
static inline u32 get32(u32 addr)
{
    return *(volatile u32 *)(bvf_mem + ((uintptr_t)addr - (uintptr_t)(SHA3_BASE & ~0xFFFu)));
}
#elif defined(HOST_TEST)
// Host-side build: the test harness emulates the sha3/ntt/UART peripherals.
extern void host_put32(u32 addr, u32 val);
extern u32  host_get32(u32 addr);
static inline void put32(u32 addr, u32 val) { host_put32(addr, val); }
static inline u32  get32(u32 addr)          { return host_get32(addr); }
#else
static inline void put32(u32 addr, u32 val) { *(volatile u32 *)addr = val; }
static inline u32 get32(u32 addr)           { return *(volatile u32 *)addr; }
#endif

static inline u32 minu(u32 a, u32 b) { return a < b ? a : b; }

// ---------------------------------------------------------------------------
// sha3 coprocessor: absorb a message, squeeze n bytes
// ---------------------------------------------------------------------------
static void sha3_run(u32 mode, const u8 *msg, u32 len, u8 *out, u32 outlen)
{
    u32 i;

    put32(SHA3_BASE + SHA3_MODE, mode);
    put32(SHA3_BASE + SHA3_LEN, len);
    for (i = 0; i < len; i += 4) {
        u32 w = 0;
        u32 n = minu(4, len - i);
        u32 k;
        for (k = 0; k < n; k++) w |= (u32)msg[i + k] << (8 * k);
        put32(SHA3_BASE + SHA3_DATA_IN, w);
    }
    put32(SHA3_BASE + SHA3_CTRL, 1);                       // absorb_start
    while (!(get32(SHA3_BASE + SHA3_STATUS) & 0x02)) ;      // absorb_done

    put32(SHA3_BASE + SHA3_SQ_LEN, outlen);
    put32(SHA3_BASE + SHA3_CTRL, 2);                       // squeeze_start
    while (!(get32(SHA3_BASE + SHA3_STATUS) & 0x04)) ;      // squeeze_done

    for (i = 0; i < outlen; i += 4) {
        u32 w = get32(SHA3_BASE + SHA3_DATA_OUT);
        u32 n = minu(4, outlen - i);
        u32 k;
        for (k = 0; k < n; k++) out[i + k] = (u8)(w >> (8 * k));
    }
}

static void shake128(u8 *out, u32 outlen, const u8 *in, u32 inlen)
{
    sha3_run(SHAKE128_MODE, in, inlen, out, outlen);
}

static void shake256(u8 *out, u32 outlen, const u8 *in, u32 inlen)
{
    sha3_run(SHAKE256_MODE, in, inlen, out, outlen);
}

static void sha3_256(u8 *out, const u8 *in, u32 inlen)
{
    sha3_run(SHA3_256_MODE, in, inlen, out, 32);
}

static void sha3_512(u8 *out, const u8 *in, u32 inlen)
{
    sha3_run(SHA3_512_MODE, in, inlen, out, 64);
}

// ---------------------------------------------------------------------------
// ntt coprocessor
// ---------------------------------------------------------------------------
// ntt_op(op, a, b, out): a,b may be NULL. basemul uses a as A (0..255) and b
// as B (256..511). forward/inverse use a only. Results land back in 0..255.
static void ntt_op(u32 op, const u16 *a, const u16 *b, u16 *out)
{
    int i;

    put32(NTT_BASE + NTT_CTRL, op);                       // set op, reset ptrs
    for (i = 0; i < N; i++) put32(NTT_BASE + NTT_COEFF, a[i]);
    if (op == NTT_OP_MUL) {
        for (i = 0; i < N; i++) put32(NTT_BASE + NTT_COEFF, b[i]);
    }
    put32(NTT_BASE + NTT_CTRL, op | 0x10);                // go
    while (!(get32(NTT_BASE + NTT_STATUS) & 0x02)) ;      // done
    for (i = 0; i < N; i++) out[i] = (u16)(get32(NTT_BASE + NTT_COEFF) & 0xFFF);
}

static void ntt_fwd(const u16 *a, u16 *out)   { ntt_op(NTT_OP_FWD, a, 0, out); }
static void ntt_inv(const u16 *a, u16 *out)   { ntt_op(NTT_OP_INV, a, 0, out); }
static void ntt_mul(const u16 *a, const u16 *b, u16 *out)
{
    ntt_op(NTT_OP_MUL, a, b, out);
}

// ---------------------------------------------------------------------------
// Poly arithmetic (normal domain for add/sub, NTT domain for mult via engine)
// ---------------------------------------------------------------------------
static void poly_addmod(u16 *r, const u16 *a, const u16 *b)
{
    int i;
    for (i = 0; i < N; i++) {
        int t = (int)a[i] + (int)b[i];
        if (t >= Q) t -= Q;
        r[i] = (u16)t;
    }
}

static void poly_submod(u16 *r, const u16 *a, const u16 *b)
{
    int i;
    for (i = 0; i < N; i++) {
        int t = (int)a[i] - (int)b[i];
        if (t < 0) t += Q;
        r[i] = (u16)t;
    }
}

// ---------------------------------------------------------------------------
// Byte encode / decode (bit packing, LSB-first)
// ---------------------------------------------------------------------------
static void byte_encode(u8 *out, u32 outlen, const u16 *coeffs, u32 d)
{
    u32 acc = 0, bits = 0, k = 0;
    u32 ncoeff = (outlen * 8) / d;
    u32 i;
    for (i = 0; i < ncoeff; i++) {
        acc |= (u32)(coeffs[i] & ((1u << d) - 1)) << bits;
        bits += d;
        while (bits >= 8) {
            out[k >> 3] = (u8)(acc & 0xFF);
            acc >>= 8;
            bits -= 8;
            k += 8;
        }
    }
}

static void byte_decode(u16 *coeffs, u32 ncoeff, const u8 *in, u32 d)
{
    u32 acc = 0, bits = 0, k = 0;
    u32 i;
    for (i = 0; i < ncoeff; i++) {
        while (bits < d) {
            acc |= (u32)in[k >> 3] << bits;
            bits += 8;
            k += 8;
        }
        coeffs[i] = (u16)(acc & ((1u << d) - 1));
        acc >>= d;
        bits -= d;
    }
}

// ---------------------------------------------------------------------------
// Compress / decompress (FIPS 203 section 4.2.1)
// ---------------------------------------------------------------------------
static u32 compress(u32 x, u32 d)
{
    return (((x << d) + (Q >> 1)) / Q) & ((1u << d) - 1);
}

static u32 decompress(u32 y, u32 d)
{
    return ((y * Q + (1u << (d - 1))) >> d) % Q;
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------
// SampleNTT(rho, i, j): SHAKE128(rho || j || i), 3-byte rejection, mod q.
// This function computes A[ROW][COL] for arguments (ROW, COL), matching
// FIPS 203: A[i][j] = SampleNTT(rho, i, j).
static void sample_ntt(u16 *out, const u8 *rho, u32 i, u32 j)
{
    u8 buf[768];
    u8 xi[34];
    u32 p, c = 0;

    for (p = 0; p < 32; p++) xi[p] = rho[p];
    xi[32] = (u8)(j & 0xFF);
    xi[33] = (u8)(i & 0xFF);
    shake128(buf, 768, xi, 34);

    for (p = 0; p + 2 < 768 && c < N; p += 3) {
        u32 b0 = buf[p], b1 = buf[p + 1], b2 = buf[p + 2];
        u32 d1 = b0 | ((b1 & 0x0F) << 8);
        u32 d2 = (b1 >> 4) | (b2 << 4);
        if (d1 < Q) out[c++] = (u16)d1;
        if (c < N && d2 < Q) out[c++] = (u16)d2;
    }
}

// SamplePolyCBD(sigma, eta, nonce): SHAKE256(sigma || nonce), 2*eta bits each.
static void sample_cbd(u16 *out, const u8 *sigma, u32 eta, u32 nonce)
{
    u8 buf[128];
    u8 xi[33];
    u32 i;

    for (i = 0; i < 32; i++) xi[i] = sigma[i];
    xi[32] = (u8)(nonce & 0xFF);
    shake256(buf, 64 * eta, xi, 33);

    for (i = 0; i < N; i++) {
        u32 a = 0, b = 0, k;
        u32 x = (u32)buf[(2 * eta * i) >> 3] >> ((2 * eta * i) & 7);
        for (k = 0; k < eta; k++) a += (x >> k) & 1;
        for (k = 0; k < eta; k++) b += (x >> (eta + k)) & 1;
        out[i] = (u16)(((a + Q) - b) % Q);
    }
}

// ---------------------------------------------------------------------------
// K-PKE
// ---------------------------------------------------------------------------
// Encrypt m (32 bytes) under ek_pk using randomness r -> (c1[960], c2[128]).
static void pke_encrypt(u8 *c1, u8 *c2, const u8 *ek_pk, const u8 *m, const u8 *r)
{
    u16 that[K * N], yhat[K * N], e1[K * N], e2[N];
    u16 acc[N], apoly[N], tvec[N];
    u8 mu[960], v[128];
    u8 mbits[32];
    const u8 *rho = ek_pk + K * 384;
    int i, j;

    for (i = 0; i < K; i++)
        byte_decode(that + i * N, N, ek_pk + i * 384, 12);

    for (j = 0; j < K; j++) {
        u16 cbd[N];
        sample_cbd(cbd, r, ETA1, j);
        ntt_fwd(cbd, yhat + j * N);
    }
    for (i = 0; i < K; i++)
        sample_cbd(e1 + i * N, r, ETA2, K + i);
    sample_cbd(e2, r, ETA2, 2 * K);

    // u[i] = e1[i] + sum_j invntt(basemul(A[j][i], yhat[j]))
    for (i = 0; i < K; i++) {
        for (j = 0; j < N; j++) acc[j] = e1[i * N + j];
        for (j = 0; j < K; j++) {
            u16 bm[N];
            sample_ntt(apoly, rho, j, i);           // A^T[i][j] = A[j][i]
            ntt_mul(apoly, yhat + j * N, bm);
            ntt_inv(bm, apoly);
            poly_addmod(acc, acc, apoly);
        }
        for (j = 0; j < N; j++) acc[j] = (u16)compress(acc[j], DU);
        byte_encode(mu + i * 320, 320, acc, DU);
    }

    // tv = sum_j invntt(basemul(that[j], yhat[j]))
    for (j = 0; j < N; j++) tvec[j] = 0;
    for (j = 0; j < K; j++) {
        u16 bm[N];
        ntt_mul(that + j * N, yhat + j * N, bm);
        ntt_inv(bm, apoly);
        poly_addmod(tvec, tvec, apoly);
    }

    byte_decode(acc, N, m, 1);                       // message bits
    for (j = 0; j < N; j++) acc[j] = (u16)decompress(acc[j], 1);   // 0 or (q+1)/2
    poly_addmod(tvec, tvec, acc);
    poly_addmod(tvec, tvec, e2);
    for (j = 0; j < N; j++) tvec[j] = (u16)compress(tvec[j], DV);
    byte_encode(v, 128, tvec, DV);

    for (i = 0; i < 960; i++) c1[i] = mu[i];
    for (i = 0; i < 128; i++) c2[i] = v[i];
}

// Decrypt ciphertext -> 32-byte message using dk_pke (1152 bytes of shat).
static void pke_decrypt(u8 *m, const u8 *dk_pke, const u8 *c)
{
    u16 shat[K * N], u[N], v[N], acc[N], w[N];
    int i, j;

    for (i = 0; i < K; i++)
        byte_decode(shat + i * N, N, dk_pke + i * 384, 12);

    for (j = 0; j < N; j++) acc[j] = 0;
    for (i = 0; i < K; i++) {
        u16 nttu[N], bm[N];
        byte_decode(u, N, c + i * 320, DU);
        for (j = 0; j < N; j++) u[j] = (u16)decompress(u[j], DU);
        ntt_fwd(u, nttu);
        ntt_mul(shat + i * N, nttu, bm);
        ntt_inv(bm, nttu);
        poly_addmod(acc, acc, nttu);
    }
    byte_decode(v, N, c + 960, DV);
    for (j = 0; j < N; j++) v[j] = (u16)decompress(v[j], DV);

    poly_submod(w, v, acc);
    for (j = 0; j < N; j++) w[j] = (u16)compress(w[j], 1);
    byte_encode(m, 32, w, 1);
}

// ---------------------------------------------------------------------------
// ML-KEM-768
// ---------------------------------------------------------------------------
// KeyGen(d, z) -> ek_pk[1184], dk[2400]
static void mlkem_keygen(u8 *ek, u8 *dk, const u8 *d, const u8 *z)
{
    u8 g[64], rho[32], sigma[32];
    u16 shat[K * N], that[K * N], cbd[N], apoly[N], bm[N];
    u8 g_in[33];
    int i, j;

    for (i = 0; i < 32; i++) g_in[i] = d[i];
    g_in[32] = K;                                      // G(d || k), FIPS 203
    sha3_512(g, g_in, 33);
    for (i = 0; i < 32; i++) { rho[i] = g[i]; sigma[i] = g[32 + i]; }

    for (j = 0; j < K; j++) {
        sample_cbd(cbd, sigma, ETA1, j);
        ntt_fwd(cbd, shat + j * N);
    }

    for (i = 0; i < K; i++) {
        for (j = 0; j < N; j++) that[i * N + j] = 0;
        for (j = 0; j < K; j++) {
            sample_ntt(apoly, rho, i, j);              // A[i][j]
            ntt_mul(apoly, shat + j * N, bm);
            poly_addmod(that + i * N, that + i * N, bm);
        }
        // t = e + A*s  (NTT domain). Add NTT(e): ehat[i] = NTT(cbd(sigma, K+i))
        sample_cbd(cbd, sigma, ETA1, K + i);
        ntt_fwd(cbd, apoly);
        poly_addmod(that + i * N, that + i * N, apoly);
    }

    byte_encode(ek, 1152, that, 12);
    for (i = 0; i < 32; i++) ek[1152 + i] = rho[i];

    byte_encode(dk, 1152, shat, 12);
    for (i = 0; i < 1184; i++) dk[1152 + i] = ek[i];
    sha3_256(dk + 2336, ek, 1184);
    for (i = 0; i < 32; i++) dk[2368 + i] = z[i];
}

// Encaps(ek_pk, m) -> ss[32], ct[1088]
static void mlkem_encaps(u8 *ss, u8 *ct, const u8 *ek_pk, const u8 *m)
{
    u8 h[32], g[64], mh[64], r[32];
    int i;

    sha3_256(h, ek_pk, 1184);
    for (i = 0; i < 32; i++) mh[i] = m[i];
    for (i = 0; i < 32; i++) mh[32 + i] = h[i];
    sha3_512(g, mh, 64);
    for (i = 0; i < 32; i++) ss[i] = g[i];
    for (i = 0; i < 32; i++) r[i] = g[32 + i];

    pke_encrypt(ct, ct + 960, ek_pk, m, r);
}

// Decaps(dk, c) -> ss[32]
static void mlkem_decaps(u8 *ss, const u8 *dk, const u8 *c)
{
    const u8 *dk_pke = dk;                  // 1152
    const u8 *ek_pk  = dk + 1152;           // 1184
    const u8 *h      = dk + 2336;           // 32
    const u8 *z      = dk + 2368;           // 32
    u8 m[32], g[64], mh[64], r[32], ct[1088];
    int i;

    pke_decrypt(m, dk_pke, c);
    for (i = 0; i < 32; i++) mh[i] = m[i];
    for (i = 0; i < 32; i++) mh[32 + i] = h[i];
    sha3_512(g, mh, 64);
    for (i = 0; i < 32; i++) r[i] = g[32 + i];

    pke_encrypt(ct, ct + 960, ek_pk, m, r);

    for (i = 0; i < 1088; i++)
        if (ct[i] != c[i]) goto implicit_reject;

    for (i = 0; i < 32; i++) ss[i] = g[i];
    return;

implicit_reject:                                  // J(z || c)
    {
        u8 zc[1120];
        u8 jb[32];
        for (i = 0; i < 32; i++) zc[i] = z[i];
        for (i = 0; i < 1088; i++) zc[32 + i] = c[i];
        shake256(jb, 32, zc, 1120);
        for (i = 0; i < 32; i++) ss[i] = jb[i];
    }
}

// ---------------------------------------------------------------------------
// UART
// ---------------------------------------------------------------------------
#ifdef BVF_MMIO
// Board build: firmware banner goes to the Linux console.
static void uart_putc(u8 ch)
{
    fputc(ch, stdout);
    fflush(stdout);
}
#else
static void uart_putc(u8 ch)
{
    while (get32(UART_BASE + UART_STATUS) & UART_TXBUSY) ;
    put32(UART_BASE + UART_TX_DATA, ch);
}
#endif

static void uart_puts(const char *s)
{
    while (*s) uart_putc((u8)*s++);
}

// ---------------------------------------------------------------------------
// main: self-test against the FIPS 203 KATs
// ---------------------------------------------------------------------------
static u8 kat_d[32], kat_z[32], kat_m[32];
static u8 ek[1184], dk[2400], ct[1088], ss1[32], ss2[32];

static int mem_eq(const u8 *a, const u8 *b, u32 n)
{
    u32 i;
    for (i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

#ifdef HOST_TEST
static int mlkem_self_test(void)
#else
int main(void)
#endif
{
#ifdef BVF_MMIO
    if (bvf_open() != 0) {
        fprintf(stderr, "open /dev/mem failed (run as root)\n");
        return 1;
    }
#endif
    int i;
    u8 fail = 0;

    for (i = 0; i < 32; i++) { kat_d[i] = (u8)i; kat_z[i] = (u8)(32 + i); kat_m[i] = (u8)(64 + i); }

    mlkem_keygen(ek, dk, kat_d, kat_z);
    if (!mem_eq(ek, kat_pk, 1184) || !mem_eq(dk, kat_dk, 2400)) fail = 1;
#ifdef HOST_DEBUG
    {
        int i, ndiff = 0;
        for (i = 0; i < 1184; i++) if (ek[i] != kat_pk[i]) ndiff++;
        printf("keygen pk diff bytes: %d\n", ndiff);
        ndiff = 0;
        for (i = 0; i < 2400; i++) if (dk[i] != kat_dk[i]) ndiff++;
        printf("keygen dk diff bytes: %d\n", ndiff);
    }
#endif

    mlkem_encaps(ss1, ct, ek, kat_m);
    if (!mem_eq(ct, kat_ct, 1088) || !mem_eq(ss1, kat_ss, 32)) fail = 1;
#ifdef HOST_DEBUG
    {
        int i, ndiff = 0;
        for (i = 0; i < 1088; i++) if (ct[i] != kat_ct[i]) ndiff++;
        printf("encaps ct diff bytes: %d\n", ndiff);
        ndiff = 0;
        for (i = 0; i < 32; i++) if (ss1[i] != kat_ss[i]) ndiff++;
        printf("encaps ss diff bytes: %d\n", ndiff);
    }
#endif

    mlkem_decaps(ss2, dk, ct);
    if (!mem_eq(ss2, kat_ss, 32)) fail = 1;

    uart_puts("MLKEM SW ");
    uart_puts(fail ? "FAIL\r\n" : "OK\r\n");
    return fail ? 1 : 0;
}

#ifdef HOST_TEST
// Host test entry point: run the KAT self-test, print per-stage results.
int host_main(void)
{
    int r = mlkem_self_test();
    return r;
}
#endif
