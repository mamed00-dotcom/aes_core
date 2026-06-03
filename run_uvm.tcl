# =============================================================================
# run_uvm.tcl — Run AES-128 UVM tests from the Vivado Tcl Shell
#
# Usage (from Vivado Tcl Shell, with project root as working directory):
#   cd C:/Users/mamed/Desktop/aes_core
#   source run_uvm.tcl
#   run_uvm nist        ;# Phase 1 — NIST directed vectors
#   run_uvm random      ;# Phase 2a — 100 random vectors
#   run_uvm back2back   ;# Phase 2b — 50 stress vectors
#   run_uvm all         ;# All three suites
# =============================================================================

# --------------------------------------------------------------------------
# Helper: run a shell command, show output, stop on error.
# Uses {*} list expansion — avoids eval+newline command-separator bug.
# Uses cmd /c "... 2>&1" so both stdout and stderr are captured.
# --------------------------------------------------------------------------
proc xrun {args} {
    puts "\n>>> [join $args { }]"
    set cmdline [join $args { }]
    set rc [catch {exec cmd /c "$cmdline 2>&1"} out]
    if {$out ne ""} { puts $out }
    if {$rc} { error "Command failed — see output above" }
}

# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------
proc run_uvm {{test nist}} {

    # Vivado sets XILINX_VIVADO when you open the Tcl Shell
    set vivado_root $::env(XILINX_VIVADO)
    set svdpi_inc   "$vivado_root/data/xsim/include"

    # File lists — plain space-separated strings (no newlines), safe to join
    set rtl_src [list \
        rtl/aes_sbox.v \
        rtl/aes_key_expand.v \
        rtl/aes_round.v \
        rtl/aes_top.v]

    set uvm_src [list \
        uvm/top/aes_if.sv \
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
        uvm/top/aes_tb_top.sv]

    # -----------------------------------------------------------------------
    # Step 1 — Build BOTH forms of the DPI-C library:
    #   aes_dpi.a  — static archive for xelab (-sv_lib at link time)
    #   aes_dpi.dll — shared library for xsim  (--sv_lib at runtime)
    # -----------------------------------------------------------------------
    puts "\n\[1/3\] Compiling DPI-C golden model ..."
    xrun gcc -O2 -c \
        -I$svdpi_inc \
        -o uvm/dpi/aes_dpi.o \
        uvm/dpi/aes_dpi.c
    xrun ar rcs uvm/dpi/aes_dpi.a uvm/dpi/aes_dpi.o
    puts "      Done: uvm/dpi/aes_dpi.a"

    # UVM 1.2 include dir (for uvm_macros.svh)
    set uvm_inc "$vivado_root/data/system_verilog/uvm_1.2"

    # -----------------------------------------------------------------------
    # Step 2 — Compile SystemVerilog
    # -----------------------------------------------------------------------
    puts "\n\[2/3\] Compiling SystemVerilog (xvlog) ..."
    xrun xvlog -sv -L uvm -i $uvm_inc {*}$rtl_src {*}$uvm_src

    # -----------------------------------------------------------------------
    # Step 3 — Elaborate
    # -----------------------------------------------------------------------
    puts "\n\[3/3\] Elaborating (xelab) ..."
    xrun xelab -sv -L uvm aes_tb_top \
        -sv_lib uvm/dpi/aes_dpi \
        -s aes_uvm_snap \
        --timescale 1ns/1ps

    # -----------------------------------------------------------------------
    # Step 4 — Run simulation(s)
    # -----------------------------------------------------------------------
    puts "\n\[4/4\] Running test(s): $test"

    if {$test eq "all"} {
        foreach t {aes_test_nist aes_test_random aes_test_back2back} {
            run_one_test $t
        }
    } else {
        run_one_test "aes_test_$test"
    }

    puts "\n=== Done ==="
}

proc run_one_test {testname} {
    puts "\n--- $testname ---"
    set xsim_exe [file join $::env(XILINX_VIVADO) bin unwrapped win64.o xsim.exe]
    set dpi_dll  [file join [pwd] uvm dpi aes_dpi]
    set logfile  "xsim_${testname}.log"
    set plusarg  "UVM_TESTNAME=$testname"
    puts ">>> xsim aes_uvm_snap --testplusarg $plusarg --runall  (log: $logfile)"
    # Tcl exec list args = no shell, no '=' splitting on UVM_TESTNAME=...
    # --log writes all xsim output to a file (2>@stdout doesn't work in Vivado Tcl)
    catch {exec $xsim_exe aes_uvm_snap \
        --testplusarg $plusarg \
        --log $logfile \
        --runall} out
    # Print the log file so we can see UVM results
    if {[file exists $logfile]} {
        set f [open $logfile r]
        puts [read $f]
        close $f
    } else {
        puts "No log file written — xsim may have crashed before opening it"
        if {$out ne ""} { puts "exec output: $out" }
    }
}

puts "run_uvm.tcl loaded. Commands: run_uvm nist | random | back2back | all"
