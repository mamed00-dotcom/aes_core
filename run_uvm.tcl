# =============================================================================
# run_uvm.tcl — Run AES-128 UVM tests from the Vivado Tcl Shell
#
# Usage (from Vivado Tcl Shell, with project root as working directory):
#   cd C:/Users/mamed/Desktop/aes_core
#   source run_uvm.tcl
#   run_uvm nist        ;# Phase 1 — NIST directed vectors
#   run_uvm random      ;# Phase 2a — 100 vectors (forced patterns + random)
#   run_uvm back2back   ;# Phase 2b — 50 stress vectors
#   run_uvm idle_loop   ;# Phase 2c — FSM self-loop coverage
#   run_uvm all         ;# All four suites
# =============================================================================

# --------------------------------------------------------------------------
# Helper: run a shell command, show output, stop on error.
# --------------------------------------------------------------------------
proc xrun {args} {
    puts "\n>>> [join $args { }]"
    set cmdline [join $args { }]
    set rc [catch {exec cmd /c "$cmdline 2>&1"} out]
    if {$out ne ""} { puts $out }
    if {$rc} { error "Command failed — see output above" }
}

# --------------------------------------------------------------------------
# Parse one xsim log file and return a dict with key result fields.
# --------------------------------------------------------------------------
proc parse_log {logfile} {
    set result [dict create \
        passed   "?" \
        total    "?" \
        errors   "?" \
        fatals   "?" \
        status   "UNKNOWN" \
        coverage {}]

    if {![file exists $logfile]} { return $result }

    set f [open $logfile r]
    set content [read $f]
    close $f

    foreach line [split $content \n] {
        # Scoreboard summary:  "SCOREBOARD SUMMARY: 5/5 passed"
        if {[regexp {SCOREBOARD SUMMARY:\s+(\d+)/(\d+) passed} $line -> p t]} {
            dict set result passed $p
            dict set result total  $t
        }
        # ALL CHECKS PASSED
        if {[string match "*ALL CHECKS PASSED*" $line]} {
            dict set result status "PASS"
        }
        # FAILURE(S) DETECTED
        if {[string match "*FAILURE(S) DETECTED*" $line]} {
            dict set result status "FAIL"
        }
        # UVM error/fatal counts:  "UVM_ERROR :    0"
        if {[regexp {UVM_ERROR\s*:\s*(\d+)} $line -> n]} {
            dict set result errors $n
        }
        if {[regexp {UVM_FATAL\s*:\s*(\d+)} $line -> n]} {
            dict set result fatals $n
        }
        # Coverage lines — [^:]* handles multi-word names like "FSM Transitions"
        if {[regexp {(FSM|Round|State|Key|PT|Operations|Plaintext)[^:]*:\s+[\d.]+%} $line]} {
            dict lappend result coverage [string trim $line]
        }
    }
    return $result
}

# --------------------------------------------------------------------------
# Write consolidated results to results/uvm_results.txt
# --------------------------------------------------------------------------
proc write_results_file {test_results} {
    set results_dir "results"
    if {![file isdirectory $results_dir]} { file mkdir $results_dir }

    set outfile "$results_dir/uvm_results.txt"
    set f [open $outfile w]

    set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    puts $f "============================================================"
    puts $f "  AES-128 UVM Verification Results"
    puts $f "  Run: $ts"
    puts $f "  Tool: Vivado xsim  |  UVM 1.2"
    puts $f "============================================================"
    puts $f ""

    set total_pass 0
    set total_vecs 0
    set overall "PASS"
    set all_coverage {}

    foreach {testname result} $test_results {
        set p [dict get $result passed]
        set t [dict get $result total]
        set s [dict get $result status]
        set e [dict get $result errors]
        set fa [dict get $result fatals]

        if {$p ne "?" && $t ne "?"} {
            incr total_pass $p
            incr total_vecs $t
        }
        if {$s eq "FAIL"} { set overall "FAIL" }

        puts $f "------------------------------------------------------------"
        puts $f "  Test : $testname"
        puts $f "  Score: $p / $t passed"
        puts $f "  Status: $s"
        puts $f "  UVM_ERROR: $e   UVM_FATAL: $fa"
        puts $f ""

        # Prefer coverage from the comprehensive aes_test_random run; it is the
        # one driven to 100%. Other tests (e.g. idle_loop) are targeted micro-
        # tests whose standalone coverage is intentionally partial.
        set cov [dict get $result coverage]
        if {[llength $cov] > 0} {
            if {$testname eq "aes_test_random" || [llength $all_coverage] == 0} {
                set all_coverage $cov
            }
        }
    }

    puts $f "============================================================"
    puts $f "  OVERALL : $overall"
    puts $f "  TOTAL   : $total_pass / $total_vecs vectors passed"
    puts $f "============================================================"

    if {[llength $all_coverage] > 0} {
        puts $f ""
        puts $f "  FUNCTIONAL COVERAGE (aes_test_random)"
        puts $f "  ----------------------------------"
        foreach line $all_coverage {
            puts $f "  $line"
        }
    }

    puts $f ""
    puts $f "============================================================"
    close $f

    puts "\n  Results saved to: $outfile"
    return $outfile
}

# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------
proc run_uvm {{test nist}} {

    set vivado_root $::env(XILINX_VIVADO)
    set svdpi_inc   "$vivado_root/data/xsim/include"

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
        uvm/seq/aes_seq_idle_loop.sv \
        uvm/seq/aes_seq_keyswitch.sv \
        uvm/test/aes_test_base.sv \
        uvm/test/aes_test_nist.sv \
        uvm/test/aes_test_random.sv \
        uvm/test/aes_test_back2back.sv \
        uvm/test/aes_test_idle_loop.sv \
        uvm/top/aes_tb_top.sv]

    # Step 1 — DPI-C
    puts "\n\[1/3\] Compiling DPI-C golden model ..."
    xrun gcc -O2 -c \
        -I$svdpi_inc \
        -o uvm/dpi/aes_dpi.o \
        uvm/dpi/aes_dpi.c
    xrun ar rcs uvm/dpi/aes_dpi.a uvm/dpi/aes_dpi.o
    puts "      Done: uvm/dpi/aes_dpi.a"

    set uvm_inc "$vivado_root/data/system_verilog/uvm_1.2"

    # Step 2 — Compile
    puts "\n\[2/3\] Compiling SystemVerilog (xvlog) ..."
    xrun xvlog -sv -L uvm -i $uvm_inc {*}$rtl_src {*}$uvm_src

    # Step 3 — Elaborate
    puts "\n\[3/3\] Elaborating (xelab) ..."
    xrun xelab -sv -L uvm aes_tb_top \
        -sv_lib uvm/dpi/aes_dpi \
        -s aes_uvm_snap \
        --timescale 1ns/1ps

    # Step 4 — Simulate
    puts "\n\[4/4\] Running test(s): $test"

    set test_results {}

    if {$test eq "all"} {
        foreach t {aes_test_nist aes_test_random aes_test_back2back aes_test_idle_loop} {
            run_one_test $t
            lappend test_results $t [parse_log "xsim_${t}.log"]
        }
    } else {
        set tname "aes_test_$test"
        run_one_test $tname
        lappend test_results $tname [parse_log "xsim_${tname}.log"]
    }

    # Write results file
    write_results_file $test_results

    puts "\n=== Done ==="
}

proc run_one_test {testname} {
    puts "\n--- $testname ---"
    set xsim_exe [file join $::env(XILINX_VIVADO) bin unwrapped win64.o xsim.exe]
    set logfile  "xsim_${testname}.log"
    set plusarg  "UVM_TESTNAME=$testname"
    puts ">>> xsim aes_uvm_snap --testplusarg $plusarg --runall  (log: $logfile)"
    catch {exec $xsim_exe aes_uvm_snap \
        --testplusarg $plusarg \
        --log $logfile \
        --runall} out
    if {[file exists $logfile]} {
        set f [open $logfile r]
        puts [read $f]
        close $f
    } else {
        puts "No log file written — xsim may have crashed"
        if {$out ne ""} { puts "exec output: $out" }
    }
}

puts "run_uvm.tcl loaded. Commands: run_uvm nist | random | back2back | idle_loop | all"
