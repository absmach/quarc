/* bench.c - BeagleV-Fire CPU + SW SHA3-256 baseline (C) */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef uint64_t u64;
#define ROTL64(x, n) (((x) << (n)) | ((x) >> (64 - (n))))
static const u64 RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
static const int RHO[24] = {1,  3,  6,  10, 15, 21, 28, 36, 45, 55, 2,  14,
                            27, 41, 56, 8,  25, 43, 62, 18, 39, 61, 20, 44};
static const int PI[24] = {10, 7,  11, 17, 18, 3, 5,  16, 8,  21, 24, 4,
                           15, 23, 19, 13, 12, 2, 20, 14, 22, 9,  6,  1};

static void keccakf(u64 s[25]) {
  for (int round = 0; round < 24; round++) {
    u64 bc[5], t;
    for (int i = 0; i < 5; i++)
      bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20];
    for (int i = 0; i < 5; i++) {
      t = bc[(i + 4) % 5] ^ ROTL64(bc[(i + 1) % 5], 1);
      for (int j = 0; j < 25; j += 5)
        s[j + i] ^= t;
    }
    t = s[1];
    for (int i = 0; i < 24; i++) {
      int j = PI[i];
      bc[0] = s[j];
      s[j] = ROTL64(t, RHO[i]);
      t = bc[0];
    }
    for (int j = 0; j < 25; j += 5) {
      u64 t0 = s[j], t1 = s[j + 1], t2 = s[j + 2], t3 = s[j + 3], t4 = s[j + 4];
      s[j] = t0 ^ ((~t1) & t2);
      s[j + 1] = t1 ^ ((~t2) & t3);
      s[j + 2] = t2 ^ ((~t3) & t4);
      s[j + 3] = t3 ^ ((~t4) & t0);
      s[j + 4] = t4 ^ ((~t0) & t1);
    }
    s[0] ^= RC[round];
  }
}

static void sha3_256(const uint8_t *in, size_t len, uint8_t *out) {
  u64 s[25] = {0};
  size_t rate = 136, i, j;
  for (i = 0; i + rate <= len; i += rate) {
    for (j = 0; j < rate / 8; j++)
      s[j] ^= ((const u64 *)(in + i))[j];
    keccakf(s);
  }
  uint8_t buf[200];
  memset(buf, 0, rate);
  memcpy(buf, in + i, len - i);
  buf[len - i] ^= 0x06;
  buf[rate - 1] ^= 0x80;
  for (j = 0; j < rate / 8; j++)
    s[j] ^= ((const u64 *)buf)[j];
  keccakf(s);
  memcpy(out, s, 32);
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(void) {
  static uint8_t msg[4096], h[32];
  for (int i = 0; i < 4096; i++)
    msg[i] = (uint8_t)i;
  /* self-check: SHA3-256("") */
  sha3_256((uint8_t *)"", 0, h);
  printf("sha3-256(\"\") = ");
  for (int i = 0; i < 16; i++)
    printf("%02x", h[i]);
  printf("  (expect a7ffc6f8bf1ed76651c14756a061d662)\n");
  printf("sha3-256(\"abc\") = ");
  sha3_256((uint8_t *)"abc", 3, h);
  for (int i = 0; i < 16; i++)
    printf("%02x", h[i]);
  printf("  (expect 3a985da74fe225b2045c172d6bd390bd)\n");

  printf("\n=== C software SHA3-256 on BeagleV-Fire RV64 (O2) ===\n");
  for (size_t sz = 64; sz <= 4096; sz *= 4) {
    int iters = sz <= 256 ? 20000 : (sz <= 1024 ? 5000 : 1000);
    double t = now_s();
    for (int i = 0; i < iters; i++)
      sha3_256(msg, sz, h);
    double dt = (now_s() - t) / iters;
    printf("  %5zu B: %9.2f us/op  %7.2f MB/s\n", sz, dt * 1e6, sz / dt / 1e6);
  }
  return 0;
}
