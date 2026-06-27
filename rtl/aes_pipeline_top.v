`timescale 1ns / 1ps
//============================================================================
// Module:  aes_pipeline_top.v
// Project: AES-128 Encryption Core - High-Throughput Pipelined Variant
// Author:  Mohammed Hajjar
// Date:    June 2026
//
// Description:
//   Fully-unrolled, 10-stage pipelined AES-128 encryption core.
//   Replaces the iterative FSM + round counter of aes_top.v with ten
//   physically instantiated rounds (aes_round.v) separated by pipeline
//   registers. After the pipeline is filled, ONE 128-bit ciphertext block
//   is produced on EVERY clock cycle.
//
//   Compared to the iterative core (aes_top.v, ~21-cycle latency, 1 block
//   per ~21 cycles), this core unrolls the datapath to ~8x the S-box count
//   (160 datapath S-boxes vs ~20) to buy throughput (1 block/cycle) at a
//   fixed 10-cycle latency. Measured post-route area is only ~3.3x the LUTs,
//   not ~8x: the iterative baseline already carries AXI + FSM + key storage,
//   and S-boxes map efficiently (see docs/AES_PIPELINE_COMPARISON.md).
//
//   ---------------------------------------------------------------------
//   KEY MODEL: FIXED KEY (decision 1A)
//   ---------------------------------------------------------------------
//   The 11 round keys are computed ONCE by a small key-expansion FSM when
//   `key_load` is pulsed, then held static and fanned out to all 10 stages.
//   This is the cheapest option: the per-stage SubWord S-boxes of the key
//   schedule are NOT replicated (saves ~40 S-boxes versus a key-agile
//   design), and it keeps the longest combinational path to a single
//   aes_key_expand instance rather than a 10-deep combinational chain
//   (which would wreck Fmax).
//
//   ASSUMPTION: the key is held stable for the duration of a stream. Blocks
//   in flight share the same key - correct by construction for fixed key.
//   For per-block key agility, the key schedule would instead have to be
//   pipelined in lockstep with the data path (a future variant).
//
//   ---------------------------------------------------------------------
//   PIPELINE STRUCTURE (latency = 10 cycles)
//   ---------------------------------------------------------------------
//     in_data --(comb)--> [AddRoundKey rk0] --> round1 --REG--> stage_data[1]
//                                                 round2 --REG--> stage_data[2]
//                                                  ...
//                                                round10 --REG--> stage_data[10] = out_data
//
//   The initial AddRoundKey (rk0) is combinational at the input; each of the
//   10 rounds is combinational (aes_round.v) and is captured by exactly one
//   pipeline register, giving a clean 10-cycle latency.
//
//   A `valid` bit is shifted alongside the data so the consumer knows which
//   output beats are real (important once the core is fed by a back-pressured
//   AXI4-Stream source in Phase 2).
//
//   ---------------------------------------------------------------------
//   BACK-PRESSURE
//   ---------------------------------------------------------------------
//   `en` is a global clock-enable. When de-asserted, the ENTIRE pipeline
//   freezes coherently (all stage registers hold). This is the simplest
//   correct way to honor a downstream TREADY=0 in Phase 2. (A skid buffer
//   could decouple the stages later, but a global stall is sufficient and
//   easy to reason about.)
//
// Target: Xilinx Artix-7 (xc7a100tcsg324-1)
//============================================================================

module aes_pipeline_top (
    input  wire         clk,
    input  wire         rst_n,        // Active-low synchronous reset

    // ---- Key configuration (fixed-key model) --------------------------------
    input  wire [127:0] key,          // Master key
    input  wire         key_load,     // Pulse 1 cycle to (re)compute round keys
    output wire         key_ready,    // High when round keys are valid

    // ---- Streaming data interface -------------------------------------------
    input  wire         en,           // Global clock-enable (back-pressure / stall)
    input  wire         in_valid,     // Plaintext beat valid
    input  wire [127:0] in_data,      // Plaintext block
    output wire         out_valid,    // Ciphertext beat valid
    output wire [127:0] out_data      // Ciphertext block (10 cycles after input)
);

    //========================================================================
    // 1. Round-key storage
    //========================================================================
    // round_keys[0]  = master key
    // round_keys[1..10] = expanded round keys
    reg [127:0] round_keys [0:10];

    //========================================================================
    // 2. Key-expansion FSM (runs once per key_load, 10 cycles)
    //
    //    Reuses the existing combinational aes_key_expand.v, iterating one
    //    round key per cycle. Because the key is fixed during streaming, this
    //    one-time cost is fully amortized and keeps the combinational depth of
    //    the key schedule to a single S-box layer.
    //========================================================================
    reg  [3:0]   kexp_cnt;        // Current round being expanded (1..10)
    reg          kexp_busy;
    reg          key_ready_r;

    wire [127:0] kexp_out;

    aes_key_expand u_key_expand (
        .key_in  (round_keys[kexp_cnt - 4'd1]),  // Previous round key
        .round   (kexp_cnt),                      // Current round (1..10)
        .key_out (kexp_out)                       // Next round key
    );

    integer ki;
    always @(posedge clk) begin
        if (!rst_n) begin
            kexp_cnt    <= 4'd0;
            kexp_busy   <= 1'b0;
            key_ready_r <= 1'b0;
            for (ki = 0; ki <= 10; ki = ki + 1)
                round_keys[ki] <= 128'd0;
        end else if (key_load) begin
            // Latch master key as round key 0 and kick off expansion
            round_keys[0] <= key;
            kexp_cnt      <= 4'd1;
            kexp_busy     <= 1'b1;
            key_ready_r   <= 1'b0;
        end else if (kexp_busy) begin
            round_keys[kexp_cnt] <= kexp_out;
            if (kexp_cnt == 4'd10) begin
                kexp_busy   <= 1'b0;
                key_ready_r <= 1'b1;       // All 11 round keys now valid
            end else begin
                kexp_cnt <= kexp_cnt + 4'd1;
            end
        end
    end

    assign key_ready = key_ready_r;

    //========================================================================
    // 3. Initial AddRoundKey (combinational, before stage 1)
    //========================================================================
    wire [127:0] state_pre = in_data ^ round_keys[0];

    //========================================================================
    // 4. Ten cascaded rounds, each followed by one pipeline register
    //========================================================================
    // round_in[s]  : combinational input to round s
    // round_out[s] : combinational output of round s (aes_round)
    // stage_data[s]: REGISTERED output of round s  (the pipeline register)
    wire [127:0] round_in  [1:10];
    wire [127:0] round_out [1:10];
    reg  [127:0] stage_data  [1:10];
    reg          stage_valid [1:10];

    // Stage 1 consumes the combinational initial-AddRoundKey result;
    // every later stage consumes the previous stage's REGISTERED output.
    assign round_in[1] = state_pre;

    genvar s;
    generate
        for (s = 2; s <= 10; s = s + 1) begin : gen_chain
            assign round_in[s] = stage_data[s-1];
        end
    endgenerate

    // Instantiate the 10 combinational rounds. Round 10 is the final round
    // (MixColumns bypassed inside aes_round via is_final_round).
    generate
        for (s = 1; s <= 10; s = s + 1) begin : gen_round
            aes_round u_round (
                .state_in       (round_in[s]),
                .round_key      (round_keys[s]),
                .is_final_round (s == 10),
                .state_out      (round_out[s])
            );
        end
    endgenerate

    //========================================================================
    // 5. Pipeline registers + valid shift register
    //========================================================================
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 1; k <= 10; k = k + 1) begin
                stage_data[k]  <= 128'd0;
                stage_valid[k] <= 1'b0;
            end
        end else if (en) begin
            // Stage 1: capture round 1, gate the incoming valid on key_ready
            stage_data[1]  <= round_out[1];
            stage_valid[1] <= in_valid & key_ready_r;

            // Stages 2..10: shift data and valid down the pipe
            for (k = 2; k <= 10; k = k + 1) begin
                stage_data[k]  <= round_out[k];
                stage_valid[k] <= stage_valid[k-1];
            end
        end
        // en == 0 : whole pipeline holds (back-pressure)
    end

    //========================================================================
    // 6. Outputs (tap the last pipeline stage)
    //========================================================================
    assign out_data  = stage_data[10];
    assign out_valid = stage_valid[10];

endmodule
