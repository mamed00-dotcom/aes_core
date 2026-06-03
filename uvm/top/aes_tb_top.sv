`timescale 1ns / 1ps
//============================================================================
// Module: aes_tb_top.sv
// Description:
//   UVM testbench top-level.
//   - Instantiates clock, reset, DUT, interface
//   - Binds SVA assertions and functional coverage
//   - Registers interface in config_db
//   - Calls run_test() to start UVM
//
// Compile & run (Vivado xsim) — run from project root:
//   See uvm/Makefile or run_uvm.bat for the exact commands.
//   Short form:
//   xvlog -sv -L uvm rtl/*.v uvm/top/aes_if.sv uvm/sva/aes_assertions.sv \
//          uvm/coverage/aes_coverage.sv uvm/env/*.sv uvm/seq/*.sv \
//          uvm/test/*.sv uvm/top/aes_tb_top.sv
//   xelab -sv -L uvm aes_tb_top -sv_lib uvm/dpi/aes_dpi -s aes_uvm_snap
//   xsim aes_uvm_snap -testplusarg UVM_TESTNAME=aes_test_nist -runall
//============================================================================

// Include all UVM packages and components
`include "uvm_macros.svh"

module aes_tb_top;
    import uvm_pkg::*;

    // UVM component files compiled separately by xvlog — no include needed here.

    //------------------------------------------------------------------------
    // Clock and Reset
    //------------------------------------------------------------------------
    reg clk;
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;      // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
    end

    //------------------------------------------------------------------------
    // Interface instantiation
    //------------------------------------------------------------------------
    aes_if aes_vif(clk, rst_n);

    //------------------------------------------------------------------------
    // DUT instantiation — direct interface mode
    //------------------------------------------------------------------------
    aes_top #(
        .C_S_AXI_DATA_WIDTH (32),
        .C_S_AXI_ADDR_WIDTH (6)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),

        // AXI4-Lite (tied off)
        .s_axi_awaddr     (6'd0),
        .s_axi_awprot     (3'd0),
        .s_axi_awvalid    (1'b0),
        .s_axi_awready    (),
        .s_axi_wdata      (32'd0),
        .s_axi_wstrb      (4'hF),
        .s_axi_wvalid     (1'b0),
        .s_axi_wready     (),
        .s_axi_bresp      (),
        .s_axi_bvalid     (),
        .s_axi_bready     (1'b1),
        .s_axi_araddr     (6'd0),
        .s_axi_arprot     (3'd0),
        .s_axi_arvalid    (1'b0),
        .s_axi_arready    (),
        .s_axi_rdata      (),
        .s_axi_rresp      (),
        .s_axi_rvalid     (),
        .s_axi_rready     (1'b1),

        // Direct interface (driven by UVM via aes_if)
        .plaintext_direct (aes_vif.plaintext),
        .key_direct       (aes_vif.key),
        .start_direct     (aes_vif.start),
        .use_direct       (1'b1),
        .ciphertext       (aes_vif.ciphertext),
        .valid            (aes_vif.valid),
        .busy             (aes_vif.busy)
    );

    //------------------------------------------------------------------------
    // Bind SVA assertions to DUT
    //------------------------------------------------------------------------
    bind u_dut aes_assertions u_assert (
        .clk             (clk),
        .rst_n           (rst_n),
        .state           (state),
        .state_next      (state_next),
        .round_cnt       (round_cnt),
        .valid           (valid),
        .busy            (busy),
        .start_direct    (start_direct),
        .use_direct      (use_direct),
        .key_reg         (key_reg),
        .pt_reg          (pt_reg),
        .ct_reg          (ct_reg),
        .ciphertext      (ciphertext),
        .s_axi_awvalid   (s_axi_awvalid),
        .s_axi_wvalid    (s_axi_wvalid),
        .s_axi_awready   (s_axi_awready),
        .s_axi_wready    (s_axi_wready),
        .s_axi_bvalid    (s_axi_bvalid),
        .s_axi_bready    (s_axi_bready)
    );

    //------------------------------------------------------------------------
    // Bind functional coverage to DUT
    //------------------------------------------------------------------------
    bind u_dut aes_coverage u_coverage (
        .clk            (clk),
        .rst_n          (rst_n),
        .state          (state),
        .round_cnt      (round_cnt),
        .valid          (valid),
        .busy           (busy),
        .start_direct   (start_direct),
        .use_direct     (use_direct),
        .key_reg        (key_reg),
        .pt_reg         (pt_reg),
        .ct_reg         (ct_reg)
    );

    //------------------------------------------------------------------------
    // UVM configuration and launch
    //------------------------------------------------------------------------
    initial begin
        // Register interface in config_db
        uvm_config_db#(virtual aes_if)::set(null, "*", "vif", aes_vif);

        // Run UVM test (selected by +UVM_TESTNAME=... on command line)
        run_test();
    end

    //------------------------------------------------------------------------
    // Global timeout watchdog
    //------------------------------------------------------------------------
    initial begin
        #500_000;
        `uvm_fatal("TIMEOUT", "Global simulation timeout reached!")
    end

endmodule
