`timescale 1ns / 1ps
//============================================================================
// Module:  aes_coverage.sv
// Project: AES-128 UVM Verification
// Author:  Mohammed Hajjar
// Date:    March 2026
//
// Description:
//   Functional coverage for the AES-128 core.
//   Bound to the DUT alongside assertions.
//   Targets 95%+ coverage across all groups.
//
// Coverage groups:
//   1. FSM state coverage (all 4 states hit)
//   2. FSM transition coverage (all legal transitions)
//   3. Round counter coverage (all values 0-10)
//   4. Key pattern coverage (all-zeros, all-ones, mixed)
//   5. Plaintext pattern coverage
//   6. Cross: FSM state × round counter
//   7. Operational coverage (back-to-back, key switching)
//============================================================================

module aes_coverage (
    input wire        clk,
    input wire        rst_n,
    input wire [1:0]  state,
    input wire [3:0]  round_cnt,
    input wire        valid,
    input wire        busy,
    input wire        start_direct,
    input wire        use_direct,
    input wire [127:0] key_reg,
    input wire [127:0] pt_reg,
    input wire [127:0] ct_reg
);

    localparam [1:0] S_IDLE       = 2'b00,
                     S_KEY_EXPAND = 2'b01,
                     S_ENCRYPT    = 2'b10,
                     S_DONE       = 2'b11;

    wire start_pulse = use_direct & start_direct;

    // Track previous state for transition coverage
    reg [1:0] state_prev;
    always @(posedge clk) begin
        if (!rst_n)
            state_prev <= S_IDLE;
        else
            state_prev <= state;
    end

    // Track key changes
    reg [127:0] prev_key;
    reg         key_changed;
    always @(posedge clk) begin
        if (!rst_n) begin
            prev_key    <= 128'd0;
            key_changed <= 1'b0;
        end else if (state == S_DONE && valid) begin
            key_changed <= (key_reg != prev_key);
            prev_key    <= key_reg;
        end
    end

    // Track back-to-back operations
    reg back_to_back;
    always @(posedge clk) begin
        if (!rst_n)
            back_to_back <= 1'b0;
        else
            back_to_back <= (state_prev == S_DONE && state == S_KEY_EXPAND);
    end

    //========================================================================
    // COVERGROUP 1: FSM State Coverage
    //========================================================================
    covergroup cg_fsm_state @(posedge clk);
        option.per_instance = 1;
        option.name = "FSM_State_Coverage";

        cp_state: coverpoint state {
            bins idle       = {S_IDLE};
            bins key_expand = {S_KEY_EXPAND};
            bins encrypt    = {S_ENCRYPT};
            bins done       = {S_DONE};
            illegal_bins illegal = default;
        }
    endgroup

    //========================================================================
    // COVERGROUP 2: FSM State Transitions
    //========================================================================
    covergroup cg_fsm_transitions @(posedge clk);
        option.per_instance = 1;
        option.name = "FSM_Transition_Coverage";

        cp_prev: coverpoint state_prev {
            bins idle       = {S_IDLE};
            bins key_expand = {S_KEY_EXPAND};
            bins encrypt    = {S_ENCRYPT};
            bins done       = {S_DONE};
        }

        cp_curr: coverpoint state {
            bins idle       = {S_IDLE};
            bins key_expand = {S_KEY_EXPAND};
            bins encrypt    = {S_ENCRYPT};
            bins done       = {S_DONE};
        }

        // Legal transitions only
        cx_transitions: cross cp_prev, cp_curr {
            bins idle_to_idle       = binsof(cp_prev.idle)       && binsof(cp_curr.idle);
            bins idle_to_keyexp     = binsof(cp_prev.idle)       && binsof(cp_curr.key_expand);
            bins keyexp_to_keyexp   = binsof(cp_prev.key_expand) && binsof(cp_curr.key_expand);
            bins keyexp_to_encrypt  = binsof(cp_prev.key_expand) && binsof(cp_curr.encrypt);
            bins encrypt_to_encrypt = binsof(cp_prev.encrypt)    && binsof(cp_curr.encrypt);
            bins encrypt_to_done    = binsof(cp_prev.encrypt)    && binsof(cp_curr.done);
            bins done_to_done       = binsof(cp_prev.done)       && binsof(cp_curr.done);
            bins done_to_keyexp     = binsof(cp_prev.done)       && binsof(cp_curr.key_expand);
        }
    endgroup

    //========================================================================
    // COVERGROUP 3: Round Counter Values
    //========================================================================
    covergroup cg_round_cnt @(posedge clk);
        option.per_instance = 1;
        option.name = "Round_Counter_Coverage";

        cp_round: coverpoint round_cnt {
            bins round_0  = {0};
            bins round_1  = {1};
            bins round_2  = {2};
            bins round_3  = {3};
            bins round_4  = {4};
            bins round_5  = {5};
            bins round_6  = {6};
            bins round_7  = {7};
            bins round_8  = {8};
            bins round_9  = {9};
            bins round_10 = {10};
            illegal_bins out_of_range = {[11:15]};
        }
    endgroup

    //========================================================================
    // COVERGROUP 4: Cross — FSM State × Round Counter
    //   Ensures all round values are hit in each active state
    //========================================================================
    covergroup cg_state_x_round @(posedge clk);
        option.per_instance = 1;
        option.name = "State_Round_Cross_Coverage";

        cp_state: coverpoint state {
            bins key_expand = {S_KEY_EXPAND};
            bins encrypt    = {S_ENCRYPT};
        }

        cp_round: coverpoint round_cnt {
            bins rounds[] = {[1:10]};
        }

        cx_state_round: cross cp_state, cp_round;
    endgroup

    //========================================================================
    // COVERGROUP 5: Key Patterns
    //   Sampled when encryption completes (valid rises)
    //========================================================================
    covergroup cg_key_patterns @(posedge clk iff (valid && state == S_DONE));
        option.per_instance = 1;
        option.name = "Key_Pattern_Coverage";

        cp_key_type: coverpoint key_reg {
            bins all_zeros = {128'h0};
            bins all_ones  = {128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF};
            bins nist_key  = {128'h000102030405060708090a0b0c0d0e0f};
            bins other     = default;
        }

        cp_key_msb: coverpoint key_reg[127:120] {
            bins low  = {[0:63]};
            bins mid  = {[64:191]};
            bins high = {[192:255]};
        }
    endgroup

    //========================================================================
    // COVERGROUP 6: Plaintext Patterns
    //========================================================================
    covergroup cg_pt_patterns @(posedge clk iff (valid && state == S_DONE));
        option.per_instance = 1;
        option.name = "Plaintext_Pattern_Coverage";

        cp_pt_type: coverpoint pt_reg {
            bins all_zeros = {128'h0};
            bins all_ones  = {128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF};
            bins nist_pt   = {128'h00112233445566778899aabbccddeeff};
            bins other     = default;
        }
    endgroup

    //========================================================================
    // COVERGROUP 7: Operational Scenarios
    //========================================================================
    covergroup cg_operations @(posedge clk iff (valid && state == S_DONE));
        option.per_instance = 1;
        option.name = "Operational_Coverage";

        cp_back_to_back: coverpoint back_to_back {
            bins normal     = {1'b0};
            bins back2back  = {1'b1};
        }

        cp_key_switch: coverpoint key_changed {
            bins same_key   = {1'b0};
            bins new_key    = {1'b1};
        }

        cx_ops: cross cp_back_to_back, cp_key_switch;
    endgroup

    //========================================================================
    // Instantiate all covergroups
    //========================================================================
    cg_fsm_state       cov_fsm_state       = new();
    cg_fsm_transitions cov_fsm_transitions = new();
    cg_round_cnt       cov_round_cnt       = new();
    cg_state_x_round   cov_state_x_round   = new();
    cg_key_patterns    cov_key_patterns     = new();
    cg_pt_patterns     cov_pt_patterns      = new();
    cg_operations      cov_operations       = new();

    //========================================================================
    // Coverage reporting (at end of simulation)
    //========================================================================
    final begin
        $display("======================================================");
        $display("  AES-128 FUNCTIONAL COVERAGE REPORT");
        $display("======================================================");
        $display("  FSM State:       %0.1f%%", cov_fsm_state.get_coverage());
        $display("  FSM Transitions: %0.1f%%", cov_fsm_transitions.get_coverage());
        $display("  Round Counter:   %0.1f%%", cov_round_cnt.get_coverage());
        $display("  State x Round:   %0.1f%%", cov_state_x_round.get_coverage());
        $display("  Key Patterns:    %0.1f%%", cov_key_patterns.get_coverage());
        $display("  PT Patterns:     %0.1f%%", cov_pt_patterns.get_coverage());
        $display("  Operations:      %0.1f%%", cov_operations.get_coverage());
        $display("======================================================");
    end

endmodule
