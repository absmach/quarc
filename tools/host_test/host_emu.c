// host_emu.c - Host emulation of the Quarc sha3 / ntt coprocessors + UART.
//
// Compiles together with fw/mlkem_sw.c (with -DHOST_TEST) to run the exact
// SoC firmware driver against software models of the fabric peripherals.
// This is how the full ML-KEM-768 KAT self-test runs on the BeagleV-Fire's
// hard RISC-V cores (or any Linux host) before the sha3/ntt fabric has been
// placed in the PolarFire.
//
// The models are behavioral, not cycle-accurate, but they reproduce the MMIO
// register protocol and the byte order of the RTL exactly:
//   - sha3:   standard Keccak sponge; absorb bytes LSB-first per 32-bit word,
//             pad byte (0x06 SHA3 / 0x1F SHAKE) at gpos==len, 0x80 on the last
//             byte of the final block; squeeze reads the state directly and
//             permutes only on rate boundaries (see rtl/sha3.v).
//   - ntt:    plain arithmetic NTT / invNTT / basemul over q=3329 with
//             zetas[i] = 17^bitrev7(i) mod q, inverse scaled by 128^-1
//             (see scripts/gen_ntt_kat.py, which also generates rtl/ntt_zetas.vh).
//   - uart:   TX byte writes are forwarded to stdout so the firmware's
//             "MLKEM SW OK"/"FAIL" line is visible on the console.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t  u8;

#define SHA3_BASE  0x10000000u
#define NTT_BASE   0x10000800u
#define UART_BASE  0x20000100u

#define Q       3329
#define N       256

#define SHA3_256_MODE  0
#define SHA3_512_MODE  1
#define SHAKE128_MODE  2
#define SHAKE256_MODE  3

#define NTT_OP_FWD  1
#define NTT_OP_INV  2
#define NTT_OP_MUL  3

// ---------------------------------------------------------------------------
// Keccak-f[1600]
// ---------------------------------------------------------------------------
#define ROL64(a, o) (((a) << (o)) | ((a) >> (64 - (o))))

static const uint64_t keccak_rndc[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

static const unsigned keccak_rotc[24] = {
    1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
    27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
};

static const unsigned keccak_piln[24] = {
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
};

static void keccak_f(uint64_t st[25])
{
    unsigned round, i, j;

    for (round = 0; round < 24; round++) {
        uint64_t bc[5];
        uint64_t t;

        for (i = 0; i < 5; i++)
            bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
        for (i = 0; i < 5; i++) {
            t = bc[(i + 4) % 5] ^ ROL64(bc[(i + 1) % 5], 1);
            for (j = 0; j < 25; j += 5)
                st[j + i] ^= t;
        }

        t = st[1];
        for (i = 0; i < 24; i++) {
            j = keccak_piln[i];
            bc[0] = st[j];
            st[j] = ROL64(t, keccak_rotc[i]);
            t = bc[0];
        }

        for (j = 0; j < 25; j += 5) {
            t = st[j];
            bc[0] = st[j + 1];
            bc[1] = st[j + 2];
            bc[2] = st[j + 3];
            bc[3] = st[j + 4];
            st[j]     = t      ^ ((~bc[0]) & bc[1]);
            st[j + 1] = bc[0]  ^ ((~bc[1]) & bc[2]);
            st[j + 2] = bc[1]  ^ ((~bc[2]) & bc[3]);
            st[j + 3] = bc[2]  ^ ((~bc[3]) & t);
            st[j + 4] = bc[3]  ^ ((~t) & bc[0]);
        }

        st[0] ^= keccak_rndc[round];
    }
}

// ---------------------------------------------------------------------------
// sha3 sponge model
// ---------------------------------------------------------------------------
static struct {
    u8    mode;
    u32   len;
    u8    msg[2048];
    u32   nmsg;
    u32   sqlen;
    uint64_t st[25];
    u8    out[8192];
    u32   outpos;
    int   absorb_done;
    int   squeeze_done;
} sha3;

static size_t s_rate(void)
{
    return (sha3.mode == SHA3_512_MODE) ? 72 :
           (sha3.mode == SHAKE128_MODE) ? 168 : 136;
}

static u8 s_pad(void)
{
    return (sha3.mode == SHAKE128_MODE || sha3.mode == SHAKE256_MODE) ? 0x1F : 0x06;
}

static void s_absorb(void)
{
    size_t rate = s_rate();
    size_t nblocks = sha3.len / rate + 1;
    size_t b;

    memset(sha3.st, 0, sizeof(sha3.st));
    for (b = 0; b < nblocks; b++) {
        size_t off = b * rate;
        size_t k;
        for (k = 0; k < rate; k++) {
            size_t g = off + k;
            u8 byte = 0;

            if (g < sha3.len)
                byte = sha3.msg[g];
            else if (g == sha3.len)
                byte = s_pad();
            if (b == nblocks - 1 && k == rate - 1)
                byte |= 0x80;
            if (byte)
                sha3.st[k >> 3] ^= (uint64_t)byte << (8 * (k & 7));
        }
        keccak_f(sha3.st);
    }
}

static void s_squeeze(void)
{
    uint64_t st[25];
    size_t i, rate = s_rate();

    memcpy(st, sha3.st, sizeof(st));
    for (i = 0; i < sha3.sqlen; i++) {
        if (i && (i % rate) == 0)
            keccak_f(st);
        sha3.out[i] = (u8)(st[(i % rate) >> 3] >> (8 * ((i % rate) & 7)));
    }
}

// ---------------------------------------------------------------------------
// ntt model
// ---------------------------------------------------------------------------
static u16 zetas[128];
static u16 ram[512];

static int ntt_op;
static int ntt_wr_ptr;
static int ntt_rd_ptr;
static int ntt_done;

static u16 powq(int b, int e)
{
    u32 r = 1;
    u32 x = (u32)(b % Q);
    while (e) {
        if (e & 1)
            r = (r * x) % Q;
        x = (x * x) % Q;
        e >>= 1;
    }
    return (u16)r;
}

static u16 modq(int v)
{
    v %= Q;
    if (v < 0)
        v += Q;
    return (u16)v;
}

void zeta_init(void)
{
    int i;
    for (i = 0; i < 128; i++) {
        int r = 0, x = i, k;
        for (k = 0; k < 7; k++) {
            r = (r << 1) | (x & 1);
            x >>= 1;
        }
        zetas[i] = powq(17, r);
    }
}

static void ntt_fwd_c(u16 *f)
{
    int k = 1, len = 128;
    while (len >= 2) {
        int start;
        for (start = 0; start < N; start += 2 * len) {
            u16 z = zetas[k++];
            int j;
            for (j = start; j < start + len; j++) {
                int t = (int)(((u32)z * f[j + len]) % Q);
                f[j + len] = modq((int)f[j] - t);
                f[j]       = modq((int)f[j] + t);
            }
        }
        len >>= 1;
    }
}

static void ntt_inv_c(u16 *f)
{
    int k = 127, len = 2;
    while (len <= 128) {
        int start;
        for (start = 0; start < N; start += 2 * len) {
            u16 z = zetas[k--];
            int j;
            for (j = start; j < start + len; j++) {
                int t = f[j];
                int dt = (int)f[j + len] - t;
                f[j]       = modq((int)f[j] + (int)f[j + len]);
                dt %= Q;
                if (dt < 0)
                    dt += Q;
                f[j + len] = modq((int)(((u32)z * (u32)dt) % Q));
            }
        }
        len <<= 1;
    }
    for (k = 0; k < N; k++)
        f[k] = modq((int)(((u32)f[k] * powq(N / 2, Q - 2)) % Q));
}

static void ntt_basemul_c(u16 *f, const u16 *a, const u16 *b)
{
    int p;

    for (p = 0; p < 128; p++) {
        u16 a0 = a[2 * p], a1 = a[2 * p + 1];
        u16 b0 = b[2 * p], b1 = b[2 * p + 1];
        u16 z  = zetas[64 + (p >> 1)];

        if (p & 1)
            z = (u16)(Q - z);
        f[2 * p]     = modq(a0 * b0 + (int)(((uint64_t)a1 * b1 * z) % Q));
        f[2 * p + 1] = modq(a0 * b1 + a1 * b0);
    }
}

static void ntt_go(void)
{
    u16 work[N];

    memcpy(work, ram, sizeof(work));
    switch (ntt_op) {
        case NTT_OP_FWD: ntt_fwd_c(work); break;
        case NTT_OP_INV: ntt_inv_c(work); break;
        case NTT_OP_MUL:
            ntt_basemul_c(work, work, &ram[N]);
            break;
        default: break;
    }
    memcpy(&ram[0], work, N * sizeof(u16));
}

// ---------------------------------------------------------------------------
// MMIO
// ---------------------------------------------------------------------------
void host_put32(u32 addr, u32 val)
{
    if (addr >= SHA3_BASE && addr < NTT_BASE) {
        switch (addr & 0xFF) {
            case 0x00:                          // CTRL
                if (val & 1) {                  // absorb_start
                    sha3.absorb_done  = 0;
                    sha3.squeeze_done = 0;
                    s_absorb();
                    sha3.absorb_done  = 1;
                }
                if (val & 2) {                  // squeeze_start
                    if (!sha3.absorb_done) {
                        /* RTL raises error; ignore for KAT */
                    } else {
                        sha3.outpos      = 0;
                        s_squeeze();
                        sha3.squeeze_done = 1;
                    }
                }
                if (val & 4)                    // soft_reset
                    memset(&sha3, 0, sizeof(sha3));
                break;
            case 0x08: sha3.mode = val & 3; break;
            case 0x0C: {                        // DATA_IN (LSB-first words)
                int k;
                for (k = 0; k < 4 && sha3.nmsg < sha3.len; k++)
                    sha3.msg[sha3.nmsg++] = (u8)(val >> (8 * k));
                break;
            }
            case 0x14: sha3.len = val; sha3.nmsg = 0; break;
            case 0x18: sha3.sqlen = val; break;
            default: break;
        }
        return;
    }

    if (addr >= NTT_BASE && addr < UART_BASE) {
        switch (addr & 0xFF) {
            case 0x00:                          // CTRL
                ntt_op    = val & 7;
                ntt_wr_ptr = 0;
                ntt_rd_ptr = 0;
                if (val & 0x10) {               // go
                    ntt_done = 0;
                    ntt_go();
                    ntt_done = 1;
                }
                break;
            case 0x08:                          // COEFF
                ram[ntt_wr_ptr] = (u16)(val & 0xFFF);
                ntt_wr_ptr = (ntt_wr_ptr + 1) & 511;
                break;
            default: break;
        }
        return;
    }

    if (addr == UART_BASE) {                    // UART TX
        putchar((int)(val & 0xFF));
        if ((char)(val & 0xFF) == '\n')
            fflush(stdout);
        return;
    }
}

u32 host_get32(u32 addr)
{
    if (addr >= SHA3_BASE && addr < NTT_BASE) {
        switch (addr & 0xFF) {
            case 0x04:                          // STATUS
                return 1u
                     | (sha3.absorb_done  ? 0x02u : 0u)
                     | (sha3.squeeze_done ? 0x04u : 0u);
            case 0x10: {                        // DATA_OUT (LSB-first words)
                u32 w = 0;
                int k;
                for (k = 0; k < 4; k++) {
                    u32 b = (sha3.outpos < sha3.sqlen) ? sha3.out[sha3.outpos] : 0;
                    w |= b << (8 * k);
                    sha3.outpos++;
                }
                return w;
            }
            default: return 0;
        }
    }

    if (addr >= NTT_BASE && addr < UART_BASE) {
        switch (addr & 0xFF) {
            case 0x04:                          // STATUS
                return ntt_done ? 0x02u : 0x00u;
            case 0x08: {                        // COEFF (auto-advance read)
                u32 v = (u32)(ram[ntt_rd_ptr] & 0xFFF);
                ntt_rd_ptr = (ntt_rd_ptr + 1) & 511;
                return v;
            }
            default: return 0;
        }
    }

    if (addr == UART_BASE + 0x04)               // UART STATUS (not busy)
        return 0;
    return 0;
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------
int host_main(void);

#ifndef HOST_NO_MAIN
int main(void)
{
    int r;

    zeta_init();
    r = host_main();
    printf("HOST KAT: %s\n", r ? "FAIL" : "PASS");
    return r;
}
#endif
