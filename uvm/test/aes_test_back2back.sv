`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_test_back2back
// Description:
//   Stress test: rapid back-to-back encryptions with random data.
//   Verifies FSM handles DONE→KEY_EXPAND transitions cleanly.
//============================================================================

class aes_test_back2back extends aes_test_base;
    `uvm_component_utils(aes_test_back2back)

    function new(string name = "aes_test_back2back", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_single   nist_seq;
        aes_seq_back2back b2b_seq;

        phase.raise_objection(this);

        `uvm_info("TEST", "=== Back-to-Back Stress Test ===", UVM_LOW)

        // First: one directed encryption to prime the FSM
        nist_seq = aes_seq_single::type_id::create("primer");
        nist_seq.use_fixed = 1;
        nist_seq.fixed_key = 128'h000102030405060708090a0b0c0d0e0f;
        nist_seq.fixed_pt  = 128'h00112233445566778899aabbccddeeff;
        nist_seq.start(env.agt.sqr);

        // Then: 50 back-to-back random encryptions
        b2b_seq = aes_seq_back2back::type_id::create("b2b");
        b2b_seq.num_transactions = 50;
        b2b_seq.start(env.agt.sqr);

        #200;
        phase.drop_objection(this);
    endtask

endclass
