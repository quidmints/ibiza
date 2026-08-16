# TODO — open items only

Everything here is UNDONE. Completed work, superseded designs and the evidence behind both live in
`TODO-ARCHIVE.md`, which is unchanged and is still the authority for *why* a thing is the way it is.
Each section below cites its archive line so the reasoning is one jump away.

⚠️ **Sections are kept only where an item is still open.** A section's absence here means it is done
or superseded, NOT that it never existed - check the archive before concluding anything is missing.

---

## Live now — opened or reopened 2026-08-13..15, not yet in the numbered scheme

### ⚖️ TRIAGE — order this work by whether a wrong outcome is PROVABLY WRONG AFTERWARDS

Derived from the UMA/Polymarket failure (see the sortition item). Attacker payoff scales with what is
being decided; defender payoff is fixed. No quorum size fixes that. **What separates a safe mechanism
from an unsafe one is not the incentive, it is whether a bad outcome can be CONTRADICTED BY EVIDENCE
after the fact.** Ranked by size of the un-contradictable surface:

| # | predicate | ground truth | external claim surface |
|---|---|---|---|
| 1 | **non-association** (`label ∉ tainted`) | **the chain itself** - propagation is deterministic and anyone can recompute it | **only the SEED set**, and it is small |
| 2 | **sanctions non-membership** | the published register - anyone can rebuild the leaves | the whole register, but public |
| 3 | **Court on transcription fidelity** | same as (2): does this leaf match the source | none of its own |
| 4 | **governance votes** (removal, citizenship) | **NONE - it is a judgment** | unbounded |

⇒ **Build in that order.** (1) has the smallest un-contradictable core of anything here and needs NO
CRE at all beyond anchoring a small seed - which makes it a better first target than the sanctions
work I had queued ahead of it.
⇒ **(4) is blocked on economics that may have no solution**, not on engineering. Do not extend Court
to carry a governance ruling until "what does a wrong ruling cost, and who bears it" has an answer.
That is the Polymarket shape: high value, no anchor, apathetic panel.


- [ ] **Port SORTITION to a per-jurisdiction citizen pool.** ⚠️ We are NOT importing the `quid` folder,
      and UMA is not used at all - an earlier version of this item said to pin the workflow ID in
      `UMA.onReport`, which was wrong twice over. The only thing that transfers is the mechanism:
        * **entropy** - `RandaoLib.getHistoricalRandaoValue(n, headerRlp)`: caller supplies an RLP
          header, contract pins it to `blockhash(n)` and reads `prevRandao`, mixed over >=3 blocks.
          Caller-supplied but NOT caller-chosen, and no single proposer can steer it. Transfers
          unchanged - it depends only on `blockhash`, not on anything in `quid`.
        * **selection** - ⛔ **DOES NOT TRANSFER.** `idx = seed % poolSize` both NEEDS the set size to
          compute and PUBLISHES the chosen indices. The requirement is anonymous selection that
          reveals neither the members nor the SET SIZE - only that someone in the set was chosen.
          Replace drawing with SELF-SELECTION: each epoch's RANDAO is a public seed, a citizen
          computes `PRF(sk, seed)` locally and is selected iff it falls under a threshold, then
          proves in ONE circuit (a) membership in the jurisdiction's citizen SMT, (b) correct PRF
          evaluation on that seed, (c) output under threshold. Nobody draws anyone; they discover it.
          Reuses `smt_verifier_full` - a THIRD instance of the same primitive, beside sanctions
          non-membership and non-association - and a Poseidon PRF the circuits already do.
        * **opt-in** - in `quid` this is STAKE (`juryPoolSize`, `lockedStake`, slashing). For a
          citizen set it is an opted-in subset of `CitizenRegistry` per jurisdiction.
      ⚠️ **THE INCENTIVE DOES NOT TRANSFER, and that is the real design question.** Sortition without
      stake has no slashing lever, so nothing makes a drawn citizen vote honestly rather than not at
      all. Solve that before porting, not after.
      🔴 **THE ATTACK ECONOMICS ARE THE SECURITY PARAMETER, and they are the target to beat.** The
      Polymarket attackers held YES on a US/Ukraine mineral deal - 97% in February, under 10% by
      April, about to expire worthless. Corrupting the resolution was worth their ENTIRE POSITION,
      while each honest voter stood to gain a share of routine rewards. **Attacker payoff scales with
      the stake in the decision; defender payoff is fixed.** No quorum size fixes an unbounded
      numerator. A sanctions ruling has an unbounded numerator too - removing an address unfreezes
      arbitrary value, adding one censors arbitrary value - so a fixed-compensation panel is
      corruptible for a valuable enough address, and an unpaid citizen panel for less.
      ✅ **WHAT SAVES THE SANCTIONS CASE IS DETECTABILITY, NOT INCENTIVES.** Transcription fidelity has
      a public ground truth: rule that an entry is absent when it is present, and anyone rebuilding
      the leaves sees it. The ruling still executes, but it is CONTRADICTABLE, which leaves room for a
      second-order remedy. Polymarket had no anchor, which is why "a deal was AND was not agreed on
      27 February" stands as a permanent contradiction nobody can adjudicate after the fact.
      ⇒ **Court is usable where a wrong ruling is PROVABLY wrong afterwards, and dangerous where it is
      not.** Sanctions transcription: safe side. Removal of a monarch: judgment, no anchor, high
      value, same apathy exposure - the Polymarket shape exactly.
      🔴 **DEMONSTRATED, NOT HYPOTHETICAL.** UMA's oracle was manipulated into resolving a Polymarket
      market against reality by attackers who timed the dispute for when attention was low - the
      failure was CHECKED-OUT VOTERS, not broken cryptography. Note the direction of the evidence:
      UMA HAD a token-weighted stake lever and it was still insufficient. A citizen panel with no
      lever at all is strictly weaker. Two further lessons: (1) UMA's "trusted" LABEL on the
      attackers did the work - **do not add a reputation layer to Court**, it reintroduces exactly
      that; (2) fixed appeal windows are schedulable, so an attacker picks the moment.
      ⚠️ **AND THE REMIT SPLIT MATTERS MORE THAN THE INCENTIVE.** Court on SANCTIONS adjudicates
      transcription fidelity - is this entry in the published register - which has a GROUND TRUTH
      anyone can rebuild, so an absent or bribed panel can be contradicted by evidence. Removal of a
      monarch, or a citizenship grant, has NO anchor: it is a judgment, like "was a deal agreed",
      which is the exact question class that failed. **The engine is sound for the use it was
      designed for and structurally exposed for the governance use** - and no cryptography closes
      that gap. Decide what a wrong governance ruling costs, and who bears it, before extending Court
      to carry one.
      ⚠️ **THE SET SIZE LEAKS THROUGH TURNOUT, and no construction avoids it for free.** With a public
      fixed threshold, expected committee size = |set| x P, so counting who shows up ESTIMATES the
      population. Pick two of three: fixed threshold / fixed committee size / hidden population.
        * fixed threshold -> committee varies with population -> leaks
        * fixed committee -> threshold calibrated to population -> leaks
        * hidden or committed threshold, or padding with decoy submissions -> hides size, but the
          committee size stops being knowable, which breaks any quorum rule that depends on it
      The leak is bounded - an adversary learns roughly HOW MANY opted in, never WHO - so whether it
      is acceptable is policy, not cryptography, and may differ for a small jurisdiction.
      ✅ Composes with the secret ballot: being SELECTED can stay private too, and how one voted is
      separate again. Selection privacy and ballot privacy are independent properties.
- [x] ✅ **Non-association predicate — LANDED on the single-withdrawal path.** `label ∉ tainted`, proven
      in-circuit as an eighth public signal. The PP paper's EXCLUSION branch, where 0xbow deployed
      membership. Third use of `smt_verifier_full`: identity uses `fnc=false`, this uses `fnc=true`.
      * The taint root is SUBSTITUTED by `PrivacyPool`, never read from the proof - a prover-supplied
        root would let them prove exclusion from an empty tree of their own and make it vacuous.
      * `taintRoot = 0` means EMPTY, and empty admits everyone: the bootstrap and the fail-open
        failure mode in one. Proven feasible first by
        `smt::test_exclusion_against_an_empty_tree_is_the_zero_witness`, which is what made the
        committed fixtures updatable with zeros instead of needing a taint tree built first.
- [ ] 🔴 **The BATCH path does not carry it.** `aggregate_withdrawals` still folds SEVEN signals, so a
      batched withdrawal bypasses non-association. Closing the path was tried and REVERTED: it deleted
      the guard coverage (nullifier reuse, context binding, proof rejection) and traded a known gap for
      untested code. Regenerate the aggregation circuit with EIGHT signals and widen `PUB_LEN` in both
      batch libraries **before enabling batching on a pool with a non-empty taint root.**
- [ ] Anchor the taint root: seed set + deterministic propagation, and a setter path from the
      registry. `setTaintRoot` is entrypoint-gated and defaults to 0 (empty).
- [ ] **`court.sol` ← blacklist disputes.** Jurisdiction is TRANSCRIPTION FIDELITY, not designation
      validity. Blocked on the sanctions predicate existing (2.18gz-unify).
- [ ] 🏗️ **CONSOLIDATION (owner, 2026-08-16): `backend/` MERGES INTO THE SPV REPO, AND THE SPA's SWAP
      + LP FUNCTIONALITY MOVES INTO REACT NATIVE — the landing page does NOT come.** Measured before
      any file moved; both halves are smaller than they look, for different reasons.
      **(A) THE BACKEND MERGE HAS A RULE-2 ARGUMENT, WHICH IS STRONGER THAN THE TIDINESS ONE.**
      `backend/contracts` does NOT import the pinned SPV submodule at all — the coupling is
      `contracts/pool/spv/ISpvVenue.sol`, where ibiza HAND-DECLARES `ISpvVogue` and `ISpvBasket` as
      subsets of SPV's real contracts. That is the same interface declared twice in two repos, i.e.
      exactly what SPV standing rule 2 forbids inside one ("one declaration per interface, in a
      shared file"), and it is the mechanism behind SPV's *"depends on exactly four Vogue/Basket
      signatures staying permissionless and stable"*. ⇒ **Merging replaces a hand-copied interface
      with a real import, and the cross-repo drift risk deletes itself.** Scope: ~128 circuit +
      ~448 contract source files, plus 8 vendored `lib/` deps whose remappings must be reconciled
      with SPV's `evm/remappings.txt` (`@openzeppelin/`, `forge-std/` overlap; `@solarity/`,
      `@rarimo/`, `poseidon-solidity/`, `lean-imt/`, `solady/`, `evidence-registry/` are new).
      **(B) THE RN PORT IS MOSTLY A MOVE, NOT A REWRITE — because both apps already use `ethers` 6**
      (SPA `^6.16.0`, wallet `^6.17.0`; no wagmi, no viem, no rainbowkit). The SPA splits on a clean
      seam already: `(site)/` + `components/castle/*` is the LANDING PAGE (Hero, FeatureA-D,
      SalesLanding, LogosStrip) and is **explicitly excluded**; `(app)/app/page.tsx` +
      `components/app/*` + `lib/*` is the swap/LP app.
      📌 **MEASURED, and this is the number that matters: of the 15 files (1,765 lines) in
      `spa/src/lib/`, only TWO touch the browser at all** — `eth.ts` (75 lines) and `protect.ts`
      (63) — **and every hit is `window.ethereum`**, the injected-wallet connector. Five more files
      matched a first grep only on the `'use client'` pragma, which is an inert string off Next.
      ⇒ **The chain layer ports as-is; `window.ethereum` is replaced by the signer this wallet
      already has** (`ethers` + `expo-secure-store`), which is a substitution the LP-signer item
      below needs anyway. The genuine rewrite is the VIEW layer only: `components/app/*` from
      DOM+tailwind to RN primitives (tailwind → `nativewind` or plain styles — not yet chosen).
      ▶️ **THE ONE DECISION THAT ORDERS THIS, and it is not technical:** SPV's tree currently has a
      second thread committing into it hourly (`Aux.sol`, `Basket.sol`, `SwapLib.sol`, `vault.rs`
      all moved during one session on 2026-08-16). Dropping ~576 files in while that runs will
      collide. **Either land (A) in a quiet window with the other thread paused, or do (B) first** —
      (B) is purely additive, touches only `frontend/identity-wallet`, and is not blocked by (A).
      ⚠️ **Do NOT start (A) by moving files.** Reconcile the two `remappings.txt` first and prove
      `forge build` green on the union, or the merge lands as a repo that does not compile.
- [ ] 🔑 **THE LP-SIDE SIGNER — ibiza's half of the SPV fleet split (SPV §E166-3, §E175).** The fleet
      RELAYS consent and provably cannot manufacture it: `VaultRegistry.LpConsent { auth, exits }`
      goes DORMANT on absence, a conflicting re-bind is REFUSED not overwritten, and both halves need
      the LP funding key which §E175-a removed from the fleet. `quid-lp-daemon` landed on the SPV side
      (683 passed) and holds the LP funding half; **nothing produces the consent, and that is here.**
      Two pieces:
        * **`auth.lp_sig`** - an EVM signature over `openAuthDigest`. Small; the wallet already signs.
        * **`exits` ladder** - one pre-signed spend of the 2-of-2 PER RUNG, each requiring an
          INTERACTIVE MuSig2 session between the LP's vault node and the fleet's hop at open.
      ⚠️ **DO NOT HAND-ROLL MuSig2.** BIP-327 nonce handling is where reuse silently leaks the
      private key, and this signs spends of a live 2-of-2.
      ✅ **THE LIBRARY QUESTION IS SETTLED, AND THE ANSWER WAS IN A README WE ALREADY SHIP** (checked
      2026-08-16). `@noble/curves` 2.2.0 exports `schnorr`, `secp256k1_FROST`, `schnorr_FROST` and
      **no MuSig2** - read off `node_modules/@noble/curves/secp256k1.d.ts`, not assumed. Its own
      README says where it went: *"MuSig2 signature scheme and BIP324 ElligatorSwift mapping for
      secp256k1 are available in a separate package"* → **`@scure/btc-signer`**, same maintainer
      (paulmillr) as the `@noble/curves` + `@noble/hashes` this wallet already depends on.
      ⇒ **Use `@scure/btc-signer`; adding it is step one**, since `@scure/` is absent from the
      wallet's `node_modules` today. ⚠️ Confirm its MuSig2 export surface against the INSTALLED
      package before designing the session flow - this entry cites noble's README, which is evidence
      the package exists and is the sanctioned route, NOT evidence of its API shape.
      🔑 **The two pieces are independent and only ONE is Bitcoin.** `auth.lp_sig` is an EVM digest
      `ethers` can already sign and needs no new dependency; only the `exits` ladder needs BIP-327.
      Landing `lp_sig` first is real progress that is not blocked on the library question.
      ⚠️ **Nothing named `LpConsent`, `OpenAuth`, `lp_sig` or "pre-signed ladder" exists anywhere in
      ibiza** - re-verified 2026-08-16: every match in the repo is inside the vendored
      `backend/contracts/lib/SPV/` submodule, i.e. SPV's own code, not ours. Still greenfield, and
      the spec lives in SPV's QUEUE.md §E166-3 rather than in an ibiza section.
      ⚠️ It gates SPV Phases 2-3. **1(a), 1(b) AND 1(c) have all landed** (SPV `09fc4f8c`/`28a80ee3`,
      2026-08-16): the LP declares `Individual` so it boots on mainnet, a born seed is written out
      once as a mnemonic, `QUID_SEED` takes it back, and a `family` role gets a K-of-N Shamir split
      instead. ⇒ **Nothing on the SPV side is holding this item up any more; it is waiting on ibiza.**
- [ ] **Secret ballot for removal-by-electorate and citizenship renunciation** - rarime's vote extended;
      PP for mixing, SPV for yield. The 'final fold', gated on the 6909 basket and the links.
- [ ] **Modularise `iran-constitutional-monarchy` into a bilateral parliament.** Open first question:
      does the jury engine land inside `SupremeCourt`, or beside it as a `Court` it appoints into?
- [ ] **Simplify along the `quid` seam.** Measured: quid `Aux+Vogue+VogueCore` = 1,742 lines with **0**
      `isBTC`; SPV `Aux+Vogue+Core` = 4,164 with **358**. quid is a working reference for the §J.2
      consolidation - but it never faced BTC, so it proves the cost, not that one impl serves both.
- [x] ✅ **`Registration2` certificate paths** - `test/registration/CertificateLifecycle.t.sol`, 5 tests,
      real contracts. Pins that `revokeCertificate` is PERMISSIONLESS BY DESIGN: it forwards to
      `StateKeeper.removeCertificate`, which is `onlyRegistration` and requires an expiry in the past,
      so it needs no authority precisely BECAUSE its precondition is on-chain fact rather than
      judgment. ⚠️ That is the property most likely to be "fixed" by adding `onlyOwner`; the tests
      make that fail loudly. Also recorded: `onlyRegistration` is an ALLOWLIST - a Registration2 must
      be added via `updateRegistrationSet`; pointing it at the keeper is not enough, and only one of
      the two directions comes from the initializer.
- [ ] **brainpoolP224r1** (DE 63, AE 42 DSCs). Deliberately unbuilt: unreachable until a tuple exists.
- [ ] **File the upstream reports.** `backend/circuits/UPSTREAM-REPORTS.md`, corrected; needs `gh` creds.

⚠️ **Needs a phone and a passport, and cannot be closed without one:** a committed witness for
`register_identity_td1`; end-to-end `registerViaNoir` / `registerDocumentViaIcao`; profile tuples for the
~3.5% PKD gap (IN 312, CH 240, SC 44, AT 62).

---

### 2.18ck THE WORKFLOW PIN WAS NEVER ENFORCED - `onReport` threw away the field that names it (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 7879</sub>

⛔ **PREMISE IS STALE (audited 2026-08-15).** The pin IS enforced: `RegistrySourceAnchor.onReport`
reads the workflow ID out of the metadata and reverts `UnpinnedWorkflow`. The remaining item below is
stale too - `REGISTRY_POSTMAN` was REPLACED by the forwarder+pin, not granted to it (`:167`).
⇒ Close unless someone identifies a path the pin does not cover. **The same hole is still OPEN in
`quid`'s `UMA.onReport` - see Live now.**

- [ ] Grant REGISTRY_POSTMAN to the Forwarder address alone once its calling convention is confirmed;

### 2.18cl "WE DONT NEED A POSTMAN AT ALL THOUGH?" - the chain cannot see a TLS session (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 7939</sub>

⛔ **PARTLY STALE (audited 2026-08-15).** `REGISTRY_POSTMAN` survives only in COMMENTS in
`RegistrySourceAnchor`; the grantable role was replaced by the forwarder + workflow pin. Items 1-2
below are therefore moot. Item 4 (`publishSnapshot` carries no workflow ID) was NOT re-audited and
may still be live.

- [ ] **Grant REGISTRY_POSTMAN to the Forwarder address and to nothing else** - this is the actual
- [ ] **Remove the role from the ICAO path entirely** - source-signed, so it needs no authority.
- [ ] Decide whether to verify DON signatures in-contract (permissionless for unsigned sources) or
- [ ] `publishSnapshot` is the bigger hole and outlives all of this: it carries no workflow ID and no

### 2.18cx THE PERMISSIONLESS ENROLMENT PATH IS ALREADY WIRED - what remains is a product decision (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 7982</sub>

⛔ **BLOCKER CLEARED (audited 2026-08-15).** "Close the six-profile gap first" is done: **88 live
profiles, 1 quarantined** (2.18gz). The enrolment path is also multi-profile now and `notAfter` is
derived from the document. What remains is the product decision in items 2-3, not the gap.

- [ ] Close the six-profile gap first (2.18co), or deleting the signer paths strands those holders.
- [ ] Then retire `registerDocumentViaNoir`/`renewDocumentViaNoir` and update the wallet SDK in the
- [ ] The revoke path is separate: it is the holder revoking their OWN document, so a signer there is

### 2.18df THE SIZE-CLASS QUESTION IS ANSWERED - and the answer is FIVE, measured (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 8009</sub>

- [ ] Prototype ONE 2^18-class circuit with padded arrays + true lengths as witnesses, and check it
- [ ] Do NOT pursue a single universal circuit (128x). Size classes only.

### 2.18ez FOUR CORRECTIONS, AND THE SCARCITY ARGUMENT HAS AN ALLOWLIST UNDER IT (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8051</sub>

- [ ] **Restore the taint predicate as REQUIRED, inverted**: `label ∉ tainted`. Not optional, not an
- [ ] **Fix or justify the signer gate on `registerDocumentViaNoir`.** As written, personhood is
- [ ] Automate taint propagation from public chain data, with the SEED set anchored separately from

### 2.18ey WHY THE CERTIFICATE CODE EXISTS - and what today's measurements did to that reason (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8123</sub>

- [ ] **This is a scope decision for the repo owner, not a defect to fix quietly.** Either restore
- [ ] If personhood-only is the answer, the certificate code stays - `HolderRegistration`, the title

### 2.18ex ANY CSCA MAY SIGN ANY CERTIFICATE, AND NOTHING RECORDS WHICH ONE DID (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8174</sub>

- [ ] **Record the signing CSCA on each certificate.** Small, and it is what makes issuer-scoped
- [ ] Then an issuer-scoped removal: drop every certificate whose `signerKey` is in an anchored
- [ ] Consider whether the certificate's own issuer field should be checked against the signer.

### 2.18ew PP'S ASSOCIATION SET WAS DELETED, NOT DEFERRED - and 2.13b said keep it (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8226</sub>

- [ ] **Fix the false header on `PrivacyPool`** before anything else here - it describes a guarantee
- [ ] **Decide whether to restore predicate 3.** It is the whole regulatory argument of Privacy
- [ ] If restored, it is a SEPARATE predicate, per 2.13b - a deployment may enable it, with the

### 2.18ev A REVOKED-BUT-UNEXPIRED CERTIFICATE CANNOT BE REMOVED AT ALL - and the fix needs no circuit (2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8277</sub>

- [ ] **Extend the ICAO workflow to emit the revoked-key tree.** `CRLs` is already a parsed field of
- [ ] **⚠️ AND THE ICAO WORKFLOW HAS NO ON-CHAIN WRITE PATH AT ALL.** `backend/cre/icao_master_list`
- [ ] **Do not gate it on the workflow.** The contract half closes the hole for any anchored revoked

### 2.18eu NO THRESHOLDS: reduce the CLAIM to what has a canonical key, and every one of those is trustless (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8336</sub>

- [ ] **Build CRL revocation** - and 2.18ev refines the shape: NOT keyed on issuer+serial, because
- [ ] **State the scope reduction explicitly**: the protocol does not screen persons against
- [ ] Re-check `IdentityRegistry`'s remaining predicates against the table above. If every one has a

### 2.18et "IS THERE A WAY WITH NO SACRIFICE" - no, and the binding constraint is the DATA (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8401</sub>

- [ ] **Say this in the docs.** The sanctions predicate has an authority; the reason is that the
- [ ] Revisit ONLY if a source begins publishing a canonical subject identifier, or if registration

### 2.18es FEWER MOVING PARTS: split the controller KEY, not the trust model (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8454</sub>

- [ ] Decide `n` and who holds the shares. **The only real question here**, and it is governance, not
- [ ] Additive `n`-of-`n` first, since it needs no dealer. Move to `t`-of-`n` only if a lost share
- [ ] Require `revoke` to cite `(registryId, snapshotIndex)` as EVIDENCE, explicitly not as a check.
- [ ] Say plainly in the docs that the sanctions predicate has an authority. Three measurements say

### 2.18er THE OPRF IS NOT THE BLOCKING DEPENDENCY, AND IT CONTRADICTS 2.18cu'S CENTRAL CLAIM (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8510</sub>

- [ ] **Correct 2.18cu's central claim.** "Nobody whose action is required" is false for any design
- [ ] **The real open question: is there a canonical subject identifier at all?** Names are not,
- [ ] Only after that: OPRF for grindability, if there is an identifier to blind.

### 2.18eq MEASURED: Poseidon on-chain is dead, keccak in-circuit is fine, and coverage is 27.7% (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8559</sub>

- [ ] If shipped, the claim must be stated exactly: *"not listed under a published passport number"*,

### 2.18ep BIND ON THE DOCUMENT NUMBER, NOT THE NAME - simpler, cheaper, and removes the controller (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8642</sub>

- [ ] Extend `sources.go` to parse `idList` (OFAC), the UN's `INDIVIDUAL_DOCUMENT`, and OFSI's
- [ ] Build the country map as an ENUMERATED table with an unmapped-string FAILURE, and anchor its
- [ ] Emit number variants as separate leaves rather than normalising, and pin the exact-match rule
- [ ] Then the non-membership circuit: extract issuing state + document number from the MRZ at their

### 2.18eo THE NAME-BINDING CIRCUIT CANNOT BE BUILT AGAINST THESE LEAVES - and the reason is in our own code (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8737</sub>

- [ ] **Do the OPRF first.** It is the dependency, not an enhancement, and nothing downstream of a
- [ ] **Assess the NOTARY name-binding separately** - its leaf lacks the fatal `Reference` component,
- [ ] **Do NOT build sanctions name-binding as specified.** If it is wanted anyway, the CRE workflow

### 2.18en THE POSTMAN ROLE IS GONE - and 2.18cp's preferred option does not exist (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8790</sub>

- [ ] **UNDO WRITE-ONCE.** It blocks the documented simulation-to-production migration. Make it
- [ ] **Implement `IReceiver` and `IERC165`.** `IReceiver is IERC165`, so `supportsInterface` may be
- [ ] Take the forwarder address from the Forwarder Directory for the target network rather than
- [ ] **Set the Forwarder at deployment.** A one-time step with no default; an anchor without it
- [ ] 2.18cm's "replace REGISTRY_POSTMAN with quid's write-once forwarder address" is DONE in

### 2.18ek THE FOLD CEILING IS 25, AND IT IS THE FOLD'S ALONE - the tree has none (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8961</sub>

- [ ] Build a tree at 64 if a batch that size is ever wanted. Depths 3, 4 and 5 all give the same

### 2.18eh 5.1.0 DELETED - one pin, in one file, for host and container (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 9134</sub>

- [ ] The nargo pin is still `1.0.0-beta.26+quid-icefix1` on the host and stock `1.0.0-beta.26` in the

### 2.18ec THE BATCH COMMITMENT HAD SILENTLY DIVERGED, and its guard could not fire (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9442</sub>

- [ ] **Audit the other cross-language pins for the same shape.** `NotaryRegistryProofTest` is cited

### 2.18dy The folded stack, built and measured (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9679</sub>

- [ ] Fold a real sixteen-withdrawal stack end to end. Needs witnesses threaded through the chain
- [ ] Generate the wrapper's EVM verifier and check it against `BatchVerifierLib`, which must move from

### 2.18dx Designing the fold to keep its advantages, not just its gate count (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9719</sub>

- [ ] Thread the accumulated COUNT through the kernels so the wrapper can expose it, and check it

### 2.18dw The folding number, measured directly (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9760</sub>

- [ ] Restructure `withdraw_identity` to `return_data`, and write the kernel and hiding circuits.
- [ ] Write our own chonk-verifying wrapper, the analogue of `rollup_tx_base_private`, and emit its EVM
- [ ] Decide whether to move the whole repo to a 6.0 toolchain or keep 5.1.0 for everything except this

### 2.18dv The decider number, found (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9797</sub>

- [ ] Build `bb-avm` from barretenberg source to compile and measure our own wrapper. That is now the

### 2.18du Folding researched properly: Aztec's is coupled, the general one is unfinished, and its decider needs a ceremony (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9836</sub>

- [ ] Recheck sonobe when ProtoGalaxy (PR 247), the decider (PR 259) and the Noir frontend land. If the

### 2.18dr Folding: accumulation is ~57x cheaper, and the decider needs a circuit we do not have (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9950</sub>

- [ ] To measure the decider we need either Aztec's hiding kernel circuit, or a folding implementation

### 2.18ds Batch sizes are fixed per circuit, and the multi-prover choice (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9994</sub>

- [ ] Wire elect-to-wait at deposit: a queue the batcher serves, with the immediate path as the
- [ ] Decide which fixed sizes to run. 16 fills sooner and saves less; 256 saves 12x more and will not
- [ ] The multi-prover choice (2.18do) sits on top of this, and its blocker is the ceremony rather than

### 2.18dq Folding measured as far as it goes: accumulation is ~57x cheaper, the decider is still unmeasured (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10017</sub>

- [ ] Work out the app/kernel structure chonk expects, or find whether a plain stack is supported at

### 2.18do Two withdrawal paths, and what stands between us and them (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10055</sub>

- [ ] Prototype the translation and on-device proving with a **throwaway single-contributor key**,
- [ ] Test the translated circuit adversarially. Witnesses that must fail, confirmed failing. Seam 1 is
- [ ] Freeze the withdrawal circuit before the real ceremony. Every revision needs a new one, and this
- [ ] Only then the ceremony, with open contribution, published transcript, and a final random beacon.
- [ ] Dispatcher and wallet path selection last. Worthless without the above.
- [ ] Keep the batched Honk path as the default, so the yield floor and the timing cohort are what

### 2.18dp The batcher as a standing target (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10117</sub>

- [ ] Measure the folding decider against the recursive baseline in 2.18dk. It decides whether the

### 2.18dn COSTING GROTH16 FOR WITHDRAWALS - and it would make the aggregator redundant (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10142</sub>

- [ ] Prototype `noir-gnark` on `withdraw_identity` FIRST. Everything else is routine; this is the
- [ ] Do NOT build the depth-2 tree until this is decided - it is 256-slot fill for a saving the

### 2.18dm AGGREGATION IS A THROUGHPUT WIN, NOT A PER-WITHDRAWAL ONE - and Groth16 wins the thin case (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10184</sub>

- [ ] Fix `verifyBatch`'s unreachable `signals.length < maxBatch` branch - require a full batch, or
- [ ] Decide the FILL POLICY: settle singly below 2 pending, batch above. Nothing does this today.
- [ ] Price the hybrid seriously: Groth16 withdrawal (one ceremony) + Honk registration. On the thin
- [ ] Note the tension with the depth-2 tree (2.18dl): 256 slots make fill HARDER, so the tree pays

### 2.18dl THE AGGREGATION ECONOMICS, MEASURED ON-CHAIN AT LAST (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10240</sub>

- [ ] Build the depth-2 tree (N=256). Largest measured efficiency win available, no new primitives.
- [ ] Consider EIP-4844 blobs for the signal calldata at large N - at N=256 signals are ~917k gas, the

### 2.18dk THE N=16 BASELINE, MEASURED END-TO-END ON THE CURRENT PIN (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10281</sub>

- [ ] Minor: `BATCH_N=1` fails to compile (N=2 and N=16 are fine) - unexamined, and it would make the
- [ ] Minor: `inner_vk.nr`'s header says "112 field elements"; it is **115**. Stale comment.

### 2.18dj FOLDING ATTACKS THE 28 GB WITHOUT LEAVING THE STACK - and `bb` already ships it (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10326</sub>

- [ ] Prototype `bb prove -s chonk --ivc_inputs_path <stack>` over 16 `withdraw_identity` instances and
- [ ] Then price the final UltraHonk wrap of the folded accumulator (one recursive verification, not

### 2.18di WHAT STAYING FULLY NOIR ACTUALLY COSTS (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10371</sub>

- [ ] Revisit annually, not continuously, and revisit on EVIDENCE: (a) does `acvm-backend-plonky2` or a

### 2.18dh TESTING THE STARK PATH AS FAR AS THIS MACHINE ALLOWS - and "no rewrite" is mostly RIGHT (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10425</sub>

- [ ] Cheapest decisive test, in order: (a) does our ACIR load in that backend at all, given the
- [ ] Do NOT restate "we would rewrite every circuit" - measured false. The circuits are Noir; the

### 2.18dg "BUT WE DO AGGREGATION" - the gas argument against STARKs does not survive it (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10474</sub>

- [ ] If the on-device constraint ever relaxes (server-side proving, or a delegated prover that does

### 2.18dd IT WAS NEVER THE STACK - it is PER-PROFILE SPECIALISATION (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10552</sub>

- [ ] Do NOT re-open Noir vs Groth16 on the strength of this (2.18dc): the verifier count is a circuit

### 2.18dc IS NOIR/ULTRAHONK STRICTLY BETTER THAN CIRCOM/GROTH16? NO - and the reason we chose it is one axis (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10591</sub>

- [ ] When EIP-170 is finally addressed (deferred by the repo owner until last), remember the cause is

### 2.18da THE ORPHANS ARE ENUMERABLE AFTER ALL - EC_LEN is quantised by data-group count (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10622</sub>

- [ ] Cheap first check before building: 2.18cy showed `SA_LEN`/`DG1_LEN`/`N` are recoverable from the

### 2.18db KECCAK vs POSEIDON IS PRINCIPLED - but self-proved non-membership breaks the split (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10664</sub>

- [ ] Decide the sanctions root's hash by measuring both sides, AFTER inlining Poseidon. Do not pick

### 2.18cz WHAT FOLDS AND WHAT CANNOT - and 7 profiles we are missing (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10693</sub>

- [ ] ~~Treat the OPRF as a dependency of self-proved non-membership.~~ **RE-ORDERED by 2.18er**: the

### 2.18cy THE SIX ORPHANS: EC_LEN IS THE ONLY MISSING GENERIC, AND IT IS DOCUMENT-SPECIFIC (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10747</sub>

- [ ] Six orphans need one SOD each. NOT RAM-blocked, NOT toolchain-blocked - the swap fix does not
- [ ] Until then the Groth16 verifiers for those six MUST stay: they are those profiles' only

### 2.18cw REMOVING ALL FOUR, AND EACH REPLACEMENT IS STRICTLY STRONGER (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10788</sub>

- [ ] 1. Land the proofs first - name-binding circuit, DON signature verification, CRL anchoring,
- [ ] 2. Remove the four authorities as each proof lands, smallest blast radius first.
- [ ] 3. THEN freeze the proof-path contracts (immutable, or an owner-renounced timelock). Until this
- [ ] Never claim the postman is gone while step 3 is open - the upgrade key IS the postman, with a

### 2.18cv THE POSTMAN INVENTORY - one is gone, four are not (user: "there is no postman anymore", 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10836</sub>

- [ ] Track these four to zero. None is blocked on a decision: three share the same circuit (2.18cu)

### 2.18cu SELF-PROVED NON-MEMBERSHIP - reinstating 2.18ct's retraction, which was wrong twice (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10856</sub>

- [ ] Withdrawal-time non-membership against the anchored sanctions root, root validity by
- [ ] Recheck the ~8-opcode estimate against the bracketing term (third revision of this number; the

### 2.18ct FEWER MOVING PARTS - SUPERSEDED BY 2.18cu, both its grounds were wrong (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10907</sub>

- [ ] **`ROOT_ACTIVATION_DELAY` is still live** in `latestActiveRoot`, although 2.18br concluded it

### 2.18cs EVIDENCE FOR #41, FROM THE SHIPPED CODE - two of its open questions are already answered (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10968</sub>

- [ ] For #41: bind the leaf to a document nullifier (trap 6), not to `sk_identity`.
- [ ] For #41: the label term's answer to silence is `registerViaNoir`'s shape. Also fix the live

### 2.18cr EVIDENCE-BOUND REVOCATION IS NOT CONTRACT-ONLY - I said it was, and the envelope says otherwise (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11010</sub>

- [ ] Name-binding circuit: prove `hash(document name fields) == leaf` for a leaf in an anchored
- [ ] THEN evidence-bound `revoke`: inclusion proof replaces `CONTROLLER`'s discretion for the

### 2.18cq THE BLACKLIST IS NOT INTEGRATED WITH THE ASP AT ALL - and the lean way in already exists (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11047</sub>

- [ ] Record per-source whether exclusion is by ABSENCE or by a status field, in `SourceSpec`

### 2.18cp "WHY CAN'T IT BE REMOVED?" - it can; the claim conflated trust with authority (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11094</sub>

- [ ] Verify DON report signatures in `RegistrySourceAnchor` and drop `onlyRole` from the report path,

### 2.18co THE 35/6/ADDRESS CLAIM RE-MEASURED - and today's Docker work did not touch it (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11185</sub>

- [ ] Decide the six twinless profiles: generate Noir verifiers or retire the profiles. Not

### 2.18cm THE FORWARDER PATTERN, TAKEN FROM `quid` AS REFERENCE ONLY (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11219</sub>

- [ ] **Replace `REGISTRY_POSTMAN` with quid's write-once forwarder address** in
- [ ] **Write ibiza's deployment sequence**, with forwarder wiring as an explicit step that FAILS

### 2.18gz-unify 🟢 THE COHESIVE PREDICATE IS BUILDABLE — but on ADDRESSES, not names
<sub>archive: `TODO-ARCHIVE.md` line 16179</sub>

- [ ] CRE publishes the identifier set as a Poseidon SMT keyed by the leaf hash, not a sorted list
- [ ] `RegistrySourceAnchor` anchors that root; reuse `isValidRoot`'s `MAX_ROOT_AGE` rule so
- [ ] Withdrawal circuit: one `smt_verifier_full(..., fnc = true)` term keyed by the recipient
- [ ] Recheck the opcode estimate against THIS term - the third revision the note asks for, now

