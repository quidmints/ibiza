# TODO — canonical tracker

Ordered by **implementation sequence**, not discovery order. Superseded material and the history of
how conclusions were reached have been removed; what remains is either actionable, a decision
someone has to make, or a fact that will cost you time if you don't know it.

Update in place. If you kill an item, say why in one line — the reason is what stops it being
re-proposed.

---

## 1. Build & toolchain

**Exactly one toolchain combination works. This is enforced, not advisory.**

| | version |
|---|---|
| nargo | `1.0.0-beta.13` (`noirup --version 1.0.0-beta.13`) |
| bb | `1.2.0` (`barretenberg-<arch>-darwin\|linux.tar.gz` from the `v1.2.0` release) |

`backend/circuits/codegen-verifiers.sh` refuses to run on anything else, and **validates its own
output** before writing artifacts (native `bb verify` + a two-run determinism check). Do not weaken
either guard — §7 explains what they catch.

```bash
cd backend/contracts && forge build && forge test              # 157/157 ✅
cd backend/circuits/pp && nargo test                           # 53/53 ✅
cd backend/circuits/noir_dl_lib && nargo test                  # 49/49 ✅
./backend/circuits/codegen-verifiers.sh                        # regenerates both Honk verifiers
python3 tools/check-client-abis.py                             # TS ABI ↔ Solidity cross-check
cd frontend/identity-wallet && npx tsc --noEmit --strict       # ✅
cd backend/cre/notary_registry && GOOS=wasip1 GOARCH=wasm go build ./...   # ✅
```

**ONE toolchain for everything — no split (landed 2026-07-27).** Every circuit (`pp`,
`withdraw_identity`, `title_holder`, `query_identity`, `query_identity_td1`,
`register_identity_light_td1`, `register_identity`) compiles on this pair, AND verifier generation
runs on it. 157/157 Forge, 53/53 pp, 49/49 lib.

**`bb 1.x` REQUIRES `-k <vk>` on `prove`; 0.82.2 did not.** Omitting it does not error — bb exits 0
and writes a proof against a different key that its own verifier rejects with `SumcheckFailed()`.
This single flag masqueraded as a bb-version incompatibility for a long time. It is now passed
explicitly in `codegen-verifiers.sh`, and the self-checks would catch a regression anyway.

**On bb 1.x, ZK is the DEFAULT** (opt out with `--disable_zk`). On 0.82.2 it was opt-in via `--zk`,
and omitting it silently produced witness-leaking proofs — upstream inverted the flag because the
old default was a footgun.

**⚠ EIP-170 headroom is now only ~85 bytes** (verifiers are 24,491 / 24,492 against the 24,576
limit, already with `optimizer_runs = 1` scoped to those two files). bb 1.2.0's verifier is larger
than 0.82.2's. **Check `forge build --sizes` after every regeneration** — a circuit change could
push these over, and the failure would only appear at deploy time.

**Why not newer?** nargo beta.22 compiles the PP circuits (53/53 pp tests pass there) but hits an
upstream ICE — `ice: all function ids should have metadata` — on `query_identity` and
`register_identity`, with zero regular errors. Bisected to `sigver`, but no individual submodule
removal clears it and the ICE masks whatever is behind it. bb 5.x needs msgpack ACIR from a nargo
newer than beta.25. **beta.13 + bb 1.2.0 is the newest pair where everything works.**

### 1b. Wallet launch readiness — BLOCKED ON HARDWARE, and it is an ARCHITECTURE block (2026-07-27)

**The wallet cannot be run on this machine, and no simulator will validate the enclave design.**
Two independent blockers; buying a phone clears the second, not the first.

**Blocker 1 — the native proving binaries are arm64-only.** This is not "install the SDKs":

| binary | slices present | consequence |
|---|---|---|
| `@rarimo/rarime-rn-sdk/android/libs/noir.aar` | `jni/arm64-v8a` **only** | no `x86_64` ⇒ **proving cannot run on an x86 Android emulator at all** |
| `ios/Frameworks/SwoirenbergLib.xcframework` | `ios-arm64`, `ios-arm64-simulator`, `macos-arm64` | simulator slice is **arm64** ⇒ needs an Apple Silicon host |

This dev machine is an **Intel Mac (x86_64, macOS 15.7.4)**, whose iOS Simulator is x86_64. There is
no slice for it. **A wallet build requires an Apple Silicon Mac** (or an arm64 Android emulator,
which is itself Apple-Silicon-hosted). Toolchains are also absent: `/usr/bin/xcodebuild` is the
CommandLineTools stub (`xcrun simctl` unavailable, so there is no iOS Simulator at all), no `adb`,
no `emulator`, and Java is 1.8 where modern AGP needs 17+.

**Blocker 2 — a simulator exercises the code path but NOT the security property.** `identity/root.ts`
is deliberately fail-closed: `InsecureDeviceError` when `SecureStore.canUseBiometricAuthentication()`
returns false — *"refusing to store the root seed"* — alongside `requireAuthentication: true` and
`keychainAccessible: WHEN_UNLOCKED_THIS_DEVICE_ONLY`. Its own comment: proceeding *"would store
identity + all PP notes without the hardware backing this design requires."*

The iOS Simulator **can** enrol Face ID (Features → Face ID → Enrolled), so the gate passes — but
**the Secure Enclave is emulated in software**. Android emulators are the same: the keystore works,
but software-backed, and StrongBox is unavailable. So a simulator can confirm that identity + PP
notes derive from one seed and that the biometric session-cache UX behaves — it can **never** confirm
anything is hardware-protected.

**⇒ The "notes + identity in one enclave" design is verifiable ONLY on physical hardware.** The
target device (Samsung A16, Knox, arm64) matches the AAR's only slice, so it will work — untested.

**What this blocks: device-only work.** NFC scanning (§2.6), on-device proving time, the Knox-backed
enclave path, real biometric prompts. **What it does NOT block:** everything in §1c.

**Not available on this machine:** JDK/Android SDK/NDK, Xcode. No device build has ever been
attempted, so anything Android-specific is unverified.

### 1c. What to do while hardware-blocked

**The critical path is NOT device-blocked. §2.1 is still the right next task** — witness assembly is
pure TypeScript over primitives that already exist, and it is validated by a **Forge test against a
real proof**, not by running the wallet. Same for §2.5 (circuit work) and the §3 items below. Device
hardware gates *validation of the mobile client*, not construction of the protocol.

Ranked by value while waiting on the phone:

1. **§2.1 witness assembly** — the actual blocker on anyone withdrawing at all. Fully unblocked.
2. **§2.4c share-denominated notes** — the design work for "depositors keep their own yield" is
   contract + circuit shaped, no device involved.
3. **§2.5 predicate-bound revocation** — circuit work.
4. **§3 items that are pure TS/Solidity** — denomination splitting, ERC-5564 stealth withdrawals,
   the stables leg of `SpvTreasuryAdapter`, the orphaned `bitcoin.nr`, `App.tsx` zero addresses.
5. **Prepare the device work so the phone is not itself a blocker later** — write the NFC (§2.6)
   integration against `@rarimo/rarime-rn-sdk`'s documented surface, and stage a CI job for the
   never-run ECDSA/recursion Noir suites (§3).

**Do NOT** start §2.4 (aggregator — explicitly deferred) or §2.7 (iran repo — last).

**`bb` needs AVX2/BMI2.** It SIGILLs on CPUs without them (an i3-U330 was the original blocker; an
i9-9880H is fine). Check before assuming a machine can't run it. `bb.js` (WASM) is the fallback.

---

## 2. Critical path — in this order

### 2.1 Wallet-side withdrawal witness assembly — ✅ DONE 2026-07-27

**Was the blocker on anyone withdrawing at all.** Everything downstream (gas work, aggregation)
optimises a path that now works end-to-end in everything except on-device proving (§1b).

**NEXT: §2.5 (revocation, circuit work) or §3 items — NOT §2.4.** The aggregator remains explicitly
deferred by the user, and §2.6/§2.7 need hardware.

Exists: `pp/discovery.ts` (finds your notes), `pp/notes.ts` (secret derivations), `pp/relay.ts`
(withdrawal + `context`), `postman/identityAsp.ts` (`IdentityAspTree.proof()` for ASP siblings,
`loadIdentityAspTree` to rebuild from chain).

**STATUS 2026-07-27: both pieces are BUILT and VALIDATED AGAINST THE REAL CIRCUIT.**

1. ✅ **State-tree mirror** — `src/pp/stateTree.ts`. `StateTree` + `loadStateTree()`.
2. ✅ **The assembler** — `src/pp/withdrawWitness.ts`. `buildWithdrawalWitness()` →
   **19 inputs** (8 public + 11 private; the old "20-field" count was wrong) + `pubSignals` in
   ProofLib order. `nextWithdrawalIndex()` derives the change-note index rather than trusting a
   caller-supplied integer, which is the one input that can silently make the remainder unspendable.

**Validated by running the actual circuit, not by typechecking.** A witness assembled by these
modules was fed to `nargo execute` on `withdraw_identity`: *"Circuit witness successfully solved."*
Two negative controls confirm the test is not vacuous — tampering `state_siblings[0]` fails at
`main.nr:68` (the `computed_state_root == state_root` assert) and tampering `sk_identity` fails at
`identity_asp.nr:61` (ASP membership), with the untampered witness re-solving afterwards.

Three findings the build produced, each recorded where it bites:

- **`State.sol:152` emitted `size` into a field named `_index`** — i.e. `index + 1` — while
  `Entrypoint._admitIdentity` emits the true `size - 1`. Fixed to `size - 1`. It had **zero
  consumers** at the time, so this was free; the state mirror would have been the first. Left
  unfixed it is an off-by-one that yields a proof rejected on-chain with nothing pointing back.
- **`State._insert` does NOT reject duplicate leaves** (unlike `Entrypoint`, which enforces
  `aspAdmitted`). So `LeanIMT.indexOf` — first match wins — is unsafe here. `StateTree` takes proofs
  **by index** and `leafIndexOf` throws on ambiguity instead of guessing.
- **`LeafInserted` is the leaf feed, not `Deposited`/`Withdrawn`.** Both insert sites
  (`PrivacyPool.sol:140` deposit, `:162` change note) funnel through `State._insert`, which emits one
  `LeafInserted` per leaf in tree order. Replaying the two user-facing events instead would mean
  re-deriving that interleaving from log order — reconstructible, but strictly worse.

✅ **The end-to-end Forge test now exists and passes.** `test/pool/WithdrawalHonkVerifier.t.sol`
gained `test_VerifiesWalletAssembledWitness`: the wallet's modules assembled a witness, `nargo
execute` solved it, `bb 1.2.0` proved it (`bb verify` OK natively), and the **on-chain
`WithdrawalHonkVerifier` accepts it** — fixture `test/fixtures/withdraw_identity_wallet.proof`,
regenerated by `tools/build-withdrawal-fixture.js` (deterministic, `sk_identity` pinned to 1234).
**162/162 Forge**, up from 157.

**It is strictly stronger than the baseline fixture, which is degenerate.** The baseline uses
size-1 trees: one leaf, all-zero siblings, so the LeanIMT carry-up rule makes the root equal the
leaf, depth is 0 and **no sibling is ever hashed**. The wallet witness has state depth 3 / ASP depth
2 over trees with filler leaves, so real multi-level sibling hashing is on the proven path.
`test_WalletWitnessExercisesRealMerklePaths` asserts both depths stay > 0 so a future regeneration
cannot silently fall back to the degenerate case. A cross-fixture guard
(`test_BaselineProofDoesNotVerifyWalletSignals`) pins that one proof cannot be presented with the
other's public signals.

**Note for anyone regenerating: on bb 1.2.0 there is NOTHING TO STRIP.** `bb prove` writes
`target/proof` and `target/public_inputs` as separate files and `target/proof` IS the fixture format
(16,224 bytes). The "strip the 4-byte field count and the 8 leading public-input fields" line in the
baseline fixture's provenance comment is a 0.82.2-era instruction from when the two were
concatenated.

### 2.1a Wallet proving bridge — ✅ PORTED 2026-07-27. Two real constraints remain.

Found while wiring §2.1's endpoint: the wallet could not produce a Honk proof at all, because
`src/sdk/` is a vendored copy of `@rarimo/rarime-rn-sdk` that declared **only `provePlonk`**, and it
is the copy the wallet actually imports (`Rarime.ts`, `Freedomtool.ts`, `Eudi.ts` all import
`"./RnNoirModule"`, never the package).

✅ **`proveHonk` ported into the local copy** (`src/sdk/RnNoirModule.ts` + `src/sdk/src/NoirModule.ts`).
✅ **`withdraw_identity` (8 public signals) and `title_holder` (2) registered** in
`supportedNoirCircuits`.

✅ **DE-DUPLICATED 2026-07-27 — `src/sdk/` went from 32 files to 6.** All fixes were upstreamed to
`quidmints/rarime-rn-sdk` first, then the copies deleted and imports repointed at the package.

**Why the copy existed at all: the package was IMPORTABLE BY NOBODY.** Not a style choice — a chain
of packaging defects, each hiding the next:
1. `npm install` of the SDK failed outright with **ERESOLVE** (`typescript@7` vs `@li0ard/tsemrtd`'s
   peer `^5`), so its devDependencies never installed;
2. so `prepare` could not build — and `prepare` was `expo-module prepare`, **a documented no-op**
   that never built anything regardless;
3. so `build/` was never produced, while `main`/`types` pointed *into* it;
4. and a real build would have failed anyway on **26 TypeScript errors** (17 mechanical
   `verbatimModuleSyntax`, **9 genuine unchecked-index defects** on parsed passport/contract data).

All fixed upstream. The package now installs, builds, and resolves. **Seven SDK defects total** —
also: the expo-file-system 57 migration (it used the API 57 removed while pinning `~57.0.1`),
`@noble/hashes` v2 subpaths, `1 << v` int32 vote truncation, undeclared `buffer`, and a hardcoded
Android AAR path. Plus `registerNoirCircuit()` / `bundledAsset` and a broadened root export surface,
without which a consumer with its own circuits still had no option but to fork the module.

**The 6 remaining files are ones the package genuinely lacks:** `Rarime.ts` (a real superset —
`holderRegistrationAddress`, `generateRegistrationMaterial()`), `HolderTree.ts`,
`holder/HolderContracts.ts`, `Eudi.ts`, `circuits.ts` (registers our two circuits — ~40 lines
replacing a ~250-line vendored `RnNoirModule.ts`), and `index.ts`.

**Also fixed: `metro.config.js` mapped `@rarimo/rarime-rn-sdk` → `path.resolve(__dirname, '..')`**,
i.e. `frontend/` — a directory holding only `identity-wallet/` and `secure-recovery/`, not the SDK.
A leftover from an autolinked-sibling layout. Removed; the package resolves from `node_modules`.

✅ **Circuit bytecode is now BUNDLED INTO THE APP** — was "built but hosted nowhere", so
`downloadByteCode` had nothing to fetch. `assets/circuits/{withdraw_identity,title_holder}.circuit`
(3.27 MB + 0.35 MB) ship in the bundle; `metro.config.js` registers `circuit` in `assetExts` so
Metro treats them as opaque assets instead of inlining a 3.3 MB parsed object into the JS bundle;
`NoirCircuitParams.loadByteCode()` prefers the bundled asset and never touches the network.
**`codegen-verifiers.sh` re-copies them on every run**, so bundled bytecode cannot drift from the
circuit whose verifier was just generated — a drift that would produce proofs the on-chain verifier
rejects with nothing pointing at the stale asset.

Bundling is also the better security posture, not just a workaround: the bytecode determines what is
being proven, so fetching it from a mutable remote URL would put whoever controls that URL inside the
trust boundary of every proof.

---

**TWO OPEN ITEMS — both device-gated, neither a code defect. Do not close without hardware (§1b).**

**(a) iOS has no Honk path — UltraHonk proving is Android-only.**
`ios/RnNoirModule.swift` exposes only `provePlonk` and hardcodes `proof_type: "plonk"`. Android
implements it (`android/.../RnNoirModule.kt:69`, `proofType = "honk"`). So every Honk circuit in this
fusion (`withdraw_identity`, `title_holder`) is Android-only until **Swoirenberg's Honk entry point
is exposed on the Swift side**. **Fine for the A16** — and it aligns with §1b rather than fighting
it: the target Samsung A16 is Android/arm64, which is both the only platform with a Honk path AND the
only ABI slice `noir.aar` ships. **An iOS launch is blocked on this and cannot be worked around
client-side.**

**(b) `proveHonk` reuses `ultraPlonkTrustedSetup.dat` — reasoning, not measurement.**
Barretenberg's SRS is a universal curve-level KZG setup shared across its proof systems rather than
Plonk-specific, so it **should** be correct for Honk despite the filename. But that is an argument,
not a measurement, and there is no device to measure on (§1b). **This is the FIRST thing to check if
device proving fails**; the fix, if it is wrong, is a Honk-specific SRS download. Recorded at the
constant itself (`NoirCircuitParams.TrustedSetupFile`) so whoever hits the failure finds it.

### 2.2 Gas: where it actually stands — UltraPlonk is REJECTED, aggregation is the answer

**DECIDED (user, 2026-07-27): no UltraPlonk. We stay on UltraHonk.** Deprecated from bb 0.87.0 with
no patched version to migrate to if a soundness bug appears — unacceptable for a value-bearing pool.
This also removes the constraint that used to gate the toolchain bump, so §2.3 can proceed freely.

**The gas problem is NOT solved, and recent work made it worse — deliberately.** Do not mistake the
volume of Honk work for progress on cost:

| | gas | note |
|---|---|---|
| before the `--zk` fix | 1,770,591 | proofs were **not zero-knowledge** — leaked the witness |
| after | 2,760,141 | **+51%**, the cost of blinding |
| + calldata (15,712 B × 16) | **3,011,533** | ≈ **$271** @30 gwei, ETH $3k |

The `--zk` fix was **correctness, not optimisation** — we were shipping proofs that leaked
`sk_identity`, `label`, `nullifier` and `secret`. The EIP-170 work (24,534 → 23,527 bytes) was a
*deployment* fix, not a gas one. Everything else was measurement.

**Consequence for L1:** at ~$271 a withdrawal, the pool is only usable for withdrawals around $5k
and up (for the fee to stay under 5%). That is a product constraint, not a line item.

**The only remaining answer is aggregation** (§2.4): ~68k/withdrawal at N=16, ~41k at N=64. It is
blocked solely on §2.3. Optimising UltraHonk itself cannot help — the irreducible precompile floor
is ~568k, and a Yul rewrite plus a forked bb would still land ~1.5M. There is no third option that
preserves what the protocol guarantees.

### 2.3 Dependency tree — ✅ DONE 2026-07-27. All circuits on beta.13 + bb 1.2.0, no split.

**527 compile errors → 0, by deleting dead code rather than migrating a library.**

The blocker was never our circuits. `pp` / `withdraw_identity` / `title_holder` used exactly ONE
function out of rarime's ~16k-line `noir_dl_lib` — `extract_pk_identity_hash`, **9 lines** — which
needs exactly ONE helper, `jubjub::priv_to_pub`, **126 lines with zero imports**. Importing those
135 lines dragged in the entire passport-verification stack (`sigver`, `big_curve`, `bignum`, every
ECDSA curve), making the PP circuits hostage to migrating a library they never use.

**What was done:**
1. **Deleted `noir_dl_lib/src/bitcoin.nr` and `recursion.nr`** — both orphaned (`lib.nr` never
   declared either; nothing referenced them). `bitcoin.nr` was the *only* consumer of the
   `ripemd160` dependency, so dropping it removed **548 of the errors on its own**. `recursion.nr`
   was dead UltraPlonk-era code (`[Field; 114]` VK shapes).
2. **Copied the 135 needed lines into `pp`** as `pp/src/jubjub.nr` + `pp/src/holder_root.nr`,
   verbatim, with headers explaining why they are copies and must not be "cleaned up".
3. **Dropped the `noir_dl` dependency from `pp` entirely.** The PP circuits no longer depend on the
   passport library at all.
4. **Bumped `poseidon` v0.1.0 → v0.2.0** and imported `PoseidonHasher` from the library rather than
   `std` (beta.13 removed it from std), plus an explicit `use std::hash::Hasher;`.

**Result — verified both ways:**

| | nargo beta.1 | nargo beta.13 |
|---|---|---|
| `pp` / `withdraw_identity` / `title_holder` | **COMPILES** | **COMPILES** |
| `pp` tests | **53/53** | **53/53** |

**The derivation is byte-identical, and that is what the tests prove.** `priv_to_pub` defines
`holder_root` — the durable identity commitment `HolderStateKeeper` anchors and the wallet computes
as `profileKey`. The published vectors in `identity_asp.nr` / `title_holder.nr`
(`sk_identity = 1234 → holder_root`) pass on **both** toolchains and against **both** poseidon
versions, so identity has not forked across circuit / contract / wallet.

**Why this matters:** beta.13 is bb 1.2.0's matched pair, and bb 1.x is where ZK-under-recursion
works. **The aggregation path (§2.4) is no longer blocked by our source.**

**PASSPORT CIRCUITS — MIGRATION COMPLETE 2026-07-27. 542 → 0 errors on beta.13.**

Every circuit compiles on beta.13: `pp`, `withdraw_identity`, `title_holder`, `query_identity`,
`query_identity_td1`, `register_identity_light_td1`, and `register_identity` (the ~16k-line one).
**Tests: 53/53 `pp`, 49/49 `noir_dl_lib`.**

**Every remaining fix was reviewed individually, not scripted, because they were integer-width
changes in bignum LIMB ARITHMETIC where a wrong cast compiles cleanly and truncates silently:**
- `u60_representation` shift operands — all bounded by `% 60` (0..59), so widening to `u64` is a
  type fix, never a truncation.
- `msb.nr` de Bruijn index — `u64 >> 57` yields 0..127 against a `[u32; 128]` table. Exact fit.
- `sha1`/`sha384` rotation amounts — bounded 0..31 / 0..63 by construction.
- `carry as bool` / `borrow as bool` — both produced by `(<comparison>) as u64`, so strictly 0 or 1;
  `!= 0` is exactly equivalent.
- `sha224` byte shifts — `shifts <= 3`.
- `big_curve` lookup indices came from an UNCONSTRAINED search hint, so rather than assume the
  bound, `assert_max_bit_size::<32>()` was ADDED before narrowing. Safe by constraint, not by
  construction.
- `u8`→`u32` index casts are widening and cannot truncate.

**New code written (the only non-mechanical part):** `noir_dl_lib/src/sha512.nr`. The stdlib dropped
`std::sha512` after beta.1 and there is **no `noir-lang/sha512` package**. This library already
contained the complete SHA-512 core inside `sha384.nr` (SHA-384 *is* SHA-512 with a different IV,
truncated to 48 bytes, FIPS 180-4), so sha512 reuses those exact helpers — only the IV and the
absence of truncation differ. **Verified against Python `hashlib.sha512` for both the one-block and
multi-block padding paths.** `sha256` came from `noir-lang/sha256` v0.2.0.

**More dead code removed:** `sigver/recursive_curve_proofs.nr` — exported but referenced nowhere,
and its failing call was a `#[test]` with hardcoded UltraPlonk-era verification keys that can never
validate on Honk. Same category as `bitcoin.nr` / `recursion.nr`.

**Interface change:** `register_identity/src/main.nr` no longer takes `dg15: [u8; 0]` — beta.13
rejects zero-length entry-point types. The DG15 length generic was already `0`, so the parameter
carried no data; it is constructed locally. **Constraints and public inputs are unchanged.**

**There is NO toolchain split — see §1.** Passport circuits are forward-only onto beta.13 (they no
longer build on beta.1), PP circuits build on both, and verifier generation runs on beta.13 + bb
1.2.0 like everything else. An earlier revision of this section claimed "verifier generation still
requires beta.1 + bb 0.82.2, because bb 1.x remains unusable" and that `codegen-verifiers.sh` stays
pinned to beta.1 — **both were true only until the flag below was found, and both are now false.**

**bb 1.x WORKS — the blocker was a missing flag, not an incompatibility (resolved 2026-07-27).**

**Root cause: `bb 1.x`'s `prove` REQUIRES `-k <vk>`. `bb 0.82.2`'s did not.** Without it, bb 1.2.0
silently proves against a different key, producing a proof its own verifier rejects with
`SumcheckFailed()`. It does NOT error, warn, or hint — it exits 0 and writes a plausible-looking
proof. Every "bb 1.x is broken / silently produces invalid proofs" conclusion recorded earlier in
this project was this flag, and was wrong.

**Verified working on nargo beta.13 + bb 1.2.0:**
- native `bb verify` — **passes**
- on-chain via the generated Solidity verifier — **passes, 2,747,575 gas**
- `publicInputsSize: 18` for `title_holder` = 2 real + 16 pairing-point accumulator, exactly as the
  generated verifier expects (2 from calldata, 16 read from the proof)
- **ZK under `--honk_recursion 1`: two runs of one witness give DIFFERENT proofs, and the recursion
  proof verifies natively.** This is the property aggregation needs, and it now holds end to end.

**HOW IT WAS FOUND — the technique is the reusable part.** Every attempt against the real circuit
failed identically, which made it look like a version incompatibility. Building a MINIMAL circuit
(`fn main(x: pub Field, y: Field) { assert(x == y * 2); }`) and running the same pipeline surfaced
the real error immediately: `Unable to open file: ./target/vk`. On the big circuit that message was
lost in the noise; on a two-line circuit it was the only output. **When a toolchain fails
identically on everything, reproduce it on the smallest possible input before concluding the
toolchain is at fault.**

**CONSEQUENCE: aggregation (§2.4) is UNBLOCKED.** The toolchain requirement is nargo beta.13 +
bb 1.2.0, both of which now build every circuit in this repo.

✅ **The repo pin was moved — all three follow-ups are DONE** (kept here only because each records a
0.82.2-vs-1.x behavioural difference that will bite anyone reading older material):
1. `codegen-verifiers.sh` is pinned to beta.13 / 1.2.0, passes `-k target/vk` on `prove` (the whole
   bug), and no longer passes `--zk` — **bb 1.x is ZK BY DEFAULT**; the opt-out is `--disable_zk`.
2. **1.x has NO 4-byte length prefix and writes public inputs to a SEPARATE file**, so there is
   nothing to strip out of `target/proof` — it is directly the fixture format. Any instruction to
   "strip the 4-byte field count and the 8 leading public-input fields" is 0.82.2-era. The proof
   carries 16 accumulator fields (491 + 16 = 507).
3. Both verifiers regenerated; Forge is green at **162 tests**.

**Also newly reachable: bb 5.x.** It was rejected only because it needs msgpack ACIR from a newer
nargo, and newer nargo previously ICE'd on our pre-migration code. Post-migration, beta.22 is down
to ~10-13 errors (library-version drift: poseidon v0.2.0's `RATE` global, `u1` → `bool`) plus one
remaining ICE in `query_identity`. Not needed for aggregation — beta.13 + bb 1.2.0 suffices — but no
longer a dead end either.

**Previous partial work (superseded, safe to delete):** `/tmp/noir_dl_lib.migrated`.**

`register_identity` / `query_identity` still carry the full `noir_dl_lib`. Migrating it: **542 → 73
errors**, all mechanical, in this order (each number is what it cleared):

| fix | cleared |
|---|---|
| `use crate::bignum::BigNumTrait;` where `.__add`/`.__neg`/`.__mul`/`__invmod` are called (7 files) | 135 |
| `mod X;` → `pub mod X;` in `sigver/mod.nr` etc; `pub` on `params` / `CurveParamsTrait` | 113 |
| wrap `let x = <expr with .__>;` bodies in `unsafe { }` (69 sites) | 100 |
| `PoseidonHasher` + `Poseidon2` moved out of std → `poseidon` lib (add the dep) | 46 |
| `sha256` left std → `noir-lang/sha256`, and `sha256_var` takes `(msg, len)` | 23 |
| `ScalarFieldTrait` / `RuntimeBigNumTrait` / `std::ops::{Mul,Add,Sub,Div,Neg}` imports | 52 |

**The remaining 73 are integer-width tightenings inside bignum LIMB ARITHMETIC** — `u64`→`u32`
indexing, mismatched bit widths, `u64 as bool`. **Do not script these.** A wrong cast silently
truncates in cryptographic code, and unlike every other class here it would compile cleanly. Each
site needs reading in context.

**HISTORICAL — this describes a mid-migration state that no longer exists.** The migration makes
`noir_dl_lib` beta.13-forward and therefore beta.1-incompatible, so mid-migration it built on
NEITHER, and was reverted via git at the time. **That revert has since been superseded: the
migration was completed and the pin MOVED to beta.13 + bb 1.2.0 (§1).** Nothing compiles on beta.1
any more, and nothing needs to. Kept only because the integer-width guidance above is still the
right way to review that class of change.

✅ **ALL OF THIS IS DONE — the pin HAS moved (§1). Retained only as a record of what it took.**
- The **passport** circuits (`register_identity`, `query_identity`) carried the full `noir_dl_lib`
  and ~527 errors on beta.13 (110 `unsafe {}` blocks, ~130 trait-import lines, 42 type-inference,
  plus `PoseidonHasher`/`sha256` path moves). **Migrated: 542 → 0.**
- bb 1.2.0's verifier expects a **pairing-point accumulator**. Confirmed present and handled: the
  proof carries 16 accumulator fields and the generated Solidity reads them from the proof itself
  (`publicInputsSize - PAIRING_POINTS_SIZE` comes from calldata).
- `ProofLib` and `codegen-verifiers.sh` were updated for the 1.x proof format — no 4-byte length
  prefix, and public inputs written to a SEPARATE file rather than prepended.

### 2.4pre Feasibility spike — MEASURED 2026-07-27. It fits, but barely, and there are traps.

**Run before committing to a design, because "it does not fit" would have changed N and the tree
shape.** A throwaway N-proof aggregator was built, its Solidity verifier generated and compiled;
the spike was then deleted. Findings:

**1. It FITS — but ONLY with `optimizer_runs = 1`, and with 83 bytes to spare.**

| build | runtime bytecode | vs EIP-170 (24,576) |
|---|---|---|
| default optimizer | **25,506** | **930 OVER — would not deploy** |
| `optimizer_runs = 1` | **24,493** | fits, **83 bytes** margin |

The aggregation verifier will need its own `compilation_restrictions` entry in `foundry.toml`, like
the two existing verifiers. **Margin is effectively zero** — the same knife-edge as the withdrawal
verifier's 85 bytes.

**2. Verifier size is INDEPENDENT OF N.** N=1, 4 and 16 all produce a ~90,372-byte source and the
same bytecode (±2 bytes). Honk's verifier is a fixed algorithm; N grows the *circuit*, not the
contract. **So N=16 costs nothing on-chain versus N=1** — the sizing decision is about proving time
and batch latency (§2.4b), not EIP-170.

**3. That result DEPENDS on keeping the public surface at ONE field.** The spike exposes a single
`batch_commitment` (a Poseidon fold over every inner proof's 8 public signals) rather than N×8
public inputs. The verifier's calldata handling scales with public inputs, and 83 bytes leaves no
room for that. **A design that surfaces per-withdrawal signals will not fit.** Nothing is lost by
compressing — the pool still checks each withdrawal's real signals itself.

**4. TRAP — `bb` SIGSEGVs (exit 139) on a wrong in-circuit vk length; it does NOT error.** The
recursive `verification_key` parameter is **128 fields**, NOT the 55 fields of the on-disk
`target/vk`. Passing 55 segfaults bb *after* it has already printed "Scheme is: ultra_honk", so
anything grepping stdout for errors reads it as success. Same family as the `-k`-on-`prove` footgun
(§1). Proof length is 507 fields, matching `target/proof`.

**5. The recursion API on beta.13 is `std::verify_proof_with_type(vk, proof, public_inputs,
key_hash, proof_type)`.** `std::verify_proof` does NOT exist and `#[recursive]` is not in scope.
Poseidon is the external `noir-lang/poseidon` package, not `std::hash::poseidon`.

**Still unmeasured, needs the phone:** aggregation-circuit proving time, and per-user withdrawal
proving time on the A16 (§2.4b). Aggregation batches VERIFICATION — each user still proves their own
withdrawal locally, and that number is unchanged by any N.

### 2.4 Build the aggregator — DECIDED: build our own. **THE ORIGINAL REASON TO DEFER IS GONE.**

**Why it was deferred:** "comes after §2.1 — until wallet-side witness assembly exists no user can
withdraw at all, and aggregation optimises a path that does not yet work end to end." **§2.1 landed
2026-07-27**, the withdrawal works end to end against a real pool, and §2.4pre measured the verifier
at 24,491 bytes with 85 spare and confirmed ZK survives `--honk_recursion`. So the stated blocker no
longer holds and nothing technical is in the way.

**It remains deferred only by explicit instruction** (user, 2026-07-27: "we are building our own
aggregator but dont do this yet"). Worth re-confirming rather than treating as permanent — the
things that would sensibly precede it are §2.5b (ragequit, which is a correctness hole rather than
an optimisation) and on-device proving time, which needs the phone.

**Decision (user, 2026-07-27): we build our own aggregator.** Not an AVS (§2.4e — it secures the
wrong property), not Aligned (§2.4f — same work, plus a dependency on someone else's roadmap).
**N=16**, 16-wide tree if wider.

**But do NOT start it.** §2.1 comes first: until wallet-side witness assembly exists **no user can
withdraw at all**, and aggregation optimises a path that does not yet work end to end. Building the
optimisation before the thing being optimised is backwards, and §2.1 is unblocked today.

Everything external that was blocking this is now cleared — §2.3 landed the toolchain and
ZK-under-recursion is verified working on beta.13 + bb 1.2.0. **The remaining gate is sequencing,
not capability.**

Design settled AND the toolchain now works: ZK-under-recursion verified end-to-end on
beta.13 + bb 1.2.0 (two runs of one witness give different proofs; the recursion proof verifies
natively). Nothing external blocks this any more.

**Who runs what.** Users prove their **own** withdrawal on-device (~1.3 s) — the witness never
leaves. A **batcher** runs the aggregation prover (~1M gates per inner proof, ~16M at N=16; tens of
GB, minutes) and sees only proofs and public inputs. **Anyone can be a batcher**: no registry, no
stake, no whitelist, paid through PP's existing relay fee. This is why recursion is required rather
than the cheaper "one circuit proving N withdrawals natively" — that needs one prover to hold
everyone's secrets.

**Four load-bearing constraints:**
1. **Inner verification key PINNED as a circuit constant, never an input** — otherwise a batcher
   aggregates proofs from a different circuit and forges withdrawals. Most important property here.
2. Every one of the N inner proofs actually verified — no short-circuit.
3. The batch commitment binds exactly those N public-input sets, **in order**.
4. The contract recomputes that commitment from calldata identically.
5. **The aggregator MUST replicate `PrivacyPool.validWithdrawal`'s range checks**, in particular
   `stateTreeDepth`/`ASPTreeDepth` `<= MAX_TREE_DEPTH`. The circuit casts those `Field` public
   inputs to `u32`, which TRUNCATES, and `lean_imt_inclusion` uses `actual_depth` **only** in its
   bound assert — it never affects the computed root. So a depth of `2^32 + 5` truncates to `5`
   in-circuit and passes. It is rejected today solely because the CONTRACT checks the full
   `uint256`. Any verifier that bypasses `PrivacyPool` loses that protection.

**Non-negotiables:** `PrivacyPool.withdraw` stays untouched, so self-submission at full gas always
works and a batcher refusing you costs money, never access. A batcher **cannot forge** — the
aggregate is verified on-chain, so worst case is refusal (liveness), never theft. That is the
structural difference from an AVS, where operators *attest* and you trust them.

**Oracle split — resolved.** Inner proofs use the default poseidon2 oracle + `--honk_recursion`; the
outer proof uses keccak. So a batching proof is not directly self-submittable. **The wallet retains
the witness until the withdrawal confirms and re-proves with keccak (~1.3 s) if it must
self-submit** — cheaper than generating two proofs every time. *Requirement: the wallet must not
discard the witness after handing a proof to a batcher.* An optimising refactor will delete that.

**Expected result**, using the measured model `verify_gas ≈ 2.38M + 3,510 × (public inputs)` —
circuit size is essentially free (44k-gate and 11.8k-gate circuits both ~2.7M):

| N per batch | gas/withdrawal (public inputs hash-compressed) |
|---|---|
| 1 | 2.39M |
| 16 | ~68k |
| 64 | ~41k |

**Costs to expect:** prover hardware is the ceiling (few batchers in practice, though entry stays
permissionless); low volume kills the economics (a batch of 3 costs ~800k each, not 41k); the
proof-relay layer is new infrastructure whose code must live in **ibiza**, not SPV (§7).

### 2.4b Aggregation sizing, infra and UX — what N to pick and what it costs

**N=256 flat is INFEASIBLE; tree-structured recursion makes it cheap.** Proving memory measured at
**3.4 KB/gate** (bb reported ~148 MiB for our 44,176-gate circuit), and in-circuit UltraHonk
verification is order 1M gates each:

| N | flat aggregator | RAM |
|---|---|---|
| 16 | 16M gates | ~56 GB |
| 64 | 64M gates | ~225 GB |
| 256 | 256M gates | **~899 GB — not a single machine** |

**Use a 16-wide TREE instead of one flat circuit.** Each node aggregates 16 proofs (~56 GB), and
depth 2 reaches N=256, depth 3 reaches N=4096 — every node stays at ~56 GB regardless of total N.
More proofs overall, but each is bounded and they parallelise across machines.

**Gas per withdrawal** (measured base 2.38M + 4,096 calldata that cannot be amortised, since the
contract needs each withdrawal's public inputs to recompute the batch commitment):

| N | gas | @30 gwei / $3k |
|---|---|---|
| 1 (today) | 3,113,864 | $280 |
| 16 | 152,846 | $13.76 |
| 64 | 41,284 | $3.72 |
| 256 | 13,393 | $1.21 |

**DECIDED (user, 2026-07-27): N=16.** It captures ~95% of the achievable saving. Beyond it the benefit decays as 1/N while prover
cost grows linearly, and calldata becomes the floor (a third of the total by N=256). Start at 16;
widen only if real volume justifies it — **a batch of 3 costs ~800k each, so at low volume the
discount never materialises at any N.**

**HARD CONSTRAINT: user-side proving must run on a Samsung A16** (budget phone, Knox enclave for key
custody). This is satisfied by construction and is a reason the split matters:
- The **user** proves only `withdraw_identity` — 44,176 gates, ~148 MiB, 1.33 s on a desktop i9.
  Memory is a non-issue on the phone; expect roughly 15-40 s wall-clock. **Unmeasured — measure on
  the actual device.**
- The **batcher** carries the ~56 GB aggregator. A phone never runs it.
- The recursion flavour (`--oracle_hash poseidon2 --honk_recursion 1`) does not change the user's
  circuit size — proof is still 507 fields — so the phone's cost is identical either way.

**INFRA:** a **batcher** (runs the aggregation prover — tens of GB, so realistically few operators,
though entry stays permissionless) and a **proof-relay endpoint** for users to submit to. Both can
run on SPV's fleet operationally; **the code lives in ibiza** to keep the one-way coupling
(sec. 7 — SPV's repo must contain zero PP references; sharing operators is free, sharing a repo is
not).

**UX:** withdrawal becomes **async** — you wait for a batch. Local proving is unchanged (~1.3 s
desktop). **The wallet MUST retain the witness until the withdrawal confirms**, so it can re-prove
with the keccak oracle if it ever needs to self-submit past a censoring batcher. An optimising
refactor will delete that retention; it is load-bearing for the escape hatch.

### 2.4c NO YIELD SUBSIDISATION — depositors keep their own yield (user, 2026-07-27)

**Directive: PP participants keep ALL of their yield, with the same UX as a regular SPV LP.** This
supersedes every earlier note in this file about yield funding gas subsidies, challenge bounties or
paymasters — **do not reintroduce those.**

**The obstacle, and the fix.** Yield cannot be credited per-depositor without per-user accounting,
and per-user accounting is exactly the linkage the pool destroys (PP-SPV-BUFFER-DESIGN sec. 2
forbids earmarking inside the Vogue position for this reason).

**Resolution: make notes SHARE-denominated, not value-denominated — the ERC-4626 pattern.** A note
commits to a *share count* rather than an absolute amount; the pool's assets grow with yield; the
withdrawal pays `shares x currentRate`. Yield then accrues to every note proportionally with
**zero per-user tracking and zero leakage**, and a PP depositor holds economically the same
instrument as an SPV LP — which is precisely the "same UX as a regular LP" requirement.
- Requires: `PrivacyPool` deposit/withdraw to denominate in shares, and the rate applied on the
  contract side at withdrawal (the circuit continues to prove share amounts, unchanged).
- **Known tension, must be designed around:** `shares x rate` produces distinctive, non-round
  withdrawal amounts, which worsens the amount-fingerprinting weakness that sec. 3's
  denomination-splitting is meant to fix. Splitting on *shares* rather than on payout value is the
  likely answer.
- This also removes the buffer design's awkwardness: idle capital earning yield is no longer a
  treasury question, it is the depositors' own return.

### 2.4d vBTC through PP — RULED OUT. It is not a bearer instrument; there is nothing to anonymise.

**Verdict reached in two corrections, both worth keeping so this is not re-proposed.**

**First draft said "mechanically viable"** on the strength of `Vault.sol:599` exposing a real
"vBTC ERC-20 + 4626 face" with standard `transfer`/`approve`, fungible 1:1 with sats. That checked
the token layer and stopped.

**Second look (user): the exit is channel-bound.** `unexposeBtcFromLev(address lp, uint sats)` takes
an LP address and is gated to `LEV_MANAGER_BTC`. True, and important — but not the deepest problem.

**Third look, and this is the decisive one: NOBODY EVER HOLDS vBTC.**
`exposeBtcToLev` mints with `emit Transfer(address(0), msg.sender, sats)` — and `msg.sender` is the
**LevManager**, not the LP. The manager holds it, supplies it to the Aave/Euler venue as collateral,
and burns it on close ("burn the sats vBTC the manager withdrew from the venue and convert the LP's
levered slice back to FREE channel band depth"). The LP never holds vBTC; the LP holds a **channel
band position**.

So vBTC is an **internal accounting token inside the leverage machinery**, not a BTC wrapper anyone
can custody. **There is no vBTC holder population to build an anonymity set from.** PP could
technically custody the ERC-20, and it would be pointless.

**The user's architectural instinct was also right: you cannot "just allow withdrawal to any
address" — that binding is load-bearing SECURITY, not a policy choice.** `BTCChannels.sol:477-496`
spells out why, and it is worth quoting because it is the reason a rearchitecture is not free:

> *"We REJECT any other output: without this, a malicious LP could route its withdrawal to a script
> != btcRecipientOf, making `_lpFinalBalance` read 0 -> `delivered = shrinkSats` -> over-claim the
> SHARED swap-out proceeds pool (cross-LP theft)."*

The contract cannot see *who* was paid, only *how much reached the committed script*. Free-form
outputs make the payout unmeasurable, so `delivered` becomes forgeable and one LP can drain the
shared pool. `btcRecipientOf` (the LP's upfront-shutdown P2TR key) is ONE source of truth for both
cooperative-close attribution and the on-chain splice path. **Unbinding it to gain anonymity would
trade a cryptoeconomic invariant for a privacy property — the wrong direction, and exactly the
hack-containment the user flagged.**

**"A different instrument" means precisely one thing: a token whose BURN PAYS THE BEARER in BTC**,
rather than one whose burn converts an LP's levered slice back to channel depth. vBTC's burn is an
LP *accounting operation*; a bearer instrument's burn is a *settlement*.

**The anonymity blocker and the LIQUIDATOR blocker are the same problem.** vBTC meets three of the
four requirements for an open lending market — transferable ERC-20, oracle (1:1 sats vs WBTC),
lenders possible — and fails the fourth: a liquidator who seizes vBTC holds a token only
`unexposeBtcFromLev` can burn, and that burn credits the LP, not the seizer. No redemption ⇒ no
liquidators ⇒ no rational lender. A PP withdrawer is in the identical position. **No bearer
redemption ⇒ no lending market AND no anonymity. Solving one solves both.**

It cannot be patched, because public redemption collides with an explicit invariant —
`Vault.sol:658` / `BtcLevManager.sol:570`: *"The LP never receives loose vBTC (that would
double-claim the same channel BTC)."* Same family as the `btcRecipientOf` binding above.

**⚠ IMPORTANT UPDATE (2026-07-27) — a bearer-delivery rail ALREADY EXISTS, and it defeats the
"unmeasurable payout" objection above.** `BTCChannels.requestSwapOutOnchain` → `deliverSwapOutOnchain`
delivers **real on-chain BTC to a plain Bitcoin address**. The recipient needs **no channel, no LN
node, no Lightning** — just an address. Delivery is gated to `channels[channelId].hop`, and the
protocol settles the hop afterwards via the `pendingSwapOutUsd` obligation.

*Correction to the framing: the script check is no longer the loose 22/25/34 length range.* It was
**tightened to P2TR-only today** (`BTCChannels.sol:1189-1197`): exactly 34 bytes AND prefix
`0x51 0x20`, because a length-only test accepts any 34-byte blob including a P2WSH the rest of the
stack cannot match. So the bearer address must be **key-path P2TR** — which is fine, the protocol is
taproot everywhere.

**Why this matters more than it looks:** §2.4d's central objection — *the contract cannot see WHO was
paid, only how much reached `btcRecipientOf`, so free-form outputs make `delivered` forgeable* — is
an argument about the **close / withdrawal splice** path. **The swap-out rail already solved it**, by
a different mechanism (`BTCChannels.sol:1221-1228`):

> *"delivered PINNED to the obligation … the delivered amount is NOT inferred from the tx outputs, so
> it cannot be inflated by routing the LP's change away from `btcRecipientOf`."*

Pinning `delivered` to the pre-recorded obligation (`so.sats`) instead of inferring it from outputs
is exactly the anti-over-claim property the `btcRecipientOf` binding was protecting. **A rail that
pays an arbitrary bearer address without breaking the cross-LP-theft invariant is already in the
codebase and shipping.** That substantially weakens the "option 2 is large and speculative" verdict
below — most of the accounting it needs exists.

**Three options, in order of what to actually do:**
1. **Put WBTC/tBTC through `PrivacyPoolComplex` — available TODAY, zero new design.** PP's ERC20
   pool already handles it, so anonymised BTC needs no architectural change. Cost: no SPV yield on
   that portion, since it is not channel BTC. **This is the recommendation.**
2. **A pooled-backing BTC token** — backed by AGGREGATE channel capacity and redeemable against any
   LP with capacity rather than the originator, dissolving the per-LP binding by construction.
   **← OWNED BY THE USER, in a parallel SPV thread (2026-07-27). Do not start it from the ibiza
   side.** Reclassified from "large and speculative" to "tractable" by the swap-out finding above.
   **Swap-out ≡ bearer redemption. What is missing is TWO THINGS, not a capability** (user,
   2026-07-27) — the recipient side is already solved, since swap-out takes a raw P2TR script and the
   hop pays an arbitrary address whose owner has no channel:

   1. **An entrypoint.** `exposeBtcToLev`/`unexposeBtcFromLev` are gated to `LEV_MANAGER_BTC`, so **no
      third party can burn vBTC**. A `redeemVBtc(sats, script, channelId)` would **reuse the existing
      rail wholesale** — `pendingSwapOutUsd` obligation, symmetric `swapOutUsed`/`swapInUsed` dedup,
      `requestBlock` self-refund timeout, failed-delivery reversal via `settleSwapIn` — with the USD
      intake (`creditSwapOut` pulling from `msg.sender`) replaced by a **token burn**.
   2. **Source-of-funds binding.** Swap-out names a `channelId` and is delivered by **that channel's
      hop**, so a liquidator is pinned to the originating LP. **The binding is about WHICH CHANNEL
      PAYS, not whether a bearer can be paid** — that is the one genuine design question, and the
      pooled-backing model is what answers it.

   Must not violate `Vault.sol:658` / `BtcLevManager.sol:570` (*"The LP never receives loose vBTC —
   that would double-claim the same channel BTC"*).
3. **Solve liquidator exit** — if SPV ever wants an open vBTC lending market it needs public
   redemption anyway, and that mechanism yields the anonymity for free. **The right trigger for
   revisiting this is SPV wanting the lending market, not PP wanting privacy.**

A permissioned market where the protocol backstops seizure (roughly what the per-LP escrow design
already approximates) solves the LENDING problem but **not** the anonymity one — permissioned means
identified.

### 2.4e Batcher decentralisation — an AVS secures the WRONG property. Do not use one.

**The batcher cannot forge.** The aggregate proof is verified on-chain, so validity is already
cryptographic. The only fault a batcher can commit is **refusing to include you** — liveness, not
soundness.

**That is why an AVS does not fit.** An AVS exists to make *attestations* trustworthy by putting
stake behind them. Our batcher makes no attestation; it produces a proof the chain checks itself.
So there is nothing to attest and nothing to economically secure. Slashing would have to target
censorship, which is **hard to attribute** — proving a batcher saw your proof and excluded it needs
a canonical mempool with proof-of-submission, which is more infrastructure than the thing it
protects. You would be adding staking, an operator registry and slashing logic to secure a property
that is already cryptographic, against a fault you cannot cleanly prove.

**What actually decentralises the batcher, in order of value:**
1. **The 16-wide TREE is the real lever** (sec. 2.4b). Each node is an INDEPENDENT ~56 GB job, so a
   deep batch can be built by MANY operators each proving one node, rather than one machine holding
   the whole thing. Flat N=64 needs a single ~225 GB box; a depth-2 tree reaching N=256 needs
   several ~56 GB boxes that never talk to each other. **Tree structure buys decentralisation that
   no amount of staking does.**
2. **Permissionless entry** — no registry, no stake, no whitelist. Nothing to capture.
3. **The escape hatch** — `PrivacyPool.withdraw` is untouched, so self-submission at full gas
   (~$280) always works. A censoring batcher costs you money, never access. That is the actual
   censorship bound, and it needs no slashing to enforce.
4. **Fee market** — batchers compete on the existing relay fee.

Residual honest weakness: ~56 GB is server-class, so expect FEW operators in practice even though
entry is open. That is *de facto* concentration without *de jure* permissioning, and an AVS would
not change it — an AVS registry would make it *more* permissioned, not less.

### 2.4f Upstreaming Honk into Aligned — real upside, but the same work as building our own

**The economics genuinely favour it, which is why it is worth stating precisely rather than
dismissing.** Aligned's aggregation service verifies its aggregate with a CHEAP outer system
(~300k gas) where ours pays UltraHonk's ~2.38M floor:

| N | ours (Honk outer) | Aligned (cheap outer) |
|---|---|---|
| 16 | 152,846 | **22,846** |
| 64 | 41,284 | **8,784** |
| 256 | 13,393 | **5,268** |

~7x better at our chosen N=16. Their aggregation service also has **full L1 hard finality** (one
proof verified on Ethereum), unlike their verification layer, which is restaking-backed "soft
finality" and wrong for a value-bearing pool.

**Effort to add Honk, split by product — the asymmetry is the whole point:**
- **Verification layer: EASY.** Operators run verification natively on bare metal; their docs call
  adding proof systems "straightforward". For UltraHonk that is essentially shelling out to
  `bb verify`. **But this is the weak-trust product — not usable here.**
- **Aggregation service: HARD.** Recursion requires an UltraHonk verifier running INSIDE their
  proving system (SP1/Risc0/Gnark). That means porting bb's verifier to zkVM-friendly Rust or a
  Gnark circuit — weeks to months of specialist cryptography that must be correct, since a bug
  forges proofs. **This is the SAME work as building our own aggregator**; it does not disappear,
  it relocates to a third party who audits and maintains it.

**Why not to pursue it now:** it makes our core cost structure depend on someone else's roadmap for
a launch-blocking property, and neither Noir nor Barretenberg appears anywhere in their docs or
roadmap. **Revisit only if Aligned ships Honk in the AGGREGATION service** (the hard-finality one) —
at which point the 7x is real and worth taking. Until then, build our own at N=16.

### 2.13b INVERT THE ASP: blacklist, not allowlist — and keep PP's labels alongside (user, 2026-07-27)

**The instruction:** stop maintaining a list of approved people. Membership should be proven
NEGATIVELY — "I am not on the blacklist" — and PP's original label-based screening should COEXIST
rather than be replaced.

**Why this is right.** An allowlist fails closed by omission: a postman who simply never admits you
censors you without ever acting, which is the same inaction lever §2.5a spent effort removing from
the revocation side. A blacklist fails OPEN — inaction means everyone can withdraw — and requires an
affirmative, rule-bound act to exclude anyone. It also enlarges the anonymity set from "everyone
admitted" to "everyone not excluded", which is strictly larger and does not shrink when the postman
is slow.

**⚠ THE TRAP: a blacklist over identities is trivially evaded on its own.** If a withdrawal only
proves `holderRoot ∉ blacklist`, an attacker generates a fresh random `sk_identity`, derives a
holderRoot nobody has listed, and passes. The check is vacuous. **A negative proof is only
meaningful against a scarce identity** — something you cannot mint more of.

**The resolution, and it needs no new trust:** pair the negative proof with INCLUSION IN THE
PERMISSIONLESS REGISTERED-IDENTITY SET. `HolderRegistration.registerDocumentViaNoir` already
registers a `holderRoot` against a Noir proof binding a real passport's DG1, and it is **not
role-gated** — anyone with a valid passport can register and nobody can decline them. So inclusion
there is proof-of-personhood, NOT approval. The distinction is the whole point: an allowlist is
someone's decision, a registration set is a fact about holding a passport.

**Target shape of a withdrawal proof:**
1. `holderRoot ∈ registered identities` — permissionless, scarce, nobody's discretion.
2. `holderRoot ∉ blacklist` — rule-bound (§2.5), fail-open, latest root never expires.
3. *optionally* `label ∈ ASP-screened set` — PP's ORIGINAL chain-analysis screening, preserved as a
   separate predicate a deployment may enable, rather than deleted.

That is what "coexist" means concretely: two independent gates on different properties — who you
are, and where the money came from — neither replacing the other, and neither being an approval
list.

**What this changes in the code:** `IdentityAspRegistry` stops being the gate (it becomes either the
registered-identity mirror or is dropped in favour of reading rarime's own registration state);
`withdraw_identity` swaps `identity_asp_membership` (inclusion in an ADMITTED set) for inclusion in
the REGISTERED set, keeping the existing `smt_verifier_full` exclusion; PP's label predicate returns
as an optional public input. The exclusion machinery already exists and is tested — this is a change
of which tree is consulted, not new cryptography.

**Open, and the reason this is recorded before it is built:** whether the label predicate is
per-pool configuration or a global toggle, and whether the registered-identity set is read from
rarime's SMT directly or mirrored into a PP-side registry (the mirror costs a sync, the direct read
costs a cross-contract dependency on an upgradeable rarime contract — which §2.5a would object to).

### 2.13c THE BLACKLIST MUST BE SECRET — options weighed, epoch pseudonyms recommended

**Constraint (user, 2026-07-27): who is on the blacklist is itself confidential.** §2.13b's design
publishes an SMT of blacklisted `holderRoot`s. That is unacceptable: registered identities are
public on-chain, so anyone can hash every registered holderRoot against the published tree and
recover the entire list by brute force. Publishing the tree publishes the list.

**THE CORE TENSION, stated before the options.** To prove non-membership WITHOUT a trusted issuer,
the prover must know the set — a Merkle non-inclusion path requires the surrounding tree. If the
prover knows the set, the set is public. **So "secret list" and "trustless non-inclusion proof"
cannot both hold as stated.** Every option below is a choice about which one bends.

**Option A — public list (status quo).** Trustless, fail-open, already built and tested.
*Cons:* no confidentiality at all. **Fine for OFAC SDN, which IS a published list — its secrecy is
not a requirement.** Useless for suspicion/law-enforcement predicates, which are secret by nature.

**Option B — issuer-signed non-membership credentials.** The authority signs "holderRoot X is not
listed as of epoch T"; the circuit verifies the signature instead of a tree path.
*Pros:* list never published in any form; simple circuit.
*Cons:* **reintroduces exactly the failure §2.13b exists to remove.** An issuer that declines to
sign censors you by inaction, indistinguishably from being slow. This is the allowlist again wearing
a different hat.

**Option C — cryptographic accumulator (RSA / bilinear) with non-membership witnesses.**
*Pros:* constant-size state; genuine non-membership witnesses exist.
*Cons:* computing a witness requires knowing the accumulated set, so either the prover knows it
(public again) or the issuer computes it (Option B again). Witness updates on every change are a
standing liveness burden. **Buys nothing over B while costing far more machinery.**

**Option D — EPOCH PSEUDONYM LIST. ← RECOMMENDED**
Each user holds a revocation secret `s`, shared with the authority at registration and bound to
their `holderRoot`. For epoch `T`, the authority publishes the list of `P = PRF(s, T)` for revoked
users only. The list is PUBLIC — so non-inclusion is trustlessly provable — but every entry is an
opaque PRF output that cannot be linked to an identity without `s`.

The withdrawal proves, with the pseudonym as a **PRIVATE** input:
1. `holderRoot ∈ registered` (permissionless, scarce — §2.13b's trap fix)
2. `P = PRF(s, T)` and `s` is the secret bound to that `holderRoot`
3. `P ∉ blacklist_T`

*Why it resolves the tension:* the SET is public (so anyone can build a path, no issuer in the
proving path) while the MEMBERSHIP is opaque (entries are PRF outputs). It fails OPEN — an authority
that does nothing publishes an empty or stale list and everybody withdraws. And it cannot be evaded,
because `s` is bound to a registered identity, so a fresh `s` fails step 2.

*What it leaks:* the SIZE of the revoked set per epoch, and nothing else on-chain. `P` never appears
publicly — it is a private input, so the authority (which knows every `s`) still cannot link a
withdrawal to a user.

*What it costs, honestly:* the authority holds a per-user secret, so a breach grants the ability to
revoke anyone (NOT to deanonymize — pseudonyms stay private). Users must fetch the current epoch's
list, which is public data, so no per-user issuance and no refusal surface. Epoch granularity bounds
how quickly a revocation takes effect, exactly like `MAX_ROOT_AGE` already does.

**Recommendation: A for public predicates, D for secret ones — and they compose.** OFAC is published;
forcing it through D would add a shared secret for no confidentiality gain. A deployment enables
whichever predicates it needs, and the circuit checks non-inclusion in each configured tree. The
exclusion gadget is identical for both — only the leaf derivation differs (`holderRoot` vs
`PRF(s, T)`), so D is largely a key-derivation change over machinery already built and tested.

**RESIDUAL COST OF SECRECY, AND IT IS NOT SMALL — SECRECY DESTROYS AUDITABILITY.** §2.5 exists to
make revocation PROVABLY RULE-BOUND: a revocation must cite a predicate, and anyone can check that
it did. A confidential list breaks that check for everyone except the authority — if observers
cannot see WHO was listed, they cannot verify the listing followed a rule, and "provably rule-bound"
degrades to "asserted rule-bound". Option D fixes the CENSORSHIP-BY-INACTION problem, and it does
not fix this one; no option above does, because the two properties are in genuine tension.

The mitigation, if it is wanted, is a ZK proof of CORRECT LISTING: alongside each published
pseudonym the authority proves in zero-knowledge that the corresponding identity satisfies a
declared predicate, without revealing the identity. That restores auditability at real cost (a proof
per listing, and each predicate must be expressible in-circuit — which the OFAC one currently is
NOT, since the linkage from a holderRoot to a listed person does not exist on-chain at all; see
backend/cre/ofac_sdn/main.go's own note on this). Recorded as the honest price rather than buried:
adopting D means accepting weaker auditability than §2.5 promises until that proof exists.

**Open before building D:** which PRF (Poseidon over `(s, T)` keeps it in-circuit-cheap and reuses
the audited hash), epoch length, and how `s` is delivered to the authority at registration
(encrypted to a published authority key is the obvious route, and wants its own scrutiny).

### 2.13d SCOPED: escrow-bound revocation secret. MEASURED, and the cost lands off the hot path

Closes §2.13c's soundness hole (nothing forced a user to pick an `s` the authority knows, so anyone
could be permanently unrevokable) WITHOUT an authority interaction that could be refused.

**Mechanism.** The user encrypts `s` to the authority's published BabyJubJub key with HASHED ELGAMAL
— `C1 = r*G`, `C2 = s + Poseidon(r*PK_A)` — and posts the ciphertext ON-CHAIN with a proof it is
well-formed and encrypts the `s` they committed to. No approval step exists, so there is nothing to
withhold. BabyJubJub is already the curve: `pp/src/jubjub.nr` has the 254-bit ladder and point
addition, and the only new primitive is that ladder generalised to an ARBITRARY base (`priv_to_pub`
hardcodes G), which is a ten-line change.

**MEASURED with `nargo info`, 1.0.0-beta.13 — not estimated:**

| circuit | ACIR opcodes | note |
|---|---|---|
| `withdraw_identity` today | 43,772 | baseline |
| `register_identity` today | 72,932 | baseline |
| `register_identity_light_td1` today | 16,180 | baseline |
| hashed-ElGamal escrow proof | **23,727** | dominated by 2 scalar mults (~11.8k each) |
| withdrawal add, SEPARATE escrow tree | 7,895 (**+18%**) | the depth-20 inclusion is nearly all of it |
| withdrawal add, escrow folded into the REGISTERED LEAF | **8** (+0.02%) | ← the shape to build |

**The shape those numbers pick.** Do NOT put the encryption in a registration circuit: it is +33% on
`register_identity` and **+147%** on the light TD1 path, which would be the worst place to spend it.
Do NOT give escrow its own tree either — that costs 7,895 opcodes on EVERY withdrawal forever.
Instead:

1. **Registered-identity leaf becomes `Poseidon(holder_root, Poseidon(s))`.** The withdrawal already
   proves inclusion of that leaf, so the escrow binding rides along for free.
2. **Escrow is a SEPARATE, ONE-TIME, PERMISSIONLESS transaction** carrying the 23,727-opcode proof
   that the posted ciphertext encrypts the `s` committed in that leaf. Both registration circuits
   stay untouched.
3. **Withdrawal adds 8 opcodes**: derive `P = Poseidon(s, epoch)`, and swap the blacklist leaf from
   `holder_root` to `P`. The depth-20 exclusion gadget it runs today is REUSED as-is — this is a
   leaf-derivation change, not new machinery.

Recurring cost is therefore ~zero and the whole price is paid once, off the hot path.

**REQUIRED GUARD: assert `r != 0`.** With `r = 0` the shared secret degenerates to the identity
point, so the mask is a public constant and `C2` reveals `s` TO EVERYONE. That would let any
observer test the published pseudonym list for that user — the exact confidentiality the design
exists to provide. A degenerate `r` looks like a valid encryption and would pass every other check.

**Residual costs, stated plainly:** the authority can decrypt every `s`, so it can revoke anyone —
that IS the intended power, and a key compromise grants revocation (denial of service) but NOT
deanonymisation, since `P` is a private input and never appears on-chain. §2.13c's auditability loss
is unchanged by any of this.

**Open:** epoch length, and whether the escrow record is required before the FIRST withdrawal or
before the first deposit.

### 2.13e CORRECTION: the epoch was redundant, and the blacklist is the REVOCATION REGISTRY

Supersedes the epoch-based parts of §2.13c/§2.13d. Both were challenged by the user on efficiency
grounds and both were wrong; recorded here rather than silently edited, because the REASON generalises.

**The epoch bought nothing.** The pseudonym `P` is a PRIVATE circuit input and never appears
on-chain, so there is nothing to track across withdrawals and therefore nothing to rotate for. The
rotation was imported from anonymous-credential revocation, where pseudonyms ARE revealed — that is
the premise that makes rotation necessary, and it does not hold here. Root freshness was ALREADY
solved by `RevocationRegistry`'s `MAX_ROOT_AGE` + always-valid-latest, so the epoch was a second
notion of time doing the first one's job. Drop it: `P = Poseidon(s)`, published when it changes.

*(This is the third mechanism imported from a context whose premise does not hold here — after the
revocation root policy borrowed from the ASP's inclusion semantics, and the accumulator option that
never asked who computes the witness. The failure mode is reusing a mechanism without re-checking
its premise, and it is worth a deliberate check on anything else borrowed wholesale.)*

**THE BIGGER ONE: the identity blacklist and the revocation registry are the SAME OBJECT.**
`RevocationRegistry` already holds "identities that may not withdraw", proven by exclusion at depth
20. The blacklist being designed is that tree with a different leaf derivation. Building both would
have duplicated two contracts, two roots, two public inputs and two witness paths for one job.
§2.13's blacklist IS §2.5's revocation registry made CONFIDENTIAL — leaves become `Poseidon(s)`
instead of `holder_root`, which is exactly the secrecy upgrade and nothing more.

**Second merge, from the user's observation that ONE authority writes both lists:** the tainted-label
entries belong in that same tree — `Poseidon(s)` keys persons, `Poseidon(s, label)` keys flagged
deposits, distinct preimages so they cannot collide. One contract, one root, one validity check.
Still two exclusion PATHS (~7,895 opcodes); it is the contract/root duplication that goes.

**Checked and clean:** root expiry must NOT extend to the registered set — it is an INCLUSION tree,
where old roots have FEWER members and are therefore safe. Only exclusion trees need expiry.
Registered-set inclusion and the escrow binding are already ONE proof, since the leaf is
`Poseidon(holder_root, Poseidon(s))`.

**Resulting shape** — two trees beyond PP's state tree, no epoch, both identity and label screening
live, everything failing open:

| gate | tree | key |
|---|---|---|
| note exists, unspent | state (LeanIMT) | commitment |
| registered + escrowed | registered mirror (inclusion) | `Poseidon(holder_root, Poseidon(s))` |
| person not listed | exclusion tree | `Poseidon(s)` |
| deposit not flagged | SAME exclusion tree | `Poseidon(s, label)` |

### 2.13f CORRECTION: "no cryptographic invariant across passports" was too broad — build these

Challenged by the user, and the challenge was right. Two DIFFERENT things were blurred: DERIVING a
person-linkage from document contents (genuinely limited) and ENFORCING document-level uniqueness
(entirely possible, and currently NOT DONE).

**THE HOLE — CORRECTED AFTER READING THE CODE. My first description of it was wrong.** I claimed
`HolderRegistration` had no `documentKey -> holderRoot` mapping. It effectively does: `addDocument`
requires `status == DocStatus.None`, status only ever moves None -> Current -> Superseded/Revoked and
NEVER back, and `_usedDocumentHash` is set-only. So a document key cannot be re-bound.

The REAL defect is one level down, and sharper. `_verifyNoirZKProof` binds exactly three public
signals — `dgCommit`, `dg1Hash`, `holderRoot`. But the uniqueness guard was keyed on
`passport_.passportHash`, and the document identity on `passport_.publicKey`, and **NEITHER OF THOSE
IS CONSTRAINED BY THE PROOF** — both are caller-supplied struct fields attested only by the backend
signer's signature. So the guard keyed on values the proof never checks, while a proof-bound value
sat unused beside them. Anyone able to obtain a signature could present a FRESH `publicKey` and
`passportHash` for the SAME physical passport and bind it to a SECOND `holderRoot`; the proof still
verifies, because nothing ties those fields to the document. That defeats any identity-level
blacklist by construction: get listed, re-register, withdraw as someone new.

FIX (landed): feed the anti-replay guard `dg1Hash` instead of `passportHash`, and reject zero on
this path. `dg1Hash` is computed IN-CIRCUIT as `passport_hash(dg1)` over the MRZ, so it is
deterministic per passport and unforgeable. No new storage, no signature change — the guard already
existed and was simply being fed the wrong value. Zero must be rejected HERE because `addDocument`
treats a zero hash as "no anti-replay wanted" and skips the check entirely.

Renewal is unaffected: a renewed passport has a new MRZ, hence a new `dg1Hash`. Verified by
reverting the fix — 5 of the 6 new tests fail without it, and `test_renewalStillWorksUnderTheDg1Guard`
passes both ways by design, being the regression guard rather than an attack.

**TWO MORE THAT HOLD:**
- **Mandatory authenticated DG1 in the envelope** — the full MRZ, not a digest. The controller
  receives name, DOB, sex, nationality and document number PASSPORT-SIGNED via the ICAO chain, which
  is STRONGER than conventional KYC where documents can be forged.
- **The MRZ personal-number field** (TD3 line 2, 14 chars) carries a national ID in many states.
  Where populated it links one person's documents from the same issuer cryptographically.

**WHERE IT STOPS, AND WHY IT MUST.** Cross-STATE, different-name linkage. ICAO 9303 defines no field
shared between two states' passports for the same person. The available quasi-identifier is
DOB + sex + place of birth, and thousands of people collide on it — making it a hard key would BLOCK
INNOCENT PEOPLE from withdrawing. That false-positive cost is why it stays a fuzzy match rather than
a cryptographic one; the harm from a wrong hard key is borne by someone who did nothing.

Accurate claim, replacing the too-broad one: the protocol enforces that NO DOCUMENT ESCAPES THE
CONTROLLER'S VIEW and NO DOCUMENT CAN BE RE-HOMED. Cross-state person-linkage is fuzzy matching on
UNFORGEABLE inputs — the same matching sanctions screening already performs, on better data.

**PREDICATE CITATION: an event is not enough (user).** Events are log data — not contract state, not
readable on-chain, droppable by any indexer. The exclusion SMT is key->value and its VALUE SLOT IS
CURRENTLY WASTED (always 0). Store the predicate THERE: covered by the root, part of the committed
state, impossible to omit or prune, and exactly what a ZK proof-of-correct-listing must prove
against. Costs nothing — the field exists and is being filled with zero. Strictly stronger than an
event, and it drops the per-predicate attester mapping's misconfiguration surface without losing
the record.

### 2.13g CANCELLED: the SMT swap for the registered mirror. Measured, and it is a net loss

Step 2 of the §2.13 build order, dropped before implementation on its own numbers.

**Claimed:** swapping the registered mirror from LeanIMT to SparseMerkleTree would be free or
cheaper, drop the `asp_tree_depth` public input, and leave ONE proof gadget instead of two.

**Measured with `nargo info`, capacity-matched at depth 32 (~4 billion identities):**

| gadget | ACIR opcodes |
|---|---|
| `lean_imt_inclusion` (current) | 10,575 |
| `smt_verifier_full` inclusion (proposed) | **11,856** |

The swap COSTS +1,281 opcodes (+12%) on every withdrawal. The earlier "SMT is cheaper" figure
compared depth-20 SMT (7,889) against depth-32 LeanIMT — different capacities, so not a comparison
at all. The registered set is the LARGE tree; the depth-20 figure belongs to the blacklist, which
holds thousands, not millions.

**And the main justification was false.** PP's own state tree uses `lean_imt_inclusion` too
(withdraw_identity/src/main.nr:81) and is not changing, so LeanIMT stays in the trusted base
regardless. The swap does not remove a gadget — it only changes which tree uses which. That claim
was made without checking the tree three lines above the one being changed.

Net: pay +12% per withdrawal to drop one public input. Not worth it. `asp_tree_depth` stays, and its
existing safety argument holds — a false depth simply fails to reconstruct the root, so no separate
range check is needed.

**What survives from the original step 2:** nothing. The key->value property that motivated "SMT
everywhere" is wanted only for the EXCLUSION tree's predicate slot (§2.13f), and that tree is
ALREADY a SparseMerkleTree.

### 2.13h Step 3 was ALREADY DONE; step 4's ladder landed, and the r=0 degeneracy is now measured

**Step 3 (predicate into the SMT value slot) needed no work — it already exists.**
`RevocationRegistry.revoke` does `_tree.add(holderRoot_, predicate_)`, with a comment saying exactly
why: "the tree records not just that an identity was revoked but under which rule - auditable after
the fact without trusting the event log." My §2.13f claim that "the value slot is currently wasted,
always 0" came from reading the CIRCUIT's exclusion call - which passes 0 because exclusion does not
use a value - and generalising to the contract without opening it. The user's concern that an event
is not enough was already answered by the code.

**Step 4, part one: `mul_point` (arbitrary-base scalar multiplication) landed in pp/src/jubjub.nr.**
This was the ONLY primitive the hashed-ElGamal envelope was missing - sealing to the controller's
key needs `r*PK`, not just `r*G`. `priv_to_pub` now DELEGATES to it rather than carrying a second
copy of the same 254-iteration ladder.

*Safety of touching `priv_to_pub`, which defines `holder_root`:* the ACIR is BYTE-IDENTICAL after the
refactor - `withdraw_identity` measures 43,772 opcodes before and after - so no verifier key changes
and nothing needs redeploying. Differential vectors against @iden3/js-crypto (base 7*G, four
scalars including a full-width one) plus `test_priv_to_pub_agrees_with_mul_point` pin the delegation.

**THE r=0 DEGENERACY IS NOW MEASURED, NOT ASSUMED.** `mul_point(P, 0)` returns **(0,0)**, NOT the
curve identity (0,1) - this ladder uses (0,0) as its empty-accumulator sentinel, and (0,0) does not
satisfy the curve equation at all. The test was written asserting (0,1) and FAILED, which is how the
real value was established.

That makes the `r != 0` guard concrete: with r=0 the shared secret is (0,0) for EVERY controller key,
so the mask `Poseidon2([0,0])` is a public constant and `C2 = s + mask` discloses the sealed
revocation secret to anyone who looks. Base-independent, so the leak is universal rather than
key-specific. Both facts are asserted in
`test_mul_point_by_zero_returns_the_sentinel_not_the_identity`.

### 2.13i Step 4 COMPLETE: the escrow envelope proves, verifies on-chain, and costs 37,384

`pp/src/envelope.nr` (hashed ElGamal over Baby Jubjub) + the `escrow_envelope` circuit + a generated
Solidity verifier that has ACCEPTED A REAL PROOF. End to end: JS witness -> nargo execute -> bb
write_vk -> bb prove -> bb verify -> on-chain `forge test`.

**COST CORRECTION - 37,384 ACIR opcodes, not the 23,727 quoted in §2.13d.** That estimate missed a
THIRD scalar multiplication (deriving `holder_root` from `sk_identity`) and used Poseidon2 rather
than the circomlib Poseidon this codebase actually shares with the wallet and poseidon-solidity.
Three scalar mults at ~11.8k each dominate. It is a ONE-TIME, off-hot-path cost, so the conclusion
stands; the number was wrong by 58%.

**Why `holder_root` is PROVEN and not supplied** (the third scalar mult, and worth its cost): if the
caller could name any holder root, an attacker would escrow a commitment to a secret of THEIR
choosing against a VICTIM's identity. The victim's withdrawal - which proves its `s` matches the
escrowed commitment - would then fail forever. Requiring knowledge of `sk_identity` makes escrow
self-service only.

**The r=0 guard is exercised, not merely present.** Four negative witnesses were run and each fails
with its own assertion: zero ephemeral, holder_root not derived from sk_identity, commitment not
matching the sealed secret, tampered ciphertext.

**EIP-170 - THE NEW VERIFIER DID NOT FIT.** At the default optimizer setting it compiled to 25,503
bytes, 927 OVER the 24,576 limit and undeployable. It has 8 public inputs, more than any other
circuit here, and each costs runtime code. Fixed by scoping `optimizer_runs = 1` to it in
foundry.toml, exactly as the other three verifiers already do -> 24,490 bytes, 86 bytes of headroom.
This surfaces ONLY at deploy time, so `forge build --sizes` must be checked after any change that
adds a public input.

**Regenerating all four verifiers confirmed the jubjub refactor was ACIR-neutral**: the three
existing verifiers came out byte-identical (no git diff), which is the strongest available evidence
that delegating `priv_to_pub` to `mul_point` did not fork `holder_root`.

**Cross-implementation, not a self-consistent loop:** every public input in the fixture was produced
by @iden3/js-crypto - the same babyJub and Poseidon the wallet uses - and then accepted by the Noir
circuit and the Solidity verifier.

**Still open on this circuit:** the sealed `document_attribute` is currently ONE field supplied by
the caller. §2.13f wants the FULL authenticated DG1 sealed so the controller can attribute
registrations to a person across passports; that needs the DG1 bytes re-hashed in-circuit to bind
them to the proof-bound `dg1Hash`, whose cost has NOT been measured. Sealing more fields is nearly
free (one shared secret, ~8 opcodes per extra mask); re-hashing DG1 is the unknown.

### 2.13j The FULL DG1 is sealed - measured, and two claims in §2.13i were wrong

**Closes §2.13f's attribution requirement and §2.13i's one open item.** The envelope now carries the
entire authenticated MRZ, not a caller-supplied placeholder field.

**Why the whole MRZ and not a digest.** A person may hold several passports under different names,
and ICAO 9303 defines no field linking two states' documents for one person, so the controller must
perform that attribution itself - which it can only do from the ACTUAL MRZ (name, date of birth,
nationality, document number). A hash lets it VERIFY a guess but never FORM one. So the MRZ rides
inside the envelope: opaque on-chain, readable only by the controller, bound by `dg1_hash` to the
same bytes registration already pinned.

**MEASURED - it looked expensive and is not:**

| | ACIR opcodes |
|---|---|
| sealing 4 fields, no binding | 25,146 |
| + sha256 binding over 95 bytes | 25,542 (**+396**) |
| escrow_envelope, single placeholder attribute | 37,384 |
| escrow_envelope, full sealed MRZ | **38,874** (+1,490, +4%) |

sha256 costs only 396 ACIR opcodes because it is a BLACKBOX gadget, not unrolled arithmetic (Brillig
opcodes go 26 -> 611). Extra sealed fields are ~8 opcodes each, since ONE shared secret covers the
whole payload. One-time and off the hot path.

**TWO CLAIMS IN §2.13i WERE WRONG, both about the EIP-170 incident:**
1. "It has 8 public inputs, more than any other circuit here" - `withdraw_identity` has NINE.
2. "each public input costs runtime code", implying input count drove the overflow. MEASURED across
   all four verifiers: TitleHolder (2 inputs) 24,491; Ragequit (4) 24,489; Withdrawal (9) 24,491;
   EscrowEnvelope (12) 24,491. **Verifier size is essentially FLAT in public-input count.** The
   25,503-byte overflow was caused ENTIRELY by the missing `optimizer_runs = 1` scoping. Going from
   8 to 12 public inputs moved the size by ONE byte.

**The digest-packing convention is copied deliberately, not cleaned up.** `register_identity_light`
skips `digest[0]` and reads the remaining 31 bytes big-endian. The obvious `digest[0..31]` yields a
DIFFERENT field, so `dg1_hash` would not equal the `dg1Hash` that
`RegistrationSimple._verifyNoirZKProof` binds and that `HolderStateKeeper` now stores as the
document anti-replay key (§2.13f). The escrow would bind the MRZ to a value nothing else agrees
with, and no test outside the escrow circuit would catch it.

**Test hardening:** the forge test now READS both the proof and a committed `escrow_envelope.public`
fixture, and asserts the named constants MATCH the fixture rather than being the source of truth.
Hand-transcribing twelve 77-digit field elements was the obvious place for this test to rot - a typo
would have failed for a reason unrelated to the verifier. 5 tests: real proof verifies, fixture is
the documented witness, all 12 inputs binding, sealed slots pairwise distinct, malformed rejected.

### 2.13k SUPERSEDES step 5: ONE identity tree, no sk_identity in the withdrawal. -43% MEASURED

Step 5 was "change the RevocationRegistry leaf to Poseidon(s)". Doing it exposed something larger:
`membership.holder_root` is used for EXACTLY ONE thing in `withdraw_identity` - as the revocation
key. Once that key becomes the escrow commitment, **the withdrawal does not need `holder_root`, and
therefore does not need `sk_identity`, at all.** Identity is checked ONCE, at escrow, where
`escrow_envelope` already proves `holder_root` from `sk_identity` and binds the MRZ.

And the two identity trees collapse into one. Key = the escrow commitment; VALUE carries status:
`0` = registered and clean, non-zero = the revocation predicate (which §2.13f established is
already stored there). So a SINGLE INCLUSION proof of `commitment -> 0` replaces BOTH the ASP
inclusion and the revocation exclusion.

**MEASURED, capacity-matched at depth 32:**

| | ACIR opcodes |
|---|---|
| `withdraw_identity` today | 43,772 |
| proposed, one tree, no sk_identity | **24,812** |
| | **-18,960 (-43%)** |

Where it comes from: the ASP scalar multiplication disappears (~11.8k), and one LeanIMT inclusion
plus one SMT exclusion (~18.5k combined) become one SMT inclusion (~11.9k).

**Soundness.** Scarcity still holds: commitments enter the tree ONLY via `escrow_envelope`, which
proves a registered, uniquely-bound document. Fail-open still holds: a controller that does nothing
leaves every value at 0 and every withdrawal works. Knowing `s` rather than `sk_identity` is
equivalent authorisation - neither spends a note, which needs the note secrets; both only satisfy
the clearance gate.

**THE ROOT-POLICY TRAP THIS CREATES, and it is the one I have already shipped once.** §2.13e recorded
that inclusion trees need NO root expiry (old roots have fewer members, so they are safe) while
exclusion trees REQUIRE it. A merged tree does BOTH jobs, so it MUST take the STRICTER policy:
`MAX_ROOT_AGE` plus always-valid-latest. Without expiry, a revoked identity proves `commitment -> 0`
against a root from before its revocation, forever. This is exactly the asymmetry I argued should be
kept in separate contracts precisely so it could not be confused - merging the trees gives that
argument up, so the policy has to be enforced in code and tested directly.

### 2.13l TITLE PATH CONSISTENCY: three confirmed defects (user, 2026-07-28)

User's framing: *"titleholder is just another document like a second passport, the only thing is
that it links two identities, the titleholder and the certified identity of a notary attesting the
title."* Checked against the code, and it does not currently work that way:

1. **`DOC_NOTARIAL_TITLE` is declared and NEVER USED.** `HolderStateKeeper.sol:66` defines it
   alongside DOC_PASSPORT / DOC_NATIONAL_ID / DOC_MDL / DOC_EUDI_PID; a repo-wide grep finds no
   other reference. The document model already has a slot for titles and nothing puts one there.

2. **`TitleLedger` does not touch `HolderStateKeeper` at all.** A title is a parallel structure
   (`mapping(uint256 => bytes32) holderCommitment`), NOT a document under a holder root. So a title
   gets none of the document machinery: no `dg1Hash`-style uniqueness guard (§2.13f), no
   supersede/revoke lifecycle, no multi-document-per-identity accounting. If a title is "just
   another document", it should register through the same path a second passport does.

3. **The notary is an ADDRESS, not a certified identity.** `address notary` and
   `mapping(address => bytes32) notaryDataHash`. TitleLedger's own header already flags this as an
   OPEN GAP - "binding a real-world notary's identity to an on-chain signing address ... still isn't
   cryptographically proven". Under the user's framing the notary should be a REGISTERED
   `holder_root` like anyone else, so that attesting a title links two identities rather than an
   identity and a keypair. That also folds the notary into §2.13k's single identity tree, making a
   notary revocable by the same mechanism as everyone else - which an address can never be.

**Consequence for §2.13k:** if titles become documents and notaries become identities, both sit in
the SAME merged tree, and `title_holder`'s commitment `Poseidon(holder_root, title_id)` should be
reconsidered against the escrow commitment so there is one identity key rather than two conventions.
NOT changed yet - recorded so the merged-tree work does not land while the title path still uses a
second, incompatible identity notion.

### 2.13m MERGE TRAPS: enumerated, and the two fatal ones are now TESTED CLOSED

Before landing §2.13k's single identity tree, the traps in "status lives in the VALUE" were hunted
deliberately rather than assumed away. Two would have been fatal and silent; both are now pinned by
tests in pp/src/smt.nr (84 pp tests pass).

**TRAP 1 - would `key -> 0` be indistinguishable from ABSENCE?** If so, ANY unregistered identity
could prove the clean state and withdraw, and the gate would be vacuous for exactly the population
it exists to exclude. NOT vacuous: leaf hashing is `Poseidon(key, value, 1)`, so `leaf(k, 0)` is a
non-zero hash while an empty node is literal `0`, and the two cannot collide.
`test_absent_key_cannot_be_proven_present_with_value_zero` asserts it.

**TRAP 2 - is the VALUE actually binding?** If a leaf's value could be misreported, a REVOKED
identity would claim 0 and withdraw, defeating revocation entirely. It is binding:
`test_a_revoked_entry_cannot_claim_value_zero` proves key=7 (present with value 77 in the reference
tree) CANNOT be shown to hold 0. Plus `test_inclusion_with_value_zero_is_provable` (the clean case
must genuinely work) and `test_value_zero_inclusion_still_binds_the_root`.

NONE of these were covered before, because no caller had ever passed value 0 - the existing
inclusion test uses 77. The merged design is the first thing to depend on that path.

**REMAINING TRAPS, to enforce when the merge lands:**

- **ROOT EXPIRY IS NOW MANDATORY.** §2.13e recorded that inclusion trees need none and exclusion
  trees require it. The merged tree does BOTH jobs, so it must take the STRICTER policy
  (`MAX_ROOT_AGE` + always-valid-latest). Without it a revoked identity proves `commitment -> 0`
  against a pre-revocation root FOREVER. This is the asymmetry I argued should stay in separate
  contracts precisely so it could not be confused; merging surrenders that structural protection, so
  it must be enforced in code and tested directly.
- **`predicate != 0` MUST BE REJECTED.** Zero is the CLEAN sentinel, so a zero predicate would
  "revoke" an identity into the clean state. Negligible by accident, fatal if reachable.
- **`remove` MUST NEVER BE EXPOSED.** `@solarity` `Bytes32SMT` provides `add`, `update` AND
  `remove`. `update` is what revocation needs (0 -> predicate, one-way, guarded by the existing
  `isRevoked` mapping). `remove` would DELETE a registration - censorship by erasure, and precisely
  the "postman can drop an existing member" failure the append-only design was built to prevent.
  It must not be reachable from any external function.
- **TWO WRITERS, ONE TREE.** Escrow adds `commitment -> 0` permissionlessly (proof-gated); only the
  controller may update to a predicate. One tree with two different access rules is workable but is
  where an access-control mistake would hide.

### 2.13n MERGE LANDED (contract half): IdentityRegistry, with every trap guarded and tested

`contracts/registry/IdentityRegistry.sol` + 16 tests driving the REAL escrow proof through the REAL
verifier into the REAL state keeper. 280 forge tests, 84 pp tests, ABI check clean.

**A SIXTH TRAP, found while writing the contract and NOT on the §2.13m list.** `escrow_envelope`
proves an MRZ hashes to `dg1_hash` and that `holder_root` derives from `sk_identity`. It CANNOT prove
the passport is GENUINE - the ICAO signature chain is verified during REGISTRATION, not escrow. So a
caller could invent an MRZ, produce a perfectly valid escrow proof, and land a commitment in the
identity tree backed by no real document. That would make the tree's scarcity guarantee, and
therefore the entire blacklist, worthless - the exact vacuity §2.13b's trap was about, re-entering
one layer down. Closed by requiring `HolderStateKeeper.holderOfDocumentHash(dg1Hash) == holderRoot`,
which needed a new `dg1Hash -> holderRoot` mapping (`_usedDocumentHash` recorded THAT a hash was
consumed, never BY WHOM). Two tests: unregistered document, and document bound to another holder.

**A SEVENTH, found by a failing test.** `isValidRoot(bytes32(0))` returned TRUE: the empty tree's
root IS zero and the constructor records it. Harmless in practice - an inclusion path always ends at
a non-zero leaf hash, so nothing can be proven against an empty root - but `State.sol::_isKnownRoot`
already rejects zero and the two must not disagree about what a zero root means. Now rejected
explicitly.

**All six earlier traps are guarded AND pinned by a test that fails if the guard is removed:**

| trap | guard | test |
|---|---|---|
| root expiry mandatory (merged tree does BOTH jobs) | `isValidRoot` MAX_ROOT_AGE + always-valid-latest | `test_ASupersededCleanRootExpires`, `test_LatestRootIsAlwaysValidHoweverOld` |
| zero predicate = revoke-into-clean | rejected in `revoke` AND at deploy | `test_RevokeRejectsAZeroPredicate`, `test_ConstructorRejectsAZeroPredicate` |
| `remove` = censorship by erasure | never called; no external path | `test_ThereIsNoRemovalPath` |
| two writers on one tree | `register` proof-gated, `revoke` controller-only | `test_RevokeRevertsForNonController` |
| duplicate / re-add resets a revocation | `registered` mapping + SMT `KeyAlreadyExists` | `test_RegisterRevertsOnDuplicate`, `test_RevokedCommitmentCannotBeReAdded` |
| unreadable envelope = unrevocable identity | controller key pinned as immutable | `test_RegisterRevertsOnAForeignControllerKey` |

**`test_ConstructorRejectsAZeroPredicate` needed try/catch**, not `vm.expectRevert` - forge does not
reliably match a revert raised inside CREATE, and reports "did not revert" even when the guard is
working. Same trap hit earlier this project; noted so the next CREATE-guard test does not rediscover it.

**Integration verified end-to-end, not argued:** on-chain `add(key, 0)` produces EXACTLY the root the
Noir gadget computes (`test_ZeroValueLeafMatchesTheCircuitRoot`), a zero-valued leaf is
distinguishable from an empty tree, and revocation's `update` (0 -> predicate) yields the expected
leaf hash.

**STILL TO DO for the 43%:** the `withdraw_identity` circuit rewrite itself (one SMT inclusion, no
`sk_identity`), regenerated fixtures + verifier, `ProofLib`/`PrivacyPool`/`IState` public-input
changes (9 -> 7), and the wallet. The contract half is what landed here.

### 2.5 Provably rule-bound revocation (after §2.3 — circuit work)

Deliberately after the toolchain settles, so verifiers aren't regenerated twice.

**Goal:** make "we cannot remove you arbitrarily" a *provable* property. A revocation is valid only
if it cites a provable predicate from a closed set, **and that is the only way to block a
withdrawal**. Both clauses are load-bearing.

Two predicates, both checkable with machinery already built:
1. **Identity invalid** — `HolderStateKeeper` already has `enum DocStatus { None, Current,
   Superseded, Revoked }`. Cite it with a proof the status is not `Current`. Zero discretion.
2. **Listed on an anchored external authority (OFAC SDN)** — `RegistrySourceAnchor` is
   `registryId`-keyed by design and its CRE workflow uses `ConsensusIdenticalAggregation` (every DON
   node fetches independently and must agree byte-for-byte). **No new contract** — a second CRE
   workflow and a new `registryId`.

**New work:** `RevocationRegistry.sol` (append-only, unowned, non-upgradeable — same rationale as
the deleted `IdentityAspLeafRegistry`: its value is that nobody can rewrite it); an **SMT exclusion
gadget** in Noir (`lean_imt` cannot express absence; `noir_dl_lib/src/smt.nr` is a circomlib
`SMTVerifier` port that is **inclusion-only**, missing `fnc`/`oldKey`/`oldValue`/`isOld0` — the one
real cryptographic addition, differential-test it); a `revocation_root` public input on
`withdraw_identity`; and the OFAC CRE workflow.

**Predicate-set governance — DECIDED: immutable at deploy.** Constructor params, no setter, no
owner, no upgrade path. An owner-mutable set moves discretion up a level rather than removing it.
Combined with the append-only ASP tree this spends **less** governance than upstream PP — the
postman survives but is admit-only.

✅ **Anchor liveness — DECIDED AND IMPLEMENTED: fail-open.** See §2.5a. The latest revocation root
never expires, so inaction can never block a withdrawal.

✅ **The negative invariant — ESTABLISHED.** `test_NoGovernanceLeverCanBlockAWithdrawal` and
`test_TheOnlyThirdPartyGateIsTheNonUpgradeableRegistry`. `withdraw()` reverts on exactly seven
conditions; six are the caller's own doing (wrong processooor, context mismatch, tree depth, stale
state root, bad proof, spent nullifier) and the seventh is the ASP membership check — now served by
a contract with **no owner and no upgrade path**. The only governance action reachable on a live
pool is `windDown`, and it is proven NOT to block withdrawals: a wound-down pool still pays out a
valid proof, so "wind the pool down" cannot trap existing depositors.

✅ **`revocation_root` IS WIRED — sec. 2.5 is complete apart from the OFAC feed below.**
`withdraw_identity` carries a 9th public input and proves NON-INCLUSION of its own
`membership.holder_root` (not a free input — letting the prover choose the key would make the check
vacuous). `PrivacyPool` validates the root with `RevocationRegistry.isValidRoot`, holding the
registry `immutable` and direct, so nothing upgradeable sits between the pool and a set that can
block a withdrawal. EIP-170 held exactly as measured: **24,491 bytes, 85 spare.**

Proven, not assumed:
- `test_RevocationEventuallyInvalidatesAnOldProof` — a revocation supersedes the empty root, and
  after `MAX_ROOT_AGE` the committed proof **stops working**. Revocation actually bites.
- `test_CurrentRevocationRootSurvivesTheSameDelay` — the CURRENT root still works after ten years,
  so expiry is not a liveness failure.
- `test_exclusion_against_the_empty_tree` (pp) — a fresh registry has root 0 and every identity can
  prove absence against it, so the system can bootstrap. Without this, no withdrawal would be
  possible until somebody had been revoked.

✅ **OFAC CRE workflow — WRITTEN AND COMPILING** (`backend/cre/ofac_sdn/`). Cron-triggered fetch of
Treasury's SDN export, parsed to a leaf set, keccak Merkle root anchored via
`RegistrySourceAnchor.publishSnapshot` under `keccak256("OFAC_SDN")`. Deliberately a structural
sibling of `notary_registry` rather than a second shape. `GOOS=wasip1 GOARCH=wasm go build` passes
for both.

An earlier note called this "external infrastructure, not code in this repo" — **that was wrong**;
only *running* it needs a deployed DON.

**⚠ IT ANCHORS THE LIST; IT CANNOT REVOKE ANYONE, AND THAT GAP IS A DESIGN QUESTION, NOT A TODO.**
The missing step is the link from "person P is on the list" to "holderRoot H belongs to P". That
mapping does not exist on-chain **by construction** — a holderRoot revealing nothing about its owner
is the entire point of the identity ASP. Only whoever performed the original identity check holds
that correspondence, so any mechanism resolving it must answer: **who may learn that holderRoot H is
person P, and what stops them asserting it falsely?** Left open deliberately rather than papered
over. Anchoring the list is safe and useful on its own; revoking on it is not, until that is
answered.

The remaining shape is an attester CONTRACT (never an EOA — §2.5a) holding the sanctions predicate,
accepting a proof that an identity is in the anchored set. Two other operator items are recorded in
the workflow header: the exact SDN export URL, and granting `REGISTRY_POSTMAN` to the address
`WriteReport` resolves to. The XML schema follows Treasury's documented `sdnList`/`sdnEntry` shape
but is **unverified against a real download** — the same caveat `notary_registry` carries.

### 2.5a Upgradeability audit + the root-staleness bug (2026-07-27)

**A DESIGN BUG WAS FOUND AND FIXED IN `RevocationRegistry` BEFORE IT SHIPPED.** The first version
marked every root known FOREVER, by analogy with the append-only ASP tree in `Entrypoint`. **The
analogy is inverted:**

| tree | proves | append-only means an older root has... | accepting old roots |
|---|---|---|---|
| ASP | **inclusion** | fewer MEMBERS | safe - can only fail to admit |
| Revocation | **NON-inclusion** | fewer **REVOCATIONS** | **evades every revocation since** |

Under the old behaviour a revoked identity could prove absence against the **empty initial root**
forever and revocation would have been a total no-op. Fixed: a root is valid only while it is the
**latest** or younger than an immutable `MAX_ROOT_AGE`. `test_StaleRootStopsBeingValid_...` is the
regression test. **Do not re-derive the old behaviour from the Entrypoint precedent.**

**NO CENSORSHIP THROUGH INACTION - DECIDED AND IMPLEMENTED (user, 2026-07-27).** The latest root is
**always** valid regardless of age. A pure age check would have been fail-CLOSED: the newest root
would age out, every withdrawal would halt, and an operator could censor by doing nothing.
`test_LatestRootNeverExpires_NoCensorshipByInaction` warps a decade forward and asserts withdrawals
still work. The grace window on superseded roots exists so an in-flight proof is not killed by
someone else's revocation landing first - without it, an attester could censor by revoking an
unrelated identity to invalidate everyone's pending proofs.

✅ **DONE 2026-07-27 — the ASP tree moved to `contracts/registry/IdentityAspRegistry.sol`.**
Non-upgradeable (not a proxy), unowned (no roles, no admin), postman fixed at construction,
append-only. `test_NoRolesNoOwnerNoUpgradeNoRemove` asserts against the ABI that `grantRole`,
`owner`, `upgradeToAndCall`, `initialize` and `remove` DO NOT EXIST.

**A PASS-THROUGH WOULD NOT HAVE FIXED IT — this is the part worth remembering.** Leaving
`isKnownAspRoot` on `Entrypoint` to delegate to the registry preserves the entire hole: `PrivacyPool`
would still be asking an UPGRADEABLE contract whether a root is genuine, and an upgraded Entrypoint
could simply lie. So `PrivacyPool` takes the registry as a constructor argument and holds it
`immutable`; the Entrypoint is out of the ASP trust path completely, and stays upgradeable only for
asset config and routing where that is legitimate.

**Root policy differs from `RevocationRegistry` ON PURPOSE.** This tree accepts EVERY historical
root, forever — correct here, because it proves INCLUSION and only grows, so an old root's member
set is a strict subset and can never wrongly admit. That is exactly what removes the operator's
retroactive lever. The same policy in `RevocationRegistry` was fatal (see above). Same structure,
opposite direction of use.

**Cost, and the mitigation:** the postman cannot be rotated. Deploy it as a CONTRACT
(multisig/threshold), never an EOA — the registry only checks `msg.sender` and a signature, so an
attester contract rotates its own keys while the registry stays immutable.

**Free because nothing is deployed** — `App.tsx` still holds zero addresses and there is no
`broadcast/` directory, so there was no migration to pay for. That was the deciding factor.

**⚠ ORIGINAL FINDING, now resolved — kept because the reasoning generalises:**
`_authorizeUpgrade` is `onlyRole(_OWNER_ROLE)`, and `_OWNER_ROLE` also administers `_ASP_POSTMAN`
and `DEFAULT_ADMIN_ROLE`. §2.13 says the append-only ASP tree means "the postman can no longer drop
an existing member" — true of the postman, **but the OWNER can upgrade the implementation and
rewrite the tree wholesale.** So the honest statement is "append-only *unless the owner upgrades*",
not "append-only by construction". This is inherited from upstream PP, not introduced here.
**The principled fix is to move the ASP tree into its own non-upgradeable registry**, exactly as
`RevocationRegistry` is — leaving `Entrypoint` upgradeable for asset config and routing, where
upgradeability is legitimate. Not done; it is a real refactor and it changes a deployed interface.
`TitleLedger` and `RegistrySourceAnchor` are also `onlyRole(OWNER_ROLE)`-upgradeable; for those it
is defensible, since neither claims an immutability property the way the ASP tree does.

**HIDDEN COST OF IMMUTABILITY, and the mitigation that makes it acceptable.** A `RevocationRegistry`
attester cannot be rotated — there is no owner and no upgrade, so **a compromised attester key can
revoke arbitrarily forever**. In that one failure mode an immutable registry is WORSE than an
upgradeable one. **Deploy attesters as CONTRACTS (multisig/threshold), never EOAs**: the registry
only checks `msg.sender`, so an attester contract can rotate its own keys internally while the
registry stays immutable. Deploying with EOA attesters is the trap.

**`curve_384.nr` IS BRAINPOOL P384R1, NOT secp384r1 — but it is NOT a live trap.** Checked: nothing
imports `curve_384::` anywhere; it is orphaned (same class as the deleted `bitcoin.nr` /
`recursion.nr`). The circuits that really do verify these curves use `sigver::ecdsa`'s
`verify_secp384r1_ecdsa` (genuine secp384r1 via `big_curve::curves::secp384r1`) and
`verify_brainpoolp384r1_ecdsa` — separate, correct code paths. `curve_192::ecdsa_ver` and
`curve_224::ecdsa_ver` ARE live (used by `not_passports_zk_circuits.nr`) and are now
differential-tested. **Delete or rename `curve_384.nr`** so nobody wires it up expecting secp384r1.

### 2.5b ✅ Ragequit ported to Noir — the correctness hole is CLOSED (2026-07-27)

**The hole:** `PrivacyPool.ragequit` and a Groth16 `CommitmentVerifier.sol` were both inherited from
upstream PP, but **no circuit source for it existed anywhere in this repo**. No ragequit proof could
be produced at all. That was a correctness hole, not a missing feature: ragequit is the ONLY exit
for a depositor the ASP declines to admit, since withdrawal requires membership — so a rejected
depositor could neither withdraw nor reclaim, and §2.13's argument that admission cannot become a
trap rested on an exit that did not exist.

**Fixed by porting to Noir** (`backend/circuits/ragequit`) rather than vendoring circom + snarkjs,
so the fusion stays on ONE proving stack. The alternative meant a second toolchain to pin, audit and
keep working for ~15 lines of constraints. `ProofLib.RagequitProof` is now `bytes proof` +
`uint256[4] pubSignals`; **the signals and their order are unchanged**, so every accessor reads the
same slot it did before.

The circuit asserts BOTH halves of `commitment_hasher` — commitment AND nullifier hash — and each
matters for a different attack, tested as such:
- `test_RejectsInflatedValue` — the pool pays out `pubSignals[2]` directly, so a prover who could
  raise `value` while keeping a valid commitment would drain it. Value is bound into the commitment.
- `test_RejectsTamperedNullifierHash` — the pool spends `pubSignals[1]`; unbound, one note could be
  reclaimed repeatedly under different nullifiers.

`RagequitHonkVerifier` is **24,489 bytes, 87 spare** under EIP-170, and needs its own
`optimizer_runs = 1` entry like the other two.

**Still wallet-side work:** assembling the ragequit witness and calling `ragequit()`. The circuit,
verifier and contract path all work; `discovery.ts` still only READS `Ragequit` events.

### 2.6 NFC passport scanning

Not implemented anywhere in the wallet — the README flags it and no NFC code exists in `src/`.
Without it a `RarimePassport` cannot be populated from a real passport, so registration and query
proofs must be fed hand-constructed test data. **Load-bearing for the wallet ever working on a real
device.**

### 2.7 iran-constitutional-monarchy identity swap (LAST)

Cloned at `../iran-constitutional-monarchy`. It **stubs** our identity work rather than competing:
`PassportBallot.circom` says so ("Simplified passport verification circuit for POC", outputs "23
signals, matching PublicSignalsBuilder layout" — *our* layout), hardcodes 9 of 23 outputs to zero,
and **never verifies a real passport** — EdDSA over Baby Jubjub with a mock CSCA key.
`IIdentityVerifier.sol` states outright: *"In production, this would be implemented by a ZK proof
verifier (e.g., Rarimo Freedom Tool)."*

**`AQueryProofExecutor` is already dual-stack** (`execute` for Circom Groth16, `executeNoir` for
Noir, over one `PublicSignalsBuilder`), so they can adopt our real ICAO verification **without
abandoning Groth16**.

Last because it consumes `query_identity` / `register_identity` / `PublicSignalsBuilder` as a
downstream client — exporting before §2.5 lands would ship an interface about to change. It is also
the only item in a repo we do not own.

**One-way:** our title/notary machinery must NOT move there. Their `provinceId` ("assigned by CSCA
at registration") has no passport equivalent and needs its own home regardless.

---

## 3. Parallel work — not blocked

- ✅ **Denomination splitting — DONE 2026-07-27** (`src/pp/deposit.ts`). This turned out to be TWO
  gaps: the wallet had **no deposit path at all** — it could discover, prove and withdraw, but never
  create a note. Splitting is the DEFAULT, not an option, since a wallet that quietly deposits
  3.7314 ETH as one note has already lost the anonymity the pool provides. `allowRemainder` defaults
  to **false**: an inexpressible amount raises rather than silently emitting a uniquely-sized note,
  which would be a fingerprint on both deposit and withdrawal.
  **Honest limit:** the MULTISET still leaks — 1 + 0.1 + 0.1 is less distinctive than 1.3, but not
  nothing. Real fixed-denomination pools refuse non-multiples outright; that is what the default
  approximates. Deposits are submitted SEQUENTIALLY because `label` derives from an incrementing
  pool nonce, so concurrent sends would leave the wallet unable to attribute labels; a partial
  failure is reported rather than swallowed, since retrying blind would reuse a spent
  precommitment (`Entrypoint.usedPrecommitments`) and revert. Costs more deposit gas, which is an
  argument for fixing withdrawal gas (§2.4), not against splitting.
- **ERC-4337 paymaster** so the user never holds ETH. **NOT yield-funded** — see sec. 2.4c: yield
  belongs to depositors, not to a subsidy pool. Fund it from relay fees or protocol revenue.
- **Stealth-address withdrawals (ERC-5564)** — removes the "withdraw to a fresh address you must
  fund" problem at the root instead of routing around it via relayers.
- **Measure mobile proving time** — feeds §2.2.
- **Wire the stables leg of the SPV adapter.** `ISpvBasket` is declared but `SpvTreasuryAdapter` has
  no `BASKET` immutable — only ETH/Vogue exists. **Confirm the intended stablecoin is in SPV's
  deploy-time basket whitelist (`Aux.toIndex`) first** — an arbitrary ERC20 reverts.
- **Batch admission** — a postman admitting K identities per transaction saves per-tx base cost,
  though Poseidon hashing dominates. Modest (~5%).
- **`App.tsx` CONFIG holds literal zero addresses** for `stateKeeper` / `registerSimpleContract` /
  `poseidonSmt` / `holderRegistration` — the exact file to edit the moment anything deploys.
- **No backend endpoint produces a revocation signature** — `revokeDocument` takes it as a manual
  external input.
- **ECDSA (8) Noir suites in the rarime tree have never been run** — deferred as a cost issue,
  suited to a CI job. (The recursive-proof suites are gone: `recursion.nr` and `bitcoin.nr` were
  both deleted as orphaned dead code, so there is nothing left to run there.)
- **Unverified:** whether the repeated-biometric-prompt UX fix landed in `root.ts`.
- **Efficiency backlog:** Poseidon2 uniform swap, tree-depth tuning, public-input packing,
  shared-SRS reuse.

---

### 3a. Test-coverage inventory — what is untested, and whose it is (2026-07-27)

**Every contract in OUR fusion surface, and every one inherited from PP/0xbow, is now tested.** The
PP lineage is exactly five contracts — `PrivacyPool`, `State`, `Entrypoint`, `PrivacyPoolSimple`,
`PrivacyPoolComplex` — and the last of those had NO tests at all until today despite its constructor
changing twice in one day.

**Progress 2026-07-27: the crypto primitives are done — SHA1/SHA384/SHA512 and Date2Time are now
differential-tested** against Python `hashlib` / `calendar.timegm`, with the padding boundaries
(111/112/128 bytes) and leap years (2024 yes, 2100 no) that hand-rolled implementations get wrong.
All correct. **RSA, Bytes2Poseidon and BOTH PublicSignals builders followed — 22 remain.**

The builders were the highest-risk of the set: 23 and 24 signals written by hand-computed assembly
offsets (`mstore(add(ptr, 544), x)`) straight into the array a verifier consumes. A wrong offset
does not revert — it writes the wrong slot AND clobbers whichever signal really lives there. Every
index in both is now pinned with a distinct sentinel and read back as a whole array, so a COLLISION
is visible (a per-field test cannot see one — a clobber needs two fields observed together).

**TD1 is not TD3-plus-a-field.** 24 signals vs 23, and the layout genuinely differs: TD1 carries
birthDate / expirationDate / documentNumberHash / personalNumberHash / documentType as signals of
their own, shifting nearly everything after index 3. `nationality` is index 4 in TD1 and 5 in TD3.
Using the wrong builder compiles, runs, and produces a plausible-but-wrong array — the same TD1/TD3
trap that made the SDK's MRZ parser read passports at ID-card offsets.
`test_td1AndTd3LayoutsGenuinelyDiffer` pins the divergence so a future "simplification" cannot merge
them.

`PublicSignalsBuilder` was the highest-risk file of the set: 23 signals written by hand-computed
assembly offsets (`mstore(add(ptr, 544), x)`) straight into the array a verifier consumes. A wrong
offset does not revert — it writes the wrong slot AND clobbers whichever signal really lives there.
Every index is now pinned with a distinct sentinel, read back as a whole array so a COLLISION is
visible (a per-field test cannot see one, since a clobber needs two fields observed together). All
23 correct, and the constructor's ZERO_DATE seeding is pinned too — unset dates must not read as
0000-00-00.

`RSA.decrypt` is the 0x05 modexp plumbing every passport signature check runs through; verified
against an independently generated vector (Miller-Rabin primes, `s = m^d mod n`), including that a
tampered signature does NOT recover the message and that the output is exactly modulus-length — a
short buffer would misalign every subsequent digest read.

`Bytes2Poseidon.hash512` **discards the top byte of each 32-byte word** (`mod 2**248`, to fit
BN254's field), so inputs differing only there hash identically. Not a bug — a 256-bit word cannot
be a field element — but it means this is not collision-resistant over arbitrary 64 bytes, and it
must match whatever the circuit does or on-chain and in-circuit commitments diverge. Pinned, along
with the complement: every OTHER byte does affect the hash.

`Date2Time`'s `+2000` looked like a bug — a two-digit year always decodes as 20xx, so a 1974 birth
date would become 2074 — but it is only ever applied to `currentDate`, where it is right. Birth
dates never reach it: they stay encoded as bounds and are compared in-circuit.
`test_TwoDigitYearIsAlways20xx` pins that so the function is not later reused where it does not
belong.

**26 contracts remain untested, ALL of them rarime's passport stack**, not PP's and not ours:
`certificate/` dispatchers and signers, `utils/SHA1|SHA384|SHA512|RSA|Date2Time|Bytes2Poseidon`,
`registration/Registration2`, `sdk/PublicSignals*Builder`, `state/L1RegistrationState`,
`RegistrationSMTReplicator`.

**This is a DECISION, not an oversight.** They are vendored upstream code on the passport path, and
several (the SHA and RSA primitives especially) are the kind of thing that wants differential
testing against reference vectors rather than a smoke test — the same treatment `smt.nr` and the
curve gadgets got. That is real work and should be scoped deliberately. What matters is that the
line is now drawn explicitly: nothing of ours is untested, and this list is the exact remainder.

**Deleted rather than left looking healthy:** `WithdrawalVerifier.sol` and `CommitmentVerifier.sol`
(the superseded Groth16 verifiers — unreferenced after the Honk ports, and a stale verifier that
still compiles is a deployment hazard), plus `VerifierMock`/`FailingVerifierMock`, which nothing
instantiated once the proof paths moved to real verifiers, and a dead Groth16 `IVerifier` import in
`State.sol` implying a Groth16 path that no longer exists.

## 4. Decisions someone has to make

- **The ASP retroactive lever.** `PrivacyPool` now accepts any historical ASP root, safe *only*
  because the tree is append-only by construction. The same change under the old
  operator-published-root design would have been catastrophic — it would have re-admitted everyone
  ever removed and made removal a global no-op. **Accepting historical roots and predicate-bound
  revocation (§2.5) compose; either alone is broken.**
- **Single-seed SPOF — no recovery path.** One device seed derives both `sk_identity` and PP note
  keys; losing the device loses everything. `unforgettable-sdk` was evaluated and rejected
  (deepfake/liveness, four unanswered vendor questions). Deserves a native design pass. **Genuine
  product decision, not one to make unilaterally.**
- **Notary-to-address binding.** `bindNotaryAddress` is authorization-consistent but does not
  establish *how* a real notary proves identity. Ukraine's register verifies licensure only, not
  individual identity (that goes through Diia/BankID). A UK-solicitor-multisig PoA model was raised
  with unresolved cross-jurisdiction questions — **needs real counsel, not engineering.** Concrete
  suggestion from `TITLE-LEDGER-DESIGN.md`: reuse the passport flow for the notary's own identity,
  cross-checked by registration number against the registry.
- **Rarimo interop:** must this fork interoperate with the *live* Rarimo protocol (forces
  circomlib-Poseidon) or is it self-contained (Poseidon2-everywhere becomes possible)? Unresolved,
  and it gates the efficiency backlog.
- **PP SDK interop:** does byte-identical interop with the official Privacy Pools SDK matter, or is
  self-consistency enough? Related: `privkey % FIELD` in `notes.ts` is justified "by construction"
  but never checked against their real SDK output.
- **Test scope:** should the PP core Forge suite cover ERC20 (`PrivacyPoolComplex`) and `ragequit`?
  Currently only ASP-anchor-specific tests exist.

---

## 5. Blocked externally

- **SPV mainnet deployment.** `SpvTreasuryAdapter`'s immutable constructor params need real
  `Vogue`/`Basket` addresses. SPV has not deployed and has not picked a chain. When it does:
  re-verify `Vogue.deposit/withdraw` and `Basket.mint` signatures immediately before wiring (they
  matched at HEAD on 2026-07-26, but SPV commits daily), deploy `AaveCreditLine` with real Aave
  Pool/WETH addresses, and size the buffer/sweep/backstop parameters (still placeholder defaults:
  1 hour, 50%).
- **Android build** — no JDK/SDK/NDK here. `RnNoirModule.kt`'s `proveHonk` and `app.plugin.js`'s AAR
  path resolution have never been Gradle-built.

---

## 6. Parked — do not re-litigate without a reason

- **Card/BaaS/Rain/Baanx/EMI/KYC/MiCA/GENIUS compliance thread** — paused. Lives in
  `COMPLIANCE-THESIS.md` / `IDENTITY-COMPLIANCE-CARD-TODO.md` / `legal.md`. Includes abandoned
  money-transmitter research: `COMPLIANCE-THESIS.md` asserts the fleet/family-plan model "dissolves
  the large-purchase question" re: FinCEN 31 CFR 1010.100(ff)(5) — **treat that claim as
  unconfirmed** if the thread resumes.
- **EUDI Wallet Core native binding** — dropped as a hard dependency; format gap never resolved.
- **AirGap two-device / Knox provisioning** — dropped, would have been fully bespoke.
- **unforgettable-sdk** — dropped (deepfake/liveness). Still on disk, unused.
- **ILP / Interledger** — grant-funded side bet, not core roadmap.
- **Identity-bound PP withdrawal** — proposed then retracted; compliance is the wrong layer. The
  *soft* version (recovery-only label, never a withdrawal gate) stays a backlog idea.
- **companion/, vault/, qr-protocol/** — stale AirGap/card scaffolding, kept as reference.
- **Optimistic verification** — investigated, set aside. It does NOT trade away cryptographic
  soundness (the proof stays cryptographic, just verified lazily); it trades *immediate* finality
  plus a "≥1 honest challenger" assumption. Killed by two things: **a value cap is the only bound on
  worst-case loss** — without the chain checking the math, an unchallenged invalid proof withdraws
  whatever it claims — and **a bond does not fix it**, since an unchallenged theft returns the bond
  anyway. The bond must also come from a funded address, which is the linkage the pool exists to
  prevent.
- **EigenLayer AVS / Aligned Layer** — Aligned's verification layer is ~40k gas amortised but
  restaking-backed ("soft finality") and **does not support Noir/UltraHonk**; its aggregation service
  has real L1 finality but is ~300k gas and also lacks Honk. Both make our core cost structure depend
  on someone else's roadmap. SPV's own §W AVS anchors on the dead-man broadcaster for *liveness*, a
  different problem, and its docs warn against forcing other components in.
- **zkVerify** — a separate Substrate chain; Ethereum settlement needs its consensus **plus an
  authorized relayer plus a bridge**. Too much trust for a value-bearing pool. Ruled out ("no
  substrate").

---

## 7. Facts that will cost you time if you don't know them

**Toolchain traps — every one initially looked like success:**
- **`bb 1.2.0` + nargo beta.1 fails SILENTLY.** `bb prove` exits 0 and writes a proof that **bb's own
  `bb verify` rejects** ("Sumcheck failed!"). Anyone evaluating a bump by "did prove succeed?" ships
  a broken system. **Always run native `bb verify`.**
- **`--zk` is silently ignored under `--honk_recursion` on bb ≤ 0.87.0.** Two runs on one witness
  give byte-identical proofs — conclusive that ZK is off. Fixed on the 1.x line, where the flag
  inverted to `--disable_zk` (ZK now default). **Always run a two-run determinism check**, and clear
  output dirs between runs — comparing stale files once produced a false negative here.
- **Never judge a toolchain by `grep -c "^error"`.** nargo reports an ICE as a *panic*, so a crash
  that wrote no artifact reads as "0 errors". **Check the exit code AND that the artifact exists.**
- **`--oracle_hash keccak` is mandatory** for standalone on-chain verification; the default poseidon2
  transcript is for in-circuit recursive verification and its proofs revert `SumcheckFailed()`
  against generated Solidity.
- **nargo rejects non-ASCII in comments** — a `§` character breaks `nargo test` outright.

**Solidity / EVM:**
- **Higher `optimizer_runs` produces MORE bytecode**, not less. The ZK verifiers are ~24.5KB against
  EIP-170's 24,576; `optimizer_runs = 1` is scoped to the two verifier files via
  `compilation_restrictions` + `additional_compiler_profiles`, buying 1,007 bytes of headroom for
  +0.6% gas. **`via_ir` is deliberately NOT enabled.**
- **Verifier gas ≈ 2.38M + 3,510 × (public inputs). Circuit size is essentially free.** The
  irreducible precompile floor is ~568k (74 ecMul + ecPairing) — which alone exceeds UltraPlonk's
  entire 385k verification, so optimising UltraHonk cannot close that gap.
- **`bb` emits every generated contract as `HonkVerifier`**, and the ZK flavour declares it
  ` contract HonkVerifier is IVerifier {` (leading space) vs non-ZK `is BaseHonkVerifier`. The
  codegen rename handles both and hard-fails rather than silently leaving it unrenamed.

**Silent truncation — swept 2026-07-27, one real bug found:**
- **FIXED: JS `1 << v` in `Freedomtool.ts` vote masks.** JS number bitwise coerces to **int32**, so
  option 31 produced a NEGATIVE mask and option 32 silently wrapped to `1` — a vote for option 32
  encoded as a vote for option 0, with no error anywhere. Now `1n << BigInt(v)`. Every other bitmask
  in the codebase already used BigInt; these two sites were the exceptions. **Relevant to §2.7: the
  iran repo is a voting system.**
- **Checked and safe:** Solidity's flagged `unsafe-typecast` sites (`PoseidonSMT` tree height,
  `StateKeeper` expiration) each have an explicit `require(x <= type(uintN).max)` immediately
  before the cast. Noir casts in the PP circuits are `u1`/`bool` → `Field`, i.e. widening.
  `Number(...)` on timestamps/enums is within 2^53.
- **Safe only by contract enforcement:** `state_tree_depth as u32` / `asp_tree_depth as u32` in
  `withdraw_identity` truncate, and the circuit does not care (the value is used only in a bound
  assert, never in root computation). `PrivacyPool` rejects out-of-range depths using the full
  `uint256`. See §2.4 constraint 5 — this must be replicated by any other verifier.

**Client ↔ contract:**
- **ethers ABIs are plain strings, so `tsc` cannot check them against Solidity.** Removing
  `Entrypoint.updateRoot` left `identityAsp.ts` broken with **both** `forge build` and
  `tsc --strict` fully green. **Run `tools/check-client-abis.py` after any contract change.**
- **Do NOT index `_precommitmentHash`** to speed up note discovery. Exact-match queries tell your RPC
  provider which notes are yours. `PrivacyPool.PRECOMMITMENT_BUCKETS = 256` exists so wallets query a
  coarse bucket shared with many unrelated users; `scanAllBuckets` opts back into full scanning.

**Architecture:**
- **SPV coupling is one-way.** SPV's repo must contain **zero** references to PP; ibiza declares local
  interface stubs instead. Sharing *operators* is free (the batcher and any watcher can run on the
  same fleet); sharing a *repo* breaks the invariant. Batcher code lives in ibiza.
- **`Basket.mint`'s token acceptance is a hard deploy-time whitelist** (`Aux.toIndex`), even though
  its access control is permissionless.
- **`Entrypoint` storage layout changed** when the ASP tree moved on-chain. Harmless now (nothing
  deployed) but it is UUPS — once deployed, a change of that shape needs a migration, not an upgrade.
- **The identity-keyed ASP has a larger blast radius than upstream's label-keyed one:** revoking one
  identity blocks **every** note it holds, across every deposit.
