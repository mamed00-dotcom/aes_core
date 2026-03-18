# AES-128 Core — Verification Report

## Verification Methodology

Three independent verification paths were used to ensure correctness:

1. **Python golden model** (`verify/aes_golden_model.py`) — Algorithmic mirror of the Verilog, cross-checked against Python `cryptography` library (OpenSSL backend)
2. **C++ golden model** (`cpp/aes_golden_model.cpp`) — Standalone reference implementation for intermediate value debugging
3. **SystemVerilog testbench** (`sim/tb_aes_top.sv`) — Behavioral simulation in Vivado xsim against NIST test vectors

## Test Vectors

### Source
- NIST FIPS 197 Appendix C.1 (primary validation vector)
- NIST CAVP ECBGFSbox128 (Cryptographic Algorithm Validation Program)
- Custom vectors (all-zeros, all-ones, key switching, back-to-back)

### Results (Vivado xsim)

```
[TEST 1] NIST FIPS 197 Appendix C.1 (AES-128)
  Expected:  69c4e0d86a7b0430d8cdb78070b4c55a
  Got:       69c4e0d86a7b0430d8cdb78070b4c55a
  Cycles:    22
  [PASS]

[TEST 2] All-zeros (key and plaintext)
  Expected:  66e94bd4ef8a2c3b884cfa59ca342b2e
  Got:       66e94bd4ef8a2c3b884cfa59ca342b2e
  Cycles:    22
  [PASS]

[TEST 3] NIST CAVP ECBGFSbox128
  Expected:  0336763e966d92595a567cc9ce537f5e
  Got:       0336763e966d92595a567cc9ce537f5e
  Cycles:    22
  [PASS]

[TEST 4] All-ones plaintext, incrementing key
  Expected:  3c441f32ce07822364d7a2990e50bb13
  Got:       3c441f32ce07822364d7a2990e50bb13
  Cycles:    22
  [PASS]

[TEST 5] Back-to-back: repeat NIST C.1 (no reset)
  Expected:  69c4e0d86a7b0430d8cdb78070b4c55a
  Got:       69c4e0d86a7b0430d8cdb78070b4c55a
  Cycles:    22
  [PASS]

[TEST 6] Same plaintext, different key
  Expected:  8df4e9aac5c7573a27d8d055d6e4d64b
  Got:       8df4e9aac5c7573a27d8d055d6e4d64b
  Cycles:    22
  [PASS]

RESULTS: 6/6 passed — 100% pass rate
```

### Key Expansion Verification

All 11 round keys verified against FIPS 197 Appendix A.1:

```
Round key[ 0]: 000102030405060708090a0b0c0d0e0f  [OK]
Round key[ 1]: d6aa74fdd2af72fadaa678f1d6ab76fe  [OK]
Round key[ 2]: b692cf0b643dbdf1be9bc5006830b3fe  [OK]
Round key[ 3]: b6ff744ed2c2c9bf6c590cbf0469bf41  [OK]
Round key[ 4]: 47f7f7bc95353e03f96c32bcfd058dfd  [OK]
Round key[ 5]: 3caaa3e8a99f9deb50f3af57adf622aa  [OK]
Round key[ 6]: 5e390f7df7a69296a7553dc10aa31f6b  [OK]
Round key[ 7]: 14f9701ae35fe28c440adf4d4ea9c026  [OK]
Round key[ 8]: 47438735a41c65b9e016baf4aebf7ad2  [OK]
Round key[ 9]: 549932d1f08557681093ed9cbe2c974e  [OK]
Round key[10]: 13111d7fe3944a17f307a78b4d2b30c5  [OK]
```

## Synthesis Verification

- **Zero latches** inferred — confirms fully synchronous design
- **Zero combinational loops** — no unintended feedback
- **Zero critical warnings** from synthesis
- **FSM encoding**: One-hot (auto-selected by Vivado)

## Test Coverage Notes

- Back-to-back test (Test 5) verifies the FSM correctly transitions DONE→KEY_EXPAND without reset
- Key switching test (Test 6) verifies round key storage is fully overwritten between encryptions
- All-zeros and all-ones vectors stress the S-box and MixColumns edge cases

## Tools

- **Simulation**: Vivado xsim 2024.1
- **Python**: cryptography library (OpenSSL backend) for reference ciphertext generation
- **C++**: g++ with `-std=c++11`, standalone verification
