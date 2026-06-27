# AES-128 - Pipelined Core, Streaming & Coprocessor Integration

## Overview

This document describes the high-throughput evolution of the AES-128 core: a
fully-unrolled, 10-stage **pipelined** datapath, and its integration through two
distinct architectures so they can be compared on performance and complexity:

- **Approach A** - a tightly-coupled, memory-mapped **RISC-V coprocessor**
  (`aes_coproc.v`): the CPU feeds the core directly via MMIO, posted/decoupled.
- **Approach B** - a pure **AXI4-Stream + DMA** streaming peripheral
  (`aes_stream_system.v`): an autonomous memory-to-memory engine.

It records the design decisions, the verification strategy, and the post-route
synthesis results that quantify the trade-off against the original iterative
core (`aes_top.v`).

> Scope: Phase 1 (pipelined core), Phase 2 (streaming, Approach B),
> Phase 3 (coprocessor, Approach A).

## Motivation

The original core reuses a single combinational round over ~21 cycles. It is
area-efficient but processes only **one block per ~21 cycles**. For bulk
encryption (disk, network, memory-to-memory), throughput dominates. Unrolling
the 10 rounds into a pipeline yields **one block per clock cycle** once filled -
roughly a **21× throughput gain** - while, crucially, *keeping the same clock
frequency*, because the per-stage critical path is still exactly one AES round.

---

## Design Decision: Fixed Key

The round keys are computed **once** by a short key-expansion FSM when `key_load`
is pulsed, then held static and fanned out to all 10 stages.

- **Why fixed key:** the per-stage SubWord S-boxes of the key schedule are *not*
  replicated (saves ~40 S-boxes vs. a key-agile design), and the longest
  combinational path of the key schedule stays at a single `aes_key_expand`
  rather than a 10-deep combinational chain (which would wreck Fmax).
- **Assumption:** the key is stable for the duration of a stream. Blocks in
  flight share the same key - correct by construction.
- **Alternative (key-agile):** to allow a different key per block, the key
  schedule would have to be pipelined in lockstep with the data path (+~40
  S-boxes, key carried alongside `TDATA`).

---

## Phase 1 - Pipelined Core (`aes_pipeline_top.v`)

### Module hierarchy

```
aes_pipeline_top.v
├── aes_key_expand.v  ×1  (iterative, one-time key schedule FSM)
│   └── aes_sbox.v ×4
└── aes_round.v       ×10 (one per pipeline stage)
    └── aes_sbox.v ×16   →  160 S-boxes in the datapath
```

### Datapath

```
in_data ─(comb)→ [AddRoundKey rk0] → round1 ─REG→ stage1
                                      round2 ─REG→ stage2
                                       ...
                                     round10 ─REG→ stage10 = out_data
```

- The initial AddRoundKey (rk0) is combinational at the input.
- Each of the 10 rounds is combinational (`aes_round.v`) and captured by exactly
  **one** pipeline register → a clean, fixed **10-cycle latency**.
- A `valid` bit is shifted alongside the data so the consumer knows which output
  beats are real.
- `en` is a global clock-enable: de-asserting it freezes the entire pipeline
  coherently (used for back-pressure in Phase 2).

### Properties

| Property      | Value                       |
|---------------|-----------------------------|
| Latency       | 10 cycles (fixed)           |
| Throughput    | 1 block / cycle (when full) |
| Key model     | Fixed (precomputed)         |
| BRAM / DSP    | 0 / 0                       |

---

## Phase 2 - Streaming Integration (Approach B)

```
+-----------+   rd   +---------+  S_AXIS  +-------------------+
|  buffer   |------->|         |--------->| aes_axis_wrapper  |
|  (LUTRAM) |        | aes_dma |          | (10-stage pipe)   |
|           |<-------|         |<---------|                   |
+-----------+   wr   +---------+  M_AXIS  +-------------------+
                          |  irq → RISC-V
```

### AXI4-Stream wrapper (`aes_axis_wrapper.v`)

- **S_AXIS** (slave): plaintext in - `TDATA[127:0] / TVALID / TREADY / TLAST`.
- **M_AXIS** (master): ciphertext out - same signals.
- **TLAST** was added (beyond the original TDATA/TVALID/TREADY request) because
  the DMA/IRQ needs *packet boundaries*. It is carried through a shadow shift
  register that advances in lockstep with the data pipeline, so the LAST flag
  re-emerges aligned with its own ciphertext block.

#### Back-pressure - the key correctness point

A filled pipeline cannot hold back a result about to pop out. When the consumer
is not ready while a valid output is present, the **entire pipeline is frozen**
via the core's clock-enable, and input acceptance stops too. Nothing is dropped
or reordered.

```
en            = ~(out_valid & ~m_axis_tready)   // stall on a blocked output
s_axis_tready =  en & key_ready                 // accept only while advancing
accept        =  s_axis_tvalid & s_axis_tready
```

AXI4-Stream compliance:
- `M_AXIS_TVALID` does **not** depend on `M_AXIS_TREADY`.
- `S_AXIS_TREADY` depends only on the *other* channel's TREADY, never on
  `S_AXIS_TVALID`.
- On a stall, `TVALID` stays high with stable `TDATA`/`TLAST` until handshake.

### DMA engine (`aes_dma.v`)

A compact stand-in for a full AXI4 memory-mapped DMA (e.g. Xilinx AXI DMA),
performing two **concurrent** transfers:

- **MM2S** (read): `buffer[src_base + i]` → AXIS master → AES input.
- **S2MM** (write): AES output → AXIS slave → `buffer[dst_base + j]`.

Because MM2S and S2MM run in parallel, the engine streams: while early
ciphertext blocks are written back, later plaintext blocks are still being
fetched, keeping the AES pipeline full. Completion is detected from **TLAST** on
the returning ciphertext stream, which raises a single-cycle **`irq`** and
latches `done` until the next `start`.

> Buffer note: the engine assumes a **combinational-read** scratchpad
> (distributed/LUT RAM), so MM2S sustains one block/cycle with no prefetch FIFO.
> A BRAM-backed buffer (1-cycle registered read) only requires a small prefetch
> FIFO on the MM2S side; the control logic is unchanged.

---

## Phase 3 - Coprocessor (Approach A)

Approach A attaches the pipelined core as a tightly-coupled, **memory-mapped
coprocessor** (`aes_coproc.v`). It is an AXI4-Lite **slave**, so the CPU drives
it with ordinary load/store instructions - it is **core-agnostic** and attaches
to any RISC-V (Ibex, NEORV32, ...) with no custom-instruction port.

```
   CPU  --MMIO writes-->  [DIN0..3] --PUSH--> input FIFO --+
                                                           |  (credit-gated)
                                                     aes_pipeline_top
                                                           |
   CPU  <--MMIO reads--  [DOUT0..3] <--POP--- output FIFO -+--> irq
```

### The two problems it solves

1. **128 bits through 32-bit registers.** A 128-bit block cannot pass through
   RV32's registers in one instruction. Operands cross as **4x32-bit MMIO
   writes** (`DIN0..3`), assembled into a block and pushed into an input FIFO;
   results are read back as 4x32-bit words from `DOUT0..3`.

2. **Latency vs. throughput.** A single instruction that stalls the CPU for the
   10-cycle latency wastes the pipeline. Instead the model is **posted /
   decoupled**: the CPU can PUSH many blocks back-to-back, do other work, and
   collect results later via an output FIFO + **`irq`**. Issue and
   result-collection are decoupled, keeping the pipeline fed.

### Flow control - credit scheme (no pipeline stall)

A block is injected from the input FIFO only when a **credit** is free. Credits
start at `OUT_DEPTH`; each injection consumes one, each result the CPU pops
returns one. Because every in-flight block holds a credit until popped,
`(in_flight + out_fifo_count) <= OUT_DEPTH` always, so the output FIFO can
**always** accept an emerging result. The pipeline therefore runs free
(`en = 1`) and never stalls; bubbles flow through when no block is ready.

### A vs. B - the architectural distinction

| Aspect            | Approach A (coprocessor)        | Approach B (streaming DMA)      |
|-------------------|---------------------------------|---------------------------------|
| Bus role          | AXI4-Lite **slave** (CPU-fed)   | AXI-Stream + **bus master** (DMA) |
| Data movement     | through the CPU (MMIO words)    | autonomous, memory-to-memory    |
| Bottleneck        | CPU MMIO bandwidth (~5 stores/block) | the pipeline itself (1 blk/cyc) |
| Best for          | low-latency, few blocks, tight CPU coupling | bulk throughput, large buffers |
| CPU involvement   | per block (post + collect)      | per transfer (setup + 1 irq)    |

Both keep the *internal* pipeline at 1 block/cycle; they differ in **who feeds
it**. The coprocessor is limited by how fast the CPU can issue MMIO stores; the
DMA removes the CPU from the data path entirely, so it alone reaches the full
~14.2 Gbps. This is the core lesson of the comparison.

---

## Verification Strategy

All testbenches are **self-checking** against the existing DPI-C golden model
(`uvm/dpi/aes_dpi.c`) and were run on Vivado 2024.1 `xsim`.

### In-flight scoreboard (the pipeline adaptation)

Because the AES pipeline is **strictly order-preserving** (block N out always
corresponds to block N in), the scoreboard adaptation for in-flight transactions
is simply a **FIFO**:

```
on input accept :  push  aes_encrypt_dpi(key, plaintext)   into expected_q
on output valid :  pop   expected_q  and compare to ciphertext
```

The DPI golden model itself is unchanged - only the bookkeeping moves from a
single-compare to a queue. No transaction IDs are needed.

### Testbenches and results

| Testbench             | What it proves                                              | Result            |
|-----------------------|------------------------------------------------------------|-------------------|
| `tb_aes_pipeline.sv`  | KAT + 10-cycle latency; 1 block/cycle; 200 random (FIFO); back-pressure | **254 / 254 pass** |
| `tb_aes_axis.sv`      | 40 random packets, dual-side randomized back-pressure, TLAST alignment   | **182 / 182 pass, 40 TLAST** |
| `tb_aes_dma.sv`       | 50-block DMA, write-back checked, single `irq`, streaming timing         | **50 / 50 pass, irq=1** |
| `tb_aes_coproc.sv`    | AXI4-Lite MMIO: KAT, posted burst (8 before pop), IRQ-driven 40-block stream | **49 / 49 pass** |

The DMA test measured **61 cycles** from `start` to `irq` for 50 blocks
(50 inject + 10 fill + 1), versus ~500 for a one-block-at-a-time engine -
direct evidence of streaming behaviour. The coprocessor test pushes 8 blocks
*before* popping any, proving issue/result decoupling and FIFO ordering.

---

## Synthesis Results (post-route, xc7a100tcsg324-1)

Synthesized **out-of-context** (these are IP blocks, not top-level chips - the
128-bit buses are internal fabric nets, not package pins).

### Resource utilization

| Block                              | LUTs  | FFs   | BRAM | DSP |
|------------------------------------|-------|-------|------|-----|
| Iterative core `aes_top` (baseline)| 2,309 | 1,986 | 0    | 0   |
| **Pipelined core** `aes_pipeline_top` | **7,677** | **2,712** | 0 | 0 |
| AXIS wrapper (core + TLAST glue)   | 7,725 | 2,715 | 0    | 0   |
| DMA controller `aes_dma`           | 78    | 73    | 0    | 0   |
| **Approach B** - streaming (wrapper + DMA) | **~7,803** | **~2,788** | 0 | 0 |
| **Approach A** - coprocessor `aes_coproc` | **8,019** | **3,052** | 0 | 0 |

The AXI4-Stream interface (valid/ready/TLAST alignment) costs only **+48 LUTs**
over the bare core; the DMA adds **78 LUTs**. The coprocessor adds **+342 LUTs**
over the bare core for the full AXI4-Lite slave, two FIFOs (176 LUTs as
distributed RAM) and the credit logic. **Both integration wrappers are nearly
free** relative to the ~7,700-LUT cryptographic datapath - the architectural
choice is driven by *system fit*, not gate count.

### Performance comparison

| Metric                | Iterative `aes_top` | Pipelined          | Factor    |
|-----------------------|---------------------|--------------------|-----------|
| Throughput            | 1 block / ~21 cyc   | **1 block / cyc**  | **~21×**  |
| Fmax (post-route)     | ~108 MHz            | **110.9 MHz**      | ≈ equal   |
| Sustained bitrate     | ~0.66 Gbps          | **~14.2 Gbps**     | **~21×**  |
| Latency               | ~21 cycles          | 10 cycles          | 0.5×      |
| Slice LUTs            | 2,309               | 7,677              | 3.3×      |
| Slice FFs             | 1,986               | 2,712              | 1.37×     |
| BRAM / DSP            | 0 / 0               | 0 / 0              | -         |

`Fmax` derived from worst-case setup slack: `1000 / (10.000 − 0.980) = 110.9 MHz`.
Bitrate = `Fmax × 128 bits/cycle`.

---

## Real RISC-V Integration (NEORV32)

Approaches A and B above are verified against AXI/AXIS bus models. To close the
loop with an *actual* processor, the coprocessor (Approach A) is wired to the
**NEORV32** RV32 core (v1.13.2) in a small SoC and driven by **compiled
firmware**:

```
   neorv32_top --XBUS (Wishbone)--> wb_to_axil --AXI4-Lite--> aes_coproc
        |  (rv32i, boots IMEM image)                              |
      gpio_o  <--- PASS/FAIL sentinel                        10-stage AES pipe
```

- `wb_to_axil.v` bridges NEORV32's Wishbone external bus to the coprocessor's
  AXI4-Lite slave, so the **AES block is reused unchanged** and the CPU sees it
  as MMIO at `0x9000_0000`.
- The firmware (`sw/aes_demo/main.c`) loads the key, pushes a plaintext block,
  polls STATUS, reads the ciphertext back, and checks it against the FIPS-197
  C.1 known answer - then reports on GPIO.
- `run_neorv32.sh` rebuilds the firmware image (no `make` needed) and runs the
  mixed-language simulation (NEORV32 VHDL + Verilog AES + SV testbench) on xsim.

**Result:** `*** PASS *** at cycle 472` - a real RISC-V core, executing compiled
instructions, encrypts a block on the hardware AES pipeline over a real bus and
gets the NIST-correct ciphertext. This makes the "RISC-V integrated" claim
literal rather than interface-only.

---

## Conclusions

1. **Throughput vs. area trade-off is highly favourable.** ~3.3× the LUTs buys
   ~21× the throughput. The unrolled pipeline does **not** lower the clock - the
   per-stage critical path is still a single AES round, so Fmax is preserved
   (in fact marginally higher than the iterative core's, free of FSM overhead).

2. **Both integration wrappers are nearly free.** AXI4-Stream + TLAST + DMA add
   ~126 LUTs; the AXI4-Lite coprocessor + dual FIFOs add ~342 LUTs. Both are a
   small fraction of the ~7,700-LUT datapath, so the **choice between Approach A
   and B is about system fit, not area**.

3. **A vs. B is a feeding problem, not a compute problem.** Internally both run
   the same 1-block/cycle pipeline. The coprocessor (A) is bounded by CPU MMIO
   bandwidth (~5 stores/block) and suits low-latency, tightly-coupled use; the
   DMA (B) takes the CPU out of the data path and alone reaches the full
   ~14.2 Gbps, suiting bulk throughput.

4. **Pipelining simplifies verification.** Strict order preservation reduces the
   in-flight scoreboard to a FIFO over the *unchanged* DPI golden model.

5. **Cost is on-chip resources, not money.** All results were produced with the
   free Vivado edition on the `xc7a100t`; every block uses 0 BRAM and 0 DSP, and
   the largest (the coprocessor) occupies ~13% of the part's LUTs.

## Files

| File                          | Role                                    |
|-------------------------------|-----------------------------------------|
| `rtl/aes_pipeline_top.v`      | 10-stage unrolled pipelined core        |
| `rtl/aes_axis_wrapper.v`      | AXI4-Stream wrapper (+ TLAST, back-pressure) |
| `rtl/aes_dma.v`               | MM2S/S2MM DMA + IRQ                      |
| `rtl/aes_stream_system.v`     | Buffer + DMA + AES integration top (Approach B) |
| `rtl/aes_coproc.v`            | AXI4-Lite memory-mapped coprocessor (Approach A) |
| `sim/tb_aes_pipeline.sv`      | Pipeline core self-checking TB           |
| `sim/tb_aes_axis.sv`          | AXI4-Stream wrapper TB                    |
| `sim/tb_aes_dma.sv`           | DMA system TB                            |
| `sim/tb_aes_coproc.sv`        | Coprocessor AXI4-Lite TB                  |
| `run_pipeline.tcl`            | Build/run the pipeline TB (xsim)         |
| `run_stream.tcl`              | Build/run the streaming TBs (xsim)       |
| `synth_pipeline.tcl`          | OOC synth + place&route for area/Fmax    |
| `rtl/wb_to_axil.v`            | Wishbone -> AXI4-Lite bridge (NEORV32)    |
| `rtl/neorv32_aes_soc.vhd`     | NEORV32 + bridge + coprocessor SoC top    |
| `sw/aes_demo/main.c`          | Firmware: CPU drives AES over MMIO        |
| `sim/tb_neorv32_aes.sv`       | Real-RISC-V SoC testbench                  |
| `run_neorv32.sh`              | Build firmware + run NEORV32 SoC sim       |
