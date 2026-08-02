# ibiza

A fork of **Privacy Pools** and **rarimo/rarime**, merged onto one Foundry + Noir/Honk stack.

`TODO.md` is the canonical tracker and holds current state, traps and open decisions. This file
answers the questions the tracker cannot: **where the code came from, why the fork was made the way
it was, and what we changed.**

---

## Why the two were merged at all

rarime proves **who you are** from a biometric passport. Privacy Pools proves **membership in an
association set** — that your deposit is one of a chosen subset — **without revealing which one is
yours**.

**Privacy Pools does NOT prove where money came from, and saying so inverts the design.** Nothing
about origin is proven or disclosed on-chain. A screening provider curates a set OFF-CHAIN, using
whatever analysis it likes, and the circuit proves only that your deposit lies inside it. The
property is **provable dissociation** — "I am one of these depositors, none of whom are the ones you
excluded" — which is weaker than provenance and deliberately so: it is what lets an honest user
distance themselves from tainted deposits without ever identifying their own.

Neither is sufficient alone for the thing this repo exists to build: a person who can prove
eligibility and hold value without those two facts being linkable.

Merging them creates one property neither had: **the identity that gates a withdrawal and the note
being withdrawn are bound in a single proof**, so an operator sees a valid withdrawal without
learning whose it is. Everything below follows from paying for that.

## Why ONE toolchain

The fork inherited **two proving stacks**: rarime's passport circuits in **Circom/Groth16**, Privacy
Pools' in **Circom** too but a different pipeline, with separate verifiers, separate trusted setups
and separate tooling. That is not a tidiness problem:

- **Two verifiers on the same withdrawal cannot share a proof.** A withdrawal that must check both
  identity and note membership pays for two verifications and two calldata payloads.
- **Groth16 needs a per-circuit trusted setup.** Every passport profile (35 of them) is a separate
  ceremony. Honk needs none.
- **A shared hash is required for the fusion to work at all.** The identity tree and the pool's
  commitment tree must agree on Poseidon, or a single proof cannot span both.

So everything was ported to **Noir + UltraHonk**: one prover, one verifier shape, no per-circuit
ceremony, and one Poseidon shared across circuits, Solidity (`poseidon-solidity`) and the wallet
(`@iden3/js-crypto`) — each cross-checked against the others rather than assumed compatible.

The cost is that we now depend on the Noir toolchain's maturity, which is where several of the
sharpest problems in `TODO.md` come from (a compiler ICE we patched, a bignum ecosystem that trails
the compiler, proof formats that shift between `bb` versions).

## Why aggregation was the first big piece

Gas, measured rather than assumed: **a single withdrawal cost ~3.07M gas**, dominated by the
in-circuit Honk verification. That is not a product — it is a demo.

**Aggregation is the only structural answer.** One recursive proof attests to N withdrawals, so the
verification cost is paid once per batch instead of once per withdrawal:

| | gas / withdrawal |
|---|---|
| single withdrawal | ~3.07M |
| **batched, N=16** | **~68k** |
| batched, N=64 | ~41k |

That is a ~45× improvement at N=16, and it is why `aggregate_withdrawals`, `BatchVerifierLib` and
`PrivacyPool.withdrawBatch` exist. It also forced the toolchain question: recursive ZK proofs need a
Noir/bb combination that produces them correctly, which is what drove the beta.26 + bb 5.1.0 pin.

Other measured gas work along the way:
- **keccak batch commitment instead of Poseidon** — the N=16 aggregation circuit fell from
  **11,610,552 to 550,404 gates**, and the N=2 case from 1,396,874 to 81,668. The Poseidon variant's
  in-circuit verifications were **vacuous** — present in the gate count, absent in effect.
- withdrawal verifier size brought under the **EIP-170** 24,576-byte limit (24,534 → 23,527) with
  `optimizer_runs = 1` scoped to the verifiers.
- **root memo** in `withdrawBatch`: distinct state/identity roots are checked once per batch rather
  than once per withdrawal, which is exactly equivalent because a root's validity is a pure function
  of pool state.

## How we changed Privacy Pools' screening architecture, and why

**Upstream shape.** In Privacy Pools an ASP publishes an association-set root; a withdrawal proves
its label is in that set. One authority, one root, one predicate — and the ASP can publish a new
root omitting your commitment at any time after you deposited. Your private exit disappears an hour
later without anyone taking your money. **That retroactive lever is the property we changed.**

**What we changed it to.** Screening became a **closed set of independent predicates**, each with
its own anchored source, rather than a single curated root:

- **identity** — holder-rooted registration, proven once at escrow (`escrow_envelope`), with
  revocation as a status in the same tree rather than a separate authority
- **sanctions** — `backend/cre/ofac_sdn` anchors the OFAC SDN list via
  `RegistrySourceAnchor.publishSnapshot`
- **notary** — `backend/cre/notary_registry` anchors a notary registry the same way
- **the original ASP chain-analysis set** — preserved as an OPTIONAL predicate a deployment may
  enable, not deleted

**Why that shape.** Two reasons, both structural rather than cosmetic:

1. **Anchored external authority instead of an operator's opinion.** Each source is scraped by a
   Chainlink CRE workflow where every DON node fetches the same export independently and must
   produce a byte-identical result before a report is generated. A single relayer could substitute a
   tampered snapshot; this cannot. That property is the entire justification for admitting a
   predicate into a set that is otherwise deliberately tiny.
2. **A closed set is auditable; discretion is not.** Anyone can enumerate what may be checked. The
   upstream design lets an ASP decide, per-root, in a way nobody can enumerate after the fact.

**What this does NOT yet achieve, stated plainly because the claim is easy to overstate:** the
retroactive lever is **reduced, not removed**. Turning the equality check into an append-only
`mapping(root => publishedAt)` would remove it — at the cost of making a genuinely tainted root
permanently unremovable — and that is a governance decision, not an engineering one. `IdentityRegistry`
is also UUPS-upgradeable, so the upgrade key can un-register people independently of any of this.
**Both are open decisions recorded in `TODO.md`; until one is taken, "this fork has no retroactive
third-party lever" is false.**

## Why "one key, many documents"

A person with two passports is the user this design exists for — and the naive shape leaks them.
If each document produced its own identity, holding two would be visible, and **multi-citizenship
makes the leak worse rather than better**.

So identity is **holder-rooted**: one key owns many documents, the holder root is what the pool sees,
and which document was used is not disclosed. That is what `HolderStateKeeper`, `HolderRegistration`
and the escrow envelope exist for, and why `register_identity` has TD1/TD3/light variants — the same
holder, different document formats.

## What we fixed in the rarime SDK and wallet

- **`@rarimo/rarime-rn-sdk`** provides Noir proving on-device via prebuilt AARs. We forked it to
  `quidmints/rarime-rn-sdk`; **PR #1 (merged 2026-07-27)** migrated it to the expo-file-system 57
  File/Directory API, which the package declared as a dependency while still calling the string-path
  API that version removed — consumers hit "undefined is not a function". It also fixed a path bug
  in `TrustedSetupFileName` and made the noir directory exist before bytecode is written.
- **Six `pp/` wallet modules could not be loaded by `node --test` at all** — type-only imports used
  as values, extensionless relative imports, and a TypeScript `enum` (which Node's strip-only mode
  refuses). That is why that directory had zero tests; all fixed, and it now has ~132.
- **Root-seed handling**: `revealRootMnemonic` / `exportEncryptedBackup` bypass the session cache and
  force re-authentication, because those two operations hand over the key rather than use it.
- **Fresh withdrawal recipients** derived from the same seed (`pp/recipient.ts`), so a payout address
  is never one the user funded — and never a key they must back up separately.

## Provenance map

| path | origin |
|---|---|
| `backend/contracts/contracts/pool/**` | **Privacy Pools** (`0xbow-io/privacy-pools-core`) |
| `backend/contracts/contracts/{certificate,passport,registration,state,sdk,utils}/**` | **rarimo** (`rarimo/passport-contracts`) |
| `backend/circuits/{pp,withdraw_identity,ragequit}` | Privacy Pools circuits, ported Circom → Noir |
| `backend/circuits/{register_identity*,query_identity*}` | **rarimo** (`rarimo/passport-zk-circuits-noir`) |
| `backend/circuits/noir_dl_lib` | **rarimo**, which itself vendors `noir-lang/noir-bignum` + `noir_bigcurve` |
| `frontend/identity-wallet` | **rarimo/rarime** wallet |
| `backend/circuits/{escrow_envelope,title_holder,notary_action,aggregate_withdrawals}` | **ours** |
| `backend/contracts/contracts/{title,holder,pool/spv}/**`, `registry/RegistrySourceAnchor.sol` | **ours** |
| `backend/cre/**`, `tools/**` | **ours** |

**The fork was imported as ONE squashed commit** (`0762975`), so there is no upstream history to diff
against here. Everything since is divergence:

```sh
git diff --name-only 0762975..HEAD -- backend/contracts/contracts \
  | grep -vE 'verifiers2|Verifier\.sol'
```

As of 2026-08-02: **51 non-generated contracts**, 58 files in `noir_dl_lib`, 3 rarimo circuit files,
62 in the wallet. **We are a heavily modified fork, not a thin skin. Do not assume any upstream file
is untouched.**

## Changes to upstream code whose consequences exceed their diff

### `noir_dl_lib` (rarimo → vendoring noir-bignum / noir_bigcurve)

Ported to nargo 1.0.0-beta.26; full detail in `backend/circuits/NOIR-DL-PORT.md`.

- **`u1` → `Field` at the BOUNDARY, not throughout.** `to_le_bits` now returns `[bool; N]`;
  substituting `bool` library-wide was tried and reverted, because the library does arithmetic on
  those bits and it meant editing modular-arithmetic and hash expressions. One conversion at each
  bit source keeps every algorithm body byte-identical.
- **`.eq()` disambiguated to `BigNumTrait::eq`.** `std::cmp::Eq` compares limbs; `BigNumTrait::eq`
  compares modular values. They differ for unreduced representations — the other choice would have
  compiled and been silently wrong.
- **22 `global … = BigNumParams::new(..)` became `pub fn`** — an ACCOMMODATION for a Noir compiler
  bug, **to revert when the fix ships upstream.** Zero measured gate cost.
- **`sigver/curve_384.nr` deleted** — a second, never-wired Brainpool P384R1 under a secp384r1 name.
- **Dependency pins bumped** (`sort`, `poseidon`, `sha256`); all were stale against beta.26.
- **⚠️ `ScalarField::from_bignum` carried the vendor's own `// TODO: NONE OF THIS IS CONSTRAINED
  YET. FIX!`** on the ECDSA scalar decomposition. See `TODO.md` — this is the most serious thing in
  the repo's history and was found by reading the file, not by any tracker.

### `noir-lang/noir` itself

A 3-hunk ICE fix (`backend/circuits/noir-ice-repro/noir-fix.patch`) with a 14-line reproduction.
Not vendored; the built compiler is local. See **Toolchain** below.

### Privacy Pools Solidity

Additive, but they change the contract surface:
- `withdrawBatch` + `MAX_BATCH` + batch errors, with `BatchVerifierLib` / `BatchCommitmentLib`
- `AGGREGATION_VERIFIER` as an immutable constructor argument — it was previously **declared, read,
  and never assigned**, so batching was unreachable
- `DeployLib` gained actual deployment functions; it previously held salts and nothing else, so no
  pool was ever constructed outside a test

---

## Toolchain (read before generating any artifact)

**`nargo` is a LOCALLY PATCHED beta.26** reporting `1.0.0-beta.26+quid-icefix1`. The suffix is
load-bearing: an unmarked patched build is indistinguishable from the release and would slip past
`codegen-verifiers.sh`'s guard. **CI and other developers will fail that guard, correctly** — the
circuits still build on stock beta.26, which is why the accommodation above was kept.

- stock binary: `~/.nargo/bin/nargo.beta26-release.bak`, or `noirup --version 1.0.0-beta.26`
- **`bb` 5.1.0 must be on PATH**: `export PATH="$HOME/.bb:$PATH"`
- artifact generation is a **5-step pipeline**; `codegen-verifiers.sh` is step 4 and
  `tools/prove-escrow-fixtures.sh` is step 5. Skipping step 5 produces `SumcheckFailed()` far from
  the cause.
- **regenerate only what changed** — re-proving unchanged circuits is churn, and `title_holder`
  currently fails when re-proved (TODO.md).
- **not covered by the script:** `aggregate_withdrawals` and the 76 `NoirRegisterIdentity_*.sol`.
