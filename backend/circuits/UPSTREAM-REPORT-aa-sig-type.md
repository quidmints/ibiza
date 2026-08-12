# Upstream report: `extract_dg15_pk_hash` has no branch for `AA_SIG_TYPE` 20, 21, 24, 25

**For:** `rarimo/passport-zk-circuits-noir`
**Found:** 2026-08-10, while regenerating every published `registerIdentity_*` profile on a newer nargo.
**Status:** ready to file. Not filed — `gh` is not installed here and no upstream credentials are
configured. Two independent items; (2) stands alone and is worth sending even if (1) is declined.

---

## 1. One profile cannot compile: the AA key runs past `dg15`

`registerIdentity_20_256_3_5_336_248_25_2120_5_1816` (published in `v0.2.4`) does not compile on
nargo `1.0.0-beta.26`:

```
bug: Assertion is always false: Index out of bounds
    not_passports_zk_circuits.nr:672  in extract_dg15_pk_hash
...
circuit is unsatisfiable. An AssertZero opcode contains no variables but has a non-zero constant
```

It **does** compile on `1.0.0-beta.1`, which is what the published artifact was built with — the
newer compiler is not regressing, it is diagnosing something that was always there.

### The arithmetic

`extract_dg15_pk_hash` selects the AA key size from `AA_SIG_TYPE`:

```noir
let mut HASH_SIZE = 31;
let mut EC_FIELD_SIZE = 32;
if (AA_SIG_TYPE == 22) { EC_FIELD_SIZE = 40; }
if (AA_SIG_TYPE == 23) { EC_FIELD_SIZE = 24; HASH_SIZE = 24; }

let X_Y_SHIFT = EC_FIELD_SIZE - HASH_SIZE;
for j in 0..HASH_SIZE {
    x += (dg15[AA_SHIFT + (HASH_SIZE - 1 - j) + X_Y_SHIFT]) as Field * current;
    y += (dg15[AA_SHIFT + (HASH_SIZE - 1 - j) + X_Y_SHIFT + EC_FIELD_SIZE]) as Field * current;
    current *= 256;
}
```

This profile declares `AA_SIG_TYPE = 25`, which matches no branch, so it takes the 32-byte default.
With its published generics — `DG15_LEN = 283`, `AA_SHIFT = 227` — the highest `y` index is

```
AA_SHIFT + (HASH_SIZE-1) + X_Y_SHIFT + EC_FIELD_SIZE
  = 227 + 30 + 1 + 32
  = 290        against dg15: [u8; 283]      → 8 past the end
```

The generics are not in question: they are read verbatim from the artifact's own embedded `main.nr`
(`register_identity::<93, 283, 297, 74, 6, 256, 32, 32, 20, 31, 265, 42, 25, 227>`) and agree with its
ABI.

### What we did **not** do

We did not add a local `AA_SIG_TYPE == 25` branch. Solving `AA_SHIFT - 1 + 2*EC_FIELD_SIZE = DG15_LEN - 1`
gives `EC_FIELD_SIZE = 28`, which fits exactly — and every other ECDSA-AA profile does land exactly on
`DG15_LEN - 1`, so 28 is plausible. **But a local patch would make our verifier check a different
statement than your prover produces**, silently. It belongs here, from whoever knows what curve
`AA_SIG_TYPE 25` denotes.

---

## 2. ⚠ The same gap affects five profiles that **do** compile and ship

`AA_SIG_TYPE` 20, 21 and 24 also match no branch and take the same 32-byte default. Unlike 25, their
`dg15` is large enough that the reads stay in bounds — so they compile, emit verifiers, and ship:

| profile | `AA_SIG_TYPE` |
|---|---|
| `registerIdentity_1_256_3_7_336_264_20_2760_6_2008` | 20 |
| `registerIdentity_25_384_3_5_576_248_20_3768_3_2008` | 20 |
| `registerIdentity_21_256_3_7_336_264_21_3072_6_2008` | 21 |
| `registerIdentity_2_256_3_6_336_264_21_2448_6_2008` | 21 |
| `registerIdentity_28_384_3_3_576_264_24_2024_4_2792` | 24 |

**If 32 bytes is not the correct key size for those curves, these verifiers read the wrong bytes of
`dg15` as the Active Authentication public key — with no error, at any stage.** The out-of-bounds on
`AA_SIG_TYPE 25` is the lucky case: it is the only one whose mistake was large enough to escape the
array and be caught by a compiler.

We cannot tell from outside whether 32 is right for 20, 21 and 24 — that needs the curve each value
denotes. If 32 is correct for all three, item 2 is a no-op and only 25 needs a branch. If it is not,
five shipped profiles are affected.

**Suggested minimum:** make the fall-through explicit rather than silent, e.g.

```noir
assert(AA_SIG_TYPE == 20 | AA_SIG_TYPE == 21 | AA_SIG_TYPE == 22
     | AA_SIG_TYPE == 23 | AA_SIG_TYPE == 24, "unhandled AA_SIG_TYPE");
```

so a new value fails loudly at compile time instead of inheriting a default.

---

## 3. Optional: a self-consistency check for the generated tuples

Three `v0.1.0` profiles are also uncompilable, from a different defect —
`registerIdentity_21_160_1_2_560_576_NA`, `registerIdentity_14_256_1_4_1752_576_1_1496_3_512`,
`registerIdentity_1_256_1_5_2376_336_1_2120_4_512` each declare `DG1_LEN = 0` (a circuit that reads no
MRZ) **and** `DG1_SHIFT == EC_LEN`, so `assert(dg1_hash[i] == ec[i + DG1_SHIFT])` reads past `ec`.
No profile outside these three has `DG1_SHIFT == EC_LEN`; working values lie in 23..33.

Every one of these defects is arithmetic on numbers already in the emitted tuple, checkable in
milliseconds without a document, a build, or a proving run:

- `DG1_LEN != 0`
- `DG1_SHIFT + DG_HASH_ALGO <= EC_LEN`
- `DG15_SHIFT + DG_HASH_ALGO <= EC_LEN` when `DG15_LEN > 0`
- `EC_SHIFT + HASH_ALGO <= SA_LEN`
- `AA_SHIFT + (HASH_SIZE-1) + X_Y_SHIFT + EC_FIELD_SIZE <= DG15_LEN - 1` when `AA_SIG_TYPE >= 20`

Our implementation is `tools/check-passport-profile-consistency.py`; it clears all 78 profiles we
build and refuses exactly the four above. Happy to port it to whatever form suits your generator.

---

# 4. ⚠ REGRESSION: a circuit bb 5.1.0 builds, bb 6.0.0-nightly.20260804 refuses by 0.4%

Separate from items 1–3, and the strongest of the four because there is a clean before/after.

**Same circuit, same nargo, same generics. Only bb changed.**

| bb | result |
|---|---|
| **5.1.0** | builds `registerIdentity_25_384_3_5_576_248_20_3768_3_2008` and `..._28_384_3_3_576_264_24_2024_4_2792` successfully |
| **6.0.0-nightly.20260804** | `write_vk` aborts |

Both verifiers are committed artifacts produced under `REQUIRED_BB="5.1.0"`; nargo was
`1.0.0-beta.26` in both cases and did not change.

### The failure

```
CircuitProve: Proving key computed in 2158032 ms (mem: 12494.55 MiB)
libc++abi: terminating due to uncaught exception of type std::runtime_error:
  Assertion failed: (aligned_local + bytes <= bound)
  Left   : 124990672
  Right  : 124518529
```

Note the proving key **succeeds**. The abort is in `write_vk` afterwards, and the overflow is
**472,143 bytes — 0.4%** of a ~124.5 MB bound.

### What we ruled out, by measurement

| | |
|---|---|
| host memory | not the cause — 32 GiB swapfile available, bb peaked at 12.4 GB, well under |
| thread count | `HARDWARE_CONCURRENCY` honoured, peak unchanged |
| `--slow_low_memory` | **helps and is worth noting**: with it the proving key computes, where without it bb aborts *before* reaching that point. Does not clear this second bound. |
| `--storage_budget` | **no effect at all.** `8g` and `512m` produce a **byte-identical** bound — `Left 124990672 / Right 124518529` both times. A 16× change moves it by zero. |

That invariance is the useful signal: the bound does not appear to be the FileBackedMemory budget it
looks like, and a 0.4% overshoot after a successful proving-key computation reads as arena **sizing**
rather than a genuine capacity limit.

### Why it matters downstream

A verifier built under 5.1.0 does not accept proofs from a 6.0 prover (they fail at
`verification failed at reduction step`, with **zero VK constants differing** — so no key comparison
detects it). Consumers therefore cannot regenerate these two verifiers to match a 6.0 prover, and
cannot keep using the 5.1.0 ones either. The profiles become unusable rather than merely stale.

Happy to supply the exact circuit, generics tuple, and container recipe on request.
