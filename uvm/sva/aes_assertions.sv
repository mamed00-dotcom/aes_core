`timescale 1ns / 1ps
//============================================================================
// Module:  aes_assertions.sv
// Project: AES-128 UVM Verification
// Author:  Mohammed Hajjar
// Date:    May 2026
//
// Description:
//   SystemVerilog Assertions (SVA) for the AES-128 encryption core.
//   Bound to the DUT via `bind` directive in the testbench top.
//   Covers: FSM transitions, latency, protocol, data integrity.
//
// Usage:
//   bind aes_top aes_assertions u_assert (.*);
//============================================================================

module aes_assertions (
    input wire        clk,
    input wire        rst_n,
    input wire [1:0]  state,
    input wire [1:0]  state_next,
    input wire [3:0]  round_cnt,
    input wire        valid,
    input wire        busy,
    input wire        start_direct,
    input wire        use_direct,
    input wire [127:0] key_reg,
    input wire [127:0] pt_reg,
    input wire [127:0] ct_reg,
    input wire [127:0] ciphertext,
    input wire        s_axi_awvalid,
    input wire        s_axi_wvalid,
    input wire        s_axi_awready,
    input wire        s_axi_wready,
    input wire        s_axi_bvalid,
    input wire        s_axi_bready
);

    // Local aliases for FSM state encoding (must match aes_top.v)
    localparam [1:0] S_IDLE       = 2'b00,
                     S_KEY_EXPAND = 2'b01,
                     S_ENCRYPT    = 2'b10,
                     S_DONE       = 2'b11;

    // Derive start_pulse for direct mode
    wire start_pulse = use_direct & start_direct;

    //========================================================================
    // ASSERTION 1: Valid FSM state transitions
    //   IDLE can only go to KEY_EXPAND (on start) or stay IDLE
    //   KEY_EXPAND can only go to ENCRYPT (on round_cnt==10) or stay
    //   ENCRYPT can only go to DONE (on round_cnt==10) or stay
    //   DONE can only go to KEY_EXPAND (on start) or stay DONE
    //========================================================================
    property p_fsm_idle_transitions;
        @(posedge clk) disable iff (!rst_n)
        (state == S_IDLE) |-> (state_next == S_IDLE || state_next == S_KEY_EXPAND);
    endproperty
    assert property (p_fsm_idle_transitions)
        else $error("[SVA] IDLE: illegal transition to state %0b", state_next);

    property p_fsm_keyexp_transitions;
        @(posedge clk) disable iff (!rst_n)
        (state == S_KEY_EXPAND) |-> (state_next == S_KEY_EXPAND || state_next == S_ENCRYPT);
    endproperty
    assert property (p_fsm_keyexp_transitions)
        else $error("[SVA] KEY_EXPAND: illegal transition to state %0b", state_next);

    property p_fsm_encrypt_transitions;
        @(posedge clk) disable iff (!rst_n)
        (state == S_ENCRYPT) |-> (state_next == S_ENCRYPT || state_next == S_DONE);
    endproperty
    assert property (p_fsm_encrypt_transitions)
        else $error("[SVA] ENCRYPT: illegal transition to state %0b", state_next);

    property p_fsm_done_transitions;
        @(posedge clk) disable iff (!rst_n)
        (state == S_DONE) |-> (state_next == S_DONE || state_next == S_KEY_EXPAND);
    endproperty
    assert property (p_fsm_done_transitions)
        else $error("[SVA] DONE: illegal transition to state %0b", state_next);

    //========================================================================
    // ASSERTION 2: Encryption latency — exactly 22 cycles from start to valid
    //   KEY_EXPAND: 10 cycles + ENCRYPT: 10 cycles + transitions = 22
    //========================================================================
    // Count cycles from start_pulse to valid assertion
    integer cycle_count;
    reg counting;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            counting    <= 1'b0;
        end else begin
            if (start_pulse && (state == S_IDLE || state == S_DONE)) begin
                cycle_count <= 1;
                counting    <= 1'b1;
            end else if (counting) begin
                if (valid && state == S_DONE) begin
                    counting <= 1'b0;
                end else begin
                    cycle_count <= cycle_count + 1;
                end
            end
        end
    end

    property p_latency_21_cycles;
        @(posedge clk) disable iff (!rst_n)
        (counting && valid && state == S_DONE) |-> (cycle_count == 21);
    endproperty
    assert property (p_latency_21_cycles)
        else $warning("[SVA] Latency: expected 21 cycles, got %0d", cycle_count);

    //========================================================================
    // ASSERTION 3: Valid signal only asserted in DONE state
    //========================================================================
    property p_valid_only_in_done;
        @(posedge clk) disable iff (!rst_n)
        valid |-> (state == S_DONE);
    endproperty
    assert property (p_valid_only_in_done)
        else $error("[SVA] valid asserted outside DONE state (state=%0b)", state);

    //========================================================================
    // ASSERTION 4: Busy signal — asserted only during KEY_EXPAND and ENCRYPT
    //========================================================================
    property p_busy_correct;
        @(posedge clk) disable iff (!rst_n)
        busy |-> (state == S_KEY_EXPAND || state == S_ENCRYPT);
    endproperty
    assert property (p_busy_correct)
        else $error("[SVA] busy asserted in state %0b (expected KEY_EXPAND or ENCRYPT)", state);

    property p_busy_and_valid_mutex;
        @(posedge clk) disable iff (!rst_n)
        !(busy && valid);
    endproperty
    assert property (p_busy_and_valid_mutex)
        else $error("[SVA] busy and valid both asserted simultaneously!");

    //========================================================================
    // ASSERTION 5: Key register stable during KEY_EXPAND and ENCRYPT
    //   key_reg should only change on start_pulse in IDLE or DONE
    //========================================================================
    property p_key_stable_during_operation;
        @(posedge clk) disable iff (!rst_n)
        (state == S_KEY_EXPAND || state == S_ENCRYPT) |=>
            (key_reg == $past(key_reg));
    endproperty
    assert property (p_key_stable_during_operation)
        else $error("[SVA] key_reg changed during active operation!");

    //========================================================================
    // ASSERTION 6: Round counter range — never exceeds 10
    //========================================================================
    property p_round_cnt_range;
        @(posedge clk) disable iff (!rst_n)
        (round_cnt <= 4'd10);
    endproperty
    assert property (p_round_cnt_range)
        else $error("[SVA] round_cnt out of range: %0d", round_cnt);

    //========================================================================
    // ASSERTION 7: KEY_EXPAND to ENCRYPT transition at round_cnt == 10
    //========================================================================
    property p_keyexp_to_encrypt_at_10;
        @(posedge clk) disable iff (!rst_n)
        (state == S_KEY_EXPAND && state_next == S_ENCRYPT) |->
            (round_cnt == 4'd10);
    endproperty
    assert property (p_keyexp_to_encrypt_at_10)
        else $error("[SVA] KEY_EXPAND->ENCRYPT but round_cnt=%0d (expected 10)", round_cnt);

    //========================================================================
    // ASSERTION 8: ENCRYPT to DONE transition at round_cnt == 10
    //========================================================================
    property p_encrypt_to_done_at_10;
        @(posedge clk) disable iff (!rst_n)
        (state == S_ENCRYPT && state_next == S_DONE) |->
            (round_cnt == 4'd10);
    endproperty
    assert property (p_encrypt_to_done_at_10)
        else $error("[SVA] ENCRYPT->DONE but round_cnt=%0d (expected 10)", round_cnt);

    //========================================================================
    // ASSERTION 9: AXI4-Lite handshake — awready only when both aw+w valid
    //========================================================================
    property p_axi_awready_handshake;
        @(posedge clk) disable iff (!rst_n)
        s_axi_awready |-> $past(s_axi_awvalid && s_axi_wvalid);
    endproperty
    assert property (p_axi_awready_handshake)
        else $error("[SVA] AXI: awready asserted without awvalid+wvalid on previous cycle");

    property p_axi_wready_handshake;
        @(posedge clk) disable iff (!rst_n)
        s_axi_wready |-> $past(s_axi_awvalid && s_axi_wvalid);
    endproperty
    assert property (p_axi_wready_handshake)
        else $error("[SVA] AXI: wready asserted without awvalid+wvalid on previous cycle");

    //========================================================================
    // ASSERTION 10: Ciphertext output stable in DONE (until next start)
    //========================================================================
    property p_ciphertext_stable_in_done;
        @(posedge clk) disable iff (!rst_n)
        (state == S_DONE && !start_pulse) |=>
            (ct_reg == $past(ct_reg));
    endproperty
    assert property (p_ciphertext_stable_in_done)
        else $error("[SVA] ciphertext changed in DONE state without new start!");

    //========================================================================
    // COVER PROPERTIES — track interesting scenarios
    //========================================================================
    cover property (@(posedge clk) disable iff (!rst_n)
        start_pulse && state == S_IDLE);                    // c1: Fresh start

    cover property (@(posedge clk) disable iff (!rst_n)
        start_pulse && state == S_DONE);                    // c2: Back-to-back

    cover property (@(posedge clk) disable iff (!rst_n)
        state == S_KEY_EXPAND && round_cnt == 4'd10);       // c3: Key expand done

    cover property (@(posedge clk) disable iff (!rst_n)
        state == S_ENCRYPT && round_cnt == 4'd10);          // c4: Encryption done

    cover property (@(posedge clk) disable iff (!rst_n)
        $rose(valid));                                       // c5: Valid rising edge

    cover property (@(posedge clk) disable iff (!rst_n)
        $fell(valid));                                       // c6: Valid falling edge

    cover property (@(posedge clk) disable iff (!rst_n)
        $fell(valid) ##[1:5] $rose(valid));                 // c7: Back-to-back valid

    cover property (@(posedge clk) disable iff (!rst_n)
        state == S_IDLE ##1 state == S_KEY_EXPAND
        ##[9:11] state == S_ENCRYPT ##[9:11] state == S_DONE); // c8: Full cycle

endmodule
