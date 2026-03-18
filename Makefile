# =============================================================================
# AES-128 Core — Makefile
# =============================================================================
# Usage:
#   make sim       — Compile & run with Icarus Verilog
#   make wave      — Open waveform in GTKWave
#   make golden    — Run Python golden model
#   make cpp       — Build & run C++ golden model
#   make clean     — Remove generated files
# =============================================================================

RTL_DIR  = rtl
SIM_DIR  = sim
CPP_DIR  = cpp

RTL_SRC  = $(RTL_DIR)/aes_sbox.v \
           $(RTL_DIR)/aes_key_expand.v \
           $(RTL_DIR)/aes_round.v \
           $(RTL_DIR)/aes_top.v
TB_SRC   = $(SIM_DIR)/tb_aes_top.sv

# Icarus Verilog simulation
sim: $(RTL_SRC) $(TB_SRC)
	iverilog -g2012 -o aes_sim $(RTL_SRC) $(TB_SRC)
	vvp aes_sim

wave: aes_top_tb.vcd
	gtkwave aes_top_tb.vcd &

# Python golden model
golden:
	python3 verify/aes_golden_model.py

# C++ golden model
cpp:
	g++ -std=c++11 -O2 -o aes_golden $(CPP_DIR)/aes_golden_model.cpp
	./aes_golden

clean:
	rm -f aes_sim aes_golden aes_top_tb.vcd

.PHONY: sim wave golden cpp clean
