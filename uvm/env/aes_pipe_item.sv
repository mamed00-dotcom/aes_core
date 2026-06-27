`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_item
// Description:
//   Sequence/analysis item for the pipelined AES env. Carries the fixed key
//   and a plaintext block as stimulus; ciphertext is filled by the monitor
//   on output observation. The same type is used on both monitor analysis
//   ports (input-observed and output-observed).
//============================================================================

class aes_pipe_item extends uvm_sequence_item;
    `uvm_object_utils(aes_pipe_item)

    rand bit [127:0] plaintext;
    bit [127:0]      key;          // fixed key (set by sequence/driver)
    bit [127:0]      ciphertext;   // filled by monitor on output

    constraint c_nontrivial { soft plaintext != 128'h0; }

    function new(string name = "aes_pipe_item");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf("KEY=%032h PT=%032h CT=%032h", key, plaintext, ciphertext);
    endfunction

    function void do_copy(uvm_object rhs);
        aes_pipe_item r;
        super.do_copy(rhs);
        if (!$cast(r, rhs)) `uvm_fatal("CAST", "bad rhs")
        plaintext  = r.plaintext;
        key        = r.key;
        ciphertext = r.ciphertext;
    endfunction

endclass
