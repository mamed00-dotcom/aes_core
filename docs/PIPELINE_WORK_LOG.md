# AES-128 Pipeline + RISC-V Work Log

Everything added on branch `feature/aes-pipeline-riscv`, why it was added, and
what problem each piece solved. The starting point was the working iterative
AES-128 core (`aes_top.v`): FSM-driven, ~21-cycle latency, 1 block per ~21
cycles, AXI4-Lite, verified 155/155 in UVM. The goal was a high-throughput
pipelined core plus two ways to integrate it with a RISC-V, so the two
architectures could be compared on performance and complexity.

All results below were produced on Vivado 2024.1 `xsim` and synthesis,
`xc7a100tcsg324-1`, using the free Vivado edition. Nothing was committed or
pushed; no external contributor was added.

---

## Key decisions taken up front

| Decision | Choice | Why |
|----------|--------|-----|
| Key model | **Fixed key** | Precompute the 11 round keys once and fan them out. Saves ~40 S-boxes vs. a key-agile design and keeps the key-schedule critical path to one stage (a 10-deep combinational key chain would wreck Fmax). |
| Coprocessor ABI | **Posted / decoupled** | A 128-bit block cannot pass through RV32's 32-bit registers in one instruction, and a single stalling instruction wastes the pipeline. Posting operands + collecting later solves both. |
| Coprocessor attach | **Core-agnostic (MMIO)** | An AXI4-Lite slave driven by plain load/store works on any RISC-V (Ibex, NEORV32) with no custom-instruction port. |
| Build order | **Phase by phase** | Each stage verified before the next, so a problem is caught while the design is still small. |

---

## Phase 1 - Pipelined core

**What's new:** `rtl/aes_pipeline_top.v` - the 10 encryption rounds unrolled in
cascade, each followed by one pipeline register, with a one-time key-expansion
FSM, a `valid` shift register, and a global clock-enable `en`.
Plus `sim/tb_aes_pipeline.sv` and `run_pipeline.tcl`.

**Why:** the iterative core reuses one round over ~21 cycles, so it processes one
block per ~21 cycles. Unrolling gives a fixed 10-cycle latency but **one block
every clock** once the pipeline is full - the core throughput goal.

**What it fixed / proved:** verified **254/254** checks - FIPS-197 known-answer,
exactly 10-cycle latency, 1 block/cycle throughput, 200 random blocks checked
through a reference FIFO, and `en` back-pressure losing nothing. This is the
foundation both integration approaches sit on.

---

## Phase 2 - Streaming integration (Approach B)

**What's new:**
- `rtl/aes_axis_wrapper.v` - AXI4-Stream slave (plaintext in) + master
  (ciphertext out).
- `rtl/aes_dma.v` - DMA running MM2S (read+stream) and S2MM (stream+write)
  concurrently, with a completion `irq`.
- `rtl/aes_stream_system.v` - buffer RAM + DMA + wrapper wired together.
- `sim/tb_aes_axis.sv`, `sim/tb_aes_dma.sv`, `run_stream.tcl`.

**Why:** to actually exploit the 1-block/cycle throughput, the core has to be
fed continuously without the CPU in the loop. A DMA streaming the buffer through
the core is the architecture that does that.

**Two problems solved in this phase:**

1. **`TLAST` was added** (the original spec asked for `TDATA/TVALID/TREADY`
   only). The DMA/IRQ needs to know when a buffer of N blocks ends, and that is
   exactly what `TLAST` carries. It is pushed through a shadow shift register so
   the LAST flag re-emerges aligned with its own ciphertext block 10 cycles
   later.
2. **Back-pressure into a full pipeline.** A filled pipeline cannot hold back a
   result about to pop out, so when the consumer is not ready the **entire
   pipeline is frozen** via `en`, and input acceptance stops too. This keeps the
   interface AXI-Stream compliant (`TVALID` never depends on `TREADY`) and loses
   nothing.

**What it fixed / proved:**
- Wrapper TB: **182 blocks / 40 packets**, all correct with `TLAST` aligned,
  under randomized back-pressure on *both* stream sides.
- DMA TB: **50/50** blocks correct, single `irq`, and **61 cycles** start-to-irq
  for 50 blocks versus ~500 for one-block-at-a-time - direct proof of streaming.

> The DMA is a compact, synthesizable stand-in for a full AXI4 memory-mapped DMA
> (control via direct ports, on-chip scratchpad buffer). The buffer is modeled
> combinational-read so MM2S needs no prefetch FIFO; a BRAM buffer would add one
> with no control-logic change. This was deliberate, to keep Phase 2 focused on
> the streaming datapath and the IRQ hand-off.

---

## Phase 3 - Coprocessor integration (Approach A)

**What's new:** `rtl/aes_coproc.v` - an AXI4-Lite **slave** memory-mapped
coprocessor wrapping the pipeline, with an input FIFO, an output FIFO, a credit
counter, and an `irq`. Plus `sim/tb_aes_coproc.sv` (an AXI4-Lite master BFM).

**Why:** to provide the *tightly-coupled* alternative to the DMA, driven
directly by the CPU - and to make it a genuinely different architecture, not a
second DMA.

**Three problems solved:**

1. **128 bits through 32-bit registers** - operands cross as 4x32-bit MMIO
   writes (`DIN0..3`), assembled into a block and pushed into the input FIFO;
   results are read back as 4x32-bit words from `DOUT0..3`.
2. **Latency vs. throughput** - instead of one stalling instruction, the model
   is posted/decoupled: the CPU pushes many blocks, does other work, and
   collects results later via the output FIFO + `irq`.
3. **Output overflow without stalling** - a credit scheme (credits start at
   `OUT_DEPTH`, decrement on injection, increment on CPU pop) guarantees the
   output FIFO can always accept an emerging result, so the pipeline runs free
   (`en = 1`) and never has to stall.

**What it fixed / proved:** verified **49/49** - single-block KAT through MMIO,
a posted burst of 8 blocks pushed *before* any pop (proving issue/result
decoupling and FIFO ordering), and a 40-block IRQ-driven stream.

---

## A vs. B - what the comparison showed

Both wrap the *same* 1-block/cycle pipeline at the *same* clock. They differ in
**who feeds the core**:

| | Approach A (coprocessor) | Approach B (streaming DMA) |
|--|--------------------------|----------------------------|
| Bus role | AXI4-Lite slave (CPU-fed) | AXI-Stream + bus master |
| Bottleneck | CPU MMIO bandwidth | the pipeline itself |
| Best for | low-latency, tight coupling | bulk throughput (~14.2 Gbps) |

The lesson: the choice is a **feeding problem, not a compute problem**.

---

## Synthesis - turning claims into numbers

**What's new:** `synth_pipeline.tcl` and the post-route data folded into
`docs/AES_PIPELINE_COMPARISON.md`.

**Why:** the whole project is a *comparison*; without real area/Fmax numbers the
comparison is hand-waving. Synthesis also proves the RTL is synthesizable, not
just simulatable.

**Results (post-route, xc7a100t):**

| Block | LUTs | FFs | BRAM/DSP | Fmax |
|-------|------|-----|----------|------|
| Iterative `aes_top` (baseline) | 2,309 | 1,986 | 0/0 | ~108 MHz |
| Pipelined core | 7,677 | 2,712 | 0/0 | **110.9 MHz** |
| Approach B (wrapper + DMA) | ~7,803 | ~2,788 | 0/0 | - |
| Approach A (coprocessor) | 8,019 | 3,052 | 0/0 | - |

The headline: **~3.3x the LUTs buys ~21x the throughput at the same clock**, with
0 BRAM and 0 DSP. My earlier "~10x area" caution was pessimistic; the iterative
baseline already carries AXI + FSM + key storage, and S-boxes map efficiently.

---

## Phase 4 - Verification strategy in the real UVM env

**What's new:** a full parallel UVM environment for the pipelined core -
`uvm/top/aes_pipe_if.sv`, `uvm/env/aes_pipe_{item,driver,monitor,scoreboard,agent,env}.sv`,
`uvm/seq/aes_pipe_seq.sv`, `uvm/test/aes_pipe_test.sv`,
`uvm/top/aes_pipe_tb_top.sv`, and `run_uvm_pipe.tcl`.

**Why:** the original env drives the iterative core one block at a time (the
driver blocks waiting for `valid` after each), so it never has in-flight
transactions. To prove the scoreboard strategy for a pipeline, the env itself
had to change.

**The three protocol changes (the actual answer to the original prompt):**

1. **Driver** streams fire-and-forget (`try_next_item`, no wait-for-result), so
   blocks go in back-to-back - this is what creates in-flight transactions.
2. **Monitor** has *two* analysis ports: `ap_in` on each accepted input and
   `ap_out` on each valid output.
3. **Scoreboard** becomes a FIFO (`uvm_analysis_imp_decl(_in/_out)`): push the
   DPI-C golden result on input, pop and compare on output. The **DPI-C golden
   model is unchanged** - only the bookkeeping moved from single-compare to a
   queue, because the pipeline is strictly order-preserving.

**What it fixed / proved:** **200/200 passed, UVM_ERROR = 0, UVM_FATAL = 0,
peak in-flight = 11**. The "11" is the proof: the scoreboard tracked 11
transactions at once (10 stages + 1) - something the old single-compare
scoreboard could not do. The existing `aes_top` env was left untouched (the
build scripts use explicit file lists, so the new files do not interfere).

---

## Phase 6 - Real RISC-V integration (NEORV32)

**What's new:** an actual RISC-V SoC that runs compiled firmware driving the AES
coprocessor over a real bus - the literal version of the "RISC-V integrated"
claim, where earlier phases only provided RISC-V-*attachable* peripherals
verified against bus BFMs.

- `rtl/neorv32_aes_soc.vhd` - SoC top (VHDL) wiring `neorv32_top` (the NEORV32
  RV32 core) to `aes_coproc` through the bridge below. Mixed-language: NEORV32
  is VHDL, the AES + bridge are Verilog (instantiated as components). Boots
  `BOOT_MODE_SELECT=2` (directly from the pre-initialized IMEM image, no
  bootloader), base rv32i, internal IMEM/DMEM, XBUS on, GPIO for a result
  sentinel.
- `rtl/wb_to_axil.v` - Wishbone-b4 (classic) slave -> AXI4-Lite master bridge.
  NEORV32's external bus (XBUS) is Wishbone; the coprocessor is AXI4-Lite. The
  bridge lets the CPU reach it as plain MMIO at `0x9000_0000` with the AES block
  **unchanged**.
- `sw/aes_demo/main.c` - bare-metal firmware (raw MMIO, no BSP): load key, push
  a plaintext block, poll STATUS, read the ciphertext, check it against the
  FIPS-197 C.1 known answer, drive PASS/FAIL onto GPIO.
- `sim/tb_neorv32_aes.sv` - SV testbench that clocks the SoC and watches the
  GPIO sentinel.
- `run_neorv32.sh` - one script that rebuilds firmware **without `make`**
  (`make` isn't installed): host-compile `image_gen`, cross-compile+link with
  the NEORV32 linker script and `crt0.S`, `objcopy` to a flat binary,
  `image_gen -t vhd` to regenerate `neorv32_imem_image.vhd`, then mixed-language
  elaborate (NEORV32 VHDL into library `neorv32`, the Verilog + SV) and run.

**Toolchain:** xPack `riscv-none-elf-gcc` 15.2.0 (portable, extracted to
`~/tools`); NEORV32 v1.13.2 cloned to `~/Desktop/neorv32`. Both are *outside*
this repo; `run_neorv32.sh` takes their paths from `NEORV32_HOME` / `RISCV_DIR`
(defaults baked in).

**What it proved:** a **real RV32 core executing compiled instructions** drove
the AES coprocessor over **XBUS -> AXI4-Lite** and read back the **NIST-correct
ciphertext** - `*** PASS *** at cycle 472`. This is end-to-end: C source ->
RISC-V machine code -> IMEM image -> CPU load/store -> Wishbone -> AXI4-Lite ->
pipelined AES -> result checked in firmware.

**IRQ-driven variant (added after the polling version):** `sw/aes_demo/main_irq.c`
wires the coprocessor `irq` to the RISC-V machine-external interrupt
(`irq_mei_i` on `neorv32_top`) and replaces polling with a trap handler + `WFI`.
The ISR drains the result FIFO - which deasserts the level-sensitive `irq`, so
it self-clears - and sets a done flag. `run_neorv32.sh` now takes the firmware
source via `FW_SRC` (default `main.c`). Both variants pass: polling at cycle
472, IRQ-driven at cycle 676 (the extra cycles are interrupt setup + WFI wake +
trap entry/exit). Because `g_done` is set *only* by the ISR, reaching PASS
proves the interrupt fired and the handler ran.

**Things solved in this phase:**

1. **`make` is missing** - replicated NEORV32's image build by hand (the six
   steps above), so no `make` dependency.
2. **Bus mismatch** - NEORV32 speaks Wishbone (XBUS), the coprocessor speaks
   AXI4-Lite. The `wb_to_axil` bridge translates single 32-bit transfers; the
   coprocessor asserts AWREADY/WREADY together, so the bridge drives AW+W at
   once.
3. **Mixed-language elaboration** - NEORV32 (VHDL) compiled into library
   `neorv32` via its own `rtl/file_list_soc.f`; the AES (Verilog) bound to VHDL
   components by name. `xelab` rejects the `--2008` flag (that's an `xvhdl`
   flag) - dropping it fixed elaboration.

---

## Problems we hit and fixed along the way

| Problem | Cause | Fix |
|---------|-------|-----|
| Placer failed: "391 I/O ports overutilization" | Synthesizing the core as if it were a whole chip, mapping every wide-bus bit to a package pin | Synthesize **out-of-context** (`-mode out_of_context`) - it is an IP block, buses are internal nets |
| `aes_stream_system` reported only 57 LUTs | The buffer makes the ciphertext unobservable, so synthesis legally pruned the whole datapath | Measured the wrapper and DMA separately (real stream outputs, nothing pruned) |
| Synth error: `in_count[5:0] out of range` | FIFO counts are 4-5 bits, but the STATUS read sliced `[5:0]`; simulation was lenient, synthesis strict | Zero-extend counts to fixed 6-bit STATUS fields; build STATUS bit-by-bit |
| Intermittent Vivado `lib_core.tcl / unimacro` flake | Helper-process race when running several synth runs back-to-back | Retried in a fresh Vivado session |
| `xsim` printed help / wouldn't take `--testplusarg` | The `bin/xsim` wrapper rejects that flag; the unwrapped exe needs Vivado's DLL env | `tb_top` hardcodes `run_test("aes_pipe_test")`, so plain `--runall` works; `run_uvm_pipe.tcl` uses the unwrapped exe like `run_uvm.tcl` (works from the Vivado Tcl Shell) |
| em-dash characters in files | Authoring habit | Replaced all 58 `-` style em-dashes with plain hyphens at your request |

---

## Test results at a glance

| Suite | Result |
|-------|--------|
| `tb_aes_pipeline.sv` (core) | 254 / 254 |
| `tb_aes_axis.sv` (stream wrapper) | 182 / 182, 40 TLAST |
| `tb_aes_dma.sv` (DMA system) | 50 / 50, irq=1, + zero-length guard |
| `tb_aes_coproc.sv` (coprocessor) | 57 / 57 (incl. mid-stream KEY_LOAD interlock) |
| Pipelined UVM env (`aes_pipe_test`) | 200 / 200, peak in-flight 11 |
| `tb_neorv32_aes.sv` (real RISC-V SoC, polling fw) | PASS - CPU-driven AES, FIPS-197 C.1, cycle 472 |
| `tb_neorv32_aes.sv` (real RISC-V SoC, IRQ fw) | PASS - IRQ-driven (ISR + WFI), cycle 676 |

---

## File map of new work

```
rtl/
  aes_pipeline_top.v      10-stage pipelined core (fixed key)
  aes_axis_wrapper.v      AXI4-Stream wrapper (+TLAST, back-pressure)   [Approach B]
  aes_dma.v               MM2S/S2MM DMA + IRQ                           [Approach B]
  aes_stream_system.v     buffer + DMA + wrapper top                    [Approach B]
  aes_coproc.v            AXI4-Lite memory-mapped coprocessor + FIFOs   [Approach A]
  wb_to_axil.v            Wishbone -> AXI4-Lite bridge                  [NEORV32]
  neorv32_aes_soc.vhd     NEORV32 + bridge + coprocessor SoC top (VHDL) [NEORV32]
sw/
  aes_demo/main.c         bare-metal firmware: CPU drives AES via MMIO  [NEORV32]
  aes_demo/main_irq.c     IRQ-driven firmware variant (ISR + WFI)       [NEORV32]
sim/
  tb_aes_pipeline.sv      core self-checking TB
  tb_aes_axis.sv          stream wrapper TB
  tb_aes_dma.sv           DMA system TB
  tb_aes_coproc.sv        coprocessor AXI4-Lite TB
  tb_neorv32_aes.sv       real-RISC-V SoC TB (watches GPIO sentinel)    [NEORV32]
uvm/                      parallel UVM env for the pipeline (FIFO scoreboard)
  top/aes_pipe_if.sv  top/aes_pipe_tb_top.sv
  env/aes_pipe_{item,driver,monitor,scoreboard,agent,env}.sv
  seq/aes_pipe_seq.sv  test/aes_pipe_test.sv
docs/
  AES_PIPELINE_COMPARISON.md   architecture + synthesis + verification
  PIPELINE_WORK_LOG.md         this file
run_pipeline.tcl  run_stream.tcl  run_uvm_pipe.tcl  synth_pipeline.tcl
```
