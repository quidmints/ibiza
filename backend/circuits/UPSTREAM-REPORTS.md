# Upstream reports from regenerating every published passport profile

**Found:** 2026-08-10, regenerating all 78 `registerIdentity_*` profiles on a newer toolchain.
**Status:** ready to file, none filed — `gh` is not installed here and no upstream credentials are
configured.

⚠️ **THESE GO TO TWO DIFFERENT PROJECTS. Do not file them as one issue.**

| item | repo | summary |
|---|---|---|
| 1 | `rarimo/passport-zk-circuits-noir` | one profile cannot compile: AA key runs 8 bytes past `dg15` |
| 2 | `rarimo/passport-zk-circuits-noir` | **the same gap silently affects five profiles that DO ship** |
| 3 | `rarimo/passport-zk-circuits-noir` | optional: self-consistency checks for the generated tuples |
| 4 | **`AztecProtocol/barretenberg`** | **bb regression** — a circuit 5.1.0 builds, 6.0.0-nightly refuses by 0.4% |

Items 1–3 are independent of each other; (2) is the one with live consequences and stands alone.
Item 4 is a different project entirely and is the strongest of the four, because it has a clean
before/after in a single repository's history.

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

That invariance is the useful signal: the bound is **not** the FileBackedMemory budget it looks like.

### ⚠️ This is NOT the case fixed by #24249

`fix(bb): size Pippenger MSM arena for the non-GLV mid-band` (#24249, merged 2026-06-24, commit
`6deae818`) targets this exact assertion in `MsmArena::bump_alloc`. **That fix is already in our
build** — it is an ancestor of `next`, `next` is this repository's default branch, and our pin is
`6.0.0-nightly.20260804`, six weeks later. The assertion still fires.

#24249 addressed the non-GLV mid-band, 8,192–131,072 points, "around ~28,696 points". **This circuit
needs a 2^25 CRS**, far outside that band, and overshoots by 0.4% after the proving key has already
been computed. So it appears to be a second, larger-scale instance of the same arena-sizing class,
not a regression of the fix.

### Why it matters downstream

A verifier built under 5.1.0 does not accept proofs from a 6.0 prover (they fail at
`verification failed at reduction step`, with **zero VK constants differing** — so no key comparison
detects it). Consumers therefore cannot regenerate these two verifiers to match a 6.0 prover, and
cannot keep using the 5.1.0 ones either. The profiles become unusable rather than merely stale.

Happy to supply the exact circuit, generics tuple, and container recipe on request.

---

## rarimo/passport-zk-circuits — profile `14_256_1_4_1752_576_1_1496_3_512` cannot be satisfied by any input

**Severity:** the profile is unbuildable as published; no `DG15_LEN` exists that satisfies it.

Decoding the name against `RegisterIdentityBuilder`'s parameter list gives
`AA_SHIFT = 512 bits = 64 bytes` and `DG15_BLOCK_NUMBER = 3`, with `DG_HASH_TYPE = 256`.

Two requirements collide:

* The Active Authentication reader takes a **fixed 128 bytes** from `AA_SHIFT` (five chunks: four of
  25 bytes and a last of 28), so the top index touched is `AA_SHIFT + 127 = 191`, forcing
  `DG15_LEN >= 192`.
* `dg15` spans `DG15_BLOCK_NUMBER * 64 = 192` bytes, and SHA-256 padding needs 9 of them
  (`0x80` plus the 8-byte length), so `DG15_LEN <= 183`.

`192 > 183`, so the constraint system is unsatisfiable for every input — not merely for the documents
we have. More plainly: **no 1024-bit RSA AA key can start at byte 64 and still fit in three blocks.**
Either `DG15_BLOCK_NUMBER` should be 4, or `AA_SHIFT` should be 256 bits like every other RSA-AA
profile in the set (all 38 of the ones that work use `AA_SHIFT = 32` bytes).

Both bounds were validated against the corpus before being used to make this claim: the padding cap
holds 45/45 and the block cap 44/44 across every profile that does build. The identity
`DG15_LEN >= AA_SHIFT + 128` holds for 37 of 38 RSA-AA profiles, the sole exception being a tuple we
had derived ourselves and have since corrected.

Two sibling TD1 profiles are affected by the same family of issue but are *not* impossible — they are
merely under-determined from published material (`21_160_1_2_560_576_NA` needs `EC_LEN`,
which is a per-document DER length fitting no formula across all 83 profiles we build).
