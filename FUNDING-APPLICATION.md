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

## 1. Short description of the proposed project *(297/300 words)*

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

The purpose is narrow and worth stating plainly: to strip a licensed intermediary's cost out of
mortgage credit, and to make refusal impossible. Nobody can be denied on grounds of faith, politics,
sex or ethnicity, because there is no one in the system with the power to refuse.

---

## 2. Implementation: approach, activities, and milestones *(1000/1000 words)*

**Every part of the software is written and ships with this application**, proving and verifying
on-chain today. It has not had an audit, a real passport, or value at stake — the three gaps the
milestones close, in order.

**What ships:** the zero-knowledge circuits for registration, withdrawal, escrow and emergency exit;
the identity registry, shielded pool and title ledger; the reserve that earns on shielded deposits;
the payment-channel bridge that holds bitcoin without a custodian; and a wallet deriving every key
from one recovery phrase in the phone's secure enclave.

One engineering decision underpins the rest: the two systems we merged proved things incompatibly, so
we rebuilt both onto one proving system. Identity, money and title verify through a single stack —
one toolchain to keep current, one surface to audit.

Both repositories are public, so the claim is checkable rather than asserted: clone either, run the
suites, regenerate every fixture from committed scripts. Each generated verifier is exercised
on-chain against a real proof, so one that stopped verifying would fail.

### Milestone 1 — Audit

Nothing reaches a real user before independent review, by descending risk. **The circuits**, where a
flaw is silent and total: one wrong constraint lets an attacker mint value or bypass identity while
tests still pass. **The identity registry**, whose guarantees are the product: registration
cannot be refused, exclusion demands an act citing a rule, and a stale record expires so revocation
cannot be outrun, while the newest never expires so inaction blocks nobody. **The money** —
deposit and withdrawal accounting, double-spend prevention, redemption. And
**key handling**, where a weakness loses funds however good the circuits are. We will also commission
a review of who can do what to whom — where such systems fail more often than in their
arithmetic.

### Milestone 2 — Deploy

Both repositories to mainnet. **The gating item is not the contracts but the phone:** the identity
libraries run only on a device, and passport NFC reading is the one piece still to write — a contract
nobody can reach is not deployed. This milestone finishes it and confirms a proof made on real hardware
verifies on-chain.

### Milestone 3 — Proving it works in practice

A small consenting group, real passports, value starting near zero and rising as it holds: scan,
register, deposit, withdraw to a fresh address, and confirm nobody holding the whole chain can
connect the two. Timings come from mid-range phones, not new ones.

**This is field work** — engaging notaries, retaining counsel, recruiting through partners users
already trust — done in-country, where most of this funding goes. It needs passports from several
states, since chip behaviour differs in ways the standard does not.

### Milestone 4 — Title and lending

The title ledger exists; the bridge to the land registry does not. Iran's Deeds and Properties
Organisation (*Sazman-e Sabt*, سازمان ثبت) grants three levels of access, each doing a job the others
cannot — and that division decides where each check runs:

- **The owner**, via *Sabt-e Man* (my.ssaa.ir), sees every parcel and charge against their ID number
  (*kod-e melli*, کد ملی) — the only way to *discover* an undisclosed charge.
- **Anyone** can confirm a named deed (*Tasdiq-e Asalat*, تصدیق اصالت) from its 18-digit identifier
  and the owner's ID.
- **A licensed notary** (*Sardaftar*, سردفتر), via ssar.ir alone, registers a mortgage or executes a
  transfer.

Only a licensed notary can register a *consensual* mortgage: a private agreement is not void, but
the Land Registration Act makes it inadmissible before courts and registries, so it cannot be
foreclosed. Whether a notary is licensed is public fact about a public register, so we index that
register through a decentralised oracle network where every node returns byte-identical data.

A *deed* cannot be checked that way, because the query names the owner. Run by a lender it exposes
every applicant; run by the owner it discloses nothing — they supply details a government already
holds. So the owner runs it on their own device and submits a proof: what reaches the chain is that
a genuine deed exists, bound to identifiers naming neither person nor parcel.

**Notaries can be punished for serving a system like this**, so which notary acted is never
published: they prove membership of the licensed set without naming a member, and their identity
travels encrypted, openable by a quorum of custodians against a proven discrepancy.

**We fund loans; we do not write them — the central choice.** Writing a loan means judging a person,
and whoever holds that judgment can refuse: on faith, politics, sex, name. A promise never to use it
is worth only the promiser's freedom from pressure, so we do not take the power. The protocol lends
against collateral checked mechanically, and mechanical checks cannot be aimed at a person.

Two further levers go with it: originating needs a licence, so the system would run on permission
that can be withdrawn; and an originator holds the borrower's file — data never collected cannot be
compelled from us.

A cheaper rate follows, though less of one than disintermediation is usually claimed to give;
section 7 sets out which parts of a bank's rate we actually remove and which we do not.

Lending also needs what cryptography cannot supply: an **independent valuation**. The borrower
provides the figure and gains by inflating it. The tractable form is attesting a licensed valuer as
we attest notaries, or reading public auction results.

Foreclosure uses existing institutions — judicial enforcement (*Ejra-ye Ahkam*, اجرای احکام) and
public auction (*Mozāyedeh*, مزایده) — with irrevocable assignment
(*Vekālat-nāmeh-ye Belā-'Azl*, وکالت‌نامه بلاعزل) signed at the start, a form courts recognise.
**If valuation cannot be made independent we ship identity and title without lending.**

**Delivered:** an audit report and fixes; live contracts and a wallet reading a real passport;
evidence a person can register, transact and leave unconnected; a title registered by a
proven-licensed notary, the property undisclosed.


---

## 3. Technical feasibility *(299/300 words)*

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

## 4. Scalability *(298/300 words)*

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
rather than a second codebase. Notaries scale the same way: proving membership of the licensed set
costs the same whether that set holds ten or ten thousand.

**Every user brings their own capacity.** Proofs are made on the person's phone and checked by the
chain, so there is no shared component that saturates: a thousandth user costs the same as the first.
The reserve grows by adding deposits, needing no protocol change and nobody's permission, and its
assets are diversified so capacity is not gated on the depth of any single one. What limits lending
volume is the supply of independently valued properties, not anything technical.


---

## 5. Resilience to censorship *(299/300 words)*

**What can be blocked** is network access to the chain and the registries the property layer reads.
**Nothing else offers a lever:** no server to seize, no operator to coerce. Registration has no
approval step, so nothing can be ordered withheld, and exclusion **fails open** — someone pressured
into inaction blocks nobody, because the newest state stays valid indefinitely. Most systems get
this backwards; here doing nothing is the safe default. Nor can anyone be quietly dropped:
exclusion demands an affirmative act citing a stated reason, recorded permanently.

Chain access runs over ordinary HTTPS to any endpoint the user supplies, and is costly to
distinguish from other web traffic.

**App-store delisting is among the weakest levers against us.** Sanctions already keep Google Play
largely unavailable to Iranian users, so that market runs on local stores and direct installation:
sideloading is the existing norm, not a habit we must teach. We chose React Native for that reason —
it compiles to a standard Android package that installs from a file, passed between phones or over a
messaging app, with no store, no account, no record of who downloaded it. A store can be delisted; a
file cannot be recalled once it spreads. iOS lacks this path, so Android leads.

A user cut off entirely is still not trapped: they can reclaim their deposit directly from the
chain (section 6).

**Blocking the registries degrades the system rather than stopping it.** Identity and the shielded
pool read no state endpoint — only the passport chip and the chain — so cutting the registry costs
property functions while leaving identity and private transfer intact.

**What we cannot engineer away** is coercion: a seized phone whose holder is made to unlock it.
Biometric gating and holding no identity in the clear limit that damage without solving it.

---

## 6. User security measures *(298/300 words)*

**Nothing identifying is published.** An obvious design would store a fingerprint of a street
address; anyone could then fingerprint addresses from public records and find the match. Those
values are disguised so they cannot be searched.

**One secret, in hardware.** A single phrase sits in the phone's secure storage behind biometric
unlock, and every other key derives from it — spending keys derived, never stored. If hardware
backing cannot be confirmed, the wallet refuses to store it at all.

**The gap we disclose rather than let an auditor find: there is no recovery.** The phrase is
generated on the device, never shown, and kept out of cloud backup — a lost phone is a lost identity
and lost funds. Milestone 2 adds recovery that puts no key on anyone's server.

**A guaranteed way out.** Whoever deposited can always reclaim directly from the contract with the
key on their own phone — no approval, no operator, nothing working but the chain. The cost is that
this action publicly links the deposit to whoever reclaims it. Nobody makes that trade for them.

**Assumptions stated, not hidden.** The check proves someone holds a genuine passport, not that they
are trustworthy — and a person may hold several, limiting what excluding one achieves.

**Joining is now unobservable.** Registration used to publish a person's identity beside their pool
account, so it was visible that someone had joined. The proof now shows the passport is registered
without naming it; the one value published is shared by everyone.

**Verification over assertion.** We test by deleting a safeguard and confirming the test then fails,
rather than trusting a green result — which caught several real defects, including a test that had
quietly stopped checking.

**Audit first.** No real value at stake until independent review is complete and its findings are
fixed.


---

## 7. Keeping costs low *(299/300 words)*

**No infrastructure to run.** No backend, no database, no server holding user data — removing the
largest recurring cost and the largest liability together. Ethereum provides availability; the phone
does the rest.

**Optimise what recurs, accept what does not.** Every change is measured, and we reject those adding
cost to the frequent path however elegant: withdrawal is 43% cheaper than it was, and one redesign
was cancelled on measurement at 12% more expensive for a cosmetic gain. Registration cost we
accept — paid once per person, not per transaction.

**Transaction fees are the user's cost, so they are our problem.** Verification cost is fixed by
proof size, constant here however complex the computation behind it.

**Build on maintained open source.** We wrote no proving system, data structure or passport parser.
Where we briefly wrote one, we deleted it and asked the chain instead — less to maintain, and
impossible to drift out of agreement.

**One mechanism, two uses.** Blocking a sanctioned person and stopping a property being mortgaged
twice both reduce to publishing disguised identifiers anyone can check without learning what they
mean. Built once, used for both — half the code, one auditable thing, one fewer contract.

**The largest cost a borrower bears is the rate, and we cut less of it than disintermediation
implies.** Banks fund on insured deposits, the cheapest money there is. What genuinely goes is
branch overhead, the charter's capital charge and the premium a licensed few command. Iran's 30% is
mostly currency — negative in real terms against 40% inflation — so hard-currency credit is cheaper
in name only unless the borrower earns it.

**Grant funds go to audit, field work, devices and legal review** — what money alone unlocks. Field work dominates after audit: notaries, counsel per jurisdiction and cohort recruitment
are people-time in-country, not engineering.


---

## 8. Maintenance beyond the funding cycle *(294/300 words)*

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

**How it pays for itself.** The reserve earns a return whether or not a single mortgage is ever
written, and that — not lending — is what funds maintenance. We do not plan to depend on repeated
grants: this funding is for what cannot be self-funded, principally the audit.

**What actually recurs is narrow.** One thing genuinely needs attention over time: a government
portal changing its format, breaking the reader that indexes it. Everything jurisdiction-specific is
isolated behind one interface, so that repair is self-contained, local, and touches no cryptography —
a developer in-country can do it without us and without any key we hold.

**What happens if we stop.** The contracts are not upgradeable and have no administrator, so they
keep running with nobody at the controls; deposits, withdrawals and existing titles are unaffected by
our absence. The worst case is not loss but staleness — a stale reader blocks new titles while
leaving every existing balance and title reachable.

