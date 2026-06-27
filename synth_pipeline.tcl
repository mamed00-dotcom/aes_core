# =============================================================================
# synth_pipeline.tcl - Area + Fmax measurement for the pipelined AES (Phase 4 data)
#
# Run (background): vivado -mode batch -source synth_pipeline.tcl
#
#   Target 1: aes_pipeline_top   - full synth+place+route -> real Fmax + area
#   Target 2: aes_stream_system  - synth-only utilization (system area)
# =============================================================================

set PART xc7a100tcsg324-1

set CORE_SRC {
    rtl/aes_sbox.v
    rtl/aes_key_expand.v
    rtl/aes_round.v
    rtl/aes_pipeline_top.v
}
set SYS_SRC {
    rtl/aes_sbox.v
    rtl/aes_key_expand.v
    rtl/aes_round.v
    rtl/aes_pipeline_top.v
    rtl/aes_axis_wrapper.v
    rtl/aes_dma.v
    rtl/aes_stream_system.v
}

# Helper: compute Fmax from the worst-case setup path of the clock.
proc report_fmax {clkname} {
    set period [get_property PERIOD [get_clocks $clkname]]
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    if {$wns eq ""} { puts "  Fmax: (no timing paths)"; return }
    set achieved [expr {$period - $wns}]
    set fmax [expr {1000.0 / $achieved}]
    puts [format "  Clock period constraint : %.3f ns" $period]
    puts [format "  WNS (setup slack)       : %.3f ns" $wns]
    puts [format "  Achieved path delay     : %.3f ns" $achieved]
    puts [format "  >>> Fmax (post-route)   : %.1f MHz" $fmax]
}

# -----------------------------------------------------------------------------
# Target 1 - pipelined core, full implementation
# -----------------------------------------------------------------------------
puts "\n=================  aes_pipeline_top : OOC implementation  ================="
# Out-of-context: this is an IP block, not a top-level chip - no I/O buffers,
# no package-pin placement (the 128-bit buses are internal fabric nets).
read_verilog $CORE_SRC
read_xdc constraints/aes_timing.xdc
synth_design -top aes_pipeline_top -part $PART -mode out_of_context

puts "\n----- aes_pipeline_top UTILIZATION (post-synth) -----"
report_utilization

opt_design
place_design
route_design

puts "\n----- aes_pipeline_top UTILIZATION (post-route) -----"
report_utilization
puts "\n----- aes_pipeline_top TIMING -----"
report_fmax sys_clk

# -----------------------------------------------------------------------------
# Target 2 - full streaming system, synthesis utilization
# -----------------------------------------------------------------------------
puts "\n=================  aes_stream_system : synthesis utilization  ================="
read_verilog $SYS_SRC
read_xdc constraints/aes_timing.xdc
synth_design -top aes_stream_system -part $PART -mode out_of_context

puts "\n----- aes_stream_system UTILIZATION -----"
report_utilization

puts "\n=== synth_pipeline.tcl done ==="
