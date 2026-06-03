`include "uvm_macros.svh"
import uvm_pkg::*;
//============================================================================
// Class: aes_driver
// Description:
//   UVM driver for the AES-128 direct interface.
//   Drives key/plaintext, pulses start, waits for valid.
//============================================================================

class aes_driver extends uvm_driver #(aes_seq_item);
    `uvm_component_utils(aes_driver)

    virtual aes_if vif;

    function new(string name = "aes_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual aes_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        aes_seq_item req;
        int timeout_cnt;

        vif.drv_cb.start     <= 1'b0;
        vif.drv_cb.plaintext <= 128'd0;
        vif.drv_cb.key       <= 128'd0;

        // Wait for reset to deassert before driving any transactions
        @(posedge vif.rst_n);
        @(vif.drv_cb);

        forever begin
            seq_item_port.get_next_item(req);

            `uvm_info("DRV", $sformatf("Driving: KEY=%032h PT=%032h",
                      req.key, req.plaintext), UVM_MEDIUM)

            @(vif.drv_cb);
            vif.drv_cb.plaintext <= req.plaintext;
            vif.drv_cb.key       <= req.key;
            vif.drv_cb.start     <= 1'b1;

            @(vif.drv_cb);
            vif.drv_cb.start <= 1'b0;

            // Two-phase wait: valid drop then valid rise
            timeout_cnt = 0;
            while (vif.drv_cb.valid && timeout_cnt < 60) begin
                @(vif.drv_cb);
                timeout_cnt++;
            end
            while (!vif.drv_cb.valid && timeout_cnt < 60) begin
                @(vif.drv_cb);
                timeout_cnt++;
            end

            if (timeout_cnt >= 60)
                `uvm_error("DRV", "Timeout waiting for valid!")
            else begin
                req.ciphertext = vif.drv_cb.ciphertext;
                req.latency    = timeout_cnt + 1;
            end

            seq_item_port.item_done();
        end
    endtask

endclass
