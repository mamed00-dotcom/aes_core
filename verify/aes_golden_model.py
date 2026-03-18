#!/usr/bin/env python3
"""
AES-128 Golden Model — Mirrors the Verilog RTL logic exactly.
Verifies S-box, key expansion, round operations against NIST FIPS 197.
"""

# === AES S-box (FIPS 197 Table) — must match aes_sbox.v ===
SBOX = [
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
]

RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]

def to_bytes(val_128):
    """Convert 128-bit integer to 16-byte list (big-endian)."""
    return [(val_128 >> (120 - 8*i)) & 0xFF for i in range(16)]

def from_bytes(blist):
    """Convert 16-byte list to 128-bit integer (big-endian)."""
    v = 0
    for b in blist:
        v = (v << 8) | b
    return v

def sub_bytes(state):
    return [SBOX[b] for b in state]

def shift_rows(state):
    """State is 16 bytes in column-major order: [s00,s10,s20,s30, s01,s11,s21,s31, ...]"""
    # Convert to matrix[row][col]
    m = [[state[col*4 + row] for col in range(4)] for row in range(4)]
    # Shift each row left
    for r in range(4):
        m[r] = m[r][r:] + m[r][:r]
    # Convert back to column-major
    out = []
    for c in range(4):
        for r in range(4):
            out.append(m[r][c])
    return out

def xtime(a):
    return ((a << 1) ^ (0x1b if a & 0x80 else 0)) & 0xFF

def mix_column(col):
    """Mix one column (4 bytes)."""
    r0, r1, r2, r3 = col
    m0 = xtime(r0) ^ (xtime(r1) ^ r1) ^ r2 ^ r3
    m1 = r0 ^ xtime(r1) ^ (xtime(r2) ^ r2) ^ r3
    m2 = r0 ^ r1 ^ xtime(r2) ^ (xtime(r3) ^ r3)
    m3 = (xtime(r0) ^ r0) ^ r1 ^ r2 ^ xtime(r3)
    return [m0 & 0xFF, m1 & 0xFF, m2 & 0xFF, m3 & 0xFF]

def mix_columns(state):
    out = []
    for c in range(4):
        col = state[c*4:(c+1)*4]
        out.extend(mix_column(col))
    return out

def add_round_key(state, key_bytes):
    return [s ^ k for s, k in zip(state, key_bytes)]

def key_expansion(key_128):
    """Generate all 11 round keys (matches aes_key_expand.v logic exactly)."""
    key_bytes = to_bytes(key_128)
    # Split into 4 words
    w = []
    for i in range(4):
        w.append(key_bytes[4*i:4*i+4])

    for i in range(4, 44):
        temp = list(w[i-1])
        if i % 4 == 0:
            # RotWord
            temp = [temp[1], temp[2], temp[3], temp[0]]
            # SubWord
            temp = [SBOX[b] for b in temp]
            # XOR with Rcon
            temp[0] ^= RCON[i // 4]
        w.append([w[i-4][j] ^ temp[j] for j in range(4)])

    # Pack into 11 round keys
    round_keys = []
    for rk in range(11):
        blist = w[rk*4] + w[rk*4+1] + w[rk*4+2] + w[rk*4+3]
        round_keys.append(from_bytes(blist))
    return round_keys

def aes_encrypt(plaintext_128, key_128):
    """Full AES-128 encryption — mirrors the Verilog FSM exactly."""
    round_keys = key_expansion(key_128)
    state = to_bytes(plaintext_128)

    # Initial AddRoundKey (round 0)
    state = add_round_key(state, to_bytes(round_keys[0]))

    # Rounds 1–9 (full rounds)
    for rnd in range(1, 10):
        state = sub_bytes(state)
        state = shift_rows(state)
        state = mix_columns(state)
        state = add_round_key(state, to_bytes(round_keys[rnd]))

    # Round 10 (final round — no MixColumns)
    state = sub_bytes(state)
    state = shift_rows(state)
    state = add_round_key(state, to_bytes(round_keys[10]))

    return from_bytes(state)


# ==========================================================================
# Test Execution
# ==========================================================================

def run_test(pt, key, expected_ct, name):
    ct = aes_encrypt(pt, key)
    status = "PASS" if ct == expected_ct else "FAIL"
    print(f"[{status}] {name}")
    print(f"  Key:       {key:032x}")
    print(f"  Plaintext: {pt:032x}")
    print(f"  Expected:  {expected_ct:032x}")
    print(f"  Got:       {ct:032x}")
    if ct != expected_ct:
        print(f"  XOR diff:  {ct ^ expected_ct:032x}")
    return ct == expected_ct

def verify_round_keys():
    """Verify key expansion against FIPS 197 Appendix A.1"""
    key = 0x000102030405060708090a0b0c0d0e0f
    rks = key_expansion(key)

    expected = [
        0x000102030405060708090a0b0c0d0e0f,
        0xd6aa74fdd2af72fadaa678f1d6ab76fe,
        0xb692cf0b643dbdf1be9bc5006830b3fe,
        0xb6ff744ed2c2c9bf6c590cbf0469bf41,
        0x47f7f7bc95353e03f96c32bcfd058dfd,
        0x3caaa3e8a99f9deb50f3af57adf622aa,
        0x5e390f7df7a69296a7553dc10aa31f6b,
        0x14f9701ae35fe28c440adf4d4ea9c026,
        0x47438735a41c65b9e016baf4aebf7ad2,
        0x549932d1f08557681093ed9cbe2c974e,
        0x13111d7fe3944a17f307a78b4d2b30c5,
    ]

    print("=" * 60)
    print("KEY EXPANSION VERIFICATION")
    print("=" * 60)
    all_ok = True
    for i in range(11):
        ok = rks[i] == expected[i]
        status = "OK" if ok else "MISMATCH"
        print(f"  Round key[{i:2d}]: {rks[i]:032x}  [{status}]")
        if not ok:
            print(f"       Expected: {expected[i]:032x}")
            all_ok = False

    print(f"  {'[PASS] All round keys correct' if all_ok else '[FAIL] Key expansion errors detected'}")
    print()
    return all_ok


if __name__ == "__main__":
    print("=" * 60)
    print("  AES-128 Golden Model — Algorithm Verification")
    print("  Mirrors Verilog RTL logic exactly")
    print("=" * 60)
    print()

    # 1. Verify key expansion
    rk_ok = verify_round_keys()

    # 2. Run encryption tests
    print("=" * 60)
    print("ENCRYPTION TESTS")
    print("=" * 60)

    results = []

    # Primary NIST vector
    results.append(run_test(
        0x00112233445566778899aabbccddeeff,
        0x000102030405060708090a0b0c0d0e0f,
        0x69c4e0d86a7b0430d8cdb78070b4c55a,
        "NIST FIPS 197 Appendix C.1"
    ))
    print()

    # All-zeros
    results.append(run_test(
        0x00000000000000000000000000000000,
        0x00000000000000000000000000000000,
        0x66e94bd4ef8a2c3b884cfa59ca342b2e,
        "All-zeros"
    ))
    print()

    # CAVP vector
    results.append(run_test(
        0xf34481ec3cc627bacd5dc3fb08f273e6,
        0x00000000000000000000000000000000,
        0x0336763e966d92595a567cc9ce537f5e,
        "NIST CAVP ECBGFSbox128"
    ))
    print()

    # All-ones plaintext
    results.append(run_test(
        0xffffffffffffffffffffffffffffffff,
        0x000102030405060708090a0b0c0d0e0f,
        0x3c441f32ce07822364d7a2990e50bb13,
        "All-ones plaintext"
    ))
    print()

    # Different key
    results.append(run_test(
        0x00112233445566778899aabbccddeeff,
        0x2b7e151628aed2a6abf7158809cf4f3c,
        0x8df4e9aac5c7573a27d8d055d6e4d64b,
        "Different key"
    ))
    print()

    # Summary
    passed = sum(results)
    total = len(results)
    print("=" * 60)
    print(f"SUMMARY: {passed}/{total} encryption tests passed")
    print(f"Key expansion: {'PASS' if rk_ok else 'FAIL'}")
    if passed == total and rk_ok:
        print("*** ALL VERIFICATIONS PASSED ***")
    else:
        print("*** FAILURES DETECTED ***")
    print("=" * 60)
