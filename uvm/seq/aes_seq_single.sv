`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_seq_single
// Description:
//   Single AES encryption: write key + plaintext, wait for result.
//============================================================================

class aes_seq_single extends aes_seq_base;
    `uvm_object_utils(aes_seq_single)

    // Allow caller to set specific key/pt
    bit [127:0] fixed_key;
    bit [127:0] fixed_pt;
    bit         use_fixed = 0;

    function new(string name = "aes_seq_single");
        super.new(name);
    endfunction

    task body();
        aes_seq_item txn;
        txn = aes_seq_item::type_id::create("txn");

        start_item(txn);
        if (use_fixed) begin
            txn.key       = fixed_key;
            txn.plaintext = fixed_pt;
        end else begin
            if (!txn.randomize())
                `uvm_fatal("SEQ", "Randomization failed!")
        end
        finish_item(txn);

        `uvm_info("SEQ", $sformatf("Single enc done: %s", txn.convert2string()), UVM_HIGH)
    endtask

endclass
