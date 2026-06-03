# =============================================================================
# AES-128 UVM Testbench — Makefile
# Run from the PROJECT ROOT, not from inside uvm/:
#   make -f uvm/Makefile nist
#
# Requires: Vivado in PATH (xvlog, xelab, xsim) + gcc/clang for DPI-C.
# On Windows open a "Vivado Tcl Shell" or source settings64.bat first.
# =============================================================================
# Targets:
#   nist        — Phase 1 : 5 directed NIST vectors
#   random      — Phase 2a: 100 constrained-random vectors
#   back2back   — Phase 2b: 50 rapid-fire stress vectors
#   all         — Run all three suites in sequence
#   dpi         — Build DPI-C shared library only
#   elab        — Compile + elaborate only (no simulation)
#   clean       — Remove all generated artefacts
# =============================================================================

# --------------------------------------------------------------------------
# Platform detection
# --------------------------------------------------------------------------
ifeq ($(OS),Windows_NT)
    DPI_EXT  = dll
    DPI_LNKFLAGS = -Wl,--export-all-symbols
else
    DPI_EXT  = so
    DPI_LNKFLAGS = -fPIC
endif

# --------------------------------------------------------------------------
# Vivado install root (override on command line if needed)
#   make -f uvm/Makefile nist VIVADO_ROOT=C:/Xilinx/Vivado/2023.2
# --------------------------------------------------------------------------
VIVADO_ROOT ?= C:/Xilinx/Vivado/2024.1
SVDPI_INC   = $(VIVADO_ROOT)/data/xsim/include

# --------------------------------------------------------------------------
# Tools
# --------------------------------------------------------------------------
XVLOG   = xvlog
XELAB   = xelab
XSIM    = xsim
CC      = gcc
CFLAGS  = -O2 -shared $(DPI_LNKFLAGS) -I"$(SVDPI_INC)"

SNAP    = aes_uvm_snap
DPI_LIB = uvm/dpi/aes_dpi.$(DPI_EXT)
# xelab -sv_lib takes the path WITHOUT extension
DPI_SL  = uvm/dpi/aes_dpi

# --------------------------------------------------------------------------
# Source lists (relative to project root)
# --------------------------------------------------------------------------
RTL_SRC = rtl/aes_sbox.v \
          rtl/aes_key_expand.v \
          rtl/aes_round.v \
          rtl/aes_top.v

# Compile order matters: base classes before derived ones
UVM_SRC = uvm/top/aes_if.sv \
          uvm/sva/aes_assertions.sv \
          uvm/coverage/aes_coverage.sv \
          uvm/env/aes_seq_item.sv \
          uvm/env/aes_driver.sv \
          uvm/env/aes_monitor.sv \
          uvm/env/aes_scoreboard.sv \
          uvm/env/aes_agent.sv \
          uvm/env/aes_env.sv \
          uvm/seq/aes_seq_base.sv \
          uvm/seq/aes_seq_single.sv \
          uvm/seq/aes_seq_back2back.sv \
          uvm/test/aes_test_base.sv \
          uvm/test/aes_test_nist.sv \
          uvm/test/aes_test_random.sv \
          uvm/test/aes_test_back2back.sv \
          uvm/top/aes_tb_top.sv

# --------------------------------------------------------------------------
# Step 1: DPI-C shared library
# --------------------------------------------------------------------------
dpi: $(DPI_LIB)

$(DPI_LIB): uvm/dpi/aes_dpi.c uvm/dpi/aes_dpi.h
	$(CC) $(CFLAGS) -o $@ uvm/dpi/aes_dpi.c

# --------------------------------------------------------------------------
# Step 2: Compile + elaborate (depends on DPI lib being built first)
# --------------------------------------------------------------------------
elab: $(DPI_LIB)
	$(XVLOG) -sv -L uvm $(RTL_SRC) $(UVM_SRC)
	$(XELAB) -sv -L uvm aes_tb_top -sv_lib $(DPI_SL) -s $(SNAP)

# --------------------------------------------------------------------------
# Test targets
# --------------------------------------------------------------------------
nist: elab
	$(XSIM) $(SNAP) -testplusarg UVM_TESTNAME=aes_test_nist -runall

random: elab
	$(XSIM) $(SNAP) -testplusarg UVM_TESTNAME=aes_test_random -runall

back2back: elab
	$(XSIM) $(SNAP) -testplusarg UVM_TESTNAME=aes_test_back2back -runall

all: nist random back2back

# --------------------------------------------------------------------------
# Clean
# --------------------------------------------------------------------------
clean:
	rm -rf xsim.dir xvlog.pb xelab.pb *.log *.jou webtalk* \
	       $(DPI_LIB)

.PHONY: dpi elab nist random back2back all clean
