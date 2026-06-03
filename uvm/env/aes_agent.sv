`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_agent
// Description:
//   UVM active agent: contains driver, sequencer, and monitor.
//============================================================================

class aes_agent extends uvm_agent;
    `uvm_component_utils(aes_agent)

    aes_driver                       drv;
    uvm_sequencer #(aes_seq_item)    sqr;
    aes_monitor                      mon;

    function new(string name = "aes_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (get_is_active() == UVM_ACTIVE) begin
            drv = aes_driver::type_id::create("drv", this);
            sqr = uvm_sequencer#(aes_seq_item)::type_id::create("sqr", this);
        end
        mon = aes_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass
