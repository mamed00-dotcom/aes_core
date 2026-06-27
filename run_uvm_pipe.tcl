# =============================================================================
# run_uvm_pipe.tcl - UVM env for the PIPELINED core (FIFO / in-flight scoreboard)
#
# Mirrors run_uvm.tcl but targets aes_pipeline_top with the streaming agent and
# the FIFO scoreboard. Leaves the original aes_top UVM env untouched.
#
# Usage (Vivado Tcl Shell, project root as working directory):
#   cd C:/Users/mamed/Desktop/aes_core
#   source run_uvm_pipe.tcl
# =============================================================================

proc xrun {args} {
    puts "\n>>> [join $args { }]"
    set cmdline [join $args { }]
    set rc [catch {exec cmd /c "$cmdline 2>&1"} out]
    if {$out ne ""} { puts $out }
    if {$rc} { error "Command failed - see output above" }
}

proc run_uvm_pipe {} {
    set vivado_root $::env(XILINX_VIVADO)
    set svdpi_inc   "$vivado_root/data/xsim/include"
    set uvm_inc     "$vivado_root/data/system_verilog/uvm_1.2"

    set rtl_src [list \
        rtl/aes_sbox.v \
        rtl/aes_key_expand.v \
        rtl/aes_round.v \
        rtl/aes_pipeline_top.v]

    # Dependency order matters (single compilation unit in xvlog)
    set uvm_src [list \
        uvm/top/aes_pipe_if.sv \
        uvm/env/aes_pipe_item.sv \
        uvm/env/aes_pipe_driver.sv \
        uvm/env/aes_pipe_monitor.sv \
        uvm/env/aes_pipe_scoreboard.sv \
        uvm/env/aes_pipe_agent.sv \
        uvm/env/aes_pipe_env.sv \
        uvm/seq/aes_pipe_seq.sv \
        uvm/test/aes_pipe_test.sv \
        uvm/top/aes_pipe_tb_top.sv]

    puts "\n\[1/4\] Compiling DPI-C golden model ..."
    xrun gcc -O2 -c -I$svdpi_inc -o uvm/dpi/aes_dpi.o uvm/dpi/aes_dpi.c
    xrun ar rcs uvm/dpi/aes_dpi.a uvm/dpi/aes_dpi.o

    puts "\n\[2/4\] Compiling SystemVerilog (xvlog) ..."
    xrun xvlog -sv -L uvm -i $uvm_inc {*}$rtl_src {*}$uvm_src

    puts "\n\[3/4\] Elaborating (xelab) ..."
    xrun xelab -sv -L uvm aes_pipe_tb_top \
        -sv_lib uvm/dpi/aes_dpi \
        -s aes_pipe_uvm_snap \
        --timescale 1ns/1ps

    puts "\n\[4/4\] Running aes_pipe_test ..."
    set xsim_exe [file join $::env(XILINX_VIVADO) bin unwrapped win64.o xsim.exe]
    catch {exec $xsim_exe aes_pipe_uvm_snap \
        --testplusarg UVM_TESTNAME=aes_pipe_test \
        --log xsim_pipe_uvm.log --runall} out
    if {[file exists xsim_pipe_uvm.log]} {
        set f [open xsim_pipe_uvm.log r]; puts [read $f]; close $f
    } else {
        puts "No log written; exec output: $out"
    }
    puts "\n=== Done (log: xsim_pipe_uvm.log) ==="
}

run_uvm_pipe
