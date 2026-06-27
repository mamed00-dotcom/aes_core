`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_monitor
// Description:
//   Streaming monitor with TWO analysis ports - the protocol change that lets
//   the scoreboard track in-flight transactions:
//     ap_in  : fires on every accepted input  (en & in_valid & key_ready)
//     ap_out : fires on every valid output    (en & out_valid)
//   Each input item carries {key, plaintext}; each output item carries the
//   ciphertext. Because the pipeline is order-preserving, the scoreboard can
//   match them with a simple FIFO.
//============================================================================

class aes_pipe_monitor extends uvm_monitor;
    `uvm_component_utils(aes_pipe_monitor)

    virtual aes_pipe_if vif;
    uvm_analysis_port #(aes_pipe_item) ap_in;
    uvm_analysis_port #(aes_pipe_item) ap_out;

    function new(string name = "aes_pipe_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap_in  = new("ap_in", this);
        ap_out = new("ap_out", this);
        if (!uvm_config_db#(virtual aes_pipe_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "aes_pipe_if not found")
    endfunction

    task run_phase(uvm_phase phase);
        aes_pipe_item in_t, out_t;
        forever begin
            @(vif.mon_cb);

            // Input accepted this cycle
            if (vif.mon_cb.en && vif.mon_cb.in_valid && vif.mon_cb.key_ready) begin
                in_t = aes_pipe_item::type_id::create("in_t");
                in_t.key       = vif.mon_cb.key;
                in_t.plaintext = vif.mon_cb.in_data;
                ap_in.write(in_t);
            end

            // Valid result this cycle
            if (vif.mon_cb.en && vif.mon_cb.out_valid) begin
                out_t = aes_pipe_item::type_id::create("out_t");
                out_t.ciphertext = vif.mon_cb.out_data;
                ap_out.write(out_t);
            end
        end
    endtask

endclass
