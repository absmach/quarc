IBEX_SV    := $(filter-out ibex/rtl/ibex_tracer.sv ibex/rtl/ibex_tracer_pkg.sv \
                ibex/rtl/ibex_top_tracing.sv, $(wildcard ibex/rtl/*.sv))
IBEX_PRIM  := ibex/vendor/lowrisc_ip/ip/prim
IBEX_PKG   := $(wildcard $(IBEX_PRIM)/rtl/*pkg.sv) $(wildcard $(IBEX_PRIM)_generic/rtl/*pkg.sv)
IBEX_V     := build/ibex.v
QUARC_SRCS := rtl/top.v rtl/bus.v rtl/boot_rom.v rtl/data_ram.v rtl/keccak.v rtl/keccak_engine.v rtl/sha3.v \
               rtl/ntt.v rtl/mlkem.v rtl/mldsa.v rtl/trng.v rtl/drbg.v \
               rtl/kue.v rtl/keystore.v rtl/lifecycle.v rtl/rollback.v \
               rtl/spi_slave.v rtl/uart.v rtl/timer.v
ALL_SRCS   := $(IBEX_V) $(QUARC_SRCS)
TB_SRCS    := $(wildcard tb/*.sv)

FW_HEX     := fw/boot.hex

.PHONY: all sim synth pnr bitstream prog formal clean fw

all: bitstream

$(IBEX_V): $(IBEX_SV)
	mkdir -p build
	# -D SYNTHESIS drops sim-only Ibex code (DPI exports, fcov macros) that
	# Icarus cannot elaborate; the functional core is unaffected.
	sv2v $(IBEX_SV) $(IBEX_PKG) \
		-D SYNTHESIS \
		-I $(IBEX_PRIM)/rtl -I ibex/vendor/lowrisc_ip/dv/sv/dv_utils \
		-y $(IBEX_PRIM)/rtl -y $(IBEX_PRIM)_generic/rtl \
		-w $(IBEX_V)
	# prim_clock_gating is an ICG (latch) cell that Yosys `check -assert`
	# rejects and that we don't need on an FPGA target; make it pass-through.
	sed -i -e '/^module prim_clock_gating (/,/^endmodule$$/{/^[[:space:]]*reg en_latch;$$/d;/^[[:space:]]*always @(\*) begin$$/,/^[[:space:]]*end$$/d;s/^[[:space:]]*assign clk_o = en_latch & clk_i;/assign clk_o = clk_i;/;/^[[:space:]]*initial _sv2v_0 = 0;$$/d;}' $(IBEX_V)

fw: $(FW_HEX)

$(FW_HEX): fw/boot_phase0.S fw/link.ld
	$(MAKE) -C fw

sim: $(IBEX_V) $(FW_HEX)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim.vvp $(ALL_SRCS) $(TB_SRCS) -s tb_top
	vvp build/sim.vvp

sim-%: $(IBEX_V)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_$*.vvp $(IBEX_V) \
		$(if $(filter keccak,$*),,rtl/keccak.v rtl/keccak_engine.v) rtl/$*.v tb/tb_$*.sv -s tb_$*
	vvp build/sim_$*.vvp

# tb_keccak reads reference permutation vectors from kat/
KAT_VEC := kat/keccak_f1600_zero.dat kat/keccak_f1600_count.dat \
           kat/sha3/sha3_256.txt kat/sha3/sha3_512.txt \
           kat/sha3/shake128.txt kat/sha3/shake256.txt kat/drbg.txt \
           kat/ntt_in1.txt kat/ntt_in2.txt kat/ntt_fwd1.txt kat/ntt_fwd2.txt \
           kat/ntt_inv1.txt kat/ntt_mul.txt rtl/ntt_zetas.vh \
           kat/mlkem_pk.txt kat/mlkem_dk.txt kat/mlkem_ct.txt kat/mlkem_ss.txt kat/mlkem_seed.txt

$(KAT_VEC): scripts/gen_kat.py scripts/gen_ntt_kat.py scripts/gen_mlkem_kat.py
	python3 scripts/gen_kat.py
	python3 scripts/gen_ntt_kat.py
	python3 scripts/gen_mlkem_kat.py

sim-keccak: $(KAT_VEC)

# 3-client Keccak engine arbitration (SHA-3 / DRBG / ML-KEM)
sim-keccak-c2: $(KAT_VEC)
	iverilog -g2012 -D QUARC_SIM -o build/sim_keccak_c2.vvp \
		rtl/keccak.v rtl/keccak_engine.v tb/tb_keccak_c2.sv -s tb_keccak_c2
	vvp build/sim_keccak_c2.vvp
sim-sha3: $(KAT_VEC)
sim-drbg: $(KAT_VEC)
sim-ntt: $(KAT_VEC)
kat-ntt: sim-ntt

# NTT engine client port (driven by the ML-KEM controller)
sim-ntt-c: $(KAT_VEC)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_ntt_c.vvp \
		rtl/keccak.v rtl/keccak_engine.v rtl/ntt.v tb/tb_ntt_c.sv -s tb_ntt_c
	vvp build/sim_ntt_c.vvp
kat-drbg: sim-drbg

# collect a long DRBG bit stream for the SP 800-22 statistical suite
drbg-collect: $(IBEX_V) $(KAT_VEC)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_drbg_collect.vvp $(IBEX_V) \
		rtl/keccak.v rtl/keccak_engine.v rtl/drbg.v tb/tb_drbg_collect.sv -s tb_drbg_collect
	vvp build/sim_drbg_collect.vvp
	@echo "collected -> build/drbg_bits.txt"

# NIST SP 800-22 statistical suite (17 tests) on DRBG output
PY := $(shell python3 -c "import scipy" 2>/dev/null && echo python3 || (test -x "$(HOME)/.pyenv/shims/python3" && echo "$(HOME)/.pyenv/shims/python3" || echo python3))
sp80022: drbg-collect
	$(PY) scripts/run_sp80022.py

# SoC-level SHA-3 test: boots the boot_sha3 firmware on quarc_top and checks
# the UART for "SHA3 OK".
FW_SHA3_HEX := fw/boot_sha3.hex
FW_ENTROPY_HEX := fw/boot_entropy.hex
FW_NTT_HEX := fw/boot_ntt.hex

$(FW_SHA3_HEX): fw/boot_sha3.S fw/link.ld
	$(MAKE) -C fw

$(FW_ENTROPY_HEX): fw/boot_entropy.S fw/link.ld
	$(MAKE) -C fw

$(FW_NTT_HEX): fw/boot_ntt.S fw/link.ld
	$(MAKE) -C fw

fw/boot_ram.hex: fw/boot_ram.S fw/link.ld
	$(MAKE) -C fw

sim-sha3-soc: $(IBEX_V) $(FW_SHA3_HEX)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_sha3_soc.vvp $(IBEX_V) $(QUARC_SRCS) tb/tb_sha3_soc.sv -s tb_sha3_soc
	vvp build/sim_sha3_soc.vvp

sim-entropy-soc: $(IBEX_V) $(FW_ENTROPY_HEX)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_entropy_soc.vvp $(IBEX_V) $(QUARC_SRCS) tb/tb_entropy_soc.sv -s tb_entropy_soc
	vvp build/sim_entropy_soc.vvp

sim-ntt-soc: $(IBEX_V) $(FW_NTT_HEX)
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_ntt_soc.vvp $(IBEX_V) $(QUARC_SRCS) tb/tb_ntt_soc.sv -s tb_ntt_soc
	vvp build/sim_ntt_soc.vvp

sim-ram-soc: $(IBEX_V) fw/boot_ram.hex
	iverilog -g2012 -D QUARC_SIM -I rtl -o build/sim_ram_soc.vvp $(IBEX_V) $(QUARC_SRCS) tb/tb_ram_soc.sv -s tb_ram_soc
	vvp build/sim_ram_soc.vvp

synth: $(IBEX_V)
	yosys -p "read_verilog -I rtl $(ALL_SRCS); synth_ecp5 -abc9 -top quarc_top -json build/quarc.json" 2>&1 | tee build/synth.log
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

kat: $(KAT_VEC)
	python3 scripts/run_kat.py

clean:
	rm -rf build/
	$(MAKE) -C fw clean
