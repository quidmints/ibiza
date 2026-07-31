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

### 2.13o REVERTED: the JS sparse Merkle tree. ASK THE CONTRACT (user, 2026-07-28)

I hit the merge's blocker - no TS/JS SparseMerkleTree exists in this repo - by ADDING one
(`@zk-kit/smt` + `postman/identityTree.ts`), then wrote a three-way validation
(`tools/check-identity-tree.js`) against circomlibjs, solarity and the Noir gadget to manage the
divergence risk. All 8 checks passed. **All of it is removed.**

**`revocation.ts` had already decided this, in a header I did not read before writing the mirror:**

> NO LOCAL TREE MIRROR, DELIBERATELY. stateTree.ts and identityAsp.ts both rebuild their trees
> off-chain because those are LeanIMTs whose contracts expose only a root - a membership path cannot
> be read out of contract storage, so the wallet has no choice. The revocation registry is
> different: it is a `@solarity` SparseMerkleTree, and `getProof(key)` is a VIEW FUNCTION that
> returns the whole witness. Rebuilding it locally would mean writing a second implementation of a
> sparse trie and keeping it byte-compatible forever, for no benefit. Asking the contract is both
> less code and IMPOSSIBLE TO DRIFT.

The validation passing did not make the mirror worth keeping - it was managing a risk that asking
the contract does not have. `getProof` is a view function on the identity registry too.

**`pp/identityProof.ts` replaces `pp/revocation.ts`**, fetching the INCLUSION witness from
`IdentityRegistry.getProof` and distinguishing each failure where the diagnostic still exists: not
registered (post the escrow envelope first), REVOKED under a named predicate, tree/mapping
disagreement (a contract bug), path deeper than the circuit. `withdrawWitness.ts` now takes that
witness plus `revocationSecret` and drops `skIdentity`/`aspTree` entirely - the assembler's 17
emitted input names match the circuit's parameters exactly.

**Consequence for fixtures:** the generator cannot build the tree in JS either, so it must obtain
the witness the same way - from a deployed registry. A forge script that deploys IdentityRegistry,
registers, calls `getProof` and writes the witness is the remaining piece, and it makes the fixture
provably consistent with the real contract rather than with a second implementation of it.

### 2.13p Fixtures come FROM THE CONTRACT, and the bootstrap order that forces

Following §2.13o's rule (never rebuild the SMT off-chain), the withdrawal fixture's identity witness
cannot be built in JS either. It is emitted by a forge test that drives the REAL registry:
`IdentityRegistry.t.sol::test_EmitIdentityWitnessFixture` registers three identities, calls
`getProof`, and writes `test/fixtures/identity_witness.json`. Generating it inside the suite means it
CANNOT go stale against the contract - a witness built off-chain would only ever prove that two of
our own implementations agree.

**THREE registrations, not one, and there is no shortcut.** A single-leaf SMT has an EMPTY inclusion
path, so a withdrawal built on it would hash NO SIBLINGS and prove nothing about the Merkle path -
the same degeneracy `tools/build-withdrawal-fixture.js` already refuses to emit for the state tree.
The registry admits a commitment ONLY via `register`, which requires a genuine escrow proof; adding
a privileged insert to seed the tree would be exactly the mock this project forbids. So
`tools/build-escrow-fixtures.js` emits three distinct witnesses and all three are proved with bb and
committed (`escrow_envelope{0,1,2}.proof/.public`, all verified).

**A BUG IN MY OWN GENERATOR, caught before it cost anything.** The first run produced three
identities sharing ONE `dg1Hash`: the MRZ varied the passport number via
`String(1234567890 + i).slice(0, 9)`, which truncated the very digit being varied. Because a
document hash may bind to exactly one holder (§2.13f), identities 1 and 2 would have failed to
register with a `DocumentBoundToAnotherHolder` revert far from the cause. Fixed to a nine-digit
number that survives the slice; all three hashes now differ, and `escrow0` still reproduces the
previously committed fixture exactly.

**THE BOOTSTRAP ORDER, because it is circular and not obvious:**
1. escrow witnesses -> bb proofs -> committed (DONE)
2. pool test suites must COMPILE, or the emitter test cannot run at all (3 files: constructor arity
   for the single registry, `pubSignals` 9 -> 7, `ASP_REGISTRY` -> `IDENTITY_REGISTRY`)
3. run the emitter -> `identity_witness.json`
4. `tools/build-withdrawal-fixture.js` consumes it -> withdrawal witness -> bb proof
5. regenerate the withdrawal verifier (7 public inputs) and re-run everything

Steps 2-5 are the remainder. `main` stays green throughout; all of this is on
`wip/identity-tree-merge`.

### 2.13q Rewiring the pool suites: TWO bugs caught that would have shipped silently

Bootstrap step 2 (§2.13p). `PrivacyPoolSimple`/`PrivacyPoolComplex` now build against the single
registry. Both defects below would have COMPILED AND PASSED.

**BUG 1 - the registry was built at the wrong depth.** `IdentityRegistry.t.sol` constructed the tree
with `treeHeight_ = 20` while the circuit is fixed at `IDENTITY_TREE_DEPTH = 32`. Solarity's
`maxDepth` is a CAP, so the ROOT is identical either way and every existing test still passed - which
is exactly why it would have survived. It bites later: a depth-20 registry rejects a deep insert the
depth-32 circuit accepts, and a witness longer than the circuit's fixed sibling array cannot be
padded into one. Now a named constant with the agreement spelled out.

**BUG 2 - a test that would have stopped testing anything.** `MockEntrypoint.isValidRoot` returned
`true` UNCONDITIONALLY. That was sound while it only stood in for the REVOCATION registry: the ASP
root was checked separately through `isKnownAspRoot`, which did honour its `known` mapping, so the
identity gate was still exercised. Under the single tree `isValidRoot` IS the only identity gate, so
an unconditional `true` would have made `test_withdraw_revertsOnInvalidIdentityRoot` pass while
asserting NOTHING. Now honours `known` and rejects the zero root, matching the real registry.

**Slot renumbering, done by reading each site rather than pattern-replacing** - the shift is not
uniform, because a slot was REMOVED from the middle:

| old | new | |
|---|---|---|
| [5] asp_root | [5] identityRoot | same slot, different registry |
| [6] asp_tree_depth | - | gone with the LeanIMT identity tree |
| [7] context | [6] context | **moved** |
| [8] revocation_root | - | merged into [5] |

A blind `[7] -> [6]` would have been wrong for the tests perturbing `[5]`, and a blind shift-by-one
wrong for `[3]`/`[4]`. Every site was read.

**Remaining:** `WithdrawEndToEnd` (18 references to the two old registries) and
`WithdrawalHonkVerifier` both need the REGENERATED withdrawal fixture, which needs the emitter to
run, which needs those files to compile - the circular step from §2.13p. That is the next piece, and
it is deliberately not being rushed: those two suites are the primary guard on the withdrawal path.

### 2.13r INVISIBLE-BUG AUDIT (user: "search for any more invisible bugs like this")

Hunting the CLASSES of the two defects in §2.13q - a mock that silently stops asserting, and a
constant that disagrees across a boundary while every test still passes.

**FOUND AND FIXED - the escrow digest had NO independent check.**
`IdentityRegistry.register` requires `holderOfDocumentHash(dg1_hash) == holder_root`, so the escrow's
`dg1_hash` must equal the one REGISTRATION produced. Nothing verified that: `IdentityRegistry.t.sol`
plants the document using the ESCROW'S OWN `dg1Hash`, so the two could have disagreed - about the
DG1 length, the digest algorithm, or the byte packing - and every test would still have passed while
NO REAL DOCUMENT COULD EVER BE ESCROWED.

I nearly "fixed" it the wrong way. `escrow_envelope` uses `DG1_LEN = 95` while `register_identity`
takes 93, which looked like a straightforward mismatch. It is not: 95 is the ICAO TD1 layout that
`register_identity_light_td1` takes, and the LIGHT circuit is the one actually verified -
`RegistrationSimple._PROOF_SIGNALS_COUNT` is 3, the light circuit's output arity, where the full
`register_identity` returns 5. So 95 is CORRECT, my comment calling it "TD3 (passport)" was wrong,
and changing it to 93 would have BROKEN the working path.
`escrow_envelope::test_dg1_hash_matches_the_registration_circuit` now compares against
`register_identity_light`'s OWN returned value - the only reference that cannot drift with that file.
It passes.

**CHECKED AND CLEAN - constants that must agree across boundaries:**

| constant | contract | circuit | wallet |
|---|---|---|---|
| state tree depth | `State.MAX_TREE_DEPTH` 32 | `state_siblings [Field; 32]` | `stateTree.ts` 32 |
| identity tree depth | `IdentityRegistry.t.sol` 32 | `IDENTITY_TREE_DEPTH` 32 | `identityProof.ts` 32 |
| escrow public inputs | `PUBLIC_INPUT_COUNT` 12 | 12 | codegen target 12 |

**FOUND - dead inheritance in live contract code.** `Entrypoint` inherits AND initializes
`EIP712Upgradeable`, with an init comment describing `admitIdentityWithAuthorization` - a function
that no longer exists there (it moved to IdentityAspRegistry in §2.5a). There is no
`_hashTypedDataV4`, no typehash and no signature recovery anywhere in the contract. Costs bytecode
and misleads about what the contract does. Removal is layout-safe under OZ 5's ERC-7201 namespaced
storage, but it is an inheritance change to an UPGRADEABLE contract, so it belongs in the merge's
deletion pass rather than being slipped in mid-rewire.

**FOUND - `MinimalEntrypoint.isKnownAspRoot`** in PrivacyPoolComplex.t.sol is now unreachable: the
pool no longer calls it. Its sibling `isValidRoot` returning an unconditional `true` is FINE there,
unlike the Simple case in §2.13q, because that suite has no withdraw tests at all - checked, not
assumed.

**ORPHANED BY THE MERGE, to delete once WithdrawEndToEnd is rewired:** `IdentityAspRegistry` +
`IIdentityAspRegistry` + its test, `RevocationRegistry` + `IRevocationRegistry` + its test, and the
wallet's `postman/identityAsp.ts`. Listing them now so the deletion is deliberate rather than
discovered later by a dead-symbol scan.

### 2.13s SETTLED: Entrypoint no longer inherits EIP712Upgradeable (user, 2026-07-28)

*"if you are using none of it dont inherit it"*. `Entrypoint` inherited AND initialized
`EIP712Upgradeable` while containing no `_hashTypedDataV4`, no typehash and no signature recovery -
left over from when `admitIdentityWithAuthorization` lived there, before §2.5a moved it to
IdentityAspRegistry. The init comment still described that function.

**Storage safety VERIFIED, not argued.** Removing an inherited contract from an UPGRADEABLE
contract is the one way this could go badly, so it was checked with `forge inspect Entrypoint
storage-layout` before and after:

    before: scopeToPool@0, assetConfig@1, usedPrecommitments@2, EVIDENCE_REGISTRY@3
    after:  scopeToPool@0, assetConfig@1, usedPrecommitments@2, EVIDENCE_REGISTRY@3

BYTE-IDENTICAL, because OZ 5 puts EIP712's state in an ERC-7201 NAMESPACED slot
(`EIP712StorageLocation = 0xa16a46d9...`) rather than in the sequential layout. Had it used
sequential storage, this removal would have shifted every variable after it and silently corrupted a
deployed proxy - which is precisely why it was measured rather than reasoned about.

Also removed `MinimalEntrypoint.isKnownAspRoot` (PrivacyPoolComplex.t.sol), unreachable since the
pool stopped calling it. Its sibling `isValidRoot` returning unconditional `true` is documented as
deliberate there: that suite has no withdraw tests, so the identity gate is never under test - the
opposite of the Simple case in §2.13q, which did need to honour its `known` mapping.

### 2.14 legalDescriptionHash IS A DE-ANONYMISATION VECTOR (user, 2026-07-28) - NOT BUILT

`TitleLedger.sol:56` carries `bytes32 legalDescriptionHash` - a plain, UNSALTED hash of the
off-chain legal description. Two separate problems, and the second was never surfaced anywhere in
this fusion's docs.

**1. It is an unimplemented integration point, not merely a simplified one.** A grep across
`title_holder.nr`, `title_holder/src/main.nr`, the whole `identity-wallet/src/` tree and `tools/`
finds NOTHING that computes this hash. Verified: no wallet-side and no circuit-side producer exists.
The contract stores a value nothing in this system knows how to make.

**2. THE REAL GAP - it is a privacy leak by construction, independent of the missing
implementation.** Legal descriptions of real property (street address, parcel/APN, plat description)
are frequently LOW-ENTROPY AND PUBLICLY ENUMERABLE - county assessor records are often public and
searchable. Anyone asking "is property X tokenised, and under which titleId?" can pull candidate
descriptions from public records, hash each one exactly as the contract does, and compare against
every on-chain `legalDescriptionHash`. A match reveals WHICH REAL-WORLD PROPERTY sits behind a given
titleId. It does not reveal who holds it - `holderCommitment` covers that - but "which properties
are in the system" is disclosed to anyone willing to run a dictionary.

**The existing test demonstrates the vector rather than guarding against it:**
`TitleLedger.t.sol:177` asserts `entry.legalDescriptionHash == keccak256('42 Khreshchatyk St,
Kyiv')` - a bare keccak of a street address, precisely the enumerable input that makes this
brute-forceable.

**The fix is a pattern this codebase ALREADY RUNS IN PRODUCTION** - Privacy Pool's precommitment
scheme (`frontend/identity-wallet/src/pp/notes.ts`). Commit to the document together with a random,
high-entropy, holder-held salt - `Poseidon(legal_description_hash, salt)` - instead of hashing the
document alone. The commitment stays binding and Ricardian: present the document plus the salt and
anyone can verify it matches on-chain, which is the property the design wants. But it becomes
computationally infeasible to brute-force from public records, because the salt supplies the entropy
the legal description lacks. The salt is disclosed only when opening is actually required - a
dispute, a loan default, a transfer needing proof of the underlying document - not by default. This
is NOT a new primitive for this system; it is the same commit-reveal shape already used for PP
deposits, applied to a field that currently has none of it.

**Real work if pursued:**
1. Decide the threat model FIRST - must "which property" stay hidden, or only "who holds it"? The
   answer changes whether this is a defect or an accepted disclosure.
2. If yes: add the salt to `mintTitle`'s commitment, and to whatever wallet/notary tooling
   eventually computes it - which does not exist yet, see (1) above.
3. Define the reveal/verification flow for the cases that genuinely need the commitment opened.

Interacts with §2.13l: if titles become documents and notaries become registered identities, this
commitment should be settled in the same pass rather than bolted on afterwards.

### 2.13t MERGE: the circular bootstrap is BROKEN, and the withdrawal proves on-chain at 7 signals

268/269 forge tests. The withdrawal circuit, both its fixtures, the verifier, ProofLib, PrivacyPool
and four test suites are all on the single identity tree.

**THE LOOP IS CLOSED, contract to circuit.** `IdentityRegistry` registers three identities through
real escrow proofs, `getProof` emits root + siblings, and the Noir circuit's `smt_verifier_full`
ACCEPTS them as an inclusion of `commitment -> 0`. Verified by `nargo execute` against the emitted
witness, then proved and verified with bb, then verified ON-CHAIN by the regenerated verifier
(`WithdrawalHonkVerifier.t.sol`, 11/11, both the hand-vector and wallet-derived fixtures).

**Withdrawal is 24,812 ACIR opcodes, down from 43,772 (-43%)** - the projection, confirmed on the
real circuit rather than a scratch model.

**Test constants were patched FROM THE PROOF FILES, never transcribed.** Fourteen 77-digit values by
hand is where this would have rotted; a wrong constant fails as `SumcheckFailed` with nothing
pointing at the transcription.

**Four incidental defects fixed on the way, each of which would have failed confusingly later:**
- `tools/build-withdrawal-fixture.js`'s documented `tsc` invocation was missing `--rootDir src`.
  With one input file tsc infers the root as `src/pp` and emits a FLAT build, so the `pp/` prefix the
  script requires disappears. It was implicit only while two files from different directories were
  compiled together.
- The same header pointed the build at `tools/build`, which cannot resolve `@iden3/js-crypto` - node
  walks UP for `node_modules` and there is none above `tools/`. It must sit inside the wallet.
- `WithdrawEndToEnd`'s new mock proxies used empty init data, which OZ 5.6.1 rejects; the other
  suites already carry an `UnsafeTestProxy` for exactly this.
- `test_FixturesAreNotDegenerate` could no longer see the identity path, since it is now PRIVATE.
  The check MOVED (registry `getProof` siblings, asserted in WithdrawEndToEnd and in the emitter)
  rather than being dropped - recorded in the test itself, because a silently narrower degeneracy
  check is the exact failure that function exists to prevent.

**REMAINING: `tools/build-e2e-fixture.js` DOES NOT EXIST.** `WithdrawEndToEnd`'s header has always
pointed at it, and it is not in the repo - so `Prover.e2e.toml` has never been reproducible from a
committed script. Its 9 tests fail only because the fixture is stale: adding the state keeper and
registry deployments moved the pool's address, hence `SCOPE`, hence every label, commitment and
context derived from it. That staleness is exactly what `test_ScopeMatchesFixture` exists to catch,
and it caught it. Writing that generator - as a mode of `build-withdrawal-fixture.js` rather than a
second script - is the last step, and it closes a reproducibility hole that predates this work.

### 2.13u MERGE COMPLETE: 281/281, and the missing e2e generator now exists

The single identity tree is live end to end. 281 forge tests, 84 pp tests, 1 escrow circuit test,
tsc clean, client ABI check clean, all four verifiers inside EIP-170.

**`tools/build-e2e-fixture.js` NOW EXISTS.** `WithdrawEndToEnd.t.sol` had named it as its fixture
provenance since the commit that introduced the test - and it was never written. Checked properly
before writing it: absent from this repo's entire history (58 commits, root
`0762975 Fork rarime + Privacy Pools...`), and it CANNOT exist upstream either, because
`withdraw_identity` is this fork's own Noir circuit while upstream Privacy Pools is Circom/Groth16
with no `Prover.toml` at all. So `Prover.e2e.toml` had never been reproducible from anything
committed. It is now, including a `--ragequit` mode for the second e2e fixture, which had the same
gap.

**The regeneration cascade, and why so much moved.** Adding the state keeper and registry
deployments to setUp moved the pool's ADDRESS, hence `SCOPE`, hence every label, precommitment,
commitment and context derived from it. `test_ScopeMatchesFixture` caught it immediately, which is
what it exists for. Regenerated in order: precommitments -> deposits -> state root -> withdrawal
witness -> proof, then the ragequit note the same way.

**A defect the generator's own cross-check caught.** The first draft reconstructed only OUR leaf and
padded the other three with a placeholder - but a LeanIMT root depends on EVERY leaf, so the root
would have been wrong. The `state_root disagrees with the chain` assertion fired immediately. Fixed
by deriving all four labels from the pool's own rule (`keccak256(SCOPE, nonce) % FIELD`, nonce from
1), which reproduces the chain's root exactly. Without that cross-check the failure would have
surfaced as an unexplained proof rejection.

**Every constant in both suites was patched FROM THE PROOF FILES, never transcribed** - twenty-odd
77-digit values, where a single typo fails as `SumcheckFailed` with nothing pointing at the cause.

Withdrawal: **24,812 ACIR opcodes, down from 43,772 (-43%)**, proving on-chain at 7 public inputs
against a root produced by the real registry from three genuine escrow registrations.

### 2.13v DELETION PASS - and it found a REGRESSION I had introduced

Seven files removed: `IdentityAspRegistry.sol`, `RevocationRegistry.sol`, both their interfaces,
both their test suites, and the wallet's `postman/identityAsp.ts`. All superseded by the single
identity tree. 255/255 forge, tsc clean, client ABI check clean.

**COVERAGE WAS MAPPED CASE BY CASE BEFORE DELETING, NOT ASSUMED.** Comparing
`RevocationRegistry.t.sol`'s 13 tests against `IdentityRegistry.t.sol`'s showed seven already had
equivalents (CannotRevokeTwice -> RevokeIsMonotone, StrangerCannotRevoke ->
RevokeRevertsForNonController, StaleRootStopsBeingValid -> ASupersededCleanRootExpires,
RootThatNeverExisted -> UnknownRootIsRejected, UnknownPredicateIsUncitable ->
RevokeRejectsAnUnknownPredicate, NoRemove -> ThereIsNoRemovalPath, LatestRootNeverExpires ->
LatestRootIsAlwaysValidHoweverOld). **Six did not, and were ported.** Deleting the file without them
would have silently narrowed coverage.

**THE REGRESSION.** `RevocationRegistry` REJECTED duplicate predicates at deploy;
**`IdentityRegistry` did not** - I never carried that guard across. A duplicate passes silently,
because `isPredicate` is idempotent, while pushing the same value twice into `_predicates`, so the
published set misreports itself. It is deploy-time-only and immutable, so there is no correcting it
afterwards. Guard added, and `test_ConstructorRejectsDuplicatePredicates` VERIFIED to fail without
it. Found ONLY because the deletion was done by mapping coverage rather than by checking that the
build still passed.

*(To be clear about the name: a PREDICATE is a REASON for revocation - `keccak256('OFAC_SDN')`,
`keccak256('DOC_INVALID')` - fixed in a closed set at deploy. Nothing to do with duplicate
IDENTITIES, which are a separate guard: `registered[commitment]` plus the SMT's own
`KeyAlreadyExists`, both already tested.)*

**Also ported:** empty predicate set, all three zero-address cases, the leaf VALUE actually
recording the predicate (auditable from committed state, not just the event log), revoking moving
the root, and the absence of any governance selector.

**`DeployLib`'s salts named deleted contracts** - live code, not comments. Replaced with
`IDENTITY_REGISTRY_SALT` and `ESCROW_VERIFIER_SALT`; the pairwise-distinctness test still covers all
eight. Comments that asserted the deleted contracts still exist were corrected; comments that
reference them as HISTORY were left, since they record why a guard exists.

**The ABI checker earned its keep again**: after deletion it reported `@contract IdentityRegistry is
AMBIGUOUS - 2 artifacts`, a stale artifact from the moved source. `forge clean && forge build`, as
its own message suggests, cleared it. That ambiguity guard was added precisely so a moved contract
could not silently resolve against an old ABI.

### 2.13w A SECOND REGRESSION, and the process gap that hid it (user, 2026-07-29)

*"deal with all of these regressions and duplicates, act on your justification"*.

**THE PROCESS GAP FIRST, because it is the reusable lesson.** I mapped `RevocationRegistry.t.sol`'s
coverage test by test before deleting it - and then deleted `IdentityAspRegistry.t.sol` in the SAME
commit without doing that at all. Same deletion, same risk, one file checked and one not. Recovering
the deleted file from git and mapping its 19 tests found what the build could not.

**REGRESSION: ERC-7812 EVIDENCE ANCHORING WAS SILENTLY DROPPED.** `IdentityAspRegistry` anchored
EVERY root as an evidence statement (`EVIDENCE_REGISTRY.addStatement`). `IdentityRegistry` had no
evidence registry at all - I never carried it across, and nothing failed, because anchoring is a
side effect no other test observed. Anchoring is what makes a root EXTERNALLY ATTESTABLE rather than
merely stored: another contract, or another chain, can verify a root existed without trusting this
contract's own getters. Every other root in this fusion is published that way, so the identity tree
had become the silent exception.

RESTORED, with a correction the old design would have got wrong here: the statement key is keyed on
a monotone `rootSequence`, NOT on tree size. A REVOCATION moves the root WITHOUT adding a leaf, so a
size-derived key would collide on the second anchor - and `TestEvidenceRegistry` reverts on a
duplicate key, so it would have taken the whole revocation transaction with it.

**Also restored:** the zero-commitment and out-of-field leaf checks. The commitment comes from a
verified proof binding it to a Poseidon output, so neither is reachable - but the previous registry
checked its leaves, and dropping the check leaves that reasoning implicit in a contract that cannot
be upgraded to add it back.

Four tests added, covering both writers: registration anchors, REVOCATION anchors, each root gets a
distinct statement key, and a zero evidence registry is refused at deploy.

### 2.13x Acting on the justification: two entry points, one library

I justified writing `tools/build-e2e-fixture.js` as a separate script - correctly, since
`WithdrawEndToEnd.t.sol` names that exact path and folding it into the other generator as a flag
would leave the reference pointing at nothing. But I then left the two scripts carrying the same
mnemonic, the same escrow secret, the same identity-witness loader with its degeneracy check, the
same wallet-module loader and the same TOML writer. A change to any of them had to be made twice or
silently drift.

`tools/lib/fixture-common.js` now holds all of it. The entry points stay separate; the logic does
not.

**VERIFIED BEHAVIOUR-PRESERVING, not assumed:** all four generated witnesses - baseline, wallet, e2e
withdrawal and e2e ragequit - are BYTE-IDENTICAL after the refactor (`git diff` empty on every
Prover.toml). A refactor of fixture generators is exactly where a silent change would go unnoticed,
since the fixtures are only read by proofs that would then fail somewhere else entirely.

259 forge, 84 pp, tsc clean, ABI check clean.

### 2.14a IMPLEMENTED - and the original write-up missed the bigger leak sitting next to it

§2.14's fix is built: `legalDescriptionHash` becomes `legalDescriptionCommitment`, a SALTED
`Poseidon(hash, salt)`, plus `verifyLegalDescription(titleId, hash, salt)` for the Ricardian open.
Without that view the salt would make the commitment merely unreadable rather than
confidential-but-provable. 259 forge tests, ABI check clean.

**THE GAP IN THE ORIGINAL ANALYSIS: `legalDescriptionURI`.** §2.14 identified the bare hash as
brute-forceable from public county records and proposed a salt - correct, and incomplete. The struct
carries a PUBLIC `string legalDescriptionURI` right beside it, and the existing test filled it with
`'ipfs://legal-doc'`. **If that URI resolves to the document, the salt buys nothing** - an observer
skips the dictionary attack and simply fetches it. Fixing the hash while its neighbour links
straight to the plaintext would have produced confidence without confidentiality.

Handled by DOCUMENTING the field's effect and leaving it optional rather than forcing it empty: a
deployment that genuinely wants public property records is legitimate, and this contract should not
decide that. But it must now be a DECISION, not an accident. The test suite leaves it empty and says
why.

**Tests assert the vector is closed, not merely that the code runs:** the stored value is NOT the
bare document hash (the dictionary attack); the true document plus salt DOES open it on-chain; a
wrong salt or wrong document does not; and the same document under two salts gives two commitments,
so two titles over one property are not linkable to each other even while the property stays hidden.

**Still open, and it is the policy question §2.14 flagged first:** whether "which property" must
stay hidden at all. The mechanism now supports either answer - empty URI for confidential, populated
for public - where before it silently supported only the leaky one.

### 2.14b SALT REPLACED - it bought confidentiality by DESTROYING uniqueness (user, 2026-07-29)

*"forget salts and use the better primitive"*. Correct, and the salt was worse than merely
suboptimal.

**WHAT THE SALT BROKE.** Nothing in `TitleLedger` prevented two titles over the SAME property -
verified, not assumed. A bare hash at least COLLIDES, so a duplicate is detectable. A per-holder
salt makes two titles over one parcel produce two unrelated values, so **DOUBLE-MINTING BECOMES
INVISIBLE**. I had even written `test_theSameDocumentUnderDifferentSaltsIsUnlinkable` celebrating
that as a privacy win; for a title registry it is a hole. The salt traded away the one property a
land register cannot do without.

**THE REPLACEMENT: a DETERMINISTIC KEYED PSEUDONYM**, `propertyKey = PRF(registryKey, docHash)`,
computed off-chain by the notary. DETERMINISTIC, so a second title over the same property collides
and is rejected. OPAQUE without the key, so the public cannot run a dictionary against county
records. And it adds NO new trust: the notary already knows the document - they attest to it - so
holding the key grants them nothing they did not have.

**The same primitive as the identity registry's revocation pseudonyms (§2.13e)** - a public set of
opaque deterministic values - now serving two subsystems instead of one.

It also removes the salt's CUSTODY failure, which would have been the worse operational bug: a lost
salt makes a commitment permanently unopenable, and for a real property title that is unrecoverable.
There is no per-title secret here to lose.

**THE UNIQUENESS INVARIANT, which never existed before:** `titleOfProperty` maps a property to its
one live title. A second mint reverts unless it is a genuine SUCCESSION citing the title it replaces
- without that branch every legitimate reissue and transfer would be blocked - and a successor may
not cite a prior title over a DIFFERENT property, which would launder one property's chain of title
into another's.

**`legalDescriptionURI` IS GONE.** §2.14a documented it as a decision the deployer must make; that
was too weak. Its only role was pointing at the document, publicly. Under this design the document
is never opened on-chain at all - binding is the notary's signature over `propertyKey` - so a public
pointer buys nothing and costs everything. Removing it also resolved a `Stack too deep` that the new
check triggered, which is the compiler agreeing the field was surplus.

**The invariant immediately caught a test minting two titles over one property**
(`test_verifyHolderProof_rejectsAProofBoundToAnotherTitle`), which now uses two properties.
263 forge tests, ABI check clean.

### 2.15 SPEC.PDF (Cryptographic Mortgage Protocol v2.0) - what it corrects and what it adds

Read 2026-07-29. Corrects a design decision I made without it, and opens scope not previously recorded.

**CORRECTION - THE NOTARY COMPUTES NOTHING.** §2.14b had the notary computing
`propertyKey = PRF(registryKey, docHash)` off-chain. Wrong. Per §3 of the spec, a notary is A REGULAR
USER; their notary status is established by TLSNOTARY PROOFS (2PC MPC-TLS) over WebPKI TLS sessions
from `portal.notary.ir`, verified on-chain in `NotaryRegistry.sol`, with headless scrapers indexing
office number, name and licence status. Explicitly NO third-party aggregator (no Reclaim). So the
notary holds no protocol key and performs no protocol computation - they are attested, not trusted
with secrets. `TitleLedger`'s current `bindNotaryAddress` placeholder is superseded by this.

**THE SPEC'S OWN NULLIFIER HAS THE TENSION I FOUND IN §2.14b.** §4.1 defines
`N = PoseidonHash(Cadastral_ID, Secret_Salt)`, described as "deterministic, un-linkable" and used to
prevent double-mortgaging. Those two properties pull against each other exactly as §2.14b found:
a per-borrower secret salt makes N un-linkable but ALSO makes two liens on one parcel look
unrelated, defeating the double-mortgage check; a shared salt makes N deterministic but
brute-forceable, since *Shenaseh Yekta* is an 18-digit enumerable key. UNRESOLVED IN THE SPEC.
Resolving it is the same problem `propertyKey` faces and should be settled once, for both.

**NEW SCOPE, none of it previously recorded:**
- `LandRegistry.sol` - parcel nullifiers, lien registration/discharge, `verifyParcelNullifier`.
- `MortgageEngine.sol` - loan lifecycle (ACTIVE/DELINQUENT/IN_DEFAULT/PAID_OFF), monthly payments,
  default enforcement at day 91, LTV <= 70% and DTI <= 43% underwriting, algorithmic rates on pool
  utilisation.
- Two capital models: sovereign treasury (7% APY RWA, 200-300bps subsidy) vs private LP vaults.
- Tiered cadastral access (§2.2): Tier 2 - general public/lenders - can verify deed authenticity
  from the 18-digit ID plus the owner's National ID. That is the verification path a lender uses,
  and it is PUBLIC, which constrains how much the parcel nullifier can hide.
- Default bridge: threshold encryption is OPTIONAL. Option A is a 2-of-3 legal multisig / notarised
  escrow of an irrevocable power of attorney; Option B is k-of-n threshold ElGamal.

**GENERALISATION (user, 2026-07-29):** this work must not be Iran-specific. The identity, title and
lien machinery is jurisdiction-agnostic; only the registry endpoints, the deed schema and the
enforcement vendors are local. Keep them behind an interface so a second jurisdiction is a
configuration, not a fork. `iran-constitutional-monarchy` is OUT OF SCOPE for now.

### 2.15a CRE INSTEAD OF TLSNotary, with a controller-published workflow version (user, 2026-07-29)

The spec (§2.15) specifies TLSNotary 2PC MPC-TLS over `portal.notary.ir`. **We already have the
property that buys, by a cheaper route.** `backend/cre/notary_registry/main.go` exists and does
exactly this job for Ukraine's Ministry of Justice registry: cron-triggered scrape, then
`cre.ConsensusIdenticalAggregation` requires EVERY DON node to independently fetch and produce a
BYTE-IDENTICAL result before a report is generated. That is what makes it an anchored external
authority rather than one operator's assertion - the same reason TLSNotary is specified, without the
MPC-TLS machinery.

**THE PROBLEM CRE HAS AND TLSNotary DOES NOT: scrapers rot.** A government portal changes its HTML
and the workflow silently starts producing nothing, or worse, produces a consensus-valid parse of
the wrong fields. TLSNotary proves the SESSION, so a format change breaks the parse in the prover;
CRE proves the CONSENSUS, so a format change breaks it identically on every node and consensus is
still reached on a wrong answer.

**USER'S PROPOSAL: the SAME controller that writes the label and blacklist lists also publishes
which CRE workflow version is current**, so the scraper can be updated when a portal changes.

That is the right shape - one authority, already trusted for exactly this class of decision, rather
than a second one - but it needs the trust caveat stated: **a controller that can point at a new
workflow can point at a MALICIOUS one**, and the DON would faithfully reach consensus on its output.
CRE's consensus protects against a rogue NODE, not against a rogue WORKFLOW.

Mitigations to design in, not assume:
- A workflow is compiled wasm with a deterministic ID, so a pointer names a SPECIFIC, auditable
  artifact - not "whatever the controller runs".
- Version history APPEND-ONLY, so a swap is permanently visible rather than a silent substitution.
- A TIMELOCK between publishing a version and it taking effect, so a swap can be seen and contested
  BEFORE it is load-bearing. Without this the update mechanism is a same-block censorship lever.
- The existing fail-open rule still applies: if no valid workflow is published, the last good
  anchored data stays valid rather than everything halting.

**NOT YET BUILT.** Recorded now because it changes §2.15's stated approach and because the timelock
is the kind of thing that is hard to add after a mechanism is depended upon.

### 2.13l-DONE A notary is a REGISTERED IDENTITY, and therefore revocable

Closes the structural half of §2.13l, informed by §2.15's correction that a notary is a regular user
whose status comes from CRE attestation rather than from holding any protocol key. 267 forge tests.

**THE DEFECT.** `address notary` plus `notaryDataHash[address]`, bound by the registry postman.
`TitleLedger`'s own header already called this an OPEN GAP - "this address really is that notary"
was asserted, not proven. Worse than unproven: **an address has no passport to expire, no document
to invalidate and no status to lose, so a notary was the ONLY participant in this system who could
not be revoked.**

**NOW: keyed by `holderRoot`.** Two independent facts, deliberately kept apart because they fail
independently:
- `notaryDataHashOf[holderRoot]` - WHICH registry entry the identity claims, proven against the
  CRE-anchored active snapshot. Notary-ness comes from the official register.
- `notaryIdentityOf[signingKey]` - which key acts for that identity, so an action needs no fresh
  zero-knowledge proof per signature.

`_requireActiveNotary` now checks THREE things: the key is bound; the identity **still holds a
current document**; and the registry entry is in the active snapshot. Losing notary status and
losing identity status are different events, so collapsing them into one flag somebody must remember
to clear would be the bug.

**DELIBERATELY NOT KEYED ON THE POOL COMMITMENT**, which is this system's other identity handle and
would have made the revocation check trivial. That value is a notary's PRIVATE key into the shielded
pool; publishing it to gain revocability would link their public professional role to their private
financial identity - buying one property by destroying the one the pool exists to provide.
`holderRoot` is already public in registration events, so it costs nothing.

**THE REMAINING GAP, narrowed and still stated.** Binding is still postman-gated: "this holderRoot
really is that notary" is asserted. It is now much narrower - the subject is a real, registered,
revocable identity rather than an anonymous keypair, and the registry entry itself is CRE-attested -
but closing it fully needs the notary to prove control of `holderRoot` at bind time, which needs a
circuit that does not exist yet.

**Tests:** a notary whose document is revoked stops being able to act; binding refuses an identity
with no current document; and a VALID identity whose registry entry is absent from the snapshot is a
valid person but not a valid notary - the two checks failing separately, as designed.

### 2.13l-B The notary binding is PROOF-GATED - no new circuit was needed (user, 2026-07-29)

*"are you sure we need the circuit that doesnt exist yet?"* - no, and the challenge was right.

I claimed closing the notary-binding gap needed a circuit proving control of `holder_root` at bind
time. **`pp::title_holder` already does exactly that.** It proves
`holder_root == extract_pk_identity_hash(sk_identity)` and binds it to a SECOND FIELD - and that
field is an arbitrary CONTEXT. It is named `title_id` only because that was its first use. Its
verifier is already deployed and wired into TitleLedger, and PoseidonUnit2L is already available
on-chain, so the whole thing was a call away.

`bindNotaryIdentity` now requires that proof, against a context binding BOTH the signing key and the
register entry, so a proof obtained for one binding cannot be replayed to attach a different key or
a different notary.

**WHAT THIS CLOSES:** the postman can no longer fabricate a binding for an identity whose owner never
consented. Previously it could name any holderRoot at all.

**WHAT REMAINS, and it is a materially smaller claim:** the postman still chooses WHICH register
entry is attached. Proving the entry is genuinely this person's needs the register's name and office
number matched against the passport's own DG1 name field - a comparison no circuit here performs.
So the residual trust is "the postman attached the right entry", not "the postman invented a notary".

**THE LESSON:** I reached for a new circuit before checking what the existing ones actually prove.
The generality was in the parameter NAME, not the constraint - `title_id: Field` constrains nothing
about titles.

### 2.16 HOLDING A NOTARY TO ACCOUNT WITHOUT UNMASKING ANYONE (user, 2026-07-29)

*"if they make fraudulent claims someone should be able to prove that and hold it against them in
court - how would this reveal the notary's identity though without defeating the purpose?"*

**IT DOES NOT, BECAUSE A NOTARY'S IDENTITY IS ALREADY PUBLIC BY PROFESSION.** They hold a public
office; their name, office number and licence status are ON THE STATE REGISTER - that register is
precisely what the CRE scraper reads. Attribution therefore discloses only what the state already
publishes.

The evidentiary chain is complete and permanent: the notary's signature over the mint message, bound
to their signing key, bound to their `holderRoot`, bound to their `notaryDataHash`, which IS their
register entry. Non-repudiable, and it names a real person in a real register - which is what a court
needs.

**WHAT STAYS PRIVATE:** which PROPERTY (opaque `propertyKey`) and WHO the holder is
(`holderCommitment`). And the aggrieved party in a notary-fraud case IS the holder, so disclosing the
property is at the VICTIM'S OWN DISCRETION when they bring the case. Nobody else can open it.

**AND THE NOTARY'S PERSONAL FINANCES STAY SEPARATE.** This is where §2.13l's refusal to key the
notary on their pool commitment pays off: professional accountability without exposing their private
financial life. Had we taken the easy revocation check, holding a notary to account for fraud would
have simultaneously deanonymised their own pool activity.

**NO STAKE OR BOND IS NEEDED**, and this is a design conclusion rather than an omission. A notary is
LEGALLY bound - they already hold a licence a court can strip. Requiring them to pledge capital into
the pool would add a slashing mechanism that duplicates a sanction the law already imposes far more
heavily, while making the professional role capital-gated.

**ONE REAL LEAK TO FLAG.** `IdentityRegistry.register` carries BOTH `holder_root` and `commitment` as
public inputs, so they are linkable from calldata. A notary's `holderRoot` becomes public when bound,
which makes their pool COMMITMENT discoverable. Their ACTIVITY stays hidden - a withdrawal never
discloses the commitment, it is a private SMT key - but their PARTICIPATION becomes visible.
Mitigation: a notary should register a SEPARATE identity for their professional role. The system
already supports many identities per person, so this is operational guidance, not new machinery.

### 2.16a CORRECTION: notaries can be TARGETED - anonymous attestation, conditional accountability

§2.16 answered "how do we hold a notary to account without unmasking them" with: a notary's identity
is ALREADY public by profession, so attribution discloses nothing new. **That is wrong under the
threat model that actually matters here** (user, 2026-07-29): notaries can be targeted.

**THE DISTINCTION I MISSED.** It is public that Jane Doe is a notary - her name and office are on the
state register. It must NOT be public that Jane Doe attested titles IN THIS SYSTEM. In a hostile
jurisdiction the second fact is the dangerous one, and the current design publishes it: `holderRoot`
is bound on-chain and every action names the signing key.

**THE FIX, and it needs no new primitives - both already exist here:**

1. **ANONYMOUS SET MEMBERSHIP.** The notary proves in zero knowledge "I am one of the currently
   active notaries" - a Merkle inclusion against the CRE-anchored snapshot - WITHOUT revealing which.
   Exactly the proof shape the identity registry already performs, applied to the notary set.
   `_requireActiveNotary` currently takes a public `address notary_` and a plaintext Merkle proof;
   that becomes a ZK proof over the same root.

2. **CONDITIONAL DEANONYMISATION via the SEALED ENVELOPE we already built.** The attestation carries
   a hashed-ElGamal envelope sealing the notary's identity to a k-of-n legal guardian set, opened
   ONLY on a fraud finding. `pp/src/envelope.nr` does this today for revocation secrets; the
   difference is only what is sealed and who holds the key.

**THIS IS THE SPEC'S OWN PATTERN.** §5 Option B specifies threshold ElGamal with decentralised legal
guardian nodes releasing shares on a default. Same machinery, applied to notary identity rather than
the power of attorney - so it is one mechanism serving two purposes, not a new dependency.

**IT ALSO DISSOLVES THE SECOND-IDENTITY WORKAROUND** (§2.16's "a notary should register a separate
identity"). That was treating a symptom, and only for notaries. If the notary never publishes
`holderRoot` at all, there is no `holderRoot` -> commitment link to leak, and no separate identity to
maintain. One fix, both problems.

**THE UNDERLYING LEAK IS NOT NOTARY-SPECIFIC, and this is the part worth acting on separately.**
`IdentityRegistry.register` carries BOTH `holder_root` and `commitment` as public inputs, so EVERY
user's identity is publicly linked to their pool commitment in calldata. Their ACTIVITY stays hidden
- a withdrawal never discloses the commitment - but PARTICIPATION is visible for everyone, not just
notaries. The clean fix is the same shape again: prove the document binding by INCLUSION in a
committed tree rather than by publishing the identifiers. `StateKeeper` already maintains a
`PoseidonSMT` (`registrationSmt`), so the structure exists; what is missing is putting the document
bindings in it and proving against its root.

**NOT BUILT.** Recorded with the design settled, because the current `bindNotaryIdentity` /
`_requireActiveNotary` shape is publicly identifying and should not be deployed to anyone who can be
targeted for it.

### 2.16b "HOW COULD THERE BE A FRAUD FINDING IF EVERYTHING IS SECRET" (user, 2026-07-29)

The question finds a real hole. §2.16a proposed conditional deanonymisation "on a fraud finding"
without ever specifying HOW FRAUD IS DETECTED. If the notary is anonymous, the property is an opaque
pseudonym and the holder is a commitment, nothing on-chain is legible enough for anyone to notice
wrongdoing - so the trigger for opening the envelope was assumed, not designed.

**PART ONE, WHICH IS FINE ONCE STATED: DETECTION IS OFF-CHAIN, AND SHOULD BE.** Notarial fraud is a
REAL-WORLD ACT - registering a lien or transfer against a property - and it leaves its trace in the
STATE CADASTRE, not here. The spec's §2.2 Tier 1 gives a property owner full view of every parcel and
encumbrance registered under their National ID via `Sabt-e Man`. That is where an owner sees a charge
they never authorised. A lender detects it differently and just as concretely: they appraised the
property, so they know exactly what they lent against, and discover the defect when they enforce.

So the chain is the ATTRIBUTION surface, not the DETECTION surface. Detection comes from a party who
already knows the underlying facts - the owner via the official registry, the lender via their own
underwriting - and the chain then supplies non-repudiable evidence of who attested what. That is
coherent, and it is what §2.16a should have said instead of "a fraud finding" as though it were
self-executing.

**PART TWO, AND THIS ONE IS AN ACTUAL GAP: NOBODY IS ASSIGNED TO COMPUTE `propertyKey`.**
§2.14b specified `PRF(registryKey, legalDescriptionHash)` "computed off-chain by the notary".
§2.15 then established that notaries compute nothing and hold no protocol key. **The correction was
never propagated** - `TitleLedger.sol:60` still says "computed off-chain by the notary", and no party
in the current design holds `registryKey`.

Consequences, both real:
- The mint path is unimplementable as written; someone must hold the key.
- **A property owner CANNOT CHECK whether their own property has been titled here**, because
  computing `propertyKey` needs a key they do not have. That is a detection path we lose - the owner
  can see a fraudulent entry in the STATE register, but not a fraudulent entry in OURS.

**THE CANDIDATES, none obviously right:**
- *The controller* (the party already managing labels and the blacklist) - simplest, but puts it in
  the path of every mint, which is a liveness and censorship dependency on exactly the party the
  rest of the design works to keep out of that position.
- *A protocol-wide constant* - no key custody at all, but then `propertyKey` is brute-forceable,
  since a *Shenaseh Yekta* is an 18-digit enumerable identifier. That is the confidentiality the
  keyed pseudonym existed to provide, given straight back.
- *The k-of-n legal guardian set* already proposed for deanonymisation, via a threshold PRF - no
  single party can brute-force, and it reuses a group the design already needs. Cost is a threshold
  interaction per mint.

**UNRESOLVED, and it is the same tension as §2.15's parcel nullifier** - the spec's own
`N = PoseidonHash(Cadastral_ID, Secret_Salt)` faces this identically. Settle it once, for both.
Until it is settled, `TitleLedger`'s propertyKey comment is stale and should not be read as a
specification.

### 2.17 "MORTGAGES MIGHT NOT BE VIABLE AT ALL?" - the honest answer (user, 2026-07-29)

**MY LENDER ARGUMENT IS DEAD, and the user killed it correctly.** §2.16b's detection story rested on
"the lender appraised the property, so they know what they lent against". **THERE IS NO LENDER.**
Underwriting comes from a pool of QUI holders - basket shares in the SPV - and there is no class
action either. So:

- **Nobody knows which property backs a loan**, so nobody notices a fraudulent title.
- **Nobody has standing**, so the conditional-deanonymisation trigger has no plaintiff.
- **The pool silently eats the loss**, and cannot even tell a loss from a defect.

That is not a gap in the mechanism; it removes the party the mechanism assumed.

**THE STRUCTURAL FACT.** Someone must (a) know the property, (b) have skin in the game, and (c) be
accountable. A diffuse pool has none of the three. The protocol CAN enforce the mechanical
predicates - the title is unique, a licensed notary attested it, LTV/DTI are within limits, payments
arrive, default is timed - but it CANNOT verify that a declared appraisal is honest or that the
property is worth what is claimed. Every one of those rests on the notary's attestation being TRUE,
which is a single point of failure the cryptography does not touch.

**SO: A FULLY TRUSTLESS POOLED MORTGAGE IS NOT VIABLE.** Saying otherwise would be dishonest. What IS
viable is narrower and worth stating precisely:

> A pool that funds loans ORIGINATED BY ACCOUNTABLE AGENTS, where the protocol enforces the
> mechanical parts and licensed humans carry the judgment parts.

That is how mortgage markets already work - originate-to-distribute - and the protocol's contribution
is privacy, automation and capital access, NOT the elimination of an underwriter.

**WHAT THE SPEC IS MISSING, and the user spotted it.** §6 hires post-default vendors - process
servers, auctioneers, REO brokers, preservation contractors - but NO PRE-DEFAULT ROLES. There is no
appraiser, no title investigator, no servicer, and no fraud investigator. Those are not optional:
- **Independent appraisal** as a separately attested role, ideally CRE-verified from a licensed
  appraisers' register exactly as notaries are - so valuation is not the notary's word alone.
- **A servicer** who knows the property and is compensated and liable, giving the pool an agent with
  standing where the pool itself has none.
- **Investigators.** Loss mitigation requires someone to investigate suspected fraud. Real servicing
  costs run roughly 25-50bps; this is a normal, PRICEABLE operating cost taken out of the interest
  spread - but it must be priced, not assumed away.

**WHAT SURVIVES WITHOUT ANY OF THIS.** Over-collateralisation does real work: at LTV <= 70% a 30%
buffer absorbs ordinary valuation error, though not outright fraud. And the notary's LICENCE is the
actual bond - a professional who can be struck off has more at stake than most crypto collateral,
which is exactly why §2.16 concluded no stake was needed.

**IMPLICATION FOR SCOPE, and it should be faced now rather than at field testing.** This strengthens
the case for shipping IDENTITY AND TITLE FIRST and treating lending as a later phase gated on the
agent roles existing. FUNDING-APPLICATION.md already commits to that shape - "where the assignment
instrument proves unenforceable we would ship the identity and title layers without the lending
layer" - and this is a second, independent reason for the same ordering. The identity and title work
is valuable ON ITS OWN: provable ownership without public disclosure does not depend on anyone
lending against it.

### 2.17a Notary anonymity: proceed on the §5 Option B pattern

Confirmed direction. The k-of-n legal guardian set the spec already specifies for the power of
attorney ALSO holds the notary-deanonymisation shares - one guardian set, two purposes, no new
trusted party. Concretely:
- The notary proves ZK set membership in the CRE-anchored active-notary snapshot; no identity on chain.
- The attestation carries a hashed-ElGamal envelope (`pp/src/envelope.nr`, built and tested) sealing
  their identity to the guardian set's threshold key.
- Opening requires k of n, on a stated predicate, exactly as the default bridge opens the PoA.

**BUT NOTE WHAT §2.17 DOES TO THE TRIGGER:** the guardians can only act on a COMPLAINT, and with no
lender there may be no complainant. The mechanism is sound and the plaintiff is missing - so the
servicer role above is a PREREQUISITE for this to mean anything, not an optimisation.

### 2.17b DISTRIBUTOR, NOT ORIGINATOR - and the minimum viable trustless configuration

**1. DISTRIBUTOR-ONLY IS THE VIABLE STRUCTURE, and it fixes what §2.17 broke.** If the pool BUYS
loans rather than writing them, the party who knows the property is the ORIGINATOR, and they are
contractually on the hook for it. The pool never needs to know which building it is; it needs the
originator's representations and a first-loss position. That is originate-to-distribute, i.e. how
RMBS has always worked, and it restores every role §2.17 found missing without inventing anything:
the originator appraises, verifies title, services, and investigates - because they eat the first
loss if they got it wrong.

**2. MINIMUM VIABLE CONFIGURATION.** "Trustless" cannot mean "no accountable party" for a loan
against an off-chain asset - the asset's existence and value are facts no oracle can settle
honestly. So the minimum is not zero trusted parties; it is:

> EXACTLY ONE accountable party per loan, whose accountability is COLLATERALISED ON-CHAIN rather
> than merely actionable in court.

Concretely:
- The originator posts FIRST-LOSS CAPITAL into the pool before their loans are funded.
- A loan that defaults for TITLE DEFECT slashes that capital automatically - no complaint, no
  plaintiff, no court in the loop. **That is what §2.17's missing-plaintiff problem needed**: the
  trigger becomes mechanical rather than adversarial.
- Courts become the BACKSTOP for losses exceeding first-loss, not the primary mechanism.
- Everything else the protocol already enforces: title uniqueness, licensed attestation, LTV/DTI,
  payment and default timing.

The pool's residual trust reduces to "the originator's first-loss is sized correctly", which is a
NUMBER that can be audited and adjusted, rather than "someone will sue on our behalf", which is a
hope. That is the honest floor - not trustless, but trust that is bounded, collateralised, and
priced.

### 2.17c MAXIMALLY ANONYMOUS OWNERSHIP ATTESTATION - buildable from what exists

The question: a CRE-verified notary proves someone owns a property, revealing NEITHER the owner NOR
the notary. Fully answerable with primitives already built and tested here.

**THE STATEMENT.** "There exists a notary N and an owner O such that N is in the currently active
notary set, N controls that identity, and N attests that O owns property P."

**PUBLIC:** the notary-set root (CRE-anchored), `propertyKey` (opaque), `ownerCommitment` (opaque),
a notary nullifier, and the sealed envelope. **PRIVATE:** which notary, which owner, which property.

**THE CIRCUIT, entirely from existing gadgets:**
1. `notary_root = extract_pk_identity_hash(sk_notary)` - proves CONTROL of the notary identity.
   (`pp/src/holder_root.nr`, already differential-tested.)
2. `notary_root` is INCLUDED in the CRE-anchored active-notary snapshot - a Merkle inclusion whose
   path is PRIVATE, so the set is public and the member is not. (`pp/src/smt.nr` or `lean_imt.nr`,
   both already used exactly this way for identities.)
3. `ownerCommitment == Poseidon(owner_holder_root, propertyKey)` - binds THIS owner to THIS property,
   with the owner's identity never appearing. Same shape as `title_holder`, which lets the owner
   later prove ownership themselves with the circuit that already exists.
4. `notary_nullifier == Poseidon(sk_notary, propertyKey)` - deterministic per (notary, property).
   Makes double-attestation on one property DETECTABLE without revealing who, and gives a
   rate-limiting handle. This is the epoch-pseudonym trick from §2.13e, third use.
5. The sealed envelope from `pp/src/envelope.nr` seals `notary_root` to the k-of-n guardian
   threshold key - so §2.17b's automatic slashing has a mechanical trigger, and guardians can open
   WHO attested only on a stated predicate.

**COST, estimable from measured neighbours:** two scalar multiplications (~11.8k opcodes each) for
the identity derivation and the envelope, one Merkle inclusion (~7.9k-11.9k depending on depth), and
a handful of Poseidons. Roughly 35-40k ACIR opcodes - the same order as `escrow_envelope`'s measured
38,874, and one-time per attestation rather than per transaction.

**NOT BUILT.** Every component exists and is tested; this is composition, not new cryptography.

### 2.17d THE 30% RATE, what "priced" means, and the KICKBACK ATTACK (user, 2026-07-29)

**1. WOULD BUYING LOANS FIX THE ~30% RATE? MOSTLY NOT, AND WE MUST NOT CLAIM IT DOES.**

An Iranian mortgage rate near 30% is overwhelmingly INFLATION, not intermediary margin. Nominal
rates track a price level running at similar magnitude, so 30% nominal may be NEGATIVE in real terms.
Distribution widens the funding base and can compress the SPREAD - the intermediary's cut, and the
risk premium charged for opacity - but no capital structure deflates a currency.

The three honest levers, and their costs:
- **Compress the spread.** Real, but it is basis points against tens of percent. Do not present a
  spread improvement as a rate improvement.
- **Change the unit of account** to hard currency at 4.5-5%, per the spec's Model A. The nominal
  number collapses - and the borrower now earns rial and owes dollars. A devaluation turns a
  serviceable loan into a default machine. **This moves risk onto the least able party to bear it**,
  and presenting it as a cheaper mortgage would be dishonest.
- **CPI-indexed IRR**, also in the spec. The honest structure: the rate tracks the price level, so
  the REAL rate is low and the borrower is not exposed to devaluation beyond their own income's.
  The nominal number stays high and that is CORRECT, not a failure.

**The claim we can defend: a lower REAL rate and access for people banks will not serve.** Not a
lower nominal number.

**2. WHAT "BOUNDED, COLLATERALISED, PRICED" MEANS - concretely.**
- **Bounded**: the maximum loss from one accountable party's failure is a KNOWN NUMBER - their
  first-loss capital - rather than open-ended.
- **Collateralised**: that number is capital locked on-chain, not a promise to pay later.
- **Priced**: the residual risk beyond it is charged for in the rate, so the pool is compensated
  rather than surprised.

If an originator posts 10% first-loss against their book, the pool's exposure to their misconduct
starts only beyond 10%, and that 10% is auditable on-chain. That is the whole content of the phrase.

**3. THE KICKBACK ATTACK, and it defeats stake by construction.**

A notary bribed enough does not care about losing a stake. If a fraudulent title extracts 100 and the
stake is 10, they take the bribe. **Any stake small enough to be postable is small enough to be
outbid**, so slashing is not a defence against a bribed professional. This is the correct objection
and it is why §2.16 concluded no crypto stake for notaries - not as an omission but as a conclusion.

**I MUST BE PRECISE ABOUT WHO POSTS WHAT, because §2.17b blurred it:**
- The **ORIGINATOR** posts first-loss capital. That works: an originator is a business with capital,
  a book of repeat business, and losses that scale with their own portfolio.
- The **NOTARY** posts NOTHING. Their bond is their LICENCE and their LIBERTY - a struck-off notary
  loses their lifetime professional income, and fraud and bribery are crimes. That is worth orders
  of magnitude more than any postable stake, and it does not capital-gate a professional role.

**What actually defends against notary collusion:**
- **DETECTION is independent of the protocol** - the owner sees the unauthorised entry in the STATE
  cadastre (spec §2.2 Tier 1). A bribed notary cannot suppress that; it is the government's register,
  not ours.
- **ATTRIBUTION** via the guardian-opened envelope, naming them.
- **CONSEQUENCE** is licence loss and prosecution, not slashing.
- **SEPARATION OF ROLES**: the notary and the originator MUST be distinct parties, so fraud requires
  collusion between two accountable actors rather than one. If a deployment lets them be the same
  entity, that is a design error and should be prevented in the contract, not the documentation.

**AND THE HONEST RESIDUAL: collusion between a notary and a borrower is not solved by cryptography.**
No proof system establishes that an off-chain document describes a real building. Real markets do not
solve this cryptographically either - they BUY TITLE INSURANCE against exactly this, and price it.
That is what "priced" should point at for this risk class, and a deployment without either title
insurance or an originator first-loss deep enough to stand in for it is under-capitalised regardless
of how good the circuits are.

### 2.17e ORIGINATORS: the plan, and why TIER 2 changes the risk picture (user, 2026-07-29)

**MY TITLE-INSURANCE ANSWER WAS US-CENTRIC AND LARGELY WRONG HERE.** Title insurance exists mainly
in RECORDING systems (US/Canada), where the register is evidence of a claim and a private insurer
underwrites the gap. Iran runs a CIVIL-LAW STATE CADASTRE (*Sazman-e Sabt*): registration is
constitutive, the state deed IS the title, and the STATE stands behind the register. Private title
insurance is largely redundant in that model and may simply not exist locally. So "the originator
has title insurance handled" is probably the wrong question - **needs local confirmation, but the
structural answer is that the state register plays the role I was assigning to an insurer.**

**AND SPEC §2.2 TIER 2 IS THE PART I UNDER-WEIGHTED.** *"General Public / Lenders - Deed Authenticity
Check (Tasdiq-e Asalat) - can verify deed authenticity by submitting the 18-digit Unique ID +
Owner's National ID."*

**AN ORIGINATOR CAN INDEPENDENTLY VERIFY THE DEED AGAINST THE STATE.** That collapses the threat I
have been building elaborate machinery around: the notary is NOT a single point of failure, because
their attestation is CORROBORABLE against the government's own system by the party taking the risk.
A bribed notary cannot forge a deed the state will not confirm.

**THIS SHOULD BE CRE-ATTESTED, and it is the highest-value unrecorded item.** The same oracle pattern
already built for the notary register can run the Tier 2 authenticity check, putting on-chain
evidence that the deed is genuine - independent of BOTH the notary and the originator. That reduces
trust in both simultaneously, using machinery that exists (`backend/cre/notary_registry/main.go` is
the template). It is a better use of effort than anything downstream of assuming the notary lied.

**THE ORIGINATOR PLAN.**

*What they do* (none of it protocol-replaceable): the Tier 2 deed check; appraisal; borrower
underwriting for DTI; servicing and collection; loss mitigation and investigation.

*What they post*: first-loss capital, sized against their book, slashed automatically on a title
defect (§2.17b) - so the trigger is mechanical and needs no plaintiff.

*What they warrant*: representations on deed authenticity, valuation basis, and borrower identity -
enforceable in-jurisdiction, which is what the first-loss backstops rather than replaces.

*What the protocol enforces*: lien uniqueness, LTV/DTI at origination, payment schedule, default
timing, and the slashing.

*ROLE SEPARATION IS MANDATORY*: originator != notary, so any fraud needs two accountable parties
colluding. This must be enforced in the contract, not the documentation.

**WHO THEY ACTUALLY ARE - the honest weak point.** In a sanctioned jurisdiction the banks are
constrained, which is the project's whole premise, so originators are likely licensed non-bank credit
institutions or real-estate finance companies. **Recruiting even one is a
BUSINESS-DEVELOPMENT problem, not a technical one, and it is the single most likely reason the
lending layer never ships.** The realistic path is ONE vetted originator, a small book, and first-loss
set deliberately high, to prove the mechanics before widening. That is also why §2.17's conclusion
stands: identity and title first, lending gated on an originator existing at all.

### 2.17f WHAT THE NOTARY/CRE LINK IS ACTUALLY FOR, and how originators are onboarded

Four questions that together ask whether the notary machinery earns its keep. Reading §2.2 against
§2.15 answers all of them, and corrects a conflation I have been carrying.

**1. THE CONCRETE BENEFIT - I WAS CONFLATING VERIFICATION WITH EXECUTION.**
Tier 2 verifies a deed is authentic, and ANYONE may do it. Tier 3's exclusive powers are different:
*"query active encumbrances, REGISTER MORTGAGES, and EXECUTE BINDING TITLE TRANSFERS using hardware
tokens."*

So a notary's unique capability is not "tell us this title is real" - Tier 2 does that better,
independently, and without trusting them. It is **MAKING THE LIEN LEGALLY EXIST.** A mortgage
registered by a non-notary is VOID, and a pool holding a void lien holds nothing.

**That is the whole point of the CRE link, and it is narrow and real:** it proves the person
executing the legal registration was licensed to do so at the time. The attestation is about the
LIEN, not the title. Everything I wrote treating the notary as the source of truth about the
PROPERTY was misdirected - Tier 2 owns that.

**2. FRAUD DEFENCE WITHOUT DEANONYMISATION - and it needs no complaint.**
A notary who claims to have registered a lien either did or did not, and the state register says
which. CRE-attest a FOLLOW-UP Tier 1/Tier 2 query: does the encumbrance actually appear? If the
notary took the fee and never registered it, the lien is absent and that is MECHANICALLY DETECTABLE
by oracle, from state data, **without knowing which notary it was.**

Only when the check FAILS is there cause to open the envelope. So anonymity holds in the normal case,
detection needs no plaintiff (which §2.17 established we do not have), and deanonymisation is
reserved for a proven discrepancy rather than a suspicion.

**3. ONBOARDING ORIGINATORS - the same mechanism, not a new trust assumption.**
*How we know they are real:* licensed credit institutions appear on a FINANCIAL REGULATOR'S PUBLIC
REGISTER. Scrape it, attest it by DON consensus - byte-identical across nodes - exactly as
`backend/cre/notary_registry/main.go` already does for notaries. Same pattern, third register.

*Why they work with us:* access to capital they cannot otherwise reach, given the banking
constraints that are this project's premise; origination and servicing income without committing
their own balance sheet; and they keep the customer relationship.

*Why we work with them:* they hold the licence, the staff and the legal standing we do not, and they
carry first-loss.

**4. "IS IT BACK TO TRUSTING THE NOTARIES ABOUT THE ORIGINATORS?" NO - NOBODY VOUCHES FOR ANYBODY.**
Three INDEPENDENT state sources, each attested separately:
- notary register -> licensed to execute liens
- financial regulator register -> licensed to originate
- cadastre Tier 2 -> the deed is genuine

No party in this system attests to another party's standing. That is the entire reason for using
REGISTERS rather than reputation or vouching, and it is why a corrupt notary cannot smuggle in a fake
originator: they have no say in it.

**THE DEEPEST RESIDUAL, and it should be stated plainly rather than discovered later.** The trust root
of all three is THE STATE'S OWN REGISTERS. That is strong against PRIVATE fraud - a bribed notary,
a fake originator, a forged deed - and worth nothing against STATE-LEVEL FABRICATION. A government
that wants to conjure a licensed notary or a genuine-looking deed can.

This sits in tension with the threat model, where the state is the surveillance adversary. The
tension is COHERENT - one can trust that a passport is genuinely issued while not wanting the issuer
to watch one's transactions, and the identity layer already rests on exactly that - but it bounds
what this system claims. It defends the user's PRIVACY from the state. It does not defend the
protocol's INTEGRITY from the state, and no amount of cryptography over state-issued credentials
would.

### 2.18 ELIMINATING THE PARTICIPATION LEAK - verified design, every piece already exists

*"try to eliminate leaks. this needs to be as trustless as possible"* (user, 2026-07-29).

**THE LEAK.** `IdentityRegistry.register` publishes `holder_root`, `commitment` AND `dg1_hash` as
public inputs, so calldata links every user's IDENTITY to their POOL HANDLE. Activity stays private -
a withdrawal never discloses the commitment, it is a private SMT key - but PARTICIPATION is public
for everyone. It also makes `holderOfDocumentHash(dg1_hash)` a second path to the same link. This is
the largest privacy defect in our own code and it affects every user, not just notaries.

**THE FIX: prove the document binding by INCLUSION, publish no identifier.** The identifiers exist
only so the contract can check `holderOfDocumentHash(dg1Hash) == holderRoot` - the scarcity link
(§2.13n trap 5). Prove that inside the circuit instead and nothing needs publishing.

**EVERY PIECE ALREADY EXISTS - checked, not assumed:**
1. **The committed tree is already there.** `HolderStateKeeper._bindDocument` writes
   `Poseidon(documentKey, holderRoot) -> Poseidon(dgCommit, seq, timestamp)` into
   `StateKeeper.registrationSmt`. We do not need to build or populate anything.
2. **Hashers are compatible.** `PoseidonSMT` uses `PoseidonUnit2L`/`PoseidonUnit3L` - the exact pair
   `SmtCompat.t.sol` already proved byte-identical to the Noir gadget.
3. **Root policy already correct.** `PoseidonSMT.isRootValid` = latest OR within `ROOT_VALIDITY`
   (1 hour), the same always-valid-latest shape as the identity registry. And for an INCLUSION tree
   old roots are SAFE anyway (fewer members), so this is strictly more than needed.
4. **Soundness comes from `dgCommit`, which IS proof-bound.** `documentKey` is NOT constrained by any
   proof (§2.13f), so proving inclusion on the INDEX alone would be weak. But the leaf VALUE contains
   `dgCommit = extract_dg1_commitment(dg1, sk_identity)` - derived from the holder's OWN secret. An
   attacker cannot produce a valid `dgCommit` for someone else's leaf without their `sk_identity`, so
   inclusion plus a re-derived `dgCommit` is sound even though the index is not.

**NEW PUBLIC INPUTS:** `controller_x/y`, `commitment`, `registration_root`, `c1_x/y`, `sealed[5]`.
**GONE:** `holder_root`, `dg1_hash`. `registration_root` is shared by EVERY user, so it identifies
nobody.

**MEASURED: 28,302 ACIR opcodes** for the private binding (identity derivation + `dgCommit` +
depth-32 inclusion). The escrow circuit goes roughly 38,874 -> ~52-55k, about +38%, and it is the
ONE-TIME registration path, never the withdrawal hot path. That is the right place to spend it.

**NOT YET BUILT.** Requires: escrow circuit rewrite, `IdentityRegistry.register` checking
`registrationSmt.isRootValid` instead of `holderOfDocumentHash`, three escrow fixtures and the
verifier regenerated, tests updated.

### 2.18 BUILT. Measured 70,223 - the sec. 2.18 estimate was wrong about the DEPTH

**MEASURED: 38,874 -> 70,223 ACIR opcodes (+81%)**, not the ~52-55k predicted. The prediction sized
the inclusion at DEPTH 32 - the IDENTITY registry's height. `registrationSmt` is a rarime
`PoseidonSMT` initialised at **80** everywhere it is deployed, and `query_identity` already took
`siblings: [Field; 80]`, so the number was checkable and I did not check it.

For context, all measured today: register_identity 72,932 | escrow 70,223 | query_identity_td1
46,797 | withdraw_identity 24,812 | title_holder 12,969 | ragequit 997. Escrow now costs about what
REGISTRATION costs, on the same one-time path. **The withdrawal hot path is untouched at 24,812.**

**PUBLIC INPUTS 12 -> 11.** Gone: `holder_root`, `dg1_hash`. Added: `registration_root`, shared by
every user of the system. The verifier is still **24,491 bytes** - unchanged - which confirms again
that verifier size is flat in public-input count (sec. 2.13i), even across a circuit that nearly
doubled in constraints.

**REUSED `identity_state_verifier` RATHER THAN REBUILDING THE LEAF.** It already existed in
`noir_dl_lib/src/query.nr`, private; made `pub`. A hand-written second copy of
`Poseidon(documentKey, holderRoot) -> Poseidon(dgCommit, seq, timestamp)` would have been free to
drift from the one `query_identity` uses, with nothing to notice.

**TWO DEFECTS CLOSED AS SIDE EFFECTS, both found while wiring it:**
1. **A REVOKED DOCUMENT COULD STILL REGISTER AN IDENTITY.** `_holderOfDocumentHash` is written at
   binding and NEVER cleared - not by `revokeDocument`, not by `renewDocument`. So the old check
   passed for a cancelled passport. The tree cannot be fooled that way: revocation overwrites the
   leaf VALUE with `Poseidon1(REVOKED)`, which no `Poseidon3(dgCommit, seq, timestamp)`
   reconstruction equals. **The new check is strictly stronger than the one it replaces.**
2. **THE ROOT CHECK RAN AFTER PROOF VERIFICATION.** I wrote a comment claiming it ran before, did
   not verify it, and the test caught me: tampering with a public input makes the generated verifier
   revert `SumcheckFailed()` first, so the useful error never surfaced. Reordered - a mapping read
   before a ~500k-gas Honk verification - and now the comment is true.

**RESIDUAL, recorded rather than left implicit (sec. 2.18b).** `PoseidonSMT.isRootValid` = latest OR
within ROOT_VALIDITY (1 hour). Because `revokeDocument` moves a leaf's VALUE, for up to an hour
after a document is cancelled its pre-revocation root still admits an escrow. Bounded and
correctable - the identity is still revocable afterwards - but it is NOT the "old roots are safe on
an inclusion tree" argument sec. 2.18 made, because this tree carries status too.

### 2.18a THE BLACKLIST WAS EVADABLE BY EVERYONE IT APPLIED TO

Found while removing `holder_root`: `IdentityRegistry` guards on `registered[commitment]` and
**nothing else**. While the escrowed secret was freely chosen, a revoked user could escrow a FRESH
secret against the SAME passport, get a DIFFERENT commitment, and register clean. `dg1Hash` still
bound to their `holderRoot`, so every check passed.

**THE FIX IS ONE POSEIDON.** `revocation_secret = Poseidon(sk_identity, "pp:revocation-secret:v1")`,
so the commitment is a FUNCTION of the identity: one identity, one commitment,
`registered[commitment]` becomes the per-holder guard, and re-registration reverts
`AlreadyRegistered`. Pinned by `test_ARevokedIdentityCannotRegisterAgain`, which the old design
could not have passed.

The domain separator is checked against its own string in-circuit
(`test_revocation_domain_is_the_string_it_claims_to_be`) and asserted distinct from
`extract_pk_identity_hash` - both are Poseidon over two fields, and a dropped separator would have
handed anyone who saw a published holder root the secret that revokes it.

**WHAT IT DOES NOT CLAIM:** two passports under two DIFFERENT `sk_identity` values are still two
identities. Nothing in ICAO 9303 links two states' documents - which is exactly why the MRZ rides
inside the envelope for the controller to attribute. What is closed is free re-registration of the
SAME identity, which needed no second passport at all.

### 2.18b THE FIXTURE PIPELINE, and the hand-built steps it replaces

The witness comes from the REAL contract, never rebuilt off-chain - the rule `identityProof.ts` and
`fixture-common.js` already established. Five steps, each consuming the last:

1. `node tools/build-escrow-fixtures.js --documents 3` -> `escrow_documents.json`
2. `forge test --match-test test_EmitRegistrationWitnessFixture` -> `registration_witness.json`
3. `node tools/build-escrow-fixtures.js 3` -> `Prover.escrow<i>.toml`
4. `backend/circuits/codegen-verifiers.sh` -> verifier + vk
5. `tools/prove-escrow-fixtures.sh` -> `escrow_envelope<i>.proof/.public`  **(NEW)**

**`dgCommit` IS TAKEN FROM THE CIRCUIT, NOT REIMPLEMENTED.** The generator shells out to
`nargo execute` on `register_identity_light_td1` and reads its output. Writing
`extract_dg1_commitment` in JS would have meant a second implementation of a bit-packing convention
with three places to get the endianness wrong. Cross-checked: the circuit's `dg1_hash` and `sk_hash`
outputs equal the values the generator computes independently, which is what licenses trusting it
for the one value we cannot derive here.

**STEP 5 DID NOT EXIST.** The three numbered proofs had been produced BY HAND with nothing in the
repo recording the commands - the same defect as a header naming a generator that does not exist.

**THE CROSS-IMPLEMENTATION RESULT THAT MATTERS:** a witness produced by solarity's on-chain
`SparseMerkleTree` is accepted by the circomlib SMT gadget in Noir. That is genuine agreement
between two independent implementations, not a self-consistent loop.

### 2.18c THE COMMITTED ragequit.proof CORRESPONDED TO NO COMMITTED WITNESS

Surfaced by regenerating. `RagequitHonkVerifier.t.sol` has always documented its fixture as the
differential vector `(value 10, label 20, nullifier 30, secret 40)` cross-checked against
poseidon-solidity - but `ragequit/Prover.toml` was overwritten with the END-TO-END witness
(value 1e18, a real label) during the single-identity-tree merge, and the fixture was never
re-proved. So the committed proof was **unreproducible**, and the next codegen run would silently
replace it with one the test rejects. That is exactly what happened.

Fixed with `ragequit/Prover.baseline.toml`, which `codegen-verifiers.sh` prefers over `Prover.toml`
- the same protection `withdraw_identity` already had, and the reason it has it.

### 2.18d THERE IS NO KEY RECOVERY (user, 2026-07-29)

*"there is no recovery possible with the enclave"* - correct, and worse than "an enclave key cannot
be exported". From `frontend/identity-wallet/src/identity/root.ts`:

- `getOrCreateRootMnemonic()` GENERATES a 24-word phrase. **There is no import path anywhere** -
  nothing calls `Mnemonic.fromPhrase` on user input.
- The phrase is **never displayed**, so the user cannot write it down.
- `keychainAccessible: WHEN_UNLOCKED_THIS_DEVICE_ONLY` **excludes it from iCloud Keychain and device
  backups** by design.
- `requireAuthentication: true` binds it to current biometric enrolment, which re-enrolment can
  invalidate.

Lost or wiped phone -> identity and every pool note gone permanently.

**THE NUANCE THAT DECIDES THE FIX:** this is NOT a non-extractable Secure Enclave key. It is a value
STORED IN Keychain/Keystore, readable by the app after biometric auth. So recovery is a feature we
never built, not a physical impossibility.

**AGAINST THE MPC/SOCIAL-RECOVERY SDKs** (Web3Auth, Turnkey, Privy, Para): every one introduces a
server-side party, and most gate on Google/Apple OAuth - precisely the deniable-refusal lever the
distributor argument exists to remove (sec. 2.22c) - plus a US-operated dependency for Iranian
users. It would contradict sec. 5's censorship claims and sec. 7's "no infrastructure to run".

**THE CONSISTENT ANSWER** is an encrypted backup the user controls: the mnemonic sealed under a user
passphrase, ciphertext storable anywhere, recovery = passphrase + blob, no custodian. NOT BUILT.
FUNDING-APPLICATION.md sec. 6 now discloses the gap and puts the fix in milestone 2; the
participation-leak disclosure it replaced is the one closed by sec. 2.18 above.

### 2.18e BOTH DEFECTS ADDRESSED (user: "address the defects")

**1. THE STALE-ROOT WINDOW IS CLOSED, not shrunk.** sec. 2.18b left up to an hour in which a
CANCELLED passport could still register a pool identity, because revoking a document overwrites its
leaf VALUE while roots created earlier keep proving it current, and `isRootValid` accepts those for
the rest of `ROOT_VALIDITY`.

Three small pieces: `PoseidonSMT.getRootTimestamp` (a view - no storage change, UUPS-safe),
`HolderStateKeeper.lastDocumentInvalidationAt` (set by `revokeDocument` AND `renewDocument`), and a
second condition in `register` requiring the cited root be newer than the last invalidation.

**I GOT THE COMPARISON BACKWARDS AND THE TEST CAUGHT IT.** `withRootUpdate` calls `_saveRoot()`
BEFORE mutating the tree, so `_roots[R]` is when R **STOPPED** being current, not when it started -
the opposite of what the getter name suggests, and the reason `isRootValid` means "superseded less
than an hour ago". The root superseded BY the invalidation therefore carries exactly
`lastDocumentInvalidationAt`, so the test must be `<=`. With `<` the very root that still shows the
cancelled document as current would have passed. Both the code and the doc comment I had written
around it were wrong; the boundary is now asserted explicitly in the test because it is the mistake
I actually made.

The LATEST root skips the check and must: the current root has NO `_roots` entry, so it reads as 0
and would be rejected forever. It is also always safe - any invalidation moves the root.

Verified by removal: with the guard deleted the registration SUCCEEDS, so the attack was real and
the test is load-bearing.

**2. KEY RECOVERY EXISTS (sec. 2.18d).** `src/identity/recovery.ts` + wrappers in `root.ts`:
`revealRootMnemonic` (the wallet was previously unbackupable BY CONSTRUCTION - the phrase was
generated on-device and never displayed), `importRootMnemonic`, `exportEncryptedBackup`,
`restoreFromEncryptedBackup`.

**FORMAT: the Web3 keystore v3 ethers already implements** - scrypt N=131072, AES-128-CTR,
MAC-checked. No new dependency, and readable by any standard tool if this wallet disappears, which
for a recovery artefact is the property that matters. Measured first: it round-trips a 24-word
phrase exactly (32 bytes of entropy - the field has a history of assuming 16).

**A PRIVACY DEFECT IN THE OBVIOUS IMPLEMENTATION, found by measuring rather than by review.** The
keystore writes a plaintext `address` - for `m/44'/60'/0'/0/0`, which is EXACTLY the path
`src/pp/notes.ts` uses for Privacy Pool account 0. An unmodified backup would publish, in the clear,
an address derived from the same key material as the user's note secrets: a stable identifier
linking every copy of the backup to every other. Stripped, along with `gethFilename` (address +
creation time) and `id`. **`address` cannot merely be blanked** - ethers checks it against the
decrypted key and rejects a zeroed one; DELETING it restores cleanly. Both behaviours are pinned,
because a future ethers that required the field would break every backup silently.

**GUARDS:** BIP39 validated BEFORE storing (a mistyped phrase derives the WRONG keys perfectly well
and shows an empty wallet, not an error, with the real phrase already overwritten); a
private-key-only keystore is rejected rather than restoring an identity-less wallet; restore refuses
by default over an existing seed (`WalletAlreadyExistsError`) because that is silent and
irreversible; minimum passphrase length, since the file is meant to be stored off the device.

**AGAINST THE MPC SDKs** - unchanged from sec. 2.18d: every one puts a share on a server and most
gate on Google/Apple sign-in, which is the deniable-refusal lever sec. 2.22c exists to remove.

**TESTED BY A SCRIPT THAT RUNS**, per the standing rule. `recovery.ts` is deliberately PURE - no
expo-secure-store, no React Native - so `tools/check-recovery.js` exercises it under node: 14
assertions, verified by removal (deleting the address strip -> 2 FAIL; deleting the
no-mnemonic guard -> 1 FAIL). An import of SecureStore into that file silently deletes the only test
this code has.

Recorded honestly: a two-word SWAP of correct words is not always caught by the BIP39 checksum. The
script reports the real behaviour rather than asserting a hoped-for one.

### 2.18f "ONLY A NOTARY CAN MAKE A MORTGAGE LEGALLY EXIST?" - overstated twice

*(user, 2026-07-29.)* The application said "Only a notary can make a mortgage legally exist - one
registered by anyone else is void." Two errors:

1. **"VOID" IS WRONG.** Under the Land Registration Act (قانون ثبت اسناد و املاک), a private
   document (سند عادی) concerning registered immovable property is **inadmissible before courts and
   government offices** - Article 48 - rather than void ab initio. The practical consequence for us
   is the same (it cannot be foreclosed through the official machinery, and creates no registered
   lien binding third parties), but the legal characterisation is not.
2. **"ONLY" IS TOO BROAD.** A notary monopoly holds for a **CONSENSUAL** mortgage. Non-consensual
   liens exist: the judiciary imposes seizures (*Bāzdāsht*) directly - the spec's own Tier 4. Our
   mortgages are consensual, so the claim holds for our use, but not as stated.

Corrected in FUNDING-APPLICATION.md sec. 2. **This is exactly the class of claim the local counsel
in milestone 3 is budgeted for** - it is drawn from spec.pdf plus general knowledge of Iranian
registration law, not from an opinion by anyone qualified to give one.

### 2.18g THE APPROVAL STEP WE CLAIMED TO HAVE REMOVED IS STILL THERE, ONE LAYER UP

Found while asking which of the 15 untested inherited contracts are actually reachable. **This is
the most serious defect in the design, and it invalidates a claim made in four places.**

**THE CHAIN OF REASONING, each step verified in the code:**
1. `IdentityRegistry.register` IS permissionless - proof-gated, no role, no signature. True.
2. But it requires the document to already be bound in `StateKeeper.registrationSmt` (sec. 2.18).
3. `registrationSmt` is written only via `_bindDocument`, reachable only through
   `HolderStateKeeper.addDocument`/`renewDocument`, both `onlyRegistration`.
4. Our registration contract is `HolderRegistration`. **EVERY** entry point on it -
   `registerDocumentViaNoir`, `renewDocumentViaNoir`, `revokeDocumentViaSigner` - routes through
   `_authenticateDocument`, which does `require(_isSigner(signer_))`.

**SO REGISTRATION IS GATED BY A BACKEND SIGNER'S ECDSA SIGNATURE.** A key we hold can be ordered to
withhold, and the person is blocked - which is EXACTLY the censorship-by-inaction lever the whole
blacklist design exists to remove. We moved the lever upstream and then described the downstream
half as if it were the system.

**THE SECOND FALSE CLAIM, same root cause.** Comments in `IdentityRegistry.sol` and
`escrow_envelope/src/main.nr` both say the ICAO signature chain "is verified during REGISTRATION".
On our path it is NOT verified on-chain at all: `RegistrationSimple` (which `HolderRegistration`
follows) checks a signer's signature and a Noir proof over DG1, and nothing else. **The trust root
for "this is a genuine passport" is our own signer key, not the issuing state's signature.**

**THE FIX IS INHERITED, UNUSED AND UNTESTED - it is those very "15 untested contracts".**
`Registration2.registerViaNoir` takes **NO signature**. It is gated only by a ZK proof against
`certificatesRoot_`, a certificates SMT that `registerCertificate` populates by verifying ICAO
signatures ON-CHAIN against `stateKeeper.icaoMasterTreeMerkleRoot()`, using the certificate
dispatchers and signers (`CECDSADispatcher`, `CRSAPSSSigner`, `CECDSA384Signer`, ...) that showed up
in the untested list. **They are not cruft. They are the trustless path we are not on.**

**THIS REFRAMES THE "UNTESTED CONTRACTS" ITEM ENTIRELY.** It was on the list as a coverage gap. It
is actually the missing half of the censorship-resistance property.

**THE SHAPE OF THE FIX IS ADDITIVE, NOT A REPLACEMENT.** `StateKeeper._registrations` is a MAP of
named registration contracts, so more than one may be authorised at once. The signer path can stay
as the cheap, convenient default; what must exist alongside it is a permissionless path nobody can
withhold - the same relationship `ragequit` has to `withdraw`. A user who is refused a signature
must still be able to register by proving the certificate chain themselves, on-chain, at their own
gas cost.

**NOT YET BUILT.** Requires: an ICAO-verifying registration contract writing into the HOLDER tree
(`addDocument`, not upstream's 1:1 `addBond`); the certificate dispatchers/signers under test for
the first time; and `icaoMasterTreeMerkleRoot` actually populated, which is its own operational
question - who publishes the ICAO master list, and can THAT be withheld?

**CLAIMS CORRECTED MEANWHILE**, rather than left standing while the build is pending:
FUNDING-APPLICATION.md sec. 5 and sec. 6, `IdentityRegistry.sol`, `escrow_envelope/src/main.nr`.

### 2.18h SCOPING THE PERMISSIONLESS PATH - much smaller than feared, and it RELOCATES the gate

**THE DISPATCHERS ARE NOT NEEDED. `register_identity` VERIFIES THE WHOLE ICAO CHAIN IN-CIRCUIT.**
Reading it settles sec. 2.18g's build estimate downward by a lot:
1. `passport_verification_flow` - DG1 hashes into EC, EC into the signed attributes (the SOD chain)
2. `verify_signature` - the DSC's RSA/ECDSA signature over those attributes, in-circuit
3. `smt_verifier::<80>(icao_root, leaf, key, branches)` - the DSC public key's inclusion in the ICAO
   master tree
Returns `(dg15_pk_hash, passport_hash, dg1_commitment, sk_hash)` and passes `icao_root` through.

So the contract needs only: verify the Honk proof, check the root, call `addDocument`.

**I THEN CLAIMED "NO CERTIFICATE DISPATCHER, NO SIGNER CONTRACT". THAT WAS WRONG - SEE sec. 2.18l.**
The dispatchers are what POPULATE the tree the circuit walks. Correction kept in place rather than
edited away, because the reasoning that produced it looked sound: the circuit really does verify the
signature chain in-circuit, and it is easy to conclude from that alone that nothing on-chain needs
to parse a certificate. What it does not tell you is where the tree of legitimate signer keys comes
from.

**THE GATE MOVES, IT DOES NOT VANISH - and the difference is the whole point.**
`StateKeeper.changeICAOMasterTreeRoot` is `onlyOwner`. So:

- **TODAY (signer gate):** per-user, per-registration. The signer can refuse YOU, specifically and
  silently, and nobody else can tell it happened. **This is targeted, deniable discrimination** -
  precisely the failure sec. 2.22c says the whole distributor argument exists to remove.
- **AFTER (ICAO-root gate):** systemic and public. An owner can refuse EVERYONE by freezing the root
  or never updating it. They CANNOT refuse one person, because the proof is self-service and the
  root is global. A stale root is publicly observable.

**Converting a targeted, invisible, per-person refusal into an all-or-nothing visible one is the
property we actually need.** You cannot discriminate with an all-or-nothing lever. Claiming "no gate"
would still be false, and I should not write that.

**THE REMAINING STEP, for later:** anchor the ICAO root through the same CRE consensus pattern the
notary registry uses (`ConsensusIdenticalAggregation`, every DON node fetching independently and
agreeing byte-for-byte). That removes the owner's discretion over the root too. The ICAO master list
is public data, so this is the same shape of problem as indexing the notary register.

**A TRAP TO AVOID WHEN BUILDING IT - THE ANTI-REPLAY KEY DIFFERS BETWEEN THE TWO PATHS.**
`HolderRegistration._replayKey` uses `dg1Hash`, which is what the LIGHT circuit returns. The full
circuit returns `passport_hash` (over the SOD's signed attributes) and NOT `dg1_hash`. If the
permissionless path keyed anti-replay on `passportHash` while the signer path keys on `dg1Hash`,
**the same physical passport could be bound TWICE, under two different holder roots** - destroying
the document-scarcity guarantee the whole identity blacklist rests on. That is the exact defect
sec. 2.13n's `_replayKey` fix closed, reappearing through a second door.

Fix: add `dg1_hash` as an extra public output of `register_identity`. The sha256 over DG1 is already
computed inside `passport_verification_flow`, so it costs ~nothing beyond the output slot. Do NOT
switch the light path to `passportHash` - it is not proof-bound there, which is what started this.

**ALSO NOTE THE LENGTHS DIFFER.** `register_identity`'s main takes `[u8; 93]` (TD3) while our light
path and `escrow_envelope` are 95 (TD1). A TD3-registered document could not be escrowed until the
TD3 escrow variant already noted in `escrow_envelope/src/main.nr` exists. A TD1 variant of the full
circuit is the smaller move.

**BUILD ORDER:** dg1_hash output + TD1 variant of the full circuit -> Solidity verifier via
codegen-verifiers.sh -> a signature-free entry point binding via `addDocument` -> tests -> then the
CRE anchoring of the ICAO root as a separate piece.

### 2.18i THE ANTI-REPLAY TRAP IS ELIMINATED STRUCTURALLY, NOT BY REMEMBERING

sec. 2.18h recorded a trap to avoid when building the permissionless path: the two registration
paths would key anti-replay on DIFFERENT values (`dg1Hash` from the light circuit, `passport_hash`
from the full one), letting the SAME passport bind twice under two holder roots - once through each
door - and destroying the document scarcity the identity blacklist rests on.

**A note saying "remember not to do this" is not a fix.** Three changes make it structural:

1. **ONE DEFINITION OF THE PACKING.** `lite::dg1_hash_field` extracted from
   `register_identity_light`. The convention - skip digest[0], read the remaining 31 bytes
   big-endian - is not obvious (32 bytes do not fit BN254, and this drops the FIRST byte rather than
   truncating the last), so a second hand-written copy was the likeliest way to diverge.
   **Behaviour-preserving, verified on the committed vector: dgCommit, dg1_hash and sk_hash all
   byte-identical, and the circuit is 16,180 opcodes exactly as before.**
2. **THE FULL CIRCUIT NOW RETURNS `dg1_hash`** as a sixth public output, computed with that same
   function. 72,932 -> 73,348 opcodes (+416, the extra sha256 - consistent with the 396 measured for
   the same binding in sec. 2.13i). The permissionless path can therefore key on exactly what
   `_replayKey` already uses.
3. **TWO TESTS, AND ONLY ONE OF THEM WORKS - WHICH I FOUND BY BREAKING IT.**
   `register_identity::test_dg1_hash_agrees_with_the_light_registration_path` compares the two
   paths, but both call the shared function, so corrupting the packing moves both together and **the
   test still passed**. It catches a path that INLINES its own copy, which is the realistic
   regression, and nothing more. The load-bearing guard is
   `lite::test_dg1_hash_field_matches_the_published_vector`, a KNOWN-ANSWER test against a value
   computed OUTSIDE Noir - the fixture generator's own sha256 and packing loop, which the committed
   escrow proofs and `HolderStateKeeper` have agreed with all along. **That one fails when the
   packing changes.** Verified both ways.

   The doc comment on the first test originally claimed it "makes the trap unreachable". It does
   not, and it now says what it actually does.

**STILL BLOCKED, AND HONESTLY SO: THE SOLIDITY SIDE CANNOT BE VERIFIED YET.** A proof from
`register_identity` needs `ec`, `sa`, `pk`, `sig` and an ICAO inclusion branch - i.e. REAL PASSPORT
DATA, signed by a real DSC that chains to a real CSCA. We have none, which is exactly what milestone
3's field work exists to obtain. Writing the contract entry point now would mean shipping a path no
test can execute, against the standing rule.

**WE DO TRUST RARIME'S CIRCUIT. THAT IS NOT WHAT THE FIXTURE IS FOR** *(user, 2026-07-29: "rarime
tested this with real passports, so why cant we trust their outputs?")*. Two different questions:

1. **"Does `register_identity` correctly verify a real passport?"** Rarime's question, answered by
   them against real documents, and the vendored library carries their primitive vectors -
   `rsa` 2048/3072/4096, `rsa_pss` at four salt/hash combinations, `sigver` ECDSA over curves
   192/224/384/521, the whole SHA family. **We inherit all of it and I am not proposing to re-verify
   any of it.**
2. **"Does OUR generated Honk verifier accept a proof from that circuit, and does OUR contract bind
   the document correctly?"** Ours, and it needs one concrete proof to exist. Not because rarime
   might be wrong - because every generated verifier in this repo is exercised on-chain against a
   real proof, and one that has never accepted a proof is a liability (see
   EscrowEnvelopeHonkVerifier.t.sol's header for the phase `WithdrawalHonkVerifier` spent in exactly
   that state).

**AND THE TRUST DOES NOT TRANSFER TO THEIR PROOF, ONLY TO THEIR WITNESS.** We compile from vendored
source with our own nargo/bb pins and generate our own verifier. A proof made against rarime's
HOSTED bytecode would not verify against our verifier unless the two circuits are byte-identical -
which is precisely what we cannot assume, since we have already modified this circuit (sec. 2.18i
added a sixth public output). So: **reuse their INPUTS, generate our own proof.**

**REVISED PLAN, cheapest first:**
1. **Look for a committed witness in rarime's `passport-zk-circuits`** - their CI has to prove these
   circuits, so a Prover.toml or equivalent test input very likely exists. If it does, this is a
   download rather than a build. NOT YET CHECKED - the vendored `noir_dl_lib` carries primitive
   vectors only, no end-to-end DG1+EC+SA+signature+ICAO-branch witness.
2. Only if none exists: construct one synthetically. Genuinely possible, since the circuit verifies
   a signature chain and not a state - generate a CSCA/DSC keypair, build a conforming SOD at the
   offsets `DG1_SHIFT`/`EC_SHIFT` expect, sign it, and build an ICAO tree containing that DSC key.

Either way it is fixture generation, not protocol work.

### 2.18j THE LIVE PATH IS BUILT FOR ID CARDS, AND EVERY DOCUMENT WE WROTE SAYS PASSPORT

Found while checking whether escrow's hardcoded `DG1_LEN = 95` can accept a real document. It can -
just not the document we keep claiming.

**THE TWO ICAO LAYOUTS ARE DIFFERENT LENGTHS AND NEED DIFFERENT CIRCUITS:**
- **TD3**, the passport booklet: 2 MRZ lines x 44 chars -> DG1 of **93** bytes.
- **TD1**, the ID card: 3 MRZ lines x 30 chars -> DG1 of **95** bytes.

**WHERE EACH CIRCUIT SITS**, measured across the repo:

| circuit | DG1 | layout |
|---|---|---|
| `query_identity` | 93 | TD3 |
| `query_identity_td1` | 95 | TD1 |
| `register_identity` (full, permissionless) | 93 | TD3 |
| `register_identity_light_td1` (live path) | 95 | TD1 |
| `escrow_envelope` | 95 | TD1 |

**SO THE LIVE PATH IS TD1 END TO END, AND THE PERMISSIONLESS PATH IS TD3 END TO END. They cannot
interoperate at all**: a document registered through `register_identity` (93) can never be escrowed,
because escrow computes `dgCommit` over 95 bytes and the SMT inclusion would fail. That is a second,
independent reason sec. 2.18g's build needs a length decision before any contract is written.

**AND THE WALLET CONFIRMS IT.** `Rarime.ts:404` selects `register_light_<hashLength>` from the
UPSTREAM rarime SDK, not from our bundled assets - and every URL in that SDK's registry is under
`storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/**id_cards**/`:
`query_identity_td1.json`, `register_lite_256.json`, and so on. The wallet is wired to the ID-CARD
circuit family. Our own TD3 `query_identity` is built and bundled by nothing.

**THE CODE IS COHERENT; THE PROSE IS NOT.** Everything says "passport": FUNDING-APPLICATION.md ("the
passport chip", "real passports", "passports from several issuing states"), the contract NatSpec,
this repo's own headers - while the shipped path reads national ID cards.
`HolderStateKeeper` already has both `DOC_PASSPORT` and `DOC_NATIONAL_ID`, so the DESIGN always
contemplated both; only the circuit wiring picked one.

**THIS IS A MILESTONE-3 SURPRISE CAUGHT EARLY.** "Test with real passports from several issuing
states" would have failed at the first scan, and the cause - a 93-byte DG1 meeting a 95-byte circuit
- names nothing about passports at all.

**IT IS ALSO NOT AN ARCHITECTURE PROBLEM.** Supporting booklets means pointing at the passport
circuit family upstream publishes alongside `id_cards/`, plus a 93-byte `escrow_envelope` variant.
Config and one circuit variant, not a redesign. **The decision to take first is which document the
product is actually for** - and for Iran that is worth asking properly, since the smart national ID
(*kart-e melli-ye hushmand*) is far more widely held than a passport, and a passport is exactly the
document a person under pressure is most likely to be denied or have confiscated.

**ALSO CORRECTED:** `EscrowEnvelopeHonkVerifier.t.sol` described its fixture as "a full 95-byte TD3
layout". 95 is TD1. The fixture is a passport-style MRZ inside a TD1-sized buffer - harmless as a
test vector, since nothing parses the MRZ, and actively misleading read as a real document.

### 2.18k THE ICAO INCLUSION PROOF IS VACUOUS BY ITSELF - THE CONTRACT CARRIES ALL OF IT

Went and looked instead of planning around it (user, 2026-07-29: *"do it immediately instead of
waiting"*). `rarimo/passport-zk-circuits-noir` ships **no committed witness** - `register_identity/js/`
holds the GENERATOR (`process_passport.js`, `asn1.js`, `poseidon.js`, `autogen.sh`) and the input is
just `{dg1, dg15, sod}`, supplied by you. So there is nothing to download, and that is the small
finding.

**THE LARGE ONE IS HOW THEIR GENERATOR BUILDS THE ICAO PROOF:**

```js
function getFakeIdenData(ec, pk){
    const branches = new Array(80).fill(0);
    ...
    const root = poseidon([pk_hash, pk_hash, 1n]).toString(16)
    return [sk_iden, root, branches]
}
```

Eighty ZERO branches, and a root that is `Poseidon(pk_hash, pk_hash, 1)` - precisely
`smt_hash1(key, value)` with key = value = this passport's own DSC key. **A single-leaf tree
containing only the document being registered.** With all-zero siblings the SMT verifier's
`levels[0]` reduces to exactly that hash, so it accepts by construction.

**SO THE IN-CIRCUIT ICAO CHECK PROVES NOTHING ON ITS OWN.** An attacker can:
1. generate their own CSCA/DSC keypair,
2. sign a fabricated SOD over a fabricated MRZ,
3. set `icao_root = Poseidon(their_pk_hash, their_pk_hash, 1)`,
4. produce a **completely valid** `register_identity` proof.

The only thing between that and a registered identity is the contract checking the proof's
`icao_root` public output. **That single check is the entire security of the permissionless path.**
sec. 2.18h described it as a formality alongside the real work; it is the reverse.

**AND I NAMED THE WRONG CHECK - see sec. 2.18l.** It is NOT a comparison against
`icaoMasterTreeMerkleRoot()`. That would reject every genuine proof.

**THIS IS THE SAME SHAPE AS THE BLACKLIST VACUITY** that made `escrow_envelope` necessary in the
first place: a proof that is perfectly sound about a structure the prover chose. Recorded here
because the trap is invisible at the point it matters - a contract that simply forgot the check
would pass every test written against a fixture, since the fixture's own root would be configured
into the state keeper.

**THE TESTING SPLIT THIS FORCES, and its own trap.** A fixture must use the fake single-leaf root
(we have no real DSC private key, and never will). So tests configure the state keeper with the
FIXTURE's root, and production configures the real ICAO master root. A test suite that only ever
does the former proves the happy path and nothing else. **Mandatory alongside it: a test that a
proof carrying a DIFFERENT `icao_root` is REJECTED** - that is the one asserting the property, and
it is the one that would fail if the contract's check were dropped.

**DECISION: WE DO NOT FAKE THE ROOT** *(user, 2026-07-29: "we cannot fake it. we must avoid the
trap.")*. Not in a fixture, not behind a flag, not "temporarily". A fake root is one
`changeICAOMasterTreeRoot` call away from production, and the failure it produces - forged documents
admitted as genuine - is silent and total. The real ICAO master list is published; building the tree
from it is work, not a research problem.

**THE HONEST CONSEQUENCE: THE POSITIVE PATH CANNOT BE TESTED UNTIL A REAL DOCUMENT EXISTS.** A valid
proof needs a SOD signed by a DSC whose key is genuinely in that list, and no synthetic keypair can
be. That waits for milestone 3, and pretending otherwise is precisely the trap.

**BUT THE GUARD ITSELF IS TESTABLE TODAY, and the ordering is what makes it so.** Check `icao_root`
against `StateKeeper.icaoMasterTreeMerkleRoot()` **BEFORE** verifying the Honk proof - the same
ordering sec. 2.18e settled on for `UnknownRegistrationRoot`, and for the same reason. Then the
negative test needs no valid proof at all: hand it arbitrary bytes with a wrong `icao_root` and
assert it reverts on the root rather than on the proof. **The test that carries the property runs
now; only the happy path waits.** That is the opposite of the usual arrangement, and it is the right
way round - the guard is what protects users, and it is the half we can prove.

**THE STANDING CAVEAT FOR THIS TODO:** everything sec. 2.18w's table guarantees is downstream of
someone publishing the right list. `changeICAOMasterTreeRoot` is `onlyOwner`, so **that is a trust
assumption and not a proof**, and it stays one until the root is anchored through CRE consensus.
Worth re-reading before anyone treats the forgery inventory as closed.

**WHAT STILL NEEDS DOING, AND IT IS NOT A FIXTURE:** obtain the ICAO master list (the PKD publishes
CSCA certificates; several states publish their own), build the depth-80 tree with the same leaf
convention `extract_pk_hash` uses, and get that root on-chain. Anchoring it through CRE consensus
rather than an owner setter (sec. 2.18h) then removes the last discretionary lever in one move -
these are the same piece of work, not two.

**NOTE THE SOD's SHA-1 IS NOT OUR `dg1_hash`.** `DG_HASH_TYPE = 20` governs the DG hashes INSIDE the
SOD; sec. 2.18i's `dg1_hash` output is sha256 over DG1 and matches the light path. Two different
digests over the same bytes, and conflating them would put a 20-byte value where the anti-replay key
belongs.

Also note their generator derives `sk_identity` from the EC hash - a throwaway. Ours must use the
USER's key, since `holder_root` derives from it.

### 2.18l THE TRUST CHAIN IS TWO LEVELS, AND I HAD THE WRONG ONE (user: "are you sure?")

Asked to check the task for missing context, and it was missing context AND wrong twice. Traced
properly this time, each step read rather than inferred.

**THE ACTUAL STRUCTURE:**

| | what it holds | how it is set | who may write |
|---|---|---|---|
| `icaoMasterTreeMerkleRoot` | keccak256 Merkle tree of **CSCA** public keys | `changeICAOMasterTreeRoot` | **owner only** |
| `certificatesSmt` | Poseidon SMT of **DSC** key hashes | `registerCertificate` | **anyone** |

`Registration2.registerCertificate` is the bridge: it proves a CSCA is in the master tree
(`icaoMerkleProof_.processProof(keccak256(icaoMember_.publicKey)) == icaoMasterTreeMerkleRoot`),
verifies THAT CSCA's signature over a DSC's signed attributes, extracts the DSC public key, and adds
it to `certificatesSmt`.

**THE CIRCUIT WALKS `certificatesSmt`, NOT THE MASTER TREE.** `register_identity` computes
`leaf = extract_pk_hash(pk)` where `pk` is the key that SIGNED THE SOD - a DSC - and sets
`key = leaf`. `StateKeeper.addCertificate` stores exactly that shape:
`certificatesSmt.add(certificateKey_, certificateKey_)`, key equals value. And
`Registration2.registerViaNoir` feeds its `certificatesRoot_` into the circuit's `icao_root`
parameter, gated by `PoseidonSMT(stateKeeper.certificatesSmt()).isRootValid(...)`.

**SO THE PARAMETER IS MISNAMED**, and the correct check is:

    PoseidonSMT(stateKeeper.certificatesSmt()).isRootValid(icao_root)

Comparing against `icaoMasterTreeMerkleRoot()` - what sec. 2.18k said - would reject every genuine
proof while looking principled. A trap of exactly the kind this section exists to catch, produced by
trusting a parameter name.

**TWO CORRECTIONS THAT MAKE THE POSITION BETTER, NOT WORSE:**

1. **THE DISPATCHERS ARE NEEDED AFTER ALL** (sec. 2.18h said the opposite, and the task dropped
   because of it should not have been). `ICertificateDispatcher` and the `C*Signer` contracts are
   what `registerCertificate` uses to verify a CSCA signature and parse a DSC key out of X.509.
   Without them `certificatesSmt` stays EMPTY and no permissionless registration can ever verify.
   They are not legacy-Circom cruft; they are the supply line.
2. **DSC ENROLMENT IS ALREADY PERMISSIONLESS.** `registerCertificate` takes no signature and no
   role. So the only owner-controlled input in the whole chain is the CSCA master root - and CSCAs
   are issued roughly once per country per several years, where DSCs turn over constantly. **We do
   not have to maintain a DSC list at all**; anyone can add one, self-service, and the owner lever
   shrinks to a small, slow, publicly-checkable value. That is a far better position than sec. 2.18k
   assumed.

**CHECKED FOR A GRIEFING VECTOR AND DID NOT FIND ONE:** `revokeCertificate` is also permissionless,
but `StateKeeper.removeCertificate` requires `expirationTimestamp < block.timestamp`, so a caller
can only remove certificates that have genuinely expired.

**WHAT THE TASK ACTUALLY IS**, restated: publish the CSCA master root (owner, once, then rarely);
get the dispatchers and signers under test since they gate every DSC admission; write the
registration entry point checking `certificatesSmt.isRootValid` BEFORE proof verification so the
negative test needs no valid proof; and anchor the CSCA root through CRE consensus to remove the
last discretionary lever.

### 2.18m OUT-OF-BOUNDS READ IN X509.extractPublicKey - found by testing what 2.18l reinstated

sec. 2.18l put the certificate dispatchers back on the list because they gate every DSC admission.
Writing their first tests found this in the library underneath them.

**THE DEFECT.** `X509.extractPublicKey(sa, prefix, keyOffset_, keyLength_)`:
- `_checkPrefix` validates only the bytes IMMEDIATELY BEFORE `keyOffset_`;
- nothing checked that `keyOffset_ + keyLength_` stayed inside `sa`;
- the copy is `MemoryUtils.unsafeCopy`, a raw identity-precompile memcpy - **no bounds check of any
  kind**, it moves `size_` bytes from a pointer.

So an offset near the end silently read **adjacent memory** into the extracted key. Demonstrated
before fixing: a 32-byte key read from offset 64 of a 64-byte array returned successfully and
contained none of the array's filler, and a 512-byte key was read out of 64 bytes of attributes.

**WHY IT WAS REACHABLE RATHER THAN THEORETICAL.** `keyOffset` is a caller-supplied field of
`Registration2.Certificate`, and the CSCA signature covers `signedAttributes` - **not the offsets**.
So anyone holding ONE genuine CSCA-signed certificate could resubmit it with a different
`keyOffset`, in a call whose other arguments (`icaoMember.publicKey`, `icaoMember.signature`) are
also theirs and land in adjacent memory. The extracted value goes to `StateKeeper.addCertificate`
and into `certificatesSmt` - **the tree `register_identity` proves membership in** (sec. 2.18l). A
key an attacker controls, admitted there, lets them sign their own SODs and enrol fabricated
identities through the permissionless path. That is the path sec. 2.18g exists to build.

**THE FIX** is one require in `extractPublicKey`, with the boundary case (`keyOffset_ + keyLength_
== length`, a key ending flush with the attributes) still accepted since that is ordinary.

**VERIFIED BY REMOVAL:** deleting the require makes both regression tests fail with "did not revert
as expected". Seven tests total, including a known-answer test for `extractExpirationTimestamp`
against the worked example in X509's own doc comment - 2030-09-11 07:21:26 UTC = 1915341686, which
the library computes correctly. **My first assertion for that was wrong and the contract was right**;
recomputed rather than adjusted to match.

**THE GENERAL SHAPE, worth carrying forward:** signatures cover CONTENT, not the OFFSETS used to
read it. Anywhere a signed blob is parsed with caller-supplied indices, the indices are unauthenticated
input even though the blob is authenticated. `Registration2.Certificate` carries `keyOffset` AND
`expirationOffset`.

**AND THE SECOND ONE WAS WORSE THAN "SAFE BY ACCIDENT OF STYLE" - MEASURED, NOT ASSUMED**
*(user: "no accidents of style")*. `extractExpirationTimestamp` was described here as safe because
Solidity bounds-checks its indexed reads. Removing the newly-added `require` to check that claim
showed something else: it reverts with **Panic(0x11), arithmetic underflow**, not Panic(0x32). The
ASCII conversion `uint8(byte) - 48` underflows on a zero byte BEFORE the index ever goes out of
range. So the thing stopping the read was not the bounds check at all - it was an unrelated
subtraction on whatever happened to be in memory.

**WHICH MEANS THE PROTECTION DEPENDED ON THE DATA.** Out-of-bounds bytes that happened to be ASCII
digits ('0'-'9') would not underflow, and the function would have parsed a timestamp out of memory
past the end of the array and returned it successfully. Explicit bound added, with the boundary case
(twelve digits ending flush with the attributes) still accepted, and both pinned by tests.

### 2.18n THE PERMISSIONLESS ENTRY POINT IS BUILT, AND ITS GUARDS ARE TESTED

*(user: "can this remaining ICAO work be done now?")* The part that protects users, yes.

`HolderRegistration.registerDocumentViaIcao` takes **no signature**. It consumes a
`register_identity` proof and the caller must satisfy only arithmetic.

**WHAT THE CALLER DOES NOT GET TO CHOOSE, each for a reason:**

- **THE VERIFIER - and this is the hole that removing the signature CREATES.**
  `registerDocumentViaNoir` reads `passport_.verifier` from its caller, which is safe ONLY because
  the backend signature covers the whole struct including that field. Delete the signature and a
  caller would pass their own contract whose `verify` returns true unconditionally and register
  anything at all. So it is owner-set storage, `icaoRegistrationVerifier`, with no argument for it.
  **The signer path looks like precedent for accepting it from the caller. It is the opposite.**
- **`documentKey`** - taken from the proof's `passportHash` rather than an argument. The signer path
  uses caller-supplied `passport_.publicKey`; here it is proof-bound, strictly better and free.
- **the anti-replay key** - `dg1Hash`, the same value `_replayKey` uses, which is why sec. 2.18i
  added that output.
- **`docType`** - fixed to `DOC_PASSPORT`; `register_identity` IS the passport circuit.
- **`notAfter`** - fixed to 0. Nothing in the proof attests an expiry, so accepting one would record
  a caller's claim about themselves as though it were established.

**CARRIED FORWARD ON THIS TODO:** the happy path cannot be exercised until a real document exists,
so **the `icao_root` check is proven only by its negative test** - and the CSCA master root it
ultimately rests on is OWNER-SET (sec. 2.18h), which is a trust assumption, not a proof. Neither is
a reason to delay the rest; both are reasons not to read the guard table in sec. 2.18w as an
all-clear.

**THE ROOT IS CHECKED BEFORE THE PROOF**, which is what makes any of this testable now: the negative
tests hand it arbitrary bytes and assert it reverts on the root, never reaching the verifier. Order
those two the other way and none could be written until a real passport existed. **Seven tests, all
negative, and that is the right way round** - the guards are the half that protects users and the
half we can prove. The happy path waits for milestone 3, with no fake root (sec. 2.18k).

### 2.18o `isRootValid` ACCEPTED ROOTS THE TREE HAD NEVER HELD

Found by the above: a guard test that did NOT warp - the natural way to write one - silently passed.

```solidity
return isRootLatest(root_) || _roots[root_] + ROOT_VALIDITY > block.timestamp;
```

`_roots[unknown]` is 0, so for an invented root this reads `0 + 3600 > block.timestamp` - **TRUE
for every root that has never existed, until an hour past the epoch.** Live chains are long past
that, which is the only reason it was ever safe. **Another protection that came from a fact about
the world rather than from anything the code says** - the third in a row, after X509's key read
(sec. 2.18m) and its expiration read, where removing the guard revealed the real stopper was an
unrelated arithmetic underflow.

**THE BLAST RADIUS IS EVERY ROOT CHECK IN THE SYSTEM.** `IdentityRegistry.register`,
`HolderRegistration.registerDocumentViaIcao` and `Registration2`'s certificate gate all reduce to
this function, and each is a guard standing in front of a proof. A fresh chain, an L2 or devnet
counting from a low timestamp, or any un-warped test accepts ARBITRARY roots. A guard that silently
passes is worth less than no guard, because it is trusted.

Fixed with an explicit existence check (`supersededAt_ != 0 && ...`), and pinned by
`test/state/PoseidonSMTRootValidity.t.sol` - five tests including the un-warped case that exposed
it, the latest root staying valid however old, and a superseded root expiring on schedule. Verified
by removal.

**THEN GREPPED THE PATTERN AND FOUND TWO MORE COPIES** *(user: "keep looking for latent defects
along adjacent lines")*. The identical expression, in two contracts that each guard proofs and
neither of which had a single test:

- **`L1RegistrationState.isRootValid`** - the L1 state `RegistrationSMT` extends.
- **`RegistrationSMTReplicator.isRootValid`** - the **L2 MIRROR**, and the worst of the three. This
  contract exists to run on a rollup, and **a chain counting from a low timestamp is its ordinary
  deployment target, not an exotic case.** Every proof consumed against a replicated root on a young
  L2 would have been guarded by a check that returned true for anything.

Both fixed the same way, and pinned by `test/state/RootValidityCopies.t.sol` - ten tests, the
un-warped case for each, plus latest-never-expires and superseded-does. Verified by removing both
existence checks: exactly the two un-warped tests fail, which is the signature of the defect.

**THREE COPIES IS THE FINDING, NOT THE BUG.** The expression was duplicated rather than shared, so
fixing one left two live. `IPoseidonSMT` is the interface all three answer to; the validity RULE
lives in none of them.

### 2.18p ADJACENT-LINE SWEEP: what the pattern is, and where it did NOT appear

The three defects in sec. 2.18m-2.18o share one shape: **a guard that holds because of a fact about
the world rather than because the code says so.**

- X509 key read - safe only while offsets happened to be small.
- X509 expiration read - "safe because Solidity bounds-checks", and on inspection the real stopper
  was an unrelated `byte - 48` underflow that would NOT have fired on ASCII digits.
- `isRootValid` x3 - safe only while `block.timestamp > 1 hour`.

**CHECKED ALONG THE SAME LINES AND FOUND THESE ALREADY SOUND**, recorded so the sweep is not
repeated:
- `Bytes2Poseidon.hash512/hash1024` - explicit `assert(length >= n)`. Deliberate, not incidental.
- `StateKeeper.removeCertificate` - permissionless, but requires the certificate be genuinely
  expired, so the open `revokeCertificate` is not a griefing vector.
- `X509._checkPrefix` - reads `offset - prefixLength`, which underflows and reverts on 0.8.x for a
  too-small offset. Bounded by the language in a way that cannot be rewritten away, unlike the
  indexed read two functions down.
- `PoseidonSMT.getRootTimestamp` (added in sec. 2.18e) - returns 0 for an unknown root, and its only
  consumer compares `<= lastDocumentInvalidationAt`, so an unknown root fails CLOSED.

### 2.18q THE RULE IS NOW SHARED, AND ONE EDIT BREAKS ALL THREE

sec. 2.18o ended on "three copies is the finding, not the bug" and left the duplication standing.
Closed now: `contracts/state/RootValidity.sol` holds the rule once, and `PoseidonSMT`,
`L1RegistrationState` and `RegistrationSMTReplicator` each reduce to a single call.

**NO STORAGE IN THE LIBRARY.** Every caller keeps its own mapping and its own `ROOT_VALIDITY`; only
the DECISION moved. That is what makes this safe to adopt in three contracts that are already
UUPS-upgradeable - their layouts are untouched, so it is a logic change and not a migration.

**THE PROPERTY, VERIFIED THE ONLY WAY THAT MEANS ANYTHING.** Deleting `recordedAt_ != 0` from the
library - ONE edit - now fails five tests across three suites: the un-warped case for each of the
three trees, plus both permissionless-enrolment guards that stand on top of them. Before this,
the same edit in one file failed one test and left two contracts silently broken. **That difference
is the whole point of the change**, and it is why the fix was not finished when the arithmetic was.

Three clauses documented where the rule lives rather than at three call sites: the zero root is
never valid (it is the empty-tree sentinel AND the default of any unset slot); the latest root is
always valid however old (inaction must not become censorship); a superseded root is valid only
briefly AND only if it existed.

Contract sizes unchanged in substance - `PoseidonSMT` 10,055 bytes, `L1RegistrationState` 4,572,
both far under EIP-170. Client ABIs re-checked.

### 2.18r MY OWN MISTAKE: I BUILT THE ENTRY POINT ON THE WRONG SIDE OF sec. 2.18j

*(user: "did you fix the mistake?")* The `isRootValid` defect was fixed and shared (2.18o/2.18q).
This is a different one, and it is mine, made in the same turn that built `registerDocumentViaIcao`.

**THE ENTRY POINT REGISTERS DOCUMENTS THAT CAN NEVER REACH THE POOL.** It pins the
`register_identity` verifier - TD3, `DG1_LEN = 93`. `escrow_envelope` computes `dgCommit` over
**95** bytes. A leaf written by this path can never be reproduced by escrow, so the identity can
never be registered and the deposit never shielded.

**sec. 2.18j RECORDED EXACTLY THIS AND I BUILT ON IT ANYWAY**, which is the part worth keeping:
knowing an incompatibility and then not checking which side of it you are standing on is a
distinct failure from not knowing. The guards are right, the tests are real, and the path is inert.

**THE FIX IS ONE DECISION, NOT MORE CODE**, and it is the same decision sec. 2.18j asked for:
- a **93-byte `escrow_envelope` variant**, so booklets work end to end; or
- a **95-byte `register_identity` variant**, so the permissionless path matches the live TD1 path
  and the wallet's upstream `id_cards` circuits.

The second is the smaller move and matches what the wallet actually reads today. **Neither can be
VERIFIED end to end without a witness** (sec. 2.18k), so I have not manufactured a circuit variant
whose SOD parameters nothing can check - that would be the unexercised-verifier mistake in another
costume. What IS verifiable today, and should come with either variant, is the cross-path agreement
test from sec. 2.18i: `dg1_hash` must match `register_identity_light` at the SAME length.

Noted at the function itself, not only here, so a caller-facing NatSpec says the path does not yet
reach the pool.

### 2.18s A BUG IN @solarity/solidity-lib: HALF OF ALL VALID RSA-PSS SIGNATURES WERE REJECTED

Thread A of the three open threads was "get the certificate dispatchers under test". Writing the
first one found this.

**`RSASSAPSS._pss` READ THE WRONG END OF THE MODULUS.**

```solidity
uint256 leadingBits_ = LibBit.clz(uint256(uint8(n_[n_.length - 1])) << 248);
uint256 sigBits_ = (sigBytes_ * 8 - leadingBits_ - 1) & 7;
```

`n_` is BIG-ENDIAN - `_rsa` hands it straight to the modexp precompile, which requires that - so the
most significant byte is `n_[0]`. Reading `n_[n_.length - 1]` counts leading zeros off the LEAST
significant byte. `sigBits_` is `emBits & 7`, used to mask the leftmost byte of DB, so a wrong value
fails the encoding check on a perfectly valid signature.

**IT IS A COIN FLIP PER KEY.** `leadingBits_` comes out 0 - the correct answer for any well-formed
RSA modulus - only when that last byte happens to be >= 0x80.

**MEASURED, NOT INFERRED.** Five 2048-bit keys from openssl, every signature independently confirmed
valid by openssl AND by a pure-Python RSASSA-PSS verifier written for the purpose (trailer, PS
padding, salt recovery and H' comparison all checked separately):

| modulus last byte | before fix | after fix |
|---|---|---|
| 0x41 | **rejected** | accepted |
| 0x85 | accepted | accepted |
| 0x99 | accepted | accepted |
| 0xeb | accepted | accepted |
| 0xff | accepted | accepted |

**WHAT IT WOULD HAVE COST US.** `CRSAPSSSigner.verifyICAOSignature` is the gate on
`Registration2.registerCertificate`, which is the ONLY way a DSC enters `certificatesSmt` - the tree
`register_identity` proves membership in (sec. 2.18l). So **roughly half of all legitimate CSCA
certificates would have been rejected**, permanently and for no discoverable reason, silently
denying enrolment to everyone holding a document signed under those keys. On a project whose entire
argument is that nobody can be refused, an arbitrary 50% refusal rate is close to the worst
available failure.

**IT WAS FAIL-CLOSED, AND THAT IS WORTH BEING PRECISE ABOUT** *(user: "coin flip doesnt sound
secure")*. The coin flip governed AVAILABILITY, not soundness. `sigBits_` sets how many leading bits
of DB must be zero; enumerating all 256 possible last bytes, the buggy value is **never larger** than
the correct 7 - it is either exactly right (129 of 256) or SMALLER, meaning a STRICTER mask
demanding more zero bits. So the defect could only ever **reject a valid signature**, never accept an
invalid one.

That makes it a censorship failure rather than a forgery risk - which on this project is still
severe, since arbitrary 50% refusal is precisely the outcome the design exists to prevent, but it
means no forged certificate could have entered `certificatesSmt` through it.

**IT WOULD NOT HAVE BEEN CAUGHT LATER EITHER.** A single test vector has a 50% chance of picking a
working key, and the failure looks like "invalid signature" - indistinguishable from a genuinely bad
certificate. The committed vector is deliberately one that ends 0x41.

**FIXED IN PLACE.** `lib/solidity-lib` is vendored into this repo as tracked files rather than a
submodule, so it is ours to correct; the change is `n_[0]` with a comment recording why. Worth
reporting upstream - it affects every consumer of `RSASSAPSS`, not just us.

**THE DIAGNOSIS PATH IS THE REUSABLE PART.** The positive test failed while all four negative tests
passed, which is the signature of "the implementation is wrong", not "the vector is wrong" - a
broken verifier usually fails OPEN, accepting everything. Confirming the vector against two
independent implementations before touching the contract is what turned a puzzling red test into a
located bug, and is why the expectation was never adjusted to match the code.

### 2.18t UNUSED-LIB AUDIT: one remapping was an open door to breaking a stated invariant

*(user: "make sure there are no unused libs")* Scanned every import in `contracts/` against actual
use, and every remapping against the tree.

**THREE GENUINELY DEAD IMPORTS, REMOVED:** `ECDSA` in `Entrypoint.sol`, `IVerifier` in
`IState.sol` (it survived only inside a comment), `ERC1967Proxy` in `Registration2Mock.sol`.

**ONE I DEFENDED WITHOUT CHECKING, THEN DELETED** *(user: "why leave it if it's entirely dead? try
doing it and see what happens")*. `contracts/mock/Helper.sol` declared NO contract - nothing but
three imports. I claimed it was the artifact-forcing pattern, kept it, and wrote a comment saying
"tests and deployment scripts deploy them by name".

**I MADE THAT UP.** It is a plausible pattern and it was NOT what was happening here. Deleting the
file and rebuilding settles it in two lines:

- the artifacts DO disappear (`out/EvidenceDB.sol`, `out/EvidenceRegistry.sol` gone), so the
  mechanism was real;
- and **nothing cares**: 310/310 tests pass, the build is clean, client ABIs check out.

There is no `script/`, no `deploy/`, no hardhat config, and no `deployCode`/`vm.getCode` anywhere in
the repo. Every test that needs an evidence registry declares its OWN local mock
(`MockEvidenceRegistry`, `TestEvidenceRegistry`, `SmtEvidenceRegistry`) or imports the INTERFACE.
The file forced artifacts no consumer exists for. Deleted.

**THE LESSON IS THE POINT, NOT THE FILE.** I invented a justification for keeping dead code because
the pattern was familiar, and wrote it into a comment where it would have been believed by the next
reader - the same failure this section keeps finding in inherited code, committed by me in the same
sitting. **"Try deleting it and see" is a two-minute experiment and it beats a plausible story every
time.**

**`solady` LOOKED UNUSED AND IS LOAD-BEARING.** Zero references from `contracts/` or `test/` - but
`lib/solidity-lib` imports it in four places including `RSASSAPSS.sol`, whose `LibBit.clz` is the
line sec. 2.18s just fixed. A grep over our own tree would have justified deleting the library the
certificate chain depends on. Exactly what the standing rule about never asserting absence from a
grep exists for.

**AND THE ONE THAT MATTERED: `SPV/=lib/SPV/evm/src/`, REMOVED.** It resolved nothing - ibiza imports
from it nowhere - and that is not an accident of tidiness: the stated invariant is **"SPV coupling is
one-way; SPV's repo must contain zero references to PP; ibiza declares local interface stubs
instead"**, and ibiza does exactly that (`contracts/pool/spv/ISpvVenue.sol` declares `ISpvVogue`
locally; `SpvTreasuryAdapter` holds the Vogue address as an immutable).

So the remapping was a live path to `import ... from "SPV/..."` - one line away from turning a
documented one-way coupling into a compile-time dependency on a sibling repo, silently. **Removing
it makes the invariant enforced by the build rather than by discipline**, which is the same move as
sec. 2.18q: stop relying on everyone remembering.

The `lib/SPV` submodule itself is left alone - that is a separate decision, and it has uses (running
SPV's own suite) that a remapping does not.

### 2.18u SIGNATURE FORGERY IN CRSASigner - demonstrated, then fixed

Continuing the dispatcher work after sec. 2.18s found a bug in the PSS signer. The PKCS#1 v1.5
signer had a worse one.

**IT COMPARED ONLY THE TRAILING HASH.** `verifyICAOSignature` decrypted with the public exponent and
compared the LAST 20/32/64 bytes against the digest. It never checked the v1.5 frame - no
`0x00 01 FF..FF 00`, no DigestInfo. **Everything left of the digest was ignored.**

**WITH A LOW EXPONENT THAT IS NOT A WEAKNESS, IT IS A FORGERY.** Cubing is a bijection on odd
residues mod 2^k, so for any target digest H one Hensel-lifts a root of `s^3 = H (mod 2^256)`. That
`s` is ~255 bits, so `s^3` is ~765 bits - far under a 2048-bit modulus - and **modexp performs no
reduction at all**, returning the plain cube whose last 32 bytes ARE H by construction.

**BUILT AND COMMITTED, WITH NO PRIVATE KEY.** `test/certificate/CRSASignerForgery.t.sol` carries a
value nobody signed which the old code accepted as a CSCA signature. e=3 is not exotic in X.509.

**WHAT IT WOULD HAVE BOUGHT.** `Registration2.registerCertificate` verifies exactly this signature
before admitting a DSC key to `certificatesSmt` - the tree `register_identity` proves membership in
(sec. 2.18l). Forging it inserts a signer key of the attacker's choosing; from there they sign their
own SODs and enrol fabricated identities through the permissionless path. **Unlike sec. 2.18s this
one fails OPEN**: 2.18s could only refuse real people, this admits invented ones.

**THE FIX** reconstructs the whole encoded message - `0x00 || 0x01 || 0xFF..FF || 0x00 ||
DigestInfo || H` - and compares every byte, rather than walking the decryption looking for a
separator. That parsing style is what produced Bleichenbacher's 2006 forgery, because it leaves the
attacker room; a full reconstruction leaves nothing to choose.

**VERIFICATION, INCLUDING WHAT IT DOES NOT SHOW.** Neutering `_checkPkcs1v15` re-accepts the forgery
and a tampered genuine signature, so the fix as a whole is load-bearing. But removing any SINGLE
clause - the frame, the 0xFF run, the separator, the DigestInfo - still rejects this forgery,
because the forged cube is mostly leading zeros and several clauses catch it independently. **So the
suite pins the fix, not each clause**; each guards a different family (frame -> left-side garbage,
0xFF run -> short-PS variants, DigestInfo -> algorithm substitution) and demonstrating those needs
forgeries this construction cannot produce. Said plainly rather than claimed.

**AND THE FIX MUST NOT REJECT REAL SIGNATURES** - the failure sec. 2.18s nearly shipped. Genuine
openssl signatures under BOTH e=3 and e=65537 verify, each confirmed by openssl before use, plus a
tampered-signature negative so those are not passing for free.

### 2.18v THE ECDSA SIGNERS REFUSE HALF OF ALL GENUINE SIGNATURES - low-s, wrong context

Third defect on the CSCA path, third distinct cause, same 50% arbitrary-refusal shape as sec. 2.18s.

**`ECDSA256/384/512` ACCEPT ONLY LOW-s.** Their own doc says it: *"signatures only from the lower
part of the curve are accepted."* That is deliberate and CORRECT for transactions - low-s prevents a
malleated copy being a second valid TRANSACTION, which is why Ethereum and Bitcoin require it.

**IT IS THE WRONG POLICY FOR VERIFYING SOMEONE ELSE'S X.509 SIGNATURE.** Nothing in certificate
admission keys on signature bytes - `registerCertificate` does not record them - so malleability
buys an attacker nothing. Meanwhile CAs do not normalise: **measured, openssl produced high-s in 11
of 20 signings of one message.** So roughly half of all genuine ECDSA CSCA certificates would be
refused, for a property of the signature that carries no meaning here.

**FIXED IN `CECDSA256Signer` BY REWRITING `s` TO ITS LOW FORM BEFORE VERIFYING.** That is sound and
not a bypass: if `(r, s)` verifies then so does `(r, n - s)` - they are the two representations of
ONE signature and ECDSA verification is symmetric in that reflection, so the low form proves exactly
the same statement about the same key and message. An invalid signature stays invalid either way,
which the negatives pin.

**A GUARD THE TEST FOUND, not review.** `n - s` underflows when a signature made under a DIFFERENT
curve carries an `s` larger than this curve's order. `test_RejectsUnderTheWrongCurve` panicked
immediately; such a signature is invalid here anyway, so it now passes through untouched for the
library to reject.

**BOTH HALVES PINNED.** The committed vector is deliberately HIGH-s - the half that was refused
outright - and a second genuine LOW-s signature from the same key proves the normalisation leaves
the already-canonical half alone. Verified by removal: without the rewrite the genuine high-s
signature is rejected again.

**A SECOND SITE, FOUND BY CONTINUING: `PECDSASHA1Authenticator`.** ECDSA Active Authentication over
brainpoolP256r1 handed the signature straight to the same library, so **roughly half of all genuine
AA responses were refused** too. Fixed and tested with real high-s and low-s vectors from one key.

**AND THE RULE IS NOW SHARED, not copied.** `EcdsaS.normalizeScalar` holds the `uint256` form once;
`CECDSA256Signer` and `PECDSASHA1Authenticator` both call it, and the `bytes` form serves 384/512.
That is the sec. 2.18q lesson applied before it could bite: I had already written the scalar rule
twice today. **Verified the same way - ONE edit to the shared rule now fails both call sites**,
where before it would have fixed one and left the other silently broken.

**RESOLVED: `CECDSA384Signer` AND `CECDSA512Signer` HAD THE IDENTICAL DEFECT.** `ECDSA384.sol`
and `ECDSA512.sol` carry the same restriction (checked). Fixed via `EcdsaS.normalize`, the
big-endian bignum form - `2s` compared against `n` rather than materialising `n/2`, since every
curve order here is odd and a rounding mistake shifts the boundary by one in a way no
random-signature test would reliably catch. Both tested with genuine high-s and low-s vectors.

### 2.18w FORGERY INVENTORY - every circuit, every prover-chosen anchor

*(user: "i meant any kind of forgery not just RSA, with our circuits too, you've been keepin track?")*
Partly, and scattered across sections. Swept properly instead.

**THE PATTERN TO HUNT** is the one sec. 2.18k found: a public input that NAMES A STRUCTURE THE
PROVER CHOSE, accepted without on-chain validation. A proof can be perfectly sound about a tree the
attacker built. Every circuit, every anchor:

| circuit | prover-chosen anchor | on-chain check | |
|---|---|---|---|
| `withdraw_identity` | `state_root` | `_isKnownRoot` (PrivacyPool:57) | OK |
| `withdraw_identity` | `identity_root` | `IDENTITY_REGISTRY.isValidRoot` (:76) | OK |
| `escrow_envelope` | `registration_root` | `registrationSmt.isRootValid` **and** not predating the last invalidation (sec. 2.18e) | OK |
| `escrow_envelope` | `controller_x/y` | pinned to `CONTROLLER_KEY_X/Y` | OK |
| `register_identity` | `icao_root` | `certificatesSmt.isRootValid` | OK, **built today** |
| `ragequit` | `commitment_hash` | `_isInState` + `depositors[label] == msg.sender` | OK |
| `title_holder` | *none* | **the contract CONSTRUCTS both public inputs from its own storage** | strongest |

**`title_holder` IS THE PATTERN TO PREFER.** `_verifyHolderProof` builds `publicInputs` from
`holderCommitment[titleId_]` and `titleId_`; `bindNotaryIdentity` computes `expected_` on-chain from
`holderRoot_` and `context_`. **The caller supplies only the proof.** Nothing prover-chosen means
nothing to validate and no vacuity to reason about - where a root has to be passed in, the check is
a patch over the fact that it could have been anything.

**ONE SHARED SINGLE POINT OF FAILURE, AND IT WAS BROKEN UNTIL TODAY.** Four of the six checks reduce
to `isRootValid`, which accepted ANY root on a chain younger than an hour (sec. 2.18o) - in three
separate copies (sec. 2.18q). So the entire table above was simultaneously vacuous on a fresh chain,
an L2, or any un-warped test. **That is the most important thing in this section**: the per-circuit
checks all looked present and were all resting on one function that said yes.

**FORGERY DEFECTS FOUND AND FIXED, consolidated:**
1. **sec. 2.18k** - ICAO tree vacuity. The circuit's inclusion proof is against a prover-supplied
   root; rarime's own generator builds a ONE-LEAF tree holding the key being registered. Closed by
   checking `certificatesSmt` in `registerDocumentViaIcao`. **Circuit-side, and the largest.**
2. **sec. 2.18u** - CRSASigner PKCS#1 v1.5 forgery, demonstrated with a constructed value under
   e=3. Fixed by full encoded-message reconstruction.
3. **sec. 2.18m** - X509 out-of-bounds read admitting an attacker-influenced DSC key. Fixed.
4. **sec. 2.18o/q** - `isRootValid` accepting unknown roots, x3. Fixed and unified.
5. **sec. 2.18a** - not document forgery but status forgery: a revoked identity re-registering
   clean under a fresh secret. Fixed by making the commitment a function of `sk_identity`.

**WHAT IS NOT CLOSED, stated so the table is not read as an all-clear:**
- `registerDocumentViaIcao` cannot be exercised on the happy path until a real document exists, so
  the `icao_root` check is proven only by its negative test (sec. 2.18k).
- The **CSCA master root itself is owner-set** (sec. 2.18h). Every guarantee above is downstream of
  someone publishing the right list; that is a trust assumption, not a proof, and the application
  now says so.

### 2.18x THE DSC-ADMISSION PATH IS NOW COVERED END TO END - and what is NOT on it

Closing thread A (sec. 2.18l's reinstated task). Everything `registerCertificate` touches now has
tests, and all three signers had defects (sec. 2.18s, 2.18u, 2.18v).

**COVERED:** `CRSAPSSSigner`, `CRSASigner` (all three hash branches), `CECDSA256/384/512Signer`
(both s-halves per curve), `X509` parsing, and now `CRSADispatcher` - the wrapper that reads a DSC's
key and expiry out of CSCA-signed attributes and derives the `certificateKey` that becomes a
`certificatesSmt` leaf. The dispatcher tests specifically pin that sec. 2.18m's bounds hold THROUGH
the wrapper, not only when X509 is called directly, since the offsets are caller-supplied and the
CSCA signature never covers them.

**MY OWN TEST REPEATED THE BUG IT WAS WRITTEN FOR.** The first expiry-bounds test used offset 18 on
a 30-byte array - which is exactly IN bounds - and it "passed" because the ASCII conversion
underflowed on a zero byte. The same accident sec. 2.18m found in the library, reproduced in the
test written to guard against it, and only caught because the revert REASON was wrong rather than
the outcome. **A test asserting `expectRevert()` with no reason string would have sailed through.**

**NOT ON OUR PATH, checked rather than assumed:** `PRSASHAAuthenticator` and
`PECDSASHA1Authenticator` implement Active Authentication (ISO 9796-2 message recovery), reached
only through `Registration2`'s `passportDispatchers`. **Our `register_identity` variant has
`DG15_LEN = 0` - no AA at all** - so they are unreachable from the enrolment path being built.
Recorded so nobody re-audits them under the impression they gate something.

For completeness on the one that looked most similar: `PRSASHAAuthenticator` compares a digest
recovered FROM the decryption against a hash over the recovered message, so the sec. 2.18u forgery
does not transfer - an attacker would need the recovered message and its own hash to agree, a
fixpoint rather than a free choice. **It did omit the ISO 9796-2 header/trailer validation. Fixed -
see sec. 2.18y.**

### 2.18y ISO 9796-2 FRAME VALIDATION IN THE AA AUTHENTICATOR - "if it's worth fixing then fix it"

I had written that this "would be worth fixing if it ever became reachable". That is a hedge, not a
judgement, and the user called it: **being unreachable today is not a property of the code.** It is a
property of ONE generic parameter in ONE circuit - `register_identity` is built with `DG15_LEN = 0`,
and a TD3 variant would make this live without anyone revisiting the file.

**WHAT WAS WRONG.** `authenticate` advanced past `decipher_[0]` and stripped the trailer WITHOUT
READING EITHER, recovering `M1` from whatever lay between. The header nibble and trailer are the only
things distinguishing a signature-shaped block from an arbitrary one, so discarding them unread left
the scheme's framing entirely unenforced.

**FIXED:** header must be `0x6A` (partial recovery) or `0x4A` (total); trailer must be `0xBC` for the
one-byte form or `0xCC` for the two-byte one; plus a minimum-length check before any of it.

**TESTED WITH THREE REAL SIGNATURES UNDER ONE PRIVATE KEY, differing only in framing** - each with a
correct `M1` and a correct `SHA1(M1 || challenge)`, so nothing but the frame decides the outcome:
- header `0x00` -> must be rejected (was accepted);
- trailer `0xAA` -> must be rejected (was accepted);
- header `0x4A` -> **must still be ACCEPTED**, because narrowing the standard to one of its two
  legal headers would be the sec. 2.18s failure again - refusing genuine documents.

Verified by removal: deleting both checks re-accepts the two bad frames and nothing else changes.

**THIS IS NOT A DEMONSTRATED FORGERY** and should not be recorded as one. Unlike sec. 2.18u, the
digest is recovered from the same decryption it is checked against, so exploiting the missing frame
needs a fixpoint an attacker cannot simply construct. What it removes is an unenforced invariant in
security code - the kind that becomes exploitable when someone later changes something else.

### 2.18z OPEN DECISION, NOT A TASK: WHICH DOCUMENT IS THE PRODUCT FOR?

Recorded as a decision because it is one, and it is not mine to guess. Everything else on the
enrolment path is either done or blocked on data; this is blocked on a choice.

**THE FACT:** the live path is TD1 end to end (`register_identity_light_td1` and `escrow_envelope`
at `DG1_LEN = 95`) and the permissionless path is TD3 end to end (`register_identity` at 93).
**They cannot interoperate** - a document registered through one can never be escrowed by the other,
because `dgCommit` is computed over a different number of bytes and the SMT inclusion fails
(sec. 2.18j, sec. 2.18r).

**THE TWO OPTIONS, and they are not symmetric:**

1. **A 95-byte `register_identity` variant (TD1 / ID CARD).** Matches what the wallet reads today -
   the vendored rarime SDK's circuit registry points exclusively at `.../id_cards/`. Smaller change.
   For Iran specifically the smart national ID (*kart-e melli-ye hushmand*) is far more widely held
   than a passport, **and a passport is precisely the document a person under pressure is most
   likely to be refused, have confiscated, or be unable to renew.**
2. **A 93-byte `escrow_envelope` variant (TD3 / PASSPORT BOOKLET).** Matches every word of prose we
   have written - the application, the NatSpec, the milestones all say "passport" - and is what
   crosses borders and what a foreign court recognises.

**WHY IT CANNOT BE DEFERRED INDEFINITELY:** `registerDocumentViaIcao` is built, guarded and tested,
and today it registers documents that CANNOT REACH THE POOL. That is stated at the function, but a
correct-looking entry point that silently goes nowhere is exactly the shape of thing that gets used.

**NOTE THE OPTIONS ARE NOT EXCLUSIVE** - both variants can exist, at the cost of a second verifier
contract (~24.5 kB) and a second fixture pipeline. If the answer is "both", say so, because it
changes the sequencing rather than just the target.

**MY RECOMMENDATION, for what it is worth:** option 1. It matches the code that already runs, it
matches the wallet, and it serves the document more people actually hold - and the prose is cheaper
to correct than the circuits.

### 2.18aa THE PATTERN ACROSS ALL OF IT: nothing had ever met a vector it did not produce

Worth banking, because it predicts where to look next better than any individual finding.

**SEVEN CONTRACTS ON THE CERTIFICATE AND PASSPORT CRYPTO PATH GOT THEIR FIRST TESTS TODAY. SIX HAD
DEFECTS:**

| contract | defect | class |
|---|---|---|
| `RSASSAPSS` (solarity) | leading-zero count off the LAST modulus byte | ~50% refusal |
| `CRSASigner` | no PKCS#1 v1.5 padding check | **demonstrated forgery** |
| `X509` | unbounded `unsafeCopy` past the attributes | attacker-influenced key |
| `CECDSA256Signer` | low-s only | ~50% refusal |
| `CECDSA384/512Signer` | low-s only | ~50% refusal |
| `PECDSASHA1Authenticator` | low-s only | ~50% refusal |
| `PRSASHAAuthenticator` | ISO 9796-2 frame unread | unenforced invariant |

**THE COMMON CAUSE IS NOT CRYPTOGRAPHY, IT IS THE ABSENCE OF AN OUTSIDE REFERENCE.** Every one of
these had been read, reviewed and shipped. None had ever been run against a value produced by
something other than itself. The moment each met an openssl vector - or in the forgery's case, a
value constructed to violate an assumption nobody had written down - it failed in under a minute.

**WHAT THIS PREDICTS.** The remaining risk is not in the code that looks hardest. It is wherever a
value is *checked* rather than *reproduced*:
- compare-the-tail instead of rebuild-the-whole (`CRSASigner`);
- trust a length instead of bounding it (`X509`);
- accept a policy from a library written for another context (low-s, x3);
- read a parameter's NAME instead of its meaning (`icao_root`, sec. 2.18l).

**AND THE CHEAPEST TEST IS ALWAYS THE SAME:** produce a valid input with an independent tool, and a
malformed one that violates the invariant you believe is enforced. Both took minutes here; four of
the six defects failed on the FIRST such test.

**A COROLLARY I WALKED INTO TWICE.** My own test for X509's expiry bound was itself in-bounds and
"passed" for an unrelated reason (sec. 2.18x), and my first cross-path digest test was vacuous
because both sides called the same function (sec. 2.18i). **A test written against your own
implementation inherits your own blind spot.** Known-answer vectors from outside are the only ones
that do not.

### 2.18ab A COLLISION THAT IS NOT A BUG - and I nearly "fixed" a deliberate design

Testing `CECDSADispatcher` produced a red test reading **"two different keys collided"**. Two DSC
public keys deriving one `certificatesSmt` leaf would be serious: one admitted certificate could
stand in for another. It is not a bug, and chasing it down is the point of recording it.

**THE MECHANISM.** `Bytes2Poseidon.hash512/hash1024` reduce each 32-byte word `% 2 ** 248`, dropping
its most significant byte so the value fits a BN254 field element. My test flipped byte 0 of the key
- exactly the discarded one.

**THE CIRCUIT DOES THE SAME THING**, which is what makes it correct rather than merely intentional.
`extract_pk_hash`'s ECDSA branch accumulates `EC_FIELD_SIZE - DIFF` bits with
`DIFF = EC_FIELD_SIZE - 248`, i.e. **the LOW 248 bits of x and y** - discarding the identical byte.
**Contract and circuit agree.** Had they disagreed, no ECDSA DSC would ever have verified, which
would have been a far worse finding than the one I thought I had.

**IS THE COLLISION SPACE REACHABLE? NO.** An attacker would need a valid curve point agreeing with an
admitted DSC in the low 248 bits of both coordinates AND the private key for it. A colliding
x-coordinate hands them nothing - they cannot sign with a point whose discrete log they do not know,
and searching for a private key whose public key collides is ~2^248 work. Also `registerCertificate`
would still demand a CSCA signature over it.

**WHAT I ALMOST DID.** The first instinct on a red "collision" test is to fix the hashing. That would
have desynchronised the contract from the circuit and broken ECDSA admission entirely - a real
outage manufactured to fix a non-issue. **The check that stopped it was reading the CIRCUIT before
touching the contract**, which is the same discipline sec. 2.18s needed in reverse: there, the test
was right and the code was wrong; here, the code was right and the test was wrong.

**PINNED EITHER WAY.** `test_TheTopByteOfEachCoordinateIsIgnored` now asserts the truncation
explicitly, so it is documented behaviour rather than a surprise - and it fails loudly if anyone
changes the contract's reduction without changing the circuit's.

### 2.18ac THE CIRCUIT IS CORRECTED: `register_identity_td1` closes the length gap

*(user: "correct the circuits, dont be lazy")* sec. 2.18z framed this as a decision awaiting an
answer. The recommendation was the 95-byte registration variant, and building it is cheap enough
that leaving the path inert while waiting was the lazy option. Built.

**`register_identity_td1`** - identical to `register_identity` in every generic except
`DG1_LEN = 93 -> 95`. The SOD layout parameters (`EC_LEN`, `SA_LEN`, `DG1_SHIFT`, `EC_SHIFT`)
describe where hashes sit INSIDE the encapsulated content and signed attributes, which is a property
of the SOD encoding rather than of the MRZ length, so they carry over unchanged.

**73,382 opcodes** against `register_identity`'s 73,348 - +34, the cost of hashing two more bytes.

**WHAT IS PROVEN TODAY, and it is the part that mattered:**
- `dg1_hash` agrees with `register_identity_light` **at 95 bytes** - the anti-replay key both
  registration paths must share (sec. 2.18i);
- `dgCommit` agrees too, which is the stronger requirement: **that is the value
  `escrow_envelope` reproduces to locate the registration leaf.** Without it a permissionlessly
  enrolled document could never be escrowed, which was the whole defect.

**WHAT IS NOT PROVEN, said rather than implied:** the SOD layout constants against a REAL TD1
document. None exists here and we do not fabricate an ICAO chain to pretend otherwise (sec. 2.18k).
A real card may need different shifts - a parameter change, not a redesign.

**`HolderRegistration.registerDocumentViaIcao` NOW NAMES THE RIGHT VERIFIER.** Its NatSpec said the
path "does not yet reach the pool"; it now says `icaoRegistrationVerifier` must be set to the TD1
circuit and why. The function itself needed no change - the verifier was always injected, never
hardcoded, which is exactly why fixing this was a configuration matter rather than a rewrite.

**THE OPEN DECISION IN sec. 2.18z NARROWS BUT DOES NOT VANISH.** TD1 is now buildable end to end.
Supporting passport booklets as well still needs a 93-byte `escrow_envelope` variant - a second
verifier contract and a second fixture pipeline. That remains a product question: **which document
is this for**, and whether both.

### 2.18ad EVERYTHING NOT PROVEN, IN ONE PLACE - with what would close each

Scattered caveats are caveats nobody reads. This is the complete list of things asserted but not
demonstrated, each with the specific thing that would settle it. **Nothing below is a known defect -
they are claims resting on argument rather than execution.**

**BLOCKED ON A REAL DOCUMENT** (milestone 3; a synthetic one is refused, sec. 2.18k):
1. **`register_identity` / `register_identity_td1` happy path.** No proof has ever been produced by
   either. Needs a SOD signed by a DSC genuinely in the ICAO chain. *Closes with:* one real card or
   passport, `js/process_passport.js`'s `{dg1, dg15, sod}` input, then `nargo execute`.
2. **The `icao_root` check's POSITIVE case.** `registerDocumentViaIcao` is proven only by its
   negative test - an unknown root reverts. That a VALID root is accepted has never run.
   *Closes with:* the same document, plus `certificatesSmt` populated by a real
   `registerCertificate`.
3. **The TD1 SOD layout constants** (`EC_LEN 126`, `SA_LEN 62`, `DG1_SHIFT 25`, `EC_SHIFT 42`).
   Inherited from the TD3 profile on the reasoning that they describe SOD structure rather than MRZ
   length. **Plausible, unverified.** *Closes with:* one real TD1 card - and if wrong, it is a
   parameter change, not a redesign.
4. **No Solidity verifier is generated for either full-registration circuit.** Deliberate: a
   verifier that has never accepted a proof is a liability, and `codegen-verifiers.sh`'s self-checks
   need a witness. *Closes with:* item 1.

**TRUST ASSUMPTIONS, NOT PROOFS:**
5. **The CSCA master root is owner-set** (`changeICAOMasterTreeRoot`, `onlyOwner`). Every guarantee
   in sec. 2.18w's table is downstream of someone publishing the right list. *Closes with:* CRE
   consensus anchoring, which removes the discretion rather than documenting it.
6. **Iranian legal claims** - the Land Registration Act making private deeds inadmissible, the
   notary monopoly on consensual mortgages, the foreclosure institutions. From `spec.pdf` plus
   general knowledge, **not from anyone qualified to give an opinion.** *Closes with:* the
   in-country counsel milestone 3 budgets for. Already corrected once (sec. 2.18f), which is
   evidence the rest deserves checking too.

**PARTIALLY PINNED - the whole is tested, the parts are not:**
7. **`CRSASigner`'s individual padding clauses.** Neutering `_checkPkcs1v15` re-admits the forgery,
   so the fix as a whole is load-bearing; removing any SINGLE clause does not, because the forged
   cube is mostly leading zeros and several clauses catch it independently (sec. 2.18u). Each guards
   a different family. *Closes with:* forgeries tailored to bypass all-but-one, which this
   construction cannot produce.
8. **`PRSASHAAuthenticator`'s fix is unit-tested but unreachable in situ** - Active Authentication
   needs DG15 and our variant has `DG15_LEN = 0` (sec. 2.18y). *Closes with:* a DG15-carrying
   profile, if one is ever wired.

**NOT YET BUILT:**
9. **A 93-byte `escrow_envelope`** - required if passport booklets are supported alongside ID cards.
   Second verifier, second fixture pipeline (sec. 2.18ac).
10. **Untested contracts that remain:** the passport dispatchers (`PECDSASHA1Dispatcher`,
    `PRSASHADispatcher`, `PNOAADispatcher`), unreachable for the same reason as item 8, and the
    generated query verifiers. `AQueryProofExecutor`'s root check is covered (sec. 2.18ae) and the
    **signal LAYOUT is now covered too** (sec. 2.18af) - **I had marked that blocked on a real proof
    and it was not**, which is the error this list exists to prevent. What genuinely still needs a
    proof is only end-to-end acceptance: that a real `query_identity` proof verifies against signals
    this builder produced. *Closes with:* item 1.

**THE ONE THING THIS LIST IS FOR:** sec. 2.18w's forgery table reads like an all-clear. It is not,
and items 1, 2 and 5 are why. The guards are real and tested; what has never run is the path they
guard.

### 2.18ae THE PRESENTATION PATH'S ROOT CHECK WAS REAL AND UNTESTED - behind an always-true mock

Followed sec. 2.18ad's own prediction that the query executors were the next place to look.

**I EXPECTED A VACUITY AND DID NOT FIND ONE.** `AQueryProofExecutor.execute*` take
`registrationRoot_` FROM THE CALLER and feed it into the public signals - textbook sec. 2.18k shape.
The executor itself contains no validation, and `_beforeVerify` is an EMPTY VIRTUAL HOOK, which
reads exactly like a security check left optional. **The check exists**, in
`PublicSignalsBuilder.withIdStateRoot`: `isRootValid`, reverting `InvalidRegistrationRoot`. Not in
the file anyone would look in first, which is worth knowing on its own.

**BUT NOTHING EXERCISED IT, AND THE REASON IS THE INTERESTING PART.** The only harness on this path,
`mock/sdk/ProofBuilderTest.sol`, wires a `MockRegistrationSMT` whose `isRootValid` **returns TRUE
UNCONDITIONALLY**. So the guard was inert in every existing test and **would have stayed green if
someone deleted it** - the precise defect already caught once in this project with
`MockEntrypoint.isValidRoot`, sitting in a second place.

**NOW COVERED WITH A REAL `PoseidonSMT`:** an invented root, an invented root on the TD1 entry point,
and the zero root are each refused; and a root the tree genuinely holds gets PAST the check and on to
proof verification, which is what proves the guard rejects the root specifically rather than failing
everything. Verified by removal: deleting the check makes two of the four fail.

**IT IS ALSO A FOURTH CONSUMER OF `isRootValid`** (after the identity registry, the escrow path and
`Registration2`'s certificate gate). Until sec. 2.18o that function accepted ANY root on a chain
younger than an hour - so this check was vacuous on a fresh chain or L2 **even with a real SMT
behind it**. Four independent guards, one shared failure, which is the sec. 2.18q argument again.

### 2.18af THE SIGNAL LAYOUT WAS TESTABLE ALL ALONG - I had it filed as blocked

*(user: "if anything can be done now before we have phone or passport, do it, do not wait")* sec.
2.18ad listed the signal building as blocked on a real proof. **That was wrong.** The builder is a
pure function from inputs to 23 words; checking that each lands in the slot the circuit reads it
from needs no proof, no phone and no document. Filed as blocked, done in twenty minutes.

**WHY IT MATTERS.** `PublicSignalsBuilder` assembles the signals a `query_identity` proof is
verified against, and **their order is a contract with the circuit that nothing enforced.** A field
one slot out verifies happily against the wrong claim - a proof of nationality checked as though it
were sex, an age bound applied to an expiry date. Silent, and wrong in the direction that matters.

**THE EXISTING TESTS COULD NOT HAVE CAUGHT IT.** `mock/sdk/ProofBuilderTest.sol`'s eleven
"equivalence" tests compare the library against a reference **in the same file**. That proves
internal consistency and says nothing about the circuit - the same vacuity as sec. 2.18i, where both
sides of my cross-path test called one function.

**THE REFERENCE USED HERE IS THE CIRCUIT SOURCE**, the only thing that cannot drift with the
library. Mapped by hand from `query_identity/src/main.nr`'s return tuple against the builder's
`mstore` offsets (`slot = (offset - 32) / 32`), and **every one matches**: nullifier at 0, the
identity fields at 3-7, eventId/eventData at 9-10, idStateRoot 11, selector 12, and the five bound
PAIRS through 22.

**THE BOUND PAIRS ARE THE DANGEROUS PART** and get their own test: every one is a (lower, upper) of
the same shape, so a pair written one slot out still looks like a plausible range while constraining
the WRONG attribute. Verified by swapping two adjacent bound slots - the test fails immediately.

Also pinned: the array is exactly 23 long, and unset date slots default to `ZERO_DATE` rather than 0,
since the circuit reads them as passport timestamps and a raw zero is a different claim from
"unconstrained".

### 2.18ag THE PASSPORT DISPATCHERS - and a vacuous test I wrote while documenting vacuous tests

Last untested cluster. Unreachable today (AA needs DG15, our variant is `DG15_LEN = 0`) and tested
anyway, on sec. 2.18y's reasoning: unreachable is a property of one generic in one circuit, not of
the code.

**FOUND AND BOUNDED.** `PECDSASHA1Dispatcher.authenticate` reads `r`, `s`, `x`, `y` by raw `mload`
at fixed offsets into caller-supplied arrays **without consulting their lengths** - so a short
signature or key pulls adjacent memory into the verification inputs. Same shape as sec. 2.18m.

**AND THE TEST I WROTE FOR IT IS VACUOUS.** Removing the guard does NOT make it fail: whatever the
out-of-bounds read picks up still has to satisfy ECDSA verification, garbage does not, so
`authenticate` returns false either way. **It passes with the guard and without it.** I wrote it,
ran the removal check out of habit, and it came back green - which is the only reason I know.

That is worth more than the fix. **A test asserting the CORRECT outcome for the WRONG reason is
indistinguishable from a working one until you delete the code it claims to guard.** Every removal
check this session has been cheap; this is the first where the answer was "your test proves
nothing", and it would have read as coverage forever.

Left in place with the limitation written into the file rather than quietly deleted, because the
tests still pin something real - that refusal is explicit and does not depend on surrounding memory.
What would genuinely prove the guard is adjacent bytes forming a VERIFYING tuple, which needs
control of Solidity's memory layout I do not have here. **So the guard is defence in depth, not a
fix for a demonstrated exploit, and it is labelled that way.**

**ALSO COVERED, and these are not vacuous:** the ECDSA dispatcher unpacks a real brainpoolP256r1
response to the same verdict as the authenticator; the challenge is the last 8 bytes of the identity
key big-endian, and both dispatchers agree on that convention - a mismatch would let a response be
replayed under a different identity; and `PNOAADispatcher` accepts ONLY an empty signature, which is
its entire security, since returning true regardless would let a document that supports AA skip it
by claiming not to.

### 2.18ah THE WITHDRAWAL CIRCUIT HAD ZERO TESTS - the one that spends money

Surveyed circuit coverage looking for work with no external requirement. `pp` has 84 tests and
`noir_dl_lib` 63, but **`withdraw_identity` had NONE**, and neither did `title_holder`,
`query_identity` or `register_identity_light_td1`.

**THE PIECES WERE TESTED; THE COMPOSITION WAS NOT.** `commitment_hasher`, `lean_imt_inclusion`,
`smt_verifier_full` and `secret_commitment` all have their own vectors in `pp`. What nothing
exercised was `main` - and a wiring error there (two `Field` arguments swapped, a check reading the
wrong variable) is invisible to every unit test in `pp` and still produces a circuit that proves and
verifies perfectly.

**NO EXTERNAL DATA WAS EVER NEEDED, which is the uncomfortable part.** A single-leaf LeanIMT has
root == leaf by its carry-up rule, and a single-leaf SMT root is `Poseidon(key, value, 1)` - so a
complete valid witness is constructible in-circuit with no fixture, phone or document. **The absence
of tests was a choice, not a constraint**, and it sat behind the most security-critical circuit in
the repo for the whole project.

**FIVE TESTS:** a consistent withdrawal proves; a WRONG revocation secret cannot withdraw (the
identity gate - the registry key is derived from the secret precisely so a prover cannot name a
clean identity, all of which are public in the tree); withdrawing more than the note holds fails
(the 128-bit range check exists so the subtraction cannot wrap the field and mint a balance); a
false nullifier hash cannot prove (single-spend); and withdrawing the ENTIRE note is ALLOWED, which
is asserted because a range check written slightly wrong would reject exactly that case and leave a
user unable to empty a note.

**THE NEGATIVES ARE VERIFIED, NOT ASSUMED.** `#[test(should_fail)]` passes if the test fails for ANY
reason - the same trap as a bare `expectRevert()`, and I have already written one vacuous test today
(sec. 2.18ag). So each negative was checked by REMOVING the guard it targets: deleting the identity
assert makes the wrong-secret test stop failing, deleting the nullifier assert makes the false-hash
test stop failing. Each targets its own guard.

**AND THE COMPILER FOUND SOMETHING** - which turned out to be a naming problem, not a dead input.
*"we cant have unused things. what couldve been the use of it"* (user, 2026-07-29). Fair question, and
the answer is that `context` is the single most load-bearing signal in the circuit's public I/O.

**WHAT IT IS FOR.** `context` carries `keccak256(abi.encode(withdrawal, SCOPE)) % SNARK_SCALAR_FIELD`
- the recipient, the fee, the processooor, the pool. **Nothing else in this circuit names who gets
paid.** `new_commitment`, `withdrawn_value`, the roots, the nullifier hash - a proof of all of those
is equally a valid proof for ANY recipient. So without `context` a withdrawal proof sitting in the
mempool could be copied by anyone, re-submitted with themselves as `processooor`, and the money would
follow. `context` is what makes a proof about one withdrawal instead of about an amount.

**WHY NOTHING CONSTRAINS IT, AND WHY THAT IS RIGHT.** There is nothing to check in-circuit. The
value's meaning lives entirely in data only the contract holds - the `Withdrawal` struct and `SCOPE`
are not circuit inputs and could not be without hashing keccak inside a Poseidon circuit for no gain.
What the circuit owes is not a computation but a COMMITMENT: that the proof is bound to whatever
value was passed. `pub` delivers exactly that, in the transcript, gate or no gate. Then
`PrivacyPool.validWithdrawal` recomputes the hash from the real withdrawal data and reverts
`ContextMismatch` on disagreement. The division of labour is deliberate: the circuit binds, the
contract interprets.

**PROVEN, NOT ARGUED.** sec. 2.3 inferred the binding from `publicInputsSize == 8`, which is evidence
about the verification key rather than about behaviour. `WithdrawalHonkVerifier.t.sol` now tampers
this signal on TWO real proofs - `test_RejectsTamperedContext`, `test_RejectsTamperedWalletContext` -
and both are rejected by the verifier itself, before any contract-level comparison. Had Noir optimised
an ungated public input away, those tests would pass tampering through and fail.

**DOES `let _ =` MAKE THE VALUE UNUSABLE? NO - PROBED, NOT ASSUMED.** *"the underscore still troubles
me, that makes the context unusable?"* (user, 2026-07-29). A fair worry, and reasoning by analogy to
Rust would have been a guess about a different compiler. A two-input scratch circuit settles it:

```noir
fn main(a: pub Field, b: pub Field) {
    let _ = a;
    assert(a + b == 12, "a was not usable after let _ = a");
}
```

It compiles (so `a` is still usable after being discarded) and the `should_fail` case `main(5, 8)`
fails as required (so the constraint is LIVE, not elided). `_` evaluates and drops; it does not move,
shadow, consume or mark. `context` remains an ordinary parameter and an ordinary public input, and if
a constraint on it is ever wanted the `let _` line simply becomes redundant. Corroborated twice over:
opcode count is 24,812 with and without it, and both real proofs still verify - neither of which a
line that changed `context`'s status could manage.

**WHAT CHANGED.** `let _ = context;` in the body, plus the reasoning at the parameter. No constraints
(24,812 opcodes before and after; both real proofs still verify, so the ACIR is byte-identical). The
point is the warning: `unused variable context` fired on every build, and a warning that is expected
forever is a warning nobody reads - so the day a public input goes unused BY ACCIDENT, the diagnostic
that would have caught it is already background noise. Silencing it deliberately keeps the channel
clean.

**THE RESIDUAL RISK WAS THE CONTRACT'S, AND IT IS NOW CLOSED BY CONSTRUCTION.** *"we cant have silent
vanishings like that. how can we make this safer"* (user, 2026-07-29). Correct instinct, and recording
the hazard was the weaker answer. The binding rested on three lines in `validWithdrawal`:

```solidity
if (_proof.context() != keccak256(abi.encode(_withdrawal, SCOPE)) % SNARK_SCALAR_FIELD) revert ContextMismatch();
```

Delete them and the happy path still works, the code that remains still looks complete, and the tie
between a proof and its recipient is gone. **The defect was the SHAPE, not the arithmetic** - a
comparison is deletable, and nothing downstream depends on it having run.

**THE FIX: MAKE IT AN ARGUMENT, NOT A CHECK.** `ProofLib.publicInputsBytes32` now takes the context
from its CALLER and writes it into slot [6], ignoring `pubSignals[6]` entirely. `PrivacyPool.withdraw`
passes `_contextFor(_withdrawal)`. The verifier cannot be called without a context, so there is no
longer a line whose deletion silently weakens anything - delete the derivation and it does not
compile. The unsafe no-argument overload was REMOVED rather than kept alongside, because a safe
variant beside an unsafe one only relocates the mistake.

The admission set is unchanged: a proof made for this withdrawal has `pubSignals[6] == context_` and
verifies exactly as before. `ContextMismatch` survives as a DIAGNOSTIC - a relayer handed a stale
proof learns what is wrong, rather than getting a bare `InvalidProof` - and is documented as carrying
no security.

**VERIFIED BY MUTATION, which is the only way to test a claim about deletion.** With the modifier
check commented out, `test_ProofIsBoundToItsWithdrawalParameters` (a genuine proof replayed against
`address(0xBAD)`) still fails - and `-vvvv` names the cause as **`SumcheckFailed()`**, the Honk
verifier itself rejecting the proof. Before this change that same mutation would have let the replay
through. Restored afterwards; 372 forge tests pass, client ABIs clean.

**AND THE TEST GAP THAT ALLOWED IT.** Every existing test fed the verifier the PROVER'S OWN context,
so all of them agreed with themselves and none could see the substitution missing.
`test_RejectsAContextTheContractDerivedDifferently` closes that: an untouched, genuine proof verified
against a context it was not made for must fail, and against the right one must pass.

### 2.18ai "BUT WE GOT RID OF GROTH COMPLETELY?" - yes, in the pool. The comments hadn't noticed.

The question came from a comment I had just read aloud: `ragequit` calls a Noir verifier under a line
saying *"Verify proof with Groth16 verifier"*. Checked rather than assumed - `State.sol` declares
**both** verifiers as `INoirVerifier`, and `ragequit` takes `bytes proof` with no `pA`/`pB`/`pC`. So
the pool is 100% Honk and a dozen comments still said otherwise.

**Worse than merely stale - actively contradictory.** `PrivacyPoolSimple.t.sol` claimed ragequit
"stays Groth16, matching State.sol's two distinct verifier types" while declaring `NoirVerifierMock`
for BOTH verifiers two lines below. `ProofLib.RagequitProof` carried `@param pA`, `@param pB`,
`@param pC` for fields the struct does not have. A reader trusting either would form a false model of
the trust boundary - which is exactly how the `icaoMasterTreeMerkleRoot` mis-naming nearly cost a day
(sec. 2.18k).

**Fixed at nine sites**, all comments/docs, no logic: `PrivacyPool.sol` (constructor params, the
ragequit line, a "Groth16/Noir" hedge), `IState.sol`, `IPrivacyPool.InvalidProof`, `ProofLib` (title
plus the three phantom `@param`s), `NoirVerifierMock`, `PrivacyPoolSimple.t.sol`, `PP-NOIR-FUSION.md`.
Where the old claim was once true, the note now says so and dates it, rather than silently reversing.

**AND ONE DEAD FILE.** `contracts/pool/interfaces/IVerifier.sol` - the Groth16
`verifyProof(pA,pB,pC,uint[8])` interface - had no importers left. The `IVerifier` matches elsewhere
are interfaces the generated Honk verifiers declare INTERNALLY at their own line 129, not this file.
Deleted and verified the way sec. 2.18 established: build, then the full suite. 372 tests pass, so it
was genuinely dead rather than dead-looking.

**WHAT IS STILL GROTH16, AND LEGITIMATELY SO.** The rarime registration side -
`RegistrationSimple.sol`, `Registration2.sol`, `AQueryProofExecutor.sol` - imports solarity's
`Groth16VerifierHelper` and verifies real Circom proofs. `AQueryProofExecutor` is deliberately
dual-stack (`execute` for Circom, `executeNoir` for Honk). "We got rid of Groth16" is true of the
POOL and false of the identity stack, and the two are easy to conflate because both live here.

### 2.18aj GOING FULLY HONK COSTS SIX PASSPORTS - the exact number, and what it buys

*"how many different passports would we need to eventually be fully honk and what would that give
us"* (user, 2026-07-29). Countable, so counted.

**I FIRST ANSWERED THIS WRONG.** I said our Noir coverage was "three circuits" against 35 Circom
profiles, and concluded convergence would need a re-validation programme against real documents from
every issuer. That compared our OWN `backend/circuits/` against rarime's vendored verifiers. The repo
also vendors **76 `NoirRegisterIdentity_*` verifiers** under `passport/verifiers2/noir/` - MORE
profiles than the Circom set, including signature types (6, 7, 8, 23, 25, 26, 27, 28) and SHA-384
that Circom never had. rarime already did most of this migration. Counting beat reasoning, and the
reasoning had been confident.

**THE ACTUAL GAP: 6 PROFILES.** 29 of the 35 Circom profiles already have a Noir twin. The orphans:

| profile | signature (decoded from the lib's own SIG_TYPE dispatch) | hash | Active Auth? |
|---|---|---|---|
| `1_160_3_4_576_200_NA` | RSA-2048, e=65537 | SHA-1 | no |
| `20_160_3_3_736_200_NA` | ECDSA secp256r1 | SHA-1 | no |
| `4_160_3_3_336_216_1_1296_3_256` | RSA-2048, **e=37187** | SHA-1 | **YES** |
| `1_256_3_6_336_560_1_2744_4_256` | RSA-2048, e=65537 | SHA-256 | **YES** |
| `14_256_3_4_336_64_1_1480_5_296` | RSA-PSS-3072, salt 32, e=65537 | SHA-256 | **YES** |
| `20_256_3_5_336_72_NA` | ECDSA secp256r1 | SHA-256 | no |

**THE CRYPTOGRAPHY IS NOT THE BLOCKER, and an earlier version of this section said it was.** I wrote
"signature type 4 is unported entirely", reading that off the VERIFIER FILENAMES rather than the
library. `not_passports_zk_circuits.nr` dispatches SIG_TYPE 1-8, 10-15, 20-21 and 23-27 - every type
these six need is already implemented. Third time the same mistake in this session (sec. 2.18h,
sec. 2.18aj's first count, sec. 2.18ak): a number read off the nearest file instead of the thing it
claims to measure.

**WHAT IS ACTUALLY MISSING is the per-profile SOD LAYOUT: `EC_LEN`, `SA_LEN`, `N`.** The profile name
encodes only SIG_TYPE, hash bits, doc type, `EC_SHIFT` (name value / 8) and `DG1_SHIFT` (name value /
8) - verified against our own circuit, where `336/8 = 42 = EC_SHIFT` and `200/8 = 25 = DG1_SHIFT`. It
does NOT encode the three that decide WHICH BYTES GET HASHED, no profile->parameter table exists
anywhere in this repo, and these six by definition have no rarime Noir source to copy from. Inventing
them is refused under sec. 2.18k: a wrong `SA_LEN` compiles cleanly and hashes the wrong span, with no
symptom until a real document disagrees.

**THREE OF THE SIX CARRY ACTIVE AUTHENTICATION - they ARE the DG15 profiles.** DG15 is the ICAO 9303
data group holding the chip's AA public key; AA is the challenge-response that proves the chip is
genuine rather than a clone of its data. Our circuits set `DG15_LEN = 0`, which is what the trailing
`NA` means in a profile name, and it is why `PRSASHAAuthenticator` and the passport dispatchers are
unreachable in situ. **So porting these six would also close sec. 2.18ad items 8 and 10 as a side
effect** - a better argument for the migration than the toolchain tidiness first offered here.

**GENERATING the circuits needs ZERO passports** - five of the six differ from an existing Noir
profile only in SOD layout offsets, which is a parameter change exactly like `register_identity_td1`
(sec. 2.18ac), not new design. Only signature type 4 is genuinely unported. **VALIDATING them is what
needs documents: one per profile, so SIX.** Three are SHA-1, i.e. legacy documents being phased out -
drop those and it is **three**. Accept 29/35 (83%) coverage and it is **zero**.

**WHAT IT BUYS, honestly ranked:**

1. **NO PER-CIRCUIT TRUSTED SETUP.** This is the only argument that matters. Groth16 needs a ceremony
   PER CIRCUIT - 35 of them, whose artifacts we did not produce, cannot audit, and would be trusting
   rarime for. A compromised ceremony forges identities SILENTLY: fake registrations verify perfectly.
   Honk needs only a universal SRS. For users whose alternative to this system is a sanctioned bank,
   an unauditable ceremony is the wrong thing to ask them to trust.
2. **One toolchain.** nargo/bb only - no circom/snarkjs in CI or the client bundle.
3. **Deletes the dual entrypoints** - `register`, `reissueIdentity`, `_verifyCircomZKProof`,
   `Groth16VerifierHelper`, and `AQueryProofExecutor.execute`. The ambiguity IS those pairs.
4. **One audit surface** instead of two proving systems.

**WHAT IT DOES NOT BUY: size.** The Circom verifiers are **420K**; the Noir set we are KEEPING is
**11M**. Going fully Honk makes the repo bigger, not smaller. (An earlier note implying "13 MB of
Groth16" conflated the two directories - the 13M is the whole `verifiers2` tree.)

**THE POOL IS ALREADY DONE** (sec. 2.18ai), which is the source of the confusion: "are we on one
stack?" is YES for the pool and NOT YET for identity. Ambiguity killed at the two places the split is
visible - `Registration2.registerViaNoir` and `AQueryProofExecutor` now state which stack owns which
entrypoint, that `registerCertificate` is signature-gated and belongs to NEITHER, and that new
capability goes to the Noir side.

**THE ORDERED PLAN - steps 1-4 need no document, 5 does, and 6 MUST NOT PRECEDE 5.** *"is this first
step to getting away from groth16?"* (user, 2026-07-30). Yes, first of six:

1. **VERIFY THE PREMISE** (unblocked, needs a fetch of rarime's public Circom repo). That their Circom
   circuits instantiate each profile with explicit `EC_LEN`/`SA_LEN` is **an INFERENCE, not a checked
   fact.** The circuits must carry concrete lengths somewhere, but that repo's layout has not been
   looked at. If the premise is false the plan collapses back to "needs documents", so verify before
   building anything. Flagged this loudly because three claims in this session (sec. 2.18h, this
   section's own first count, sec. 2.18ak) were read off the nearest artifact instead of the thing
   they measured.
2. **PORT** the six parameter tuples into six Noir wrapper crates, as `register_identity_td1` was
   built (sec. 2.18ac). Mechanical.
3. **IN-CIRCUIT CONSISTENCY TESTS** per profile, mirroring the TD1 cross-checks that `dg1_hash` and
   `dgCommit` agree with the light path at the same length. Catches transcription errors.
4. **`bb` CODEGEN** for six Honk verifiers. Mechanical.
5. **BLOCKED - VALIDATE each against one real document.** Steps 2-4 prove the circuits are
   SELF-CONSISTENT, not that they read a real SOD correctly. A wrong `SA_LEN` passes every test in
   step 3 and still hashes the wrong byte span - the same shape as the selector mask in sec. 2.18al:
   consistent with itself, wrong about the world.
6. **ONLY THEN DELETE:** `register`, `reissueIdentity`, `_verifyCircomZKProof`, the
   `Groth16VerifierHelper` import, `InvalidCircomProof`, `AQueryProofExecutor.execute`, the 35
   per-passport verifier contracts, and the wallet's `zkPoints` plumbing (`IdentityVault.ts`,
   `RegistrationSimple.json`).

**WHY STEP 6 CANNOT JUMP THE QUEUE.** Deleting a path rarime validated against real passports, in
favour of our unvalidated port, is a REGRESSION rather than a migration. sec. 2.18ad item 4 already
states the principle: a verifier that has never accepted a proof is a liability. Porting moves the
blocker from "we do not know the numbers" to "we have not validated them" - real progress, and still
not permission to delete.

### 2.18ak TEST COVERAGE, COUNTED PROPERLY - and why the first count was wrong

*"the table you gave me... it's already the contents of TODO.md?"* (user, 2026-07-29). It was not.
sec. 2.18ad's items 1-10 came from this file; every COVERAGE row was assembled live from a filesystem
inventory and written nowhere. Unrecorded work gets re-derived, so here it is.

**THE FIRST COUNT WAS WRONG, and wrong in the direction that wastes effort.** I reported
`title_holder`, `query_identity`, `query_identity_td1` and `register_identity_light_td1` as
"zero-coverage circuits". All four are THIN WRAPPER CRATES - `main.nr` files of 13-49 lines that
forward to a library gadget. Counting `#[test]` in the wrapper says nothing about the gadget:

- `title_holder` -> `pp::title_holder::title_holder_proof`. Tested in `pp`, and **already proved
  on-chain** against the generated verifier (`TitleHolderHonkVerifier.t.sol`, sec. 2.3).
- `register_identity_light_td1` -> `noir_dl::lite::register_identity_light`. Covered by `lite.nr`'s
  known-answer vector plus the TD1 cross-checks in `register_identity_td1` (sec. 2.18ac).
- `query_identity` / `query_identity_td1` -> `noir_dl::query`. **This one is genuinely uncovered.**

Counting the wrong artifact is the same failure as sec. 2.18h ("dispatchers are not needed at all")
and sec. 2.18aj (comparing our `backend/circuits/` against rarime's vendored verifiers): a number
read off the nearest file rather than the thing it claims to measure.

**WHERE COVERAGE ACTUALLY STANDS** (measured 2026-07-29):

| unit | tests | note |
|---|---|---|
| `pp` (all gadgets) | 84 | commitment, lean_imt, smt, envelope, jubjub, title_holder |
| `noir_dl::smt` | 11 | |
| `noir_dl::rsa` / `rsa_pss` | 5 / 5 | |
| `noir_dl::jubjub` | 5 | |
| `noir_dl::sha1/224/384/512` | 2 each | |
| `noir_dl::lite` | 1 | the dg1_hash known-answer vector |
| `withdraw_identity` | 5 | first ever, sec. 2.18ah |
| `escrow_envelope` | 4 | |
| `ragequit` | 3 | |
| **`noir_dl::query`** | **0** | **883 lines. THE REAL GAP.** |
| **`noir_dl::not_passports_zk_circuits`** | **0** | 907 lines, but see below |
| **wallet TypeScript** | **0 test files** | `check-recovery.js` is a script, not a suite |

**`query.nr` IS THE ONE TO DO, and it needs no document.** It decides WHAT A PROOF REVEALS -
selector bits, birth-date and expiry lower/upper bounds, citizenship mask, identity counters. It is
arithmetic over a DG1 byte array that can be constructed in-circuit, exactly like sec. 2.18ah's
witness. An off-by-one in a date bound or a mis-masked selector discloses more than the user chose,
and nothing would fail loudly.

**`not_passports_zk_circuits.nr` IS NOT** - its core is `passport_verification_flow`, which needs a
real SOD (sec. 2.18ad item 1). The parts that DON'T (`extract_dg1_commitment`) are already exercised
by `register_identity_td1`'s two tests.

**YES, THE UNTESTED SCOPE IS INHERITED - AND THAT IS PROVABLE, NOT AN EXCUSE.** *"are you telling me
that rarimo upstream had untested scope that we inherited?"* (user, 2026-07-29). Checked at the fork
commit `0762975`, which is the only honest way to answer it:

| module | tests AT FORK | tests NOW | who |
|---|---|---|---|
| `rsa.nr` | 5 | 5 | rarime |
| `rsa_pss.nr` | 5 | 5 | rarime |
| `sha1/224/384.nr` | 2 each | 2 each | rarime |
| `jubjub.nr` | 3 | 5 | rarime + 2 ours |
| `smt.nr` | 1 | 11 | rarime + 10 ours |
| `sha512.nr` | 0 | 2 | ours |
| `lite.nr` | 0 | 1 | ours |
| **`query.nr`** | **0** | **0** | **inherited, still open** |
| **`not_passports_zk_circuits.nr`** | **0** | **0** | **inherited, needs a document** |

**THE VENDORING DID NOT STRIP TESTS** - `rsa.nr` arrived carrying five. So `query.nr`'s zero is
upstream's actual state, not an artifact of how the fork was taken. The same holds for the vendored
crypto: `sigver` has 25 tests across 31 files, but `big_curve` has **1 across 17**.

That is an explanation of PROVENANCE, not a defence. Inheriting an untested 883-line file that decides
what a proof discloses makes it ours the moment we shipped it.

**AND THE REASON REAL-PASSPORT TESTING DOES NOT COVER IT - the sentence to remember:**

> **A selector mask can be wrong for every passport ever tried and still verify.**

rarime tested with real passports; that is their empirical claim and it is credible. It establishes
something different from what is needed here. A passport test exercises the SIGNATURE path: does this
chip's SOD verify, does the DSC chain to a CSCA. It says nothing about the DISCLOSURE arithmetic,
because a proof that reveals too much still verifies perfectly. Every party in the loop is satisfied:
the prover produced a valid proof, the verifier accepted it, the passport was genuine. The only thing
wrong is WHICH FIELDS CAME OUT, and no cryptographic check anywhere is looking at that. The same holds
for a birth-date bound off by one day, an expiry comparison using the wrong operator, or a citizenship
mask that ORs where it should AND.

This generalises past `query.nr`, and it is the reason this project keeps finding defects in things
that "work": **a check that cannot fail loudly is not covered by testing the happy path.** It is the
same shape as sec. 2.18ah's deletable context comparison, sec. 2.18 ae's always-true mock, and the
sec. 2.18o root-validity guard that silently passed for every invented root.

**WHAT ELSE IS UNTESTED REPO-WIDE, since the rule is "no untested thing":**

| unit | lines | tests | ours or inherited? |
|---|---|---|---|
| `noir_dl/src/query.nr` | 883 | 0 | inherited |
| `noir_dl/src/not_passports_zk_circuits.nr` | 907 | 0 | inherited, needs a document |
| `noir_dl/src/big_curve` | 17 files | 1 | inherited |
| **`backend/cre/notary_registry/main.go`** | **~500** | **0** | **OURS** |
| wallet TypeScript (`pp/`, `identity/`, `sdk/`) | - | 0 test files | ours |

**`main.go` IS THE UNCOMFORTABLE ONE** - it is our own code, not vendored, and it is the CRE workflow
that scrapes Ukraine's Ministry of Justice notary registry (sec. 2.15a). Its parsing logic is exactly
what sec. 2.15a warns about ("scrapers rot"), it is plain Go testable against fixture HTML with no
document and no network, and it has no tests at all. Nothing about it is blocked.

**CRE IS NOT A PREREQUISITE FOR ANY OF IT.** sec. 2.15a's scraper anchors the ACTIVE-NOTARY snapshot;
it feeds `TitleLedger`'s notary side, not the passport query path. And even for `title_holder`, the
circuit proves set membership against a root - where the root comes from is orthogonal to whether the
circuit is wired correctly.

### 2.18al QUERY.NR HAD ZERO TESTS - the file that decides what a proof reveals

**WRITTEN LATE, AND THAT IS THE POINT.** This section did not exist until 2026-07-31: the work landed
in commit `aaf9b79` and the reasoning went into the COMMIT MESSAGE ONLY, while two other sections
(2.18ak, 2.18an) cited `sec. 2.18al` as though it were here. A pointer to nothing is worse than no
pointer, because it reads as though the context was captured. Found by auditing every `sec. 2.x`
citation against the headings that actually exist - see the end of 2.18as.

**THE FILE.** `noir_dl_lib/src/query.nr`, 883 lines, inherited from rarime at the fork commit with
zero tests - verified rather than assumed: `rsa.nr` arrived carrying five, so vendoring did not strip
them (2.18ak). It decides WHAT A PROOF DISCLOSES: selector bits, birth-date and expiry bounds,
citizenship mask, identity counters.

**WHY REAL-PASSPORT TESTING DOES NOT COVER IT** - the sentence this project keeps coming back to:

> **A selector mask can be wrong for every passport ever tried and still verify.**

A passport test exercises the SIGNATURE path: does this SOD verify, does the DSC chain to a CSCA. A
proof that reveals the wrong fields still verifies perfectly - prover satisfied, verifier satisfied,
passport genuine. Nothing cryptographic anywhere looks at which values came out.

**12 TESTS, and what each pins:**
- **The selector map, bit by bit.** The code indexes `selector.to_be_bits::<18>()` - big-endian, so
  documented bit k lived at index 17-k. Pick the wrong end and every field is still multiplied by
  SOME bit: the proof verifies and the caller gets a different field than it asked for. Verified
  non-vacuous by MUTATION - swapping the birth-date and expiration-date bits fails 3 tests.
- **An empty selector discloses nothing** - the fail-safe direction, caught on the first run if the
  masking is ever inverted.
- **The nullifier is 0 for EVERYONE when its bit is clear.** A relying party doing double-spend
  prevention on that value without checking the bit would treat all holders as one person. A caller
  obligation the circuit cannot enforce, so it is written down.
- **The bounds are OPT-IN, both directions.** `assert(n1 OR NOT n2)` enforces a bound only when its
  bit is set, so a verifier who wants "born before 1995" and forgets the bit gets a valid proof
  saying NOTHING about age, with no error. Both the skip and the bite are tested - a bound that
  rejects everything is not a working bound.
- **`date_is_less` boundaries**: the two-digit-year pivot at equality, strict-less (an equal date is
  not less), and month outranking day. An off-by-one there shifts every age comparison by a century
  for one birth year, and the proof still verifies.

**A DEFECT THE TESTS FOUND ON THE FIRST RUN: zero is not a no-op date bound.** The obvious way to say
"I do not care about birth date" is to pass 0. It does not skip the check, it ABORTS PROVING -
`date_is_less` does `to_be_bytes::<6>()` then `date[0] - 48`, so a zero byte underflows a u8. Worse,
`date_is_less` runs UNCONDITIONALLY, before the gate that decides whether anyone cares, so a caller
who correctly leaves the bit clear still cannot produce a proof. And it is loud only by ACCIDENT:
Noir's u8 underflow check is the only thing making it visible - the same arithmetic over a `Field`
would wrap to an enormous year and silently invert the comparison. Pinned rather than clamped, since
clamping trades a loud abort for a quietly wrong comparison. The real gap is that no "unused"
sentinel exists: "000000" parses as year 2000, month 0, day 0.

**THE TD1 HALF came later and found the bigger defect** - one selector bit gating two unrelated
things, leaking a national ID. See 2.18an.

### 2.18am THE NOTARY IS NAMED ON-CHAIN - the application claimed the opposite

*"openable by a quorum of custodians against a proven fault"?* (user, 2026-07-31). Quoted from
FUNDING-APPLICATION.md, and the question mark was right. **Three claims in one sentence, all false.**

The sentence read: *"which notary acted is never published: they prove membership of the licensed set
without naming a member, their identity travelling encrypted, openable by a quorum of custodians
against a proven fault."* What the code does:

| claim | reality |
|---|---|
| "never published" | `TitleEntry.notary` is an `address` inside `mapping(uint256 => TitleEntry) public titles` - directly readable. Worse, THREE events emit `address indexed notary` (`TitleMinted`, `LegendAdded`, `EncumbranceSet`). **`indexed` makes it a searchable topic**, so "every title this notary touched" is one log query. Not merely published - INDEXED FOR LOOKUP. |
| "membership without naming a member" | `_requireActiveNotary(registryId_, notary_, proof_)` takes the notary's ADDRESS plus a Merkle proof. It is inclusion for a NAMED member, not anonymous set membership. |
| "identity travelling encrypted, openable by a quorum" | **No threshold or quorum cryptography exists anywhere in this repo.** The only sealing is `pp::envelope`, used at exactly one call site - `escrow_envelope/src/main.nr:215` - to seal the BORROWER's revocation secret. And it is not a quorum: `open_payload(envelope, controller_secret)` takes ONE key. |

**AND A FOURTH EXPOSURE THE SENTENCE DID NOT EVEN CLAIM TO SOLVE.** `notaryDataHashOf` is a PUBLIC
mapping from `holderRoot` to `keccak(regNumber, fullName, region, status)`. Every preimage component
comes from the official register - which is public by construction, since sec. 2.15a's whole design is
a decentralised oracle network SCRAPING it. So the hash is enumerable: compute it for every notary in
the register and match. `TitleLedger`'s own comment concedes the input, noting `holderRoot` "is
already public in the registration events".

**WHY THIS ONE MATTERED MORE THAN THE OTHER CORRECTIONS.** It is a SAFETY claim about people the same
paragraph says "can be punished for serving a system like this", in a document asking for money. The
other errors this session cost effort; this one could cost somebody their liberty if anyone relied on
it. Fixed immediately rather than noted - the application now says the notary is named on-chain today
and that anonymising them is designed, not built (997/1000 words, down 2).

**WHAT BUILDING IT WOULD ACTUALLY TAKE** - recorded so the sentence is never restored without them:
1. Anonymous set membership: prove "I am in the active-notary snapshot" WITHOUT passing an address.
   `title_holder` already proves a commitment against a root, so the shape exists; the notary path
   simply does not use it.
2. Drop `address indexed notary` from all three events and the public `titles` mapping - the
   membership proof is worthless while an indexed topic names them anyway.
3. `notaryDataHashOf` must stop being a public enumerable map of register-derived preimages.
4. A CUSTODIAN SET AND A THRESHOLD SCHEME THAT DO NOT EXIST - who holds shares, what "proven fault"
   means procedurally, and what stops the quorum colluding. This is the largest piece and it is a
   governance design, not a circuit.

**ITEM 4 DISSOLVED - THERE IS NO GOVERNANCE TO DESIGN.** *"there is no governance design. we are
inheriting the ASP structure of PP, why should it be any extension of that"* (user, 2026-07-31). That
removes the hardest part of the problem, and it does so by correcting the PRIMITIVE rather than by
descoping: **the ASP answer to a proven fault is REVOCATION, not deanonymisation.** Privacy Pools
never opens a bad actor's identity - it EXCLUDES them from the association set. Our identity registry
already works exactly that way: `withdraw_identity` proves inclusion at STATUS_CLEAN, and revoking
writes a non-zero value no clean-status proof can equal. A revoked notary simply stops being able to
prove anything, and nobody learns who they were. "Openable by a quorum" was answering a question the
architecture does not ask.

**BUILT AND PROVEN (commit d7e5dbd).** `backend/circuits/notary_action` - 12,187 opcodes, five tests,
being `withdraw_identity`'s identity section with the note-spending half removed. Negatives included
and each one earns its place: a stranger cannot authorise, **a revoked notary cannot authorise** (that
IS the fault mechanism), a proof against the wrong root fails, and any `action_context` proves -
because the contract substitutes its own derived value, per sec. 2.18ah. The verifier is generated and
a REAL proof verifies on-chain (three more tests), rather than shipped unexercised: sec. 2.18ad item 4
says a verifier that has never accepted a proof is a liability, and unlike the passport circuits this
one needs no document, so there was no reason to wait.

**STILL EXPOSED - the mechanism exists, the ledger does not use it yet.** Nothing observable has
changed: `TitleLedger` still names the notary. Wiring is specified on task #13 and is unblocked. It
forces one design decision worth stating rather than burying: `addLegend`/`setEncumbered` currently
require THE SAME notary who minted. Under anonymity, storing that notary's commitment would preserve
the semantics but create a persistent PSEUDONYM linking every title they touched - so a single
deanonymisation would expose their whole history. Letting ANY ACTIVE notary endorse is unlinkable and
also removes a liveness trap, where a revoked or unavailable minting notary leaves a title permanently
unamendable. **Recommend the latter**: the threat model is notaries being punished, so unlinkability
outranks same-notary semantics - and it matches this contract's own "county recorder" analogy, where a
different clerk can file an encumbrance.

### 2.18an ONE SELECTOR BIT GATED TWO THINGS - citizenship leaked a national ID. FIXED.

Found by writing the TD1 half of sec. 2.18al's disclosure suite. `query_identity_td1` read
`selector_bits[1]` TWICE - once to gate `citizenship_check`, once to unmask `personal_number_hash`.
Under the old 18-bit selector, index 1 was documented bit 16, **"personal number hash"**: the
citizenship check had NO BIT OF ITS OWN and borrowed that one. TD3 escaped it only because
`query_identity` returns no personal number, so index 1 had a single reader there.

**BOTH DIRECTIONS HARMED, AND ONE WAS A PRIVACY LEAK:**

1. Asking for the personal number silently ENFORCED a citizenship constraint - bit set, no mask,
   `citizenship_check` wanting exactly one match and getting none, so **the proof could not be
   produced at all** and the error named citizenship.
2. **THE LEAK.** Asking only *"are you a citizen of X?"* - a yes/no question - ALSO disclosed the
   holder's **national ID number hash**, because the only way to turn the check on was to set the bit
   that unmasked it. The user chose one thing and disclosed two; the proof verified perfectly and
   nothing anywhere reported a problem.

Exactly what sec. 2.18ak predicts: **a selector mask can be wrong for every passport ever tried and
still verify.** A passport test exercises signatures; it never asks which fields came out. This is
the first defect that rule actually caught.

**I FIRST RECORDED THIS AS "PINNED, NOT FIXED" - AND THE EXCUSE WAS FALSE.** *"we cant have defects
like this. why cant we fix them immediately"* (user, 2026-07-31). The claim was that all 18 bits were
assigned, so a fix meant a coordinated ABI change across the wallet, `PublicSignalsBuilder` and
rarime's tooling, invalidating existing proofs. **Checking took one grep.** `PublicSignalsBuilder`
only STORES the selector integer at signal index 12 (`mstore(add(dataPointer_, 416), selector_)`) and
never decomposes it - **nothing outside `query.nr` interprets bit positions at all.** And "invalidates
existing proofs" is true of any circuit change, of which there are none in production because there
are no real documents yet. I had manufactured a coordination cost to justify deferring, which is a
worse failure than the defect: it is the shape of excuse that leaves real leaks shipped.

**THE FIX IS INTERNAL AND CHANGES NO CALLER.** The selector is BIG-ENDIAN, so an index is
`width - 1 - bit`. Widening `to_be_bits::<18>` to `::<19>` shifts every INDEX in the file by one while
leaving every documented bit's VALUE untouched - a caller passing `2**16` still means "personal number
hash", and `2**18` is simply new. The citizenship check now owns documented bit 18 (`selector_bits[0]`)
in BOTH paths, so TD3 and TD1 cannot drift apart later.

**THREE TESTS, INCLUDING THE ONE THAT STOPS A VACUOUS FIX.** The leak is closed
(`test_asking_about_citizenship_no_longer_discloses_the_personal_number` asserts every other output is
zero); the personal number is requestable alone; and
`test_the_citizenship_constraint_still_rejects_a_non_matching_mask` proves bit 18 **still bites** -
without it, the first test would pass just as well if bit 18 did nothing whatsoever. 80 `noir_dl`
tests, 376 forge tests, ABIs clean.

### 2.18ao THE CRE SCRAPER'S FIRST TESTS - and three defects they found

*"is there anything you can do before you do puppeteer?"* (user, 2026-07-31). Yes:
`backend/cre/notary_registry` was ~500 lines of OUR OWN code with zero tests, deciding WHO COUNTS AS A
NOTARY - and since sec. 2.18am it is load-bearing for privacy too, because the anonymity set is built
from what it publishes.

**WHAT CONSENSUS DOES NOT COVER.** sec. 2.15a chose CRE over TLSNotary because
`cre.ConsensusIdenticalAggregation` requires every DON node to produce a BYTE-IDENTICAL result. That
protects against a rogue NODE. It does nothing about **a parser that is wrong the same way
everywhere** - every node agrees, and they agree on the wrong set. Consensus covers the FETCH; the
MEANING is untested, and sec. 2.15a said so itself ("scrapers rot").

**THE TAG THAT MADE IT UNTESTABLE.** `main.go` is `//go:build wasip1` because it links the CRE
runtime, so NONE of the parsing logic could run on a host machine. Moved the pure parts - the XML/zip
decode, the active filter, `leafHash`, `merkleRoot` - into an untagged `registry.go` that imports
nothing but stdlib and keccak. Not a mock and not a rewrite: the network call stays in `main.go` and
still calls the extracted function. Both `GOOS=wasip1` and host builds verified. **13 tests.**

**THREE DEFECTS, all found by writing the tests rather than by reading:**

1. **A STATUS CASING CHANGE SILENTLY DROPS NOTARIES.** The filter is an exact compare against
   `"active"`. A migrated portal emitting `"Active"` drops those records with no error. Total failure
   is caught - `onSchedule` refuses to publish an empty root - but a PARTIAL change is not, and mixed
   casing is exactly how a partial change arrives. **This is the under-counting direction, which is
   the dangerous one**: extra notaries would be caught by anyone comparing against the public
   register, whereas missing ones silently strip real people of the ability to act, and nothing
   downstream can distinguish "not a notary" from "the parser dropped you". NOT "fixed" by
   lowercasing, because case-folding is a GUESS about the register's vocabulary - if the real status
   set is Ukrainian, ASCII folding admits nobody and hides that the mapping was never verified. Needs
   a real export, which task #12 has to obtain per country anyway.

2. **`leafHash` CONCATENATES FIELDS WITH NO SEPARATOR.** keccak(regNumber || fullName || region ||
   status) means reg `"12"` + name `"3X"` collides with reg `"123"` + name `"X"`. Unreachable with
   Ukrainian data because registration numbers are numeric and names are not - but **that is an
   argument about the DATA, not the construction**, and it stops holding the moment a jurisdiction
   uses alphanumeric registration numbers. The fix is a length-prefixed or delimited encoding, and it
   must land BEFORE a second country, since it changes every leaf.

3. **DUPLICATE RECORDS ARE NOT DEDUPLICATED, and the contract rejects the result.**
   `RegistrySourceAnchor` requires strictly ascending leaves (its own line 97 says so); sorting
   duplicates yields equal neighbours, not strict ascent. So ONE duplicated row upstream makes the
   entire snapshot unpublishable - a safe failure, but a LIVENESS one: every notary in the country
   stops being refreshed because of a registrar's data-entry slip. Deduplication belongs in
   `activeLeaves`.

**ALL THREE FIXED, and defect 1's excuse was wrong too.** *"why cant we sandbox what we need to run
the logic here and see if it works? fix the defects"* (user, 2026-07-31). I had said 1 "needs a real
export" to learn the vocabulary. **It does not - it needs the unknown case to be LOUD.**

- **1.** Statuses are normalised (trim + lowercase), so a migrated portal emitting `"Active"` no
  longer drops anyone. And the part case-folding alone would NOT have fixed: anything outside the
  known set `{active, suspended, terminated}` now **refuses the entire snapshot** instead of skipping
  that record. A Ukrainian-language status is a visible outage a human fixes, not a person quietly
  losing the ability to act. That needed no export at all - only the recognition that "I do not know
  the vocabulary" should fail closed rather than silently.
- **2.** `leafHash` hashes each field FIRST -
  `keccak(keccak(reg), keccak(name), keccak(region), keccak(status))` - so every part is fixed-width
  and no boundary is ambiguous. `TitleLedger.registerNotary`'s `notaryDataHash_` doc updated in the
  same commit, since both sides must agree.
- **3.** `activeLeaves` deduplicates, and a new test asserts the property that motivated it: the
  submitted leaves are STRICTLY ascending, which is what `RegistrySourceAnchor` actually checks.

16 Go tests, up from 13. The three defect tests were rewritten to assert the FIXED behaviour, which
is what their own retirement instructions said to do rather than editing them to match.

**AND THE TRANSLATION LAYER, which is a SPEC requirement rather than an edge case.** *"any local
languages need to be translated as part of the cre scraping spec"* (user, 2026-07-31). Right - a
register writes statuses IN ITS OWN LANGUAGE. Ukraine's does not have to say `"active"` and Iran's
certainly will not, so treating the English words as universal is the same mistake as treating one
country's SOD layout as universal, and it fails the same way: silently, by dropping people.

`statusVocabularies` now maps `registryKey -> (the register's own string -> meaning)`, matched after
Unicode-aware case folding so Cyrillic and Arabic-script entries fold correctly. Adding a country is
adding a table entry. `RegistryKey` moved into `Config` and the on-chain `registryId` is derived from
it, so **a deployment cannot scrape one country's portal while publishing under another's
identifier** - and one root per jurisdiction is what stops membership in "some register" standing in
for authority in a SPECIFIC one (task #12).

**NOT DONE AT RUNTIME, AND THAT IS FORCED.** Machine translation inside a DON cannot reach consensus:
every node must produce a byte-identical result, and a translation service is neither deterministic
nor identical across nodes. The mapping has to be a fixed, reviewable table shipped with the workflow.

**THE UKRAINIAN ENTRIES ARE DELIBERATELY ABSENT.** I do not know what the Ministry of Justice register
actually writes, and inventing plausible Cyrillic is exactly the sec. 2.18k fabrication: a wrong
mapping either admits nobody (loud, recoverable) or assigns the WRONG MEANING to a real status
(silent, and it decides who may act). An undeclared registry refuses to publish outright, so leaving
them missing is safe and visible - `TestAnUndeclaredRegistryRefusesToPublish` pins that, and
`TestANonLatinVocabularyWorksOnceDeclared` proves the mechanism handles non-Latin scripts using its
own declared vocabulary rather than guessed-at real ones. **19 Go tests.**

### 2.18ap THE WALLET IS REACT NATIVE, NOT WEB - puppeteer does not apply, and NFC is unconfigured

*"check it"* (user, 2026-07-31), after I proposed puppeteer for the wallet and then hedged that I had
not verified it was a web app. I had not, and it is not.

**WHAT IT ACTUALLY IS.** `react-native 0.86.0` + `expo ~57.0.8`, `newArchEnabled: true`. `app.json`
declares no `platforms` and no `web` block; the `webpack.config.js` present is stock Expo web
scaffolding, not a configured target. The scripts are `expo run:ios --device` /
`expo run:android --device` - **device-first, explicitly.**

**SO PUPPETEER IS THE WRONG TOOL, not merely a weaker one.** Puppeteer drives a browser. This app has
no browser build, and its critical paths are native modules that no browser can load. The React
Native equivalents are Detox or Maestro, both of which drive a simulator or a real device. That is a
correction to my own suggestion, not a refinement of it.

**AND A SIMULATOR CANNOT REACH THE PARTS MOST LIKELY TO BREAK.** Ten `src/` files import native-only
capability: `expo-secure-store` (hardware keystore, Face ID - `recovery.ts`, `store.ts`,
`IdentityVault.ts`, `root.ts`) and `@rarimo/rarime-rn-sdk` (Noir proving via prebuilt AARs -
`prove.ts`, `withdrawWitness.ts`, `circuits.ts`, `sdk/*`). **NFC does not exist on any simulator at
all**, so the passport read can only ever be exercised on real hardware. The user's instinct that
"things can happen there that dont happen on a simulator" is right, and stronger than stated: some
things cannot happen on a simulator in principle.

**THE FINDING THAT MATTERS MORE THAN THE TOOL CHOICE: NFC IS NOT CONFIGURED ANYWHERE.** Checked at
every layer rather than inferred from one grep -

| layer | NFC present? |
|---|---|
| `app.json` `plugins` | no - only `./app.plugin.js` and `expo-secure-store` |
| our `app.plugin.js` | no - it only adds a Gradle `flatDir` for the SDK's AARs |
| SDK `app.plugin.js` | no - zero matches |
| SDK `android/**/AndroidManifest.xml` | no - the manifest is literally `<manifest></manifest>` |
| SDK iOS podspec / Swift | no matches |

Reading an eMRTD chip needs, on iOS, the `com.apple.developer.nfc.readersession.formats` entitlement
with `TAG`, an `NFCReaderUsageDescription`, and the eMRTD AID in
`com.apple.developer.nfc.readersession.iso7816.select-identifiers`; on Android,
`android.permission.NFC` plus the reader intent filters. **None of that exists.**

**WHY THIS REORDERS THE BLOCKED WORK.** sec. 2.18ad item 1 is "blocked on a real document". That is
INCOMPLETE: with a passport in hand today the app still could not read it, because the entitlement
that permits the read is absent and the build would be rejected at runtime rather than at compile
time. **Configuring NFC is a prerequisite for item 1 and needs no document, no phone and no
passport** - it is a config change, verifiable by a build. It should land BEFORE a document is
sourced, or the first real-document session gets spent discovering this.

**RELATED, ALREADY FLAGGED IN-FILE.** `app.plugin.js`'s own comment says its Gradle change has
"NOT VERIFIED BY A REAL ANDROID BUILD - no JDK/Android SDK/NDK on the machine this was written on".
So the native build path is unverified end to end, and the NFC config joins it. Both need a machine
with the Android/iOS toolchains - CI or a dev box, not necessarily a phone.

**CHALLENGED, AND THE CHALLENGE IMPROVED THE FINDING.** *"im shocked tho are you sure this isnt a
false negative? the rarimo app was working as far as i can tell"* (user, 2026-07-31). Right to push -
"it works" is exactly the evidence that should force a re-check. It is NOT a false negative, and
digging showed my framing was **understated** rather than wrong:

- **No generated native projects exist.** There is no `ios/` or `android/` directory; they are
  produced by `expo prebuild`, which `package.json` runs with `--clean`. So no hand-edited manifest
  could be carrying the entitlement.
- **The SDK is a PROVING sdk, not an NFC one.** `@rarimo/rarime-rn-sdk` exports Noir prover bindings,
  hash/signature helpers and contract typings; its native payload is `SwoirenbergLib.xcframework`
  (Swoir, a Noir prover). **Zero NFC references in its entire source**, and its Android manifest is
  literally `<manifest></manifest>`.
- **There is no NFC library in this app at all** - zero matches for "nfc" in `package.json`. No
  `react-native-nfc-manager`, nothing. `@li0ard/tsemrtd` and `mrz` PARSE document data; they do not
  read a chip.
- **The wallet already says so.** `App.tsx:70`: *"Live add/renew/revoke need: (1) a scanned passport
  (RarimePassport from NFC), (2) OUR deployed HolderStateKeeper/HolderRegistration, (3) the forked
  query circuit"*. It is a shell, and it knows.

**BOTH THINGS ARE TRUE:** Rarimo's own app works - it is a complete shipped product with its own app
config and its own scanner. `identity-wallet` is a SEPARATE Expo app that consumes their proving SDK
and was never given a scanner. An iOS entitlement is granted to an app bundle via its own
entitlements file and provisioning profile; **a library cannot grant itself NFC**, so a working
upstream app implies nothing about ours.

**SO THE ENTITLEMENT WAS THE SMALLER HALF.** Task #15 as first written said "configure NFC" as though
config were the only gap. Corrected: config is necessary and nowhere near sufficient - the scanner
itself (BAC/PACE key derivation, APDU exchange, secure messaging, then handing DGs to `tsemrtd`) does
not exist. Reading a chip is a real piece of work, not a plist key.

**DONE ANYWAY, AND FIRST, because it is the blocker that fails LATEST.** On iOS the entitlement is
enforced at RUNTIME: a build without it compiles, installs, launches, and throws only when a reader
session starts. `app.plugin.js` now adds the `TAG` reader format, the `NFCReaderUsageDescription`,
the eMRTD AID `A0000002471001` in `select-identifiers`, `android.permission.NFC`, and
`uses-feature android.hardware.nfc required="false"` (required=true would stop the app installing on
devices with no radio, and someone who restored from backup can still hold notes and withdraw without
ever reading a document). **11 tests via `node --test`** - no jest, no new dependency - covering
idempotence, not clobbering another plugin's NDEF request, and the AID as a pinned literal so a typo
is a failing test rather than a silent "no chip found" against a real passport. What they cannot
prove is that the generated project BUILDS; that still needs a toolchain.

### 2.18aq "IS IT ALL A MOCKUP?" - no, but the halves are very different, and the seam is the chip

*"are you sure this is missing? how could any of this work properly without this component? you're
telling me it's all a mockup basically?"* (user, 2026-07-31). Deserves a precise answer, so: **the
backend is real and proven; the wallet is explicitly a shell; and the component that joins a physical
document to either of them does not exist.**

**WHAT IS REAL, and "real" here means a genuine proof verified by a generated verifier, not a mock:**
`withdraw_identity`, `ragequit`, `escrow_envelope`, `title_holder` and `notary_action` all compile,
produce real `bb` proofs, and those proofs verify on-chain in Forge tests. 376 forge tests, 80
`noir_dl`, 84 `pp`, 19 Go, 11 config-plugin. The pool, the identity registry, the title ledger and
the notary anonymity set are working code with negative tests.

**WHAT IS A SHELL, and says so in its own words.** `README.md`: *"multi-document wallet shell"*,
`store.ts` *"persistence (in-memory demo; SecureStore sketch for prod)"*. `App.tsx:70`: live
add/renew/revoke need *"(1) a scanned passport (RarimePassport from NFC), (2) OUR deployed
HolderStateKeeper/HolderRegistration, (3) the forked query circuit"*. None of the three is done.

**THE HONEST SUMMARY: the cryptography works on SYNTHETIC identities.** Every fixture derives from a
chosen `sk_identity` (1234 in the withdrawal fixture), never from a passport. That is not a mockup -
the constraint system, the verifiers and the contracts are all genuine, and a synthetic witness
exercises them exactly as a real one would. **But nothing has ever ingested a real document**, and
sec. 2.18ad item 1 has said so from the start. What this session added is WHY: it is not only that we
lack a document, it is that there is no code that could read one.

**RARIMO'S SCANNER CAN BE REUSED - AS LIBRARIES, NOT AS CODE.** Their apps are native, not React
Native (`rarime-android-app` is Kotlin, `rarime-ios-app` is Swift), so nothing drops in. What they
actually use:

| | library | licence |
|---|---|---|
| Android | `org.jmrtd:jmrtd:0.7.27` + `net.sf.scuba:scuba-sc-android:0.0.20` + BouncyCastle | **LGPL** (jmrtd) |
| iOS | `github.com/rarimo/NFCPassportReader` (their own copy of AndyQ's) | MIT |

They did not write a scanner either - they took the two standard ones. So the work is a bridge
module, not a chip driver.

**DIFFED BEFORE ADOPTING, as instructed** (*"diff before adopting, no shortcuts"*). Findings:

- **rarimo's copy shares NO GIT HISTORY with AndyQ's** - `merge-base` finds nothing and the API
  reports no parent, so it was created by copying files rather than forking. A "fork" that cannot be
  diffed by git is worth knowing about before depending on it.
- Diffed by TREE instead, against upstream at rarimo's own sync point (`de25144`, 2024-07-25, since
  their last sync commit is "sync with retail NFCPassportReader"). **Six files differ, and the
  changes are almost entirely VISIBILITY:** `internal` -> `public` on `DataGroup1`, `DataGroup15`,
  `SOD` (including exposing `asn1`), and ~15 more in `OpenSSLUtils`. `SimpleASN1DumpParser` has ~31
  changes that are style (`self.` prefixes, paren removal) plus their "update the asn1 parser"
  commit. `PassportReader` has 4, one being that they still carry `aaChallenge` where upstream
  renamed it `activeAuthenticationChallenge`.
- **No cryptographic or protocol divergence.** It is a "make the internals reachable" fork, which is
  the LOW-RISK kind - and it suggests the same result could be had from upstream directly plus a
  small shim, avoiding a dependency on a copy nobody upstreams to.
- **But it is ~2 years stale**: rarimo HEAD is 2024-10-21; upstream is at v2.3.3, 2026-07-28. Every
  upstream fix since is missing.

**RECOMMENDATION:** wrap upstream AndyQ (MIT, maintained) rather than rarimo's copy, taking only the
visibility changes as a patch or via a shim. Check jmrtd's LGPL against how we ship Android before
committing - it is the only non-permissive licence in the stack, and that is a decision to make
deliberately rather than by default. Avoid `tradle/react-native-passport-reader`: last pushed
2023-12 and its licence is `NOASSERTION`, i.e. GitHub could not identify one, which is a legal
unknown rather than a permissive licence.

### 2.18ar WHAT NEEDS TWO PASSPORTS, AND WHAT DOES NOT

*"so before we can verify that multidocument works, we need two passports and a phone?"* (user,
2026-07-31). **No** - and the distinction is worth stating precisely, because it decides what is
worth building now.

**MULTI-DOCUMENT IS ALREADY VERIFIED.** `HolderRegistration.t.sol::test_multiCitizenship_twoDocumentsOneHolder`
registers two DISTINCT documents - different `dg1Hash`, different keys, one `DOC_PASSPORT` and one
`DOC_NATIONAL_ID` - under one `holderRoot`, and asserts `getActiveDocumentCount == 2`. Its neighbour
`test_sameDg1CannotBindToASecondHolderRoot` guards the re-homing attack that would otherwise defeat
any identity-level blacklist. The LOGIC is done.

**WHAT TWO REAL PASSPORTS WOULD ADD is INGESTION, not logic:** that two genuine SODs, from two real
issuers, parse and register under one holder key. That is a different claim from "the contract binds
two documents to one root", and only the first needs hardware.

**SO THE USEFUL PRE-WORK IS EVERYTHING BETWEEN THE MRZ AND THE PROOF THAT IS PURE.** Built the first
piece: `src/passport/mrzKey.ts` - ICAO 9303 Part 11 check digits and the BAC "MRZ information"
string. A chip will not talk to you until you prove you can read the printed page, so every scanner
needs this, and none of it needs a radio.

**PINNED TO THE SPEC'S OWN WORKED EXAMPLE, NOT TO THE IMPLEMENTATION.** The ICAO specimen (document
`L898902C`, born 690806, expires 940623) must produce `L898902C<369080619406236`; the three check
digits 3, 1 and 6 were each reproduced by hand from the 7-3-1 weights BEFORE the code was written, so
the test cannot be satisfied by an implementation that merely agrees with itself. **9 tests via
`node --test`** - Node 24 strips types natively, so no jest and no new dependency.

**IT IS ALSO THE PART THAT FAILS SILENTLY, which is why it was worth doing first.** A wrong BAC key
does not error - the chip simply refuses mutual authentication, and the symptom is "scanning didn't
work", indistinguishable from a bad antenna, a bad read, or an unsupported document. Doing this now
means that ambiguity is already resolved when someone is finally standing there with a passport.
Malformed input therefore throws rather than computing a plausible key: a lowercase letter from an
OCR path would otherwise produce a well-formed key over the wrong value.

**STILL MISSING FROM THIS FILE, deliberately rather than forgotten:** the seed-to-key step
(SHA-1 -> Kseed -> Kenc/Kmac with 3DES) and PACE. PACE matters - modern documents prefer it and some
refuse BAC outright - but it needs its own vectors and is better absent than half-done.

### 2.18as FOUR POINTERS TO NOTHING - the audit that found them, and how to repeat it

*"is this all banked in TODO so we can never forget it?"* (user, 2026-07-31). Checking rather than
answering found that it was NOT, in a way no amount of careful writing would have caught.

**THE FAILURE MODE: a citation to a section that does not exist.** Worse than no citation, because it
reads as though the context was captured and sends the next reader looking for something that was
never written. Four of them:

| pointer | cited from | reality |
|---|---|---|
| `sec. 2.18al` | 2.18ak, 2.18an | **NEVER WRITTEN.** The work shipped in `aaf9b79`; the reasoning went into the COMMIT MESSAGE ONLY |
| `sec. 2.12` | `title_holder.nr`, `title_holder/main.nr`, `PP-NOIR-FUSION.md`, `EscrowEnvelopeHonkVerifier.t.sol`, TODO x2 | content lives in **2.3** |
| `sec. 2.27` | `codegen-verifiers.sh` x3 - the TOOLCHAIN COMPATIBILITY MAP | content lives in **sec. 1** |
| `sec. 2.13` | several | no bare heading, but 2.13b..2.13z exist - a parent reference, harmless |

**THE `sec. 2.27` ONE WAS THE MOST EXPENSIVE.** `codegen-verifiers.sh` tells anyone tempted to bump a
version *"DO NOT 'just use a newer version' - see TODO.md sec. 2.27"*, and pointed at nothing. That
guard exists because some version combinations FAIL SILENTLY - bb 1.2.0 + nargo beta.1 reports a
successful prove and writes a proof bb's own verifier rejects. A reader who followed the pointer,
found nothing, and concluded the warning was stale would ship broken artifacts.

**WHAT I FIXED.** Wrote 2.18al from the code and the commit; repointed 2.12 -> 2.3 and 2.27 -> sec. 1
across all six files. Re-audited: **zero dangling.**

**HOW TO REPEAT IT** - the whole check is one comparison, and it should be run before trusting that a
session's context is durable:

```python
defined = set(re.findall(r'^### (2\.\d+[a-z]*)', todo, re.M))
cited   = set(re.findall(r'sec\. (2\.\d+[a-z]*)', todo + source_tree_text))
missing = cited - defined          # must be empty
```

Exclude `*.circuit` and `*.json` - compiled artifacts contain byte sequences that match the pattern.

**THE LESSON IS ABOUT WHERE REASONING LANDS.** A commit message is not durable context: it is
findable only by someone who already knows which commit to read. Everything load-bearing has to be in
the tracked file, and a citation is a PROMISE that it is - so an unkept one is a specific, checkable
kind of lie. The rule this suggests: **write the section before writing the citation**, and re-run
the audit above whenever a session adds several.

### 2.18at THE SNAPSHOT WAS PUBLISHABLE BUT NOT USABLE - nothing could prove membership in it

Found while wiring the notary anonymity set (2.18am) to the scraper (2.18ao) - a gap created by
building both halves in one day and connecting neither.

**THE GAP.** The CRE workflow published roots and leaves. `TitleLedger.registerNotary` requires a
`registryProof_` and checks it with OpenZeppelin's `MerkleProof.verify`. **Nothing anywhere produced
that sibling path.** So a notary could appear in a published snapshot and still be impossible to
admit: the set was publishable and not usable, which no test on either side could notice because
each half was correct alone.

**THE CONVENTION IS THE RISKY PART, AND IT FAILS SILENTLY.** Two rules have to match the contract
exactly - sorted pairs at every node (so proofs carry no direction bits), and **an odd node PROMOTED
unchanged** rather than hashed with itself. Get either wrong and the generator emits proofs that
never verify, with no diagnostic beyond a boolean false. The promoted-node rule is the easy one to
get wrong: appending a sibling for a node that has none yields a proof exactly one element too long.

**GO TESTING GO WOULD NOT HAVE CAUGHT IT.** A shared misunderstanding makes a generator and its own
checker agree and both be wrong - the same trap as sec. 2.18ag's vacuous test and sec. 2.18i's
same-function cross-check. So the verification is deliberately layered:

1. `verifyLikeSolidity` in the Go tests is **written out independently**, mirroring OZ's fold rather
   than calling `merkleProof`/`merkleRoot`.
2. **Every leaf at every tree size 1..9** must be provable and verify - odd sizes are exactly where
   the promoted-node rule bites.
3. **A real fixture crosses the language boundary.** `go test -run EmitSolidity` writes the root,
   leaf and path produced by the REAL generator; `NotaryRegistryProof.t.sol` reads it and checks it
   with the REAL `MerkleProof` library the contract uses. If the conventions ever diverge, that
   Forge test fails. Three negatives (wrong leaf, tampered sibling, wrong root) stop it passing
   vacuously.

**TWO SMALLER TRAPS PINNED AS TESTS.** An ABSENT leaf is reported absent rather than handed an empty
proof - an empty path is legitimately valid for a single-leaf tree, so conflating the two would let a
non-notary be admitted against a one-notary snapshot. And `merkleProof` COPIES before sorting:
`merkleRoot` sorts in place and Go slices share backing arrays, so a generator that did the same
would silently permute the caller's leaves - including the ones about to be submitted on-chain.

**23 Go tests** (up from 19), **380 forge tests** (up from 376), both wasm and host builds green.

**STILL NOT CONNECTED, and worth saying plainly:** this makes the proof OBTAINABLE, not obtained.
Nobody yet calls `registerNotary` - the postman needs a notary's commitment, which the notary derives
from a secret they generate, and no tool does that. Task #13's remaining work.

### 2.18au A NOTARY KEEPS ONE KEY - fold the notary secret into sk_identity

*"secret they generate? how is this different from regular PP or rarimo flow? can we fold it in?"*
(user, 2026-07-31). The right question, and the answer is that it should never have been a separate
secret. **Folded in.**

**WHAT WAS WRONG.** `notary_action` took a free `notary_secret`. That quietly invented a THIRD thing
for a person to keep: `sk_identity` for their identity, the escrowed revocation secret for the pool,
and now a notary key. **A secret that can be lost independently is a way to lose a professional role
independently** - and it was unnecessary, because `TitleLedger`'s own design note already says a
notary is a registered identity like any other user, revocable by the same machinery.

**THE FLOW IS ALREADY IN THE REPO.** `escrow_envelope::derive_revocation_secret` does exactly this:
`Poseidon(sk_identity, DOMAIN)`, with the domain separator checked against its own ASCII string so a
magic number cannot be copied wrong. `derive_notary_secret` is the same shape under
`"pp:notary-secret:v1"`, and lives in `pp::envelope` beside `secret_commitment` so both the circuit
and any future wallet code share ONE definition.

**THE DOMAIN SEPARATOR IS WHAT MAKES FOLDING SAFE, and it is the subtle part.** `TitleLedger`
deliberately refuses to reuse the POOL commitment, because publishing it would link a notary's public
professional role to their private financial identity - buying revocability by destroying the privacy
the pool exists to provide. Deriving under a DIFFERENT domain yields a commitment that is an
unrelated field element: without `sk_identity` nobody can connect the two. So the role becomes
revocable through the same identity machinery **without** publishing the link. Pinned by
`test_the_notary_commitment_is_unrelated_to_the_pool_commitment`, which asserts both the secrets and
the commitments differ, and that neither equals `sk_identity` itself.

**THE CIRCUIT NOW TAKES `sk_identity`**, deriving the commitment two hops deep, so the prover cannot
supply it directly - every active notary's commitment is public in the tree, and a free commitment
would let anyone name one and act as them. Regenerated the verifier and a real proof (the fixture
root moved, as it must when the derivation changes); 5 circuit tests, 87 `pp` tests, 380 forge tests.

**WHAT THIS DOES NOT SOLVE.** Nobody yet calls `registerNotary`: the postman still needs the
notary's commitment, which is now `secret_commitment(derive_notary_secret(sk_identity))` - derivable
by the notary's own wallet from the key they already hold, but no wallet code does that yet. The
secret-management problem is gone; the plumbing is not.

### 2.18av THE OLDER LIST, RE-CHECKED - most of it moved, two items still real

Asked whether an older agenda still applies. Checked rather than assumed:

- **§2.1 wallet-side withdrawal witness assembly - DONE** (2026-07-27). `src/pp/` now holds
  `withdrawWitness.ts`, `stateTree.ts`, `discovery.ts`, `notes.ts`, `identityProof.ts`, `deposit.ts`,
  `prove.ts`, `relay.ts`. It is no longer "the top of the critical path"; what it lacks is TESTS, not
  existence - see 2.18ak.
- **The `propertyKey` gap - STILL REAL, and still unassigned.** `TitleLedger` line 64 continues to
  say *"WHO COMPUTES IT IS UNRESOLVED"*, pointing at 2.16b. The two consequences stand: the mint path
  is unimplementable as written because no party holds `registryKey`, and a property owner cannot
  check whether their own property has been titled here - they can spot a fraudulent entry in the
  state register but not in ours, which is a detection path we simply lose. **Untouched by any of
  today's work**, and it is a design decision rather than a coding task.
- **§2.4c share-denominated notes, §2.5 predicate-bound revocation** - both still open, both
  contract/circuit shaped, neither blocked on hardware.
- **§3 pure TS/Solidity items** - denomination splitting, ERC-5564 stealth withdrawals, the
  SpvTreasuryAdapter stables leg, the orphaned `bitcoin.nr`. Still unblocked.
- **"Front-load the device work"** - partly overtaken. The NFC *config* is done (2.18ap) and the MRZ
  key derivation is done (2.18ar), but the premise that one can "write the NFC integration against
  the SDK's surface now" was WRONG: the SDK has no NFC surface at all (2.18aq). The integration is
  against jmrtd and NFCPassportReader, not against rarime's SDK.

### 2.18aw APPLYING THE BLACKLIST AND PSEUDONYM LENSES TO `propertyKey` - one lens condemns it, the other will not transplant

*"im not sure who should hold the registry key. what is the consequence of approaching it like we did
the blacklist and the labels"* (user, 2026-07-31). Worth doing, and it produces a harder answer than
"pick a holder".

**FACTS VERIFIED FIRST.** `titleOfProperty` is a PUBLIC mapping keyed by `propertyKey`, so every key
in use is readable on-chain. `TitleLedger` and 2.15 both state a notary *"holds no protocol key and
performs no protocol computation"*. So the key-holder cannot be the notary, and the outputs are not
hidden - only their preimages are.

**LENS 1 (2.13b, invert so it fails OPEN): THE REGISTRY-KEY HOLDER IS AN ALLOWLIST WEARING A
DIFFERENT HAT.** 2.13b's objection to an allowlist was not that it is a list - it is that **inaction
censors**: a postman who simply never admits you excludes you without ever acting, indistinguishably
from being slow. A `registryKey` holder is exactly that. Nothing can be minted without them
computing a value, so declining to compute is censorship with no act to point at, no rule to bind,
and no appeal. **So "who should hold it" is not an open slot to fill - filling it reintroduces
precisely the failure the ASP redesign existed to remove.** That is the first consequence, and it is
a condemnation of the mechanism rather than a difficulty in staffing it.

**LENS 2 (2.13c, public set + opaque membership): THE SAME TENSION APPEARS, BUT THE SECRET HAS THE
WRONG SHAPE.** 2.13c resolved "the list must be secret" against "non-inclusion must be trustlessly
provable" by making the SET public and each ENTRY an opaque PRF output. The critical structural
detail is that `s` is **PER-USER**: a prover needs only their own secret, and no one else's.

`propertyKey` cannot be built that way, because of what it is FOR. Uniqueness works by COLLISION:
two independent parties minting over the same property must compute the SAME value, or the duplicate
is not detected. That requires the key to be shared by **everyone who might ever mint**. A secret
that every potential minter must hold is not a secret - and once it is out, the input is
county-record enumerable, so every property's pseudonym is computable.

Stated as 2.13c stated its own: **"opaque to the public" and "duplicates collide" cannot both hold.**
Every option below is a choice about which one bends.

**AND THE RESOLUTION 2.13c ACTUALLY USED WILL NOT TRANSPLANT.** Epoch pseudonyms work because they
ROTATE - `PRF(s, T)` deliberately breaks linkage across epochs. A title's uniqueness must be
**PERMANENT**: a title minted in 2026 has to collide with a fraudulent one minted in 2031. Rotating
the key gives the same property different keys in different epochs, so cross-epoch double-minting
becomes undetectable. The one mechanism that fixed the blacklist is the one thing this problem cannot
use.

**THE SYMMETRY THAT MAKES THIS UNCOMFORTABLE, and it is the crux.** The lost detection path - an
owner cannot check whether their own property has been titled here - and the enumeration attack are
**THE SAME CAPABILITY**. Both are "compute the key from the public legal description and look it up".
There is no arrangement that lets an owner check their own property without letting an adversary walk
the county register. Any design must choose.

**OPTIONS, with what each costs:**

- **A - BARE PUBLIC HASH.** Uniqueness holds; no key-holder exists, so no one can censor by inaction;
  **owners regain the detection path**. Cost: the ledger is enumerable from county records - an
  observer learns which real properties are titled here, though not who holds them (`holderCommitment`
  is separate and stays private). This is the ONLY option that keeps uniqueness with no key-holder.
- **B - KEYED PSEUDONYM, shared key.** Confidential against outsiders, but the key-holders are a
  permissioned minter set: 2.13b's allowlist, restored. Fails closed by omission.
- **C - ATTESTED UNIQUENESS INSTEAD OF CRYPTOGRAPHIC.** Store a SALTED commitment and move
  uniqueness to the notary attesting *"I checked the register; this parcel has no live title"*.
  **TWO costs, and I initially recorded only one** - see the correction below.
  - *Uniqueness stops being cryptographic and becomes attested*: a deceived or colluding notary can
    double-mint and nothing on-chain detects it. Defensible, since notaries already anchor every
    other legal fact here and are now revocable (2.18am) - but a real reduction, not an equivalent.
  - *THE SALT IS A CUSTODY FAILURE.* **A lost salt makes the commitment permanently unopenable, and
    for a real property title that is unrecoverable.** This is worse than losing a pool note: a lost
    note costs money, whereas a lost title salt costs the ability to demonstrate that an entry
    corresponds to your actual home - potentially the collateral behind a loan.

**CORRECTION - I RE-PROPOSED SALTS HAVING DROPPED HALF THE OBJECTION.** *"we had a problem we noticed
with salts earlier, do you forget?"* (user, 2026-07-31). Yes. `TitleLedger`'s own comment records BOTH
reasons salts were rejected - *"the salt bought confidentiality by destroying uniqueness"* AND *"a
lost salt makes a commitment permanently unopenable - for a real property title that is
unrecoverable. There is no per-title secret here to lose."* I carried the first into option C and
silently lost the second, which is the exact failure sec. 2.18as was written about: reasoning that
exists in the repo not reaching the place where a decision gets made.

**THE CUSTODY HALF IS FIXABLE; THE UNIQUENESS HALF IS NOT.** Deriving the salt rather than randomising
it - `Poseidon(sk_identity, "pp:title-salt:v1")`, the pattern 2.18au just used for the notary secret -
makes it recoverable from the one key a holder already keeps, so `recovery.ts` restores it and there
is nothing extra to lose. **But it does NOT restore uniqueness**: a salt derived from the HOLDER still
differs between two holders minting over the same property, so duplicates still fail to collide.
Option C therefore remains "uniqueness by attestation", and the derivation only removes its second,
avoidable cost.

**WHICH SHARPENS THE COMPARISON.** Option A has neither problem - no secret to lose and uniqueness
intact - and pays only in enumerability. Option C, even with a derived salt, still trades a
cryptographic guarantee for a human one.

**NOT DECIDED HERE.** This is a design choice with a privacy/detectability trade at its centre, and
it is yours. What I can say from the analysis: **B is the option the project's own prior reasoning
already rejects**, so the live choice is between A and C - between an enumerable ledger that anyone
can audit, and a confidential one whose uniqueness rests on a revocable human attestation.

### 2.18ax A DESIGN WITH BOTH STRENGTHS: an oblivious PRF, and why it is the only shape that fits

*"no unrecoverable failure modes. what is something that has both options' strengths and none of
their weaknesses. look from all sides."* (user, 2026-07-31).

**THE REQUIREMENTS, stated so a candidate can be checked rather than argued about:**

| | requirement | A (bare hash) | C (salted) |
|---|---|---|---|
| R1 | duplicates COLLIDE, so double-minting is detectable | yes | **no** |
| R2 | an owner can check THEIR OWN property | yes | weak |
| R3 | the public cannot enumerate the ledger | **no** | yes |
| R4 | nobody can censor a mint by inaction | yes | yes |
| R5 | no unrecoverable failure mode | yes | **no** (lost salt) |

**WHY NO SIMPLE FUNCTION CAN SATISFY ALL FIVE.** R1 forces the value to be a DETERMINISTIC function
of the property alone - any per-holder input breaks collision. R3 forces it to be infeasible to
compute from public data. A deterministic function of a low-entropy, publicly-enumerable input is
brute-forceable, full stop. **So the function must contain a secret - and R4 says no one may hold a
secret whose withholding blocks a mint.** That is the whole problem in three lines, and it is why
"pick a key-holder" cannot work.

**THE RESOLUTION: MAKE THE SECRET UNUSABLE FOR CENSORSHIP AND UNUSABLE FOR ENUMERATION, RATHER THAN
UNHELD.** An **oblivious PRF** does exactly that. The minter learns `PRF(k, description)` WITHOUT the
key-holders learning the description, and without the minter learning `k`. Hold `k` as a THRESHOLD
key across the DON that already anchors the notary register.

Checked against each requirement:
- **R1** - the output is deterministic in the description, so two independent minters over the same
  property get the SAME value and collide. Uniqueness stays CRYPTOGRAPHIC, not attested.
- **R2** - an owner runs the OPRF on their own description and looks the result up. Detection intact.
- **R3** - enumeration requires one OPRF query PER CANDIDATE property, served by the threshold. Mass
  enumeration is therefore RATE-LIMITED and, more importantly, VISIBLE as query volume - the one
  thing a plaintext key never gives you.
- **R4, and this is the part that surprised me** - because the protocol is OBLIVIOUS, the key-holders
  **cannot see which property is being queried**. So they cannot selectively refuse one property or
  one person. They can only serve everyone or refuse everyone, and blanket refusal is a visible
  outage rather than silent omission. **Selective censorship becomes structurally impossible**, which
  is strictly stronger than what 2.13b asked for.
- **R5** - the user holds NO secret in this scheme. Nothing to lose, nothing to back up.

**WHAT IT ACTUALLY COSTS, stated rather than buried:**
- **Liveness becomes a dependency.** Minting and checking both need a threshold of the DON online. A
  key that is never lost but temporarily unreachable is an availability failure, not an
  unrecoverable one - but it is real, and it is new.
- **New machinery.** A threshold OPRF (2HashDH-style) is well-understood and deployed elsewhere
  (Privacy Pass, OPAQUE), but nothing in this repo implements one today.
- **`k` must never rotate**, for the same reason epoch pseudonyms could not be transplanted (2.18aw):
  uniqueness must hold across decades, so a rotated key silently un-collides old titles against new
  ones. That makes `k` a permanent threshold secret - losing it above the threshold would be
  catastrophic in the R5 sense, so the recovery story for `k` itself has to be part of the design.

**NOT BUILT, AND NOT VERIFIED IN THIS STACK.** The reasoning above is sound about the PRIMITIVE; what
is unchecked is whether a threshold OPRF composes with CRE's consensus model (every node must produce
byte-identical output - an OPRF evaluation is deterministic given `k`, so it plausibly does, but
"plausibly" is not "checked"), and whether the result needs to be proven in-circuit anywhere. Both are
answerable without hardware.

### 2.18ay LOST PHONE: recovery exists, and the deeper fix is to derive the root from the passport

*"lets say i lost my phone with all my enclave notes. there is no recovery ceremony similar to
unforgettable sdk possible in theory?"* (user, 2026-07-31).

**IT ALREADY EXISTS, and this was built earlier in this project.** `identity/recovery.ts` backs up
**the one root mnemonic every other key derives from**. Its own header records why it was needed: the
phrase was GENERATED and never displayed, and `WHEN_UNLOCKED_THIS_DEVICE_ONLY` deliberately excludes
it from iCloud/device backups - so a lost, wiped or re-enrolled phone meant a permanently lost
identity and every pool note gone. **The distinction that made a fix possible: the phrase is NOT a
non-extractable Secure Enclave key**, it is a value stored in Keychain and readable after biometric
auth. Recovery was unbuilt, not impossible.

**WHY NOT AN MPC/SOCIAL-RECOVERY SDK (Web3Auth, Turnkey, Privy, Para) - already decided (2.22c).**
Every one puts a share on somebody's server, and most gate recovery behind Google or Apple sign-in.
That is the deniable-refusal lever this project exists to remove, and a US-operated dependency for
exactly the users least able to afford one.

**THE DEEPER FIX, and it composes with everything derived today.** `sk_identity` currently comes from
the mnemonic, so losing BOTH phone and phrase is still terminal. But the passport is the one credential
a user still holds after losing a phone. If `sk_identity` were derived from something the CHIP can
re-produce plus a memorised passphrase, then re-scanning recovers everything downstream -
`derive_revocation_secret`, `derive_notary_secret`, and a derived title salt all hang off
`sk_identity`, so one recovery restores the pool notes, the notary role and the title bindings at once.

**THE HONEST CAVEATS, because this is attractive enough to be adopted carelessly:**
- **DG data is NOT secret.** Anyone who reads your chip has DG1. So chip data alone cannot be the
  secret; a passphrase is mandatory, and a memorable passphrase is low-entropy against an adversary
  who has already read your chip. A deliberately slow KDF mitigates, it does not solve.
- **Active Authentication would be the right primitive and we do not have it.** The AA private key
  never leaves the chip, so a signature over a FIXED challenge is a secret an attacker cannot extract
  from a photocopy. But all six of our profiles are `NA` (no DG15, 2.18aj), and AA determinism depends
  on the signature scheme - RSA PKCS#1 v1.5 is deterministic, ECDSA generally is not unless RFC 6979.
- **Changing the derivation of `sk_identity` is not backward-compatible** with any identity already
  registered, so it is a pre-launch decision.

### 2.18az NEAR-DUPLICATES DEFEAT COLLISION-BASED UNIQUENESS - the flaw under A, C *and* the OPRF

*"what if duplicates wont be perfect duplicates?"* (user, 2026-07-31). **This is the most damaging
question asked about the title design, and it invalidates a premise every option above shares.**

**HASHES COLLIDE ON BYTES, NOT ON MEANING.** `"42 Khreshchatyk St"`, `"42 Khreshchatyk Street"`,
`"42 khreshchatyk st."`, `"вул. Хрещатик, 42"` are ONE property and FOUR different hashes. So a second
title over the same land does not collide, `titleOfProperty` sees a fresh key, and **double-minting
succeeds silently** - defeated not by cryptography but by whitespace. Every option in 2.18aw and
2.18ax inherits this: A, C and the OPRF are all deterministic functions of a STRING.

Real registries make it worse, not better: abbreviation variance, Cyrillic/Latin transliteration,
component ordering, and - specifically for Ukraine - **mass street renaming since 2022**, which means
the same parcel legitimately has different descriptions before and after.

**AND A HASH CANNOT DETECT NEAR-DUPLICATES BY CONSTRUCTION.** It is all-or-nothing: it cannot report
"this is 95% the same property". So the mechanism cannot even FLAG a suspicious near-match for human
review. That is the specific "silent error" shape the user asked about.

**THE FIX IS TO STOP HASHING PROSE.** Key on the **registry-assigned canonical identifier** - Ukraine's
cadastral number (`8000000000:82:031:0016`), Iran's plaque/registration number - which the state
registry itself assigns and which the notary already reads when attesting. Consequences:
- Collisions become meaningful again, because the input is canonical by construction.
- **It does not fully close.** Parcel SPLITS and MERGES issue new identifiers for land that overlaps
  old ones, so a merged parcel can be titled while its constituents already are. That needs an
  explicit rule, not a hash.
- It makes enumeration EASIER (cadastral numbers are structured and low-entropy), which strengthens
  the case for the OPRF's rate-limiting rather than weakening it.
- **The notary attestation stops being optional.** Only a human reading the register can say "this
  cadastral number is the land this deed describes", and only a human can catch a split/merge case.
  So uniqueness is cryptographic ON THE IDENTIFIER and attested ON THE MAPPING from deed to
  identifier. That is a more honest description of what any of these designs can deliver.

**RECORDED AS A CORRECTION TO 2.18aw/2.18ax rather than a footnote:** the comparison there was
between options that all silently assumed byte-identical inputs. That assumption is false, and no
choice among A/C/OPRF matters until the INPUT is canonical.

### 2.18ba DOES `recovery.ts` GET ALL THE NOTES BACK? Yes - bounded by a gap limit that fails silently

*"does recovery.ts enable getting all the notes?"* (user, 2026-07-31). Checked rather than assumed.

**THE DERIVATION IS FULLY DETERMINISTIC**, so the mnemonic is sufficient in principle:
`masterKeysFromMnemonic(mnemonic)` yields `masterNullifier`/`masterSecret`; deposit notes are
`Poseidon(master, scope, index)`; withdrawal (change) notes are `Poseidon(master, label, index)`.
Nothing else is needed - no server, no per-note backup.

**BUT DISCOVERY IS A SCAN WITH A GAP LIMIT.** `discovery.ts` documents `scanDepositIndices` as *"how
many deposit indices to scan per scope (HD gap limit)"*. Notes beyond that limit are **not found, and
nothing reports that they were missed** - the wallet simply shows a smaller balance. That is the same
silent-failure shape as 2.18az: an under-count that looks like an answer.

**WORSE FOR CHANGE NOTES**, because they chain: withdrawal notes key on `label`, which comes from a
DEPOSIT. A deposit missed by the gap limit takes every change note descended from it with it.

**WHAT SHOULD CHANGE** (not done here): the gap limit must be a LOUD boundary rather than a quiet
one - scan until N consecutive empty indices AND report the highest index found, so a user whose
notes sit beyond the window sees "scanned to index N" rather than a confidently wrong balance. The
loop-until-dry shape, applied to recovery.

### 2.18bb DG DATA CANNOT BE MADE SECRET - and nothing beats Active Authentication, because the problem is not AA

*"how do we make the DG data secret... is there something even better than active authentication?"*
(user, 2026-07-31).

**DG DATA CANNOT BE SECRET.** It is on the chip; BAC/PACE gates reading it behind the MRZ, which is
PRINTED ON THE PAGE. So the true statement is not "secret" but *"available to anyone who physically
handles the document, or photographs the data page"* - which includes border control, police, hotels,
and anyone who steals it. There is no configuration that changes this.

**IS THERE SOMETHING BETTER THAN AA? Yes and no, and the "no" is the important half.**
- **Chip Authentication (CA)**, part of EAC, is generally considered SUPERIOR to AA: the chip holds a
  static DH private key and proves genuineness by establishing a shared secret, instead of signing a
  terminal-supplied challenge. **AA is a signing oracle** - it will sign whatever challenge it is
  given, which is a known criticism (the "challenge semantics" problem).
- **But CA does not fix the thing we care about.** Both AA and CA are properties of the CHIP, and a
  passport is a **BEARER CREDENTIAL**. Anyone in physical possession can run either protocol and
  derive exactly the same value. **You cannot extract a personal secret from a bearer token.**

**SO THE THREE CAVEATS IN 2.18ay ARE NOT AA'S LIMITATIONS - THEY ARE THE LIMITATION OF THE APPROACH.**
Being told they are "unacceptable" is fair, and the correct response is not a better chip primitive:
it is to stop trying to derive an unrecoverable-proof secret from a document that a border guard can
hold. Any passport-derived key is compromised by the exact adversary this project exists to resist.

**WHAT ACTUALLY DELIVERS "NO UNRECOVERABLE FAILURE MODES" WITHOUT THAT TRADE.** 2.22c rejected
Web3Auth/Turnkey/Privy/Para for specific reasons - *a share on somebody's server*, and *recovery gated
behind Google or Apple sign-in*. **It did not reject threshold recovery itself.** Shamir shares held
by GUARDIANS THE USER CHOOSES - people they know, offline, no company and no US dependency - keep the
property (any k of n restores the mnemonic) while avoiding every objection 2.22c actually raised.
Combined with the existing user-held mnemonic backup, that gives two independent recovery paths and no
single point of loss. **This is the direction to take**, and it is unblocked: it is client-side
cryptography over a value that already exists.

### 2.18bc WHAT A STOLEN PASSPORT REVEALS TODAY - and why access control would be theatre

*"if someone's passport is stolen can they still break the vulnerability... make sure that a single
holding of the passport reveals no notes, or anything PP related. keep it as damage-minimised as
possible"* (user, 2026-07-31). Traced rather than assumed.

**THE GOOD NEWS FIRST, because it is real and was deliberate.** A stolen passport reveals **NO NOTES
AND NO POOL HANDLE**:
- Note secrets are `Poseidon(masterNullifier|masterSecret, scope|label, index)`, and the masters come
  from the MNEMONIC via `masterKeysFromMnemonic` - **HD path index 100 for `sk_identity`, separate
  indices for the PP masters**. The passport is nowhere in that derivation.
- `escrow_envelope` **used to publish `holder_root` and `dg1_hash` and no longer does** - dropped in
  2.18 precisely because they were per-person identifiers linking identity to pool handle in
  registration calldata. That link is already closed.

So the phone is what protects the money, and a thief with the passport but not the phone gets no
notes, no balances, no withdrawal history.

**THE LEAK THAT REMAINS, and it is a one-call lookup.** `HolderStateKeeper` exposes
`holderOfDocumentHash(bytes32) external view` over `_holderOfDocumentHash: dg1Hash => holderRoot`. So
anyone who holds the document can:

1. read the chip -> DG1 -> compute `dg1Hash` (BAC needs only the printed MRZ),
2. call `holderOfDocumentHash(dg1Hash)` -> **`holderRoot`**,
3. and `holderRoot` is an INDEXED topic on `DocumentAdded` / `DocumentRegistered` /
   `DocumentRenewed` / `DocumentRevoked` - so one log query yields **how many documents that person
   holds, which types, when each was registered, and every renewal and revocation**.

For the stated threat model that is serious on its own: it tells a border guard, a police officer or
a thief that this person USES THIS PROTOCOL, and multi-citizenship makes it worse - the whole point
of one holder key with several documents is that the set is private, and this publishes its size.

**MAKING THE GETTER PRIVATE WOULD BE THEATRE, and this is the important part.** The obvious fix -
drop `external`, or gate it to the identity registry - **does not work**. The value lives in contract
STORAGE, and any mapping slot is computable and readable with `eth_getStorageAt` by anyone, whatever
Solidity's visibility says. Visibility keeps out casual callers; it does not keep out the adversary
who already has your passport in their hand. **A fix that only removes the getter would look like a
fix and not be one** - exactly the shape this project keeps catching.

**THE REAL FIX IS THE SAME PRIMITIVE AS `propertyKey`, and the tension is structurally identical:**
- anti-replay requires a value **deterministic in the DOCUMENT** - the same passport must not bind
  twice under two holder roots (`test_sameDg1CannotBindToASecondHolderRoot`, and 2.18 records that
  re-homing defeats any identity blacklist by construction);
- privacy requires that value **not be computable by whoever holds the document**.

Deterministic-in-a-bearer-readable-input versus not-enumerable is precisely 2.18ax's problem. So key
the anti-replay on **`OPRF(k, dg1Hash)`** with `k` a threshold key: still deterministic given `k`, so
re-homing stays blocked; not computable by a passport holder without a query that is **oblivious**
(the holders never learn which document) and **rate-limited** (bulk checking of a seized stack of
passports is visible as volume). One primitive, two problems - which is an argument for building it
properly rather than twice.

**DAMAGE-MINIMISATION AVAILABLE WITHOUT THE OPRF**, ranked by whether they actually help:
1. **Stop indexing `holderRoot` on the four document events.** Genuine and cheap: it converts "one
   log query for this person's full history" into "scan and decode every event ever emitted". Does
   not stop a determined adversary, does raise the cost of the casual one, and costs nothing.
2. **Do not return `holderRoot` at all** - have the registry pass `dg1Hash` and receive a boolean, so
   the mapping's VALUE never crosses the ABI. Storage remains readable, so this is a smaller win than
   it looks, but it removes the value from every trace, log and archive-node RPC response.
3. **Recovering the phone changes nothing about this leak** - it is on-chain state, not device state.
   Which is the honest answer to "can they still break it if the phone is recovered": the notes were
   never at risk from the passport, and the registration history was never protected by the phone.

**RECORDED AS A DEFECT, NOT A DESIGN NOTE.** It is not a break of the pool, and it does not touch
funds - but it does defeat the multi-citizenship privacy property that one-key-many-documents exists
to provide, and it is reachable by anyone who handles the document for thirty seconds.

### 2.18bd CAN THE MNEMONIC BE GUESSED? No - and the check found a real bug next to it

*"what if the mnemonic can be guessed? then all crypto wallets in the world are hackable? are you
sure that this security is impenetrable?"* (user, 2026-07-31).

**NO, IT IS NOT IMPENETRABLE, and saying otherwise would be the wrong answer.** Nothing is. But the
mnemonic's brute-force resistance is not the weak link, and the reason is arithmetic rather than
faith: `root.ts` generates `Mnemonic.fromEntropy(hexlify(randomBytes(32)))` - **32 bytes, 256 bits,
24 words**, not the common 12. A 2^256 search is not "expensive", it is beyond any physically
conceivable computation, and even Grover's square-root speed-up leaves 2^128.

**REAL WALLETS ARE NOT BROKEN BY GUESSING SEEDS - THEY ARE BROKEN BY BAD ENTROPY.** Trust Wallet's
2022 browser-extension flaw and the "Milk Sad" libbitcoin bug both generated seeds from a weak or
32-bit-seeded RNG, so the search space collapsed from 2^256 to something enumerable. **That, not
brute force, is the class of bug worth checking for** - so I checked ours.

**THE RESULT IS THE SAFE ONE, and it is structural rather than lucky.** Metro aliases `crypto` to
`crypto-browserify`; its `randombytes/browser.js` reads `global.crypto || global.msCrypto` and, when
`getRandomValues` is absent, exports `oldBrowser` - **a function that THROWS**. It does not fall back
to `Math.random`. So a weak, guessable mnemonic is not a reachable state in this wallet: the failure
mode is "identity creation fails loudly", never "identity created with 32 bits of entropy".

**BUT THE CHECK FOUND A REAL BUG: `polyfills.ts` WAS NEVER IMPORTED.** The file exists and installs
`react-native-get-random-values` and `global.Buffer` - and **nothing referenced it**: not `index.ts`,
not `App.tsx`, not `src/`, not `metro.config.js`, not `babel.config.js`. `index.ts` was three lines
and imported only `expo` and `./App`. So either identity creation throws on first run, or it works
only because the Expo runtime happens to provide `getRandomValues` itself - and which of those is
true cannot be settled without a device build.

**FIXED:**
1. `index.ts` now imports `"./polyfills"` FIRST, with the position documented as load-bearing rather
   than stylistic - an import that must precede all others is exactly the kind that gets dropped.
2. **`react-native-get-random-values` moved from `devDependencies` to `dependencies`.** A RUNTIME
   polyfill in devDependencies survives only because Metro bundles whatever is imported; an
   `npm install --production` would omit it.
3. `root.ts` now asserts `globalThis.crypto?.getRandomValues` before generating, and **names the real
   cause**. The inherited message is *"Secure random number generation is not supported by this
   browser. Use Chrome, Firefox or Internet Explorer 11"* - accurate for a browser, baffling in a
   mobile wallet, and it names neither the polyfill nor the file that should import it. The guard
   adds no safety; it makes the diagnosis instant.

**WHERE THE ACTUAL RISK LIVES, since "impenetrable" deserves an honest answer:** not in the seed's
length, but in (a) the entropy source - now checked and fail-loud, (b) storage, which is SecureStore
behind biometrics with `WHEN_UNLOCKED_THIS_DEVICE_ONLY`, (c) **the user's own backup handling**, which
no code can defend, and (d) the supply chain - ethers, noble, crypto-browserify and the rarime SDK all
run before any of our logic does. (d) is the one nobody in this project has audited.

### 2.18be BLACKLISTING IS PER-IDENTITY, NOT PER-DOCUMENT - and the leak is worse because of it

*"REMEMBER THAT BLACKLISTING IS ON AN IDENTITY, NOT A DOCUMENT... ONE OF YOUR DOCS MIGHT BE GOOD
ANOTHER NOT"* (user, 2026-07-31). Correct, and it sharpens 2.18bc rather than softening it.

**THREE DISTINCT MECHANISMS, and conflating any two produces a wrong design:**

| level | keyed on | what it does | where |
|---|---|---|---|
| **document anti-replay** | `dg1Hash` | one physical passport binds to ONE holderRoot, ever | `_usedDocumentHash`, `_holderOfDocumentHash` |
| **document status** | `documentKey` | one document revoked/renewed/expired, the others unaffected | `revokeDocument`, `renewDocument`, `getActiveDocumentCount` |
| **identity blacklist** | the identity commitment | the PERSON cannot withdraw | `IdentityRegistry`, `withdraw_identity`'s STATUS_CLEAN |

**So one bad document does NOT taint the identity.** `getActiveDocumentCount(holderRoot)` gates on
*any* current document, and the pool proves inclusion at STATUS_CLEAN for a commitment derived from
`sk_identity` - which no document revocation touches. A person with an expired passport and a valid
ID card keeps acting on the ID card. **That is deliberate and must survive any change here** - the
OPRF proposal in 2.18bc changes only the ANTI-REPLAY key and must not be read as moving revocation
to the document level.

**AND IT MAKES THE STOLEN-DOCUMENT LEAK WORSE THAN 2.18bc STATED.** Because blacklisting is
per-identity, learning `holderRoot` from ONE seized document is enough to name the unit the blacklist
acts on - and, via the indexed events, to enumerate every OTHER document under it. So the damage from
holding one document is not "this document is known" but **"this person, and their entire document
set, is identified"**. For a multi-citizenship holder - the exact user this design exists for, someone
whose second passport is the way out - a single border inspection exposes the set. That is the
strongest argument yet for both fixes: the OPRF on the anti-replay key, and de-indexing `holderRoot`.

### 2.18bf ENTROPY HARDENED, AND `holderRoot` DE-INDEXED

*"make sure the entropy source is as bulletproof as conceivable within the laws of physics. leaks
must be impossible. do the deindex"* (user, 2026-07-31). Both done; the honest limits of each are
stated rather than glossed.

**ENTROPY - `src/identity/entropy.ts`, 14 tests.** Seed generation no longer calls one RNG directly:

1. **The CSPRNG is asserted, and its absence names the fix.** The inherited failure was already SAFE
   (crypto-browserify throws rather than falling back to `Math.random` - 2.18bd), but its message
   said *"use Chrome, Firefox or Internet Explorer 11"* inside a mobile wallet. This adds no safety,
   only an instant diagnosis.
2. **Degenerate output is rejected** - all-zero (an uninitialised buffer), all-0xFF, or any single
   byte repeated (a stuck counter, a stubbed mock). **This is a sanity check, not a randomness test**,
   and the distinction is the point: no test can certify 32 bytes are random, since every specific
   value is equally likely. It catches a source that has plainly STOPPED, and a real CSPRNG hits it
   with probability 256/2^256 - never, in practice.
3. **Multiple sources are mixed through keccak-256, not XOR.** XOR would be adequate but preserves
   position-correlated bias; hashing the concatenation is a randomness EXTRACTOR, so any ONE source
   with full entropy makes the digest unpredictable no matter what the others did. The source COUNT
   and NAMES are hashed in for domain separation - without that, one source returning `a || b` would
   be indistinguishable from two returning `a` and `b`, letting a single compromised source
   impersonate the whole mix.
4. **Every source must succeed.** A throwing source ABORTS generation rather than being skipped -
   silently degrading from two sources to one is exactly how a mixing scheme becomes decorative, and
   the caller cannot tell from the output.

**THE LIMIT, because "bulletproof within the laws of physics" deserves the caveat:** mixing defends
against ONE source failing - a polyfill regression, a platform bug, a bad backport - which is the
realistic case. **It cannot invent entropy if every source is broken the same way.** And nothing here
defends the seed AFTER generation: storage, the user's backup handling, and the supply chain (ethers,
noble, crypto-browserify, the rarime SDK all run before our code) are separate, and the last of those
is unaudited. 256 bits is beyond brute force under any physics we know, including Grover's
square-root speed-up, which leaves 2^128.

**EVERY GUARD IS TESTED BY BREAKING WHAT IT GUARDS** - a stuck source, a predictable source, a
throwing source, a short read, a missing polyfill. A mixing scheme never fed a broken source would
pass identical tests whether or not its checks fired.

**DE-INDEX - five events, `holderRoot` no longer a topic:** `DocumentAdded`, `DocumentRenewed`,
`DocumentRevoked` (`HolderStateKeeper`), `DocumentRegistered`, `DocumentRenewedVia`
(`HolderRegistration`). Verified no consumer filters on it - only emit sites exist - so nothing
breaks; 380 forge tests pass and client ABIs are clean.

**WHAT IT BUYS AND WHAT IT DOES NOT.** It converts "one `eth_getLogs` call returns this person's
entire document set" into "fetch and decode every event this contract ever emitted" - which defeats
casual and bulk lookup at real cost. It does **NOT** defeat an adversary who scrapes the whole log,
and it does **NOT** hide contract STORAGE: `_holderOfDocumentHash` stays readable via
`eth_getStorageAt` whatever Solidity visibility says. **So "leaks must be impossible" is not yet
true**, and no event change can make it true - the complete fix is making the anti-replay key
uncomputable from the document itself (the OPRF, 2.18bc). This is the part available without that
decision, kept rather than dismissed for being partial.

### 2.18bg THE COMPLETE FIX WAS DELETION, NOT AN OPRF - the leak was dead code

*"we shouldnt depend on events. do the complete fix"* (user, 2026-07-31). Right on both counts, and
investigating produced a far better answer than the one I had proposed.

**I HAD THE FIX WRONG.** 2.18bc concluded the complete fix was an OPRF under a threshold key - new
machinery, a liveness dependency, and a quorum this project does not have. Before building that I
checked what `_holderOfDocumentHash` (dg1Hash => holderRoot) is actually FOR. **Nothing calls it.**
The only surviving references were TEST COMMENTS describing what the contract *used to* do:
*"That worked while the contract only checked `holderOfDocumentHash`; since [then] the leaf VALUE
carries the soundness"*. Its own doc comment still explained why it was indispensable - and was
STALE, describing a design that had already moved into the `registrationSmt` leaf.

**SO THE COMPLETE FIX WAS TO DELETE IT.** The mapping, its public getter and both writes are gone.
382 forge tests pass, client ABIs clean. **The worst leak in the identity path was vestigial code
nobody had removed** - which is why the honest move was to check the mechanism before building
cryptography to defend it.

**WHAT A SEIZED DOCUMENT REVEALS NOW.** Only `_usedDocumentHash`, a BOOL, remains keyed on something
a document-holder can compute. So the leak is bounded to **one bit - "this document is registered
here"** - and yields nothing about WHICH identity holds it, how many other documents that identity
holds, or what they are. Given that blacklisting acts on the IDENTITY (2.18be), removing the
identity link removes the ability to name the unit sanctions apply to. That is the difference between
"this person and their entire document set are identified" and "this passport appears in some
system".

**AND EVENTS ARE NO LONGER LOAD-BEARING FOR THIS**, which was the user's actual objection. The
de-indexing in 2.18bf was a mitigation for a leak that no longer exists; it stays because a public
`holderRoot` topic is still worth not publishing, but **nothing about the fix now depends on how logs
are indexed.** Storage was always the real surface - `eth_getStorageAt` ignores Solidity visibility -
and storage is where the fix landed.

**PINNED BY TWO TESTS, ONE OF THEM MUTATION-CHECKED:**
- `test_noPublicFunctionMapsADocumentHashToItsHolder` probes the deployed ABI rather than the source,
  so a future getter under a DIFFERENT NAME would still be caught - a grep would not. **Verified
  non-vacuous:** re-adding a `holderOfDocumentHash` getter makes it fail with its own named message.
- `test_theAntiReplayGuardStillRejectsAReusedDocumentHash` - privacy must not have been bought by
  weakening the guard that stops one physical passport binding to two identities, which is what
  defeats an identity-level blacklist by construction. **Note the trap it avoids:** `documentHash_`
  is the SECOND parameter of `addDocument`, and every existing test passes `bytes32(0)` there, which
  SKIPS the anti-replay path entirely - a test copied from its neighbours would have asserted nothing.

**WHAT REMAINS FOR THE OPRF.** Only the one bit. Removing even that needs the anti-replay key to be
uncomputable from the document, which still means a threshold party. **That is now a much smaller
prize for a much larger cost**, and the decision should be re-taken on those terms rather than the
ones in 2.18bc.

**AUDITED FROM ALL SIDES AFTERWARDS, and the audit found a hazard I had introduced.**

1. **Did deleting it break the security property its comment claimed?** The stale comment warned that
   without the lookup *"a caller could invent a DG1, escrow against it, and land a commitment in the
   identity tree backed by no real document - which would make the tree's scarcity guarantee, and
   therefore the entire blacklist, worthless."* That is a real property, so I verified the
   replacement rather than trusting a test comment: `IdentityRegistry` line 271 requires
   `registrationSmt.isRootValid(registrationRoot_)`, and its own note says the alternative would let
   a prover *"build a tree containing whatever leaf they liked and prove inclusion in that."* The
   escrow circuit proves inclusion of the document leaf; the contract confirms the root came from the
   REAL state keeper, whose only writer is `HolderRegistration`, which does the ICAO check.
   **Property intact.**

2. **STORAGE LAYOUT - THE HAZARD I CREATED.** `HolderStateKeeper` is UUPS-upgradeable and slots are
   assigned by DECLARATION ORDER, so removing a variable from the MIDDLE shifts everything after it.
   `lastDocumentInvalidationAt` was declared immediately after the deleted mapping, and
   `IdentityRegistry` line 277 reads it to enforce `RegistrationRootPredatesAnInvalidation`. **A
   shifted read returns 0, that guard never fires, and a revoked document can escrow against its
   pre-revocation root forever** - the same silent class as sec. 2.18b/e, reintroduced by a change
   made for privacy. No deployment exists in this repo, so a clean deletion would have been safe
   today; a `bytes32 private __deprecated_holderOfDocumentHash` placeholder makes it safe even if an
   instance exists somewhere unrecorded. One unused slot against a silently disabled revocation
   guard is not a close call.

3. **Dangling interface?** None - no `IHolderStateKeeper` or other declaration still exposes the
   removed getter, so no caller can compile against a function that no longer exists.

4. **Does the remaining bool enable more than stated?** Combined with holding the document, it tells
   the holder *"this person uses this protocol"*. That is a real disclosure for this threat model and
   is not eliminated - it is the one bit the OPRF would remove.

5. **Renewal path** still marks `_usedDocumentHash[newDocumentHash_]`, so anti-replay covers renewed
   documents and the deletion did not open a re-binding window there.

### 2.18bh "IS THAT BIT EVEN NECESSARY?" - the bit is, but it was never the main leak. My fix was incomplete.

*"leave no unresolved issues. are you sure that bit is even necessary?"* (user, 2026-07-31). Asking
made me re-derive the surface instead of trusting my own summary, and **the summary was wrong.**

**FIRST, THE BIT ITSELF: YES, NECESSARY.** `_usedDocumentHash` is what stops one physical passport
binding to two holder roots. Since blacklisting acts on the IDENTITY (2.18be), re-binding a seized or
owned passport to a FRESH identity escapes the blacklist entirely - and the attacker can do it,
because they hold the document and can produce a valid registration proof. sec. 2.13b already states
the general form: *"a negative proof is only meaningful against a scarce identity."* The bit is what
makes a document scarce. Removing it does not reduce a leak, it removes the guard.

Bucketing it - the `PRECOMMITMENT_BUCKETS` trick used elsewhere in this repo for exactly this shape of
problem - **does not work here.** Uniqueness checks cannot tolerate collisions: two unrelated
documents sharing a bucket would make the second registration fail as "already used", locking a
legitimate holder out permanently. Confidentiality by collision is fine for DISCOVERY and fatal for
UNIQUENESS.

**BUT THE BIT WAS NEVER THE MAIN LEAK, AND I SAID THE FIX WAS COMPLETE WHEN IT WAS NOT.** Re-deriving
the surface from scratch:

| path | key | passport-derivable? | leaks |
|---|---|---|---|
| `_usedDocumentHash` | `dg1Hash` | **yes** | one bit: registered or not |
| `_documents` | `documentKey` | **YES** - it is `passport.publicKey` / the proof's `passportHash`, both readable from the chip | **`holderRoot`, via `DocumentBond.holderRoot`** |
| `registrationSmt` leaf | `Poseidon(documentKey, holderRoot)` | no - needs `holderRoot` | nothing |
| `_holderDocuments` | `holderRoot` | no - needs `holderRoot` first | nothing (not an entry point) |

**`_documents` IS THE SAME LEAK I JUST CLOSED, THROUGH A SECOND DOOR.** `getDocument(bytes32)` is a
public getter returning `DocumentBond`, whose first field is `holderRoot`. And - exactly as with the
mapping I deleted - **removing the getter would be theatre**, because `_documents[documentKey]` has a
computable slot and `eth_getStorageAt` ignores Solidity visibility. So deleting
`_holderOfDocumentHash` narrowed nothing in practice while I described it as the complete fix.

**WHY I MISSED IT.** I audited the change I MADE rather than the PROPERTY I claimed. Five angles in
2.18bg, all about whether the deletion broke something - none asking "what OTHER document-keyed state
reaches `holderRoot`?" A fix is not verified by checking that it did no harm.

**WHAT AN ACTUAL FIX REQUIRES.** Any mapping from a passport-derivable key to `holderRoot` leaks,
whatever its visibility. So the key must stop being passport-derivable: `_documents` would have to be
keyed on `Poseidon(documentKey, holderRoot)`, so that finding a bond requires already knowing the
holder. That is a real refactor - `revokeDocument`/`renewDocument`/`getDocument` all take
`documentKey` alone today and would need the pair - and it is NOT blocked on the OPRF, unlike the
remaining one bit. **Not attempted here rather than half-done**, because it touches the revocation
path, which is the last thing to change carelessly.

**SO "LEAVE NO UNRESOLVED ISSUES" IS NOT YET TRUE, and saying otherwise would be the more comfortable
lie.** State of the surface: the identity link is still reachable from a seized document via
`_documents`; the one-bit existence leak needs a threshold party; the storage-layout hazard from
2.18bg is closed with a reserved slot; and no event depends on any of it.

### 2.19 THE ORIGINATOR MODEL IS INCOHERENT - the borrower's equity IS the first loss

*"i dont think the origination logic really makes sense?"* (user, 2026-07-29). It does not. Stated
plainly it contradicts itself:

- If an originator HAS capital to post first-loss, **they do not need our pool** - they could lend it
  directly. The premise of this project is that capital is scarce and sanctioned.
- If they DO NOT have capital, they cannot post first-loss, and the accountability mechanism I built
  the whole structure on does not exist.
- And bearing first-loss for an origination fee is a bad trade for them regardless. We were asking
  someone to take most of the risk for a fraction of the return.

I imported RMBS structure because the problem LOOKED like "the pool has no counterparty with
knowledge", without asking whether a mortgage already contains its own answer. It does.

**THE BORROWER IS THE ACCOUNTABLE PARTY, AND ALWAYS WAS.** A mortgage is over-collateralised BY
CONSTRUCTION. At 70% LTV the borrower holds 30% equity - **that IS the first-loss position**, posted
in the asset itself rather than in someone else's balance sheet. They know the property because they
own it. They are legally bound because they executed the irrevocable assignment
(*Vekālat-nāmeh-ye Belā-'Azl*) at origination. Nothing needs to be invented.

**WHAT ACTUALLY REMAINS, and it is much smaller:**
- **Title verification** - Tier 2 *Tasdiq-e Asalat*, which ANYONE can perform and a CRE workflow can
  attest. No originator required.
- **Lien creation** - Tier 3, the one thing only a notary can do. Already designed.
- **Servicing** - payments are on-chain and the schedule is contract logic; this is largely automated
  rather than a role.
- **Foreclosure** - the named vendors, already in the spec.
- **APPRAISAL - the genuinely missing role.** Someone must value the property, and the protocol
  cannot. Options, in order of preference: CRE-attest a licensed appraiser's registration exactly as
  for notaries; use auction comparables from *setadiran.ir*, which is public data an oracle can read;
  or set LTV conservatively enough that appraisal error is absorbed by the borrower's equity.

**THIS DELETES THE RISK I FLAGGED AS MOST LIKELY TO KILL LENDING.** §2.17e called "no originator will
partner with us" the single most likely reason the lending layer never ships. That risk is now GONE,
because the model no longer requires one. What replaces it is a smaller and more tractable problem:
attesting an appraisal.

**FUNDING-APPLICATION.md MUST BE CORRECTED** - it currently presents the distributor/originator model
in Milestone 4 and names originator sourcing as a budgeted field-work activity and a headline risk.
Both are now wrong.

### 2.20 ADVERSARIAL TEARDOWN OF THE WHOLE MODEL (user: "try to break every assumption")

Attacking each assumption rather than defending it. **Five of six break. The identity and title
layers survive; the lending layer does not.**

**BREAK 1 - THE BORROWER'S EQUITY IS NOT INDEPENDENT PROTECTION, and this kills §2.19.**
I concluded yesterday that 30% equity IS the first loss, so no third party is needed. Wrong. Equity
only protects if the VALUATION is honest - and the borrower both supplies the valuation input and
benefits from inflating it. Inflate an appraisal 50% and the "30% equity" is fictional; the loan is
underwater at origination. **I moved the fraud from the notary to the appraisal and handed it to the
party with the strongest motive to lie.** So the independent, competent, accountable valuer is not a
small remaining piece - it is the core problem, and calling them an appraiser rather than an
originator does not make them easier to recruit. §2.19 was too optimistic and §2.17e's recruitment
risk is NOT deleted, only renamed.

**BREAK 2 - A POOL CANNOT HOLD A LIEN.** Foreclosure needs a named creditor with standing in an
Iranian court. A smart contract has none, and neither does a diffuse set of QUI holders. Somebody
must hold the lien as nominee - a legal entity that can be coerced, sanctioned, or simply abscond
with the security interest of every loan in the book. That is a single point of failure with no
cryptographic mitigation, and it is not in any version of the design so far.

**BREAK 3 - THE LENDING LAYER'S PRIVACY IS NEAR-CONTRADICTORY.** A mortgage REQUIRES registering an
encumbrance (*Bāzdāsht*) in the state cadastre, executed by a state-licensed notary on a state portal
using a state-issued hardware token. **The state therefore knows: this property, this owner, this
lien.** On-chain privacy is irrelevant to that fact. What we can hide is WHO FUNDED it and the
linkage between pool deposits and withdrawals. What we cannot hide, from the adversary in the threat
model, is that a specific person mortgaged a specific property. Presenting "private mortgages" to a
funder without this caveat would be misrepresentation.

**BREAK 4 - THE FX RISK HAS NOWHERE TO GO.** A dollar pool lending to a rial-earning borrower: if
the borrower owes dollars, devaluation makes servicing harder exactly when they can least afford it,
which is a default machine. If the loan is CPI-indexed rial, the POOL is short dollars and long an
inflating currency - an unhedged position QUI holders have no reason to accept. The spec's Model A
resolves this only because a SOVEREIGN can absorb FX risk as policy. A private pool cannot. **Neither
counterparty wants the risk and there is no third party to sell it to** - which is a large part of
why this market does not already exist.

**BREAK 5 - "TRUSTLESS" IS NOT CLOSE TO ACCURATE.** Trusted roles now: the state registers
(conceded), the notary, the appraiser, the legal nominee, the CRE scrapers and their version
publisher, and the guardian set. Six, several of which can act unilaterally against a user. The
honest word is "trust-MINIMISED in specific, stated places", and every claim should be scoped to the
layer it applies to.

**BREAK 6 - SANCTIONS EXPOSURE IS EXISTENTIAL, NOT TECHNICAL.** A protocol knowingly facilitating
credit into a sanctioned jurisdiction exposes its operators, its pool, and any nominee or originator
to real legal jeopardy. No amount of cryptography addresses this, and it can end the project
independent of whether the code is correct.

**WHAT SURVIVES, AND IT IS NOT NOTHING:**
- **Private identity.** Prove you hold a genuine passport without revealing who you are. No economic
  assumptions, no third party, works today.
- **Private title.** Prove you own a property without revealing which, with double-titling prevented.
  Depends on Tier 2 verification, which is public and permissionless.
- **Private transfer.** The shielded pool, unlinkable deposits and withdrawals, with an unconditional
  exit.

None of these require an appraiser, a nominee, FX risk, or a lien in the state register. **They are
the product.** Lending is a hypothesis stacked on six unresolved dependencies, and should be
presented as such or not at all.

**ACTION: FUNDING-APPLICATION.md OVERSTATES LENDING.** It leads with mortgage underwriting in §1 and
gives lending a full milestone. The honest version leads with identity and title, and treats lending
as explicitly conditional. Correcting it.

### 2.21 I OVER-CORRECTED. Two of §2.20's breaks do not hold (user, 2026-07-29)

*"what do you mean by conditional, not promised?"* - fair, because "conditional" was hedging rather
than analysis. Re-examining §2.20's six breaks, two of them are wrong.

**BREAK 3 WAS A CATEGORY ERROR.** I called the state-visible encumbrance a privacy failure. **A lien
is SUPPOSED to be public.** Public notice is what makes it enforceable against third parties - a
secret lien binds nobody and is worthless as security. Hiding it would destroy its legal function,
not protect anyone.

So the privacy claim for lending was never "nobody knows there is a mortgage". It is:
- the FUNDERS are private (QUI holders are not disclosed),
- the borrower's OTHER financial activity is private (the pool),
- the property-to-titleId mapping is private from the public (`propertyKey`),
- and the lien is public in the cadastre, AS LIENS MUST BE.

That is coherent and narrower than "private mortgages" implies - which is a labelling problem, not a
design one.

**BREAK 2 IS SOLVABLE AND WE ALREADY HAVE THE SOLUTION.** "A pool cannot hold a lien, so a legal
entity must" - yes, and **that entity is a special-purpose vehicle**. It is what the sibling
repository is named after. A nominee holding security on behalf of note-holders is standard finance,
not an unsolved problem. It remains a real single point of failure and should be stated as one, but
"unsolved" was wrong.

**BREAK 1 STANDS AND IS THE REAL CONSTRAINT.** Valuation still needs an independent, competent,
accountable party, and the borrower cannot be it. Tractable via attested appraisers (same CRE pattern
as notaries) or public auction comparables - real work, not a blocker.

**BREAKS 4, 5, 6 STAND.** FX risk has no natural holder; "trustless" is inaccurate; sanctions
exposure is existential and non-technical.

**THE HONEST POSITION IS BETWEEN MY TWO ANSWERS.** Lending is harder than §2.17 said and less
impossible than §2.20 said. Oscillating between them was worse than either. Concretely: valuation and
nominee are ENGINEERING AND LEGAL WORK; FX and sanctions are BUSINESS RISKS that no design resolves.

### 2.21a "OTHERWISE WE JUST ENABLE SPECIALISED VOTING?" - no, and the real answer is stronger

If title never carries a loan, what is it for? Not merely property-weighted voting.

**IT IS AN INDEPENDENT EVIDENTIARY RECORD OF OWNERSHIP THAT THE STATE CANNOT RETROACTIVELY ALTER.**
Our record derives FROM the cadastre - notary attestation plus Tier 2 verification - so it is a
notarised snapshot of what the official register said at a moment in time, held somewhere the issuer
cannot revise. Where property confiscation and register manipulation against disfavoured groups are
real, that is not a lesser use case than lending; it may be the more important one, and it needs no
valuation, no nominee, no FX and no counterparty.

Property-weighted voting is then a downstream application of the same proof, not the point of it.

### 2.22 WHY THE TIERS ARE SHAPED THAT WAY - and the break it exposes in OUR design

**The tiers are not our architecture.** They are Iran's cadastre's access model, and it is a
deliberate anti-enumeration design, not an accident:
- **The owner** sees everything under their national ID. Only they can DISCOVER an undisclosed
  charge. Nobody else gets a list.
- **The public** can CONFIRM one named deed but cannot browse, because the query demands the
  18-digit *Shenaseh Yekta* AND the owner's national ID together. You must already know both to ask.
- **Notaries** transact, because they are public officials carrying legal authority.
- **The judiciary** seizes.

Each tier exists to stop a different capability leaking into a lower one. It is coherent, and it is
also the source of the problem below.

**THE BREAK: TIER 2 VERIFICATION IS NOT ANONYMOUS, AND I BUILT AS THOUGH IT WERE.**
The authenticity check requires the OWNER'S NATIONAL ID as an input. So whoever performs it LEARNS
WHO OWNS THE PROPERTY. Every design above that says "anyone can verify the deed, so nobody must
trust the notary" quietly assumed verification was identity-free. It is not.

**AND THAT INVERTS §2.15a's CRE-OVER-TLSNOTARY CONCLUSION.** With CRE, the DON NODES make the HTTP
request - so for a PER-USER query every node sees that user's national ID and deed number. That is
fine for the notary REGISTER, which is a public bulk export containing no per-user data, and it is
disqualifying for Tier 2, which is inherently per-user.

TLSNotary does exactly what is needed here and CRE cannot: the USER makes the query themselves and
proves the result, without the inputs ever reaching a third party. The spec specified it for a
reason I dismissed. **Correct split: CRE for the bulk notary register; TLSNotary (or an equivalent
client-side proof) for per-user deed verification.** Using one mechanism for both was the error.

### 2.22a WHAT ACTUALLY SURVIVES - settled, not oscillating

I have swung between "lending works" (§2.17) and "nothing works" (§2.20). Neither was right. Layer by
layer, with the unresolved items named:

**IDENTITY - SURVIVES INTACT.** Passport to zero-knowledge proof, no server, field-proven in Iran by
the Freedom Tool. Registration cannot be refused, exclusion fails open and cannot be retroactive.
One known defect, fully designed and measured: registration publicly links an identity to its pool
account (§2.18, 28,302 opcodes to fix).

**MONEY - SURVIVES INTACT.** Shielded deposits and withdrawals; yield on shielded balances, which
Privacy Pools never had; non-custodial BTC where the depositor holds one of two keys and can close
unilaterally. No external dependency, no counterparty, no jurisdiction.

**TITLE - TWO UNRESOLVED ITEMS, both structural rather than fatal.**
1. Nobody is assigned to compute `propertyKey` (§2.16b), so a property owner cannot check whether
   their own land has been titled here.
2. Tier 2 verification discloses the owner's national ID to whoever performs it - above.
Both are solvable; neither is solved.

**LENDING - THREE, of which two are not technical.** Independent valuation (solvable, unsolved).
FX risk with no natural holder (not solvable by design - a sovereign can absorb it, a private pool
cannot). Sanctions exposure (existential, legal, unaffected by any amount of cryptography).

**The honest sentence:** identity and money are finished work that needs auditing. Title is nearly
finished with two named gaps. Lending is a hypothesis whose blockers are mostly not ours to solve.
That ordering has been stable across every teardown; my error was restating it each time as though
it were new.

### 2.22b THE TIER 2 DISCLOSURE IS NOT A DISCLOSURE - I alarmed myself over nothing

§2.22 said the deed check "discloses the owner's national ID to whoever performs it". True, and I
failed to ask WHO PERFORMS IT.

**If the OWNER runs the query, it discloses nothing.** They are supplying their own national ID and
their own deed number, to a government that already holds both. No third party is involved and no
new fact reaches anyone. The disclosure I panicked about only exists if a LENDER or an ORACLE runs
the query — which is exactly why the check must be client-side, and why CRE is the wrong tool for it.

So the corrected architecture stands, but for a better reason than I gave: not "CRE would leak" as a
regrettable constraint, but **the owner is the only party who can run this query without creating a
disclosure that did not previously exist.**

**What actually remains, and it is smaller:** the state can observe that a person queried their own
record at a particular time, and could correlate that with an on-chain registration appearing
shortly after. That is NETWORK-LEVEL correlation, not data disclosure - the state learns nothing
about the deed it did not already know, only that the owner looked at it. Mitigable by routing the
query over Tor or a VPN and by not tying registration timing to the query.

**On-chain the proof reveals only that a genuine deed exists**, bound to an opaque property
identifier and an opaque owner commitment. No identity, no parcel, nothing searchable.

### 2.22c WHY THE DISTRIBUTOR MODEL - the real reason (user, 2026-07-29)

I have twice answered with what distribution ACHIEVES - a lower rate - and never with why it was
chosen. The reason is not economic.

**ORIGINATION REQUIRES DISCRETION, AND DISCRETION IS WHERE DENIAL OF SERVICE LIVES.** To originate is
to judge a person: their creditworthiness, their character, their risk. Any entity making that
judgment CAN refuse, and in practice refuses along the lines everyone knows - faith, politics, sex,
name, ethnicity. There is no way to hold that power and promise never to use it; the promise is worth
exactly as much as the promiser's freedom from pressure. **The only durable guarantee is not to hold
the power at all.**

Distribution means the protocol never decides who gets a loan. It supplies capital against collateral
whose validity is checked mechanically - the title is genuine, the parcel is not already mortgaged,
the ratio is within limits - and those checks cannot be pointed at a person.

**Two more, both about levers:**
- **Licensing.** Originating requires a licence in each jurisdiction, so the system would run on
  regulatory permission, which can be withdrawn. Distribution does not.
- **Data.** An originator holds the customer relationship and therefore the customer's file. We do
  not want it. Not holding data is a stronger privacy guarantee than any promise about handling it,
  and it cannot be compelled out of us.

That is the answer: **we distribute because originating means holding three levers - judgment,
licence and data - each of which someone can pull against a user.**

### 2.22d The word counts are now CHECKED, not asserted

The user asked why the per-section counts weren't written down. They had been, and I removed them
without being asked - which was the smaller error. The larger one is that a hand-written count is
wrong the moment anyone edits the section, and a heading reading "297 used" over a 340-word section
is worse than no number, because it stops the next person from looking.

`tools/check-application-wordcount.js` recomputes every section and fails on EITHER a section over
its limit OR a heading whose stated count disagrees with the body. `--write` refreshes the stated
counts, and still exits 1 if a section is over - the number becomes honest, the section is still too
long.

**Verified by breaking it, not by watching it pass** (per the standing rule about guards that assert
nothing): misstating a count -> exit 1; padding a section past its limit -> exit 1 both with and
without `--write`; restored document -> exit 0.

Counting rule: emphasis markers, backticks, bullets, blockquote markers and the em-dash are stripped
before splitting, since we use `—` unspaced and it would otherwise count as a word. Headings are not
counted - the limit applies to the body a reader reads.

Final state, all eight within limit: 297/300, 998/1000, 299/300, 298/300, 298/300, 299/300, 283/300,
294/300.

**One duplicate removed while measuring.** Section 8 made the government-portal-format point twice,
almost verbatim ("A narrow surface to maintain", then again in "What happens if we stop"). Merged,
and the reclaimed words went to the thing that paragraph never said: what the failure mode actually
IS if nobody maintains the reader. **It is staleness, not loss** - a stale reader blocks NEW titles
while every existing balance and title stays reachable.

### 2.22e "DO WE ACTUALLY REMOVE THE BANK'S MARGIN?" - NO, AND THE DOC SAID WE DID

*"do we actually remove the banks margin as the doc says?"* (user, 2026-07-29). We do not. Two
sentences claimed it and both were wrong.

**DECOMPOSE A BANK'S MORTGAGE RATE.** Cost of funds + operating cost + credit-loss provision +
regulatory capital charge + profit. Against that:

- **Cost of funds - WE ARE WORSE, NOT BETTER.** A bank funds itself on INSURED DEPOSITS, the
  cheapest money in any economy. Our capital costs whatever its holders forgo elsewhere - the
  reserve's own yield is the floor. This is the largest term in the rate and we lose on it.
- **Operating cost - GENUINELY REMOVED.** Branches, staff, manual underwriting. Real, and ours.
- **Credit losses - NOT REMOVED, REDISTRIBUTED.** Still priced; borne by underwriters instead of
  the bank. The borrower's 30% equity at 70% LTV is the first-loss layer (see 2.19).
- **Capital charge - REDUCED** (no charter) but **REPLACED** by over-collateralisation, which is a
  real cost to the borrower, just not a line item.
- **Profit - REDIRECTED, NOT ELIMINATED.** QUI holders are the shareholders now. What CAN go is the
  MONOPOLY component: competition among capital rather than among a licensed few.

**AND THE PART THAT ACTUALLY DOMINATES: IRAN'S 30% IS MOSTLY CURRENCY, NOT MARGIN.** Against
inflation near 40% a 30% nominal IRR mortgage is a NEGATIVE REAL RATE - the borrower is already
being subsidised by the currency. No amount of disintermediation touches that. Quoting a
hard-currency rate against it is a category error: it is cheaper in name only, and a borrower who
earns rial and owes dollars has swapped an interest cost for FX risk that can be far larger. **That
is a worse deal dressed as a better one, and the honest framing is that we lend in the currency the
borrower earns or we are moving risk rather than cutting cost.**

Both sentences corrected in FUNDING-APPLICATION.md (sec. 1 and sec. 2). Section 2 re-fitted to
exactly 1000/1000.

**THE STANDING FX RISK IS UNCHANGED AND STILL UNRESOLVED** - it was already flagged as
non-technical. What changed is that the document no longer implies we have solved it.

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
