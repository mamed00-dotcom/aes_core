`timescale 1ns / 1ps
//============================================================================
// Module:  aes_stream_system.v
// Project: AES-128 Core - Approach B (Streaming), Phase 2b
// Author:  Mohammed Hajjar
// Date:    June 2026
//
// Description:
//   Top-level integration of the streaming AES subsystem:
//
//     +-----------+   rd   +---------+  S_AXIS  +------------------+
//     |  buffer   |------->|         |--------->|  aes_axis_wrapper|
//     |  (LUTRAM) |        |  aes_dma|          |  (10-stage pipe) |
//     |           |<-------|         |<---------|                  |
//     +-----------+   wr   +---------+  M_AXIS  +------------------+
//                              |  irq -> RISC-V
//
//   The DMA reads plaintext blocks from the on-chip buffer, streams them
//   through the pipelined AES core, and writes the ciphertext back to the
//   buffer, raising `irq` when the last block lands. In a Zynq/RISC-V SoC
//   the buffer would be shared DDR/BRAM and the control/status ports would
//   be AXI4-Lite registers; here they are direct ports for clarity.
//
//   Key model: FIXED key (Phase decision 1A). Pulse key_load, wait key_ready,
//   then pulse start.
//============================================================================

//----------------------------------------------------------------------------
// Simple combinational-read scratchpad buffer (1 read port + 1 write port).
// Synthesizes to LUT/distributed RAM. Read is asynchronous so the DMA MM2S
// path sustains one block/cycle without a prefetch FIFO.
//----------------------------------------------------------------------------
module aes_ram #(
    parameter ADDR_W = 12,
    parameter DEPTH  = 256
)(
    input  wire                clk,
    input  wire [ADDR_W-1:0]   rd_addr,
    output wire [127:0]        rd_data,
    input  wire                wr_en,
    input  wire [ADDR_W-1:0]   wr_addr,
    input  wire [127:0]        wr_data
);
    reg [127:0] mem [0:DEPTH-1];

    assign rd_data = mem[rd_addr];           // asynchronous (combinational) read

    always @(posedge clk)
        if (wr_en)
            mem[wr_addr] <= wr_data;          // synchronous write
endmodule


//----------------------------------------------------------------------------
// Streaming AES system top
//----------------------------------------------------------------------------
module aes_stream_system #(
    parameter ADDR_W = 12,
    parameter LEN_W  = 16,
    parameter DEPTH  = 256
)(
    input  wire                clk,
    input  wire                rst_n,

    // Key configuration
    input  wire [127:0]        key,
    input  wire                key_load,
    output wire                key_ready,

    // DMA control / status
    input  wire                start,
    input  wire [ADDR_W-1:0]   src_base,
    input  wire [ADDR_W-1:0]   dst_base,
    input  wire [LEN_W-1:0]    num_blocks,
    output wire                busy,
    output wire                done,
    output wire                irq
);

    // ---- DMA <-> buffer ----------------------------------------------------
    wire [ADDR_W-1:0] rd_addr;
    wire [127:0]      rd_data;
    wire              wr_en;
    wire [ADDR_W-1:0] wr_addr;
    wire [127:0]      wr_data;

    // ---- DMA <-> AES wrapper streams ---------------------------------------
    wire [127:0]      s_tdata;   // plaintext  : DMA master -> wrapper slave
    wire              s_tvalid;
    wire              s_tready;
    wire              s_tlast;

    wire [127:0]      m_tdata;   // ciphertext : wrapper master -> DMA slave
    wire              m_tvalid;
    wire              m_tready;
    wire              m_tlast;

    //========================================================================
    // On-chip buffer
    //========================================================================
    aes_ram #(.ADDR_W(ADDR_W), .DEPTH(DEPTH)) u_ram (
        .clk     (clk),
        .rd_addr (rd_addr),
        .rd_data (rd_data),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data)
    );

    //========================================================================
    // DMA engine
    //========================================================================
    aes_dma #(.ADDR_W(ADDR_W), .LEN_W(LEN_W)) u_dma (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .src_base   (src_base),
        .dst_base   (dst_base),
        .num_blocks (num_blocks),
        .busy       (busy),
        .done       (done),
        .irq        (irq),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .wr_en      (wr_en),
        .wr_addr    (wr_addr),
        .wr_data    (wr_data),
        .out_tdata  (s_tdata),
        .out_tvalid (s_tvalid),
        .out_tready (s_tready),
        .out_tlast  (s_tlast),
        .in_tdata   (m_tdata),
        .in_tvalid  (m_tvalid),
        .in_tready  (m_tready),
        .in_tlast   (m_tlast)
    );

    //========================================================================
    // Pipelined AES, AXI4-Stream wrapped
    //========================================================================
    aes_axis_wrapper u_aes (
        .clk           (clk),
        .rst_n         (rst_n),
        .key           (key),
        .key_load      (key_load),
        .key_ready     (key_ready),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .s_axis_tlast  (s_tlast),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast)
    );

endmodule
