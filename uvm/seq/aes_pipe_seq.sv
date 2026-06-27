`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_seq
// Description:
//   Streams `n` random plaintext blocks under a single fixed key. finish_item
//   returns as soon as the driver accepts each block, so blocks are issued
//   back-to-back - filling the pipeline and exercising in-flight checking.
//============================================================================

class aes_pipe_seq extends uvm_sequence #(aes_pipe_item);
    `uvm_object_utils(aes_pipe_seq)

    int n = 200;
    bit [127:0] fixed_key = 128'h000102030405060708090a0b0c0d0e0f;

    function new(string name = "aes_pipe_seq");
        super.new(name);
    endfunction

    task body();
        aes_pipe_item req;
        repeat (n) begin
            req = aes_pipe_item::type_id::create("req");
            start_item(req);
            if (!req.randomize())
                `uvm_error("SEQ", "randomize failed")
            req.key = fixed_key;
            finish_item(req);
        end
    endtask

endclass
