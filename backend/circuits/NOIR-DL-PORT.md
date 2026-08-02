# Porting `noir_dl_lib` to nargo 1.0.0-beta.26 — COMPILES; VECTORS NOT YET CONFIRMED

**All 13 circuit crates compile on beta.26 with zero errors and no ICE**, including the six that
previously failed: register_identity, register_identity_td1, register_identity_light_td1,
query_identity, query_identity_td1, escrow_envelope.

**COMPILING IS NOT CORRECTNESS.** Hash and curve code was edited. `nargo test` on this library takes
over ten minutes and its result is NOT yet recorded here — until the pinned vectors pass, none of
this is trusted for real value.

## THE BUG ITSELF — isolated, and it is upstream's

**`noir-ice-repro/` is a 14-line, dependency-free reproduction.** `nargo compile` on it still ICEs.

**Trigger: a GENERIC OPERATOR-OVERLOAD impl invoked during comptime evaluation of a `global`.**
Narrowed by elimination — the identical call from `main` compiles; an ordinary trait (`From`) in a
global compiles; removing the const generic compiles. Only operator-overload + generic + global ICEs.

**This is a compiler defect, not our misuse**, and that matters: it means no amount of rewriting our
crypto source is "the fix". beta.26 is the NEWEST release and still has it, and a search of
noir-lang/noir found **no matching issue** — so it is unreported. The nearest prior art is PR #12580
("delayed elaboration of complex globals"), which is the same area of the compiler.

**What our source change actually is.** Moving `BigNumParams::new` out of global scope is an
ACCOMMODATION, not a repair, and it should be reverted when upstream fixes this. Two things make it
acceptable to carry meanwhile, both measured rather than assumed:
- **It costs zero gates.** A circuit reading the params is **1 ACIR opcode — identical to an empty
  control circuit**. The constants still fold; nothing got bigger. There was never a
  safety-for-size trade here, because these are PUBLIC constants a prover cannot lie about either
  way — comptime folding was simply the right design and remains in effect.
- It is the same function with the same literal arguments.

**Solving it properly means patching `noirc` and running a custom toolchain**, which trades an
unreported upstream bug for a locally-built compiler that `codegen-verifiers.sh` does not pin. That
is a toolchain decision, not a code decision — hence it is written down here rather than taken
unilaterally.

## Why the ICE is definitely gone from our build

The blocker was `ice: all function ids should have metadata`, which reports nothing about its cause.
**Two ways the "it's gone" claim could have been false were both checked and both ruled out:**
1. *Probe artifact* — the reproduction crate uses nothing from the library, so it might have skipped
   code. Ruled out: the REAL crates showed the identical error profile, and now compile.
2. *Hidden behind an early abort* — 80 errors could have masked a later crash. Ruled out the only
   way it can be: **all 80 were fixed, and no ICE appeared.**

**Root cause:** beta.26's comptime interpreter crashes evaluating `BigNumParams::new(...)` at GLOBAL
scope (`new` calls `U60Repr::from` and `get_double_modulus`, so a global forces that arithmetic
through comptime). 22 such globals became `pub fn NAME() -> BigNumParams<..>`. Same function, same
literal arguments — but the work moved out of comptime, so **gate counts must be measured**; if the
constants no longer fold, circuits get bigger. Nobody has measured this.

**Keep the 3-second reproduction** — a crate whose only dependency is `noir_dl`, with
`fn main(x: Field) -> pub Field { x + 1 }`, using nothing from the library. Mere inclusion was enough
to ICE. That is what made bisection cheap; an earlier attempt failed only because it ran in
`nargo test` mode.

## The choice that matters most: `u1` at the BOUNDARY, not throughout

`u1` is gone in beta.26 and `to_le_bits`/`to_be_bits` now return `[bool; N]`. The obvious fix —
`u1` → `bool` library-wide — was tried and **reverted**: it turned 80 errors into 59 new ones,
because this library does ARITHMETIC on those bits throughout, and it would have meant editing
modular-arithmetic and hash expressions, where a rewritten line is a silently different result.

Instead `u1` → `Field` (which is what the arithmetic already assumed) with a single conversion at
each bit source, `crate::utils::bits_to_field`. **Every algorithm body is byte-identical.** That took
80 errors to 21 in one step.

Other changes, all chosen to keep call sites unchanged:
- `std::wrapping_add` is now a trait method — kept as a local `fn wrapping_add(a: u64, b: u64)`
  wrapper in sha384/sha512 rather than rewriting each nested call.
- `.eq()` became ambiguous (`BigNumTrait` vs `std::cmp::Eq`) at 10 sites on BigNum values.
  **`BigNumTrait::eq` is the behaviour-preserving choice** — it compares modular values where `Eq`
  compares limbs, and the two differ for unreduced representations. Picking the other one would
  have compiled and been wrong.
- 4 dialect fixes in `bignum` (empty slice literal, a `comptime global` read at runtime,
  `std::wrapping_mul` → method), `rotate_left`'s `u8` generic → `u32`, and `sha256_var`'s length
  argument → `u32` (test vectors only).

**Every dependency pin was stale against beta.26** and all were bumped: `sort` v0.3.0→v0.4.0,
`poseidon` v0.2.0→v0.3.0 (in BOTH noir_dl_lib and escrow_envelope), `sha256` v0.2.0→v0.3.0. The
comment on the library's poseidon pin claimed it matched pp while sitting on v0.2.0 with pp on
v0.3.0 — **the comment was false**, and v0.2.0 does not build on beta.26 at all.

**Upstream is not an escape** — checked: `noir-bignum` v0.9.2 (latest) pulls `poseidon` v0.2.6, which
beta.26 also rejects. The bignum ecosystem trails the toolchain, so this port had to happen here.
