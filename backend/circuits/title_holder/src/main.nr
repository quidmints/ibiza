// Compiled entry point for pp::title_holder::title_holder_proof - see pp/src/title_holder.nr for
// the gadget itself and the full rationale (why the public commitment is title-specific, not the
// raw holder_root).
//
// NOT YET nargo-compiled/tested (standing constraint this session - see withdraw_identity/src/
// main.nr for the pattern this repo follows once approval is given: compile, `nargo test`,
// differential-check before trusting for real value). pp::title_holder's own gadget test already
// cross-checked the underlying Poseidon derivation against @iden3/js-crypto independently.
//
// PUBLIC I/O ordering pinned to TitleLedger.sol's _verifyHolderProof:
//   [0] expected_commitment  (TitleLedger.holderCommitment(titleId) - the on-chain stored value)
//   [1] title_id
use pp::title_holder::title_holder_proof;

fn main(expected_commitment: pub Field, title_id: pub Field, sk_identity: Field) {
    let _proof = title_holder_proof(sk_identity, title_id, expected_commitment);
}
