# =============================================================================
# create_project.tcl - build a browsable Vivado IDE project for the whole
# AES-128 core work (iterative core, pipelined core, streaming, coprocessor,
# the Wishbone->AXI4-Lite bridge, and the NEORV32 SoC top), plus the
# testbenches and constraints.
#
# Usage (from the project root):
#   vivado -mode batch -source create_project.tcl     # create it
#   then open  vivado_project/aes_core.xpr  in the GUI
# or directly:
#   vivado -source create_project.tcl                 # create + open in GUI
#
# The NEORV32 SoC top needs the external NEORV32 clone; set NEORV32_HOME if it
# is not at the default path below.
# =============================================================================

set proj_name aes_core
set proj_dir  [file join [pwd] vivado_project]
set part      xc7a100tcsg324-1

create_project $proj_name $proj_dir -part $part -force

# ---- Design sources: all local RTL (Verilog) ----
add_files -norecurse [glob rtl/*.v]

# ---- The NEORV32 SoC top (VHDL-2008) ----
if {[file exists rtl/neorv32_aes_soc.vhd]} {
    add_files -norecurse rtl/neorv32_aes_soc.vhd
    set_property file_type {VHDL 2008} [get_files rtl/neorv32_aes_soc.vhd]
}

# ---- NEORV32 (external clone) compiled into library 'neorv32' so the SoC
#      elaborates. Uses NEORV32's own file_list_soc.f for the correct set. ----
set neorv32_home [expr {[info exists ::env(NEORV32_HOME)] ? $::env(NEORV32_HOME) \
                                                          : "C:/Users/mamed/Desktop/neorv32"}]
if {[file exists $neorv32_home/rtl/file_list_soc.f]} {
    set fh [open $neorv32_home/rtl/file_list_soc.f r]
    foreach line [split [read $fh] "\n"] {
        set f [string map [list {$NEORV32_HOME} $neorv32_home] [string trim $line]]
        if {$f ne "" && [file exists $f]} {
            add_files -norecurse $f
            set_property library   neorv32        [get_files $f]
            set_property file_type {VHDL 2008}    [get_files $f]
        }
    }
    close $fh
    puts "INFO: NEORV32 sources added into library 'neorv32'."
} else {
    puts "NOTE: NEORV32 clone not found at '$neorv32_home'."
    puts "      The neorv32_aes_soc top will not elaborate until you set NEORV32_HOME."
}

# ---- Constraints ----
add_files -fileset constrs_1 -norecurse constraints/aes_timing.xdc

# ---- Simulation sources: self-checking testbenches + DPI-C golden model ----
add_files -fileset sim_1 -norecurse [glob sim/*.sv]
if {[file exists uvm/dpi/aes_dpi.c]} {
    add_files -fileset sim_1 -norecurse uvm/dpi/aes_dpi.c
}

# ---- Default tops (change in the GUI Flow Navigator any time) ----
#   synth/impl top : aes_coproc   (the full AXI4-Lite AES coprocessor)
#   simulation top : tb_aes_trace (clean, self-checking, no external deps)
set_property top aes_coproc   [get_filesets sources_1]
set_property top tb_aes_trace [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "\n========================================================"
puts "  Project created: $proj_dir/$proj_name.xpr"
puts "  Open it:  vivado $proj_dir/$proj_name.xpr"
puts "  Synth top = aes_coproc ; Sim top = tb_aes_trace"
puts "  (switch top to neorv32_aes_soc / tb_neorv32_aes for the full SoC)"
puts "========================================================"
