`timescale 1ns / 1ps
//============================================================================
// Module:  aes_coproc.v
// Project: AES-128 Core - Approach A (Tightly-Coupled Coprocessor), Phase 3
// Author:  Mohammed Hajjar
// Date:    June 2026
//
// Description:
//   Core-agnostic, memory-mapped AES-128 coprocessor built around the
//   pipelined core (aes_pipeline_top.v). It is an AXI4-Lite SLAVE - the CPU
//   drives it directly with ordinary load/store instructions, so it attaches
//   to ANY RISC-V (Ibex, NEORV32, ...) without a custom-instruction port.
//
//   ---------------------------------------------------------------------
//   POSTED / DECOUPLED MODEL (Phase decision 2A)
//   ---------------------------------------------------------------------
//   The classic problem: a 128-bit block cannot pass through RV32's 32-bit
//   registers in one instruction, and a single blocking instruction that
//   stalls the CPU for the 10-cycle latency throws away the pipeline's
//   throughput. This coprocessor solves both:
//
//     * Operands cross the 32-bit boundary as 4x32-bit MMIO writes (DIN0..3),
//       assembled into a 128-bit block and PUSHed into an INPUT FIFO.
//     * The CPU can POST many blocks back-to-back, then continue doing other
//       work; results land in an OUTPUT FIFO and raise `irq`. The CPU is
//       never stalled waiting for AES - issue and result-collection are
//       decoupled. This keeps the 10-stage pipeline fed -> 1 block/cycle.
//
//   ---------------------------------------------------------------------
//   FLOW CONTROL - credit scheme (no pipeline stall needed)
//   ---------------------------------------------------------------------
//   A block is injected from the input FIFO into the pipeline only when a
//   credit is available. Credits start at OUT_DEPTH; each injection consumes
//   one, each result the CPU pops returns one. Because every in-flight block
//   holds a credit until popped, (in_flight + out_fifo_count) <= OUT_DEPTH at
//   all times, so the output FIFO can ALWAYS accept an emerging result. The
//   pipeline therefore runs free (en = 1) and never has to stall; bubbles
//   simply flow through when no block is ready to inject.
//
//   Key model: FIXED key (Phase decision 1A): write KEY0..3, pulse KEY_LOAD,
//   wait STATUS.key_ready.
//
//   ---------------------------------------------------------------------
//   AXI4-Lite REGISTER MAP (32-bit)
//   ---------------------------------------------------------------------
//     0x00 CTRL    W  bit0 PUSH(enqueue DIN), bit1 POP(dequeue DOUT),
//                     bit2 KEY_LOAD, bit3 FLUSH
//     0x04 STATUS  R  bit0 in_full,  bit1 in_empty,  bit2 out_full,
//                     bit3 out_empty, bit4 key_ready, bit5 busy,
//                     [13:8] out_count, [21:16] in_count
//     0x08 IRQ_EN  W  bit0 interrupt enable
//     0x0C IRQ_STS R  bit0 result_available (= irq line, before enable mask)
//     0x10..0x1C  KEY0..KEY3  W  (KEY0 = key[127:96])
//     0x20..0x2C  DIN0..DIN3  W  (DIN0 = plaintext[127:96])
//     0x30..0x3C  DOUT0..DOUT3 R (DOUT0 = ciphertext[127:96], FIFO head)
//============================================================================

module aes_coproc #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 7,
    parameter IN_DEPTH           = 8,    // input FIFO depth  (power of two)
    parameter OUT_DEPTH          = 16    // output FIFO depth (power of two)
)(
    input  wire                                clk,
    input  wire                                rst_n,

    // ---- AXI4-Lite slave ---------------------------------------------------
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [2:0]                          s_axi_awprot,
    input  wire                                s_axi_awvalid,
    output reg                                 s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output reg                                 s_axi_wready,
    output reg  [1:0]                          s_axi_bresp,
    output reg                                 s_axi_bvalid,
    input  wire                                s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [2:0]                          s_axi_arprot,
    input  wire                                s_axi_arvalid,
    output reg                                 s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                          s_axi_rresp,
    output reg                                 s_axi_rvalid,
    input  wire                                s_axi_rready,

    // ---- Interrupt to the CPU ----------------------------------------------
    output wire                                irq
);

    //========================================================================
    // Register addresses (byte offsets)
    //========================================================================
    localparam ADDR_CTRL   = 7'h00,
               ADDR_STATUS = 7'h04,
               ADDR_IRQEN  = 7'h08,
               ADDR_IRQSTS = 7'h0C,
               ADDR_KEY0   = 7'h10,
               ADDR_DIN0   = 7'h20,
               ADDR_DOUT0  = 7'h30;

    //========================================================================
    // Software-visible registers
    //========================================================================
    reg [127:0] key_r;
    reg [127:0] din_r;
    reg         irq_en;

    // Forward declarations: FIFO status / engine-busy nets are driven further
    // below, but the KEY_LOAD interlock in the write-decode block references
    // `busy`, so they must be declared first (xvlog is order-strict).
    wire in_full, in_empty, out_full, out_empty;
    wire busy;

    //========================================================================
    // AXI4-Lite write channel (handshake mirrors the proven aes_top.v style)
    //========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_lat;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            awaddr_lat    <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid) begin
            s_axi_awready <= 1'b1;
            awaddr_lat    <= s_axi_awaddr;
        end else begin
            s_axi_awready <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n)
            s_axi_wready <= 1'b0;
        else if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid)
            s_axi_wready <= 1'b1;
        else
            s_axi_wready <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else if (s_axi_awready && s_axi_awvalid &&
                     s_axi_wready  && s_axi_wvalid  && ~s_axi_bvalid) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= 2'b00;
        end else if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end
    end

    wire wr_en = s_axi_awready && s_axi_awvalid &&
                 s_axi_wready  && s_axi_wvalid;

    //========================================================================
    // Write decode -> command pulses + register loads
    //========================================================================
    reg push_pulse, pop_pulse, keyload_pulse, flush_pulse;

    always @(posedge clk) begin
        if (!rst_n) begin
            key_r         <= 128'd0;
            din_r         <= 128'd0;
            irq_en        <= 1'b0;
            push_pulse    <= 1'b0;
            pop_pulse     <= 1'b0;
            keyload_pulse <= 1'b0;
            flush_pulse   <= 1'b0;
        end else begin
            // command pulses are single-cycle
            push_pulse    <= 1'b0;
            pop_pulse     <= 1'b0;
            keyload_pulse <= 1'b0;
            flush_pulse   <= 1'b0;

            if (wr_en) begin
                case (awaddr_lat)
                    ADDR_CTRL: begin
                        push_pulse    <= s_axi_wdata[0];
                        pop_pulse     <= s_axi_wdata[1];
                        // Fixed-key interlock: a KEY_LOAD recomputes the round
                        // keys over 10 cycles. If issued while blocks are in
                        // flight, in-flight stages would finish under freshly
                        // recomputed keys -> silent corruption. Honor KEY_LOAD
                        // only when the engine is fully drained (~busy). FLUSH
                        // first if you need to force a re-key mid-stream.
                        keyload_pulse <= s_axi_wdata[2] & ~busy;
                        flush_pulse   <= s_axi_wdata[3];
                    end
                    ADDR_IRQEN:        irq_en        <= s_axi_wdata[0];
                    ADDR_KEY0 + 7'h0:  key_r[127:96] <= s_axi_wdata;
                    ADDR_KEY0 + 7'h4:  key_r[95:64]  <= s_axi_wdata;
                    ADDR_KEY0 + 7'h8:  key_r[63:32]  <= s_axi_wdata;
                    ADDR_KEY0 + 7'hC:  key_r[31:0]   <= s_axi_wdata;
                    ADDR_DIN0 + 7'h0:  din_r[127:96] <= s_axi_wdata;
                    ADDR_DIN0 + 7'h4:  din_r[95:64]  <= s_axi_wdata;
                    ADDR_DIN0 + 7'h8:  din_r[63:32]  <= s_axi_wdata;
                    ADDR_DIN0 + 7'hC:  din_r[31:0]   <= s_axi_wdata;
                    default: ;
                endcase
            end
        end
    end

    //========================================================================
    // Input / output FIFOs + AES pipeline + credit-based flow control
    //========================================================================
    wire [127:0]  in_dout, out_dout;
    wire [$clog2(IN_DEPTH):0]  in_count;
    wire [$clog2(OUT_DEPTH):0] out_count;

    wire core_key_ready;
    wire core_out_valid;
    wire [127:0] core_out_data;

    // Credit counter: room reserved in the output FIFO for in-flight blocks.
    reg [$clog2(OUT_DEPTH):0] credits;

    // Inject a block whenever one is staged, the key is ready, and a credit
    // is free. en = 1 always, so the core accepts it the same cycle.
    wire inject     = ~in_empty & core_key_ready & (credits != 0);
    wire out_pop    = pop_pulse & ~out_empty;     // CPU consumes a result
    wire flush      = flush_pulse;

    always @(posedge clk) begin
        if (!rst_n)
            credits <= OUT_DEPTH[$clog2(OUT_DEPTH):0];
        else if (flush)
            credits <= OUT_DEPTH[$clog2(OUT_DEPTH):0];
        else
            credits <= credits - (inject ? 1'b1 : 1'b0)
                                + (out_pop ? 1'b1 : 1'b0);
    end

    // ---- Input FIFO : staged plaintext blocks ------------------------------
    aes_sync_fifo #(.W(128), .DEPTH(IN_DEPTH)) u_in_fifo (
        .clk   (clk),
        .rst_n (rst_n & ~flush),
        .push  (push_pulse & ~in_full),
        .din   (din_r),
        .pop   (inject),
        .dout  (in_dout),
        .full  (in_full),
        .empty (in_empty),
        .count (in_count)
    );

    // ---- Pipelined AES core (runs free) ------------------------------------
    aes_pipeline_top u_core (
        .clk       (clk),
        .rst_n     (rst_n),
        .key       (key_r),
        .key_load  (keyload_pulse),
        .key_ready (core_key_ready),
        .en        (1'b1),
        .in_valid  (inject),
        .in_data   (in_dout),
        .out_valid (core_out_valid),
        .out_data  (core_out_data)
    );

    // ---- Output FIFO : ciphertext results (push always fits by credits) ----
    aes_sync_fifo #(.W(128), .DEPTH(OUT_DEPTH)) u_out_fifo (
        .clk   (clk),
        .rst_n (rst_n & ~flush),
        .push  (core_out_valid),
        .din   (core_out_data),
        .pop   (out_pop),
        .dout  (out_dout),
        .full  (out_full),
        .empty (out_empty),
        .count (out_count)
    );

    wire result_avail = ~out_empty;
    assign busy       = ~in_empty | ~out_empty |
                        (credits != OUT_DEPTH[$clog2(OUT_DEPTH):0]);

    assign irq = irq_en & result_avail;

    //========================================================================
    // AXI4-Lite read channel
    //========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_lat;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            araddr_lat    <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else if (~s_axi_arready && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            araddr_lat    <= s_axi_araddr;
        end else begin
            s_axi_arready <= 1'b0;
        end
    end

    // Zero-extend the FIFO counts to fixed 6-bit STATUS fields (the native
    // count widths depend on IN_DEPTH/OUT_DEPTH).
    wire [5:0] in_cnt6  = in_count;
    wire [5:0] out_cnt6 = out_count;

    reg [C_S_AXI_DATA_WIDTH-1:0] status_word;
    always @(*) begin
        status_word        = 32'd0;
        status_word[0]     = in_full;
        status_word[1]     = in_empty;
        status_word[2]     = out_full;
        status_word[3]     = out_empty;
        status_word[4]     = core_key_ready;
        status_word[5]     = busy;
        status_word[13:8]  = out_cnt6;
        status_word[21:16] = in_cnt6;
    end

    reg [C_S_AXI_DATA_WIDTH-1:0] rdata_mux;
    always @(*) begin
        rdata_mux = 32'd0;
        case (araddr_lat)
            ADDR_STATUS: rdata_mux = status_word;
            ADDR_IRQSTS: rdata_mux = {31'd0, result_avail};
            ADDR_DOUT0 + 7'h0: rdata_mux = out_dout[127:96];
            ADDR_DOUT0 + 7'h4: rdata_mux = out_dout[95:64];
            ADDR_DOUT0 + 7'h8: rdata_mux = out_dout[63:32];
            ADDR_DOUT0 + 7'hC: rdata_mux = out_dout[31:0];
            default: rdata_mux = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= 32'd0;
        end else if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= rdata_mux;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

endmodule


//============================================================================
// Module:  aes_sync_fifo
// Description:
//   Simple synchronous FIFO with first-word-fall-through (dout always shows
//   the head). DEPTH must be a power of two so the pointers wrap naturally.
//============================================================================
module aes_sync_fifo #(
    parameter W     = 128,
    parameter DEPTH = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  push,
    input  wire [W-1:0]          din,
    input  wire                  pop,
    output wire [W-1:0]          dout,
    output wire                  full,
    output wire                  empty,
    output wire [$clog2(DEPTH):0] count
);
    localparam AW = $clog2(DEPTH);

    reg [W-1:0]   mem [0:DEPTH-1];
    reg [AW-1:0]  wptr, rptr;
    reg [AW:0]    cnt;

    assign full  = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign count = cnt;
    assign dout  = mem[rptr];          // first-word-fall-through head

    always @(posedge clk) begin
        if (!rst_n) begin
            wptr <= 0;
            rptr <= 0;
            cnt  <= 0;
        end else begin
            case ({push & ~full, pop & ~empty})
                2'b10: begin                 // push only
                    mem[wptr] <= din;
                    wptr <= wptr + 1'b1;
                    cnt  <= cnt + 1'b1;
                end
                2'b01: begin                 // pop only
                    rptr <= rptr + 1'b1;
                    cnt  <= cnt - 1'b1;
                end
                2'b11: begin                 // simultaneous push + pop
                    mem[wptr] <= din;
                    wptr <= wptr + 1'b1;
                    rptr <= rptr + 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
