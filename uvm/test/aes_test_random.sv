`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_test_random
// Description:
//   Constrained random test — runs 100 random encryptions.
//   All results checked via DPI-C scoreboard.
//============================================================================

class aes_test_random extends aes_test_base;
    `uvm_component_utils(aes_test_random)

    int num_tests = 100;

    function new(string name = "aes_test_random", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_back2back seq;

        phase.raise_objection(this);

        `uvm_info("TEST", $sformatf("=== Random Test: %0d vectors ===", num_tests), UVM_LOW)

        seq = aes_seq_back2back::type_id::create("rand_seq");
        seq.num_transactions = num_tests;
        seq.start(env.agt.sqr);

        #200;
        phase.drop_objection(this);
    endtask

endclass
