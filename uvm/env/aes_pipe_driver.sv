`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_pipe_driver
// Description:
//   Streaming driver for the pipelined AES core. Unlike the iterative-core
//   driver, it does NOT wait for a result after each block - it injects one
//   plaintext per cycle (fire-and-forget), which is exactly what creates the
//   in-flight transactions the FIFO scoreboard must handle.
//
//   Sequence flow:
//     1. Load the fixed key once (key_load pulse), wait for key_ready.
//     2. Stream items: drive in_data + in_valid for each accepted cycle.
//        When the sequencer has nothing ready, deassert in_valid (a bubble)
//        so the pipeline keeps advancing without injecting a stale block.
//   `en` is held high here; back-pressure via `en` is stress-tested in the
//   standalone tb_aes_pipeline (TEST 4).
//============================================================================

class aes_pipe_driver extends uvm_driver #(aes_pipe_item);
    `uvm_component_utils(aes_pipe_driver)

    virtual aes_pipe_if vif;
    bit [127:0] cfg_key = 128'h000102030405060708090a0b0c0d0e0f;

    function new(string name = "aes_pipe_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual aes_pipe_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "aes_pipe_if not found")
        void'(uvm_config_db#(bit [127:0])::get(this, "", "aes_key", cfg_key));
    endfunction

    task run_phase(uvm_phase phase);
        aes_pipe_item req;

        // Init
        vif.drv_cb.en       <= 1'b1;
        vif.drv_cb.in_valid <= 1'b0;
        vif.drv_cb.in_data  <= 128'd0;
        vif.drv_cb.key      <= 128'd0;
        vif.drv_cb.key_load <= 1'b0;

        @(posedge vif.rst_n);
        @(vif.drv_cb);

        // ---- Load the fixed key once ----
        vif.drv_cb.key      <= cfg_key;
        vif.drv_cb.key_load <= 1'b1;
        @(vif.drv_cb);
        vif.drv_cb.key_load <= 1'b0;
        while (vif.drv_cb.key_ready !== 1'b1) @(vif.drv_cb);
        `uvm_info("DRV", $sformatf("Key loaded: %032h", cfg_key), UVM_LOW)

        // ---- Stream blocks ----
        forever begin
            seq_item_port.try_next_item(req);
            if (req == null) begin
                // No stimulus ready this cycle: inject a bubble
                @(vif.drv_cb);
                vif.drv_cb.in_valid <= 1'b0;
            end else begin
                @(vif.drv_cb);
                vif.drv_cb.in_data  <= req.plaintext;
                vif.drv_cb.in_valid <= 1'b1;
                seq_item_port.item_done();
            end
        end
    endtask

endclass
