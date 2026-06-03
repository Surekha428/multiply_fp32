# fmultiplier — FP32 Multiplier (Handshake, Multi-Cycle, IEEE-754)

## Overview
`fmultiplier` computes `z = a * b` where `a`, `b`, `z` are IEEE-754 **single-precision
(binary32)** numbers. It is **multi-cycle**: one operation at a time, started with a
`valid` pulse and completed with an `out_valid` pulse. Internally a small FSM
(`counter`) walks the operation through a fixed sequence of stages.

What this design must get exactly right (this is what is verified):
- **Bit-accurate results for normal × normal → normal**, using IEEE-754
  **round-to-nearest-even (RNE)**.
- A clean `valid` / `out_valid` handshake.
- **No `X`/`Z` on any output after reset.**

> **Grading scope (read this first).** The testbench multiplies random **normal** FP32
> operands and requires the result to be **bit-identical** to a host FP32 multiply.
> NaN/Inf inputs are disabled by default and **subnormal *outputs* are skipped**. So the
> only path you must get perfect is **normal × normal → normal**. Handling of
> NaN/Inf/zero/subnormal is optional — implement it minimally (or with safe defaults)
> and spend your effort on the normal path and on never emitting `X`.

---

## Interface

### Ports
| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk`   | in  | 1  | Clock |
| `rst`   | in  | 1  | **Synchronous, active-high** reset |
| `valid` | in  | 1  | **1-cycle start pulse**; accepted only when not busy |
| `a`     | in  | 32 | Operand A (FP32 bits) |
| `b`     | in  | 32 | Operand B (FP32 bits) |
| `z`         | out | 32 | Result (FP32 bits) |
| `out_valid` | out | 1  | **1-cycle pulse** when `z` is valid |

### Handshake contract
- When `busy == 0`, a high `valid` sampled on a rising edge **starts** an operation:
  `a` and `b` are latched into internal regs (`a_r`, `b_r`) and the FSM advances from
  `counter = 0` toward completion.
- While `busy == 1`, further `valid` pulses are **ignored**.
- On completion: `z` is updated, `out_valid` is asserted **for exactly one cycle**, and
  `busy` is cleared so the next operation can start.

### Reset contract (do not skip — this fails the test if wrong)
- `rst` is **synchronous and active-high**: sample it on `posedge clk`. Use
  `always @(posedge clk)` with `if (rst) ... else ...` (do **not** put `rst` in the
  sensitivity list).
- On reset, drive **every** register to a known value: `z <= 0`, `out_valid <= 0`,
  `busy <= 0`, `counter <= 0`, and all datapath regs (`a_r,b_r`, mantissas, exponents,
  signs, product, guard/round/sticky) to 0.
- After reset deasserts, `z`, `out_valid`, and `busy` must **never read as `X`/`Z`** —
  the testbench reads them as integers and will error on `X`.

---

## Latency
- Multi-cycle, single-issue. A fixed latency in the range of about **7 cycles** from the
  accepted `valid` to `out_valid` is the design target.
- Exact latency is **not** asserted (the test waits up to 100 cycles for `out_valid`), so
  any deterministic small cycle count is acceptable. Correctness of `z` is what matters.

---

## Recommended structure (minimal and robust — follow this)

You do **not** need a deep multi-stage pipeline, and a hand-rolled multi-stage FSM is the
most common source of bugs (stale regs, mistimed `out_valid`, `X` reads). The simplest
**correct** design is a 2-state machine, and it comfortably meets the latency window:

- **Outputs to register:** `z`, `out_valid`, plus control `busy` and operand latches
  `a_r`, `b_r`. Everything else (mantissas, product, guard/round/sticky, exponents) can be
  **local blocking-assignment temporaries** computed inside the busy cycle — they do not
  need to be module-level regs.
- Use one `always @(posedge clk)` block with **synchronous** reset.

```
always @(posedge clk) begin
    if (rst) begin
        z <= 32'd0; out_valid <= 1'b0; busy <= 1'b0;
        a_r <= 32'd0; b_r <= 32'd0;            // init EVERY reg you declare
    end else begin
        out_valid <= 1'b0;                     // default: deassert each cycle
        if (!busy) begin
            if (valid) begin                   // accept a new op only when idle
                a_r <= a; b_r <= b; busy <= 1'b1;
            end
        end else begin
            // ---- do the full computation on a_r/b_r here (steps 1-7 below) ----
            // ... compute sign_z, exp_z, mant_z via blocking temps ...
            z <= packed_result;                // step 7
            out_valid <= 1'b1;                  // exactly one cycle
            busy <= 1'b0;
        end
    end
end
```

This gives a fixed 2-cycle latency (latch, then compute) and makes `out_valid` a clean
1-cycle pulse. All of the arithmetic below can be done combinationally within that single
busy cycle using `reg`/blocking temporaries inside the `else` branch.

---

## The algorithm (standard, exact — implement this)

Use the textbook single-precision multiply. Below, fields are extracted from the latched
operands `a_r`, `b_r`.

### 1. Unpack
For each operand `x` in {a, b}:
- `sign_x = x[31]`
- `exp_x  = x[30:23]`            (8-bit biased exponent)
- `frac_x = x[22:0]`             (23-bit fraction)
- `mant_x = {1'b1, frac_x}`      (**24-bit** significand with the implicit leading 1)

> For normal operands `exp_x` is in `1..254`, so the implicit `1` is always present. (For
> a true subnormal `exp_x == 0` the implicit bit is `0`, but subnormal handling is not
> graded — a minimal/normal-only path is fine.)

### 2. Sign
- `sign_z = sign_a ^ sign_b`

### 3. Exponent (biased domain — no off-by-one traps)
Work directly in the **biased** domain:
- `exp_sum = exp_a + exp_b - 127`   (use a signed/wide reg, e.g. 10 bits, to hold the
  intermediate; `127` is the binary32 bias)

The final `+1` correction (if any) is applied during normalization below, **based on the
product**, not guessed up front.

### 4. Significand product (24 × 24 → 48 bits)
- `product = mant_a * mant_b`   (declare `product` at least **48 bits** wide)

Because each `mant` is in `[2^23, 2^24)`, `product` is in `[2^46, 2^48)`, i.e. exactly
**bit 47 or bit 46** is the most-significant set bit.

### 5. Normalize + extract guard/round/sticky (two cases on `product[47]`)
There are exactly two cases. Pick the 24-bit result mantissa so that its MSB
(`mant_z[23]`) is the leading 1, and read guard/round/sticky from the bits just below it.

**Case A — `product[47] == 1`** (significand in `[2,4)`, exponent grows by 1):
- `mant_z = product[47:24]`              (24 bits)
- `guard  = product[23]`
- `round  = product[22]`
- `sticky = | product[21:0]`             (OR-reduce the remaining low bits)
- `exp_z  = exp_sum + 1`

**Case B — `product[47] == 0`** (significand in `[1,2)`; here `product[46] == 1`):
- `mant_z = product[46:23]`              (24 bits)
- `guard  = product[22]`
- `round  = product[21]`
- `sticky = | product[20:0]`
- `exp_z  = exp_sum`

### 6. Round to nearest even (RNE)
Compute a single round-up decision, then handle the carry-out:
```
round_up = guard & (round | sticky | mant_z[0]);   // mant_z[0] = tie-to-even term
if (round_up) begin
    mant_z = mant_z + 1;
    if (mant_z == 24'h0) begin        // carried out of bit 23 (was 0xFFFFFF -> 0x000000)
        mant_z = 24'h800000;          // renormalize to 1.0...
        exp_z  = exp_z + 1;           // bump exponent
    end
end
```
> The `mant_z[0]` term is what makes it round-to-nearest-**even** rather than
> round-half-up. Do not drop it. Equivalent carry test: increment into a 25-bit temp and
> check bit 24.

### 7. Pack
- If `exp_z >= 255` → **overflow to infinity**: `z = {sign_z, 8'hFF, 23'h0}`.
- Else if `exp_z <= 0` → underflow toward zero/subnormal (not graded; emitting
  `{sign_z, 8'h0, 23'h0}` is an acceptable safe default).
- Else (normal): `z = {sign_z, exp_z[7:0], mant_z[22:0]}`   (drop the implicit
  `mant_z[23]`).

Then assert `out_valid` for one cycle and clear `busy`.

> **Special inputs (optional, not graded by default).** If you choose to handle them:
> NaN in → quiet NaN `0x7FC00000`; Inf × (nonzero) → signed Inf; Inf × 0 → NaN; any × 0
> → signed zero. None of this is required to pass the default test.

---

## Worked numeric checks (use these to self-verify the bit math)

**`1.5 × 1.5 = 2.25`**
- `1.5 = 0x3FC00000`: `exp = 127`, `mant = 0xC00000`.
- `product = 0xC00000 * 0xC00000 = 0x900000000000` → `product[47] = 1` (**Case A**).
- `mant_z = product[47:24] = 0x900000`; `guard/round/sticky = 0`; no round-up.
- `exp_z = (127 + 127 - 127) + 1 = 128`.
- `z = {0, 8'd128, 0x100000} = 0x40100000` = `2.25`. ✓

**`1.0 × 2.0 = 2.0`**
- `1.0 = 0x3F800000` (`exp 127`, `mant 0x800000`), `2.0 = 0x40000000` (`exp 128`, `mant 0x800000`).
- `product = 0x800000 * 0x800000 = 0x400000000000` → `product[47] = 0`, `product[46] = 1` (**Case B**).
- `mant_z = product[46:23] = 0x800000`; guard/round/sticky = 0; no round-up.
- `exp_z = 127 + 128 - 127 = 128`.
- `z = {0, 8'd128, 0x000000} = 0x40000000` = `2.0`. ✓

---

## Implementation constraints
- Must be **synthesizable**.
- **Do not use SystemVerilog Assertion (SVA) `property`/`sequence`/`assert property`
  syntax** — the simulator (Icarus Verilog) does not support it.
- Keep the module name `fmultiplier` and the port list above unchanged.
- A single sequential `always @(posedge clk)` block driving the FSM is sufficient; you may
  use blocking temporaries inside a stage for the normalize/round math.
