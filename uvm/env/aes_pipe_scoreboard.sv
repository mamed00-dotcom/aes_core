`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_scoreboard
// Description:
//   FIFO (in-flight) scoreboard for the pipelined AES core. This is the
//   adaptation of the original single-compare scoreboard:
//
//     write_in  (input observed) : golden = aes_encrypt_dpi(key, pt);
//                                  expected_q.push_back(golden);
//     write_out (output observed): exp = expected_q.pop_front();
//                                  compare against ciphertext;
//
//   The DPI-C golden model is UNCHANGED from the iterative-core scoreboard -
//   only the bookkeeping moves from one-at-a-time to a queue. Strict order
//   preservation in the pipeline makes a plain FIFO sufficient (no IDs).
//
//   Two analysis imports are created with `uvm_analysis_imp_decl so a single
//   component can receive both the input and output streams.
//============================================================================

import "DPI-C" function void aes_encrypt_dpi(
    input  bit [127:0] key_in,
    input  bit [127:0] pt_in,
    output bit [127:0] ct_out
);

`uvm_analysis_imp_decl(_in)
`uvm_analysis_imp_decl(_out)

class aes_pipe_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(aes_pipe_scoreboard)

    uvm_analysis_imp_in  #(aes_pipe_item, aes_pipe_scoreboard) ap_in;
    uvm_analysis_imp_out #(aes_pipe_item, aes_pipe_scoreboard) ap_out;

    // In-flight expected ciphertexts, oldest first
    bit [127:0] expected_q [$];

    int in_count    = 0;
    int out_count   = 0;
    int pass_count  = 0;
    int fail_count  = 0;
    int max_inflight = 0;     // peak queue depth observed (should reach ~10)

    function new(string name = "aes_pipe_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap_in  = new("ap_in", this);
        ap_out = new("ap_out", this);
    endfunction

    // ---- Input observed: push expected result ----
    function void write_in(aes_pipe_item t);
        bit [127:0] golden;
        in_count++;
        aes_encrypt_dpi(t.key, t.plaintext, golden);
        expected_q.push_back(golden);
        if (expected_q.size() > max_inflight)
            max_inflight = expected_q.size();
    endfunction

    // ---- Output observed: pop expected and compare ----
    function void write_out(aes_pipe_item t);
        bit [127:0] exp;
        out_count++;
        if (expected_q.size() == 0) begin
            `uvm_error("SCB", $sformatf("[%0d] output with empty expected FIFO: CT=%032h",
                       out_count, t.ciphertext))
            fail_count++;
            return;
        end
        exp = expected_q.pop_front();
        if (t.ciphertext === exp) begin
            pass_count++;
            `uvm_info("SCB", $sformatf("[PASS %0d] CT=%032h (inflight=%0d)",
                      out_count, t.ciphertext, expected_q.size()), UVM_HIGH)
        end else begin
            fail_count++;
            `uvm_error("SCB", $sformatf("[FAIL %0d] exp=%032h got=%032h",
                       out_count, exp, t.ciphertext))
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("SCB", "======================================================", UVM_NONE)
        `uvm_info("SCB", $sformatf("  PIPELINE SCOREBOARD: %0d/%0d passed", pass_count, out_count), UVM_NONE)
        `uvm_info("SCB", $sformatf("  inputs=%0d outputs=%0d peak in-flight=%0d",
                  in_count, out_count, max_inflight), UVM_NONE)
        if (expected_q.size() != 0)
            `uvm_error("SCB", $sformatf("  %0d expected results never arrived", expected_q.size()))
        if (fail_count == 0 && expected_q.size() == 0 && out_count > 0)
            `uvm_info("SCB", "  *** ALL CHECKS PASSED ***", UVM_NONE)
        else
            `uvm_error("SCB", "  *** FAILURE(S) DETECTED ***")
        `uvm_info("SCB", "======================================================", UVM_NONE)
    endfunction

endclass
