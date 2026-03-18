## =============================================================================
## AES-128 Core — Timing Constraints
## Target: Xilinx Artix-7 (xc7a100tcsg324-1)
## =============================================================================

## Clock definition: 100 MHz target (10 ns period)
## Adjust the period to find the actual Fmax
create_clock -period 10.000 -name sys_clk [get_ports clk]

## Input/output delay constraints (estimate for unconstrained I/O)
set_input_delay -clock sys_clk 2.0 [all_inputs]
set_output_delay -clock sys_clk 2.0 [all_outputs]

## Remove timing on reset (async by nature of system)
set_false_path -from [get_ports rst_n]
