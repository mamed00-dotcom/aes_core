# AES-128 Hardware Encryption Core

A fully synthesizable AES-128 ECB encryption core in Verilog, targeting Xilinx Artix-7 FPGAs with an AXI4-Lite slave interface. Designed per **NIST FIPS 197** and verified against official test vectors.

## Key Results

| Metric | Value |
|--------|-------|
| **Target FPGA** | Xilinx Artix-7 (xc7a100tcsg324-1) |
| **LUTs** | 2,309 / 63,400 (3.64%) |
| **Flip-Flops** | 1,986 / 126,800 (1.57%) |
| **BRAM / DSP** | 0 / 0 |
| **Fmax** | 108 MHz |
| **Latency** | 22 clock cycles per 128-bit block |
| **Throughput** | 581 Mbit/s |
| **Verification** | 6/6 NIST test vectors — 100% pass rate |

## Architecture

```
aes_top.v ─── FSM controller + AXI4-Lite slave interface
├── aes_key_expand.v ─── Iterative round key generation (10 cycles)
│   └── aes_sbox.v × 4 ─── SubWord S-box lookups
└── aes_round.v ─── Combinational encryption round
    └── aes_sbox.v × 16 ─── SubBytes S-box lookups
```

**FSM:** `IDLE → KEY_EXPAND (10 cycles) → ENCRYPT (10 cycles) → DONE`

The initial AddRoundKey (`plaintext ⊕ key[0]`) is folded into the IDLE→KEY_EXPAND transition at zero cycle cost. Round 10 bypasses MixColumns via a clean MUX before AddRoundKey.

## Module Summary

| Module | Type | Description |
|--------|------|-------------|
| `aes_sbox.v` | Combinational | 256-entry FIPS 197 S-box lookup table |
| `aes_key_expand.v` | Combinational | Single-step round key derivation (RotWord → SubWord → Rcon → XOR) |
| `aes_round.v` | Combinational | SubBytes → ShiftRows → MixColumns → AddRoundKey (MixColumns bypassed on round 10) |
| `aes_top.v` | Sequential | FSM, round key storage (11×128b), AXI4-Lite slave interface |

## AXI4-Lite Register Map

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | CTRL | W | Bit[0]: START (self-clearing) |
| 0x04 | STATUS | R | Bit[0]: BUSY, Bit[1]: VALID |
| 0x10–0x1C | KEY | W | 128-bit key (4 × 32-bit words, MSB first) |
| 0x20–0x2C | PLAINTEXT | W | 128-bit plaintext (4 × 32-bit words) |
| 0x30–0x3C | CIPHERTEXT | R | 128-bit ciphertext (4 × 32-bit words) |

## Quick Start

### Simulate with Icarus Verilog
```bash
make sim
```

### Simulate with Vivado
```
1. Create project targeting xc7a100tcsg324-1
2. Add rtl/*.v as design sources
3. Add sim/tb_aes_top.sv as simulation source
4. Add constraints/aes_timing.xdc
5. Run Simulation → Run Behavioral Simulation → Run All
```

### Run C++ Golden Model
```bash
cd cpp && g++ -std=c++11 -O2 -o aes_golden aes_golden_model.cpp && ./aes_golden
```

## Verification

All vectors verified against Python `cryptography` library (OpenSSL) and Vivado xsim.

| # | Test | Status |
|---|------|--------|
| 1 | NIST FIPS 197 Appendix C.1 | **PASS** |
| 2 | All-zeros (key + plaintext) | **PASS** |
| 3 | NIST CAVP ECBGFSbox128 | **PASS** |
| 4 | All-ones plaintext | **PASS** |
| 5 | Back-to-back (no reset) | **PASS** |
| 6 | Key switching | **PASS** |
| — | Key expansion (11 round keys) | **PASS** |

## Synthesis (Vivado 2024.1)

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| Slice LUTs | 2,309 | 63,400 | 3.64% |
| Slice Registers | 1,986 | 126,800 | 1.57% |
| Block RAM | 0 | 135 | 0% |
| DSP48 | 0 | 240 | 0% |

WNS = +0.763 ns @ 100 MHz → **Fmax ≈ 108 MHz**. Zero latches, zero combinational loops.

## Repository Structure

```
├── rtl/                         Synthesizable Verilog
│   ├── aes_top.v                Top-level FSM + AXI4-Lite
│   ├── aes_round.v              Encryption round logic
│   ├── aes_key_expand.v         Key schedule
│   └── aes_sbox.v               S-box lookup table
├── sim/                         Testbench
│   └── tb_aes_top.sv            SystemVerilog (6 test vectors)
├── constraints/                 Xilinx XDC
│   └── aes_timing.xdc           Clock + I/O timing
├── cpp/                         C++ golden model
│   └── aes_golden_model.cpp     Reference implementation
├── verify/                      Python verification
│   └── aes_golden_model.py      Algorithm mirror + NIST check
├── docs/                        Documentation
│   ├── ARCHITECTURE.md          Design decisions
│   └── VERIFICATION_REPORT.md   Full test results
└── results/                     Synthesis reports (add yours)
```

## Future Extensions

- AES-256 support (14 rounds, 256-bit key)
- GCM authenticated encryption mode
- Side-channel countermeasures (Boolean masking)
- Pipelined architecture for higher throughput

## References

- [NIST FIPS 197](https://nvlpubs.nist.gov/nistpubs/fips/nist.fips.197.pdf) — AES Standard
- [NIST CAVP](https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program) — Validation Vectors

## Author

**Mohammed Hajjar** — FPGA & Hardware Security Engineer

## License

MIT License — see [LICENSE](LICENSE) for details.
