`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_test_nist
// Description:
//   Directed test with NIST FIPS 197 Appendix C.1 vector.
//   Also includes all-zeros, all-ones, and key-switching vectors.
//============================================================================

class aes_test_nist extends aes_test_base;
    `uvm_component_utils(aes_test_nist)

    function new(string name = "aes_test_nist", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_single seq;

        phase.raise_objection(this);

        `uvm_info("TEST", "=== NIST Directed Test ===", UVM_LOW)

        // Test 1: NIST FIPS 197 C.1
        seq = aes_seq_single::type_id::create("nist_c1");
        seq.use_fixed = 1;
        seq.fixed_key = 128'h000102030405060708090a0b0c0d0e0f;
        seq.fixed_pt  = 128'h00112233445566778899aabbccddeeff;
        seq.start(env.agt.sqr);

        // Test 2: All-zeros
        seq = aes_seq_single::type_id::create("all_zeros");
        seq.use_fixed = 1;
        seq.fixed_key = 128'h0;
        seq.fixed_pt  = 128'h0;
        seq.start(env.agt.sqr);

        // Test 3: All-ones plaintext
        seq = aes_seq_single::type_id::create("all_ones");
        seq.use_fixed = 1;
        seq.fixed_key = 128'h000102030405060708090a0b0c0d0e0f;
        seq.fixed_pt  = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        seq.start(env.agt.sqr);

        // Test 4: Different key
        seq = aes_seq_single::type_id::create("diff_key");
        seq.use_fixed = 1;
        seq.fixed_key = 128'h2b7e151628aed2a6abf7158809cf4f3c;
        seq.fixed_pt  = 128'h00112233445566778899aabbccddeeff;
        seq.start(env.agt.sqr);

        // Test 5: CAVP ECBGFSbox128
        seq = aes_seq_single::type_id::create("cavp");
        seq.use_fixed = 1;
        seq.fixed_key = 128'h0;
        seq.fixed_pt  = 128'hf34481ec3cc627bacd5dc3fb08f273e6;
        seq.start(env.agt.sqr);

        #200;
        phase.drop_objection(this);
    endtask

endclass
