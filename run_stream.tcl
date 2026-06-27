# =============================================================================
# run_stream.tcl - Compile & run the Approach-B (streaming) testbenches
#                  Phase 2a (AXI4-Stream wrapper) + Phase 2b (DMA + IRQ).
#
# Usage (from the Vivado Tcl Shell, project root as working directory):
#   cd C:/Users/mamed/Desktop/aes_core
#   source run_stream.tcl
# =============================================================================

proc xrun {args} {
    puts "\n>>> [join $args { }]"
    set cmdline [join $args { }]
    set rc [catch {exec cmd /c "$cmdline 2>&1"} out]
    if {$out ne ""} { puts $out }
    if {$rc} { error "Command failed - see output above" }
}

proc run_one {top snap} {
    set xsim_exe [file join $::env(XILINX_VIVADO) bin unwrapped win64.o xsim.exe]
    set log "xsim_${top}.log"
    puts "\n--- Simulating $top ---"
    catch {exec $xsim_exe $snap --log $log --runall} out
    if {[file exists $log]} {
        set f [open $log r]; puts [read $f]; close $f
    } else {
        puts "No log written; exec output: $out"
    }
}

proc run_stream {} {
    set vivado_root $::env(XILINX_VIVADO)
    set svdpi_inc   "$vivado_root/data/xsim/include"

    set rtl_src [list \
        rtl/aes_sbox.v \
        rtl/aes_key_expand.v \
        rtl/aes_round.v \
        rtl/aes_pipeline_top.v \
        rtl/aes_axis_wrapper.v \
        rtl/aes_dma.v \
        rtl/aes_stream_system.v]

    # DPI-C golden model
    puts "\n\[1/4\] Compiling DPI-C golden model ..."
    xrun gcc -O2 -c -I$svdpi_inc -o uvm/dpi/aes_dpi.o uvm/dpi/aes_dpi.c
    xrun ar rcs uvm/dpi/aes_dpi.a uvm/dpi/aes_dpi.o

    puts "\n\[2/4\] Compiling RTL + testbenches (xvlog) ..."
    xrun xvlog -sv {*}$rtl_src sim/tb_aes_axis.sv sim/tb_aes_dma.sv

    puts "\n\[3/4\] Elaborating ..."
    xrun xelab -sv tb_aes_axis -sv_lib uvm/dpi/aes_dpi -s axis_snap --timescale 1ns/1ps
    xrun xelab -sv tb_aes_dma  -sv_lib uvm/dpi/aes_dpi -s dma_snap  --timescale 1ns/1ps

    puts "\n\[4/4\] Running ..."
    run_one tb_aes_axis axis_snap
    run_one tb_aes_dma  dma_snap

    puts "\n=== Done ==="
}

run_stream
