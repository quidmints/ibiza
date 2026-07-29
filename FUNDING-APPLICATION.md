# Funding Application — Private Property & Identity Infrastructure

> Working answers. Each section is held to its stated limit; word counts are given so they can be
> re-checked after editing. Claims are deliberately conservative — what is built is described as
> built, what is not is described as not.

**Source code** (both repositories ship with this application):
- Identity, privacy pool and title layer — <https://github.com/quidmints/ibiza>
- Treasury and reserve protocol — <https://github.com/quidmints/SPV>

**Prior deployment of the identity base, in Iran:** Rarime's Freedom Tool — the passport
zero-knowledge stack this work forks — was used by Iranian civil-society organisations
(IranUnchained, TCT e.V.) to run anonymous protest votes on the 2024 presidential election,
verifying eligibility from biometric passports scanned locally, with nothing transmitted to a server.
<https://alexablockchain.com/iranian-voting-app-to-protest-presidential-election/>

---

## 1. Short description of the proposed project *(300 max)*

We have built infrastructure that lets people prove who they are, and what they own, without
disclosing either publicly. The code ships with this application. The funding proves it works in
practice.

The identity base is not hypothetical here: the passport zero-knowledge stack we fork was already
used inside Iran for anonymous voting, passports scanned on the phone, nothing sent to a server.
People at real risk have already trusted this method. What has never existed is the layer beneath it
— the ability to *hold* something, and prove you hold it, on the same terms.

We joined two open-source systems. Privacy Pools (0xbow) lets someone deposit and later withdraw
unlinkably; Rarime proves a passport genuine while revealing nothing about its holder. Each had a
gap: Privacy Pools screens *money*, by chain-analysis heuristics that taint funds by association;
Rarime proves *personhood* with no financial layer. Merged, a withdrawal proves the honest thing — a
real, admitted person is withdrawing — not guilt-by-association about where their money has been.

On that base we built what the merge exposed as missing. An identity registry that **fails open**: an
operator who does nothing blocks nobody, and no one can be retroactively removed — the reverse of how
these systems usually fail. Then property: ownership provable, the property itself not publicly
identifiable, the same parcel never titled twice.

**Private identity, private title, private transfer.** None needs a counterparty, a valuation, or a
court, which is why all three work today. Lending against those titles is specified and would follow,
but it depends on things cryptography does not provide, and we scope it separately rather than
promise it.

For people whose governments treat financial surveillance as an instrument of control, this is the
difference between owning something and being permitted to.

*(≈299 words)*

---

## 2. Implementation: approach, activities, and milestones *(1000 max)*

**The code is written and shipping; this funding proves it works in practice.** It is built and
tested — 269 contract tests, 84 circuit tests, real zero-knowledge proofs verified on-chain through
generated verifiers, not mocks — but unaudited, never having met a real passport, holding no real
value. Those three gaps are what the milestones close, in order.

**What ships:** four Noir/UltraHonk circuits (withdrawal, ragequit, escrow, registration); the
identity registry, privacy pool, entrypoint and title ledger; the dollar pool that funds against
them; and a wallet holding one BIP39 seed in the device secure enclave, from which every key derives.

Both repositories are public and these claims are checkable today: clone either, run the suites,
regenerate the proof fixtures from committed scripts. Nothing here asks to be taken on trust that
could instead be run.

### Milestone 1 — Audit

Nothing reaches a real user before independent review. Scope, by descending risk:

**Circuits.** A soundness bug here is silent and total — a wrong constraint lets an attacker mint
value or bypass identity while every test passes. `withdraw_identity`, `escrow_envelope`,
`ragequit`, and the inherited passport circuits.

**The identity registry.** Its guarantees are the product: registration cannot be refused; exclusion
requires an affirmative, rule-citing act; a stale root expires so revocation cannot be evaded, while
the newest never expires so inaction cannot block anyone. Each is a property an auditor should try
to break.

**The pool and treasury.** Deposit/withdraw accounting, nullifier handling, the change-note path,
ragequit payouts, reserve accounting and the redemption ladder.

**Key management.** Seed derivation, enclave storage, the biometric gate — a weakness here loses
funds regardless of the circuits. **The generated verifiers**, against the circuits they claim to
verify.

We will also review the trust model — not "is the code correct" but "who can do what to whom",
where this class of system usually fails.

### Milestone 2 — Deploy

Both repositories to mainnet: identity, pool and title contracts, and the treasury behind them.
Deployment is not only contracts — **the wallet's device path is the gating item.** The identity SDK
ships device-only binaries so it cannot run on our machines, and NFC passport reading is not
implemented. A deployed contract nobody can reach is not deployed. This milestone completes NFC
reading against real passports, verifies the enclave key path on hardware, and confirms a
phone-generated proof verifies on-chain. Passports vary in ways specifications do not capture, so
this needs real documents, not test vectors.

### Milestone 3 — Proving it works in practice

A small consenting cohort, real passports, value starting near zero and rising only as it holds.
Full round trip: scan, register, deposit, withdraw to a fresh address, and confirm an observer with
the whole chain cannot link the two. Proving time is measured on mid-range devices — the population
that most needs this does not carry flagships.

**This is field work, the half no code replaces:** engaging notaries, retaining counsel, recruiting a
cohort through partners those users already trust. Relationship and legal work done in-country, and
where most of this funding goes.

It requires **devices and documents** from multiple issuing states, since MRZ layouts and chip
behaviour differ; **informed consent** and a documented exit per participant; **monitoring that does
not itself surveil**; and a **rollback plan** — any depositor can already exit unilaterally, which is
what makes a pilot ethically defensible.

### Milestone 4 — Title and lending

The title ledger exists; the registry bridge does not. Iran's cadastre (*Sabt-e Asnad va Amlak*,
سازمان ثبت) exposes tiered access we build on rather than replace:

- **Tier 1, the owner** — *Sabt-e Man* (my.ssaa.ir): every parcel and encumbrance under their
  national ID (*Kārt-e Melli*, کد ملی).
- **Tier 2, lenders and public** — *Tasdiq-e Asalat* (تصدیق اصالت), deed authenticity from the
  18-digit *Shenaseh Yekta* plus the owner's national ID.
- **Tier 3, licensed notaries** (*Sardaftar*, سردفتر) — ssar.ir: query encumbrances (*Bāzdāsht*,
  بازداشت), register mortgages, execute binding transfers.

**That division decides the design.** Anyone can verify a deed, so nobody need trust a notary's word
about a property. What only a notary can do is *make a lien legally exist* — one registered by anyone
else is void. So we prove notary licensing on-chain by indexing the official register through a
decentralised oracle network where every node returns byte-identical data: the narrow claim that
whoever executed the registration was entitled to. Deed truth comes from Tier 2, independently. Fraud
detection then needs no accuser — an oracle re-query catches a missing encumbrance from state data,
identifying nobody.

**Notaries can be targeted for serving a system like this**, so their participation stays private: a
notary proves in zero knowledge that they are one of the licensed set without revealing which, and
their attestation carries an encrypted identity a quorum of legal guardians can open **only** on a
proven discrepancy.

**Lending is scoped separately, deliberately.** Everything above stands alone. Lending adds one
dependency cryptography cannot supply: an **independent valuation**. The borrower provides the input
and gains by inflating it, so their own equity is not self-verifying — the tractable form is
attesting a licensed appraiser's registration exactly as we attest notaries, or reading public
auction comparables. A lien also needs a legal holder, which is a special-purpose vehicle, standard
finance rather than an open problem.

Foreclosure would use existing institutions — *Ejra-ye Ahkam* (اجرای احکام) via adliran.ir,
*Mozāyedeh* (مزایده) via setadiran.ir — with an irrevocable assignment
(*Vekālat-nāmeh-ye Belā-'Azl*, وکالت‌نامه بلاعزل) executed at origination, a form courts recognise.
**If valuation cannot be made independent, we ship identity and title without lending.** Those are
the product; lending is the extension.

**What each milestone delivers:** 1 — an audit report and remediated code. 2 — live contracts and a
wallet that reads a real passport. 3 — measured evidence that a person can register, transact and
exit unlinkably on a mid-range phone. 4 — a title provably issued by a licensed notary, with the
property undisclosed.

*(1000 words)*

---

## 3. Technical feasibility *(300 max)*

**Technologies.** Noir/UltraHonk circuits; Solidity verification; React Native with platform secure
enclaves. Identity follows ICAO 9303, so the trust root is the issuing state's signature, not
anything we control.

**Capacity.** The system is built and tested, the strongest evidence we can build it. We found and
fixed subtle defects along the way — a proof binding to an unconstrained field, stale roots letting
revocation be evaded, a commitment hiding the property while permitting the same parcel to be titled
twice. Finding our own errors matters more than claiming correctness. **The identity base is
field-proven in this exact jurisdiction:** the passport stack we fork ran anonymous Iranian protest
voting (link above), so passport scanning by users at risk is demonstrated, not hypothetical.

**Dependencies.** The proving toolchain and passport standard, both stable and open; and the
jurisdiction's registry portals, outside our control.

**Risks and mitigation.** *Lending's dependencies do not resolve* — independent valuation, an entity
able to hold a lien, and a state-visible encumbrance; mitigated by scoping identity and title to
stand alone, since provable private ownership is useful without anyone lending against it. *Portal
changes break the scrapers* — versioned workflows with a timelock, so an update is visible before it
takes effect. *Registry access withdrawn* — local integration sits behind an interface, so a
jurisdiction is configuration, not a fork. *Proving too slow* — measured on mid-range devices; the
withdrawal circuit is already 43% smaller. *A soundness bug* — why audit is first. *Key loss* — every
key derives from one enclave-held seed, and notes are re-derivable by scanning.

**One bound we state rather than hide.** The registers are the state's own: strong against private
fraud — a bribed notary, a forged deed — and worth nothing against a state fabricating credentials.
We protect privacy *from* the state, not the protocol's integrity *against* it.

*(≈299 words)*

---

## 4. Scalability *(300 max)*

**Cryptographic scaling is already done and measured.** The withdrawal proof was reduced from 43,772
to 24,812 constraints — a 43% cut — by merging two identity structures into one and moving the
identity check off the frequently-used path onto a one-time registration step. Costs that recur per
user, per transaction, are the ones we optimise; one-time costs we accept.

**On-chain state scales sublinearly.** Membership lives in a sparse Merkle tree; adding a user costs
a proof of depth proportional to the logarithm of the population, not its size. The registry is sized
for roughly four billion identities, which is not the binding constraint.

**The binding constraint is client proving time**, since proofs are generated on the user's phone. It
is bounded by circuit size, which is why we measure every change in constraints rather than
estimating. This also scales with hardware improving over time, in our favour.

**Jurisdictional scaling is the real question.** Identity, title and lien logic are
jurisdiction-agnostic. What is local is narrow: the registry endpoints, the deed schema, and the
enforcement vendors. These sit behind interfaces so that supporting a second country is a
configuration exercise plus legal review — not a second codebase. We designed it this way after
being asked to generalise beyond a single country, and it is the difference between a tool for one
population and infrastructure for many.

**Capital scales independently of any of this.** Funding capacity grows by adding reserves or
liquidity — no protocol change, no permission — and diversified reserves mean capacity is not gated
on a single asset's depth. What bounds lending volume is the supply of independently valued
properties, not anything technical.

**Operationally**, there is no server to scale. The chain and the user's device do the work.

*(≈293 words)*

---

## 5. Resilience to censorship *(300 max)*

**What can be blocked, honestly.** Network access to the chain, app-store distribution, and the
official registry portals the property layer reads. We do not claim otherwise.

**What cannot.** No server to seize, no operator to coerce. Registration is permissionless by
construction — no approval step means nothing an authority can instruct anyone to withhold. And
exclusion is *fail-open*: an operator pressured into inaction blocks nobody, because the newest state
stays valid indefinitely. That is the property most systems get backwards; we made "do nothing" the
safe default rather than the censoring one.

Nobody can be retroactively removed. In the system we started from, an operator could publish a
membership set omitting someone and silently strip their private exit. Exclusion now requires an
affirmative act citing a stated reason, recorded permanently.

**Mitigations for what can be blocked.** Chain access via any RPC endpoint, including user-supplied
ones, over ordinary HTTPS expensive to distinguish from other traffic; distribution outside app
stores by direct install, which Android permits; and — critically — an unconditional escape hatch:
any depositor can always recover their funds without anyone's permission, so a blocked user is never
a trapped one.

**Blocking the registry portals degrades the system rather than stopping it.** Identity and the
shielded pool read no government endpoint — only the passport chip in the user's hand and the chain.
Just the title and lending layer consults the cadastre, so cutting that access costs property
functions while leaving private identity and transfer intact. That layering is deliberate.

**The residual we cannot engineer away** is coercion of the individual: a phone can be seized and a
person compelled to unlock it. We reduce blast radius — biometric gating, no plaintext identity
on-chain — but do not pretend to solve it.

*(≈291 words)*

---

## 6. User security measures *(300 max)*

**Nothing identifying is published.** On-chain values are commitments and opaque pseudonyms. Where a
naive design would store a hash of something guessable — a property address — we treated that as a
live vulnerability, since low-entropy inputs are brute-forceable from public records. Those are now
keyed pseudonyms resisting a dictionary attack.

**One secret, in hardware.** A single seed lives in the device secure enclave behind biometric
authentication; every other key derives from it. Availability is checked explicitly and the wallet
*fails closed* — refusing to store the seed rather than silently falling back to weaker storage.

**No note storage to lose or leak.** Spending secrets are derived, not stored, so a compromised
backup discloses nothing extra.

**An unconditional exit.** Any depositor can withdraw their own funds without any operator's
permission. It costs them unlinkability — a trade that is theirs to make, not ours.

**Assumptions stated rather than hidden.** The identity check tells you someone holds a genuine
passport — not that they are trustworthy. A person may hold several passports, limiting what
identity-based exclusion achieves.

**A known limitation we disclose rather than discover later:** registering publishes a link between
an identity and its pool handle, so *participation* is visible even though *activity* is not — a
withdrawal never reveals which handle it belongs to. Anyone can see that a person joined; nobody can
see what they did, or connect a deposit to a withdrawal. We are closing this by proving membership
against a committed tree instead of publishing identifiers.

**Verification over assertion.** Testing is adversarial: we check a guard fails when removed, not
merely that the suite is green. Several real defects were caught this way, including a test that had
silently stopped testing anything.

**Audit before users.** No real value until independent review is complete and remediated.

*(≈299 words)*

---

## 7. Keeping costs low *(300 max)*

**No infrastructure to run.** There is no backend, no database, and no server holding user data —
which removes both the largest recurring cost and the largest liability. The chain provides
availability; the user's device does the computation.

**Optimise what recurs, accept what does not.** Every circuit change is measured in constraints, and
we reject changes that add cost to the frequently-used path even when they look elegant. The
withdrawal path is 43% cheaper than it was; a proposed change to the identity structure was
*cancelled* on measurement when it turned out to cost 12% more for a cosmetic gain. One-time
registration cost we accept, because it is paid once per user rather than once per transaction.

**On-chain gas is the user's cost, so it is our problem.** Deployment fits within contract size
limits with the optimiser scoped only where needed. Verification cost is bounded by proof size,
which is constant for this proving system regardless of circuit complexity.

**Build on maintained open source.** We did not write our own proving system, sparse Merkle tree, or
passport parser — we use audited or widely-used implementations and test against them differentially.
Where we briefly wrote our own tree, we deleted it and asked the chain instead: less code to
maintain, and impossible to drift.

**Reuse across subsystems.** The same pseudonym primitive serves identity revocation and property
uniqueness. One mechanism audited once, used twice.

**Grant funds go to audit, field work, devices and legal review** — what genuinely cannot be done
without money. Field work dominates after audit: engaging notaries, counsel per jurisdiction, and
cohort recruitment are people-time in-country, not engineering. We spend nothing on marketing and
issue no token.

*(≈281 words)*

---

## 8. Maintenance beyond the funding cycle *(300 max)*

**Low structural maintenance burden.** No servers means no operational cost floor: if funding stops,
the deployed contracts keep working and users keep control of their funds. The escape hatch means
nobody is stranded even in total project abandonment — which we consider a requirement, not a
feature.

**Documented to be handed over.** The codebase records not just what it does but *why*, including
the mistakes: decisions that were reversed and the measurement that reversed them, guards that exist
because a specific failure was found, and errors made and corrected. A maintainer who has never met
us can see the reasoning, which is what makes a project survivable after its authors leave. This is
already the working practice, not a plan.

**Open source, on maintained dependencies.** The proving toolchain and identity libraries are
actively developed by others; our contribution is the layer joining them. Defects we find in
upstream we push upstream — we have already contributed fixes back.

**Narrow local surface.** Jurisdiction-specific integration is deliberately isolated, so the part
most likely to break — a government portal changing — is the part cheapest to repair, and can be
repaired by someone local without touching the cryptography.

**Sustainability path.** The treasury earns yield on its reserves whether or not a single mortgage is
written, and that revenue — not lending — is what funds maintenance. Lending would add to it. We do
not plan to depend on repeated grant cycles: grant funding is for what cannot be self-funded,
principally security audit.

**Realistic commitment.** We will not claim indefinite stewardship. What we commit to is leaving the
system in a state where someone else can take it on.

*(≈291 words)*
