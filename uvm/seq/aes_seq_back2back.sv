`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_seq_back2back
// Description:
//   Send N encryptions back-to-back without gaps.
//   Tests FSM DONE->KEY_EXPAND transition.
//============================================================================

class aes_seq_back2back extends aes_seq_base;
    `uvm_object_utils(aes_seq_back2back)

    int num_transactions = 10;

    function new(string name = "aes_seq_back2back");
        super.new(name);
    endfunction

    task body();
        aes_seq_item txn;
        int i;

        `uvm_info("SEQ", $sformatf("Starting %0d back-to-back encryptions", num_transactions), UVM_LOW)

        for (i = 0; i < num_transactions; i++) begin
            txn = aes_seq_item::type_id::create($sformatf("txn_%0d", i));
            start_item(txn);
            if (!txn.randomize())
                `uvm_fatal("SEQ", "Randomization failed!")
            finish_item(txn);
        end

        `uvm_info("SEQ", "Back-to-back sequence complete", UVM_LOW)
    endtask

endclass
