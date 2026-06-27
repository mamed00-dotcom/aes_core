`timescale 1ns / 1ps
//============================================================================
// Testbench: tb_aes_dma.sv
// Project:   AES-128 Core - Approach B (Streaming), Phase 2b
// Author:    Mohammed Hajjar
// Date:      June 2026
//
// Description:
//   System-level self-checking testbench for aes_stream_system.v.
//   Flow modelled on how a RISC-V driver would use the block:
//     1. Back-door load N plaintext blocks into the buffer at src_base.
//     2. Program the key (key_load) and wait for key_ready.
//     3. Program src_base/dst_base/num_blocks and pulse start.
//     4. Wait for the completion irq.
//     5. Back-door read the ciphertext region and check every block against
//        the DPI-C golden model.
//
//   Also measures start->irq latency to demonstrate that the DMA streams the
//   buffer (~N + pipeline_latency cycles) rather than processing one block at
//   a time (~N * latency).
//============================================================================

module tb_aes_dma;

    import "DPI-C" function void aes_encrypt_dpi(
        input  bit [127:0] key_in,
        input  bit [127:0] pt_in,
        output bit [127:0] ct_out
    );

    localparam ADDR_W = 12;
    localparam LEN_W  = 16;
    localparam DEPTH  = 256;

    localparam int  N        = 50;                 // blocks to encrypt
    localparam int  SRC_BASE = 0;
    localparam int  DST_BASE = 100;
    localparam [127:0] NIST_KEY = 128'h000102030405060708090a0b0c0d0e0f;

    //------------------------------------------------------------------------
    reg                 clk;
    reg                 rst_n;
    reg  [127:0]        key;
    reg                 key_load;
    wire                key_ready;
    reg                 start;
    reg  [ADDR_W-1:0]   src_base;
    reg  [ADDR_W-1:0]   dst_base;
    reg  [LEN_W-1:0]    num_blocks;
    wire                busy;
    wire                done;
    wire                irq;

    bit [127:0] pt_mem  [0:N-1];   // local copy of plaintext
    bit [127:0] golden  [0:N-1];   // expected ciphertext (DPI)

    integer pass_count = 0;
    integer fail_count = 0;
    integer irq_pulses = 0;
    integer cyc_start, cyc_irq;
    integer cycle = 0;
    integer w, zl_pass = 0;       // zero-length-transfer guard
    reg     zl_saw_irq;

    //------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;
    always @(posedge clk) cycle <= cycle + 1;

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    aes_stream_system #(.ADDR_W(ADDR_W), .LEN_W(LEN_W), .DEPTH(DEPTH)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .key        (key),
        .key_load   (key_load),
        .key_ready  (key_ready),
        .start      (start),
        .src_base   (src_base),
        .dst_base   (dst_base),
        .num_blocks (num_blocks),
        .busy       (busy),
        .done       (done),
        .irq        (irq)
    );

    //------------------------------------------------------------------------
    // Count irq pulses + capture completion cycle
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && irq) begin
            irq_pulses = irq_pulses + 1;
            cyc_irq    = cycle;
        end
    end

    //------------------------------------------------------------------------
    integer i;
    initial begin
        rst_n      = 1'b0;
        key_load   = 1'b0;
        start      = 1'b0;
        key        = 128'd0;
        src_base   = SRC_BASE;
        dst_base   = DST_BASE;
        num_blocks = N;

        // Generate plaintext + golden, back-door load into buffer
        for (i = 0; i < N; i = i + 1) begin
            pt_mem[i] = {$urandom, $urandom, $urandom, $urandom};
            aes_encrypt_dpi(NIST_KEY, pt_mem[i], golden[i]);
            dut.u_ram.mem[SRC_BASE + i] = pt_mem[i];   // back-door preload
        end

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Program key
        @(negedge clk);
        key      = NIST_KEY;
        key_load = 1'b1;
        @(negedge clk);
        key_load = 1'b0;
        wait (key_ready === 1'b1);
        @(posedge clk);

        //--------------------------------------------------------------------
        // Directed case: zero-length transfer (num_blocks == 0).
        // The engine must complete immediately (done + single irq) instead of
        // hanging in S_RUN with busy stuck high (no TLAST would ever return).
        //--------------------------------------------------------------------
        $display("\n[DMA] Zero-length transfer guard (num_blocks=0)");
        zl_saw_irq = 1'b0;
        @(negedge clk);
        num_blocks = {LEN_W{1'b0}};
        start      = 1'b1;
        @(negedge clk);
        start = 1'b0;
        // bounded window: completion (done) is expected within a couple of
        // cycles; capture the single-cycle irq pulse anywhere in the window.
        for (w = 0; w < 20; w = w + 1) begin
            @(posedge clk);
            if (irq) zl_saw_irq = 1'b1;
        end
        if (done === 1'b1 && busy === 1'b0 && zl_saw_irq) begin
            zl_pass = 1;
            $display("    [PASS] completed (done=1, busy=0, irq pulsed)");
        end else begin
            zl_pass = 0;
            $display("    [FAIL] done=%0b busy=%0b saw_irq=%0b (want done=1 busy=0 irq=1)",
                     done, busy, zl_saw_irq);
        end

        // Restore length for the main streaming transfer; clear the irq counter
        // so the 1-pulse expectation below applies to that transfer alone.
        num_blocks = N;
        irq_pulses = 0;
        repeat (2) @(posedge clk);

        // Kick off the DMA transfer
        $display("\n[DMA] Encrypting %0d blocks  src=%0d -> dst=%0d", N, SRC_BASE, DST_BASE);
        @(negedge clk);
        start     = 1'b1;
        cyc_start = cycle;
        @(negedge clk);
        start = 1'b0;

        // Wait for completion interrupt
        wait (irq === 1'b1);
        @(posedge clk);
        repeat (2) @(posedge clk);

        // Check the ciphertext that the DMA wrote back
        for (i = 0; i < N; i = i + 1) begin
            if (dut.u_ram.mem[DST_BASE + i] === golden[i]) begin
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] block %0d  exp=%032h got=%032h",
                         i, golden[i], dut.u_ram.mem[DST_BASE + i]);
                fail_count = fail_count + 1;
            end
        end

        //--------------------------------------------------------------------
        $display("\n========================================================");
        $display("  DMA SYSTEM TB SUMMARY");
        $display("    blocks checked : %0d  (pass=%0d fail=%0d)", N, pass_count, fail_count);
        $display("    irq pulses     : %0d  (expected 1)", irq_pulses);
        $display("    done latched   : %0b", done);
        $display("    zero-length    : %s", zl_pass ? "PASS" : "FAIL");
        $display("    start->irq     : %0d cycles  (one-block-at-a-time would be ~%0d)",
                 cyc_irq - cyc_start, N*10);
        if (fail_count == 0 && irq_pulses == 1 && done === 1'b1 && zl_pass)
            $display("  *** ALL CHECKS PASSED ***");
        else
            $display("  *** FAILURE(S) DETECTED ***");
        $display("========================================================\n");
        $finish;
    end

    //------------------------------------------------------------------------
    initial begin
        #500000;
        $display("  [FAIL] Global timeout (irq never fired?)");
        $finish;
    end

endmodule
