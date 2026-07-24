# #2 — Noir/Honk unification of rarime + Privacy Pools (the coherent fusion)

**Decision (locked):** full **UltraHonk** migration of the *whole* stack — rarime identity circuits **and** PP
circuits on one **Noir 1.0 + Barretenberg (Honk)** toolchain. Complexity is accepted; the goal is the most
*correct and coherent* fusion, not the minimal port.

## Why Honk + one toolchain
- One **prover** binary, one **SRS**, one **verifier-codegen** pipeline on device — the real single-prover win.
- Faster client-side proving (Honk) — the on-device UX bottleneck.
- Future-proof (UltraPlonk/`BaseUltraVerifier` is the dying path); do the re-audit once, on the modern backend.

## The unified hash: circomlib-Poseidon (NOT Poseidon2)
The most *correct* choice, because it is the **audited, already-present** one:
- rarime's identity circuits already hash with circomlib-Poseidon and verify on-chain against
  `poseidon-solidity`; keeping it means **no hash change inside the complex, audited identity circuits**.
- The wallet (`src/pp/notes.ts`, `discovery.ts`) already uses `@iden3/js-crypto` (circomlib).
- On-chain we already vendored `poseidon-solidity` + `@zk-kit/lean-imt.sol` (circomlib).
- → **one hash across circuit + wallet + contracts, all audited/proven.** Poseidon2 would either fork the
  stack into two hashes (incoherent) or move rarime onto the **unaudited** `poseidon2-evm` (less correct).
- **Poseidon2 stays a deferred, uniform efficiency swap** — `noir-lang/poseidon` exposes both, so it's a
  one-line change everywhere *after* the coherent stack is proven and *if* proving time demands it.

> Determining unknown to confirm: whether our forked identity stack must interoperate with the **live
> Rarimo protocol** (passport/CSCA registrations, global identity SMT). If yes, circomlib is *forced* for
> rarime (reinforcing the above). If we are fully self-contained on our own `HolderStateKeeper`, Poseidon2-
> everywhere becomes *possible* — but still the less-audited option, so circomlib remains the recommendation.

## Coherent-fusion architecture (what "makes the most sense")
- **One circuits workspace** — rarime circuits (migrated to Noir 1.0) + `pp/` lib (this dir), both importing
  `noir-lang/poseidon` and a shared Merkle module (rarime SMT gadget + PP `lean_imt`), all over one hash.
- **One verifier interface on-chain** — PP drops its Groth16 `IVerifier`/`verifyProof(pA,pB,pC,[8])` and
  adopts rarime's **`INoirVerifier.verify(bytes proof, bytes32[] publicInputs)`**. Both stacks call the same
  Honk verifier ABI. This is the tangible contract-level fusion.
- **One on-chain Poseidon** (`poseidon-solidity`) serves both rarime's SMT and PP's LeanIMT.
- **One evidence registry (ERC-7812)** anchors both identity state roots and PP ASP roots (finishes idea C;
  #3 already anchors the ASP side).
- **Recursion available** (rarime ships `recursion.nr`) — Honk composes proofs, so identity+PP flows can be
  aggregated into one on-chain verify later if desired.

## Reuse map (lean on these; build almost nothing)
| Layer | Reuse (exists) | New |
|---|---|---|
| Circuit hash | `noir-lang/poseidon` (Poseidon1, circomlib) | — |
| Wallet hash | `@iden3/js-crypto` (already a dep) | — |
| On-chain hash + tree | `poseidon-solidity` + vendored `@zk-kit/lean-imt.sol` | — |
| LeanIMT circuit gadget | (no Noir lib) — PP `merkleTree.circom` is the spec | `pp/src/lean_imt.nr` ✅ ported |
| Commitment gadget | PP `commitment.circom` is the spec | `pp/src/commitment.nr` ✅ ported |
| Comparators / range / bits | Noir stdlib | — |
| Verifier (Honk) | `bb` codegen | — |
| Withdraw/ragequit logic | PP `withdraw.circom` is the spec | translate (Phase 2) |
| Passport primitives (rarime) | `zkpassport/noir-ecdsa`, `noir_rsa` | — |

## P0 — CONFIRMED GO (toolchain spike, run on this dev machine 2026-07-01)

**Toolchain installed:**
- `nargo 1.0.0-beta.1` via `noirup --version 1.0.0-beta.1` — matches rarime's pinned README version exactly.
- `bb.js@0.82.2` (WASM, npm) — **not native `bb`**. This machine's CPU (Intel Core i3-U330, SSE4.2 only, no
  AVX2/BMI2) segfaults the native `bb` binary (`Illegal instruction`). This is not a version problem — it's
  a hardware ceiling, and it's the **same ceiling mobile ARM chips have** (no AVX2), so `bb.js` WASM is
  actually the *correct* target anyway, not a workaround. `noir-lang/awesome-noir`-adjacent tooling and the
  wallet's own prover will use the WASM/portable backend in production, same as this spike.
- **Correction to the original plan:** do **not** match rarime's pinned `bb 0.66.0`. `bbup`'s own installer
  warns of a **critical UltraHonk soundness vulnerability in bb < 0.82.0** ("any Solidity verifier contracts
  must be regenerated using a patched version"). `bbup` auto-resolved `0.82.2` as compatible with
  `nargo 1.0.0-beta.1` — use that resolution method (`bbup` with no args, reading installed `nargo`), not a
  hardcoded version, whenever this is repeated.

**End-to-end loop closed (all empirically verified, not assumed):**
1. `nargo compile` — trivial circuit compiles clean under `1.0.0-beta.1`.
2. `nargo execute` — witness generation works.
3. `bb.js prove_and_verify_ultra_honk` — proof generated + verified via WASM, ~6s, exit 0.
4. `bb.js contract_ultra_honk` — generates a Solidity `HonkVerifier` whose interface is
   **`verify(bytes calldata _proof, bytes32[] calldata _publicInputs) external view returns (bool)`** —
   confirmed **identical in shape** to rarime's existing `INoirVerifier.sol`. The P3 interface-unification
   step is trivial, not an adapter.
5. **Load-bearing correction found by testing, not assumption:** the plain `_ultra_honk` prove/vk commands
   (Poseidon2/native-transcript, meant for in-circuit **recursive** verification) do **NOT** verify against
   `contract_ultra_honk`'s generated Solidity — deploying and calling `verify()` reverted `SumcheckFailed()`.
   Standalone on-chain (EVM) verification requires the **keccak-transcript variants**:
   `prove_ultra_keccak_honk` + `write_vk_ultra_keccak_honk`, paired with `contract_ultra_honk`. With that
   pairing, a real Forge test **deploys the generated verifier and calls `verify()` with a real WASM-produced
   proof → returns `true`**; a tampered public input correctly reverts.
   → **This promotes the old P6 "keccak-Honk verifier variant" from a deferred efficiency tweak to a P3
   functional requirement.** Always use the `_keccak_honk` prove/vk/verify commands when the target is a
   standalone Solidity verifier (i.e. every PP/rarime on-chain verifier in this fusion).
6. **Measured gas** (Forge `--gas-report`, trivial 1-public-input circuit): `verify()` alone ≈ **1,982,980
   gas**; deployment ≈ 6.56M gas / 30,216 bytes. This is real and non-trivial — materially higher than a
   Groth16 verify (~200–250k gas). Confirms the P3 "gas jumps materially" caveat with a real number instead
   of a guess; real circuits (bigger public-input counts) will cost more. This is a genuine trade the fusion
   makes for one-prover coherence — worth remembering when judging whether the union is worth it per-circuit.

**Scratch artifacts** (not committed — regenerate via the commands above; `/tmp` scratchpad is ephemeral):
Nargo project + witness, `bb.js` proof/vk (both transcript variants), generated `HonkVerifier.sol`
(non-keccak, fails on-chain — kept as a negative example) and `VerifierKeccak.sol` (the correct one), and a
Forge test proving both the positive and negative (wrong-input) case.

## P1 — gadget differential tests: CONFIRMED (2026-07-01)

Both `pp/` gadgets now compile under `nargo 1.0.0-beta.1` and pass real `nargo test` differential
tests against the exact on-chain functions PP will call:

- **`pp/src/lean_imt.nr`** — `lean_imt_inclusion` matches `@zk-kit/lean-imt.sol` (`LeanIMT.insert` +
  `.root()`) exactly, for a real 3-leaf tree, cross-checked via a Forge test using the vendored
  `PoseidonT3`/`LeanIMT.sol`. `nargo test`: **pass**.
- **`pp/src/commitment.nr`** — `commitment_hasher` matches `poseidon-solidity`'s `PoseidonT2/T3/T4` —
  the same functions `PrivacyPool.sol` itself calls for commitments/nullifiers. `nargo test`: **pass**.
- Two real bugs were caught by actually compiling (not just writing) the gadgets, both fixed:
  non-ASCII (em-dash) characters in comments are rejected by this Noir parser; and the import path
  for `noir-lang/poseidon` v0.1.0 is `poseidon::poseidon::bn254`, not `poseidon::bn254` (package
  `poseidon` re-exports `pub mod poseidon;`, which contains the `bn254` submodule).
- The library's own source confirms the design doc's central claim independently: `bn254.nr` states
  "Consistent with Circom's implementation" — not just asserted, now primary-sourced.

**Remaining for P1:** these are single hand-derived vectors, not fuzzed/randomized ones. Before
trusting `lean_imt_inclusion` for real value, add randomized (leaf, index, siblings, depth) vectors —
particularly the LeanIMT carry-up edge case (odd leaf counts at multiple levels) — cross-checked the
same way.

## Tracked gap: no exclusion (non-membership) path in the Noir SMT gadget

**The Noir circuit side has no exclusion path at all — `smt_verifier` in `smt.nr` only proves
membership.** (`noir_dl_lib/src/smt.nr:65-91`: takes `(root, leaf, key, siblings)` and always assumes
the claimed `leaf` value sits at `key`'s position; no aux-leaf params, no branch for an empty subtree
or a different key found on the path.) The on-chain Solidity side (`@solarity/solidity-lib`'s
`SparseMerkleTree.getProof`, vendored at `lib/solidity-lib/`) already returns full exclusion data
(`existence`/`auxExistence`/`auxKey`/`auxValue`) — so there's a working reference spec to port from,
same shape as the `pp/` gadget ports above, when this becomes needed.

**Does anything need it today? No — confirmed, not just assumed.** `HolderStateKeeper`'s
revocation/renewal never needed true exclusion: the document key stays a tree member forever, only
its value changes to a `Poseidon1(REVOKED)`/`Poseidon1(SUPERSEDED)` sentinel, so a query circuit that
reconstructs the claimed-current value (`Poseidon3(dgCommit, seq, timestamp)`) and does a plain
*membership-with-value* check against the current root will correctly reject a stale claim — no
exclusion proof required. This is proven directly (not just asserted) by
`test_leaf_value_matches_circuit_reconstruction` in `test/holder/HolderStateKeeper.t.sol`. (An earlier
version of `HolderStateKeeper.sol`'s NatSpec incorrectly called this "exclusion (non-membership)
proofs" — fixed to describe the real membership-with-value mechanism, 2026-07-02.)

**A real, separate, currently-unaddressed gap:** even with the Solidity-side property proven, nothing
today makes the *circuit* actually consume it. The forked `query_identity` circuit's only tree check
(`identity_state_verifier`, `query.nr:56-80`) still proves membership against the upstream
`id_state_root`/passport-commitment convention — it has not yet been rewired to reconstruct and check
against `HolderStateKeeper`'s value convention (`dgCommit`/`seq`/`timestamp`) at all. Until that wiring
happens, a revoked/superseded document's query proof isn't actually rejected end-to-end — the
cryptographic property holds on-chain, but nothing calls it. **Add to P2 (or a new P1.5): wire
`query_identity` to the holder-tree leaf convention**, as part of the circuit migration, not a
follow-on.

**When exclusion (true non-membership) WOULD be needed:** a real external-list check — e.g. "this
identity is not on a sanctions list" — is structurally a non-membership proof (the identity was never
added, not "added then revoked"). That's the one scenario that would actually require porting the
`smt_verifier` exclusion path above. See the separate identity-compliance/card-issuance TODO doc for
that workstream; it is NOT assumed to be in scope for the base Noir migration.

## Phased plan (remaining)
- **P0-remaining: rarime migration.** Migrate rarime circuits to Noir 1.0 syntax (mixed old/new generics
  found — `noir_dl_lib/src/big_curve/*` uses pre-`<let N: u32>` generics in places); bump `noir_sort`/
  `ripemd160` dependency tags to 1.0-compatible releases; regenerate verifiers with the **keccak-Honk**
  commands confirmed above; confirm identity register/query **still prove + verify on-chain**. ~16k lines of
  `.nr` source total (mostly `noir_dl_lib`'s signature-verification/bignum code) — this is the bulk of the
  remaining P0 work and the part not yet spiked.
- **P1-remaining:** randomized/fuzzed differential vectors (see above).
- **P2 PP circuit port.** Translate `withdraw.circom`/`ragequit` to Noir using these gadgets; pin public
  I/O ordering to what the contract reads from `publicInputs[]`.
- **P3 On-chain verifier unification.** Replace PP Groth16 verifiers with Honk (**keccak-transcript
  variant, confirmed required above**); swap `IVerifier`→`INoirVerifier` (confirmed drop-in shape);
  rewire `PrivacyPool`/`ProofLib` to `verify(bytes,bytes32[])`. Budget real gas per the measurement above.
- **P4 Wallet prover unification.** One bb.js-WASM Honk prover serves identity + PP (confirmed this is
  also the right backend for mobile, not just this dev machine); one SRS; witness gen from discovered
  notes (`src/pp/discovery.ts`) + reconstructed LeanIMT paths.
- **P5 Re-audit + differential equivalence.** Audit migrated rarime + new PP; assert old-Groth16-PP and
  new-Honk-PP agree on accept/reject; deposit→withdraw e2e.
- **P6 (deferred efficiency).** Poseidon2 uniform swap · recursion/aggregation · tree-depth tuning ·
  public-input packing.

## Status
- ✅ **P0 (spike): CONFIRMED GO.** Toolchain installed + working end-to-end incl. real on-chain verify.
- ✅ **P1 (gadgets): core differential tests CONFIRMED.** `pp/src/commitment.nr`, `pp/src/lean_imt.nr`
  compile and match on-chain Solidity vectors exactly (`nargo test`, 2/2 pass). Randomized vectors
  still open.
- ⏳ **P0-remaining (rarime migration)** is the next substantial dev-machine task — the bulk of the
  work, not yet started. P2–P5 follow.
