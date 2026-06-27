`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_agent
// Description: Active agent for the pipelined AES env (driver + sequencer +
//              streaming monitor).
//============================================================================

class aes_pipe_agent extends uvm_agent;
    `uvm_component_utils(aes_pipe_agent)

    aes_pipe_driver                   drv;
    uvm_sequencer #(aes_pipe_item)    sqr;
    aes_pipe_monitor                  mon;

    function new(string name = "aes_pipe_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (get_is_active() == UVM_ACTIVE) begin
            drv = aes_pipe_driver::type_id::create("drv", this);
            sqr = uvm_sequencer#(aes_pipe_item)::type_id::create("sqr", this);
        end
        mon = aes_pipe_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass
