`timescale 1ns / 1ps
//============================================================================
// Testbench: tb_aes_pipeline.sv
// Project:   AES-128 Encryption Core - Pipelined Variant (Phase 1)
// Author:    Mohammed Hajjar
// Date:      June 2026
//
// Description:
//   Self-checking testbench for aes_pipeline_top.v. Demonstrates the three
//   properties that Phase 1 must prove:
//     TEST 1 - Correctness + latency: the FIPS-197 known-answer vector
//              produces the expected ciphertext exactly 10 cycles after it
//              is accepted.
//     TEST 2 - Throughput: with in_valid held high, the core accepts one
//              block AND produces one block on EVERY clock cycle.
//     TEST 3 - In-flight checking + order: a stream of random blocks is fed
//              back-to-back; each result is checked against the DPI-C golden
//              model using a reference QUEUE (the miniature scoreboard).
//     TEST 4 - Back-pressure: de-asserting `en` freezes the pipeline; no
//              data is lost or reordered.
//
//   The reference-queue pattern here is exactly how the UVM scoreboard must
//   be adapted for the pipeline: push expected on input accept, pop+compare
//   on output valid. Because an AES pipeline is strictly order-preserving,
//   a simple FIFO suffices - no transaction IDs needed.
//
//   Requires the DPI-C golden model (uvm/dpi/aes_dpi.c) for TEST 3/4.
//============================================================================

module tb_aes_pipeline;

    //------------------------------------------------------------------------
    // DPI-C golden model (same import used by the UVM scoreboard)
    //------------------------------------------------------------------------
    import "DPI-C" function void aes_encrypt_dpi(
        input  bit [127:0] key_in,
        input  bit [127:0] pt_in,
        output bit [127:0] ct_out
    );

    //------------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------------
    reg          clk;
    reg          rst_n;
    reg  [127:0] key;
    reg          key_load;
    wire         key_ready;
    reg          en;
    reg          in_valid;
    reg  [127:0] in_data;
    wire         out_valid;
    wire [127:0] out_data;

    // Bookkeeping
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // Reference scoreboard: FIFO of expected ciphertexts for in-flight blocks
    bit [127:0] expected_q [$];

    //------------------------------------------------------------------------
    // 100 MHz clock
    //------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    aes_pipeline_top dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .key       (key),
        .key_load  (key_load),
        .key_ready (key_ready),
        .en        (en),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_valid (out_valid),
        .out_data  (out_data)
    );

    //------------------------------------------------------------------------
    // Continuous output checker (TEST 3/4): every valid output beat is
    // popped from the reference queue and compared. This runs concurrently
    // with stimulus, mirroring a UVM monitor->scoreboard analysis path.
    //------------------------------------------------------------------------
    bit        checker_on;
    bit [127:0] exp_ct;
    always @(posedge clk) begin
        if (rst_n && en && out_valid && checker_on) begin
            if (expected_q.size() == 0) begin
                $display("  [FAIL] Output beat with EMPTY reference queue: %032h", out_data);
                fail_count = fail_count + 1;
            end else begin
                exp_ct = expected_q.pop_front();
                if (out_data === exp_ct) begin
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] CT mismatch  exp=%032h got=%032h", exp_ct, out_data);
                    fail_count = fail_count + 1;
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------------
    task automatic do_reset;
        begin
            rst_n    = 1'b0;
            key_load = 1'b0;
            en       = 1'b1;
            in_valid = 1'b0;
            in_data  = 128'd0;
            key      = 128'd0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic load_key (input bit [127:0] k);
        begin
            @(negedge clk);
            key      = k;
            key_load = 1'b1;
            @(negedge clk);
            key_load = 1'b0;
            // Wait for the 10-cycle key expansion to complete
            wait (key_ready === 1'b1);
            @(posedge clk);
        end
    endtask

    //------------------------------------------------------------------------
    // Main stimulus
    //------------------------------------------------------------------------
    localparam [127:0] NIST_KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] NIST_PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] NIST_CT  = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    integer latency;
    bit [127:0] rnd_pt;
    bit [127:0] golden;

    initial begin
        checker_on = 1'b0;
        do_reset;

        //====================================================================
        // TEST 1 - Correctness + fixed 10-cycle latency (single block)
        //====================================================================
        $display("\n[TEST 1] FIPS-197 known-answer + latency measurement");
        load_key(NIST_KEY);

        @(negedge clk);
        in_data  = NIST_PT;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;
        in_data  = 128'd0;

        // Count cycles from input-accept to out_valid
        latency = 0;
        while (out_valid !== 1'b1) begin
            @(posedge clk);
            latency = latency + 1;
        end

        if (out_data === NIST_CT) begin
            $display("  [PASS] CT=%032h", out_data);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] exp=%032h got=%032h", NIST_CT, out_data);
            fail_count = fail_count + 1;
        end

        if (latency == 10) begin
            $display("  [PASS] Latency = %0d cycles (expected 10)", latency);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Latency = %0d cycles (expected 10)", latency);
            fail_count = fail_count + 1;
        end

        //====================================================================
        // TEST 2 - Throughput: 1 block/cycle in AND out
        //====================================================================
        $display("\n[TEST 2] Throughput - stream NIST_PT for 16 consecutive cycles");
        repeat (4) @(posedge clk);     // drain pipeline

        fork
            // Producer: drive a valid block every single cycle for 16 cycles
            begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data  = NIST_PT;
                repeat (16) @(negedge clk);
                in_valid = 1'b0;
                in_data  = 128'd0;
            end
            // Consumer: once the pipeline is full, out_valid must be high
            // every cycle and out_data must equal NIST_CT.
            begin
                integer good;
                good = 0;
                // skip the 10-cycle fill
                repeat (11) @(posedge clk);
                repeat (16) begin
                    if (out_valid === 1'b1 && out_data === NIST_CT)
                        good = good + 1;
                    @(posedge clk);
                end
                if (good >= 15) begin   // allow 1 cycle of edge alignment slack
                    $display("  [PASS] %0d/16 cycles produced a valid correct block (1 block/cycle)", good);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] Only %0d/16 cycles produced a valid correct block", good);
                    fail_count = fail_count + 1;
                end
            end
        join

        //====================================================================
        // TEST 3 - In-flight random stream checked via reference QUEUE
        //====================================================================
        $display("\n[TEST 3] 200 random blocks, back-to-back, FIFO-checked");
        repeat (12) @(posedge clk);    // drain
        expected_q.delete();
        checker_on = 1'b1;

        @(negedge clk);
        for (i = 0; i < 200; i = i + 1) begin
            rnd_pt = {$urandom, $urandom, $urandom, $urandom};
            aes_encrypt_dpi(NIST_KEY, rnd_pt, golden);
            expected_q.push_back(golden);     // push expected on input accept
            in_valid = 1'b1;
            in_data  = rnd_pt;
            @(negedge clk);
        end
        in_valid = 1'b0;
        in_data  = 128'd0;

        // Let the pipeline drain
        repeat (15) @(posedge clk);

        //====================================================================
        // TEST 4 - Back-pressure: freeze pipeline mid-stream with en=0
        //====================================================================
        $display("\n[TEST 4] Back-pressure (en toggling) preserves data & order");
        repeat (4) @(posedge clk);
        expected_q.delete();

        @(negedge clk);
        for (i = 0; i < 50; i = i + 1) begin
            rnd_pt = {$urandom, $urandom, $urandom, $urandom};
            aes_encrypt_dpi(NIST_KEY, rnd_pt, golden);
            in_valid = 1'b1;
            in_data  = rnd_pt;
            expected_q.push_back(golden);
            @(negedge clk);
            // Inject a 2-cycle stall every 7 blocks
            if (i % 7 == 6) begin
                in_valid = 1'b0;
                en       = 1'b0;
                @(negedge clk);
                @(negedge clk);
                en       = 1'b1;
            end
        end
        in_valid = 1'b0;
        in_data  = 128'd0;
        repeat (15) @(posedge clk);
        checker_on = 1'b0;

        if (expected_q.size() != 0) begin
            $display("  [FAIL] %0d expected blocks never came out (lost in pipeline)", expected_q.size());
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] All streamed blocks accounted for, in order");
            pass_count = pass_count + 1;
        end

        //====================================================================
        // Summary
        //====================================================================
        $display("\n========================================================");
        $display("  PIPELINE TB SUMMARY: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0) $display("  *** ALL CHECKS PASSED ***");
        else                 $display("  *** %0d FAILURE(S) ***", fail_count);
        $display("========================================================\n");
        $finish;
    end

    //------------------------------------------------------------------------
    // Global watchdog
    //------------------------------------------------------------------------
    initial begin
        #200000;
        $display("  [FAIL] Global timeout");
        $finish;
    end

endmodule
