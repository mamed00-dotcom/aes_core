`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_seq_item
// Description:
//   UVM sequence item representing a single AES-128 transaction.
//   Contains stimulus (key, plaintext) and response (ciphertext).
//============================================================================

class aes_seq_item extends uvm_sequence_item;
    `uvm_object_utils(aes_seq_item)

    // Stimulus fields (randomizable)
    rand bit [127:0] key;
    rand bit [127:0] plaintext;

    // Response fields (set by monitor, not randomized)
    bit [127:0] ciphertext;
    int         latency;        // Cycles from start to valid

    //------------------------------------------------------------------------
    // Constraints
    //------------------------------------------------------------------------

    // Default: fully unconstrained (all bytes 0-255)
    // Override in specific sequences for targeted patterns

    // Constraint: Ensure at least some byte diversity
    constraint c_not_trivial {
        // Soft constraint: prefer non-trivial inputs
        soft (key != 128'h0);
        soft (plaintext != 128'h0);
    }

    //------------------------------------------------------------------------
    // Standard UVM methods
    //------------------------------------------------------------------------
    function new(string name = "aes_seq_item");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf("KEY=%032h PT=%032h CT=%032h LAT=%0d",
                         key, plaintext, ciphertext, latency);
    endfunction

    function void do_copy(uvm_object rhs);
        aes_seq_item rhs_item;
        super.do_copy(rhs);
        if (!$cast(rhs_item, rhs))
            `uvm_fatal("CAST", "Failed to cast rhs to aes_seq_item")
        key        = rhs_item.key;
        plaintext  = rhs_item.plaintext;
        ciphertext = rhs_item.ciphertext;
        latency    = rhs_item.latency;
    endfunction

    function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        aes_seq_item rhs_item;
        if (!$cast(rhs_item, rhs)) return 0;
        return (key       == rhs_item.key       &&
                plaintext == rhs_item.plaintext  &&
                ciphertext== rhs_item.ciphertext);
    endfunction

endclass
