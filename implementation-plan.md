# Quarc — Implementation Plan v1.0

## For Automated Coding Agent Execution

### PROPRIETARY & CONFIDENTIAL

---

## How to Use This Document

This document is the single source of truth for implementing Quarc v1. Each task is:

- **Self-contained** — has all information needed to implement it
- **Ordered** — must be completed in the sequence given; later tasks depend on earlier ones
- **Verifiable** — has exact acceptance criteria the agent can test autonomously
- **Atomic** — one task = one logical unit of work

**Rules for the agent:**

1. Never start Task N+1 until Task N passes all acceptance criteria
2. Never skip acceptance criteria — they exist to catch integration bugs early
3. If a task is ambiguous, refer to the PRD (Quarc_PRD_v1.1.md) for the authoritative definition
4. All RTL files are Verilog 2005 — no SystemVerilog constructs in any file under `rtl/`
5. Ibex is the only exception — it lives under `ibex/` and is converted by sv2v, never edited

---

## Repository Structure

Create this directory layout before starting any task:

```
quarc/
├── Makefile
├── README.md
├── boards/
│   └── ulx3s.lpf              # Pin constraint file for ULX3S ECP5-85K
├── ibex/                      # Git submodule — do not edit
│   └── rtl/                   # Ibex SystemVerilog sources
├── rtl/                       # ALL Quarc RTL — Verilog 2005 only
│   ├── top.v                  # SoC top-level
│   ├── bus.v                  # Wishbone-lite bus + address decoder
│   ├── boot_rom.v             # Immutable boot ROM
│   ├── keccak.v               # Keccak-f[1600] permutation
│   ├── sha3.v                 # SHA3/SHAKE wrapper
│   ├── ntt.v                  # Shared NTT/iNTT engine
│   ├── mlkem.v                # ML-KEM-768 controller
│   ├── mldsa.v                # ML-DSA-65 controller
│   ├── trng.v                 # True random number generator
│   ├── drbg.v                 # SHAKE-256 DRBG
│   ├── kue.v                  # Key Usage Enforcer
│   ├── keystore.v             # Key store controller
│   ├── lifecycle.v            # Lifecycle state machine
│   ├── rollback.v             # Anti-rollback counter
│   ├── spi_slave.v            # SPI slave interface
│   ├── uart.v                 # UART debug (disabled in production)
│   └── timer.v                # Timer + watchdog
├── tb/                        # Testbenches — SystemVerilog allowed here
│   ├── tb_keccak.sv
│   ├── tb_ntt.sv
│   ├── tb_mlkem.sv
│   ├── tb_mldsa.sv
│   ├── tb_trng.sv
│   ├── tb_drbg.sv
│   ├── tb_kue.sv
│   ├── tb_bus.sv
│   ├── tb_lifecycle.sv
│   ├── tb_spi.sv
│   └── tb_top.sv
├── formal/                    # SymbiYosys formal verification
│   ├── bus_decoder.sby
│   ├── keccak.sby
│   ├── trng_health.sby
│   ├── pmp_config.sby
│   ├── kue_policy.sby
│   └── lifecycle_fsm.sby
├── fw/                        # Firmware — bare metal C
│   ├── Makefile
│   ├── link.ld                # Linker script
│   ├── startup.S              # Reset vector, stack setup
│   ├── main.c
│   ├── cmd.c / cmd.h          # SPI command dispatcher
│   ├── kue.c / kue.h          # KUE driver
│   ├── crypto.c / crypto.h    # Accelerator drivers
│   ├── lifecycle.c            # Lifecycle state management
│   ├── noise.c / noise.h      # Noise Protocol IK implementation
│   ├── aes_gcm.c              # AES-256-GCM (software, for channel)
│   └── hal.h                  # Hardware register map
├── kat/                       # NIST Known Answer Test vectors
│   ├── sha3/
│   ├── mlkem768/
│   ├── mldsa65/
│   ├── aes_gcm/
│   └── drbg/
├── scripts/
│   ├── run_kat.py             # KAT runner script
│   ├── run_sp80022.py         # NIST SP 800-22 statistical tests
│   └── gen_fw_header.py       # Generate signed firmware header
└── build/                     # Generated — gitignored
    ├── ibex.v                 # sv2v output
    ├── quarc.json             # Yosys output
    ├── quarc.config           # nextpnr output
    └── quarc.bit              # Final bitstream
```

---

## Memory Map

This is fixed for all phases. Every module must use these base addresses exactly.

```
Address Range          Size    Module                  Notes
--------------------   ------  ----------------------  ---------------------------
0x0000_0000            16KB    Boot ROM                R-X, locked by PMP Region 0
0x0000_4000            64KB    Firmware IRAM           R-X, locked by PMP Region 1
0x0001_4000            16KB    Data RAM                RW,  locked by PMP Region 2
0x0002_0000            4KB     Key store               BLOCKED, PMP Region 3
0x1000_0000            256B    Keccak/SHAKE MMIO       PMP Region 4
0x1000_0100            256B    NTT MMIO                PMP Region 4
0x1000_0200            256B    ML-KEM MMIO             PMP Region 4
0x1000_0300            256B    ML-DSA MMIO             PMP Region 4
0x1000_0400            256B    KUE MMIO                PMP Region 4
0x1000_0500            256B    TRNG / DRBG MMIO        PMP Region 4
0x2000_0000            256B    SPI slave MMIO          PMP Region 5
0x2000_0100            256B    UART MMIO               PMP Region 5
0x2000_0200            256B    Timer / WDT MMIO        PMP Region 5
0x3000_0000            32B     Lifecycle register      PMP Region 6
0x3000_0100            32B     Rollback counter        PMP Region 7 (R only)
```

---

## Register Maps

### Keccak Engine (base: 0x1000_0000)

```
Offset  Name          RW   Description
0x00    CTRL          WO   [0]=absorb_start [1]=squeeze_start [2]=reset
0x04    STATUS        RO   [0]=ready [1]=absorb_done [2]=squeeze_done [3]=error
0x08    MODE          WO   [2:0] 0=SHA3-256 1=SHA3-512 2=SHAKE-128 3=SHAKE-256
0x0C    DATA_IN       WO   Write 32-bit word to absorb buffer (burst)
0x10    DATA_OUT      RO   Read 32-bit word from squeeze output (burst)
0x14    LEN           WO   Absorb byte count
0x18    SQUEEZE_LEN   WO   Number of output bytes requested
0x1C    IRQ_EN        WO   [0]=absorb_done_irq [1]=squeeze_done_irq
```

### NTT Engine (base: 0x1000_0100)

```
Offset  Name          RW   Description
0x00    CTRL          WO   [0]=start [1]=inverse [2]=zeroize [3]=reset
0x04    STATUS        RO   [0]=ready [1]=done [2]=zeroized [3]=error
0x08    MODULUS       WO   [1:0] 0=q3329 1=q8380417
0x0C    ADDR_IN       WO   BRAM start address for input polynomial
0x10    ADDR_OUT      WO   BRAM start address for output polynomial
0x14    IRQ_EN        WO   [0]=done_irq [1]=zeroized_irq
0x18    COEFF_WR      WO   Write coefficient to scratchpad (addr auto-increment)
0x1C    COEFF_RD      RO   Read coefficient from scratchpad (addr auto-increment)
0x20    COEFF_ADDR    WO   Set scratchpad address for read/write
```

### KUE (base: 0x1000_0400)

```
Offset  Name          RW   Description
0x00    CMD           WO   [7:4]=slot [3:0]=op (0=sign 1=decap 2=keygen 3=store 4=erase)
0x04    STATUS        RO   [0]=ready [1]=done [2]=policy_err [3]=limit_err [4]=busy
0x08    HASH_PTR      WO   DRAM address of message hash (for SIGN op)
0x0C    CT_PTR        WO   DRAM address of ciphertext (for DECAP op)
0x10    OUT_PTR       WO   DRAM address for output (signature or shared secret)
0x14    SLOT_POLICY   RO   Policy flags for selected slot [see bit definitions below]
0x18    SLOT_COUNT    RO   Use counter for selected slot
0x1C    IRQ_EN        WO   [0]=done_irq [1]=error_irq

Policy flags (SLOT_POLICY register):
  [0]  SIGN_ONLY      Key usable for ML-DSA sign only
  [1]  DECAP_ONLY     Key usable for ML-KEM decap only
  [2]  NO_EXPORT      Key bytes never leave key store
  [3]  NO_OVERWRITE   Slot cannot be overwritten
  [15:0] (upper)  COUNTER_LIMIT value
```

### Lifecycle (base: 0x3000_0000)

```
Offset  Name          RW   Description
0x00    STATE         RO   [1:0] 0=MANUFACTURING 1=PROVISIONED 2=LOCKED 3=RMA
0x04    TRANSITION    WO   Write target state — accepted only if valid transition
0x08    NONCE         WO   32-bit nonce required for LOCKED→RMA transition
0x0C    STATUS        RO   [0]=transition_ok [1]=transition_err
```

### Rollback Counter (base: 0x3000_0100)

```
Offset  Name          RW   Description
0x00    COUNTER       RO   Current rollback counter value (32-bit, monotonic)
0x04    FW_VERSION    RO   Version of currently running firmware (set by Boot ROM)
```

---

## Phase 0 — Repository and Build Foundation

**Goal:** Ibex boots on ULX3S, UART prints "QUARC v0", bitstream programs cleanly.

### Task 0.1 — Repository Initialisation

Create the full directory structure above. Add Ibex as a git submodule:

```bash
git init quarc
cd quarc
git submodule add https://github.com/lowrisc/ibex ibex
```

Create `.gitignore`:

```
build/
*.vvp
*.vcd
*.fst
*.bit
*.config
*.json
fw/*.elf
fw/*.bin
fw/*.hex
```

**Acceptance:** `git submodule status` shows ibex at a known commit. All directories exist.

---

### Task 0.2 — Makefile

Create `Makefile` with exactly these targets. No other build system.

```makefile
IBEX_SV    := $(wildcard ibex/rtl/*.sv)
IBEX_V     := build/ibex.v
QUARC_SRCS := rtl/top.v rtl/bus.v rtl/boot_rom.v rtl/keccak.v rtl/sha3.v \
              rtl/ntt.v rtl/mlkem.v rtl/mldsa.v rtl/trng.v rtl/drbg.v \
              rtl/kue.v rtl/keystore.v rtl/lifecycle.v rtl/rollback.v \
              rtl/spi_slave.v rtl/uart.v rtl/timer.v
ALL_SRCS   := $(IBEX_V) $(QUARC_SRCS)
TB_SRCS    := $(wildcard tb/*.sv)

.PHONY: all sim synth pnr bitstream prog formal clean

all: bitstream

$(IBEX_V): $(IBEX_SV)
	mkdir -p build
	sv2v $(IBEX_SV) -w $(IBEX_V)

sim: $(IBEX_V)
	iverilog -g2012 -o build/sim.vvp $(ALL_SRCS) $(TB_SRCS) -s tb_top
	vvp build/sim.vvp

sim-%: $(IBEX_V)
	iverilog -g2012 -o build/sim_$*.vvp $(IBEX_V) rtl/$*.v tb/tb_$*.sv -s tb_$*
	vvp build/sim_$*.vvp

synth: $(IBEX_V)
	yosys -p "read_verilog $(ALL_SRCS); synth_ecp5 -abc9 -top quarc_top -json build/quarc.json" 2>&1 | tee build/synth.log
	@grep -E "Number of cells|LUT4|TRELLIS_FF|EBR" build/synth.log

pnr: synth
	nextpnr-ecp5 --85k --package CABGA381 --json build/quarc.json \
	             --lpf boards/ulx3s.lpf --textcfg build/quarc.config \
	             --freq 50 --timing-allow-fail 2>&1 | tee build/pnr.log
	@grep -E "Max frequency|critical path" build/pnr.log

bitstream: pnr
	ecppack --svf build/quarc.svf build/quarc.config build/quarc.bit

prog: build/quarc.bit
	openFPGALoader -b ulx3s build/quarc.bit

formal:
	sby -f formal/bus_decoder.sby
	sby -f formal/keccak.sby
	sby -f formal/trng_health.sby
	sby -f formal/pmp_config.sby
	sby -f formal/kue_policy.sby
	sby -f formal/lifecycle_fsm.sby

formal-%:
	sby -f formal/$*.sby

kat:
	python3 scripts/run_kat.py

clean:
	rm -rf build/
```

**Acceptance:** `make clean && make -n all` prints the expected command sequence without errors.

---

### Task 0.3 — ULX3S Pin Constraint File

Create `boards/ulx3s.lpf` with these minimum required constraints:

```
LOCATE COMP "clk_25mhz"    SITE "G2";
IOBUF PORT "clk_25mhz"     IO_TYPE=LVCMOS33;
FREQUENCY PORT "clk_25mhz" 25 MHZ;

# UART via FTDI
LOCATE COMP "uart_tx"      SITE "L4";
LOCATE COMP "uart_rx"      SITE "M1";
IOBUF PORT "uart_tx"       IO_TYPE=LVCMOS33;
IOBUF PORT "uart_rx"       IO_TYPE=LVCMOS33;

# SPI to host (PMOD connector GP0)
LOCATE COMP "spi_sck"      SITE "B11";
LOCATE COMP "spi_mosi"     SITE "C11";
LOCATE COMP "spi_miso"     SITE "A10";
LOCATE COMP "spi_cs_n"     SITE "A9";
IOBUF PORT "spi_sck"       IO_TYPE=LVCMOS33;
IOBUF PORT "spi_mosi"      IO_TYPE=LVCMOS33;
IOBUF PORT "spi_miso"      IO_TYPE=LVCMOS33;
IOBUF PORT "spi_cs_n"      IO_TYPE=LVCMOS33;

# Status LEDs
LOCATE COMP "led[0]"       SITE "B2";
LOCATE COMP "led[1]"       SITE "C2";
LOCATE COMP "led[2]"       SITE "C1";
IOBUF PORT "led[0]"        IO_TYPE=LVCMOS25;
IOBUF PORT "led[1]"        IO_TYPE=LVCMOS25;
IOBUF PORT "led[2]"        IO_TYPE=LVCMOS25;
```

---

### Task 0.4 — SoC Top-Level Stub

Create `rtl/top.v` — this is the SoC top-level. It wires everything together. In Phase 0, only Ibex, UART, timer, and a stub bus need to be functional. Other modules are instantiated as empty stubs.

```verilog
// quarc_top.v — Quarc SoC top-level
// Instantiates Ibex and all peripherals. Wires system bus.
// Phase 0: Ibex + UART + timer only. All other modules are stubs.

`default_nettype none
`timescale 1ns/1ps

module quarc_top (
    input  wire clk_25mhz,
    input  wire uart_rx,
    output wire uart_tx,
    input  wire spi_sck,
    input  wire spi_mosi,
    output wire spi_miso,
    input  wire spi_cs_n,
    output wire [2:0] led
);

    // ── Clock and reset ────────────────────────────────────────────────────
    wire clk, rst_n;
    // Phase 0: use 25 MHz directly. Phase 1+: add PLL for 50 MHz.
    assign clk  = clk_25mhz;
    assign rst_n = 1'b1; // TODO: add power-on reset logic

    // ── Ibex instruction bus ───────────────────────────────────────────────
    wire        instr_req;
    wire [31:0] instr_addr;
    wire        instr_gnt;
    wire        instr_rvalid;
    wire [31:0] instr_rdata;

    // ── Ibex data bus (→ system bus) ───────────────────────────────────────
    wire        data_req;
    wire        data_we;
    wire [3:0]  data_be;
    wire [31:0] data_addr;
    wire [31:0] data_wdata;
    wire        data_gnt;
    wire        data_rvalid;
    wire [31:0] data_rdata;
    wire        data_err;

    // ── Ibex interrupts ────────────────────────────────────────────────────
    wire        irq_timer;
    wire        irq_external;

    // ── Ibex PMP interface (configured via CSRs internally) ────────────────
    // PMP is configured by firmware via CSR writes — no extra wiring needed

    ibex_top u_ibex (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        .test_en_i       (1'b0),
        .scan_rst_ni     (1'b1),
        .ram_cfg_i       ('0),
        .hart_id_i       (32'h0),
        .boot_addr_i     (32'h0000_0000), // Boot from ROM at 0x0
        .instr_req_o     (instr_req),
        .instr_gnt_i     (instr_gnt),
        .instr_rvalid_i  (instr_rvalid),
        .instr_addr_o    (instr_addr),
        .instr_rdata_i   (instr_rdata),
        .instr_rdata_intg_i ('0),
        .instr_err_i     (1'b0),
        .data_req_o      (data_req),
        .data_gnt_i      (data_gnt),
        .data_rvalid_i   (data_rvalid),
        .data_we_o       (data_we),
        .data_be_o       (data_be),
        .data_addr_o     (data_addr),
        .data_wdata_o    (data_wdata),
        .data_wdata_intg_o(),
        .data_rdata_i    (data_rdata),
        .data_rdata_intg_i('0),
        .data_err_i      (data_err),
        .irq_software_i  (1'b0),
        .irq_timer_i     (irq_timer),
        .irq_external_i  (irq_external),
        .irq_fast_i      (15'b0),
        .irq_nm_i        (1'b0),
        .debug_req_i     (1'b0),
        .crash_dump_o    (),
        .double_fault_seen_o(),
        .fetch_enable_i  (4'b0101),
        .alert_minor_o   (),
        .alert_major_internal_o(),
        .alert_major_bus_o(),
        .core_sleep_o    ()
    );

    // ── System bus + all peripheral instantiations ─────────────────────────
    // (bus.v instantiates and wires all peripherals)
    quarc_bus u_bus (
        .clk         (clk),
        .rst_n       (rst_n),
        // Ibex instruction port
        .instr_req   (instr_req),
        .instr_addr  (instr_addr),
        .instr_gnt   (instr_gnt),
        .instr_rvalid(instr_rvalid),
        .instr_rdata (instr_rdata),
        // Ibex data port
        .data_req    (data_req),
        .data_we     (data_we),
        .data_be     (data_be),
        .data_addr   (data_addr),
        .data_wdata  (data_wdata),
        .data_gnt    (data_gnt),
        .data_rvalid (data_rvalid),
        .data_rdata  (data_rdata),
        .data_err    (data_err),
        // Interrupts back to Ibex
        .irq_timer   (irq_timer),
        .irq_external(irq_external),
        // External pins
        .uart_tx     (uart_tx),
        .uart_rx     (uart_rx),
        .spi_sck     (spi_sck),
        .spi_mosi    (spi_mosi),
        .spi_miso    (spi_miso),
        .spi_cs_n    (spi_cs_n),
        .led         (led)
    );

endmodule
`default_nettype wire
```

---

### Task 0.5 — Bus Stub

Create `rtl/bus.v` as a minimal stub that routes instruction fetches to Boot ROM and data accesses to UART and timer. Other peripherals return 0. This grows in each phase.

The bus module must:

- Route `instr_addr[31:16] == 16'h0000` → Boot ROM
- Route `instr_addr[31:16] == 16'h0001` → IRAM
- Route `data_addr[31:24] == 8'h20` → UART/Timer/Periph
- Return `data_err = 1` for all other addresses
- Implement single-cycle `gnt` and one-cycle-later `rvalid`

---

### Task 0.6 — UART Module

Create `rtl/uart.v` — 8N1 UART transmitter and receiver.

```verilog
// uart.v — 8N1 UART
// Base address: 0x2000_0100
// Registers:
//   0x00  TX_DATA  WO  write byte to transmit
//   0x04  STATUS   RO  [0]=tx_busy [1]=rx_ready [2]=rx_overflow
//   0x08  RX_DATA  RO  read received byte (clears rx_ready)
//   0x0C  BAUD_DIV WO  baud rate divisor (clk_freq / baud_rate)
//                      default: 25000000/115200 = 217
```

Parameters:

- `CLK_FREQ` — default 25000000
- `BAUD_RATE` — default 115200

**Acceptance:**

```bash
make sim-uart
# Simulation must transmit "QUARC" and show correct waveform in GTKWave
```

---

### Task 0.7 — Timer Module

Create `rtl/timer.v` implementing RISC-V machine-mode timer (mtime/mtimecmp).

```verilog
// timer.v — RISC-V mtime/mtimecmp + watchdog
// Base address: 0x2000_0200
// Registers:
//   0x00  MTIME_LO     RW  mtime[31:0]
//   0x04  MTIME_HI     RW  mtime[63:32]
//   0x08  MTIMECMP_LO  RW  mtimecmp[31:0]
//   0x0C  MTIMECMP_HI  RW  mtimecmp[63:32]
//   0x10  WDT_LOAD     WO  write any value to reset watchdog
//   0x14  WDT_CTRL     WO  [0]=enable watchdog
//   0x18  WDT_PERIOD   WO  watchdog timeout in clock cycles
//                          default: 25000000*0.1 = 2500000 (100ms at 25MHz)
// timer_irq output asserted when mtime >= mtimecmp
// wdt_rst output asserted (active high, one cycle) on watchdog timeout
```

---

### Task 0.8 — Boot ROM

Create `rtl/boot_rom.v`. In Phase 0 this contains a minimal test program. The real secure boot sequence is added in Phase 6.

```verilog
// boot_rom.v — Synthesis-time Verilog ROM
// Phase 0 content: minimal RISC-V program that:
//   1. Sets up stack pointer (sp = 0x00018000)
//   2. Calls uart_print("QUARC v0\r\n")
//   3. Enters infinite loop
// Real content: loaded from fw/boot.hex in later phases

module boot_rom #(
    parameter ROM_FILE = "fw/boot.hex",
    parameter DEPTH    = 4096           // 16KB / 4 bytes
)(
    input  wire        clk,
    input  wire        req,
    input  wire [31:0] addr,
    output reg         rvalid,
    output reg  [31:0] rdata
);
    reg [31:0] mem [0:DEPTH-1];
    initial $readmemh(ROM_FILE, mem);

    always @(posedge clk) begin
        rvalid <= req;
        rdata  <= (req) ? mem[addr[13:2]] : 32'h0;
    end
endmodule
```

---

### Task 0.9 — Phase 0 Firmware

Create `fw/boot_phase0.S` — minimal RISC-V assembly that prints a banner and loops. This is loaded into boot ROM for Phase 0 only.

Compile with:

```bash
riscv32-unknown-elf-gcc -march=rv32imc -mabi=ilp32 \
    -nostdlib -nostartfiles -T fw/link.ld \
    fw/boot_phase0.S -o build/boot_phase0.elf
riscv32-unknown-elf-objcopy -O ihex build/boot_phase0.elf fw/boot.hex
```

**Phase 0 Acceptance Criteria:**

```
[ ] make sim-top runs without error
[ ] UART output in simulation shows "QUARC v0\r\n"
[ ] make synth completes — yosys reports < 5000 LUT (Phase 0 stub only)
[ ] make pnr completes — nextpnr achieves timing at 25 MHz
[ ] make prog programs ULX3S successfully
[ ] Physical UART shows "QUARC v0" at 115200 baud
[ ] LED[0] blinks at ~1 Hz (timer interrupt driven)
```

---

## Phase 1 — Keccak / SHA-3 / SHAKE Engine

**Goal:** Hardware Keccak engine passes 100% NIST SHA-3 KAT vectors. Accessible from Ibex.

### Task 1.1 — Keccak-f[1600] Permutation

Create `rtl/keccak.v` implementing the Keccak-f[1600] permutation.

**Interface:**

```verilog
module keccak_f1600 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,        // Pulse to begin permutation
    input  wire [1599:0] state_in,     // Full 1600-bit state input
    output reg  [1599:0] state_out,    // Full 1600-bit state output
    output reg           done          // Pulse when permutation complete
);
```

**Requirements:**

- Implement all 24 rounds of Keccak-f[1600]: theta, rho, pi, chi, iota
- Round constants hardcoded as `parameter` array — no magic numbers
- Iterative (one round per clock cycle) — 24 cycles per permutation
- No combinational loops
- Constant-time: `done` asserts exactly 24 cycles after `start` regardless of input
- All intermediate state in registers — no combinational paths between rounds

**Round constants (iota step):**

```
RC[0]  = 64'h0000000000000001    RC[12] = 64'h000000008000808B
RC[1]  = 64'h0000000000008082    RC[13] = 64'h800000000000008B
RC[2]  = 64'h800000000000808A    RC[14] = 64'h8000000000008089
RC[3]  = 64'h8000000080008000    RC[15] = 64'h8000000000008003
RC[4]  = 64'h000000000000808B    RC[16] = 64'h8000000000008002
RC[5]  = 64'h0000000080000001    RC[17] = 64'h8000000000000080
RC[6]  = 64'h8000000080008081    RC[18] = 64'h000000000000800A
RC[7]  = 64'h8000000000008009    RC[19] = 64'h800000008000000A
RC[8]  = 64'h000000000000008A    RC[20] = 64'h8000000080008081
RC[9]  = 64'h0000000000000088    RC[21] = 64'h8000000000008080
RC[10] = 64'h0000000080008009    RC[22] = 64'h0000000080000001
RC[11] = 64'h000000008000000A    RC[23] = 64'h8000000080008008
```

**Testbench `tb/tb_keccak.sv`:** Apply known input state, compare output to reference vector.

---

### Task 1.2 — SHA-3 / SHAKE Wrapper

Create `rtl/sha3.v` — wraps `keccak_f1600` with padding, absorb/squeeze state machine, and memory-mapped register interface.

**Interface:**

```verilog
module sha3 (
    input  wire        clk,
    input  wire        rst_n,
    // Bus interface (base 0x1000_0000)
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    // Interrupt
    output wire        irq_done
);
```

**State machine:**

```
IDLE → ABSORB (streaming input words) → PADDING → PERMUTE (24 cycles)
     → SQUEEZE (streaming output words) → IDLE
```

**Padding rules:**

- SHA3-256/512: pad with `0x06` then `0x80` at end of rate
- SHAKE-128/256: pad with `0x1F` then `0x80` at end of rate
- Rate (bytes): SHA3-256=136, SHA3-512=72, SHAKE-128=168, SHAKE-256=136

**Acceptance:**

```bash
make sim-sha3
python3 scripts/run_kat.py --suite sha3
# Must report: PASS 0/N ... PASS N/N (100%)
```

Download NIST SHA-3 KAT vectors to `kat/sha3/` from:
`https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Standards-and-Guidelines/documents/examples/SHA3-256_Msg0.pdf`

---

### Task 1.3 — SymbiYosys Formal for Keccak

Create `formal/keccak.sby`:

```
[options]
mode bmc
depth 30

[engines]
smtbmc yices

[script]
read_verilog rtl/keccak.v
prep -top keccak_f1600

[files]
rtl/keccak.v
```

Add to `rtl/keccak.v` — formal properties (inside `ifdef FORMAL` guards):

```verilog
`ifdef FORMAL
    // done asserts exactly 24 cycles after start
    reg [4:0] f_cnt;
    always @(posedge clk) begin
        if (!rst_n) f_cnt <= 0;
        else if (start) f_cnt <= 1;
        else if (f_cnt != 0 && f_cnt < 25) f_cnt <= f_cnt + 1;
    end
    always @(*) begin
        if (f_cnt == 24) assert(done == 1'b1);
        if (f_cnt > 0 && f_cnt < 24) assert(done == 1'b0);
    end
`endif
```

**Acceptance:** `make formal-keccak` exits 0. No assertion violations at depth 30.

---

### Phase 1 Acceptance Criteria:

```
[ ] make sim-sha3 passes — waveform shows correct absorb/squeeze sequence
[ ] python3 scripts/run_kat.py --suite sha3 reports 100% PASS
[ ] make formal-keccak exits 0
[ ] make synth reports additional ~1,500 LUT vs Phase 0
[ ] Keccak accessible from Ibex firmware: write MODE, write data words, read output
```

---

## Phase 2 — Entropy System (TRNG + DRBG)

**Goal:** TRNG passes SP 800-22 statistical tests. DRBG reseeds correctly. Entropy budget tracked.

### Task 2.1 — TRNG

Create `rtl/trng.v`.

**Architecture:**

- 4 independent ring oscillators (3-inverter loops)
- XOR their outputs to produce raw bits
- Sample at 1/64 of clock rate to ensure decorrelation
- Accumulate into 32-bit raw sample register
- SP 800-90B health tests in RTL:

**Repetition Count Test (RCT):**

```
cutoff C = ceil(1 + (-log2(alpha) / H_min))
         = ceil(1 + (6 / 0.5)) = 13   [alpha=2^-6, H_min=0.5]
If same bit repeats C=13 times consecutively → set HEALTH_FAIL, halt
```

**Adaptive Proportion Test (APT):**

```
Window W = 512 samples
Cutoff B = 325  [for H_min=0.5, alpha=2^-6]
Count occurrences of the first sample value in the window
If count > B → set HEALTH_FAIL, halt
```

**MMIO registers (base 0x1000_0500, offset 0x00–0x1C):**

```
0x00  CTRL        WO  [0]=enable [1]=reseed_req
0x04  STATUS      RO  [0]=ready [1]=health_fail [2]=rct_fail [3]=apt_fail [4]=pool_ready
0x08  RANDOM      RO  Read 32-bit random word (blocks until ready)
0x0C  ENTROPY_LO  RO  Entropy pool level in bits [31:0]
0x10  HEALTH_CNT  RO  RCT consecutive count (debug, disabled in production)
```

**Ring oscillator placement note:** Add to `boards/ulx3s.lpf`:

```
FREQUENCY PORT "trng_osc_0" IGNORE;
FREQUENCY PORT "trng_osc_1" IGNORE;
FREQUENCY PORT "trng_osc_2" IGNORE;
FREQUENCY PORT "trng_osc_3" IGNORE;
```

This prevents nextpnr from optimising the oscillator loops away.

**Acceptance:**

```bash
make sim-trng
# Simulation must show:
#   - health_fail asserts within 13 cycles when single-bit stuck fault injected
#   - health_fail asserts within 512 cycles when 90%-biased input injected
python3 scripts/run_sp80022.py --source trng
# Must PASS all 15 statistical tests
```

---

### Task 2.2 — SHAKE-256 DRBG

Create `rtl/drbg.v`. Uses the SHA-3 engine (Keccak) for SHAKE-256 output.

**State:** 256-bit internal state (V || Key as used in CTR_DRBG concept, mapped to SHAKE)

**Operation:**

- `RESEED`: XOR entropy from TRNG into state; run SHAKE-256 on state; replace state with output
- `GENERATE(n_bytes)`: Run SHAKE-256 on state; output n_bytes; update state with remaining output
- Reseed counter: 32-bit; incremented on each GENERATE call; forced reseed at counter = 1000
- If TRNG `health_fail` asserted during required reseed: assert `drbg_halt` → top-level halt

**MMIO (base 0x1000_0500, offset 0x20–0x3C):**

```
0x20  DRBG_CTRL    WO  [0]=generate [1]=reseed [2]=reset; [15:8]=byte_count
0x24  DRBG_STATUS  RO  [0]=ready [1]=done [2]=reseed_needed [3]=halted
0x28  DRBG_OUT     RO  32-bit output word (auto-increments)
0x2C  DRBG_COUNT   RO  reseed counter (current value)
0x30  ENTROPY_USE  WO  write operation type for budget tracking
                       0=KEM_KEYGEN 1=KEM_ENCAP 2=DSA_KEYGEN 3=DSA_SIGN 4=SESSION
```

**Acceptance:**

```bash
make sim-drbg
python3 scripts/run_kat.py --suite drbg
# Must PASS NIST SP 800-90A SHAKE-256 DRBG KAT vectors
```

---

### Task 2.3 — SymbiYosys Formal for TRNG Health

Create `formal/trng_health.sby`. Prove:

1. RCT triggers within 13 cycles of stuck-bit fault injection
2. `health_fail` once set cannot be cleared without reset

**Acceptance:** `make formal-trng_health` exits 0.

---

### Phase 2 Acceptance Criteria:

```
[ ] make sim-trng shows correct RCT halt on injected fault
[ ] make sim-trng shows correct APT halt on biased input
[ ] python3 scripts/run_sp80022.py passes all 15 tests
[ ] python3 scripts/run_kat.py --suite drbg reports 100% PASS
[ ] make formal-trng_health exits 0
[ ] Entropy budget counter increments correctly per operation type
[ ] DRBG halts when reseed needed and TRNG health_fail asserted (simulated)
```

---

## Phase 3 — NTT Engine

**Goal:** Shared NTT engine correct for both q=3329 and q=8380417. Formally verified. Zeroization RTL working.

### Task 3.1 — NTT Core

Create `rtl/ntt.v`.

**Parameters:**

```verilog
parameter COEFF_BITS = 24;   // wide enough for q=8380417
parameter N          = 256;  // polynomial degree
parameter BRAM_DEPTH = 512;  // 2x N for ping-pong
```

**Interface:**

```verilog
module ntt_engine (
    input  wire        clk,
    input  wire        rst_n,
    // Bus interface (base 0x1000_0100)
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    // DMA interface to key store (internal, not on main bus)
    // Not wired in Phase 3 — added in Phase 4/5
    // Interrupt
    output wire        irq_done
);
```

**Butterfly unit:**

```
Cooley-Tukey butterfly:
  a' = a + w*b  mod q
  b' = a - w*b  mod q

Barrett reduction for mod q:
  Given x < q^2, compute x mod q without division
  k = ceil(log2(q))
  m = floor(2^(2k) / q)
  t = x - q * floor(x*m >> 2k)
  if t >= q: t -= q
  return t
```

**Twiddle factors:**

- Precomputed as `$readmemh` from files:
  - `fw/ntt_twiddles_3329.hex` — 128 twiddle factors for q=3329
  - `fw/ntt_twiddles_8380417.hex` — 128 twiddle factors for q=8380417
- Selected at runtime by `MODULUS` register

**Zeroization:**

- When `CTRL[2]` (zeroize) written: counter walks addresses 0..511, writes 0
- `STATUS[2]` (zeroized) asserts after all addresses zeroed
- `irq_done` asserts only after zeroized is set — operation and zeroize both complete

**Acceptance:**

```bash
make sim-ntt
# Testbench must verify:
#   NTT(iNTT(random_poly)) == random_poly  for q=3329,  100 random polynomials
#   NTT(iNTT(random_poly)) == random_poly  for q=8380417, 100 random polynomials
#   Zeroization: all scratchpad addresses read 0x000000 after ZEROIZE
#   irq_done never fires before zeroized
make formal-ntt  # See Task 3.2
```

---

### Task 3.2 — NTT Formal Verification

Create `formal/ntt_zeroize.sby`. Prove:

1. `irq_done` never asserts while any scratchpad address is non-zero
2. After ZEROIZE completes, all scratchpad reads return 0
3. NTT engine never enters undefined state

**Acceptance:** `make formal-ntt_zeroize` exits 0.

---

### Phase 3 Acceptance Criteria:

```
[ ] NTT(iNTT(p)) == p for 100 random polynomials, q=3329
[ ] NTT(iNTT(p)) == p for 100 random polynomials, q=8380417
[ ] Zeroization verified: all scratchpad addresses = 0 after ZEROIZE
[ ] irq_done never asserts before zeroization complete
[ ] make formal-ntt_zeroize exits 0
[ ] make synth: total LUT count < 9,000 (Phase 0-3 cumulative)
```

---

## Phase 4 — ML-KEM-768

**Goal:** ML-KEM-768 passes 100% NIST FIPS 203 KATs. KUE integration working.

### Task 4.1 — ML-KEM Controller

Create `rtl/mlkem.v` — state machine that orchestrates ML-KEM-768 using the NTT and Keccak engines.

**ML-KEM-768 parameters:**

```
k    = 3      (module rank)
n    = 256    (polynomial degree)
q    = 3329   (modulus)
eta1 = 2      (noise parameter, KeyGen)
eta2 = 2      (noise parameter, Encaps)
du   = 10     (compression bits, ciphertext u)
dv   = 4      (compression bits, ciphertext v)
```

**Key sizes:**

```
Encapsulation key ek:    1184 bytes
Decapsulation key dk:    2400 bytes (full dk including ek, H(ek), z)
Ciphertext c:            1088 bytes
Shared secret K:           32 bytes
```

**State machine — KeyGen:**

```
IDLE → SAMPLE_A (SHAKE-128 on rho) → SAMPLE_S_E (CBD from sigma)
     → NTT_S → NTT_E → MATRIX_MUL → ADD_E → ENCODE_EK
     → STORE_DK (→ KUE) → DONE
```

**State machine — Encaps:**

```
IDLE → LOAD_EK → HASH_EK (SHA3-256) → SAMPLE_R (CBD from random)
     → NTT_R → MATRIX_MUL → COMPRESS_U
     → DOT_T_R → DECOMPRESS → ADD_MSG → COMPRESS_V
     → ENCODE_CT → HASH_KR (SHA3-256) → DONE
```

**State machine — Decaps:**

```
IDLE → LOAD_DK (from KUE, not firmware) → DECODE_CT
     → RE_ENCAPS (runs Encaps with stored ek)
     → COMPARE_CT (constant-time) → SELECT_KEY (constant-time)
     → DONE
```

**MMIO (base 0x1000_0200):**

```
0x00  CTRL      WO  [1:0]=op (0=keygen 1=encaps 2=decaps); [7:4]=slot
0x04  STATUS    RO  [0]=ready [1]=done [2]=error [3]=busy
0x08  EK_PTR    WO  DRAM address of encapsulation key (for Encaps/Decaps)
0x0C  CT_PTR    WO  DRAM address of ciphertext (for Decaps)
0x10  OUT_PTR   WO  DRAM address for output (ct for Encaps, K for both)
0x14  MSG_PTR   WO  DRAM address of plaintext message (for Encaps)
0x18  IRQ_EN    WO  [0]=done_irq
```

**Key storage:** After KeyGen, the decapsulation key `dk` is passed to KUE for storage. The ML-KEM controller never exposes `dk` on the main bus — it writes directly to the KUE command interface.

**Acceptance:**

```bash
make sim-mlkem
python3 scripts/run_kat.py --suite mlkem768
# Must report 100% PASS on all keygen/encaps/decaps vectors
# Testbench also verifies:
#   Decaps(dk, Encaps(ek)) == shared_secret  for 50 random keypairs
```

---

### Task 4.2 — Key Store Module

Create `rtl/keystore.v` — BRAM-backed key store. 8 slots. DMA-only access from KUE.

```verilog
// keystore.v — BRAM key store
// 8 slots, each slot = 2400 bytes (ML-DSA dk size, largest key)
// Total: 8 * 2400 = 19200 bytes = 153600 bits ~ 42 EBR blocks
// Access: DMA only from KUE — no bus access, no firmware access
// Bus attempts to access key store region return bus_err immediately
```

**Slot layout:**

```
Each slot (2400 bytes):
  [0:3]    flags     — policy bits (SIGN_ONLY, DECAP_ONLY, NO_EXPORT, NO_OVERWRITE)
  [4:5]    type      — key type (0=empty 1=ML-KEM-dk 2=ML-DSA-sk 3=raw)
  [6:7]    reserved
  [8:9]    counter   — 16-bit use count
  [10:11]  limit     — 16-bit use count limit (0=unlimited)
  [12:15]  reserved
  [16:2415] key_material — up to 2400 bytes of key data
```

---

### Task 4.3 — Key Usage Enforcer

Create `rtl/kue.v` — the policy engine between key store and crypto engines.

**State machine:**

```
IDLE → CHECK_POLICY → CHECK_LIMIT → DMA_KEY_TO_ENGINE
     → WAIT_ENGINE_DONE → INCREMENT_COUNTER → ZEROIZE_ENGINE_KEY_REGS
     → SIGNAL_DONE → IDLE

On policy violation: → SIGNAL_POLICY_ERR → IDLE
On limit reached:    → SIGNAL_LIMIT_ERR  → IDLE
```

**Critical requirement:** At no point in any state does key material appear on the Wishbone main bus. The DMA between key store and crypto engine is an internal point-to-point connection, not routed through the bus crossbar.

**Formal properties (add to `rtl/kue.v` under `ifdef FORMAL`):**

```verilog
// Key bytes never appear on bus_rdata
always @(*) begin
    if (slot_policy[slot_sel][2])  // NO_EXPORT
        assert(bus_rdata != stored_key_word);  // simplified — formal tools elaborate
end

// SIGN_ONLY slot cannot initiate DECAP operation
always @(*) begin
    if (slot_policy[slot_sel][0] && op == OP_DECAP)
        assert(state == STATE_POLICY_ERR);
end
```

**Acceptance:**

```bash
make sim-kue
# Testbench must verify:
#   DECAP attempt on SIGN_ONLY slot → policy_err asserted, key not loaded
#   SIGN attempt on DECAP_ONLY slot → policy_err asserted
#   use_count increments after each successful operation
#   operation blocked when use_count >= limit
make formal-kue_policy
```

---

### Phase 4 Acceptance Criteria:

```
[ ] python3 scripts/run_kat.py --suite mlkem768 → 100% PASS
[ ] Decaps(dk, Encaps(ek)) correct for 50 random keypairs in simulation
[ ] KUE policy violations correctly rejected for SIGN_ONLY, DECAP_ONLY tests
[ ] make formal-kue_policy exits 0
[ ] Key material never appears on Wishbone bus_rdata in any simulation trace
[ ] make synth: total LUT < 12,000
```

---

## Phase 5 — ML-DSA-65

**Goal:** ML-DSA-65 passes 100% NIST FIPS 204 KATs. Hardware rejection sampler. KUE integration.

### Task 5.1 — ML-DSA Controller

Create `rtl/mldsa.v`.

**ML-DSA-65 parameters:**

```
k    = 4      (rows)
l    = 4      (columns)
n    = 256    (polynomial degree)
q    = 8380417
eta  = 2      (secret key range)
tau  = 49     (number of +/-1 in challenge)
gamma1 = 2^17 (masking range)
gamma2 = (q-1)/88
d    = 13     (dropped bits)
lambda = 256  (collision strength)
omega  = 80   (max ones in hint)
```

**Key sizes:**

```
Verification key vk:  1952 bytes
Signing key sk:       4032 bytes
Signature sigma:      3309 bytes
```

**State machine — Sign (hardware rejection sampling loop):**

```
IDLE → LOAD_SK (from KUE) → HASH_MSG (SHAKE-256)
     → REJECTION_LOOP:
         SAMPLE_Y (SHAKE-256 with kappa) → NTT_Y
         → MATRIX_MUL_AY → DECOMPOSE_W1
         → HASH_W1 (SHAKE-256) → SAMPLE_CHALLENGE (c_tilde)
         → EXPAND_C → NTT_C
         → COMPUTE_Z (z = y + c*s1) → CHECK_NORM_Z
         → COMPUTE_R0 → CHECK_NORM_R0
         → if norm check fails: increment kappa, goto SAMPLE_Y
         → COMPUTE_HINT → CHECK_OMEGA
         → ENCODE_SIG → DONE
```

**Critical:** The rejection loop (`SAMPLE_Y` to `CHECK_NORM`) is entirely in hardware. Firmware never sees the loop iteration. This is non-negotiable for timing-attack resistance.

**MMIO (base 0x1000_0300):**

```
0x00  CTRL      WO  [1:0]=op (0=keygen 1=sign 2=verify); [7:4]=slot
0x04  STATUS    RO  [0]=ready [1]=done [2]=error [3]=busy [15:8]=rejection_count
0x08  MSG_PTR   WO  DRAM address of message hash (32 bytes, pre-hashed by firmware)
0x0C  SIG_PTR   WO  DRAM address for signature output (Sign) or input (Verify)
0x10  VK_PTR    WO  DRAM address of verification key (for Verify)
0x14  RESULT    RO  [0]=verify_accept (valid only when done and op=verify)
0x18  IRQ_EN    WO  [0]=done_irq
```

**Acceptance:**

```bash
make sim-mldsa
python3 scripts/run_kat.py --suite mldsa65
# Must report 100% PASS on all keygen/sign/verify vectors
```

---

### Phase 5 Acceptance Criteria:

```
[ ] python3 scripts/run_kat.py --suite mldsa65 → 100% PASS
[ ] Verify(vk, msg, Sign(sk, msg)) == accept for 50 random keypairs
[ ] Verify(vk, msg, tampered_sig) == reject for 50 tampered cases
[ ] Rejection sampling loop confirmed in hardware (waveform shows multiple SAMPLE_Y iterations)
[ ] KUE SIGN_ONLY enforcement verified for ML-DSA sk slot
[ ] make synth: total LUT < 13,000
[ ] make pnr: timing met at 50 MHz (upgrade from 25 MHz Phase 0)
```

---

## Phase 6 — Security Policy RTL

**Goal:** All security policy enforced in hardware. All SymbiYosys formal proofs pass.

### Task 6.1 — PMP Boot ROM Configuration

Update `rtl/boot_rom.v` to add the PMP configuration sequence.

The Boot ROM firmware (not RTL) executes this sequence via CSR writes before jumping to main firmware. The RTL provides a signal `boot_complete` that is asserted only after the jump — used by formal verification.

**Boot ROM assembly sequence (add to `fw/boot.S`):**

```asm
# Configure PMP regions via CSR writes
# Region 0: Boot ROM 0x0000_0000 – 0x0000_3FFF, R-X, LOCKED
li   t0, 0x0000_3FFF    # top address
srli t0, t0, 2           # PMP address format
csrw pmpaddr0, t0
li   t0, 0x9F            # NAPOT, L=1, R=1, X=1, W=0
csrw pmpcfg0, t0

# Region 1: Firmware IRAM 0x0000_4000 – 0x0001_3FFF, R-X, LOCKED
li   t0, 0x0001_3FFF
srli t0, t0, 2
csrw pmpaddr1, t0
li   t0, 0x9D            # NAPOT, L=1, R=1, X=1, W=0

# Region 2: Data RAM 0x0001_4000 – 0x0001_7FFF, RW, LOCKED
li   t0, 0x0001_7FFF
srli t0, t0, 2
csrw pmpaddr2, t0
li   t0, 0x9B            # NAPOT, L=1, R=1, X=0, W=1

# Region 3: Key store 0x0002_0000 – 0x0002_0FFF, NO ACCESS, LOCKED
li   t0, 0x0002_0FFF
srli t0, t0, 2
csrw pmpaddr3, t0
li   t0, 0x88            # NAPOT, L=1, R=0, X=0, W=0

# Regions 4-7: Peripherals RW, LOCKED
# ... (similar pattern for each)

# All regions locked — firmware cannot reconfigure after this point
# Jump to main firmware
la   t0, 0x0000_4000
jr   t0
```

**Formal verification `formal/pmp_config.sby`:**

Prove that `boot_complete` (the signal asserted when Boot ROM jumps to firmware) is never asserted before all PMP regions have been written with LOCK bits set.

---

### Task 6.2 — Lifecycle FSM

Create `rtl/lifecycle.v`.

```verilog
// lifecycle.v — Device lifecycle state machine
// States: 2'b00=MANUFACTURING 2'b01=PROVISIONED 2'b10=LOCKED 2'b11=RMA
// Transitions are one-way. Once a state is left it cannot be re-entered.
// State register is in hardware — not in firmware-writable RAM.

module lifecycle (
    input  wire        clk,
    input  wire        rst_n,
    // Bus interface (base 0x3000_0000)
    input  wire        bus_req,
    input  wire        bus_we,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    // Output to command dispatcher
    output wire [1:0]  lifecycle_state,
    // Transition error
    output wire        transition_err
);
    // State register — only transitions forward
    reg [1:0] state;
    // Valid transitions:
    // 00→01 (MFG→PROV), 01→10 (PROV→LOCK), 01→11 (PROV→RMA), 10→11 (LOCK→RMA)
    // All others are rejected
```

**Formal properties:**

```verilog
`ifdef FORMAL
    // State can never decrease
    reg [1:0] f_prev_state;
    always @(posedge clk) f_prev_state <= state;
    always @(*) assert(state >= f_prev_state);

    // RMA state is absorbing (cannot leave)
    always @(*) if (f_prev_state == 2'b11) assert(state == 2'b11);
`endif
```

**Acceptance:**

```bash
make sim-lifecycle
# Testbench verifies:
#   MFG→PROV transition accepted
#   PROV→LOCK accepted
#   LOCK→MFG rejected (transition_err asserted)
#   PROV→PROV rejected
#   LOCK stays LOCK after reset attempt
make formal-lifecycle_fsm
```

---

### Task 6.3 — Anti-Rollback Counter

Create `rtl/rollback.v`.

```verilog
// rollback.v — Monotonic anti-rollback counter
// Counter lives at 0x3000_0100 (PMP Region 7, R only for firmware)
// Only the Boot ROM sequence can increment it.
// Signal boot_rom_increment_en is driven from boot_rom.v — not from bus.

module rollback (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        boot_rom_increment_en,  // from boot_rom only
    input  wire [31:0] boot_rom_new_version,   // value to set counter to
    // Bus (R only — firmware can read, never write)
    input  wire        bus_req,
    input  wire        bus_we,           // write attempts return err
    input  wire [7:0]  bus_addr,
    output reg  [31:0] bus_rdata,
    output reg         bus_ack,
    output wire        bus_err,          // asserted on any write attempt
    // Counter value for Boot ROM comparison
    output wire [31:0] counter
);
```

**Acceptance:**

```bash
make sim-rollback
# Verify: counter only increases; bus write returns err; boot_rom_increment_en increments correctly
```

---

### Task 6.4 — Bus Address Decoder Formal

Update `rtl/bus.v` with formal assertions. Create `formal/bus_decoder.sby`.

**Formal properties:**

```verilog
`ifdef FORMAL
    // No address maps to two peripherals simultaneously
    // (sum of all sel signals <= 1)
    wire f_sel_sum = sel_rom + sel_iram + sel_dram + sel_keccak +
                     sel_ntt + sel_mlkem + sel_mldsa + sel_kue +
                     sel_trng + sel_uart + sel_timer + sel_lifecycle +
                     sel_rollback;
    always @(*) assert(f_sel_sum <= 1);

    // Key store address range never selected (blocked by PMP, extra belt-and-suspenders)
    always @(*) begin
        if (data_addr >= 32'h0002_0000 && data_addr <= 32'h0002_0FFF)
            assert(data_err == 1'b1);
    end

    // Unmapped address always returns err
    always @(*) begin
        if (f_sel_sum == 0 && data_req)
            assert(data_err == 1'b1);
    end
`endif
```

**Acceptance:** `make formal-bus_decoder` exits 0.

---

### Phase 6 Acceptance Criteria:

```
[ ] make formal-bus_decoder exits 0
[ ] make formal-kue_policy exits 0
[ ] make formal-lifecycle_fsm exits 0
[ ] make formal-pmp_config exits 0
[ ] make formal-trng_health exits 0
[ ] Security simulation tests pass (Section 9.4 of PRD):
    [ ] DECAP on SIGN_ONLY slot → ERR_KEY_POLICY
    [ ] FW_UPDATE in LOCKED state → ERR_LIFECYCLE
    [ ] Firmware read of key store address → bus_err
    [ ] Rollback attack (fw_version < counter) → boot halt
    [ ] TRNG failure → device halt
    [ ] NTT scratchpad all-zeros after operation
[ ] Lifecycle transitions confirmed one-way in all tests
```

---

## Phase 7 — SPI Interface and Host Channel

**Goal:** Encrypted SPI channel working end-to-end. Noise IK handshake completes. All 14 commands functional with lifecycle gating.

### Task 7.1 — SPI Slave RTL

Create `rtl/spi_slave.v`.

**Protocol:** SPI mode 0 (CPOL=0, CPHA=0). CS# active low. 8-bit bytes, MSB first.

**Frame format:**

```
Command frame (host → Quarc):
  [0]      CMD_LEN_HI   Length of payload (high byte)
  [1]      CMD_LEN_LO   Length of payload (low byte)
  [2]      CMD_ID       Command identifier (1 byte)
  [3..N]   PAYLOAD      Command-specific payload

Response frame (Quarc → host):
  [0]      RESP_LEN_HI  Length of response payload
  [1]      RESP_LEN_LO
  [2]      STATUS       0x00=OK, 0x01=ERR_LIFECYCLE, 0x02=ERR_KEY_POLICY,
                        0x03=ERR_VERIFY, 0x04=ERR_TRNG, 0xFF=ERR_GENERIC
  [3..N]   PAYLOAD      Response data
```

**MMIO (base 0x2000_0000):**

```
0x00  STATUS    RO  [0]=cmd_ready [1]=tx_busy [2]=cs_active
0x04  CMD_ID    RO  Command ID of received command (valid when cmd_ready)
0x08  RX_PTR    WO  DRAM address for received payload DMA
0x0C  TX_PTR    WO  DRAM address for transmit payload
0x10  TX_LEN    WO  Transmit payload length
0x14  TX_STATUS WO  Status byte to send in response header
0x18  START_TX  WO  Write any value to begin transmitting response
0x1C  IRQ_EN    WO  [0]=cmd_received_irq
```

---

### Task 7.2 — Noise Protocol IK in Firmware

Implement `fw/noise.c` — Noise Protocol Framework, pattern IK.

**Noise IK pattern:**

```
← s                     (Quarc's static ML-DSA key, known to host)
...
→ e, es, s, ss          (Initiator: host sends ephemeral, encrypts static)
← e, ee, se             (Responder: Quarc sends ephemeral, completes handshake)
```

**Hybrid key exchange:**

- Replace DH operations with hybrid: `ML-KEM-768 + X25519`
- Shared secret = `SHAKE-256(ML-KEM_ss || X25519_ss)`
- Use KUE for any Quarc-side ML-KEM decapsulation (decap key in slot)

**Channel encryption:** AES-256-GCM with per-message nonce (64-bit monotonic counter).

**Files:**

- `fw/noise.c` — Noise state machine
- `fw/aes_gcm.c` — AES-256-GCM (software implementation for channel layer)
- `fw/x25519.c` — X25519 Diffie-Hellman (permissive-licensed reference implementation)

---

### Task 7.3 — Command Dispatcher in Firmware

Create `fw/cmd.c` — dispatches SPI commands to appropriate firmware handlers.

All commands must:

1. Check lifecycle state — return `ERR_LIFECYCLE` if command not permitted in current state
2. Authenticate via Noise channel — all commands except `CHANNEL_INIT` require established session
3. Call appropriate driver
4. Return response

**Command IDs:**

```c
#define CMD_PING          0x01
#define CMD_GET_RANDOM    0x02
#define CMD_KEM_KEYGEN    0x10
#define CMD_KEM_ENCAP     0x11
#define CMD_KEM_DECAP     0x12
#define CMD_DSA_KEYGEN    0x20
#define CMD_DSA_SIGN      0x21
#define CMD_DSA_VERIFY    0x22
#define CMD_STORE_KEY     0x30
#define CMD_GET_STATUS    0x40
#define CMD_SECURE_ERASE  0x50
#define CMD_FW_UPDATE     0x60
#define CMD_SET_LIFECYCLE 0x70
#define CMD_CHANNEL_INIT  0x80
```

---

### Phase 7 Acceptance Criteria:

```
[ ] SPI frame encoding/decoding correct (loopback simulation)
[ ] CHANNEL_INIT: Noise IK handshake completes in simulation with software host
[ ] All 14 commands round-trip correctly in simulation
[ ] Lifecycle gating: 6 commands correctly rejected in wrong lifecycle state
[ ] KUE gating: DSA_SIGN with wrong slot type → ERR_KEY_POLICY
[ ] AES-256-GCM channel encryption verified against NIST KAT vectors
[ ] Forward secrecy: two sessions produce different session keys
```

---

## Phase 8 — Secure Boot and Full Integration

**Goal:** All v1 success criteria pass. v1 use case demo runs on hardware.

### Task 8.1 — Secure Boot ROM Finalisation

Update `rtl/boot_rom.v` and `fw/boot.S` with full secure boot sequence:

1. TRNG startup test (halt if health_fail within 100ms)
2. PMP configuration (all 8 regions, locked)
3. Load firmware from QSPI Flash → IRAM
4. Compute SHA3-256 over firmware image
5. Verify ML-DSA signature: `ML-DSA.Verify(root_vk, fw_hash, fw_sig)`
6. Check `fw_version >= rollback_counter`
7. Increment rollback counter to `fw_version`
8. Jump to firmware at `0x0000_4000`

**Root verification key:** Embedded in Boot ROM at synthesis time via `$readmemh`. 1952 bytes (ML-DSA-65 vk).

**Halt conditions (any → infinite loop + LED blink pattern):**

```
TRNG health failure:   LED pattern 0b001 (LED0 blink fast)
Signature failure:     LED pattern 0b010 (LED1 blink fast)
Rollback violation:    LED pattern 0b011 (LED0+1 blink fast)
```

---

### Task 8.2 — QSPI Flash Firmware Loading

Add QSPI Flash read driver to Boot ROM firmware.

**QSPI Flash (W25Q128, connected to ECP5 QSPI pins):**

```
Commands used:
  0x03  READ    — read firmware image at fixed offset 0x100000
  0xAB  RELEASE_POWERDOWN — issue on startup
```

Firmware is stored at Flash offset `0x100000` (1MB). Boot ROM reads `fw_length` bytes (from firmware header at offset 0).

---

### Task 8.3 — Full SoC Integration Test

Run full integration simulation: software SPI master (Python script) sends all 14 commands, verifies responses.

Create `scripts/integration_test.py`:

```python
# Connects to ULX3S SPI via USB-serial adapter
# Runs through:
#   1. CHANNEL_INIT (full Noise IK handshake)
#   2. PING — verify firmware version and lifecycle state
#   3. KEM_KEYGEN — generate keypair, store in slot 1
#   4. DSA_KEYGEN — generate keypair, store in slot 0
#   5. KEM_ENCAP — encapsulate with slot 1 ek
#   6. KEM_DECAP — decapsulate with slot 1 dk
#   7. Verify encap/decap shared secrets match
#   8. DSA_SIGN — sign test message with slot 0 sk
#   9. DSA_VERIFY — verify signature
#   10. GET_RANDOM — get 64 bytes, check non-zero and non-repeating
#   11. GET_STATUS — check all flags
#   12. SET_LIFECYCLE — advance to PROVISIONED
#   13. FW_UPDATE with rollback test (lower version → expect reject)
#   14. SECURE_ERASE — verify slots cleared
```

---

### Task 8.4 — v1 Use Case Demo

Implement the PQC Firmware OTA demo from PRD Section 1.4.

Create `scripts/ota_demo.py`:

```python
# Simulates full OTA flow:
# 1. Device in MANUFACTURING: generate ML-DSA identity key (slot 0)
# 2. Register device vk with "server" (local Python)
# 3. Server generates test firmware v2, signs with server ML-DSA key
# 4. Establish encrypted session with device (CHANNEL_INIT)
# 5. Send FW_UPDATE with signed firmware
# 6. Device verifies: ML-DSA signature + rollback check (v2 > v1)
# 7. Device flashes firmware, increments rollback counter
# 8. Send FW_UPDATE with firmware v1 (rollback attack)
# 9. Verify device rejects it (rollback_counter = 2, fw_version = 1 < 2)
# 10. Request device attestation (DSA_SIGN over status blob)
# 11. Server verifies attestation using registered vk
# Print PASS/FAIL for each step
```

---

### Task 8.5 — 24-Hour Soak Test

```bash
# Run on physical ULX3S
python3 scripts/soak_test.py --duration 86400
# Every 60 seconds:
#   - PING (check firmware running)
#   - GET_RANDOM (check entropy system)
#   - DSA_SIGN + DSA_VERIFY (check crypto pipeline)
#   - GET_STATUS (check watchdog, TRNG health, no errors)
# Report: elapsed time, operation count, any failures
```

---

### Phase 8 / Final Acceptance Criteria:

```
[ ] TRNG failure → LED pattern 0b001, execution halted
[ ] Signature failure → LED pattern 0b010, execution halted
[ ] Rollback violation → LED pattern 0b011, execution halted
[ ] Valid signed firmware boots correctly
[ ] All 14 SPI commands work on physical hardware
[ ] python3 scripts/integration_test.py → all steps PASS
[ ] python3 scripts/ota_demo.py → all 11 steps PASS
[ ] Soak test: 24 hours, 1440 cycles, 0 failures
[ ] make synth: LUT count reported, must be < 15,000
[ ] make pnr: timing report shows >= 50 MHz achieved
[ ] All 6 SymbiYosys formal proofs pass (make formal exits 0)
[ ] python3 scripts/run_kat.py reports 100% on all suites
```

---

## KAT Download Instructions

Download these before starting Phase 1:

```bash
mkdir -p kat/sha3 kat/mlkem768 kat/mldsa65 kat/aes_gcm kat/drbg

# SHA-3 KAT (NIST)
curl -o kat/sha3/SHA3_256ShortMsg.rsp \
  https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/sha3/sha-3bytetestvectors.zip
# (unzip and use SHA3_256ShortMsg.rsp, SHA3_512ShortMsg.rsp,
#  SHAKE128ShortMsg.rsp, SHAKE256ShortMsg.rsp)

# ML-KEM KAT (NIST FIPS 203)
# Download from: https://csrc.nist.gov/Projects/post-quantum-cryptography/post-quantum-cryptography-standardization/example-files
# Files: ML-KEM-768.kat

# ML-DSA KAT (NIST FIPS 204)
# Files: ML-DSA-65.kat

# AES-GCM KAT
# From NIST CAVS: gcmEncryptExtIV128.rsp, gcmDecrypt128.rsp (256-bit key variants)

# DRBG KAT
# From NIST SP 800-90A: SHAKE256no reseed.rsp, SHAKE256pr false.rsp
```

---

## Firmware Linker Script

Create `fw/link.ld`:

```ld
MEMORY {
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    IRAM (rwx) : ORIGIN = 0x00004000, LENGTH = 64K
    DRAM (rw)  : ORIGIN = 0x00014000, LENGTH = 16K
}

SECTIONS {
    .text : { *(.text.start) *(.text*) } > IRAM
    .rodata : { *(.rodata*) } > IRAM
    .data : { *(.data*) } > DRAM AT > IRAM
    .bss : { *(.bss*) *(COMMON) } > DRAM
    .stack (NOLOAD) : { . = . + 4096; _sp = .; } > DRAM
}

_fw_start = ORIGIN(IRAM);
_fw_end   = .;
```

---

## Hardware Register Map Header

Create `fw/hal.h`:

```c
#ifndef HAL_H
#define HAL_H

// Base addresses
#define KECCAK_BASE     0x10000000UL
#define NTT_BASE        0x10000100UL
#define MLKEM_BASE      0x10000200UL
#define MLDSA_BASE      0x10000300UL
#define KUE_BASE        0x10000400UL
#define TRNG_BASE       0x10000500UL
#define SPI_BASE        0x20000000UL
#define UART_BASE       0x20000100UL
#define TIMER_BASE      0x20000200UL
#define LIFECYCLE_BASE  0x30000000UL
#define ROLLBACK_BASE   0x30000100UL

// Register access macro
#define REG(base, offset) (*((volatile uint32_t *)((base) + (offset))))

// Keccak registers
#define KECCAK_CTRL       REG(KECCAK_BASE, 0x00)
#define KECCAK_STATUS     REG(KECCAK_BASE, 0x04)
#define KECCAK_MODE       REG(KECCAK_BASE, 0x08)
#define KECCAK_DATA_IN    REG(KECCAK_BASE, 0x0C)
#define KECCAK_DATA_OUT   REG(KECCAK_BASE, 0x10)
#define KECCAK_LEN        REG(KECCAK_BASE, 0x14)
#define KECCAK_SQ_LEN     REG(KECCAK_BASE, 0x18)

// Keccak mode values
#define KECCAK_MODE_SHA3_256  0
#define KECCAK_MODE_SHA3_512  1
#define KECCAK_MODE_SHAKE128  2
#define KECCAK_MODE_SHAKE256  3

// NTT registers
#define NTT_CTRL          REG(NTT_BASE, 0x00)
#define NTT_STATUS        REG(NTT_BASE, 0x04)
#define NTT_MODULUS       REG(NTT_BASE, 0x08)
#define NTT_MODULUS_3329     0
#define NTT_MODULUS_8380417  1

// KUE registers
#define KUE_CMD           REG(KUE_BASE, 0x00)
#define KUE_STATUS        REG(KUE_BASE, 0x04)
#define KUE_HASH_PTR      REG(KUE_BASE, 0x08)
#define KUE_CT_PTR        REG(KUE_BASE, 0x0C)
#define KUE_OUT_PTR       REG(KUE_BASE, 0x10)
#define KUE_SLOT_POLICY   REG(KUE_BASE, 0x14)
#define KUE_SLOT_COUNT    REG(KUE_BASE, 0x18)

// KUE op codes (bits [3:0] of CMD)
#define KUE_OP_SIGN    0x0
#define KUE_OP_DECAP   0x1
#define KUE_OP_KEYGEN  0x2
#define KUE_OP_STORE   0x3
#define KUE_OP_ERASE   0x4

// KUE policy bits
#define KUE_POLICY_SIGN_ONLY   (1 << 0)
#define KUE_POLICY_DECAP_ONLY  (1 << 1)
#define KUE_POLICY_NO_EXPORT   (1 << 2)
#define KUE_POLICY_NO_OVERWRITE (1 << 3)

// Lifecycle states
#define LIFECYCLE_BASE      0x30000000UL
#define LC_STATE          REG(LIFECYCLE_BASE, 0x00)
#define LC_TRANSITION     REG(LIFECYCLE_BASE, 0x04)
#define LC_MFG    0
#define LC_PROV   1
#define LC_LOCK   2
#define LC_RMA    3

// Rollback
#define RB_COUNTER        REG(ROLLBACK_BASE, 0x00)
#define RB_FW_VERSION     REG(ROLLBACK_BASE, 0x04)

// UART
#define UART_TX_DATA      REG(UART_BASE, 0x00)
#define UART_STATUS       REG(UART_BASE, 0x04)
#define UART_RX_DATA      REG(UART_BASE, 0x08)
#define UART_BAUD_DIV     REG(UART_BASE, 0x0C)

// Timer
#define TIMER_MTIME_LO    REG(TIMER_BASE, 0x00)
#define TIMER_MTIME_HI    REG(TIMER_BASE, 0x04)
#define TIMER_MTIMECMP_LO REG(TIMER_BASE, 0x08)
#define TIMER_MTIMECMP_HI REG(TIMER_BASE, 0x0C)
#define TIMER_WDT_LOAD    REG(TIMER_BASE, 0x10)
#define TIMER_WDT_CTRL    REG(TIMER_BASE, 0x14)

#endif // HAL_H
```

---

## Summary: Phase Exit Gates

| Phase | Key Exit Gate                                   | Must Not Proceed Without |
| ----- | ----------------------------------------------- | ------------------------ |
| 0     | Ibex boots, UART output on hardware             | Physical board test      |
| 1     | 100% NIST SHA-3 KAT + formal proof              | KAT script + SymbiYosys  |
| 2     | SP 800-22 pass + DRBG KAT                       | Statistical test suite   |
| 3     | NTT correctness + zeroization formal            | Simulation + SymbiYosys  |
| 4     | 100% ML-KEM FIPS 203 KAT + KUE rejection        | KAT script + sim         |
| 5     | 100% ML-DSA FIPS 204 KAT + HW rejection sampler | KAT script + waveform    |
| 6     | All 6 SymbiYosys formal proofs pass             | make formal exits 0      |
| 7     | All 14 SPI commands working + Noise handshake   | Integration simulation   |
| 8     | All PRD v1.1 Section 9.5 criteria + 24h soak    | Physical hardware        |

---

_Quarc Implementation Plan v1.0 // 2025 // Proprietary & Confidential_
