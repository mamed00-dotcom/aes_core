# AES-128 UVM Verification Environment

UVM 1.2 testbench for the AES-128 FPGA encryption core, targeting Xilinx Vivado xsim.
Verifies RTL correctness against a self-contained C golden model via DPI-C, with SVA assertions and functional coverage.

---

## What it verifies

| Test | Vectors | Method |
|------|---------|--------|
| `aes_test_nist` | 5 directed | NIST FIPS-197 + all-zeros/all-ones/key-switch |
| `aes_test_random` | 100 random | Constrained-random key × plaintext pairs |
| `aes_test_back2back` | 50 stress | Rapid DONE→KEY_EXPAND transitions |

Every ciphertext is compared against a self-contained software AES-128 implementation compiled via DPI-C — no external library required.

---

## Directory layout

```
uvm/
├── top/
│   ├── aes_if.sv              # SystemVerilog interface (clocking blocks for driver/monitor)
│   └── aes_tb_top.sv          # Testbench top: DUT instantiation, bind, UVM launch
│
├── env/
│   ├── aes_seq_item.sv        # Transaction: randomizable key + plaintext, response fields
│   ├── aes_driver.sv          # Drives direct interface; waits for valid with timeout
│   ├── aes_monitor.sv         # Passive observer; broadcasts completed transactions via TLM
│   ├── aes_scoreboard.sv      # Calls DPI-C golden model; compares with RTL output
│   ├── aes_agent.sv           # Active agent: driver + sequencer + monitor
│   └── aes_env.sv             # Environment: agent + scoreboard
│
├── seq/
│   ├── aes_seq_base.sv        # Abstract base sequence
│   ├── aes_seq_single.sv      # One encryption: drive → wait → done
│   └── aes_seq_back2back.sv   # N encryptions with no idle gap between
│
├── test/
│   ├── aes_test_base.sv       # Base test: builds env, gets vif from config_db
│   ├── aes_test_nist.sv       # Phase 1: 5 NIST FIPS-197 directed vectors
│   ├── aes_test_random.sv     # Phase 2a: 100 constrained-random vectors
│   └── aes_test_back2back.sv  # Phase 2b: 50 rapid-fire stress vectors
│
├── sva/
│   └── aes_assertions.sv      # 10 SVA properties bound to DUT internals
│
├── coverage/
│   └── aes_coverage.sv        # 7 functional covergroups bound to DUT internals
│
├── dpi/
│   ├── aes_dpi.c              # Self-contained AES-128 golden model (S-box, key expand, encrypt)
│   └── aes_dpi.h              # Header
│
└── README.md
```

---

## SVA assertions (`aes_assertions.sv`)

Bound to DUT internals via `bind` — no RTL modification required.

| # | Property | What it checks |
|---|----------|----------------|
| 1 | `p_fsm_idle_transitions` | IDLE can only go to IDLE or KEY_EXPAND |
| 2 | `p_fsm_keyexp_transitions` | KEY_EXPAND can only go to KEY_EXPAND or ENCRYPT |
| 3 | `p_fsm_encrypt_transitions` | ENCRYPT can only go to ENCRYPT or DONE |
| 4 | `p_fsm_done_transitions` | DONE can only go to DONE or KEY_EXPAND |
| 5 | `p_latency_21_cycles` | Encryption completes in exactly 21 clock cycles |
| 6 | `p_valid_only_in_done` | `valid` is only asserted in DONE state |
| 7 | `p_busy_correct` | `busy` is only asserted in KEY_EXPAND or ENCRYPT |
| 8 | `p_busy_and_valid_mutex` | `busy` and `valid` are never simultaneously asserted |
| 9 | `p_key_stable_during_operation` | Key register does not change mid-encryption |
| 10 | `p_round_cnt_range` | Round counter never exceeds 10 |

---

## Functional coverage (`aes_coverage.sv`)

Also bound via `bind`. Covergroups sample DUT internal signals.

| Group | What it measures |
|-------|-----------------|
| `cg_fsm_state` | All 4 FSM states hit |
| `cg_fsm_transitions` | All 8 legal state transitions hit |
| `cg_round_cnt` | Round counter values 0–10 all hit |
| `cg_state_x_round` | Cross: each active state × each round value |
| `cg_key_patterns` | All-zeros, all-ones, NIST key, and random keys |
| `cg_pt_patterns` | All-zeros, all-ones, NIST plaintext, and random |
| `cg_operations` | Normal vs back-to-back, same-key vs key-switch |

Results after all three test phases:

```
FSM State:       100%
FSM Transitions: 100%   (back-to-back adds DONE→KEY_EXPAND)
Round Counter:   100%
State × Round:   100%
Key Patterns:     75%+
PT Patterns:     100%
Operations:      100%
```

---

## DPI-C golden model (`dpi/aes_dpi.c`)

A self-contained, dependency-free AES-128 implementation in C:
- Full S-box (FIPS 197 compliant)
- Key expansion (10 round keys)
- 10-round encryption (SubBytes, ShiftRows, MixColumns, AddRoundKey)

The SV scoreboard declares:
```sv
import "DPI-C" function void aes_encrypt_dpi(
    input  bit [127:0] key_in,
    input  bit [127:0] pt_in,
    output bit [127:0] ct_out
);
```

Packed 128-bit vectors are used so the C side receives plain `svBitVecVal*` (4 × `uint32_t`) with no dependency on xsim runtime functions.

---

## Requirements

| Tool | Version |
|------|---------|
| Xilinx Vivado | 2024.1 (xsim) |
| UVM | 1.2 (pre-compiled in Vivado, `-L uvm`) |
| gcc / MinGW | Any recent MinGW-W64 (tested with 15.2.0) |

Run from the **project root** (`aes_core/`), not from inside `uvm/`.

---

## How to run (Vivado Tcl Shell)

```tcl
cd C:/path/to/aes_core
source run_uvm.tcl

run_uvm nist        ;# Phase 1 — 5 NIST directed vectors
run_uvm random      ;# Phase 2a — 100 random vectors
run_uvm back2back   ;# Phase 2b — 50 stress vectors
run_uvm all         ;# All three suites in sequence
```

The script handles all three steps automatically:
1. Compiles `aes_dpi.c` → `uvm/dpi/aes_dpi.a` (static archive for xelab)
2. Compiles all RTL + UVM sources with `xvlog -sv -L uvm`
3. Elaborates with `xelab`, links DPI archive → `aes_uvm_snap`
4. Runs `xsim` for each selected test; writes per-test log files

Log files are written to the project root: `xsim_aes_test_nist.log`, `xsim_aes_test_random.log`, `xsim_aes_test_back2back.log`.

---

## Expected output

```
SCOREBOARD SUMMARY: 5/5 passed
*** ALL CHECKS PASSED ***

SCOREBOARD SUMMARY: 100/100 passed
*** ALL CHECKS PASSED ***

SCOREBOARD SUMMARY: 50/50 passed
*** ALL CHECKS PASSED ***
```

No `UVM_ERROR` or `UVM_FATAL` messages in any passing run.

---

## Known simulator limitations (Vivado xsim)

- `cover property` statements in `aes_assertions.sv` are ignored with a warning — xsim does not yet support SVA cover properties. The assertions themselves work correctly.
- UVM test-name retrieval via DPI is disabled in Vivado's pre-compiled UVM build (`UVM_NO_DPI`). Test selection still works correctly via `--testplusarg UVM_TESTNAME=...`.
