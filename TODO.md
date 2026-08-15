# TODO — open items only

Everything here is UNDONE. Completed work, superseded designs and the evidence behind both live in
`TODO-ARCHIVE.md`, which is unchanged and is still the authority for *why* a thing is the way it is.
Each section below cites its archive line so the reasoning is one jump away.

⚠️ **Sections are kept only where an item is still open.** A section's absence here means it is done
or superseded, NOT that it never existed - check the archive before concluding anything is missing.

---

## Live now — opened or reopened 2026-08-13..15, not yet in the numbered scheme

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
- [ ] **Non-association predicate** - the PP paper's exclusion proof over deposit `label`s. Distinct from
      sanctions non-membership (provenance vs destination); same `smt_verifier_full(fnc=true)` primitive.
- [ ] **`court.sol` ← blacklist disputes.** Jurisdiction is TRANSCRIPTION FIDELITY, not designation
      validity. Blocked on the sanctions predicate existing (2.18gz-unify).
- [ ] **Secret ballot for removal-by-electorate and citizenship renunciation** - rarime's vote extended;
      PP for mixing, SPV for yield. The 'final fold', gated on the 6909 basket and the links.
- [ ] **Modularise `iran-constitutional-monarchy` into a bilateral parliament.** Open first question:
      does the jury engine land inside `SupremeCourt`, or beside it as a `Court` it appoints into?
- [ ] **Simplify along the `quid` seam.** Measured: quid `Aux+Vogue+VogueCore` = 1,742 lines with **0**
      `isBTC`; SPV `Aux+Vogue+Core` = 4,164 with **358**. quid is a working reference for the §J.2
      consolidation - but it never faced BTC, so it proves the cost, not that one impl serves both.
- [ ] **`Registration2` certificate paths are untested** - `registerCertificate`, `revokeCertificate`,
      X509. No document needed.
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

