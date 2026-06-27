`timescale 1ns / 1ps
//============================================================================
// Module: aes_pipe_tb_top.sv
// Description:
//   UVM testbench top for the pipelined AES core. Instantiates the clock,
//   reset, interface and aes_pipeline_top DUT, registers the interface and
//   the fixed key in the config_db, and launches the UVM test.
//
//   Run (Vivado xsim), from project root:
//     source run_uvm_pipe.tcl
//============================================================================

`include "uvm_macros.svh"

module aes_pipe_tb_top;
    import uvm_pkg::*;

    reg clk;
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;          // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    //------------------------------------------------------------------------
    // Interface + DUT
    //------------------------------------------------------------------------
    aes_pipe_if vif(clk, rst_n);

    aes_pipeline_top u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .key       (vif.key),
        .key_load  (vif.key_load),
        .key_ready (vif.key_ready),
        .en        (vif.en),
        .in_valid  (vif.in_valid),
        .in_data   (vif.in_data),
        .out_valid (vif.out_valid),
        .out_data  (vif.out_data)
    );

    //------------------------------------------------------------------------
    // UVM launch
    //------------------------------------------------------------------------
    initial begin
        uvm_config_db#(virtual aes_pipe_if)::set(null, "*", "vif", vif);
        uvm_config_db#(bit [127:0])::set(null, "*", "aes_key",
                                         128'h000102030405060708090a0b0c0d0e0f);
        uvm_config_db#(int unsigned)::set(null, "uvm_test_top", "num_blocks", 200);
        run_test("aes_pipe_test");
    end

    initial begin
        #500_000;
        `uvm_fatal("TIMEOUT", "Global simulation timeout reached!")
    end

endmodule
