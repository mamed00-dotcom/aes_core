# =============================================================================
# synth_one.tcl - OOC synth (+optional P&R) of ONE AES design, appending its
# utilization and timing to results/. Driven by env vars DESIGN and DO_ROUTE.
# Invoked once per design by synth_reports.sh (separate Vivado processes for
# clean isolation).
# =============================================================================
set PART     xc7a100tcsg324-1
set design   $::env(DESIGN)
set do_route $::env(DO_ROUTE)
set TIMING   results/timing_report.txt
set UTIL     results/utilization_report.txt
set COMMON   {rtl/aes_sbox.v rtl/aes_key_expand.v rtl/aes_round.v}

switch $design {
    aes_top          { set src [concat $COMMON rtl/aes_top.v] }
    aes_pipeline_top { set src [concat $COMMON rtl/aes_pipeline_top.v] }
    aes_coproc       { set src [concat $COMMON rtl/aes_pipeline_top.v rtl/aes_coproc.v] }
    aes_axis_wrapper { set src [concat $COMMON rtl/aes_pipeline_top.v rtl/aes_axis_wrapper.v] }
    aes_dma          { set src {rtl/aes_dma.v} }
    default          { puts "unknown design $design"; exit 1 }
}

read_verilog $src
read_xdc constraints/aes_timing.xdc
synth_design -top $design -part $PART -mode out_of_context

if {$do_route} {
    opt_design
    place_design
    route_design
    set stage "POST-ROUTE"
} else {
    set stage "post-synth"
}

proc banner {file text} {
    set fh [open $file a]
    puts $fh "\n\n################################################################"
    puts $fh "#  $text"
    puts $fh "################################################################\n"
    close $fh
}

banner $UTIL "$design  -  $stage utilization (OOC, xc7a100t)"
report_utilization -file $UTIL -append

if {[llength [get_clocks]] > 0} {
    banner $TIMING "$design  -  $stage timing (OOC, xc7a100t)"
    report_timing_summary -file $TIMING -append
    # one-line Fmax derived from worst setup slack
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set per [get_property PERIOD [get_clocks sys_clk]]
    if {$wns ne ""} {
        set fmax [expr {1000.0 / ($per - $wns)}]
        set fh [open $TIMING a]
        puts $fh [format "\n  >>> %s Fmax (period %.3f ns, WNS %.3f ns) = %.1f MHz\n" $design $per $wns $fmax]
        close $fh
    }
}
puts "DONE $design ($stage)"
