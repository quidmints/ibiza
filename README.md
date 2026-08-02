# ibiza

A fork of **Privacy Pools** and **rarimo/rarime** unified onto one Foundry + Noir/Honk stack.

`TODO.md` is the canonical tracker. This file exists for one job the tracker cannot do: **say what
came from upstream and what we changed**, so nobody has to guess whether a file is ours.

---

## Provenance map

| path | origin |
|---|---|
| `backend/contracts/contracts/pool/**` | **Privacy Pools** (`0xbow-io/privacy-pools-core`) |
| `backend/contracts/contracts/{certificate,passport,registration,state,sdk,utils}/**` | **rarimo** (`rarimo/passport-contracts`) |
| `backend/contracts/contracts/libraries/**` | rarimo, plus our inline Poseidon variants |
| `backend/circuits/{pp,withdraw_identity,ragequit}` | Privacy Pools circuits, ported Circom → Noir |
| `backend/circuits/{register_identity*,query_identity*}` | **rarimo** (`rarimo/passport-zk-circuits-noir`) |
| `backend/circuits/noir_dl_lib` | **rarimo**, which itself vendors `noir-lang/noir-bignum` and `noir_bigcurve` |
| `frontend/identity-wallet` | **rarimo/rarime** wallet |
| `backend/circuits/{escrow_envelope,title_holder,notary_action,aggregate_withdrawals}` | **ours** |
| `backend/contracts/contracts/{title,holder,pool/spv}/**`, `registry/RegistrySourceAnchor.sol` | **ours** |
| `backend/cre/**`, `tools/**` | **ours** |

**The fork was imported as ONE squashed commit** (`0762975`), so there is no upstream history to
diff against in this repo. Everything since is divergence. Regenerate the current list with:

```sh
git diff --name-only 0762975..HEAD -- backend/contracts/contracts \
  | grep -vE 'verifiers2|Verifier\.sol'
```

As of 2026-08-02 that is **51 non-generated contracts**, plus 58 files in `noir_dl_lib`, 3 rarimo
circuit files, and 62 in the wallet. **We are a heavily modified fork, not a thin skin over
upstream.** Do not assume any upstream file is untouched.

---

## Changes to upstream code that will surprise you

Ordinary edits are visible in `git log`. These are the ones with consequences beyond their diff.

### `noir_dl_lib` (rarimo → and it vendors noir-bignum/noir_bigcurve)

Ported to nargo 1.0.0-beta.26. Full detail in `backend/circuits/NOIR-DL-PORT.md`.

- **`u1` → `Field` at the BOUNDARY, not throughout.** `to_le_bits`/`to_be_bits` now return
  `[bool; N]`; substituting `bool` library-wide was tried and reverted, because the library does
  arithmetic on those bits and it would have meant editing modular-arithmetic and hash expressions.
  A single `crate::utils::bits_to_field` conversion at each bit source keeps every algorithm body
  byte-identical.
- **`.eq()` disambiguated to `BigNumTrait::eq`** at 10 sites. `std::cmp::Eq` compares limbs where
  `BigNumTrait::eq` compares modular values; they differ for unreduced representations, so the
  other choice would have compiled and been silently wrong.
- **`std::wrapping_add` kept as a local wrapper** rather than rewriting nested calls in sha384/512.
- **22 `global … = BigNumParams::new(..)` became `pub fn`.** This is an ACCOMMODATION for a Noir
  compiler bug, not a design choice — **revert it when the fix ships upstream.** Zero measured gate
  cost (1 ACIR opcode, identical to an empty circuit; the constants still fold).
- **`sigver/curve_384.nr` DELETED** — a second, never-wired Brainpool P384R1 under a secp384r1
  name. Nothing lost: `sigver::ecdsa::verify_brainpoolp384r1_ecdsa` is live.
- **Dependency pins bumped:** `sort` v0.3.0→v0.4.0, `poseidon` v0.2.0→v0.3.0, `sha256` v0.2.0→v0.3.0.
  Every one was stale against beta.26; poseidon v0.2.0 does not build on it at all.

### `noir-lang/noir` itself

A 3-hunk ICE fix (`backend/circuits/noir-ice-repro/noir-fix.patch`) with a 14-line reproduction.
**Not vendored** — the built compiler is installed locally and its source tree is ephemeral.
See "Toolchain" below. Not yet submitted upstream: `noir-ice-repro/UPSTREAM-REPORT.md` is ready
to file and needs GitHub credentials this environment does not have.

### Privacy Pools Solidity

Additive rather than rewrites, but they change the contract's surface:

- **`PrivacyPool.withdrawBatch`** + `MAX_BATCH` + batch errors, with `lib/BatchVerifierLib.sol` and
  `lib/BatchCommitmentLib.sol`. Upstream has no batching.
- **`AGGREGATION_VERIFIER` is a constructor argument and immutable.** It was previously declared and
  read but NEVER ASSIGNED, so `withdrawBatch` was unreachable. Zero is still allowed (a pool that
  does not batch is legitimate, and upstream has no such verifier) but is refused explicitly with
  `AggregationNotConfigured` rather than calling into an empty address.
- **`PrivacyPoolSimple` / `PrivacyPoolComplex` constructors gained `_aggregationVerifier`.**
- `Entrypoint`, `State`, `ProofLib` and the pool interfaces all carry local changes.

### rarimo passport circuits

`register_identity/src/main.nr`, `register_identity_td1/{Nargo.toml,src/main.nr}`.

### `escrow_envelope`

poseidon pinned v0.2.0→v0.3.0 to match `pp` and to build on beta.26.

---

## Toolchain (read before running anything that generates artifacts)

**`nargo` is a LOCALLY PATCHED beta.26** reporting `1.0.0-beta.26+quid-icefix1`. The suffix is
load-bearing: an unmarked patched build is indistinguishable from the release and would slip past
`codegen-verifiers.sh`'s guard, making the pin meaningless. **CI and other developers will fail that
guard, correctly** — they have stock beta.26. **The circuits still build on stock beta.26**; the
accommodation above was kept precisely so they do.

- stock binary: `~/.nargo/bin/nargo.beta26-release.bak`, or `noirup --version 1.0.0-beta.26`
- rebuild recipe: in the header of `backend/circuits/codegen-verifiers.sh`
- **`bb` 5.1.0 must be on PATH**: `export PATH="$HOME/.bb:$PATH"`, else codegen reports it missing

**Artifact generation is a 5-step pipeline** and `codegen-verifiers.sh` is only step 4; step 5 is
`tools/prove-escrow-fixtures.sh`. Skipping it produces `SumcheckFailed()` far from the cause.
**Regenerate only what changed** — re-proving unchanged circuits is churn, and one target
(`title_holder`) currently fails when re-proved (TODO.md, task 30).

**Not covered by `codegen-verifiers.sh`:** `aggregate_withdrawals` (deliberately) and the 83
`NoirRegisterIdentity_*.sol` passport verifiers. Changing those circuits refreshes nothing.
