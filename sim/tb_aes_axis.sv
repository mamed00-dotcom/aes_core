`timescale 1ns / 1ps
//============================================================================
// Testbench: tb_aes_axis.sv
// Project:   AES-128 Core - Approach B (Streaming), Phase 2a
// Author:    Mohammed Hajjar
// Date:      June 2026
//
// Description:
//   Self-checking testbench for aes_axis_wrapper.v. Streams random packets
//   (random length, delimited by TLAST) through the AXI4-Stream slave, while
//   independently applying:
//     * producer bubbles  - random gaps in S_AXIS_TVALID
//     * consumer back-pressure - random de-assertions of M_AXIS_TREADY
//
//   Every output beat is checked against the DPI-C golden model through a
//   reference FIFO (the in-flight scoreboard pattern). Both the ciphertext
//   (TDATA) and the packet boundary (TLAST) are verified, proving that the
//   pipeline preserves data, order, and packet framing under arbitrary
//   back-pressure on either side.
//============================================================================

module tb_aes_axis;

    import "DPI-C" function void aes_encrypt_dpi(
        input  bit [127:0] key_in,
        input  bit [127:0] pt_in,
        output bit [127:0] ct_out
    );

    //------------------------------------------------------------------------
    // Signals
    //------------------------------------------------------------------------
    reg          clk;
    reg          rst_n;
    reg  [127:0] key;
    reg          key_load;
    wire         key_ready;

    reg  [127:0] s_axis_tdata;
    reg          s_axis_tvalid;
    wire         s_axis_tready;
    reg          s_axis_tlast;

    wire [127:0] m_axis_tdata;
    wire         m_axis_tvalid;
    reg          m_axis_tready;
    wire         m_axis_tlast;

    // Reference scoreboard entry: expected ciphertext + expected LAST flag
    typedef struct packed {
        bit [127:0] ct;
        bit         last;
    } exp_t;
    exp_t exp_q [$];

    integer pass_count = 0;
    integer fail_count = 0;
    integer out_count  = 0;
    integer last_count = 0;     // number of TLAST beats observed at output
    integer pkt_sent   = 0;     // number of packets driven in

    localparam [127:0] NIST_KEY = 128'h000102030405060708090a0b0c0d0e0f;

    bit drive_done = 1'b0;

    //------------------------------------------------------------------------
    // Clock
    //------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    aes_axis_wrapper dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .key           (key),
        .key_load      (key_load),
        .key_ready     (key_ready),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast)
    );

    //------------------------------------------------------------------------
    // Consumer back-pressure: randomly drive M_AXIS_TREADY (~70% ready)
    //------------------------------------------------------------------------
    initial begin
        m_axis_tready = 1'b0;
        @(posedge rst_n);
        forever begin
            @(negedge clk);
            m_axis_tready = ($urandom_range(0, 9) < 7);
        end
    end

    //------------------------------------------------------------------------
    // Output checker: pop reference FIFO on each master handshake
    //------------------------------------------------------------------------
    exp_t e;
    always @(posedge clk) begin
        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            out_count = out_count + 1;
            if (m_axis_tlast) last_count = last_count + 1;
            if (exp_q.size() == 0) begin
                $display("  [FAIL] output with empty reference FIFO: %032h", m_axis_tdata);
                fail_count = fail_count + 1;
            end else begin
                e = exp_q.pop_front();
                if (m_axis_tdata !== e.ct) begin
                    $display("  [FAIL] CT  exp=%032h got=%032h", e.ct, m_axis_tdata);
                    fail_count = fail_count + 1;
                end else if (m_axis_tlast !== e.last) begin
                    $display("  [FAIL] TLAST mismatch on %032h exp=%b got=%b",
                             m_axis_tdata, e.last, m_axis_tlast);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Producer: drive one beat, holding it stable until accepted
    //------------------------------------------------------------------------
    task automatic send_beat(input bit [127:0] d, input bit last);
        bit [127:0] golden;
        int bub;
        begin
            // random leading bubble(s)
            bub = $urandom_range(0, 2);
            repeat (bub) begin
                @(negedge clk);
                s_axis_tvalid = 1'b0;
            end
            // present the beat
            @(negedge clk);
            s_axis_tdata  = d;
            s_axis_tlast  = last;
            s_axis_tvalid = 1'b1;
            // wait for the accepting posedge (TREADY high), holding data stable
            @(posedge clk);
            while (s_axis_tready !== 1'b1) @(posedge clk);
            // accepted on this edge -> push expected result
            aes_encrypt_dpi(NIST_KEY, d, golden);
            exp_q.push_back('{ct: golden, last: last});
        end
    endtask

    //------------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------------
    integer p, b, plen;
    bit [127:0] pt;

    initial begin
        rst_n         = 1'b0;
        key_load      = 1'b0;
        key           = 128'd0;
        s_axis_tdata  = 128'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Load fixed key, wait for expansion
        @(negedge clk);
        key      = NIST_KEY;
        key_load = 1'b1;
        @(negedge clk);
        key_load = 1'b0;
        wait (key_ready === 1'b1);

        $display("\n[AXIS] Streaming 40 random-length packets with back-pressure ...");
        // Drive 40 packets of random length 1..8
        for (p = 0; p < 40; p = p + 1) begin
            plen = $urandom_range(1, 8);
            for (b = 0; b < plen; b = b + 1) begin
                pt = {$urandom, $urandom, $urandom, $urandom};
                send_beat(pt, (b == plen - 1));   // TLAST on final block of packet
            end
            pkt_sent = pkt_sent + 1;
        end

        // Deassert producer and let the pipeline drain
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        drive_done = 1'b1;

        // Drain: wait until all expected outputs have been consumed
        wait (exp_q.size() == 0);
        repeat (5) @(posedge clk);

        //--------------------------------------------------------------------
        // Summary
        //--------------------------------------------------------------------
        $display("\n========================================================");
        $display("  AXIS WRAPPER TB SUMMARY");
        $display("    packets sent     : %0d", pkt_sent);
        $display("    output blocks    : %0d  (pass=%0d fail=%0d)", out_count, pass_count, fail_count);
        $display("    TLAST observed   : %0d  (expected %0d)", last_count, pkt_sent);
        if (fail_count == 0 && last_count == pkt_sent)
            $display("  *** ALL CHECKS PASSED ***");
        else
            $display("  *** FAILURE(S) DETECTED ***");
        $display("========================================================\n");
        $finish;
    end

    //------------------------------------------------------------------------
    // Watchdog
    //------------------------------------------------------------------------
    initial begin
        #500000;
        $display("  [FAIL] Global timeout");
        $finish;
    end

endmodule
