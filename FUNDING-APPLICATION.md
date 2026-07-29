# Funding Application — Private Property & Identity Infrastructure

> All software described here is written and ships with this application. Claims are deliberately
> conservative: what is built is described as built, what is not is described as not.

**Source code** (both repositories ship with this application):
- Identity, privacy pool and title layer — <https://github.com/quidmints/ibiza>
- Treasury and reserve protocol — <https://github.com/quidmints/SPV>

**Prior deployment of the identity base, in Iran:** Rarime's Freedom Tool — the passport
zero-knowledge stack this work renovates — was used by Iranian civil-society organisations
(IranUnchained, TCT e.V.) to run anonymous protest votes on the 2024 presidential election,
verifying eligibility from biometric passports scanned locally, with nothing transmitted to a server.
<https://alexablockchain.com/iranian-voting-app-to-protest-presidential-election/>

---

## 1. Short description of the proposed project *(300 max)*

All of the software is built. It lets a person prove who they are, and prove they own a piece of
land, without disclosing either to the public.

This is not hypothetical here: the passport zero-knowledge stack we renovate was already used inside
Iran for anonymous voting. The passport is read by the phone's NFC chip, checked on the device,
nothing sent to a server.

We joined two open-source systems. Privacy Pools (0xbow) lets someone deposit and later withdraw
without the two being linkable; Rarime proves a passport genuine while revealing nothing about its
holder. Each had a gap: Privacy Pools screens *money*, using chain-analysis guesswork that taints
funds by association; Rarime proves *personhood* but touches no money. Merged, a withdrawal proves
the honest thing — a real, non-sanctioned person is withdrawing.

Three things the merge makes possible that did not exist:

**Shielded money that earns.** Privacy Pools holds deposits idle. Ours sit in a reserve that earns
yield while shielded, so privacy stops costing the user their return.

**Bitcoin without a custodian.** Production BTC bridges ask you to trust an operator or committee
holding the coins. Ours does not: the depositor keeps one of two keys, the protocol cannot move funds
alone, and if the protocol disappears the depositor closes the channel and recovers their bitcoin
unilaterally.

**Land ownership as a private, verifiable fact** — provable to a lender or a court, invisible to
everyone else, and impossible to register twice over the same parcel.

The purpose is narrow and worth stating plainly: to make mortgage credit cheaper by removing the
bank's margin, and to make refusal impossible. Nobody can be denied on grounds of faith, politics,
sex or ethnicity, because there is no one in the system with the power to refuse.

---

## 2. Implementation: approach, activities, and milestones *(1000 max)*

**Every part of the software is written and ships with this application**, with proofs generated and
verified on-chain today. What it has not had is an audit, a real passport, or real value at stake —
the three gaps the milestones close, in order.

**What ships:** the zero-knowledge circuits for registration, withdrawal, escrow and emergency exit;
the identity registry, shielded pool and title ledger; the reserve funding them; and a wallet holding
one recovery phrase in the phone's secure enclave, from which every other key derives.

One engineering decision underpins the rest. The two systems we merged proved things in incompatible
ways; we rebuilt both onto a single proving system, so identity, money and title are verified by one
stack — one toolchain to keep current, one surface to audit, rather than several that must agree.

Both repositories are public and these claims are checkable: clone either, run the suites, regenerate
the proof fixtures from committed scripts.

### Milestone 1 — Audit

Nothing reaches a real user before independent review. By descending risk:

**The circuits.** A flaw here is silent and total: one wrong constraint lets an attacker create value
or bypass identity while every test still passes.

**The identity registry**, whose guarantees are the product — registration cannot be refused,
exclusion demands an affirmative act citing a rule, and a stale record expires so revocation cannot
be outrun, while the newest never expires so inaction blocks nobody.

**The money.** Deposit and withdrawal accounting, double-spend prevention, and the reserve's
redemption schedule.

**Key handling.** How the recovery phrase is derived, stored and unlocked — a weakness here loses
funds however good the circuits are.

We will also commission a review of who can do what to whom — where systems of this kind fail more
often than in their arithmetic.

### Milestone 2 — Deploy

Both repositories to mainnet. **The gating item is not the contracts but the phone:** the identity
libraries run only on a device, and passport NFC reading is the one piece still to write. A contract
nobody can reach is not deployed. This milestone finishes NFC reading, proves the key path works on
real hardware, and confirms a proof generated on a phone verifies on-chain.

### Milestone 3 — Proving it works in practice

A small consenting group, real passports, value starting near zero and rising only as it holds. The
full round trip: scan, register, deposit, withdraw to a fresh address, and confirm someone holding
the entire chain cannot connect the two. Timings are taken on mid-range phones, since the people who
most need this do not carry new ones.

**This is field work** — engaging notaries, retaining counsel, recruiting through partners those
users already trust — done in-country, and where most of this funding goes. It needs passports from
several issuing states, because chip behaviour and data layouts differ in ways the standard does not
capture.

### Milestone 4 — Title and lending

The title ledger exists; the bridge to the land registry does not. Iran's Deeds and Properties
Organisation (*Sazman-e Sabt*, سازمان ثبت) grants three levels of access, each doing a job the others
cannot:

- **The owner**, via *Sabt-e Man* (my.ssaa.ir), sees every parcel and charge recorded against their
  ID number (*kod-e melli*, کد ملی) — the only way to *discover* a charge nobody disclosed.
- **Anyone** can confirm a named deed is genuine (*Tasdiq-e Asalat*, تصدیق اصالت) from its 18-digit
  identifier and the owner's ID number.
- **A licensed notary** (*Sardaftar*, سردفتر), via ssar.ir and nobody else, can register a mortgage
  or execute a transfer.

**That division decides the design.** Since anyone can confirm a deed, nobody need take a notary's
word about a property. What only a notary can do is *make a mortgage legally exist* — one registered
by anyone else is void, and whoever holds it holds nothing. So the single fact we prove on-chain is
that whoever registered it was licensed at the time, by indexing the official register through a
decentralised oracle network where every node must return byte-identical data.

It also gives fraud detection with no accuser: a notary either registered the charge or did not, the
registry says which, and a re-query catches a missing one automatically, identifying nobody.

**Notaries can be punished for serving a system like this**, so which notary acted is never published:
they prove they are one of the licensed set without revealing which, and their identity travels
encrypted, openable only by a quorum of legal custodians and only against a proven discrepancy.

**We fund loans; we do not write them.** That choice is why the rate can fall. A bank's rate carries
its cost of capital, its branches and its shareholders' return; here the capital comes from whoever
holds a share of the reserve, anywhere, and the only margin is what servicing costs. It also removes
the place where refusal happens. A bank chooses whom to serve, and people are refused for their
faith, politics, sex or name. A protocol holding no such discretion cannot.

Lending needs one thing cryptography cannot supply: an **independent valuation**. The borrower
provides the figure and gains by inflating it, so their own stake does not verify itself. The
tractable form is attesting a licensed valuer as we attest notaries, or reading public auction
results. The mortgage also needs a legal holder — an ordinary special-purpose vehicle.

Foreclosure would use existing institutions — judicial enforcement (*Ejra-ye Ahkam*, اجرای احکام) and
public auction (*Mozāyedeh*, مزایده) — with an irrevocable assignment
(*Vekālat-nāmeh-ye Belā-'Azl*, وکالت‌نامه بلاعزل) signed at the start, a form the courts recognise.
**If valuation cannot be made independent, we ship identity and title without lending.**

**Delivered at each stage:** an audit report and the fixes; live contracts and a wallet reading a
real passport; measured evidence a person can register, transact and leave unconnected; and a title
provably registered by a licensed notary, the property undisclosed.


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

**Jurisdictional scaling is the real question.** Identity, title and mortgage logic are the same
everywhere. What is local is narrow — the registry endpoints, the deed format, the enforcement
institutions — and sits behind interfaces, so a second country is configuration plus legal review
rather than a second codebase.

**Every user brings their own capacity.** Proofs are made on the person's phone and checked by the
chain, so there is no shared component that saturates: a thousandth user costs the same as the first.
The reserve grows by adding deposits, needing no protocol change and nobody's permission, and its
assets are diversified so capacity is not gated on the depth of any single one. What limits lending
volume is the supply of independently valued properties, not anything technical.


---

## 5. Resilience to censorship *(300 max)*

**What can be blocked.** Network access to the chain, app-store distribution, and the government
registries the property layer reads.

**What cannot.** No server to seize, no operator to coerce. Registration has no approval step, so
nothing can be ordered withheld, and exclusion **fails open** — someone pressured into inaction
blocks nobody, because the newest state stays valid indefinitely. Most systems get this backwards;
here doing nothing is the safe default, not the censoring one.

Nor can anyone be removed after the fact. In the system we started from, an operator could publish a
membership list quietly omitting someone; exclusion now demands an affirmative act citing a stated
reason, recorded permanently.

Chain access runs over ordinary HTTPS to any endpoint, including one the user supplies, and is
costly to tell apart from other web traffic.

**Distribution was a design decision.** We built the wallet in React Native because it compiles to a
standard Android package that installs from a file — sideloaded, passed between phones, or sent over
a messaging app, with no store, no account and no list of who downloaded it. A store can be ordered
to delist; a file cannot be recalled once it has spread.

A user cut off entirely is still not trapped: they can reclaim their deposit directly from the
contract (section 6).

**Blocking the government registries degrades the system rather than stopping it.** Identity and the
shielded pool read no state endpoint — only the passport chip and the chain. Only the property layer
consults the registry, so cutting it costs property functions while leaving identity and private
transfer intact.

**What we cannot engineer away** is coercion: a phone can be seized and its holder compelled to
unlock it. Biometric gating and holding no identity in the clear limit the damage without solving
it.

---

## 6. User security measures *(300 max)*

**Nothing identifying is published.** Where an obvious design would store a fingerprint of a street
address, we treated that as a live vulnerability: anyone could take addresses from public records,
fingerprint each and find the match. Those values are now disguised in a way that cannot be
searched.

**One secret, in hardware.** A single recovery phrase lives in the phone's secure enclave behind
biometric unlock, and every other key derives from it. If the enclave is unavailable the wallet
refuses to store it rather than quietly falling back to weaker storage.

**Nothing else to lose.** Spending keys are derived from that phrase rather than stored, so a stolen
backup reveals nothing further.

**A guaranteed way out.** Whoever made a deposit can always reclaim it directly from the contract
with the key on their own phone — no approval, no operator, nothing working but the chain. The cost
is that this one action publicly links the deposit to whoever reclaims it, which ordinary withdrawal
never does. Nobody can make that trade on the user's behalf.

**Assumptions stated, not hidden.** The check proves someone holds a genuine passport, not that they
are trustworthy — and a person may hold several, limiting what excluding an identity achieves.

**A limitation we disclose rather than let an auditor find:** registering publicly links a person to
their pool account, so it is visible that someone joined — never what they did, nor which deposit
belongs to which withdrawal. We are closing it so even joining is unobservable.

**Verification over assertion.** We test by deleting a safeguard and confirming the test then fails,
rather than trusting a green result. That caught several real defects, including a test that had
quietly stopped checking anything.

**Audit first.** No real value at stake until independent review is complete and its findings
fixed.


---

## 7. Keeping costs low *(300 max)*

**No infrastructure to run.** No backend, no database, no server holding user data — removing both
the largest recurring cost and the largest liability. Ethereum provides availability; the phone does
only what it must.

**Optimise what recurs, accept what does not.** Every change is measured, and we reject those adding
cost to the frequently-used path however elegant they look: withdrawal is 43% cheaper than it was,
and one proposed redesign was cancelled on measurement when it proved 12% more expensive for a
cosmetic gain. One-time registration cost we accept, since it is paid once per person rather than
once per transaction.

**Transaction fees are the user's cost, so they are our problem.** Verification cost is fixed by proof
size, which stays constant here however complex the underlying computation.

**Build on maintained open source.** We wrote no proving system, data structure or passport parser of
our own, using established implementations and testing against them. Where we did briefly write our
own, we deleted it and asked the chain instead — less to maintain, and impossible to drift out of
agreement.

**One mechanism, two uses.** Blocking a sanctioned person and stopping a property being mortgaged
twice sound unrelated, but both reduce to publishing a list of disguised identifiers that anyone can
check against without learning what they stand for. We built that once and use it for both — half
the code, and one thing for an auditor to examine rather than two.

**Grant funds go to audit, field work, devices and legal review** — what genuinely cannot be done
without money. Field work dominates after audit: engaging notaries, counsel per jurisdiction, and
cohort recruitment are people-time in-country, not engineering.


---

## 8. Maintenance beyond the funding cycle *(300 max)*

**Nothing to keep running.** With no servers there is no cost floor: if funding stops, the deployed
contracts continue and users keep control of their money. Even if the project is abandoned outright,
nobody is stranded — the direct reclaim in section 6 needs no one but the user.

**Documented to be handed over.** The codebase records not only what it does but why — decisions that
were reversed and the measurement that reversed them, safeguards that exist because a specific
failure was found. Someone who never met us can follow the reasoning. This is already the working
practice, not a plan.

**Open source, on maintained dependencies.** The proving toolchain and identity libraries are
actively developed by others; our contribution is the layer joining them, and defects we find there
we have already contributed back.



**A narrow surface to maintain.** Everything jurisdiction-specific is isolated in one place, so the
component most likely to break — a government portal changing its format — is also the cheapest to
repair, and repairable locally without touching any cryptography.

**How it pays for itself.** The reserve earns a return whether or not a single mortgage is ever
written, and that — not lending — is what funds maintenance. We do not plan to depend on repeated
grants: this funding is for what cannot be self-funded, principally the audit.

**What happens if we stop.** The contracts are not upgradeable and have no administrator, so they
keep running with nobody at the controls; deposits, withdrawals and existing titles are unaffected by
our absence. The only work that genuinely recurs is updating the readers when a government portal
changes its format — a self-contained task, in one place, that a local developer can do without
touching the cryptography.

