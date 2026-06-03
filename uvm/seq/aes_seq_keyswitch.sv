`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_seq_keyswitch
// Description:
//   Drives keys in A,A,B,B pairs on back-to-back encryptions. The repeated
//   key gives the (back2back, same_key) operations bin; the change at each
//   pair boundary gives (back2back, new_key).
//   key_A = NIST FIPS-197 Appendix C.1 key
//   key_B = NIST FIPS-197 Appendix B   key
//============================================================================

class aes_seq_keyswitch extends aes_seq_base;
    `uvm_object_utils(aes_seq_keyswitch)

    int num_switches = 10;

    function new(string name = "aes_seq_keyswitch");
        super.new(name);
    endfunction

    task body();
        aes_seq_item txn;
        bit [127:0]  keys[2];
        bit [127:0]  fixed_pt;
        int i;
        int sel;

        keys[0]  = 128'h000102030405060708090a0b0c0d0e0f; // Key A — NIST C.1
        keys[1]  = 128'h2b7e151628aed2a6abf7158809cf4f3c; // Key B — NIST B
        fixed_pt = 128'h12345678123456781234567812345678;

        `uvm_info("SEQ", $sformatf("Key-switch: %0d alternating encryptions (A/B)", num_switches), UVM_LOW)

        // A,A,B,B pairs: (i/2)%2 selects key, repeating each key twice so a
        // same_key back-to-back occurs within a pair and a new_key at the boundary.
        for (i = 0; i < num_switches; i++) begin
            sel = (i / 2) % 2;
            txn = aes_seq_item::type_id::create($sformatf("ks_%0d", i));
            start_item(txn);
            txn.key       = keys[sel];
            txn.plaintext = fixed_pt;
            finish_item(txn);
            `uvm_info("SEQ", $sformatf("[%0d] Key %s", i, (sel == 0) ? "A (NIST C.1)" : "B (NIST B)"), UVM_MEDIUM)
        end

        `uvm_info("SEQ", "Key-switch sequence complete", UVM_LOW)
    endtask

endclass
