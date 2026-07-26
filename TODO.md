# TODO — canonical tracker

This is the one place to park anything surfaced during work on this workspace: action items,
deferred work, noticed risks/simplifications, and open questions. Update it as you go — mark items
done in place rather than deleting the history, and add new findings under the relevant section as
they come up. Don't re-litigate anything under "Parked / superseded" without a reason — it was
dropped deliberately, not forgotten.

Originally produced 2026-07-25 via an 8-agent semantic re-read of the entire session transcript (all
assistant visible text, chronological from the session's true start) cross-checked against every
user message for supersession — see "Methodology" at the bottom. Updated same day after actually
running every build/test suite this doc originally only recommended running (see §1/§2.1), and again
2026-07-26 after a direct README/inline-comment sweep of ibiza's own tree found real gaps the
transcript scan had missed (§2.11).

**Scope honesty, so "self-contained" isn't overclaimed:**
- **ibiza**: every `.md` file and every inline `TODO`/`FIXME` in actual (non-vendored) source has
  been read directly, not just inferred from the transcript — see §2.11's methodology note.
- **`rarime-rn-sdk-main`** (the separate fork repo ibiza depends on): checked the same way on
  2026-07-26 — clean, nothing beyond the two low-priority `sod.ts` notes already listed under
  §2.11's "confirmed stale" bucket (that file is shared/forked between both repos).
- **`SPV`** (the submodule, `backend/contracts/lib/SPV`): **deliberately NOT absorbed into this
  doc.** It has its own large, separate tracking system (`docs/actionable/*.md` — its own
  equivalent of this file) and is under active daily development, including by a different,
  concurrent Claude Code session observed running against it live during this work (see §2.10).
  Duplicating SPV's own TODOs here would be stale within a day and isn't this doc's job — ibiza's
  §2.10/§2.6 entries about SPV are scoped to what ibiza itself needs from SPV, not a mirror of
  SPV's internal backlog.
- **This conversation**: the original 8-agent scan covered the full transcript up to 2026-07-25.
  Since then, findings from later turns (the SPV squash/push saga, the auth/permission-classifier
  resolution, the §2.11 sweep itself) were logged into this doc as they happened, in real time —
  not via a second formal re-scan of the same rigor as the first. Given the later turns were mostly
  execution/verification (running builds, pushing, fixing what broke) rather than open-ended
  design discussion, the risk of a missed notice is lower there than it was for the original
  38K-line transcript — but "every word re-scanned twice" would be an overclaim.

**"Fully self-contained" isn't a permanent state this doc can reach and then stay in** — SPV moves
daily and ibiza itself is still being built. Treat this as "accurate and thorough as of the update
timestamp above," not "complete for all time." Re-run the §2.11-style sweep periodically, not just
once.

**Not deleted yet** — the user's own condition for deleting this file ("after SPV is integrated")
isn't met: SPV has no mainnet deployment to integrate against yet (§2.10). Delete only once that
changes and real addresses get wired in, not before.

---

## 0. "its not launch phase only" — resolved

**This exact phrase does not appear anywhere in the assistant's output this session.** Verified two
ways: (1) a direct grep across the entire raw transcript file found zero occurrences outside the
user's own message quoting it; (2) all 8 independent scanning agents, each reading a different
chronological slice of every word the assistant said, were explicitly instructed to hunt for it and
none found it or a close variant.

Two candidate near-misses, both **not real matches**:
- "don't market it at launch" — from the now-parked card/Rain-vs-Baanx go-to-market discussion.
  Different meaning entirely (marketing timing, not permanence).
- SPV's `deploy/PRODUCTION-LAUNCH.md` — a pre-mainnet checklist file name. Not a claim about this
  project at all.

Best guess: misremembered, or from a different session. **Your instinct is right: nothing in this
session claims any part of this build is "launch phase only," and everything built (contracts,
circuits, wallet SDK) is designed as permanent/production infrastructure** — every UUPS-upgradeable
contract, the CRE daily-cron registry refresh, and the holder-tree design are all built for ongoing
operation, not a one-time launch.

---

## 1. Build & toolchain status (this machine, verified 2026-07-25)

| Ecosystem | Tool | Status |
|---|---|---|
| Foundry contracts | `forge build` + `forge test` | ✅ **140/140 tests pass** |
| CRE / Go workflow | `go build` (GOOS=wasip1 GOARCH=wasm) | ✅ **clean build**, `.wasm` artifact produced |
| Wallet / npm | `npm install` + `tsc --noEmit --strict` | ✅ **clean**, zero type errors |
| Noir circuits (`pp`, `withdraw_identity`, `title_holder`) | `nargo test`/`compile` | ✅ **50/50 tests pass**, both new circuits compile clean |
| Noir circuits (`register_identity`, `register_identity_light_td1`, `query_identity`, `query_identity_td1`, `noir_dl_lib`) | `nargo compile` | ✅ **all 4 variants compile clean** — `register_identity`'s full ~16k-line `noir_dl_lib` compile took ~12 min on this CPU (slow, not broken) |
| Noir proving | `bb` (native Barretenberg) | ❌ **SIGILLs** — this CPU (no AVX2/BMI2) can't run native `bb`. Use `bb.js` (WASM) for local proof-gen. |
| rarime-rn-sdk (Android) | JDK / Android SDK / NDK | ❌ **none installed** on this machine (no `java`, no `ANDROID_HOME`, no `ndk-build` found anywhere) |
| rarime-rn-sdk (iOS) | Xcode | ❌ not available (no Mac) |

**Correction to something said earlier this session:** an earlier turn justified editing
`RnNoirModule.kt` directly (native Android/Kotlin) on "we have NDK, i have done android work on this
machine." That's not true of *this* machine as of today — no JDK/SDK/NDK found. The edit itself is
low-risk (confirmed via bytecode inspection that the native `Circuit.prove(..., "honk", ...)` call
it wraps already exists and works) but has never been Gradle-built. Verify on a machine/CI that
actually has the Android toolchain before relying on it.

**"Everything the memory says must be done"** — there's no separate persistent memory file
(`/home/rico/.claude/projects/-home-rico-projects-app/memory/` is empty). This document plus
`backend/circuits/PP-NOIR-FUSION.md` are the durable record.

### Build commands (all now confirmed passing except the flagged exceptions above)
Paths below are relative to this repo's root (this file now lives in `ibiza/`, not above it).
```bash
cd backend/contracts && forge build && forge test          # 140/140 ✅
cd backend/cre/notary_registry && GOOS=wasip1 GOARCH=wasm go build ./...   # ✅ (WASM build tag - normal `go build` finds no packages, that's expected)
cd frontend/identity-wallet && npm install && npx tsc --noEmit --strict   # ✅
cd backend/circuits/pp && nargo test                        # ✅ 50/50
cd backend/circuits/withdraw_identity && nargo compile      # ✅
cd backend/circuits/title_holder && nargo compile           # ✅
cd backend/circuits/register_identity && nargo compile      # ✅ (slow, ~12 min on this CPU)
cd backend/circuits/query_identity && nargo compile         # ✅
```

---

## 2. LIVE open items — highest priority first

### 2.1 Dependency-freshness pass — RESOLVED (2026-07-25, this session)
Ran every build/test suite for the first time since the dependency bumps. Found and fixed real
breaks in every ecosystem except the Noir circuits (see 2.5) — none of this was cosmetic, every fix
below was caught by an actual failing build/test, not by inspection:

- **Foundry**: OZ 5.6.1 genuinely dropped `ReentrancyGuardUpgradeable.sol` (the transient-storage
  variant is stateless, so it collapsed into the plain non-upgradeable package) — `Entrypoint.sol`
  now uses `ReentrancyGuardTransient`. `UUPSUpgradeable` in 5.6.1 is also now a stateless re-export
  with no `_init` step — removed the now-nonexistent `__UUPSUpgradeable_init()` calls from
  `Entrypoint`/`RegistrySourceAnchor`/`TitleLedger`. `solidity-lib` 3.3.3's `RSASSAPSS.sol` needs
  `solady` (a new transitive dep, not previously vendored) — vendored it, added the remapping.
  `foundry.toml`'s `evm_version` was pinned to `"london"` (predates transient storage AND OZ's
  `mcopy`-using `Bytes.sol`/`Arrays.sol`) — bumped to `"cancun"`.
- **A real pre-existing bug in `TitleLedger.sol`**: `nextTitleId` had an inline `= 1` default —
  invisible for a UUPS-upgradeable contract, since inline state-variable initializers only run in
  the (never-used) implementation contract's own constructor-time storage, not the proxy's. The
  proxy's slot silently stayed `0` forever. Fixed: removed the inline default, set explicitly in
  `initialize()`. Caught by a real `assertEq(titleId, 1)` test failure, not by inspection.
- **Test bugs, several classes, all pre-existing (never caught because `forge test` had never been
  run this session before now)**: (1) `vm.prank`/`vm.expectRevert` consumed by an external-call
  argument evaluated inline (`anchor.grantRole(anchor.REGISTRY_POSTMAN(), postman)` — the getter
  call consumes the single-shot cheatcode before the real call executes) — fixed across
  `RegistrySourceAnchor.t.sol`, `TitleLedger.t.sol`, and 5 tests in `HolderRegistration.t.sol` by
  hoisting the external-call argument into a local variable first. (2) `vm.deal(address(this), X)`
  paired with `vm.prank(entrypoint)` — the `{value: X}` call actually draws from the *pranked*
  caller's balance, not the test contract's — fixed across 4 tests in `PrivacyPoolSimple.t.sol` by
  dealing the right address. (3) OZ 5.6.1's `ERC1967Proxy` now hard-reverts on empty init data by
  default (`ERC1967ProxyUninitialized`, a real security hardening against uninitialized-proxy
  MITM) — `HolderStateKeeper.t.sol`/`HolderRegistration.t.sol` used the old deploy-then-initialize-
  separately pattern; added a test-only `UnsafeTestProxy` that opts back into that (safe in a
  single-threaded test, not something to replicate in real deploy scripts).
- **Go**: `go.mod`'s `cron` capability was bumped to `v1.4.0`, which doesn't exist (only
  `v1.4.0-capdev.1`, not a stable tag) — the freshness pass conflated it with `http`'s real `v1.4.0`.
  Fixed to `v1.3.0`, cron's actual latest stable. Separately, `onSchedule`'s own cron-trigger
  parameter was named `payload *cron.Payload`, colliding with a same-scope local `payload := ...`
  a few lines later — a genuine pre-existing naming bug, never caught because nothing had compiled
  this function before. Fixed by renaming the unused parameter to `_`.
- **npm**: `typescript` was bumped to `~7.0.2`, but `@li0ard/tsemrtd` (a real, used dependency —
  MRZ parsing) hard-peer-requires `typescript ^5.0.0` even at its own latest version; there's no
  newer `tsemrtd` release that lifts this. Pinned back to `~5.9.3` (latest 5.x).
- **`expo-file-system` v57 breaking rewrite**: the entire `documentDirectory`/`getInfoAsync`/
  `createDownloadResumable`/`readAsStringAsync` string-path API was replaced with a `File`/
  `Directory`/`Paths` class-based API. Rewrote `identity-wallet/src/sdk/RnNoirModule.ts` (trusted-
  setup + circuit-bytecode download/cache logic) against the new API.
- **`@noble/hashes` v2 restructuring**: `/sha1`, `/sha256`, `/sha512` subpath exports no longer
  exist — `sha256`/`sha224`/`sha384`/`sha512` consolidated into `/sha2.js`, `sha1` moved to the
  deprecated-but-still-exported `/legacy.js`. Fixed the two import lines in
  `identity-wallet/src/sdk/helpers/HashAlgorithm.ts`.

**None of this was silently "made to compile" — every fix is a genuine correction to either the
dependency pin or the calling code, verified by the relevant test suite going from red to green.**

### 2.2 `query_identity` circuit wiring — ALREADY DONE, this TODO item was stale
This session's own multi-agent transcript scan (see Methodology) flagged this as an open gap, citing
the state of the code at the point in the transcript each agent was reading. **Direct verification
today (2026-07-25) shows it was completed later in the same session, just not narrated as such in a
way the scan could see:**
- `noir_dl_lib/src/query.nr`'s `identity_state_verifier` computes leaf position as
  `Poseidon2(pk_passport_hash, sk_iden_hash)` and value as
  `Poseidon3(dg1_commit, identity_counter, timestamp)` — structurally identical in shape to
  `HolderStateKeeper.sol`'s `Poseidon2(documentKey, holderRoot)` / `Poseidon3(dgCommit, seq,
  timestamp)`, and `documentKey`/`holderRoot` are exactly `passport_.publicKey`/the identity key by
  construction on the Solidity side.
- `identity-wallet/src/sdk/Rarime.ts`'s `generateQueryProof` (line ~277) already sources
  `identity_counter` from `bond.seq` (`toPaddedHex32(bond.seq)`, comment: "holder tree: leaf
  supersession seq (== circuit identity_counter)"), `timestamp` from `bond.issueTimestamp`, and
  `id_state_root`/`siblings` from a real SMT proof against `HolderStateKeeper` — **not** from
  upstream's `getPassportInfo`. It also explicitly checks `bond.status !== DocStatus.Current` and
  throws before even attempting to prove, as a client-side pre-check on top of the cryptographic
  enforcement (a revoked/superseded document's on-chain value no longer equals the 3-element hash
  the circuit reconstructs, so a stale proof attempt would fail the SMT check anyway even without
  this guard — the guard just fails faster/friendlier).

No circuit or wallet change was needed. Removing this from the open-items list.

### 2.3 Single-seed SPOF — native recovery design, unsolved
Flagged twice, explicitly, as a catastrophic (not cosmetic) risk: the enclave-rooted key derivation
means one device seed derives both `sk_identity` AND Privacy Pool note keys. Losing the device loses
everything, with no recovery path — `unforgettable-sdk` was evaluated and rejected (deepfake/liveness
problems with its WebView biometric capture, never resolved even after four specific unanswered
vendor questions about anti-spoofing). Standing position: "the recovery gap is real but unsolved — it
deserves its own native design pass, not an unforgettable import." No design work has started. This
is a genuine product/design decision, not something to make unilaterally in a build-fixing pass.

### 2.4 Wallet-side Honk proving integration (P4) — the biggest remaining build item
Confirmed the vendored `noir.aar` in the `rarime-rn-sdk` fork already supports Honk proving;
`RnNoirModule.kt`'s `proveHonk` + the TS bridge were added and pushed (Android side; iOS/`Swoir` not
even inspected — no Xcode/Mac). **Still completely unwritten: the wallet-side code that assembles a
`withdraw_identity` witness** (existing-note state-tree membership, identity-ASP tree membership via
`postman/identityAsp.ts`, commitment/nullifier computation, change-note construction) from a
discovered note and calls the new `proveHonk`. This is real, security-sensitive cryptographic wiring
— deliberately not attempted as a rushed addition to this build-fixing pass; give it its own focused
session with the same "verify every step" discipline used for the fixes in §2.1.

### 2.5 `nargo` deliberately NOT upgraded — CONFIRMED CORRECT (2026-07-25)
`nargo` is 24 releases behind (`1.0.0-beta.1` → `1.0.0-beta.25`). This session's dependency-freshness
pass had bumped `poseidon` (v0.1.0→v0.3.0), `noir_sort` (v0.2.0→v0.4.0), and `noir-ripemd160`
(v0.0.2→v0.0.4) on the theory that the specific functions this tree calls were unchanged. **Running
`nargo test` today proved that theory wrong**: all three bumped versions fail to even *parse* under
our pinned `nargo 1.0.0-beta.1` (newer slice-reference syntax `@[]`, leading-`::` absolute-path `use`
statements — both post-beta.1 language features), regardless of which functions are actually called,
because Noir type-checks the whole package, not just the call sites in use. **Reverted all three back
to their original, confirmed-working pins.** This makes the original "don't bump nargo, it's a
separate, larger task" call not just a reasonable deferral but an empirically confirmed necessity —
bumping any of these libraries for real requires bumping `nargo` first.

### 2.6 Notary-registry: real-world data + real identity binding
Two genuinely separate gaps, both explicit operator TODOs, neither guessed at:
- The exact `data.gov.ua` bulk-export URL and the `NotaryRecordXML` field-tag schema are placeholders
  pending a real downloaded sample — `main.go`'s own header says so.
- Even once the registry root is anchored on-chain, there's still no cryptographic/legal binding of
  a *specific* notary's real-world identity to a specific address — `bindNotaryAddress` is
  authorization-consistent now (gated by `REGISTRY_POSTMAN`) but that only fixes *who* can assign
  the binding, not *how* a real notary proves they are who they claim. **Relevant, unresolved
  external input received today**: Ukraine's public notary register verifies *licensure* only, not
  general individual identity — there's no public API for verifying an arbitrary person's identity;
  that goes through Diia/BankID/qualified e-signatures instead. A UK-solicitor-multisig-as-PoA
  model was also raised as a possible binding mechanism, with real, unresolved cross-jurisdiction
  legal questions (does a blockchain multisig satisfy PoA requirements under England & Wales vs.
  Ukrainian law, is the electronic-signature framework recognized, does the notary accept this form
  of execution) — **not legal advice, needs real counsel review before being relied on.**

### 2.7 CRE Go module compatibility — RESOLVED (2026-07-25)
`go build` (with the required `GOOS=wasip1 GOARCH=wasm` — the workflow has a `//go:build wasip1` tag,
which is *why* a plain `go build ./...` previously reported "matched no packages") now succeeds
clean, `.wasm` artifact produced. See §2.1 for the two real bugs this surfaced and fixed (`cron`
version, `payload` shadowing).

### 2.8 Money-transmitter-licensing research — abandoned mid-flight, unconfirmed claim left standing
`COMPLIANCE-THESIS.md` asserts the fleet/family-plan model "dissolves the large-purchase question"
re: money-transmitter exposure. Deep research into whether that claim actually holds (FinCEN
31 CFR 1010.100(ff)(5) analysis) was still in progress when the user parked the whole card/compliance
thread. **If that thread is ever resumed, treat this specific claim as unconfirmed.**

### 2.9 Notes / smaller LIVE items, not yet picked up
- PP SDK interop: decide whether byte-identical interop with Privacy Pools' *official* SDK/web app
  matters, or whether self-consistency within this fork is sufficient. Never explicitly decided.
- `privkey % FIELD` reduction convention in `notes.ts` only justified "by construction," never
  empirically checked against Privacy Pools' actual SDK output.
- ECDSA (8 tests) and recursive-proof (4 tests) Noir suites in the migrated rarime tree have never
  been run — deliberately deferred as a cost issue, suited to a dedicated CI/background job.
- `bitcoin.nr` is orphaned dead code — `lib.nr` never declares `pub mod bitcoin;`. Pre-existing, low
  priority.
- No backend endpoint exists yet to produce a revocation signature — `revokeDocument` takes it as a
  required manual/external input.
- Whether the repeated-biometric-prompt UX fix (don't require re-auth every access after the first
  in a session) was actually implemented in `root.ts` is unverified — worth a direct check.
- Efficiency backlog, never revisited: Poseidon2 uniform swap, tree-depth tuning,
  recursion/aggregation, public-input packing, shared-SRS reuse across provers.
- Tier-2 feature backlog: ERC-4337 smart-account + LP-funded paymaster, stealth-address withdrawals
  (ERC-5564), soft identity-label on notes for recovery only (not a withdrawal gate).
- Whether this fork must interoperate with the *live* Rarimo protocol (forces circomlib-Poseidon) or
  is fully self-contained (Poseidon2-everywhere becomes possible) was never resolved.
- Yield-accrual destination for the family-plan LP model (LP itself vs. protocol treasury) was never
  decided.
- Whether the PP core Forge suite should include ERC20 (`PrivacyPoolComplex`) and `ragequit` paths
  was never decided — currently only ASP-anchor-specific tests exist for the forked PP core.

### 2.10 SPV integration — investigated today, genuinely blocked (not a build-fix problem)
Full investigation of the current SPV repo (`/home/rico/projects/SPV`) against the paused
`PP-SPV-BUFFER-DESIGN.md`/`SpvTreasuryAdapter.sol`/`ICreditLine.sol`/`ISpvVenue.sol` design:

- **The two previously-unresolved factual questions are now answered.** `LevManager.setVenueAllowed`
  really was removed (commit `82953c6`, 2026-07-02, "harden(YB): rip out rotatable governance"),
  replaced by a one-shot `init(...)`, gated `venuesFrozen` — but this doesn't affect ibiza's code,
  since `ISpvVenue.sol`/`SpvTreasuryAdapter.sol` never referenced `setVenueAllowed` in the first
  place. `Basket.mint`'s token acceptance **is** a hard, deploy-time-fixed whitelist (10/11 basket
  stables, checked via `Aux.toIndex`/`aux.tokens`) — contrary to `ISpvVenue.sol`'s comment, which is
  only accurate about *access control*, not *token acceptance*. Fix that comment next time
  `ISpvVenue.sol` is touched.
- **The existing `ICreditLine`/`ISpvVenue`/`SpvTreasuryAdapter` interfaces are still structurally
  compatible with SPV's current `HEAD`** — `Vogue.deposit/withdraw` and `Basket.mint` signatures
  match exactly, no rework needed on ibiza's side despite SPV's ~daily commit cadence (56 commits in
  the last 7 days as of this check).
- **The real blocker: SPV has not deployed to mainnet.** `deploy/PRODUCTION-LAUNCH.md`'s Phase 1
  (L1 contract deploy) and its entire pre-mainnet gates checklist are still unchecked. There are no
  real addresses to wire into `SpvTreasuryAdapter`'s immutable constructor params yet — "integrate
  with SPV" in the sense of pointing at live contracts is not something this session (or any amount
  of code-writing) can complete right now. **This is the reason TODO.md is not being deleted** — the
  user's own stated condition for deletion isn't met, and can't be met by writing more code; it's
  gated on SPV's own deployment timeline.
- **What WAS achievable today and is now done**: built a real `AaveCreditLine.sol` implementing
  `ICreditLine` against Aave V3's actual `IPool` interface (not hardcoded to any specific chain's
  Aave deployment — the target chain isn't known yet either, since SPV hasn't picked one; the pool/
  WETH addresses are constructor params, wire in the real ones once that's decided). Wraps/unwraps
  native ETH at the WETH boundary (Aave's `IPool` is ERC20-only), tracks locally-drawn principal
  debt (not Aave's own accruing variable-debt balance — see the contract's own header for why),
  owner-gated collateral supply/withdraw, single-designated-caller-gated borrow/repay. 18 new tests,
  all passing, against a real (not stub) mock Aave pool + WETH that actually custodies value and
  enforces a collateral/debt ledger. This closes the "`ICreditLine` interface-only, unwired" gap
  independently of SPV's own readiness — the credit-line backstop no longer needs SPV to exist at
  all, only a real Aave deployment (which does exist, on every chain SPV might plausibly launch on).
- When SPV does deploy: (1) wire `SpvTreasuryAdapter`'s constructor to the real `Vogue`/`Basket`
  addresses, (2) re-verify `Vogue.deposit/withdraw`/`Basket.mint` signatures one more time
  immediately before wiring (SPV's cadence means a report from today isn't a permanent guarantee),
  (3) deploy `AaveCreditLine` with the real Aave Pool/WETH addresses for whichever chain SPV
  launches on, (4) size the buffer/sweep/backstop parameters (still placeholder defaults).

**2026-07-26 update — SPV published + wired as a real dependency, still not "integrated" in the
addresses-wired sense (still gated on §2.10's mainnet-deploy blocker above):**
- `github.com/quidmints/SPV`'s `main` was 707+ commits stale (a different, concurrent Claude Code
  session was actively developing SPV locally at the same time this was being investigated — real
  live-race risk, handled by re-checking HEAD immediately before acting, not assuming the earlier
  snapshot still held). Per direction: squashed local SPV's full history to a single fresh commit
  (`git commit-tree` from the current tree, no parent) and force-pushed *only that one commit* as
  `main` — the full internal commit history (716 commits as of the squash) stays local-only, never
  pushed. Also confirmed `.env` was already correctly gitignored (`evm/.env` in the root
  `.gitignore`, pre-existing, no leak) and added `.claude/` to SPV's `.gitignore` (local session
  state, wasn't tracked but also wasn't excluded).
- `backend/contracts/lib/SPV` is now a **real `git submodule`** pinned to that squashed commit
  (`forge install`/`git submodule add` against `quidmints/SPV`, then a `SPV/=lib/SPV/evm/src/`
  remapping added to `remappings.txt`) — supersedes an earlier same-day plain-file-copy vendor
  attempt at the same path, removed in favor of the submodule. Confirmed this doesn't affect
  ibiza's own `forge build`/`forge test` (still 140/140) since nothing in ibiza's `contracts/`/
  `test/` imports from it yet — Forge only compiles the reachable-from-src/test closure, so the
  submodule sits there as real, pinned, importable reference/future-integration material without
  pulling in SPV's own large transitive dependency tree (Uniswap v4-core/v4-periphery, solmate)
  that would be needed to actually *compile* SPV's contracts, which nothing here needs to do.
- Auth note for next time: this machine's default SSH key (`id_ed25519`) authenticates as
  `tobaccorico`, who does NOT have write access to `quidmints/*`. `~/.ssh/id_edu` is the key
  actually scoped to the `quidmints` account — use `git -c core.sshCommand="ssh -i ~/.ssh/id_edu"`
  (or a per-push `GIT_SSH_COMMAND` env var) for any future push to `quidmints/ibiza` or
  `quidmints/SPV`, rather than a PAT.

### 2.11 Sweep of per-folder READMEs/docs/inline comments — real gaps this doc had missed (2026-07-26)

Prompted by a direct challenge: this doc was synthesized from a transcript scan, not from reading
every README/doc/inline-TODO in the actual repo. Did that — grepped every `.md` file and every
`TODO`/`FIXME` in actual (non-vendored) source across the whole tree. Found real, previously-
uncaptured items, plus confirmed some comments were just stale (already-done work never updated in
the text) rather than live gaps. Sorting into both buckets so nothing gets re-litigated as if it
were still open, and nothing genuinely open stays hidden in a comment nobody re-reads:

**Genuinely still open, now added here for the first time:**
- **`App.tsx`'s `CONFIG` has literal zero-address placeholders**
  (`stateKeeperAddress`/`registerSimpleContractAddress`/`poseidonSmtAddress`/
  `holderRegistrationAddress` all `0x000...000`), with its own inline
  `// TODO(fork wiring): point these at OUR deployed HolderStateKeeper / HolderRegistration`
  still present. Same root cause as the rest of this doc's deployment-blocked items (nothing has
  been deployed anywhere yet) — but worth naming the exact spot where that blocker actually bites,
  since this is the file someone would edit the moment contracts get deployed.
- **`app.plugin.js`'s Android `flatDir` path is very likely wrong now.** It still points at
  `../../android/libs` — the old "autolinked sibling module" layout from before `rarime-rn-sdk`
  became an npm/GitHub dependency. The AAR now lives at
  `node_modules/@rarimo/rarime-rn-sdk/android/libs`, not a sibling directory two levels up. Never
  updated when the architecture changed; would need fixing before an Android device build, and
  wasn't caught earlier because no device build has been attempted this session (no NDK/SDK on
  this machine — see §1).
- **NFC passport scanning is not implemented anywhere in the wallet.** `identity-wallet`'s own
  README flags this ("Passport NFC scanning is not in the rarime SDK — add an NFC reader to
  produce the raw dataGroup1/sod bytes"); confirmed no NFC code exists in `src/`. Without it there
  is no way to actually populate a `RarimePassport` from a real physical passport — everything
  downstream (registration, query proofs) currently has to be fed hand-constructed test data. This
  is a real, load-bearing gap for the wallet ever being usable end-to-end on a real device, and it
  wasn't in this doc until now.
- **The Honk verifier *contracts* for `withdraw_identity` and `title_holder` have never been
  generated.** `nargo compile`/`nargo test` (confirmed clean this session, §1) only prove the
  circuit logic itself compiles and its constraints are satisfiable — they don't produce the
  on-chain `INoirVerifier`-shaped Solidity contract PP/TitleLedger actually call `.verify()` on.
  That needs the `bb` toolchain's contract-codegen step (`bb write_vk_ultra_keccak_honk` +
  `contract_ultra_honk`, per the P0 spike's own findings), which needs either native `bb` (SIGILLs
  on this machine, no AVX2) or `bb.js` (WASM — works, but wasn't run against these two real
  circuits this session, only against the original trivial P0 spike circuit). Until this runs,
  `State.WITHDRAWAL_VERIFIER`/`TitleLedger.TITLE_HOLDER_VERIFIER` have no real contract to point at.
  `TITLE-LEDGER-DESIGN.md`'s own "Open gaps" section flagged this for `title_holder` specifically;
  it applies equally to `withdraw_identity` and wasn't previously called out as its own item here.
- **Concrete suggestion for the notary-to-address binding gap (§2.6), from
  `TITLE-LEDGER-DESIGN.md`'s own "Open gaps" section**: reuse rarime's own passport-verification
  flow for the notary's own identity — the notary proves control of their own passport-registered
  `holder_root`, cross-checked by name/registration-number/region against the notary registry.
  Not built, but a concrete mechanism rather than an open-ended question.

**Confirmed stale — already resolved, comment/doc text just never got updated (no action needed,
listed so nobody "fixes" something already fixed):**
- `lean_imt.nr`'s "DEV-MACHINE TODO: differential-test this... before trusting it for real value"
  comment — the differential testing it's asking for is done (46 fuzzed vectors, confirmed passing
  `nargo test` today). Comment corrected in place.
- `identity-wallet/README.md`'s "the circuits (TODO)" and "Wiring TODOs for true multi-document"
  section (query circuit fork, `HolderRegistration.registerDocumentViaNoir` wiring) — both
  resolved (query circuit confirmed compatible-as-is per the README's *own* table row 12 and
  `HOLDER-TREE-NOTES.md`; the registration wiring confirmed done via direct read of `Rarime.ts`/
  `IdentityVault.ts`/`HolderContracts.ts`). The README is otherwise stale throughout (still
  describes the old autolinked-sibling native-module setup, not the current npm-dependency one) —
  worth a real editing pass next time this file is touched, not urgent on its own.
- `HolderTree.ts`'s `HolderTreeOps` interface + `UNIMPLEMENTED_HOLDER_TREE` constant — **dead code,
  not a live gap.** Nothing implements or calls this interface; the real, actually-wired
  implementation is `HolderContracts.ts` + `IdentityVault.ts` (confirmed: `getHolderDocuments`
  already provides the "enumerate documents under a holder root" capability `listDocuments` was
  meant to add). Safe to delete `HolderTreeOps` entirely next time that file is touched — flagged
  here so it doesn't get mistaken for still-needed unfinished work.
- `sod.ts`'s two `// TODO: maybe move remove` / `/** TODO: mb remove */` comments — low-confidence
  self-notes, not describing missing functionality. Low priority; harmless as-is.

---

## 3. Parked / superseded — do not re-litigate without a reason

- **Card/BaaS/Rain/Baanx/EMI/KYC/MiCA/GENIUS compliance thread** — paused ("forget all the card
  stuff for now"). Lives on in `COMPLIANCE-THESIS.md`/`IDENTITY-COMPLIANCE-CARD-TODO.md`/`legal.md`.
  Includes the abandoned money-transmitter research (2.8) and the Blend-protocol identity-disclosure
  design, explicitly overruled on privacy grounds.
- **EUDI Wallet Core native binding** — deferred/dropped as a hard dependency; the format gap
  (rarime's ZK-VP proof only satisfies EUDI verifiers accepting that profile) never resolved.
- **AirGap two-device / Knox kernel-rooted provisioning** — dropped. AirGap ships no permanently-
  rooted airgapped-phone image at all; that would have been fully bespoke work.
- **unforgettable-sdk** — fully dropped (deepfake/liveness concerns, never resolved by the vendor).
  Still present on disk at `unforgettable-sdk-main/`, unused.
- **ILP / Interledger** — parked as a grant-funded side bet, not core roadmap.
- **Identity-bound PP withdrawal** — proposed then retracted (tension with PP's privacy point;
  compliance is the wrong layer). The *soft* version (recovery-only identity label, never a
  withdrawal gate) remains a live backlog idea, see 2.9.
- **Twitter/Puppeteer scrape** — deferred with "I'll explain later," never explained.
- **companion/, vault/, qr-protocol/ folders** — stale leftovers from dropped AirGap/card
  scaffolding; kept as reference material rather than deleted.
- **PP↔SPV treasury-buffer integration** — moved from "paused, revisit later" to "actively re-
  verified compatible, blocked only on SPV's own mainnet deployment" — see 2.10, no longer purely
  parked, tracked as a live item now.

---

## 4. Notable risk-reductions / simplifications applied this session

- WASM (`bb.js`) proving was seriously considered for mobile and correctly ruled out: Hermes has
  never supported WebAssembly, and `bb.js` is browser-first infra regardless. Extending rarime's
  existing *native* proving bridge needed zero new dependencies once it was found the vendored
  `noir.aar` already supports Honk.
- A hand-rolled reimplementation of `@zk-kit/lean-imt` was caught and replaced with the real,
  audited npm package.
- `RegistrySourceAnchor`/`TitleLedger` were caught being inconsistent with the codebase's UUPS-
  upgradeable convention and converted; `IdentityAspLeafRegistry` deliberately kept non-upgradeable
  with a documented rationale.
- IPFS was dropped entirely from the notary/ASP registry design in favor of on-chain leaf calldata +
  on-chain root recomputation — closes a real soundness gap and removes an external dependency.
- Standalone on-chain Honk verification requires the keccak-transcript prove/verify commands
  specifically (found by testing) — promoted from a deferred efficiency tweak to a hard requirement.
- A live UltraHonk soundness vulnerability in `bb < 0.82.0` was caught via `bbup`'s installer
  warning, avoiding a stale pin.
- Several real Solidity bugs caught and fixed pre-emptively while writing this session's code: an
  external `this.`-self-call silently changing `msg.sender` for a role check; manual byte-offset
  ABI-slicing of a dynamic-array tuple; a locator string exceeding an IPFS-CID length bound;
  `setEncumbered` having no authorization check; a revocation-signature domain-separation bug that
  would have permanently bricked revocation via deterministic-ECDSA replay collision.
- **2026-07-25 build-verification pass** (this update): every dependency-freshness-pass regression
  and every pre-existing-but-never-exercised bug listed in §2.1 — 3 Solidity API-migration fixes,
  1 real upgradeable-storage bug (`TitleLedger.nextTitleId`), 3 classes of test-file bugs (cheatcode-
  consumed-by-argument-evaluation, wrong-address-dealt, hardened-proxy-needs-init-data) across 6
  test files, 2 real Go bugs (wrong version pin, parameter-name collision), 1 npm peer-dependency
  fix, and 2 full API-surface rewrites for major dependency version bumps (`expo-file-system` v57,
  `@noble/hashes` v2). All caught by actually running the relevant build/test command, none by
  inspection alone — every fix is verified, not assumed.

---

## Methodology

Built 2026-07-25 by extracting every assistant `text` content block from the raw session transcript
into 8 chronological slices, plus a reference file of all real user messages tagged by transcript
line number. Each slice was scanned by an independent agent for action items, deferred-but-unlabeled
items, and loosely-worded notices — cross-checked against the user-messages reference to exclude
anything later overruled. `thinking` blocks were checked and confirmed to carry no recoverable text.

Updated same day: every build/test command this doc originally only recommended was actually run;
findings folded in directly (§1, §2.1, §2.2, §2.5, §2.7, §2.10). §2.6 also folded in real-world
factual input received mid-session about Ukraine's notary register scope and UK/Ukraine PoA/notary
legal questions.
