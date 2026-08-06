IBEX_SV    := $(filter-out ibex/rtl/ibex_tracer.sv ibex/rtl/ibex_tracer_pkg.sv \
                ibex/rtl/ibex_top_tracing.sv, $(wildcard ibex/rtl/*.sv))
IBEX_PRIM  := ibex/vendor/lowrisc_ip/ip/prim
IBEX_PKG   := $(wildcard $(IBEX_PRIM)/rtl/*pkg.sv) $(wildcard $(IBEX_PRIM)_generic/rtl/*pkg.sv)
IBEX_V     := build/ibex.v
QUARC_SRCS := rtl/top.v rtl/bus.v rtl/boot_rom.v rtl/keccak.v rtl/sha3.v \
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
	iverilog -g2012 -o build/sim.vvp $(ALL_SRCS) $(TB_SRCS) -s tb_top
	vvp build/sim.vvp

sim-%: $(IBEX_V) $(FW_HEX)
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
	$(MAKE) -C fw clean
