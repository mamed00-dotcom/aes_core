//============================================================================
// Testbench: tb_aes_top.sv
// Project:   AES-128 Encryption Core
// Author:    Mohammed Hajjar
// Date:      March 2026
//
// Description:
//   SystemVerilog testbench — xsim compatible.
//   Uses DIRECT interface (bypasses AXI4-Lite).
//   Test vectors verified against Python cryptography library (OpenSSL).
//============================================================================

`timescale 1ns / 1ps

module tb_aes_top;

    //------------------------------------------------------------------------
    // Testbench signals
    //------------------------------------------------------------------------
    reg          clk;
    reg          rst_n;
    reg  [127:0] plaintext;
    reg  [127:0] key;
    reg          start;
    wire [127:0] ciphertext;
    wire         valid;
    wire         busy;

    // Test tracking
    integer test_num;
    integer pass_count;
    integer fail_count;
    integer timeout;

    //------------------------------------------------------------------------
    // Clock generation: 10 ns period (100 MHz)
    //------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // DUT Instantiation
    //------------------------------------------------------------------------
    aes_top #(
        .C_S_AXI_DATA_WIDTH (32),
        .C_S_AXI_ADDR_WIDTH (6)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),

        // AXI4-Lite slave (tied off in direct mode)
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

        // Direct interface (active)
        .plaintext_direct (plaintext),
        .key_direct       (key),
        .start_direct     (start),
        .use_direct       (1'b1),
        .ciphertext       (ciphertext),
        .valid            (valid),
        .busy             (busy)
    );

    //------------------------------------------------------------------------
    // Task: Apply reset
    //------------------------------------------------------------------------
    task reset_dut;
        begin
            rst_n     = 1'b0;
            start     = 1'b0;
            plaintext = 128'd0;
            key       = 128'd0;
            repeat(4) @(posedge clk);
            rst_n     = 1'b1;
            @(posedge clk);
        end
    endtask

    //------------------------------------------------------------------------
    // Task: Run encryption
    //   FIX: After pulsing start, wait for valid to DROP (FSM left DONE),
    //        THEN wait for valid to RISE (new encryption complete).
    //------------------------------------------------------------------------
    task run_encrypt;
        input [127:0] pt_in;
        input [127:0] key_in;
        input [127:0] exp_ct;
        begin
            // Apply inputs and pulse start for one cycle
            @(posedge clk);
            plaintext = pt_in;
            key       = key_in;
            start     = 1'b1;
            @(posedge clk);
            start     = 1'b0;

            // CRITICAL: Wait for valid to deassert first.
            // This ensures we don't read stale ciphertext from
            // a previous encryption that left the FSM in DONE state.
            timeout = 0;
            while (valid && timeout < 50) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            // Now wait for valid to assert (new result ready)
            while (!valid && timeout < 50) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            // Evaluate result
            if (timeout >= 50) begin
                $display("  [FAIL] Timeout after %0d cycles!", timeout);
                fail_count = fail_count + 1;
            end else if (ciphertext === exp_ct) begin
                $display("  Expected:  %h", exp_ct);
                $display("  Got:       %h", ciphertext);
                $display("  Cycles:    %0d", timeout + 1);
                $display("  [PASS]");
                pass_count = pass_count + 1;
            end else begin
                $display("  Expected:  %h", exp_ct);
                $display("  Got:       %h", ciphertext);
                $display("  [FAIL] Ciphertext mismatch!");
                fail_count = fail_count + 1;
            end

            // One idle cycle between tests
            @(posedge clk);
        end
    endtask

    //------------------------------------------------------------------------
    // Main Test Sequence
    //------------------------------------------------------------------------
    initial begin
        $display("======================================================");
        $display("  AES-128 Encryption Core - Verification Suite");
        $display("  NIST FIPS 197 Compliance Test");
        $display("======================================================");

        test_num   = 0;
        pass_count = 0;
        fail_count = 0;

        // Reset
        reset_dut();

        //====================================================================
        // TEST 1: NIST FIPS 197 Appendix C.1
        //====================================================================
        test_num = test_num + 1;
        $display("------------------------------------------------------");
        $display("[TEST %0d] NIST FIPS 197 Appendix C.1 (AES-128)", test_num);
        run_encrypt(
            128'h00112233445566778899aabbccddeeff,
            128'h000102030405060708090a0b0c0d0e0f,
            128'h69c4e0d86a7b0430d8cdb78070b4c55a
        );

        //====================================================================
        // TEST 2: All-zeros
        //====================================================================
        test_num = test_num + 1;
        $display("------------------------------------------------------");
        $display("[TEST %0d] All-zeros (key and plaintext)", test_num);
        run_encrypt(
            128'h00000000000000000000000000000000,
            128'h00000000000000000000000000000000,
            128'h66e94bd4ef8a2c3b884cfa59ca342b2e
        );

        //====================================================================
        // TEST 3: NIST CAVP ECBGFSbox128
        //====================================================================
        test_num = test_num + 1;
        $display("------------------------------------------------------");
        $display("[TEST %0d] NIST CAVP ECBGFSbox128", test_num);
        run_encrypt(
            128'hf34481ec3cc627bacd5dc3fb08f273e6,
            128'h00000000000000000000000000000000,
            128'h0336763e966d92595a567cc9ce537f5e
        );

        //====================================================================
        // TEST 4: All-ones plaintext
        //====================================================================
        test_num = test_num + 1;
        $display("------------------------------------------------------");
        $display("[TEST %0d] All-ones plaintext, incrementing key", test_num);
        run_encrypt(
            128'hffffffffffffffffffffffffffffffff,
            128'h000102030405060708090a0b0c0d0e0f,
            128'h3c441f32ce07822364d7a2990e50bb13
        );

        //====================================================================
        // TEST 5: Back-to-back (repeat NIST C.1 without reset)
        //====================================================================
        test_num = test_num + 1;
        $display("------------------------------------------------------");
        $display("[TEST %0d] Back-to-back: repeat NIST C.1 (no reset)", test_num);
        run_encrypt(
            128'h00112233445566778899aabbccddeeff,
            128'h000102030405060708090a0b0c0d0e0f,
            128'h69c4e0d86a7b0430d8cdb78070b4c55a
        );

        //====================================================================
        // TEST 6: Different key
        //====================================================================
        test_num = test_num + 1;
        $display("------------------------------------------------------");
        $display("[TEST %0d] Same plaintext, different key", test_num);
        run_encrypt(
            128'h00112233445566778899aabbccddeeff,
            128'h2b7e151628aed2a6abf7158809cf4f3c,
            128'h8df4e9aac5c7573a27d8d055d6e4d64b
        );

        //====================================================================
        // Results Summary
        //====================================================================
        $display("");
        $display("======================================================");
        $display("  RESULTS SUMMARY");
        $display("======================================================");
        $display("  Total tests: %0d", test_num);
        $display("  Passed:      %0d", pass_count);
        $display("  Failed:      %0d", fail_count);
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("======================================================");

        #100;
        $finish;
    end

    //------------------------------------------------------------------------
    // Timeout watchdog
    //------------------------------------------------------------------------
    initial begin
        #100_000;
        $display("[FATAL] Global simulation timeout reached!");
        $finish;
    end

    //------------------------------------------------------------------------
    // VCD waveform dump
    //------------------------------------------------------------------------
    initial begin
        $dumpfile("aes_top_tb.vcd");
        $dumpvars(0, tb_aes_top);
    end

endmodule
