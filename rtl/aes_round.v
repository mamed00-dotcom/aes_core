`timescale 1ns / 1ps
//============================================================================
// Module:  aes_round.v
// Project: AES-128 Encryption Core
// Author:  Mohammed Hajjar
// Date:    March 2026
//
// Description:
//   Combinational AES encryption round per FIPS 197, Section 5.1.
//   Performs SubBytes → ShiftRows → MixColumns → AddRoundKey.
//   When is_final_round is asserted, MixColumns is bypassed (Section 5.1,
//   round Nr: SubBytes → ShiftRows → AddRoundKey only).
//
//   State byte mapping (big-endian, column-major):
//     state[127:120] = s[0,0]  state[95:88] = s[0,1]  state[63:56] = s[0,2]  state[31:24] = s[0,3]
//     state[119:112] = s[1,0]  state[87:80] = s[1,1]  state[55:48] = s[1,2]  state[23:16] = s[1,3]
//     state[111:104] = s[2,0]  state[79:72] = s[2,1]  state[47:40] = s[2,2]  state[15:8]  = s[2,3]
//     state[103:96]  = s[3,0]  state[71:64] = s[3,1]  state[39:32] = s[3,2]  state[7:0]   = s[3,3]
//
// Latency: 0 cycles (purely combinational; registered by aes_top)
//============================================================================

module aes_round (
    input  wire [127:0] state_in,
    input  wire [127:0] round_key,
    input  wire         is_final_round,
    output wire [127:0] state_out
);

    //========================================================================
    // 1. SubBytes — Apply S-box to each of the 16 state bytes
    //========================================================================
    wire [7:0] sb [0:15];   // SubBytes output bytes

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_sbox
            aes_sbox u_sbox (
                .in  (state_in[127 - 8*i -: 8]),
                .out (sb[i])
            );
        end
    endgenerate

    // Pack SubBytes output into 128-bit vector for readability
    // sb[0] = byte 0 (row 0, col 0), sb[1] = byte 1 (row 1, col 0), etc.
    wire [127:0] after_sub = {
        sb[0],  sb[1],  sb[2],  sb[3],
        sb[4],  sb[5],  sb[6],  sb[7],
        sb[8],  sb[9],  sb[10], sb[11],
        sb[12], sb[13], sb[14], sb[15]
    };

    //========================================================================
    // 2. ShiftRows — Cyclically shift each row left by its row index
    //
    //   Row 0: no shift     →  s'[0,c] = s[0,c]
    //   Row 1: shift left 1 →  s'[1,c] = s[1,(c+1) mod 4]
    //   Row 2: shift left 2 →  s'[2,c] = s[2,(c+2) mod 4]
    //   Row 3: shift left 3 →  s'[3,c] = s[3,(c+3) mod 4]
    //
    //   Using byte indices into the after_sub vector:
    //   Byte index = row + 4*col  (column-major packing)
    //========================================================================

    // Extract individual bytes from after_sub for clarity
    // Column 0: bytes 0-3, Column 1: bytes 4-7, Column 2: bytes 8-11, Column 3: bytes 12-15
    wire [7:0] s00 = after_sub[127:120]; // row 0, col 0
    wire [7:0] s10 = after_sub[119:112]; // row 1, col 0
    wire [7:0] s20 = after_sub[111:104]; // row 2, col 0
    wire [7:0] s30 = after_sub[103:96];  // row 3, col 0

    wire [7:0] s01 = after_sub[95:88];   // row 0, col 1
    wire [7:0] s11 = after_sub[87:80];   // row 1, col 1
    wire [7:0] s21 = after_sub[79:72];   // row 2, col 1
    wire [7:0] s31 = after_sub[71:64];   // row 3, col 1

    wire [7:0] s02 = after_sub[63:56];   // row 0, col 2
    wire [7:0] s12 = after_sub[55:48];   // row 1, col 2
    wire [7:0] s22 = after_sub[47:40];   // row 2, col 2
    wire [7:0] s32 = after_sub[39:32];   // row 3, col 2

    wire [7:0] s03 = after_sub[31:24];   // row 0, col 3
    wire [7:0] s13 = after_sub[23:16];   // row 1, col 3
    wire [7:0] s23 = after_sub[15:8];    // row 2, col 3
    wire [7:0] s33 = after_sub[7:0];     // row 3, col 3

    // After ShiftRows:
    //   Col 0         Col 1         Col 2         Col 3
    //   s00           s01           s02           s03       (row 0, no shift)
    //   s11           s12           s13           s10       (row 1, shift left 1)
    //   s22           s23           s20           s21       (row 2, shift left 2)
    //   s33           s30           s31           s32       (row 3, shift left 3)

    wire [127:0] after_shift = {
        s00, s11, s22, s33,   // Column 0
        s01, s12, s23, s30,   // Column 1
        s02, s13, s20, s31,   // Column 2
        s03, s10, s21, s32    // Column 3
    };

    //========================================================================
    // 3. MixColumns — Multiply each column by the MDS matrix in GF(2^8)
    //
    //   [2 3 1 1] [r0]   [r0']
    //   [1 2 3 1] [r1] = [r1']
    //   [1 1 2 3] [r2]   [r2']
    //   [3 1 1 2] [r3]   [r3']
    //
    //   xtime(a) = (a << 1) ^ (a[7] ? 8'h1b : 8'h00)
    //   Multiply by 2 = xtime(a)
    //   Multiply by 3 = xtime(a) ^ a
    //========================================================================

    // xtime function: multiplication by {02} in GF(2^8)
    function [7:0] xtime;
        input [7:0] a;
        begin
            xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
        end
    endfunction

    // MixColumns for a single column
    // Input: 4 bytes (r0, r1, r2, r3) — top to bottom of column
    // Output: 4 bytes after MDS matrix multiplication
    function [31:0] mix_column;
        input [7:0] r0, r1, r2, r3;
        reg [7:0] m0, m1, m2, m3;
        begin
            m0 = xtime(r0) ^ (xtime(r1) ^ r1) ^ r2              ^ r3;
            m1 = r0              ^ xtime(r1) ^ (xtime(r2) ^ r2) ^ r3;
            m2 = r0              ^ r1              ^ xtime(r2) ^ (xtime(r3) ^ r3);
            m3 = (xtime(r0) ^ r0) ^ r1              ^ r2              ^ xtime(r3);
            mix_column = {m0, m1, m2, m3};
        end
    endfunction

    // Apply MixColumns to each of the 4 columns
    wire [31:0] mc_col0 = mix_column(
        after_shift[127:120], after_shift[119:112],
        after_shift[111:104], after_shift[103:96]
    );
    wire [31:0] mc_col1 = mix_column(
        after_shift[95:88], after_shift[87:80],
        after_shift[79:72], after_shift[71:64]
    );
    wire [31:0] mc_col2 = mix_column(
        after_shift[63:56], after_shift[55:48],
        after_shift[47:40], after_shift[39:32]
    );
    wire [31:0] mc_col3 = mix_column(
        after_shift[31:24], after_shift[23:16],
        after_shift[15:8],  after_shift[7:0]
    );

    wire [127:0] after_mix = {mc_col0, mc_col1, mc_col2, mc_col3};

    //========================================================================
    // 4. MixColumns Bypass MUX (final round skips MixColumns)
    //========================================================================
    wire [127:0] before_ark = is_final_round ? after_shift : after_mix;

    //========================================================================
    // 5. AddRoundKey — XOR with round key
    //========================================================================
    assign state_out = before_ark ^ round_key;

endmodule
