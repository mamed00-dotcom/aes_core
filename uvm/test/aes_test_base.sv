`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_test_base
// Description: Base test — builds environment, configures interface.
//============================================================================

class aes_test_base extends uvm_test;
    `uvm_component_utils(aes_test_base)

    aes_env env;

    function new(string name = "aes_test_base", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = aes_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        uvm_top.print_topology();
    endfunction

endclass
