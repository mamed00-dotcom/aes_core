`timescale 1ns / 1ps
//============================================================================
// Module:  aes_top.v
// Project: AES-128 Encryption Core
// Author:  Mohammed Hajjar
// Date:    March 2026
//
// Description:
//   Top-level AES-128 encryption controller with AXI4-Lite slave interface.
//   Designed for Xilinx Vivado IP Integrator and Zynq PS-PL integration.
//   Orchestrates key expansion (10 cycles) and iterative encryption
//   (10 rounds × 1 cycle each) for a total latency of ~21 clock cycles.
//
//   FSM States:
//     IDLE       — Waiting for start command. Inputs may be written.
//     KEY_EXPAND — Generating round keys 1–10 iteratively (10 cycles).
//                  Round key 0 = original key, stored immediately.
//                  On entry, also performs initial AddRoundKey.
//     ENCRYPT    — Executing encryption rounds 1–10 (10 cycles).
//     DONE       — Ciphertext valid. Remains until new start or read.
//
//   AXI4-Lite Register Map (32-bit data bus):
//     Offset  Name            R/W   Description
//     0x00    CTRL            W     Bit[0]: START (self-clearing)
//     0x04    STATUS          R     Bit[0]: BUSY, Bit[1]: VALID
//     0x10    KEY_W0          W     Key[127:96]   (MSB word)
//     0x14    KEY_W1          W     Key[95:64]
//     0x18    KEY_W2          W     Key[63:32]
//     0x1C    KEY_W3          W     Key[31:0]     (LSB word)
//     0x20    PT_W0           W     Plaintext[127:96]
//     0x24    PT_W1           W     Plaintext[95:64]
//     0x28    PT_W2           W     Plaintext[63:32]
//     0x2C    PT_W3           W     Plaintext[31:0]
//     0x30    CT_W0           R     Ciphertext[127:96]
//     0x34    CT_W1           R     Ciphertext[95:64]
//     0x38    CT_W2           R     Ciphertext[63:32]
//     0x3C    CT_W3           R     Ciphertext[31:0]
//
// Target: Xilinx Artix-7 (xc7a100tcsg324-1)
//============================================================================

module aes_top #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 6
)(
    // Clock & Reset
    input  wire                                clk,
    input  wire                                rst_n,          // Active-low synchronous reset

    // =========================================================================
    // AXI4-Lite Slave Interface (AMBA spec-compliant)
    // =========================================================================

    // Write Address Channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [2:0]                          s_axi_awprot,   // Ignored (no protection)
    input  wire                                s_axi_awvalid,
    output reg                                 s_axi_awready,

    // Write Data Channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output reg                                 s_axi_wready,

    // Write Response Channel
    output reg  [1:0]                          s_axi_bresp,
    output reg                                 s_axi_bvalid,
    input  wire                                s_axi_bready,

    // Read Address Channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [2:0]                          s_axi_arprot,   // Ignored (no protection)
    input  wire                                s_axi_arvalid,
    output reg                                 s_axi_arready,

    // Read Data Channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                          s_axi_rresp,
    output reg                                 s_axi_rvalid,
    input  wire                                s_axi_rready,

    // =========================================================================
    // Direct Interface (for standalone testbench use)
    // =========================================================================
    input  wire [127:0] plaintext_direct,
    input  wire [127:0] key_direct,
    input  wire         start_direct,
    input  wire         use_direct,     // 1 = use direct ports, 0 = use AXI4-Lite
    output wire [127:0] ciphertext,
    output wire         valid,
    output wire         busy
);

    //========================================================================
    // FSM State Encoding
    //========================================================================
    localparam [1:0] S_IDLE       = 2'b00,
                     S_KEY_EXPAND = 2'b01,
                     S_ENCRYPT    = 2'b10,
                     S_DONE       = 2'b11;

    reg [1:0]   state, state_next;
    reg [3:0]   round_cnt;              // Counts 1–10 for both phases
    reg [127:0] aes_state;              // Current encryption state
    reg [127:0] round_keys [0:10];      // Pre-computed round key storage
    reg [127:0] key_reg;                // Latched master key
    reg [127:0] pt_reg;                 // Latched plaintext
    reg [127:0] ct_reg;                 // Latched ciphertext output

    //========================================================================
    // AXI4-Lite Write Infrastructure
    //
    // AXI4-Lite requires independent handshakes on AW and W channels.
    // We accept both when both are valid (simple implementation).
    // BRESP is always OKAY (2'b00) — no error conditions defined.
    //========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr_lat;

    // AXI Register File
    reg [127:0] axi_key;
    reg [127:0] axi_pt;
    reg         axi_start;

    //------------------------------------------------------------------------
    // Write Address Channel: Accept when both AW and W are presented
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            axi_awaddr_lat <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready  <= 1'b1;
                axi_awaddr_lat <= s_axi_awaddr;
            end else begin
                s_axi_awready <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------------
    // Write Data Channel: Accept when both AW and W are presented
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n)
            s_axi_wready <= 1'b0;
        else if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid)
            s_axi_wready <= 1'b1;
        else
            s_axi_wready <= 1'b0;
    end

    //------------------------------------------------------------------------
    // Write Response Channel
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (s_axi_awready && s_axi_awvalid &&
                s_axi_wready  && s_axi_wvalid  && ~s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;  // OKAY
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------------
    // Write Decode: Commit register writes on completed handshake
    //------------------------------------------------------------------------
    wire wr_en = s_axi_awready && s_axi_awvalid &&
                 s_axi_wready  && s_axi_wvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_key   <= 128'd0;
            axi_pt    <= 128'd0;
            axi_start <= 1'b0;
        end else begin
            // Self-clear start bit every cycle
            if (axi_start)
                axi_start <= 1'b0;

            if (wr_en) begin
                case (axi_awaddr_lat)
                    6'h00: axi_start          <= s_axi_wdata[0];
                    6'h10: axi_key[127:96]    <= s_axi_wdata;
                    6'h14: axi_key[95:64]     <= s_axi_wdata;
                    6'h18: axi_key[63:32]     <= s_axi_wdata;
                    6'h1C: axi_key[31:0]      <= s_axi_wdata;
                    6'h20: axi_pt[127:96]     <= s_axi_wdata;
                    6'h24: axi_pt[95:64]      <= s_axi_wdata;
                    6'h28: axi_pt[63:32]      <= s_axi_wdata;
                    6'h2C: axi_pt[31:0]       <= s_axi_wdata;
                    default: ; // No action
                endcase
            end
        end
    end

    //------------------------------------------------------------------------
    // Read Address Channel
    //------------------------------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr_lat;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready  <= 1'b0;
            axi_araddr_lat <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (~s_axi_arready && s_axi_arvalid) begin
                s_axi_arready  <= 1'b1;
                axi_araddr_lat <= s_axi_araddr;
            end else begin
                s_axi_arready <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------------
    // Read Data Channel
    //------------------------------------------------------------------------
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata_mux;

    // Combinational read mux
    always @(*) begin
        axi_rdata_mux = 32'd0;
        case (axi_araddr_lat)
            6'h04:   axi_rdata_mux = {30'd0, valid, busy};
            6'h30:   axi_rdata_mux = ct_reg[127:96];
            6'h34:   axi_rdata_mux = ct_reg[95:64];
            6'h38:   axi_rdata_mux = ct_reg[63:32];
            6'h3C:   axi_rdata_mux = ct_reg[31:0];
            default: axi_rdata_mux = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= 32'd0;
        end else begin
            if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;  // OKAY
                s_axi_rdata  <= axi_rdata_mux;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    //========================================================================
    // Input MUX: Direct vs AXI4-Lite
    //========================================================================
    wire        start_pulse  = use_direct ? start_direct : axi_start;
    wire [127:0] key_input   = use_direct ? key_direct   : axi_key;
    wire [127:0] pt_input    = use_direct ? plaintext_direct : axi_pt;

    //========================================================================
    // Key Expansion Datapath (Combinational)
    //========================================================================
    wire [127:0] expanded_key;

    aes_key_expand u_key_expand (
        .key_in  (round_keys[round_cnt - 1]),  // Previous round key
        .round   (round_cnt),                   // Current round (1–10)
        .key_out (expanded_key)                 // New round key
    );

    //========================================================================
    // Encryption Round Datapath (Combinational)
    //========================================================================
    wire [127:0] round_out;
    wire         is_final = (round_cnt == 4'd10);

    aes_round u_round (
        .state_in       (aes_state),
        .round_key      (round_keys[round_cnt]),
        .is_final_round (is_final),
        .state_out      (round_out)
    );

    //========================================================================
    // Status Outputs
    //========================================================================
    assign busy       = (state != S_IDLE) && (state != S_DONE);
    assign valid      = (state == S_DONE);
    assign ciphertext = ct_reg;

    //========================================================================
    // FSM — Next State Logic
    //========================================================================
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (start_pulse)
                    state_next = S_KEY_EXPAND;
            end

            S_KEY_EXPAND: begin
                if (round_cnt == 4'd10)
                    state_next = S_ENCRYPT;
            end

            S_ENCRYPT: begin
                if (round_cnt == 4'd10)
                    state_next = S_DONE;
            end

            S_DONE: begin
                if (start_pulse)
                    state_next = S_KEY_EXPAND;
                else
                    state_next = S_DONE;
            end

            default: state_next = S_IDLE;
        endcase
    end

    //========================================================================
    // FSM — Registered Datapath
    //========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            round_cnt <= 4'd0;
            aes_state <= 128'd0;
            ct_reg    <= 128'd0;
            key_reg   <= 128'd0;
            pt_reg    <= 128'd0;
        end else begin
            state <= state_next;

            case (state)
                //------------------------------------------------------------
                // IDLE: Latch inputs on start
                //------------------------------------------------------------
                S_IDLE: begin
                    if (start_pulse) begin
                        key_reg        <= key_input;
                        pt_reg         <= pt_input;
                        round_keys[0]  <= key_input;
                        round_cnt      <= 4'd1;
                        aes_state      <= pt_input ^ key_input;
                    end
                end

                //------------------------------------------------------------
                // KEY_EXPAND: Generate round keys 1–10
                //------------------------------------------------------------
                S_KEY_EXPAND: begin
                    round_keys[round_cnt] <= expanded_key;
                    if (round_cnt == 4'd10) begin
                        round_cnt <= 4'd1;
                    end else begin
                        round_cnt <= round_cnt + 4'd1;
                    end
                end

                //------------------------------------------------------------
                // ENCRYPT: Apply rounds 1–10 iteratively
                //------------------------------------------------------------
                S_ENCRYPT: begin
                    aes_state <= round_out;
                    if (round_cnt == 4'd10) begin
                        ct_reg    <= round_out;
                        round_cnt <= 4'd0;
                    end else begin
                        round_cnt <= round_cnt + 4'd1;
                    end
                end

                //------------------------------------------------------------
                // DONE: Hold ciphertext; restart on new start_pulse
                //------------------------------------------------------------
                S_DONE: begin
                    if (start_pulse) begin
                        key_reg        <= key_input;
                        pt_reg         <= pt_input;
                        round_keys[0]  <= key_input;
                        round_cnt      <= 4'd1;
                        aes_state      <= pt_input ^ key_input;
                    end
                end

                default: begin
                    state     <= S_IDLE;
                    round_cnt <= 4'd0;
                end
            endcase
        end
    end

endmodule
