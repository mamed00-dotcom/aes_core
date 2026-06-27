# =============================================================================
# run_pipeline.tcl - Compile & run the pipelined AES core testbench (Phase 1)
#
# Mirrors the DPI/xsim flow of run_uvm.tcl but targets the standalone
# self-checking testbench tb_aes_pipeline.sv (no UVM, no AXI - pure pipeline).
#
# Usage (from the Vivado Tcl Shell, project root as working directory):
#   cd C:/Users/mamed/Desktop/aes_core
#   source run_pipeline.tcl
# =============================================================================

proc xrun {args} {
    puts "\n>>> [join $args { }]"
    set cmdline [join $args { }]
    set rc [catch {exec cmd /c "$cmdline 2>&1"} out]
    if {$out ne ""} { puts $out }
    if {$rc} { error "Command failed - see output above" }
}

proc run_pipeline {} {
    set vivado_root $::env(XILINX_VIVADO)
    set svdpi_inc   "$vivado_root/data/xsim/include"

    set rtl_src [list \
        rtl/aes_sbox.v \
        rtl/aes_key_expand.v \
        rtl/aes_round.v \
        rtl/aes_pipeline_top.v]

    set tb_src sim/tb_aes_pipeline.sv

    # Step 1 - DPI-C golden model (same object the UVM scoreboard uses)
    puts "\n\[1/4\] Compiling DPI-C golden model ..."
    xrun gcc -O2 -c -I$svdpi_inc -o uvm/dpi/aes_dpi.o uvm/dpi/aes_dpi.c
    xrun ar rcs uvm/dpi/aes_dpi.a uvm/dpi/aes_dpi.o

    # Step 2 - Compile RTL + TB
    puts "\n\[2/4\] Compiling (xvlog) ..."
    xrun xvlog -sv {*}$rtl_src $tb_src

    # Step 3 - Elaborate with DPI lib
    puts "\n\[3/4\] Elaborating (xelab) ..."
    xrun xelab -sv tb_aes_pipeline \
        -sv_lib uvm/dpi/aes_dpi \
        -s aes_pipe_snap \
        --timescale 1ns/1ps

    # Step 4 - Simulate
    puts "\n\[4/4\] Running tb_aes_pipeline ..."
    set xsim_exe [file join $::env(XILINX_VIVADO) bin unwrapped win64.o xsim.exe]
    catch {exec $xsim_exe aes_pipe_snap --log xsim_pipeline.log --runall} out
    if {[file exists xsim_pipeline.log]} {
        set f [open xsim_pipeline.log r]
        puts [read $f]
        close $f
    } else {
        puts "No log written - xsim may have crashed"
        if {$out ne ""} { puts "exec output: $out" }
    }
    puts "\n=== Done (log: xsim_pipeline.log) ==="
}

run_pipeline
