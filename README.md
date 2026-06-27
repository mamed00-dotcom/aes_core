# AES-128 Hardware Encryption Core

A fully synthesizable AES-128 ECB encryption core in Verilog, targeting Xilinx Artix-7 FPGAs with an AXI4-Lite slave interface. Designed per **NIST FIPS 197** and verified with a full UVM 1.2 testbench on Vivado xsim.

## Key Results

| Metric | Value |
|--------|-------|
| **Target FPGA** | Xilinx Artix-7 (xc7a100tcsg324-1) |
| **LUTs** | 2,309 / 63,400 (3.64%) |
| **Flip-Flops** | 1,986 / 126,800 (1.57%) |
| **BRAM / DSP** | 0 / 0 |
| **Fmax** | 108 MHz |
| **Latency** | 21 clock cycles per 128-bit block |
| **Throughput** | 610 Mbit/s @ 100 MHz |
| **UVM verification** | 155/155 vectors — 100% pass rate |

## High-Throughput Pipeline + RISC-V Integration

Beyond the iterative core documented below, this repo also contains a
fully-unrolled **10-stage pipelined** variant (1 block/cycle, ~21x throughput at
the same Fmax) and its integration with a RISC-V, including a working **NEORV32**
SoC that runs compiled firmware driving the AES hardware over a real bus:

- **[docs/NEORV32_INTEGRATION.md](docs/NEORV32_INTEGRATION.md)** - real RISC-V
  (NEORV32) SoC: CPU firmware drives the AES coprocessor over XBUS -> AXI4-Lite,
  ciphertext checked against FIPS-197 C.1 in hardware (`run_neorv32.sh`).
- **[docs/AES_PIPELINE_COMPARISON.md](docs/AES_PIPELINE_COMPARISON.md)** -
  pipelined core, streaming (AXI4-Stream + DMA) vs. coprocessor (AXI4-Lite)
  approaches, and post-route synthesis numbers.
- **[docs/PIPELINE_WORK_LOG.md](docs/PIPELINE_WORK_LOG.md)** - what was added,
  why, and what each piece proved.

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

### UVM testbench (Vivado xsim — recommended)

Open the Vivado Tcl Shell, then:

```tcl
cd C:/path/to/aes_core
source run_uvm.tcl

run_uvm nist        ;# 5 NIST directed vectors
run_uvm random      ;# 100 constrained-random vectors
run_uvm back2back   ;# 50 rapid-fire stress vectors
run_uvm all         ;# all three suites
```

See [`uvm/README.md`](uvm/README.md) for full details on the testbench structure and requirements.

### Basic simulation (Icarus Verilog)

```bash
make sim
```

### C++ golden model

```bash
cd cpp && g++ -std=c++11 -O2 -o aes_golden aes_golden_model.cpp && ./aes_golden
```

## Verification

### UVM testbench results (Vivado xsim)

Three test phases, all run automatically via `run_uvm.tcl`:

| Phase | Test | Vectors | Result |
|-------|------|---------|--------|
| 1 | `aes_test_nist` | 5 directed | **5/5 PASS** |
| 2a | `aes_test_random` | 100 random | **100/100 PASS** |
| 2b | `aes_test_back2back` | 50 stress | **50/50 PASS** |

Every ciphertext is checked against a self-contained C AES-128 golden model linked via DPI-C — no external libraries required.

**Functional coverage after all three phases:**

| Covergroup | Coverage |
|-----------|---------|
| FSM State (all 4 states) | 100% |
| FSM Transitions (all 8 legal) | 100% |
| Round Counter (values 0–10) | 100% |
| State × Round (cross coverage) | 100% |
| Key Patterns | 100% |
| Plaintext Patterns | 100% |
| Operational Scenarios (back-to-back, key-switch) | 100% |

**SVA assertions active during simulation** (bound to DUT internals via `bind`):

- FSM legal-transition enforcement (4 properties)
- 21-cycle latency guarantee
- `valid` only in DONE state
- `busy` and `valid` mutually exclusive
- Key register stable during active operation
- Round counter never exceeds 10

### NIST FIPS 197 vectors (basic testbench)

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
│   ├── aes_top.v                Top-level FSM + AXI4-Lite slave
│   ├── aes_round.v              Encryption round logic
│   ├── aes_key_expand.v         Key schedule
│   └── aes_sbox.v               S-box lookup table
│
├── uvm/                         UVM 1.2 verification environment
│   ├── top/                     Testbench top + SystemVerilog interface
│   ├── env/                     seq_item, driver, monitor, scoreboard, agent, env
│   ├── seq/                     Base, single, and back-to-back sequences
│   ├── test/                    NIST directed, random, and stress tests
│   ├── sva/                     SVA assertions (bound via bind)
│   ├── coverage/                Functional covergroups (bound via bind)
│   ├── dpi/                     C golden model (aes_dpi.c)
│   └── README.md                UVM testbench documentation
│
├── sim/                         Basic testbench
│   └── tb_aes_top.sv            SystemVerilog (6 NIST vectors)
│
├── constraints/
│   └── aes_timing.xdc           Clock + I/O timing constraints
│
├── cpp/                         C++ reference implementation
│   └── aes_golden_model.cpp
│
├── verify/                      Python verification scripts
│   └── aes_golden_model.py
│
├── docs/
│   ├── ARCHITECTURE.md
│   └── VERIFICATION_REPORT.md
│
├── run_uvm.tcl                  Vivado Tcl Shell automation script
├── run_uvm.bat                  Windows CMD alternative
└── uvm/Makefile                 GNU make flow (Linux / MSYS2)
```

## Future Extensions

- AES-256 support (14 rounds, 256-bit key)
- GCM authenticated encryption mode
- Side-channel countermeasures (Boolean masking)
- ~~Pipelined architecture for higher throughput~~ - done, see [pipeline + RISC-V integration](#high-throughput-pipeline--risc-v-integration) above

## References

- [NIST FIPS 197](https://nvlpubs.nist.gov/nistpubs/fips/nist.fips.197.pdf) — AES Standard
- [NIST CAVP](https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program) — Validation Vectors
- [IEEE 1800-2012](https://ieeexplore.ieee.org/document/6328721) — SystemVerilog / UVM DPI-C standard

## Author

**Mohammed Hajjar** — FPGA & Hardware Security Engineer

## License

MIT License — see [LICENSE](LICENSE) for details.
