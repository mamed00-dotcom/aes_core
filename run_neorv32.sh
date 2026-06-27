#!/usr/bin/env bash
# ===========================================================================
# run_neorv32.sh - build firmware + elaborate/run the NEORV32 + AES SoC (xsim)
# Project: AES-128 Core - real RISC-V integration (NEORV32)
#
# Replicates NEORV32's firmware build WITHOUT `make` (not installed here):
#   image_gen (host gcc) -> compile/link firmware (riscv gcc) -> objcopy ->
#   image_gen -t vhd -> overwrite rtl/core/neorv32_imem_image.vhd.
# Then mixed-language elaboration: NEORV32 VHDL into library `neorv32`, the
# Verilog AES + bridge + the VHDL SoC top + SV testbench, and run.
#
# Override these if your paths differ:
#   NEORV32_HOME, RISCV_DIR, XILINX_VIVADO
# Select firmware (default = polling main.c; IRQ-driven = main_irq.c):
#   FW_SRC=sw/aes_demo/main_irq.c bash run_neorv32.sh
# ===========================================================================
set -e
export PATH="$PATH:/c/Windows/System32"

NEORV32_HOME="${NEORV32_HOME:-/c/Users/mamed/Desktop/neorv32}"
RISCV_DIR="${RISCV_DIR:-$(cat /c/Users/mamed/tools/RISCV_DIR.txt 2>/dev/null)}"
VR="${XILINX_VIVADO:-/c/Xilinx/Vivado/2024.1}"
AES_ROOT="$(cd "$(dirname "$0")" && pwd)"
FW_SRC="${FW_SRC:-$AES_ROOT/sw/aes_demo/main.c}"

RISCV="$RISCV_DIR/bin/riscv-none-elf-"
BUILD="$AES_ROOT/sw/aes_demo/build"
mkdir -p "$BUILD"

echo "=== [1/6] build host image_gen ==="
gcc -O2 -o "$BUILD/image_gen.exe" "$NEORV32_HOME/sw/image_gen/image_gen.c"

echo "=== [2/6] compile + link firmware (rv32i_zicsr_zifencei): $(basename "$FW_SRC") ==="
"${RISCV}gcc" -march=rv32i_zicsr_zifencei -mabi=ilp32 -Os -Wall -Wextra \
    -ffunction-sections -fdata-sections -nostartfiles \
    -T "$NEORV32_HOME/sw/common/neorv32.ld" -Wl,--gc-sections \
    -I "$NEORV32_HOME/sw/lib/include" \
    "$NEORV32_HOME/sw/common/crt0.S" "$FW_SRC" \
    -lm -lc -lgcc -o "$BUILD/main.elf"
"${RISCV}size" "$BUILD/main.elf"

echo "=== [3/6] objcopy -> flat binary -> IMEM image VHDL ==="
"${RISCV}objcopy" -O binary "$BUILD/main.elf" "$BUILD/elf.bin"
( cd "$BUILD" && ./image_gen.exe -t vhd -i elf.bin -o neorv32_imem_image.vhd )
cp "$BUILD/neorv32_imem_image.vhd" "$NEORV32_HOME/rtl/core/neorv32_imem_image.vhd"
echo "image installed -> rtl/core/neorv32_imem_image.vhd"

echo "=== [4/6] compile NEORV32 VHDL into library 'neorv32' (VHDL-2008) ==="
mkdir -p "$AES_ROOT/sim_neorv32"
cd "$AES_ROOT/sim_neorv32"
# expand $NEORV32_HOME in the file list and analyze in order
FILES=$(sed "s|\$NEORV32_HOME|$NEORV32_HOME|g" "$NEORV32_HOME/rtl/file_list_soc.f")
"$VR/bin/xvhdl" --2008 --work neorv32 $FILES 2>&1 | grep -iE "error" | grep -viE "INFO" || true

echo "=== [4b] compile SoC top (VHDL, references library neorv32) ==="
"$VR/bin/xvhdl" --2008 "$AES_ROOT/rtl/neorv32_aes_soc.vhd" 2>&1 | grep -iE "error| warning" | grep -viE "INFO" || true

echo "=== [5/6] compile Verilog AES + bridge + SV testbench ==="
"$VR/bin/xvlog" \
    "$AES_ROOT/rtl/aes_sbox.v" "$AES_ROOT/rtl/aes_key_expand.v" \
    "$AES_ROOT/rtl/aes_round.v" "$AES_ROOT/rtl/aes_pipeline_top.v" \
    "$AES_ROOT/rtl/aes_coproc.v" "$AES_ROOT/rtl/wb_to_axil.v" 2>&1 | grep -iE "error" || true
"$VR/bin/xvlog" -sv "$AES_ROOT/sim/tb_neorv32_aes.sv" 2>&1 | grep -iE "error" || true

echo "=== [6/6] elaborate + run ==="
"$VR/bin/xelab" -L neorv32 -L work work.tb_neorv32_aes \
    -s neorv32_snap --timescale 1ns/1ps 2>&1 | tail -6
"$VR/bin/xsim" neorv32_snap --runall 2>&1 | grep -iE "PASS|FAIL|TIMEOUT|====|NEORV32|ciphertext|cycle" | tail -20
