`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_test_idle_loop
// Description:
//   Runs aes_seq_idle_loop three times so the coverage sampler sees both
//   IDLE->IDLE (at startup) and DONE->DONE (if following another test)
//   across enough clock edges to reliably hit the missing transition bins.
//============================================================================

class aes_test_idle_loop extends aes_test_base;
    `uvm_component_utils(aes_test_idle_loop)

    function new(string name = "aes_test_idle_loop", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_idle_loop seq;
        int i;

        phase.raise_objection(this);
        `uvm_info("TEST", "=== Idle Loop Test: FSM self-loop coverage ===", UVM_LOW)

        for (i = 0; i < 3; i++) begin
            seq = aes_seq_idle_loop::type_id::create($sformatf("idle_%0d", i));
            seq.num_idle_cycles = 5;
            seq.start(env.agt.sqr);
            `uvm_info("TEST", $sformatf("Idle pass %0d/3 complete", i + 1), UVM_LOW)
        end

        #200;
        phase.drop_objection(this);
    endtask

endclass
