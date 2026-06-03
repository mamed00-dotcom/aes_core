`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_env
// Description:
//   UVM environment: connects agent (driver+monitor) to scoreboard.
//============================================================================

class aes_env extends uvm_env;
    `uvm_component_utils(aes_env)

    aes_agent      agt;
    aes_scoreboard scb;

    function new(string name = "aes_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt = aes_agent::type_id::create("agt", this);
        scb = aes_scoreboard::type_id::create("scb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // Monitor broadcasts transactions to scoreboard
        agt.mon.ap.connect(scb.ap);
    endfunction

endclass
