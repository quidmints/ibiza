# Porting `noir_dl_lib` to nargo 1.0.0-beta.26 — IN PROGRESS, NOT DONE

**State: six crates still do not compile.** `register_identity`, `register_identity_td1`,
`register_identity_light_td1`, `query_identity`, `query_identity_td1` and `escrow_envelope` all
depend on `noir_dl`, and all fail. **Do not read this file as a completion record.**

## What changed, and why it matters

The blocker was an ICE — `ice: all function ids should have metadata` — which reports NOTHING about
its cause and made the problem look intractable. **It is gone.** The library now produces ordinary,
enumerable compiler errors, which is the difference between a mystery and a work list.

**Reproduce the ICE in 3 seconds** (kept, because it will be needed again): a crate whose only
dependency is `noir_dl`, whose `main.nr` is `fn main(x: Field) -> pub Field { x + 1 }`, and which
uses nothing from the library, ICEs. Mere inclusion is enough. That is what made bisection cheap;
an earlier attempt failed only because it was run in `nargo test` mode.

**Root cause of the ICE:** beta.26's comptime interpreter crashes evaluating
`BigNumParams::new(...)` at GLOBAL scope. `new` calls `U60Repr::from` and `get_double_modulus`, so a
global forces that arithmetic through comptime. The identical call inside a function compiles.
Fixed by converting 22 such globals to `pub fn NAME() -> BigNumParams<..>` and rewriting their uses.
**This is semantics-preserving** — same function, same literal arguments — but it moves the work out
of comptime, so **gate counts must be measured** once the library builds. If Noir does not fold the
constants, circuits get bigger. Nobody has measured this yet.

**Also fixed** (4 sites, all old-dialect):
- `let mut temporaries: [[Field; N]] = &[];` → `= [];` (`&[]` is now a 0-length array reference)
- `comptime global BARRETT_REDUCTION_OVERFLOW_BITS` → plain `global` (it is read from runtime code)
- `std::wrapping_mul(v, k)` → `v.wrapping_mul(k)` plus `use std::ops::WrappingMul;`

**Dependencies bumped** — every pin was stale against beta.26: `sort` v0.3.0→v0.4.0,
`poseidon` v0.2.0→v0.3.0, `sha256` v0.2.0→v0.3.0. The comment on the poseidon pin claimed it was
"pinned to the same version pp uses" while sitting on v0.2.0 with pp on v0.3.0 — **the comment was
false**, and v0.2.0 does not build on beta.26 at all.

## What remains — 80 errors, all mechanical, none yet done

| count | error | fix |
|---|---|---|
| 32 | `` `u1` has been removed, use `bool` instead `` | `[u1; N]` → `[bool; N]`. **Careful:** these are ECDSA scalar bits; anywhere they feed arithmetic rather than selection, `bool` is not a drop-in — this is why the 4 `Cannot assign an expression of type bool to a value of type Field` errors appear. |
| 16+2 | `wrapping_add` not found / unresolved | free fn → method + `use std::ops::WrappingAdd;` |
| 10 | `Multiple applicable items in scope` (`U2.eq(U1)`) | `BigNumTrait` and `std::cmp::Eq` both provide `eq`; disambiguate explicitly. |
| 8 | `Expected type u32, found type u64` | integer-width tightening |
| 5 | `Bitwise operations are invalid on Field types` | cast to a sized integer first |
| 3 | `The numeric generic is not of type u8` | generic kind annotation |

## Do not skip

**Upstream is not an escape.** `noir-bignum` v0.9.2 (latest) pulls `poseidon` v0.2.6, which beta.26
also rejects — checked. The bignum ecosystem trails beta.26, so this port has to be done here.

**Nothing is verified beyond compilation.** `nargo test` for this library has never run on beta.26,
so once it builds, the pinned vectors must be run before any of it is trusted for real value — the
`u1`→`bool` change in particular can alter results silently rather than failing to compile.
