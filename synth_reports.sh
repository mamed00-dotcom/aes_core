#!/usr/bin/env bash
# =============================================================================
# synth_reports.sh - regenerate results/timing_report.txt + utilization_report.txt
# for every AES variant. Runs each design in its own Vivado batch process (clean
# isolation), appending its section. aes_pipeline_top gets full place&route.
# Approach B area is measured as aes_axis_wrapper + aes_dma (synthesizing the
# full aes_stream_system OOC prunes the datapath - the buffer hides ciphertext).
# =============================================================================
set -e
export PATH="$PATH:/c/Windows/System32"
VR="${XILINX_VIVADO:-/c/Xilinx/Vivado/2024.1}"
cd "$(dirname "$0")"

# fresh report headers
{ echo "AES-128 - Timing Reports (Vivado 2024.1, xc7a100tcsg324-1, out-of-context)"
  echo "Generated $(date)"; } > results/timing_report.txt
{ echo "AES-128 - Utilization Reports (Vivado 2024.1, xc7a100tcsg324-1, out-of-context)"
  echo "Generated $(date)"; } > results/utilization_report.txt

# design : do_route(1=full P&R, 0=synth only)
for job in "aes_top:0" "aes_pipeline_top:1" "aes_coproc:0" "aes_axis_wrapper:0" "aes_dma:0"; do
    d="${job%%:*}"; r="${job##*:}"
    echo "=== synthesizing $d (route=$r) ==="
    DESIGN="$d" DO_ROUTE="$r" "$VR/bin/vivado" -mode batch -source synth_one.tcl \
        -nojournal -log "results/.vivado_$d.log" 2>&1 | grep -iE "DONE|ERROR:" | head -3 || true
done

rm -f vivado*.jou vivado*.log results/.vivado_*.log 2>/dev/null || true
echo "=== all synthesis reports regenerated ==="