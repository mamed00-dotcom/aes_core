`timescale 1ns / 1ps
//============================================================================
// Module:  aes_axis_wrapper.v
// Project: AES-128 Encryption Core - Approach B (Streaming), Phase 2a
// Author:  Mohammed Hajjar
// Date:    June 2026
//
// Description:
//   AXI4-Stream wrapper around the pipelined AES core (aes_pipeline_top.v).
//   Turns the core into a pure streaming peripheral:
//
//     S_AXIS (slave)  : plaintext  in  - TDATA/TVALID/TREADY/TLAST
//     M_AXIS (master) : ciphertext out - TDATA/TVALID/TREADY/TLAST
//
//   TDATA is 128 bits (one AES block per beat). After the 10-stage pipeline
//   is filled, one ciphertext beat is produced per clock - full streaming
//   throughput limited only by the slowest of the two stream partners.
//
//   ---------------------------------------------------------------------
//   WHY TLAST (added vs. the original TDATA/TVALID/TREADY-only request)
//   ---------------------------------------------------------------------
//   The DMA / IRQ in Phase 2b needs to know when a *packet* (a buffer of N
//   blocks) ends. That boundary is exactly what TLAST carries. TLAST is
//   pushed through a shadow shift register that advances in lockstep with
//   the data pipeline, so the LAST flag always re-emerges aligned with its
//   own ciphertext block.
//
//   ---------------------------------------------------------------------
//   BACK-PRESSURE - the key correctness point
//   ---------------------------------------------------------------------
//   A filled pipeline cannot "hold back" a result that is about to pop out.
//   So when the downstream consumer is not ready (M_AXIS_TREADY = 0) while a
//   valid output is present, we FREEZE THE ENTIRE PIPELINE via the core's
//   global clock-enable `en`. While frozen we also stop accepting input
//   (S_AXIS_TREADY = 0). Nothing is dropped or reordered.
//
//       en            = ~(out_valid & ~m_axis_tready)   // stall on output block
//       s_axis_tready =  en & key_ready                 // accept only when moving
//       accept (beat) =  s_axis_tvalid & s_axis_tready
//
//   AXI4-Stream compliance:
//     * M_AXIS_TVALID (= out_valid) does NOT depend on M_AXIS_TREADY  -> legal
//     * S_AXIS_TREADY depends on the *other* channel's TREADY only,
//       never on S_AXIS_TVALID                                        -> legal
//     * On a stall, TVALID stays high with stable TDATA/TLAST until the
//       handshake completes                                           -> legal
//
//   Key model: FIXED KEY (Phase decision 1A). Pulse `key_load` once; wait
//   for `key_ready` before streaming. Key is assumed stable for the stream.
//============================================================================

module aes_axis_wrapper (
    input  wire         clk,
    input  wire         rst_n,            // Active-low synchronous reset (ARESETn)

    // ---- Key configuration (side-channel; AXI4-Lite control can wrap this) --
    input  wire [127:0] key,
    input  wire         key_load,
    output wire         key_ready,

    // ---- AXI4-Stream slave : plaintext input --------------------------------
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,

    // ---- AXI4-Stream master : ciphertext output -----------------------------
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast
);

    //========================================================================
    // Pipeline core handshake glue
    //========================================================================
    wire        core_out_valid;
    wire [127:0] core_out_data;
    wire        core_key_ready;

    // Stall the pipeline when an output beat is waiting but the consumer
    // is not ready. Otherwise advance every cycle.
    wire en = ~(core_out_valid & ~m_axis_tready);

    // Accept a new input beat only while advancing and the key is ready.
    assign s_axis_tready = en & core_key_ready;
    wire   accept        = s_axis_tvalid & s_axis_tready;

    //========================================================================
    // Pipelined AES core (fixed key)
    //========================================================================
    aes_pipeline_top u_core (
        .clk       (clk),
        .rst_n     (rst_n),
        .key       (key),
        .key_load  (key_load),
        .key_ready (core_key_ready),
        .en        (en),
        .in_valid  (accept),
        .in_data   (s_axis_tdata),
        .out_valid (core_out_valid),
        .out_data  (core_out_data)
    );

    assign key_ready = core_key_ready;

    //========================================================================
    // TLAST shadow pipeline - 10 deep, advances with `en`, aligned to data
    //========================================================================
    reg tlast_pipe [1:10];

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 1; k <= 10; k = k + 1)
                tlast_pipe[k] <= 1'b0;
        end else if (en) begin
            // Stage 1 carries LAST only for an actually-accepted beat
            tlast_pipe[1] <= s_axis_tlast & accept;
            for (k = 2; k <= 10; k = k + 1)
                tlast_pipe[k] <= tlast_pipe[k-1];
        end
    end

    //========================================================================
    // Master-side stream outputs
    //========================================================================
    assign m_axis_tdata  = core_out_data;
    assign m_axis_tvalid = core_out_valid;
    assign m_axis_tlast  = tlast_pipe[10];   // meaningful when tvalid && tready

endmodule
