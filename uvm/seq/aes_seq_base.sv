`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_seq_base
// Description: Base sequence — override body() in derived sequences.
//============================================================================

class aes_seq_base extends uvm_sequence #(aes_seq_item);
    `uvm_object_utils(aes_seq_base)

    function new(string name = "aes_seq_base");
        super.new(name);
    endfunction

    task body();
        `uvm_info("SEQ", "Base sequence — override in subclass", UVM_LOW)
    endtask

endclass
