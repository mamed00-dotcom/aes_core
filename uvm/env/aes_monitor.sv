`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_monitor
// Description:
//   Passive UVM monitor. Observes DUT interface, captures transactions
//   when valid asserts, and broadcasts to scoreboard/coverage via TLM.
//============================================================================

class aes_monitor extends uvm_monitor;
    `uvm_component_utils(aes_monitor)

    virtual aes_if vif;
    uvm_analysis_port #(aes_seq_item) ap;

    function new(string name = "aes_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db#(virtual aes_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_item txn;
        int cyc_cnt;

        forever begin
            // Wait for start pulse
            @(vif.mon_cb);
            if (vif.mon_cb.start) begin
                txn = aes_seq_item::type_id::create("mon_txn");
                txn.key       = vif.mon_cb.key;
                txn.plaintext = vif.mon_cb.plaintext;
                cyc_cnt = 0;

                // Wait for valid
                do begin
                    @(vif.mon_cb);
                    cyc_cnt++;
                end while (!vif.mon_cb.valid && cyc_cnt < 60);

                txn.ciphertext = vif.mon_cb.ciphertext;
                txn.latency    = cyc_cnt;

                `uvm_info("MON", $sformatf("Captured: %s", txn.convert2string()), UVM_HIGH)
                ap.write(txn);
            end
        end
    endtask

endclass
