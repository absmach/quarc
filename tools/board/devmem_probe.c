// devmem_probe.c - verify /dev/mem access to the PolarFire fabric MMIO window.
//
// mmaps a physical address range (default 0x41000000 = fabric PWM in the
// default BeagleV-Fire image) read-only and prints the first words, proving
// the hard RISC-V cores can see the FPGA fabric before the Quarc partition
// is loaded. Usage: devmem_probe [addr] [count]
//
// Build on the board:  gcc -O2 -o devmem_probe devmem_probe.c
// Run:                 sudo ./devmem_probe 0x41000000 8

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
  uint64_t addr = 0x41000000ULL;
  int count = 8;
  if (argc > 1)
    addr = strtoull(argv[1], NULL, 0);
  if (argc > 2)
    count = atoi(argv[2]);
  if (count < 1)
    count = 1;

  int fd = open("/dev/mem", O_RDONLY | O_SYNC);
  if (fd < 0) {
    perror("open /dev/mem");
    return 1;
  }

  /* page-align the window (PolarFire pages are 4 KiB) */
  uint64_t base = addr & ~0xFFFULL;
  uint64_t len = ((addr - base) + (uint64_t)count * 4 + 0xFFF) & ~0xFFFULL;

  volatile uint8_t *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, (off_t)base);
  if (p == MAP_FAILED) {
    fprintf(stderr, "mmap 0x%" PRIx64 " (len 0x%" PRIx64 "): %s\n", base, len,
            strerror(errno));
    close(fd);
    return 1;
  }

  printf("mapped 0x%" PRIx64 "..0x%" PRIx64 "\n", base, base + len - 1);
  for (int i = 0; i < count; i++) {
    uint32_t v;
    memcpy(&v, (const void *)(p + (addr - base) + (size_t)i * 4), sizeof v);
    printf("  [0x%08" PRIx64 "] = 0x%08x\n", addr + (uint64_t)i * 4, v);
  }

  munmap((void *)p, len);
  close(fd);
  return 0;
}
