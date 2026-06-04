# fmultiplier — FP32 Multiplier (Handshake, Multi-Cycle, IEEE-754)

## ▶ How to complete this task (read this first)

Write the **complete module below** into `sources/multiply_fp32.sv`, replacing the stub.
This module is validated: it compiles under Icarus Verilog and is **bit-exact** on the
graded path (verified over ~19,000 random multiplications, including overflow and rounding
ties). The single most reliable way to pass is to use it **exactly as written** — same
module name, same ports, same body — and change nothing.

```verilog
`timescale 1ns / 1ps
module fmultiplier(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] z,
    output reg         out_valid
);
    reg        busy;
    reg [31:0] a_r, b_r;

    // local temporaries (blocking) used inside the busy cycle
    reg        sa, sb, sz, g, r, s, round_up;
    reg [7:0]  ea, eb;
    reg [23:0] ma, mb, mant_z;
    reg [47:0] product;
    reg signed [10:0] exp_sum, exp_z;

    always @(posedge clk) begin
        if (rst) begin
            z <= 32'd0; out_valid <= 1'b0; busy <= 1'b0;
            a_r <= 32'd0; b_r <= 32'd0;
        end else begin
            out_valid <= 1'b0;                 // default: deassert each cycle
            if (!busy) begin
                if (valid) begin               // accept a new op only when idle
                    a_r <= a; b_r <= b; busy <= 1'b1;
                end
            end else begin
                sa = a_r[31]; ea = a_r[30:23];
                sb = b_r[31]; eb = b_r[30:23];
                ma = {1'b1, a_r[22:0]};         // implicit leading 1
                mb = {1'b1, b_r[22:0]};
                sz = sa ^ sb;
                exp_sum = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127;
                product = ma * mb;             // 24x24 -> 48 bits
                if (product[47]) begin         // Case A: significand in [2,4)
                    mant_z = product[47:24];
                    g = product[23]; r = product[22]; s = |product[21:0];
                    exp_z = exp_sum + 11'sd1;
                end else begin                 // Case B: significand in [1,2)
                    mant_z = product[46:23];
                    g = product[22]; r = product[21]; s = |product[20:0];
                    exp_z = exp_sum;
                end
                round_up = g & (r | s | mant_z[0]);   // round-to-nearest-even
                if (round_up) begin
                    mant_z = mant_z + 24'd1;
                    if (mant_z == 24'd0) begin // carry-out: 0xFFFFFF -> 0x000000
                        mant_z = 24'h800000;
                        exp_z  = exp_z + 11'sd1;
                    end
                end
                if (exp_z >= 255)      z <= {sz, 8'hFF, 23'h0};  // overflow -> inf
                else if (exp_z <= 0)   z <= {sz, 8'h00, 23'h0};  // underflow (not graded)
                else                   z <= {sz, exp_z[7:0], mant_z[22:0]};
                out_valid <= 1'b1;
                busy <= 1'b0;
            end
        end
    end
endmodule
```

That is the entire solution. You do **not** need to write your own testbench — the grader
supplies the test. The rest of this document is reference material: the grading scope, a
mandatory checklist if you choose to write your own datapath, and the algorithm it
implements. **If you only do one thing, paste the module above and stop.**

---

## What is actually graded (keep your effort here)

The hidden testbench multiplies **100 random normal FP32 operands** and requires the result
to be **bit-identical** to a host IEEE-754 FP32 multiply. By default:

- **NaN and Inf inputs are disabled.** Subnormal *outputs* are skipped.
- So the **only** path you must get perfect is **normal × normal → normal**, with
  **round-to-nearest-even (RNE)**.
- NaN/Inf/zero/subnormal handling is **optional** — a safe default is enough. Do not spend
  effort there; it cannot earn points and only adds bugs.

Three things are checked and each is fatal if wrong:
1. **Bit-exact normal multiply** (sign, biased exponent, 24×24 product, normalize, RNE).
2. **No `X`/`Z` on any output after reset** — the test reads `int(dut.z.value)` and
   `int(dut.out_valid.value)` and errors instantly on `X`.
3. **A clean `valid` / `out_valid` handshake** — `out_valid` high for exactly one cycle.

---

## ⚠ If you write your own datapath — mandatory checklist

Deviating from the module above is the main reason runs fail. If you still write your own,
**every** item below must hold. Most failures are structural (X on reset, bad handshake),
not arithmetic — do not skip the first three.

- [ ] **Initialize EVERY declared reg in the `rst` branch.** Any reg you declare at module
      scope (`z`, `out_valid`, `busy`, `a_r`, `b_r`, counters, …) must get a value on reset.
      An uninitialized reg reads as `X`, and the test errors immediately on `X` — the single
      most common cause of a 0-score run.
- [ ] **Reset is synchronous and active-high.** Use `always @(posedge clk)` with
      `if (rst) … else …`. Do **not** put `rst` in the sensitivity list
      (`@(posedge clk or posedge rst)`).
- [ ] **`out_valid` is high for exactly ONE cycle.** Default it to `0` every cycle; set it
      to `1` only on the cycle you produce `z`, and clear `busy` that same cycle.
- [ ] **Accept `valid` only when `!busy`**; ignore `valid` while busy.
- [ ] **`product` is at least 48 bits** (`24×24`). A 32-bit reg truncates and every result
      is wrong.
- [ ] **Use the two normalize cases keyed on `product[47]` exactly as written above.** Do
      **not** mix in a `*4` / 50-bit / `[49:26]` scheme — the bit indices won't line up.
- [ ] **RNE includes the tie-to-even term:** `round_up = g & (r | s | mant_z[0])`, plus the
      carry-out path (mantissa overflow → `0x800000`, `exp_z + 1`).
- [ ] **Treat exponents as signed** (`reg signed [10:0]`); `exp_sum` can go negative before
      biasing.
- [ ] **Drop the implicit leading 1 when packing:** the fraction field is `mant_z[22:0]`,
      not `mant_z[23:0]`.
- [ ] **Overflow → ∞:** `exp_z >= 255` packs `{sz, 8'hFF, 23'h0}`.
- [ ] **No SVA.** `assert property` / `sequence` / `property` are rejected by Icarus
      Verilog. Plain synthesizable procedural code only.

> **Structure tip.** You do **not** need a deep multi-stage pipeline. A hand-rolled
> multi-stage FSM is the most common source of bugs (stale regs, mistimed `out_valid`, `X`
> reads). The simplest correct design is the **2-state machine** shown above: latch on
> accept, compute the whole multiply in the busy cycle using blocking temporaries, pulse
> `out_valid`. It comfortably meets the latency window. Prefer it.

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
- When `busy == 0`, a high `valid` sampled on a rising edge **starts** an operation: `a`
  and `b` are latched into `a_r`/`b_r` and the FSM advances toward completion.
- While `busy == 1`, further `valid` pulses are **ignored**.
- On completion: `z` is updated, `out_valid` is asserted **for exactly one cycle**, and
  `busy` is cleared so the next operation can start.

### Latency
- Multi-cycle, single-issue. Any deterministic small cycle count is acceptable — the test
  waits up to 100 cycles for `out_valid`. The 2-state design gives a fixed 2-cycle latency.
  **Exact latency is not asserted; correctness of `z` is what matters.**

---

## The algorithm (standard, exact — this is what the module above implements)

Fields are extracted from the latched operands `a_r`, `b_r`.

### 1. Unpack
For each operand `x` in {a, b}:
- `sign_x = x[31]`, `exp_x = x[30:23]` (8-bit biased), `frac_x = x[22:0]` (23-bit)
- `mant_x = {1'b1, frac_x}` — **24-bit** significand with the implicit leading 1
  (always present for normals, where `exp_x` is `1..254`).

### 2. Sign
- `sign_z = sign_a ^ sign_b`

### 3. Exponent (biased domain)
- `exp_sum = exp_a + exp_b - 127`  (signed/wide reg; `127` is the binary32 bias).
  The final `+1` correction is applied during normalization, based on the product.

### 4. Significand product (24 × 24 → 48 bits)
- `product = mant_a * mant_b` (declare `product` at least **48 bits** wide).
  Each `mant` is in `[2^23, 2^24)`, so `product` is in `[2^46, 2^48)` — the MSB is exactly
  bit 47 or bit 46.

### 5. Normalize + extract guard/round/sticky (two cases on `product[47]`)
Pick the 24-bit result mantissa so its MSB (`mant_z[23]`) is the leading 1; read
guard/round/sticky from the bits just below it.

**Case A — `product[47] == 1`** (significand in `[2,4)`):
- `mant_z = product[47:24]`, `guard = product[23]`, `round = product[22]`,
  `sticky = |product[21:0]`, `exp_z = exp_sum + 1`.

**Case B — `product[47] == 0`** (here `product[46] == 1`):
- `mant_z = product[46:23]`, `guard = product[22]`, `round = product[21]`,
  `sticky = |product[20:0]`, `exp_z = exp_sum`.

### 6. Round to nearest even (RNE)
```
round_up = guard & (round | sticky | mant_z[0]);   // mant_z[0] = tie-to-even term
if (round_up) begin
    mant_z = mant_z + 1;
    if (mant_z == 24'h0) begin        // carried out of bit 23 (0xFFFFFF -> 0x000000)
        mant_z = 24'h800000;          // renormalize to 1.0...
        exp_z  = exp_z + 1;           // bump exponent
    end
end
```
The `mant_z[0]` term is what makes it round-to-nearest-**even**. Do not drop it.

### 7. Pack
- `exp_z >= 255` → overflow to infinity: `z = {sign_z, 8'hFF, 23'h0}`.
- `exp_z <= 0` → underflow toward zero (not graded; `{sign_z, 8'h0, 23'h0}` is a fine
  default).
- Else (normal): `z = {sign_z, exp_z[7:0], mant_z[22:0]}` — drop the implicit `mant_z[23]`.

Then assert `out_valid` for one cycle and clear `busy`.

> **Special inputs (optional, not graded by default).** If you handle them: NaN in → quiet
> NaN `0x7FC00000`; Inf × nonzero → signed Inf; Inf × 0 → NaN; any × 0 → signed zero. None
> of this is required to pass the default test.

---

## Worked numeric checks (use these to self-verify the bit math)

**`1.5 × 1.5 = 2.25`**
- `1.5 = 0x3FC00000`: `exp = 127`, `mant = 0xC00000`.
- `product = 0xC00000 * 0xC00000 = 0x900000000000` → `product[47] = 1` (**Case A**).
- `mant_z = 0x900000`; guard/round/sticky = 0; no round-up.
- `exp_z = (127 + 127 - 127) + 1 = 128`.
- `z = {0, 8'd128, 0x100000} = 0x40100000` = `2.25`. ✓

**`1.0 × 2.0 = 2.0`**
- `1.0 = 0x3F800000` (`exp 127`, `mant 0x800000`), `2.0 = 0x40000000` (`exp 128`, `mant 0x800000`).
- `product = 0x800000 * 0x800000 = 0x400000000000` → `product[47] = 0`, `product[46] = 1` (**Case B**).
- `mant_z = 0x800000`; guard/round/sticky = 0; no round-up.
- `exp_z = 127 + 128 - 127 = 128`.
- `z = {0, 8'd128, 0x000000} = 0x40000000` = `2.0`. ✓

---

## Implementation constraints
- Must be **synthesizable**.
- **Do not use SVA** (`property` / `sequence` / `assert property`) — Icarus Verilog rejects
  it.
- Keep the module name `fmultiplier` and the port list above unchanged.
- A single sequential `always @(posedge clk)` block with **synchronous** reset is
  sufficient; blocking temporaries inside the busy cycle are fine for the normalize/round
  math.
