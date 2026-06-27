`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_env
// Description:
//   Environment for the pipelined AES core. Connects BOTH monitor analysis
//   ports to the FIFO scoreboard: ap_in -> write_in, ap_out -> write_out.
//============================================================================

class aes_pipe_env extends uvm_env;
    `uvm_component_utils(aes_pipe_env)

    aes_pipe_agent      agt;
    aes_pipe_scoreboard scb;

    function new(string name = "aes_pipe_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt = aes_pipe_agent::type_id::create("agt", this);
        scb = aes_pipe_scoreboard::type_id::create("scb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agt.mon.ap_in.connect (scb.ap_in);
        agt.mon.ap_out.connect(scb.ap_out);
    endfunction

endclass
