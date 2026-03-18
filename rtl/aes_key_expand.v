`timescale 1ns / 1ps
//============================================================================
// Module:  aes_key_expand.v
// Project: AES-128 Encryption Core
// Author:  Mohammed Hajjar
// Date:    March 2026
//
// Description:
//   Iterative AES-128 key expansion per FIPS 197, Section 5.2.
//   Generates one 128-bit round key per clock cycle from the previous
//   round key. Requires 4× S-box instances for the SubWord operation.
//
//   Algorithm per round j (1 ≤ j ≤ 10):
//     temp  = RotWord(w[4j-1])
//     temp  = SubWord(temp) ⊕ {Rcon[j], 24'h0}
//     w[4j]   = w[4(j-1)]   ⊕ temp
//     w[4j+1] = w[4(j-1)+1] ⊕ w[4j]
//     w[4j+2] = w[4(j-1)+2] ⊕ w[4j+1]
//     w[4j+3] = w[4(j-1)+3] ⊕ w[4j+2]
//
// Interface:
//   clk         — System clock
//   key_in      — Previous round key (128 bits)
//   round       — Current round number (1–10)
//   key_out     — Next round key (128 bits), combinational output
//
// Latency: 0 cycles (combinational; registered externally by aes_top)
//============================================================================

module aes_key_expand (
    input  wire [127:0] key_in,     // Previous round key
    input  wire [3:0]   round,      // Round number (1-10)
    output wire [127:0] key_out     // Next round key
);

    //------------------------------------------------------------------------
    // Extract the four 32-bit words from the input key
    // Word order: w0 = MSB (key_in[127:96]), w3 = LSB (key_in[31:0])
    //------------------------------------------------------------------------
    wire [31:0] w0 = key_in[127:96];
    wire [31:0] w1 = key_in[95:64];
    wire [31:0] w2 = key_in[63:32];
    wire [31:0] w3 = key_in[31:0];

    //------------------------------------------------------------------------
    // Step 1: RotWord — Rotate last word (w3) left by one byte
    //   [a0, a1, a2, a3] → [a1, a2, a3, a0]
    //------------------------------------------------------------------------
    wire [31:0] rot_word = {w3[23:16], w3[15:8], w3[7:0], w3[31:24]};

    //------------------------------------------------------------------------
    // Step 2: SubWord — Apply S-box to each byte of the rotated word
    //------------------------------------------------------------------------
    wire [7:0] sub_b0, sub_b1, sub_b2, sub_b3;

    aes_sbox sbox_0 (.in(rot_word[31:24]), .out(sub_b0));
    aes_sbox sbox_1 (.in(rot_word[23:16]), .out(sub_b1));
    aes_sbox sbox_2 (.in(rot_word[15:8]),  .out(sub_b2));
    aes_sbox sbox_3 (.in(rot_word[7:0]),   .out(sub_b3));

    wire [31:0] sub_word = {sub_b0, sub_b1, sub_b2, sub_b3};

    //------------------------------------------------------------------------
    // Step 3: Rcon — Round constant (only MSB byte is non-zero)
    //   Rcon[j] = {rcon_byte, 8'h00, 8'h00, 8'h00}
    //------------------------------------------------------------------------
    reg [7:0] rcon_byte;

    always @(*) begin
        case (round)
            4'd1:    rcon_byte = 8'h01;
            4'd2:    rcon_byte = 8'h02;
            4'd3:    rcon_byte = 8'h04;
            4'd4:    rcon_byte = 8'h08;
            4'd5:    rcon_byte = 8'h10;
            4'd6:    rcon_byte = 8'h20;
            4'd7:    rcon_byte = 8'h40;
            4'd8:    rcon_byte = 8'h80;
            4'd9:    rcon_byte = 8'h1b;
            4'd10:   rcon_byte = 8'h36;
            default: rcon_byte = 8'h00;
        endcase
    end

    wire [31:0] rcon_word = {rcon_byte, 24'h000000};

    //------------------------------------------------------------------------
    // Step 4: Compute new round key words (XOR cascade)
    //   nw0 = w0 ⊕ SubWord(RotWord(w3)) ⊕ Rcon
    //   nw1 = w1 ⊕ nw0
    //   nw2 = w2 ⊕ nw1
    //   nw3 = w3 ⊕ nw2
    //------------------------------------------------------------------------
    wire [31:0] nw0 = w0 ^ sub_word ^ rcon_word;
    wire [31:0] nw1 = w1 ^ nw0;
    wire [31:0] nw2 = w2 ^ nw1;
    wire [31:0] nw3 = w3 ^ nw2;

    assign key_out = {nw0, nw1, nw2, nw3};

endmodule
