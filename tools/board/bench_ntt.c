/* ntt_sw.c - software ML-KEM NTT reference timing on RV64 */
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define Q 3329
static const int16_t Z[128] = {
    1,    1729, 2580, 3289, 2642, 630,  1897, 848,  1062, 1919, 193,  797,
    2786, 3260, 569,  1746, 296,  2447, 1339, 1476, 3046, 56,   2240, 1333,
    1426, 2094, 535,  2882, 2393, 2879, 1974, 821,  289,  331,  3253, 1756,
    1195, 2304, 2270, 1861, 1522, 2085, 1086, 1007, 2816, 2590, 1222, 2032,
    2016, 266,  1283, 2936, 569,  2738, 1231, 1963, 506,  1559, 571,  2522,
    2595, 3200, 1638, 1000, 678,  1156, 2394, 1539, 292,  530,  2748, 997,
    1625, 2206, 1758, 2239, 2298, 3255, 1758, 2085, 2353, 2770, 2681, 2258,
    1038, 2592, 1811, 1897, 1926, 1477, 1587, 3074, 1761, 1195, 1487, 1737,
    1711, 3225, 2071, 1265, 1235, 2939, 2816, 1330, 2174, 2341, 1132, 2147,
    2600, 2002, 3250, 880,  2257, 2215, 1597, 1983, 3073, 2735, 2360, 1808,
    2455, 2508, 1553, 1388, 2240, 1261, 1685, 1295};

static void ntt(int16_t r[256]) {
  unsigned len = 128;
  int z = 0;
  while (len >= 2) {
    unsigned start = 0;
    while (start < 256) {
      int16_t zeta = Z[z++];
      for (unsigned j = start; j < start + len; j++) {
        int16_t t = ((int32_t)zeta * r[j + len]) % Q;
        r[j + len] = (r[j] - t + Q) % Q;
        r[j] = (r[j] + t) % Q;
      }
      start += 2 * len;
    }
    len >>= 1;
  }
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(void) {
  static int16_t r[256];
  for (int i = 0; i < 256; i++)
    r[i] = i;
  int iters = 2000;
  double t = now_s();
  for (int i = 0; i < iters; i++) {
    for (int j = 0; j < 256; j++)
      r[j] = j;
    ntt(r);
  }
  double dt = (now_s() - t) / iters;
  printf("SW ML-KEM NTT (256 coeffs, C O2): %.1f us/op  (%.0f ops/s)\n",
         dt * 1e6, 1.0 / dt);
  return 0;
}
