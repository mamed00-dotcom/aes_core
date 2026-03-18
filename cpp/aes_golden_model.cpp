/**
 * AES-128 Golden Model (C++)
 * ==========================
 * Reference implementation matching the Verilog RTL logic exactly.
 * Used for generating intermediate values and verifying the hardware core.
 *
 * Build:  g++ -std=c++11 -O2 -o aes_golden aes_golden_model.cpp
 * Run:    ./aes_golden
 *
 * Author: Mohammed Hajjar
 * Date:   March 2026
 */

#include <cstdio>
#include <cstdint>
#include <cstring>

// =========================================================================
// AES S-box (FIPS 197 Table) — must match aes_sbox.v
// =========================================================================
static const uint8_t SBOX[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
};

// Round constants
static const uint8_t RCON[11] = {
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
};

// =========================================================================
// AES-128 Core Functions
// =========================================================================

static uint8_t xtime(uint8_t a) {
    return (a << 1) ^ ((a & 0x80) ? 0x1b : 0x00);
}

static void sub_bytes(uint8_t state[16]) {
    for (int i = 0; i < 16; i++)
        state[i] = SBOX[state[i]];
}

static void shift_rows(uint8_t state[16]) {
    // State is column-major: index = col*4 + row
    // Row 0: no shift
    // Row 1: shift left 1   — s[r,c] = s[r, (c+shift) mod 4]
    // Row 2: shift left 2
    // Row 3: shift left 3
    uint8_t s[16];
    memcpy(s, state, 16);

    // Row 0: unchanged
    state[0] = s[0];  state[4] = s[4];  state[8]  = s[8];  state[12] = s[12];
    // Row 1: shift left 1
    state[1] = s[5];  state[5] = s[9];  state[9]  = s[13]; state[13] = s[1];
    // Row 2: shift left 2
    state[2] = s[10]; state[6] = s[14]; state[10] = s[2];  state[14] = s[6];
    // Row 3: shift left 3
    state[3] = s[15]; state[7] = s[3];  state[11] = s[7];  state[15] = s[11];
}

static void mix_columns(uint8_t state[16]) {
    for (int c = 0; c < 4; c++) {
        int i = c * 4;
        uint8_t r0 = state[i], r1 = state[i+1], r2 = state[i+2], r3 = state[i+3];

        state[i]   = xtime(r0) ^ (xtime(r1) ^ r1) ^ r2 ^ r3;
        state[i+1] = r0 ^ xtime(r1) ^ (xtime(r2) ^ r2) ^ r3;
        state[i+2] = r0 ^ r1 ^ xtime(r2) ^ (xtime(r3) ^ r3);
        state[i+3] = (xtime(r0) ^ r0) ^ r1 ^ r2 ^ xtime(r3);
    }
}

static void add_round_key(uint8_t state[16], const uint8_t rk[16]) {
    for (int i = 0; i < 16; i++)
        state[i] ^= rk[i];
}

// =========================================================================
// Key Expansion — matches aes_key_expand.v
// =========================================================================
static void key_expansion(const uint8_t key[16], uint8_t round_keys[11][16]) {
    // Round key 0 = original key
    memcpy(round_keys[0], key, 16);

    for (int r = 1; r <= 10; r++) {
        const uint8_t *prev = round_keys[r - 1];
        uint8_t *curr = round_keys[r];

        // RotWord + SubWord + Rcon on last word of previous key
        uint8_t temp[4];
        temp[0] = SBOX[prev[13]] ^ RCON[r];  // RotWord shifts [12,13,14,15] → [13,14,15,12], then SubWord
        temp[1] = SBOX[prev[14]];
        temp[2] = SBOX[prev[15]];
        temp[3] = SBOX[prev[12]];

        // Word 0
        curr[0] = prev[0] ^ temp[0];
        curr[1] = prev[1] ^ temp[1];
        curr[2] = prev[2] ^ temp[2];
        curr[3] = prev[3] ^ temp[3];

        // Words 1-3: XOR cascade
        for (int i = 4; i < 16; i++)
            curr[i] = prev[i] ^ curr[i - 4];
    }
}

// =========================================================================
// AES-128 Encrypt — mirrors Verilog FSM exactly
// =========================================================================
static void aes128_encrypt(const uint8_t plaintext[16], const uint8_t key[16],
                           uint8_t ciphertext[16]) {
    uint8_t round_keys[11][16];
    uint8_t state[16];

    // Key expansion
    key_expansion(key, round_keys);

    // Initial AddRoundKey (round 0)
    memcpy(state, plaintext, 16);
    add_round_key(state, round_keys[0]);

    // Rounds 1-9 (full rounds)
    for (int r = 1; r <= 9; r++) {
        sub_bytes(state);
        shift_rows(state);
        mix_columns(state);
        add_round_key(state, round_keys[r]);
    }

    // Round 10 (final — no MixColumns)
    sub_bytes(state);
    shift_rows(state);
    add_round_key(state, round_keys[10]);

    memcpy(ciphertext, state, 16);
}

// =========================================================================
// Helper: hex string to byte array
// =========================================================================
static void hex_to_bytes(const char *hex, uint8_t *bytes, int len) {
    for (int i = 0; i < len; i++)
        sscanf(hex + 2 * i, "%2hhx", &bytes[i]);
}

static void print_bytes(const char *label, const uint8_t *bytes, int len) {
    printf("  %s: ", label);
    for (int i = 0; i < len; i++)
        printf("%02x", bytes[i]);
    printf("\n");
}

// =========================================================================
// Test runner
// =========================================================================
static int run_test(int num, const char *name,
                    const char *key_hex, const char *pt_hex, const char *exp_hex) {
    uint8_t key[16], pt[16], exp_ct[16], ct[16];

    hex_to_bytes(key_hex, key, 16);
    hex_to_bytes(pt_hex, pt, 16);
    hex_to_bytes(exp_hex, exp_ct, 16);

    aes128_encrypt(pt, key, ct);

    int pass = (memcmp(ct, exp_ct, 16) == 0);

    printf("------------------------------------------------------\n");
    printf("[TEST %d] %s\n", num, name);
    print_bytes("Key      ", key, 16);
    print_bytes("Plaintext", pt, 16);
    print_bytes("Expected ", exp_ct, 16);
    print_bytes("Got      ", ct, 16);
    printf("  [%s]\n", pass ? "PASS" : "FAIL");

    return pass;
}

// =========================================================================
// Main
// =========================================================================
int main() {
    printf("======================================================\n");
    printf("  AES-128 C++ Golden Model\n");
    printf("  NIST FIPS 197 Verification\n");
    printf("======================================================\n");

    int pass = 0, total = 0;

    total++; pass += run_test(total, "NIST FIPS 197 Appendix C.1",
        "000102030405060708090a0b0c0d0e0f",
        "00112233445566778899aabbccddeeff",
        "69c4e0d86a7b0430d8cdb78070b4c55a");

    total++; pass += run_test(total, "All-zeros",
        "00000000000000000000000000000000",
        "00000000000000000000000000000000",
        "66e94bd4ef8a2c3b884cfa59ca342b2e");

    total++; pass += run_test(total, "NIST CAVP ECBGFSbox128",
        "00000000000000000000000000000000",
        "f34481ec3cc627bacd5dc3fb08f273e6",
        "0336763e966d92595a567cc9ce537f5e");

    total++; pass += run_test(total, "All-ones plaintext",
        "000102030405060708090a0b0c0d0e0f",
        "ffffffffffffffffffffffffffffffff",
        "3c441f32ce07822364d7a2990e50bb13");

    total++; pass += run_test(total, "Different key",
        "2b7e151628aed2a6abf7158809cf4f3c",
        "00112233445566778899aabbccddeeff",
        "8df4e9aac5c7573a27d8d055d6e4d64b");

    printf("\n======================================================\n");
    printf("  SUMMARY: %d/%d tests passed\n", pass, total);
    if (pass == total)
        printf("  *** ALL TESTS PASSED ***\n");
    else
        printf("  *** %d TEST(S) FAILED ***\n", total - pass);
    printf("======================================================\n");

    return (pass == total) ? 0 : 1;
}
