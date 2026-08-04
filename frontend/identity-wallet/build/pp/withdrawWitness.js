"use strict";
// Withdrawal witness assembler — the second half of sec. 2.1, and the step that makes withdrawing
// possible at all. Turns a discovered note + the two tree mirrors into the exact 20-input witness
// `backend/circuits/withdraw_identity/src/main.nr` expects, plus the 8 public signals
// PrivacyPool.sol reads out of ProofLib.WithdrawProof.pubSignals.
//
// SCOPE, deliberately: this builds and self-checks the witness. It does NOT call the prover.
// Proving is `NoirCircuitParams.fromName('withdraw_identity').proveHonk(...)` from
// @rarimo/rarime-rn-sdk, with the circuit registered by src/sdk/circuits.ts. That path is
// ANDROID-ONLY: the SDK's Android native module implements proveHonk (RnNoirModule.kt,
// proofType = "honk") but iOS hardcodes proof_type: "plonk". See sec. 2.1a.
//
// Keeping assembly separate from proving is not a workaround, it is the right seam anyway: the
// witness is backend-agnostic, so it is testable TODAY against a Forge fixture with no device, no
// prover and no toolchain dependency, and it stays valid if the proving backend moves.
//
// PUBLIC SIGNAL ORDER IS PINNED by ProofLib and must not be reordered:
//   [0] new_commitment          [4] state_tree_depth
//   [1] existing_nullifier_hash [5] identity_root
//   [2] withdrawn_value         [6] context
//   [3] state_root              [7] context
Object.defineProperty(exports, "__esModule", { value: true });
exports.Poseidon = void 0;
exports.nextWithdrawalIndex = nextWithdrawalIndex;
exports.holderRootFromSk = holderRootFromSk;
exports.buildWithdrawalWitness = buildWithdrawalWitness;
const notes_ts_1 = require("./notes.js");
const stateTree_ts_1 = require("./stateTree.js");
const identityProof_ts_1 = require("./identityProof.js");
const js_crypto_1 = require("@iden3/js-crypto");
Object.defineProperty(exports, "Poseidon", { enumerable: true, get: function () { return js_crypto_1.Poseidon; } });
/** The circuit range-checks `value`, `withdrawn_value` and `value - withdrawn_value` to 128 bits
 *  (main.nr step 2, via to_le_bits). Exceeding this yields a witness that cannot be proven, so it
 *  is rejected here with a real explanation instead. */
const MAX_VALUE = 1n << 128n;
/**
 * The next withdrawal index for `label` under the wallet's convention, counted from notes that
 * discoverNotes() already returned. This is the SAME quantity discovery re-derives, computed the
 * same way, which is the point — hand-supplying it is how the remainder gets lost.
 */
function nextWithdrawalIndex(notes, label) {
    let k = 0n;
    for (const n of notes)
        if (n.kind === "withdrawal-change" && n.label === label)
            k += 1n;
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
function holderRootFromSk(skIdentity) {
    return js_crypto_1.Poseidon.hash(js_crypto_1.babyJub.mulPointEScalar(js_crypto_1.babyJub.Base8, skIdentity));
}
/** Assemble (and self-check) the withdraw_identity witness. */
function buildWithdrawalWitness(params) {
    const { note, stateLeafIndex, stateTree, masterKeys, identity, revocationSecret, withdrawnValue, context, withdrawalIndex, allowZeroForPadding = false, } = params;
    if (identity.siblings.length !== identityProof_ts_1.IDENTITY_TREE_DEPTH) {
        throw new Error(`buildWithdrawalWitness: identity witness has ${identity.siblings.length} siblings, ` +
            `but the circuit is fixed at ${identityProof_ts_1.IDENTITY_TREE_DEPTH}. Pad or regenerate both together.`);
    }
    // ── Value conservation, checked before anything expensive ──────────────────────────────────
    if (note.spent)
        throw new Error("buildWithdrawalWitness: note is already spent");
    if (withdrawnValue < 0n || (withdrawnValue === 0n && !allowZeroForPadding)) {
        throw new Error("buildWithdrawalWitness: withdrawnValue must be > 0 (see allowZeroForPadding)");
    }
    if (withdrawnValue > note.value) {
        throw new Error(`buildWithdrawalWitness: withdrawing ${withdrawnValue} from a note worth ${note.value}`);
    }
    if (note.value >= MAX_VALUE) {
        throw new Error("buildWithdrawalWitness: note value exceeds the circuit's 128-bit range check");
    }
    if (context <= 0n || context >= stateTree_ts_1.FIELD) {
        throw new Error("buildWithdrawalWitness: context must be a nonzero BN254 field element");
    }
    // ── Identity: derive the registry key from the escrowed secret ──────────────────────────────
    // The key is Poseidon(revocation_secret) - the SAME value escrow_envelope committed to and
    // IdentityRegistry stored. sk_identity is NOT used here at all any more: identity is proven ONCE,
    // at escrow. See sec. 2.13k.
    const commitment = js_crypto_1.Poseidon.hash([revocationSecret]);
    // ── State-tree membership ───────────────────────────────────────────────────────────────────
    const stateProof = stateTree.proof(stateLeafIndex, stateTree_ts_1.MAX_TREE_DEPTH);
    const leafAtIndex = stateTree.leaves[Number(stateLeafIndex)];
    if (leafAtIndex !== note.commitment) {
        throw new Error(`buildWithdrawalWitness: state leaf ${stateLeafIndex} holds ${leafAtIndex}, ` +
            `but the note's commitment is ${note.commitment}. Wrong index, or a stale tree.`);
    }
    // ── Change note ─────────────────────────────────────────────────────────────────────────────
    const newValue = note.value - withdrawnValue;
    const changeNote = (0, notes_ts_1.withdrawalSecrets)(masterKeys, note.label, withdrawalIndex);
    const newCommitment = (0, notes_ts_1.commitment)(newValue, note.label, changeNote);
    // Reconstruct the SPENT note's commitment exactly as the circuit does (main.nr step 1) rather
    // than trusting discovery's stored value — the circuit asserts this, so a mismatch is a witness
    // that cannot be proven, and it is far cheaper to find it here.
    const existingNote = { nullifier: note.nullifier, secret: note.secret };
    const recomputed = (0, notes_ts_1.commitment)(note.value, note.label, existingNote);
    if (recomputed !== note.commitment) {
        throw new Error(`buildWithdrawalWitness: recomputed commitment ${recomputed} != recorded ${note.commitment}. ` +
            "The note's value/label/secrets disagree with the on-chain commitment.");
    }
    const existingNullifierHash = (0, notes_ts_1.nullifierHash)(note.nullifier);
    const pubSignals = [
        newCommitment,
        existingNullifierHash,
        withdrawnValue,
        stateProof.root,
        BigInt(stateProof.depth),
        identity.identityRoot,
        context,
    ];
    const dec = (v) => v.toString(10);
    const inputs = {
        // public
        new_commitment: dec(newCommitment),
        existing_nullifier_hash: dec(existingNullifierHash),
        withdrawn_value: dec(withdrawnValue),
        state_root: dec(stateProof.root),
        state_tree_depth: dec(BigInt(stateProof.depth)),
        identity_root: dec(identity.identityRoot),
        context: dec(context),
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
        // private - identity clearance. ONE witness where there were two: the escrowed secret and an
        // inclusion path proving its commitment sits in the registry carrying the CLEAN status.
        revocation_secret: dec(revocationSecret),
        identity_siblings: identity.siblings.map(dec),
    };
    return { inputs, pubSignals, changeNote, newCommitment };
}
