#!/usr/bin/env bash
# =============================================================================
# run_neorv32_gui.sh - build the NEORV32 + AES SoC and open its waveform in the
# Vivado xsim GUI, with the XBUS / AXI4-Lite / IRQ / pipeline signals pre-grouped.
#
#   bash run_neorv32_gui.sh                                  # polling firmware
#   FW_SRC=sw/aes_demo/main_irq.c bash run_neorv32_gui.sh    # IRQ-driven firmware
#
# Reads the same overrides as run_neorv32.sh (NEORV32_HOME, RISCV_DIR,
# XILINX_VIVADO, FW_SRC). The GUI stays open until you close it.
# =============================================================================
set -e
export PATH="$PATH:/c/Windows/System32"
VR="${XILINX_VIVADO:-/c/Xilinx/Vivado/2024.1}"
AES_ROOT="$(cd "$(dirname "$0")" && pwd)"

# 1. build firmware + compile the mixed-language design (also runs a batch check)
bash "$AES_ROOT/run_neorv32.sh"

# 2. re-elaborate with debug symbols, then open the waveform GUI
cd "$AES_ROOT/sim_neorv32"
"$VR/bin/xelab" -debug typical -L neorv32 -L work work.tb_neorv32_aes \
    -s neorv32_gui --timescale 1ns/1ps
echo "opening Vivado xsim waveform GUI (close the window when done)..."
"$VR/bin/xsim" neorv32_gui -gui -tclbatch "$AES_ROOT/sim/neorv32_wave.tcl"
