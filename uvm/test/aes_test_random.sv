`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_test_random
// Description:
//   Random + guaranteed-pattern test. Forces corner-case key/plaintext
//   patterns for full coverage, then runs unconstrained random vectors.
//   All results checked via DPI-C scoreboard.
//
//   Pattern 1 : all-zeros  key + all-zeros  plaintext
//   Pattern 2 : all-ones   key + all-ones   plaintext
//   Pattern 3 : NIST       key + NIST       plaintext
//   Pattern 4 : key-switch (10 paired A,A,B,B encryptions)
//   Pattern 5 : 87 unconstrained random      -> total 100 vectors
//============================================================================

class aes_test_random extends aes_test_base;
    `uvm_component_utils(aes_test_random)

    int num_random = 87;

    function new(string name = "aes_test_random", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_single    seq_single;
        aes_seq_keyswitch seq_ks;
        aes_seq_back2back  seq_random;

        phase.raise_objection(this);
        `uvm_info("TEST", "=== Random Test: forced patterns + random vectors ===", UVM_LOW)

        // Pattern 1: all-zeros key + plaintext
        seq_single = aes_seq_single::type_id::create("all_zero");
        seq_single.use_fixed = 1;
        seq_single.fixed_key = 128'h0;
        seq_single.fixed_pt  = 128'h0;
        seq_single.start(env.agt.sqr);
        `uvm_info("TEST", "Pattern 1 complete: 1 vector (all-zeros)", UVM_LOW)

        // Pattern 2: all-ones key + all-ones plaintext
        seq_single = aes_seq_single::type_id::create("all_ones");
        seq_single.use_fixed = 1;
        seq_single.fixed_key = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        seq_single.fixed_pt  = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        seq_single.start(env.agt.sqr);
        `uvm_info("TEST", "Pattern 2 complete: 1 vector (all-ones key+pt)", UVM_LOW)

        // Pattern 3: NIST key + NIST plaintext (hits nist_key and nist_pt bins)
        seq_single = aes_seq_single::type_id::create("nist_vec");
        seq_single.use_fixed = 1;
        seq_single.fixed_key = 128'h000102030405060708090a0b0c0d0e0f;
        seq_single.fixed_pt  = 128'h00112233445566778899aabbccddeeff;
        seq_single.start(env.agt.sqr);
        `uvm_info("TEST", "Pattern 3 complete: 1 vector (NIST key+pt)", UVM_LOW)

        // Pattern 4: key-switch (operations coverage)
        seq_ks = aes_seq_keyswitch::type_id::create("keyswitch_test");
        seq_ks.num_switches = 10;
        seq_ks.start(env.agt.sqr);
        `uvm_info("TEST", "Pattern 4 complete: 10 vectors (key-switch)", UVM_LOW)

        // Pattern 5: unconstrained random
        seq_random = aes_seq_back2back::type_id::create("rand_seq");
        seq_random.num_transactions = num_random;
        seq_random.start(env.agt.sqr);
        `uvm_info("TEST", $sformatf("Pattern 5 complete: %0d vectors (random)", num_random), UVM_LOW)

        #200;
        phase.drop_objection(this);
    endtask

endclass
