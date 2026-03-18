# AES-128 Core — Architecture Document

## Overview

This document describes the architecture and design decisions of the AES-128 hardware encryption core.

## Design Philosophy

The core targets a balance between area and throughput: a single combinational round is reused iteratively over 10 clock cycles, with pre-computed key expansion. This avoids the area cost of a fully unrolled pipeline while achieving a predictable 22-cycle latency.

## Module Hierarchy

```
aes_top.v
├── aes_key_expand.v (combinational)
│   └── aes_sbox.v × 4
└── aes_round.v (combinational)
    └── aes_sbox.v × 16
```

Total S-box instances: 20 (16 in SubBytes + 4 in SubWord).

## FSM Design

Four states with one-hot encoding (auto-selected by Vivado):

- **IDLE**: Awaiting start pulse. Inputs latched on start. Initial AddRoundKey performed here: `state = plaintext ⊕ key[0]`.
- **KEY_EXPAND**: Generates round keys 1–10 iteratively (10 cycles). Key 0 = master key, stored immediately.
- **ENCRYPT**: Applies rounds 1–10 through `aes_round`. Round 10 asserts `is_final_round` to bypass MixColumns.
- **DONE**: Ciphertext valid. Holds until next start pulse. Back-to-back encryption supported from DONE state.

## Cycle Budget

| Phase | Cycles | Operation |
|-------|--------|-----------|
| IDLE→KEY_EXPAND | 0 | Latch inputs + initial AddRoundKey |
| KEY_EXPAND | 10 | Generate round keys 1–10 |
| ENCRYPT | 10 | Apply rounds 1–10 |
| DONE | 1 | Assert valid |
| **Total** | **~22** | |

## Key Expansion (aes_key_expand.v)

Purely combinational: takes the previous round key and round number, outputs the next round key in a single cycle. The top FSM registers each output into `round_keys[round_cnt]`.

Algorithm per step: `RotWord → SubWord(4× S-box) → XOR Rcon → 4-word XOR cascade`

## Encryption Round (aes_round.v)

Purely combinational datapath:

1. **SubBytes**: 16 parallel S-box lookups
2. **ShiftRows**: Wire permutation (zero logic)
3. **MixColumns**: GF(2⁸) xtime multiplication, 4 columns in parallel
4. **MixColumns bypass**: `is_final_round ? after_shift : after_mix`
5. **AddRoundKey**: 128-bit XOR

## S-box (aes_sbox.v)

256-entry case statement. Synthesizes to ~64 LUT6 primitives per instance on Artix-7. BRAM alternative was considered but rejected: it adds 1-cycle latency per lookup and complicates the single-cycle round architecture.

## AXI4-Lite Interface

Standard 5-channel AXI4-Lite slave (AW, W, B, AR, R) with simultaneous handshake on AW+W channels. Self-clearing START bit in CTRL register prevents re-triggering. A direct interface bypasses AXI4-Lite for testbench use.

## Endianness

Big-endian byte ordering per FIPS 197: `state[127:120] = byte_0`. State matrix is column-major.

## Critical Path

Post-synthesis critical path runs through the I/O output buffer (OBUF on `busy` port), not through internal datapath logic. The core's internal Fmax is higher than the 108 MHz reported with I/O constraints.
