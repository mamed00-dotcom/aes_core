`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_test
// Description:
//   Streams N random blocks through the pipelined core and lets the FIFO
//   scoreboard verify every in-flight result. Drains the pipeline before
//   dropping the objection (waits until every input has produced an output).
//============================================================================

class aes_pipe_test extends uvm_test;
    `uvm_component_utils(aes_pipe_test)

    aes_pipe_env env;
    int unsigned n = 200;

    function new(string name = "aes_pipe_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = aes_pipe_env::type_id::create("env", this);
        void'(uvm_config_db#(int unsigned)::get(this, "", "num_blocks", n));
    endfunction

    task run_phase(uvm_phase phase);
        aes_pipe_seq seq;
        phase.raise_objection(this);

        seq   = aes_pipe_seq::type_id::create("seq");
        seq.n = n;
        seq.start(env.agt.sqr);

        // Drain: wait until every accepted input has produced a checked output
        wait (env.scb.in_count  == n &&
              env.scb.out_count == n);

        phase.drop_objection(this);
    endtask

endclass
