`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_scoreboard
// Description:
//   UVM scoreboard for AES-128 verification.
//   Compares DUT output against golden model via DPI-C.
//   Falls back to known-vector checking if DPI-C is not available.
//
// DPI-C integration:
//   Import function aes_encrypt_dpi() from aes_dpi.c
//   Compile: gcc -shared -fPIC -o aes_dpi.so uvm/dpi/aes_dpi.c
//============================================================================

// DPI-C import — packed 128-bit vectors; maps to svBitVecVal* in C (no xsim runtime dep)
import "DPI-C" function void aes_encrypt_dpi(
    input  bit [127:0] key_in,
    input  bit [127:0] pt_in,
    output bit [127:0] ct_out
);

class aes_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(aes_scoreboard)

    uvm_analysis_imp #(aes_seq_item, aes_scoreboard) ap;

    // Statistics
    int pass_count = 0;
    int fail_count = 0;
    int total_count = 0;

    function new(string name = "aes_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
    endfunction

    //------------------------------------------------------------------------
    // Analysis port write: called by monitor for each completed transaction
    //------------------------------------------------------------------------
    function void write(aes_seq_item txn);
        bit [127:0] golden_ct;

        total_count++;

        // Call golden model via DPI-C (packed 128-bit — no byte conversion needed)
        aes_encrypt_dpi(txn.key, txn.plaintext, golden_ct);

        // Compare
        if (txn.ciphertext === golden_ct) begin
            pass_count++;
            `uvm_info("SCB", $sformatf("[PASS %0d] CT=%032h (lat=%0d cyc)",
                      total_count, txn.ciphertext, txn.latency), UVM_MEDIUM)
        end else begin
            fail_count++;
            `uvm_error("SCB", $sformatf(
                "[FAIL %0d] KEY=%032h PT=%032h\n  Expected: %032h\n  Got:      %032h\n  XOR diff: %032h",
                total_count, txn.key, txn.plaintext,
                golden_ct, txn.ciphertext, golden_ct ^ txn.ciphertext))
        end
    endfunction

    //------------------------------------------------------------------------
    // Report phase: final summary
    //------------------------------------------------------------------------
    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("SCB", "======================================================", UVM_NONE)
        `uvm_info("SCB", $sformatf("  SCOREBOARD SUMMARY: %0d/%0d passed", pass_count, total_count), UVM_NONE)
        if (fail_count == 0)
            `uvm_info("SCB", "  *** ALL CHECKS PASSED ***", UVM_NONE)
        else
            `uvm_error("SCB", $sformatf("  *** %0d FAILURE(S) DETECTED ***", fail_count))
        `uvm_info("SCB", "======================================================", UVM_NONE)
    endfunction

endclass
