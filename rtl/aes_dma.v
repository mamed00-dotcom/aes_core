`timescale 1ns / 1ps
//============================================================================
// Module:  aes_dma.v
// Project: AES-128 Core - Approach B (Streaming), Phase 2b
// Author:  Mohammed Hajjar
// Date:    June 2026
//
// Description:
//   Lightweight scatter-free DMA engine that drives the streaming AES core.
//   It performs two concurrent transfers between an on-chip block buffer and
//   the AES AXI4-Stream wrapper:
//
//     MM2S (read  path) : buffer[src_base + i]  --> AXIS master --> AES in
//     S2MM (write path) : AES out --> AXIS slave --> buffer[dst_base + j]
//
//   Because MM2S and S2MM run in parallel, the engine streams: while the
//   first ciphertext blocks are being written back, later plaintext blocks
//   are still being fetched and injected - keeping the AES pipeline full.
//
//   Completion is detected from TLAST on the returning ciphertext stream
//   (the last input block's LAST flag, carried through the 10-stage pipeline
//   by the wrapper). On completion a single-cycle `irq` pulse is raised and
//   `done` latches until the next `start`.
//
//   NOTE ON THE BUFFER: this engine assumes a COMBINATIONAL-READ buffer
//   (distributed/LUT RAM scratchpad), so rd_data is valid in the same cycle
//   as rd_addr and MM2S sustains one block/cycle with no prefetch FIFO. A
//   BRAM-backed buffer (1-cycle registered read) would simply require a small
//   prefetch FIFO on the MM2S side; the control logic here is unchanged.
//
//   This is a deliberately compact stand-in for a full AXI4 memory-mapped
//   DMA (e.g. Xilinx AXI DMA). It keeps the focus on the streaming datapath
//   and the IRQ hand-off to the RISC-V, and is fully synthesizable.
//============================================================================

module aes_dma #(
    parameter ADDR_W = 12,             // Buffer address width (in 128-bit words)
    parameter LEN_W  = 16              // Transfer-length counter width
)(
    input  wire                clk,
    input  wire                rst_n,

    // ---- Control / status (would be AXI4-Lite registers in a SoC) ----------
    input  wire                start,        // Pulse to begin a transfer
    input  wire [ADDR_W-1:0]   src_base,     // First plaintext word address
    input  wire [ADDR_W-1:0]   dst_base,     // First ciphertext word address
    input  wire [LEN_W-1:0]    num_blocks,   // Number of 128-bit blocks
    output wire                busy,
    output reg                 done,         // Latches high after completion
    output reg                 irq,          // 1-cycle completion pulse

    // ---- Buffer read port (combinational read) -----------------------------
    output wire [ADDR_W-1:0]   rd_addr,
    input  wire [127:0]        rd_data,

    // ---- Buffer write port -------------------------------------------------
    output wire                wr_en,
    output wire [ADDR_W-1:0]   wr_addr,
    output wire [127:0]        wr_data,

    // ---- AXIS master : plaintext out to AES wrapper S_AXIS ------------------
    output wire [127:0]        out_tdata,
    output wire                out_tvalid,
    input  wire                out_tready,
    output wire                out_tlast,

    // ---- AXIS slave : ciphertext in from AES wrapper M_AXIS -----------------
    input  wire [127:0]        in_tdata,
    input  wire                in_tvalid,
    output wire                in_tready,
    input  wire                in_tlast
);

    //========================================================================
    // FSM
    //========================================================================
    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1,
                     S_DONE = 2'd2;

    reg [1:0]        state;
    reg [ADDR_W-1:0] src_q, dst_q;
    reg [LEN_W-1:0]  nblk_q;
    reg [LEN_W-1:0]  rd_idx;     // blocks injected   (MM2S)
    reg [LEN_W-1:0]  wr_idx;     // blocks written back (S2MM)

    //========================================================================
    // MM2S read/stream-out path (combinational handshake)
    //========================================================================
    wire mm2s_active = (state == S_RUN) && (rd_idx < nblk_q);

    assign rd_addr    = src_q + rd_idx[ADDR_W-1:0];
    assign out_tdata  = rd_data;
    assign out_tvalid = mm2s_active;
    assign out_tlast  = mm2s_active && (rd_idx == nblk_q - 1'b1);

    wire mm2s_fire = out_tvalid && out_tready;     // a plaintext block injected

    //========================================================================
    // S2MM stream-in/write path
    //========================================================================
    assign in_tready = (state == S_RUN);
    wire   s2mm_fire = in_tvalid && in_tready;      // a ciphertext block returned

    assign wr_en   = s2mm_fire;
    assign wr_addr = dst_q + wr_idx[ADDR_W-1:0];
    assign wr_data = in_tdata;

    assign busy = (state == S_RUN);

    //========================================================================
    // Sequential control
    //========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            src_q  <= {ADDR_W{1'b0}};
            dst_q  <= {ADDR_W{1'b0}};
            nblk_q <= {LEN_W{1'b0}};
            rd_idx <= {LEN_W{1'b0}};
            wr_idx <= {LEN_W{1'b0}};
            done   <= 1'b0;
            irq    <= 1'b0;
        end else begin
            irq <= 1'b0;   // default: single-cycle pulse

            case (state)
                //------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        src_q  <= src_base;
                        dst_q  <= dst_base;
                        nblk_q <= num_blocks;
                        rd_idx <= {LEN_W{1'b0}};
                        wr_idx <= {LEN_W{1'b0}};
                        if (num_blocks == {LEN_W{1'b0}}) begin
                            // Zero-length transfer: nothing to stream, so no
                            // TLAST would ever return. Complete immediately
                            // instead of hanging in S_RUN with busy stuck high.
                            done  <= 1'b1;
                            irq   <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            done  <= 1'b0;
                            state <= S_RUN;
                        end
                    end
                end

                //------------------------------------------------------------
                S_RUN: begin
                    // Advance the read (injection) index on each MM2S beat
                    if (mm2s_fire)
                        rd_idx <= rd_idx + 1'b1;

                    // Advance the write index on each returned ciphertext block;
                    // the block tagged TLAST is the last one -> finish.
                    if (s2mm_fire) begin
                        wr_idx <= wr_idx + 1'b1;
                        if (in_tlast) begin
                            state <= S_DONE;
                            done  <= 1'b1;
                            irq   <= 1'b1;     // notify RISC-V
                        end
                    end
                end

                //------------------------------------------------------------
                S_DONE: begin
                    if (start) begin           // allow a new transfer
                        src_q  <= src_base;
                        dst_q  <= dst_base;
                        nblk_q <= num_blocks;
                        rd_idx <= {LEN_W{1'b0}};
                        wr_idx <= {LEN_W{1'b0}};
                        if (num_blocks == {LEN_W{1'b0}}) begin
                            done  <= 1'b1;
                            irq   <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            done  <= 1'b0;
                            state <= S_RUN;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
