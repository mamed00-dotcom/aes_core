`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_seq_idle_loop
// Description:
//   Exercises FSM self-loop transitions (IDLE→IDLE, DONE→DONE) by holding
//   start=0 for num_idle_cycles clock cycles. No stimulus is driven —
//   the driver stays idle, the DUT stays in whatever state it's in.
//   Used by aes_test_idle_loop to achieve 100% FSM transition coverage.
//============================================================================

class aes_seq_idle_loop extends aes_seq_base;
    `uvm_object_utils(aes_seq_idle_loop)

    int num_idle_cycles = 5;

    function new(string name = "aes_seq_idle_loop");
        super.new(name);
    endfunction

    task body();
        int i;
        `uvm_info("SEQ", $sformatf("Idle loop starting (%0d cycles, no stimulus)",
                  num_idle_cycles), UVM_LOW)
        for (i = 1; i <= num_idle_cycles; i++) begin
            `uvm_info("SEQ", $sformatf("Idle loop: cycle %0d", i), UVM_MEDIUM)
            #10; // 10ns = 1 clock cycle at 100 MHz
        end
        `uvm_info("SEQ", $sformatf("Idle loop complete (%0d cycles)", num_idle_cycles), UVM_LOW)
    endtask

endclass
