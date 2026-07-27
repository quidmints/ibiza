// Withdrawal witness assembler — the second half of sec. 2.1, and the step that makes withdrawing
// possible at all. Turns a discovered note + the two tree mirrors into the exact 20-input witness
// `backend/circuits/withdraw_identity/src/main.nr` expects, plus the 8 public signals
// PrivacyPool.sol reads out of ProofLib.WithdrawProof.pubSignals.
//
// SCOPE, deliberately: this builds and self-checks the witness. It does NOT call the prover.
// Proving is `NoirCircuitParams.fromName('withdraw_identity').proveHonk(...)` from
// @rarimo/rarime-rn-sdk, with the circuit registered by src/sdk/circuits.ts. That path is
// ANDROID-ONLY: the SDK's Android native module implements proveHonk (RnNoirModule.kt,
// proofType = "honk") but iOS hardcodes proof_type: "plonk". See TODO.md sec. 2.1a.
//
// Keeping assembly separate from proving is not a workaround, it is the right seam anyway: the
// witness is backend-agnostic, so it is testable TODAY against a Forge fixture with no device, no
// prover and no toolchain dependency, and it stays valid if the proving backend moves.
//
// PUBLIC SIGNAL ORDER IS PINNED by ProofLib and must not be reordered:
//   [0] new_commitment          [4] state_tree_depth
//   [1] existing_nullifier_hash [5] asp_root
//   [2] withdrawn_value         [6] asp_tree_depth
//   [3] state_root              [7] context

import {
  MasterKeys,
  NoteSecrets,
  commitment as commitmentHash,
  nullifierHash,
  withdrawalSecrets,
} from "./notes";
import { RecoveredNote } from "./discovery";
import { StateTree, MAX_TREE_DEPTH, FIELD } from "./stateTree";
import { IdentityAspTree } from "../postman/identityAsp";
import { RevocationWitness, REVOCATION_TREE_DEPTH } from "./revocation";
import { babyJub, Poseidon } from "@iden3/js-crypto";

/** The circuit range-checks `value`, `withdrawn_value` and `value - withdrawn_value` to 128 bits
 *  (main.nr step 2, via to_le_bits). Exceeding this yields a witness that cannot be proven, so it
 *  is rejected here with a real explanation instead. */
const MAX_VALUE = 1n << 128n;

export interface WithdrawWitnessParams {
  /** The unspent note being spent. Must come from discoverNotes(), not be hand-built. */
  note: RecoveredNote;
  /** Its leaf index in the state tree. Authoritative — see StateTree.leafIndexOf on why resolving
   *  by commitment is unsafe when the same commitment appears twice. */
  stateLeafIndex: bigint;
  /** Rebuilt + root-verified via loadStateTree(). */
  stateTree: StateTree;
  /** Rebuilt via loadIdentityAspTree(). */
  aspTree: IdentityAspTree;
  /** Seed-derived master keys — the change note MUST be derived from these to stay recoverable. */
  masterKeys: MasterKeys;
  /** The withdrawer's identity scalar, from the enclave-rooted seed. */
  skIdentity: bigint;
  /** How much to withdraw. The remainder carries into the change note. */
  withdrawnValue: bigint;
  /** From buildRelayedWithdrawal()/buildSelfWithdrawal() in ./relay. */
  context: bigint;
  /**
   * Non-inclusion witness for the revocation registry, from fetchNonRevocationWitness() in
   * ./revocation. Omit ONLY when the registry has revoked nobody: a freshly deployed registry has
   * root 0 and an all-zero witness proves absence for every key (pp/src/smt.nr's
   * test_exclusion_against_the_empty_tree pins that). Passing a hand-built witness here is how a
   * proof silently becomes unprovable, so prefer the fetch.
   */
  revocation?: RevocationWitness;
  /**
   * Which withdrawal this is FOR THIS LABEL, in the wallet's derivation convention.
   *
   * LOAD-BEARING, and the single most dangerous input here. discovery.ts re-derives change notes as
   * `withdrawalSecrets(keys, label, k)` where k counts withdrawals on that label in on-chain order.
   * Passing a k that does not match what discovery will later count produces a change note whose
   * secrets the wallet can never re-derive — the remainder becomes unspendable. Use
   * nextWithdrawalIndex() rather than supplying this by hand.
   */
  withdrawalIndex: bigint;
}

export interface WithdrawWitness {
  /** Noir input map, keyed by main()'s parameter names. Decimal strings — Noir accepts decimal or
   *  0x-hex for Field; decimal avoids any ambiguity about leading-zero padding. */
  inputs: Record<string, string | string[]>;
  /** ProofLib.WithdrawProof.pubSignals, in pinned order. */
  pubSignals: bigint[];
  /** The change note's secrets — persist/re-derive these; they own the remainder. */
  changeNote: NoteSecrets;
  /** The change note's commitment (public signal [0]). */
  newCommitment: bigint;
}

/**
 * The next withdrawal index for `label` under the wallet's convention, counted from notes that
 * discoverNotes() already returned. This is the SAME quantity discovery re-derives, computed the
 * same way, which is the point — hand-supplying it is how the remainder gets lost.
 */
export function nextWithdrawalIndex(notes: readonly RecoveredNote[], label: bigint): bigint {
  let k = 0n;
  for (const n of notes) if (n.kind === "withdrawal-change" && n.label === label) k += 1n;
  return k;
}

/**
 * holderRoot for a given identity scalar: Poseidon(babyJub.mulPointEScalar(Base8, sk)).
 *
 * Exported because the ASP tree is keyed by this value, so anything BUILDING a tree (the wallet,
 * the postman tooling, tools/build-withdrawal-fixture.js) needs the identical derivation. Having
 * one exported function rather than three re-implementations is what keeps them from drifting -
 * and it is the same value pp/src/holder_root.nr::extract_pk_identity_hash computes in-circuit.
 */
export function holderRootFromSk(skIdentity: bigint): bigint {
  return Poseidon.hash(babyJub.mulPointEScalar(babyJub.Base8, skIdentity));
}

/** Assemble (and self-check) the withdraw_identity witness. */
export function buildWithdrawalWitness(params: WithdrawWitnessParams): WithdrawWitness {
  const {
    note,
    stateLeafIndex,
    stateTree,
    aspTree,
    masterKeys,
    skIdentity,
    withdrawnValue,
    context,
    withdrawalIndex,
  } = params;

  // Empty-registry default: root 0, "the slot is empty", no siblings. Correct only because the
  // revocation tree is a sparse trie whose empty root is 0 - see this field's doc comment.
  const revocation: RevocationWitness = params.revocation ?? {
    revocationRoot: 0n,
    oldKey: 0n,
    oldValue: 0n,
    isOld0: 1n,
    siblings: new Array(REVOCATION_TREE_DEPTH).fill(0n),
  };

  if (revocation.siblings.length !== REVOCATION_TREE_DEPTH) {
    throw new Error(
      `buildWithdrawalWitness: revocation witness has ${revocation.siblings.length} siblings, ` +
        `circuit expects ${REVOCATION_TREE_DEPTH}`,
    );
  }

  // ── Value conservation, checked before anything expensive ──────────────────────────────────
  if (note.spent) throw new Error("buildWithdrawalWitness: note is already spent");
  if (withdrawnValue <= 0n) throw new Error("buildWithdrawalWitness: withdrawnValue must be > 0");
  if (withdrawnValue > note.value) {
    throw new Error(
      `buildWithdrawalWitness: withdrawing ${withdrawnValue} from a note worth ${note.value}`,
    );
  }
  if (note.value >= MAX_VALUE) {
    throw new Error("buildWithdrawalWitness: note value exceeds the circuit's 128-bit range check");
  }
  if (context <= 0n || context >= FIELD) {
    throw new Error("buildWithdrawalWitness: context must be a nonzero BN254 field element");
  }

  // ── Identity: derive holderRoot from skIdentity and check it is actually an ASP member ─────
  // Poseidon(babyJub.mulPointEScalar(Base8, sk)) — the same derivation as the circuit's
  // holder_root.nr::extract_pk_identity_hash and as RarimeUtils.getProfileKey, which is what makes
  // this cross-check meaningful rather than decorative. Catching a wrong sk_identity HERE turns an
  // unexplained proof failure into a named error.
  //
  // Computed inline from @iden3/js-crypto (a direct wallet dependency, and the SAME primitive
  // getProfileKey uses) rather than importing the SDK: this module is pure arithmetic, and pulling
  // in an RN package would make it unloadable outside React Native - which is exactly what
  // tools/build-withdrawal-fixture.js needs it to be.
  const holderRoot = holderRootFromSk(skIdentity);

  // ── State-tree membership ───────────────────────────────────────────────────────────────────
  const stateProof = stateTree.proof(stateLeafIndex, MAX_TREE_DEPTH);
  const leafAtIndex = stateTree.leaves[Number(stateLeafIndex)];
  if (leafAtIndex !== note.commitment) {
    throw new Error(
      `buildWithdrawalWitness: state leaf ${stateLeafIndex} holds ${leafAtIndex}, ` +
        `but the note's commitment is ${note.commitment}. Wrong index, or a stale tree.`,
    );
  }

  // ── ASP membership ──────────────────────────────────────────────────────────────────────────
  const aspProof = aspTree.proof(holderRoot, MAX_TREE_DEPTH);

  // ── Change note ─────────────────────────────────────────────────────────────────────────────
  const newValue = note.value - withdrawnValue;
  const changeNote = withdrawalSecrets(masterKeys, note.label, withdrawalIndex);
  const newCommitment = commitmentHash(newValue, note.label, changeNote);

  // Reconstruct the SPENT note's commitment exactly as the circuit does (main.nr step 1) rather
  // than trusting discovery's stored value — the circuit asserts this, so a mismatch is a witness
  // that cannot be proven, and it is far cheaper to find it here.
  const existingNote: NoteSecrets = { nullifier: note.nullifier, secret: note.secret };
  const recomputed = commitmentHash(note.value, note.label, existingNote);
  if (recomputed !== note.commitment) {
    throw new Error(
      `buildWithdrawalWitness: recomputed commitment ${recomputed} != recorded ${note.commitment}. ` +
        "The note's value/label/secrets disagree with the on-chain commitment.",
    );
  }

  const existingNullifierHash = nullifierHash(note.nullifier);

  const pubSignals = [
    newCommitment,
    existingNullifierHash,
    withdrawnValue,
    stateProof.root,
    BigInt(stateProof.depth),
    aspTree.root,
    BigInt(aspProof.depth),
    context,
    revocation.revocationRoot,
  ];

  const dec = (v: bigint) => v.toString(10);

  const inputs: Record<string, string | string[]> = {
    // public
    new_commitment: dec(newCommitment),
    existing_nullifier_hash: dec(existingNullifierHash),
    withdrawn_value: dec(withdrawnValue),
    state_root: dec(stateProof.root),
    state_tree_depth: dec(BigInt(stateProof.depth)),
    asp_root: dec(aspTree.root),
    asp_tree_depth: dec(BigInt(aspProof.depth)),
    context: dec(context),
    revocation_root: dec(revocation.revocationRoot),
    // private — existing note
    value: dec(note.value),
    label: dec(note.label),
    nullifier: dec(note.nullifier),
    secret: dec(note.secret),
    state_leaf_index: dec(stateProof.leafIndex),
    state_siblings: stateProof.siblings.map(dec),
    // private — change note
    out_nullifier: dec(changeNote.nullifier),
    out_secret: dec(changeNote.secret),
    // private — identity ASP
    sk_identity: dec(skIdentity),
    asp_leaf_index: dec(aspProof.leafIndex),
    asp_siblings: aspProof.siblings.map(dec),
    // private - revocation non-inclusion
    revocation_old_key: dec(revocation.oldKey),
    revocation_old_value: dec(revocation.oldValue),
    revocation_is_old0: dec(revocation.isOld0),
    revocation_siblings: revocation.siblings.map(dec),
  };

  return { inputs, pubSignals, changeNote, newCommitment };
}

/** Poseidon re-export so callers can verify a commitment without reaching into ./notes. */
export { Poseidon };
