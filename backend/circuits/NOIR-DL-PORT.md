# Porting `noir_dl_lib` to nargo 1.0.0-beta.26 — COMPILES; VECTORS NOT YET CONFIRMED

**All 13 circuit crates compile on beta.26 with zero errors and no ICE**, including the six that
previously failed: register_identity, register_identity_td1, register_identity_light_td1,
query_identity, query_identity_td1, escrow_envelope.

**COMPILING IS NOT CORRECTNESS.** Hash and curve code was edited. `nargo test` on this library takes
over ten minutes and its result is NOT yet recorded here — until the pinned vectors pass, none of
this is trusted for real value.

## WHY THERE ARE ORPHANS AT ALL — there is no coincidence, and it is not our design

**`noir_dl_lib/src/bignum/` is a VENDORED COPY of `noir-lang/noir-bignum`** (identical layout:
`bignum.nr`, `fields/`, `fns/`, `params.nr`, `runtime_bignum.nr`, `utils/`). Upstream ships every
field ITS users might want — `U256`..`U8192`, ed25519, pallas, vesta, mnt4/6_753, bls12_377/381 —
and we vendored the library whole while using only the passport subset. **The nine zero-reference
`fields/*` modules are upstream generality, not orphans of our making.** `big_curve/` is the same
story (`noir_bigcurve`).

**That makes pruning a real decision, not a cleanup.** Deleting unused fields diverges us further
from upstream and makes any future sync harder. Against that: rarimo's own
`passport-zk-circuits-noir` has not been touched since 2025-11-18 and never made this beta.26 port,
so the sync path is ALREADY broken. **Decide deliberately; do not let it happen by accident.**

**`curve_384.nr` was a DIFFERENT case and deleting it left nothing missing.** It was a SECOND,
never-wired implementation of Brainpool P384R1 under a secp384r1 name. The capability is live and
unaffected: `sigver::ecdsa::verify_brainpoolp384r1_ecdsa` is used at
`not_passports_zk_circuits.nr:549`, and `verify_secp384r1_ecdsa` exists beside it. So the duplicate
went, the function stayed — which is exactly why sec. 2.5b called it a trap rather than a component.

## ASSUMPTION AUDIT — what a re-check of this work overturned

**I PORTED DEAD CODE.** `sigver/curve_384.nr` had ZERO references (only its own `mod` line), and
TODO.md sec. 2.5b already said **"Delete or rename `curve_384.nr`"** because it is Brainpool P384R1
wearing a secp384r1 name — a documented trap. I ported it instead of reading that. **Now deleted.**
`curve_192` and `curve_224` ARE live (`not_passports_zk_circuits.nr`) and were correctly kept.

**MORE DEAD CODE IS LIKELY AND WAS NOT ACTED ON:** nine `bignum/fields/*` modules have zero
references — `U256`, `U384`, `U512`, `U768`, `U1024`, `U2048`, `U4096`, `U8192`, `ed25519Fr`. Left
in place deliberately: they are vendored generic size-variants, and deleting them is a judgement
call, not a mechanical one.

**I CALLED THE RARIMO SIDE MISALIGNED BEFORE CHECKING RARIMO.** Checked afterwards:
`rarimo/passport-zk-circuits-noir` was last touched 2025-11-18 and has NOT done this port, so there
is no upstream sync to pull and the work stands — but that check belonged first, not last.

**"UNREPORTED UPSTREAM" RESTS ON TWO API SEARCHES.** That is weak evidence of absence. Treat it as
"no issue found", not "no issue exists".

**THE 6-BROKEN-CRATES / 6-ORPHAN-PROFILES COINCIDENCE IS JUST A COINCIDENCE.** Task 10's orphans are
Circom profiles lacking a Noir twin (sec. 2.18aj); unrelated to the six crates fixed here.

## ⚠️ THE PORT IS NOT FINISHED: VERIFICATION KEYS

`backend/contracts/contracts/passport/verifiers2/noir/NoirRegisterIdentity_*.sol` were generated
from these circuits on the OLD toolchain. **Moving the circuits to beta.26 changes their constraint
systems, so those committed verifiers are stale and on-chain proofs against them will fail.** This
is inherent to the toolchain move rather than caused by the source edits — the crates did not build
on beta.26 at all before — but it means compiling and passing tests is NOT the finish line.

**`bb` WAS INSTALLED ALL ALONG** — at `~/.bb/bb`, not on PATH, and at **v0.82.2**, far below the
required 5.1.0. "Not installed" was wrong; "wrong version, invisible to the script" was the truth.
**Now fixed: bbup installed and `bb` upgraded to 5.1.0**, so nargo beta.26 + bb 5.1.0 finally match
what `codegen-verifiers.sh` enforces. **Put `~/.bb` on PATH** or the script still reports it missing.

**SO THE VERIFIERS CAN NOW BE REGENERATED HERE — that work is next, and it is not optional.**

## ✅ THE COMPILER BUG IS FIXED — patch in `noir-ice-repro/noir-fix.patch`

**Root cause:** comptime evaluation of a `global` reaches a trait method through an operator overload
BEFORE that method has been elaborated, so its `FuncMeta` does not exist yet — and three call sites
demanded it with `expect`, producing `ice: all function ids should have metadata`.

**Fix (3 hunks, 2 files, all `function_meta` -> `try_function_meta`):**
- `monomorphization/mod.rs::bind_trait_impl_func_generics_to_trait_func_generics` (x2) — return
  early; the function only ADDS bindings, so skipping degrades to "no extra bindings".
- `node_interner/mod.rs::get_trait_item_id` — yield `None`. It already returns `Option` and every
  caller handles `None`, so this is its existing contract rather than a new one.

**Safe by construction:** identical behaviour whenever the metadata exists; where it does not, the
previous behaviour was a CRASH, so there is nothing to regress.

**Verified:** the 14-line repro compiles; the original `global ... = <operator overload>` form
compiles; all 13 real crates compile on the patched compiler.

**REGRESSION-TESTED AGAINST NOIR'S OWN SUITE: `noirc_frontend` 2223 passed, 0 failed, cargo exit 0.**
A first run aborted at `tests::deeply_nested::deeply_nested_terms` with a stack overflow — that is
ENVIRONMENTAL, not the patch: the same tests pass under `RUST_MIN_STACK=134217728` (macOS default
thread stack is too small for that test in a release build), and the full green run above used it.
**Note the trap:** the background-task notification reported "exit code 0" for that aborted run,
because that is the exit of the wrapper shell, NOT of cargo — cargo had exited 101. Always read the
recorded `CARGO_EXIT=` line, never the harness summary.

**NOT APPLIED TO THE PINNED TOOLCHAIN.** This repo must build with RELEASED beta.26, so the
accommodation in `noir_dl_lib` stays until the fix ships upstream. Revert it then — that is the
whole point of having recorded it as an accommodation. Task 26 is now "submit upstream".

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
