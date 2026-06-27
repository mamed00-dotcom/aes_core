`timescale 1ns / 1ps
//============================================================================
// Testbench: tb_aes_coproc.sv
// Project:   AES-128 Core - Approach A (Coprocessor), Phase 3
// Author:    Mohammed Hajjar
// Date:      June 2026
//
// Description:
//   Self-checking testbench for aes_coproc.v. An AXI4-Lite master BFM drives
//   the coprocessor exactly as a RISC-V CPU would with load/store
//   instructions, exercising:
//     TEST 1 - Single-block FIPS-197 KAT through the MMIO register path.
//     TEST 2 - Posted burst: push a FIFO-full of blocks BEFORE popping any,
//              then drain - proves issue/result decoupling and ordering.
//     TEST 3 - Interrupt-driven streaming of random blocks with a
//              producer/consumer loop; every result checked vs DPI-C golden.
//============================================================================

module tb_aes_coproc;

    import "DPI-C" function void aes_encrypt_dpi(
        input  bit [127:0] key_in,
        input  bit [127:0] pt_in,
        output bit [127:0] ct_out
    );

    // ---- Register map ----
    localparam [6:0] ADDR_CTRL=7'h00, ADDR_STATUS=7'h04, ADDR_IRQEN=7'h08,
                     ADDR_IRQSTS=7'h0C, ADDR_KEY0=7'h10, ADDR_DIN0=7'h20,
                     ADDR_DOUT0=7'h30;
    localparam [31:0] CTRL_PUSH=32'h1, CTRL_POP=32'h2, CTRL_KEYLOAD=32'h4, CTRL_FLUSH=32'h8;

    localparam [127:0] NIST_KEY  = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] NIST_PT   = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] NIST_CT   = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    localparam [127:0] ALT_KEY   = 128'hffeeddccbbaa99887766554433221100; // re-key target

    //------------------------------------------------------------------------
    reg          clk, rst_n;
    reg  [6:0]   s_axi_awaddr;
    reg          s_axi_awvalid;
    wire         s_axi_awready;
    reg  [31:0]  s_axi_wdata;
    reg  [3:0]   s_axi_wstrb;
    reg          s_axi_wvalid;
    wire         s_axi_wready;
    wire [1:0]   s_axi_bresp;
    wire         s_axi_bvalid;
    reg          s_axi_bready;
    reg  [6:0]   s_axi_araddr;
    reg          s_axi_arvalid;
    wire         s_axi_arready;
    wire [31:0]  s_axi_rdata;
    wire [1:0]   s_axi_rresp;
    wire         s_axi_rvalid;
    reg          s_axi_rready;
    wire         irq;

    integer pass_count = 0, fail_count = 0;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    aes_coproc #(.IN_DEPTH(8), .OUT_DEPTH(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .irq(irq)
    );

    //------------------------------------------------------------------------
    // AXI4-Lite master BFM (bready/rready held high -> always-ready master)
    //------------------------------------------------------------------------
    task automatic axi_write(input [6:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            s_axi_awaddr = addr; s_axi_awvalid = 1'b1;
            s_axi_wdata  = data; s_axi_wstrb = 4'hF; s_axi_wvalid = 1'b1;
            forever begin @(posedge clk); if (s_axi_awready && s_axi_wready) break; end
            @(negedge clk);
            s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
            forever begin @(posedge clk); if (s_axi_bvalid) break; end
        end
    endtask

    task automatic axi_read(input [6:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            s_axi_araddr = addr; s_axi_arvalid = 1'b1;
            forever begin @(posedge clk); if (s_axi_arready) break; end
            @(negedge clk);
            s_axi_arvalid = 1'b0;
            forever begin @(posedge clk); if (s_axi_rvalid) break; end
            data = s_axi_rdata;
        end
    endtask

    // ---- Higher-level ops ----
    task automatic load_key(input [127:0] k);
        reg [31:0] st;
        begin
            axi_write(ADDR_KEY0 + 7'h0, k[127:96]);
            axi_write(ADDR_KEY0 + 7'h4, k[95:64]);
            axi_write(ADDR_KEY0 + 7'h8, k[63:32]);
            axi_write(ADDR_KEY0 + 7'hC, k[31:0]);
            axi_write(ADDR_CTRL, CTRL_KEYLOAD);
            // poll STATUS.key_ready (bit4)
            st = 0;
            while (!st[4]) axi_read(ADDR_STATUS, st);
        end
    endtask

    task automatic push_block(input [127:0] pt);
        begin
            axi_write(ADDR_DIN0 + 7'h0, pt[127:96]);
            axi_write(ADDR_DIN0 + 7'h4, pt[95:64]);
            axi_write(ADDR_DIN0 + 7'h8, pt[63:32]);
            axi_write(ADDR_DIN0 + 7'hC, pt[31:0]);
            axi_write(ADDR_CTRL, CTRL_PUSH);
        end
    endtask

    task automatic pop_block(output [127:0] ct);
        reg [31:0] w0,w1,w2,w3;
        begin
            axi_read(ADDR_DOUT0 + 7'h0, w0);
            axi_read(ADDR_DOUT0 + 7'h4, w1);
            axi_read(ADDR_DOUT0 + 7'h8, w2);
            axi_read(ADDR_DOUT0 + 7'hC, w3);
            ct = {w0, w1, w2, w3};
            axi_write(ADDR_CTRL, CTRL_POP);
        end
    endtask

    //------------------------------------------------------------------------
    integer i, pushed, popped, nb;
    reg busy_seen;
    reg [31:0] st;
    reg [127:0] ct, golden;
    reg [127:0] pt_q [0:63];
    reg [127:0] gold_q [0:63];

    initial begin
        rst_n=0; s_axi_awaddr=0; s_axi_awvalid=0; s_axi_wdata=0; s_axi_wstrb=0; s_axi_wvalid=0;
        s_axi_bready=1; s_axi_araddr=0; s_axi_arvalid=0; s_axi_rready=1;
        repeat (4) @(posedge clk);
        rst_n=1;
        @(posedge clk);

        load_key(NIST_KEY);
        $display("\n[TEST 1] Single-block KAT via MMIO");
        push_block(NIST_PT);
        // poll STATUS until the output FIFO is non-empty (bit3 = out_empty)
        do axi_read(ADDR_STATUS, st); while (st[3]);
        pop_block(ct);
        if (ct === NIST_CT) begin $display("  [PASS] CT=%032h", ct); pass_count++; end
        else begin $display("  [FAIL] exp=%032h got=%032h", NIST_CT, ct); fail_count++; end

        //--------------------------------------------------------------------
        $display("\n[TEST 2] Posted burst: push 8 blocks BEFORE popping any");
        for (i=0;i<8;i=i+1) begin
            pt_q[i] = {$urandom,$urandom,$urandom,$urandom};
            aes_encrypt_dpi(NIST_KEY, pt_q[i], gold_q[i]);
            push_block(pt_q[i]);                 // post all 8 first
        end
        for (i=0;i<8;i=i+1) begin
            do axi_read(ADDR_STATUS, st); while (st[3]);   // wait result
            pop_block(ct);
            if (ct === gold_q[i]) pass_count++;
            else begin $display("  [FAIL] burst %0d exp=%032h got=%032h", i, gold_q[i], ct); fail_count++; end
        end
        $display("  [PASS] 8/8 burst results correct and in order");

        //--------------------------------------------------------------------
        $display("\n[TEST 3] IRQ-driven streaming of 40 random blocks");
        axi_write(ADDR_IRQEN, 32'h1);            // enable interrupt
        pushed=0; popped=0;
        while (popped < 40) begin
            axi_read(ADDR_STATUS, st);
            // push if input not full (bit0) and more remain
            if (pushed < 40 && !st[0]) begin
                golden = {$urandom,$urandom,$urandom,$urandom};
                aes_encrypt_dpi(NIST_KEY, golden, gold_q[pushed]); // gold_q holds expected ct
                push_block(golden);
                pushed=pushed+1;
            end
            // pop if a result is available (out not empty -> bit3==0), gated by irq
            if (!st[3]) begin
                if (irq !== 1'b1) begin
                    $display("  [FAIL] result available but irq not asserted"); fail_count++;
                end
                pop_block(ct);
                if (ct === gold_q[popped]) pass_count++;
                else begin $display("  [FAIL] stream %0d exp=%032h got=%032h", popped, gold_q[popped], ct); fail_count++; end
                popped=popped+1;
            end
        end
        $display("  [PASS] 40/40 streamed results correct, irq observed");

        //--------------------------------------------------------------------
        // TEST 4 - fixed-key interlock: a KEY_LOAD issued while the engine is
        // busy (blocks in flight / results not yet popped) must be IGNORED, so
        // the in-flight batch stays encrypted under the original key. After the
        // engine drains, a real re-key must be honored.
        //--------------------------------------------------------------------
        $display("\n[TEST 4] KEY_LOAD interlock (re-key ignored while busy)");
        nb = 6;
        for (i=0;i<nb;i=i+1) begin
            pt_q[i] = {$urandom,$urandom,$urandom,$urandom};
            aes_encrypt_dpi(NIST_KEY, pt_q[i], gold_q[i]);   // expected under ORIGINAL key
            push_block(pt_q[i]);                             // post all, do not pop yet
        end
        // engine should be busy now (results waiting in the output FIFO)
        axi_read(ADDR_STATUS, st);
        busy_seen = st[5];
        // attempt a mid-stream re-key to ALT_KEY - must be ignored
        axi_write(ADDR_KEY0 + 7'h0, ALT_KEY[127:96]);
        axi_write(ADDR_KEY0 + 7'h4, ALT_KEY[95:64]);
        axi_write(ADDR_KEY0 + 7'h8, ALT_KEY[63:32]);
        axi_write(ADDR_KEY0 + 7'hC, ALT_KEY[31:0]);
        axi_write(ADDR_CTRL, CTRL_KEYLOAD);
        // drain: every block must still match the ORIGINAL-key golden
        for (i=0;i<nb;i=i+1) begin
            do axi_read(ADDR_STATUS, st); while (st[3]);
            pop_block(ct);
            if (ct === gold_q[i]) pass_count++;
            else begin $display("  [FAIL] re-key leaked: block %0d exp=%032h got=%032h", i, gold_q[i], ct); fail_count++; end
        end
        if (busy_seen) begin
            $display("  [PASS] %0d blocks stayed under original key; re-key ignored while busy", nb);
            pass_count++;
        end else begin
            $display("  [FAIL] engine was not busy when the re-key was attempted");
            fail_count++;
        end
        // now drained -> a genuine re-key must take effect
        load_key(ALT_KEY);
        pt_q[0] = {$urandom,$urandom,$urandom,$urandom};
        aes_encrypt_dpi(ALT_KEY, pt_q[0], gold_q[0]);        // expected under NEW key
        push_block(pt_q[0]);
        do axi_read(ADDR_STATUS, st); while (st[3]);
        pop_block(ct);
        if (ct === gold_q[0]) begin
            $display("  [PASS] re-key honored after drain (new-key block correct)");
            pass_count++;
        end else begin
            $display("  [FAIL] post-drain re-key wrong: exp=%032h got=%032h", gold_q[0], ct);
            fail_count++;
        end

        //--------------------------------------------------------------------
        $display("\n========================================================");
        $display("  COPROC TB SUMMARY: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count==0) $display("  *** ALL CHECKS PASSED ***");
        else               $display("  *** %0d FAILURE(S) ***", fail_count);
        $display("========================================================\n");
        $finish;
    end

    initial begin #2000000; $display("  [FAIL] timeout"); $finish; end

endmodule
