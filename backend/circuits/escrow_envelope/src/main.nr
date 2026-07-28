// escrow_envelope - the one-time, permissionless transaction that makes an identity REVOCABLE.
//
// Posted once per identity, never on the withdrawal hot path. It proves that a published ciphertext
// genuinely seals the revocation secret committed under this holder root, so the controller CAN
// list that identity later. Without it, a user picks a secret nobody knows and their absence from
// the blacklist is guaranteed forever - see pp/src/envelope.nr's header for why that vacuity is the
// whole reason this circuit exists.
//
// PERMISSIONLESS BY CONSTRUCTION: no controller signature is consumed, so there is no approval to
// withhold. That is deliberate - an attested escrow would hand back the censorship-by-inaction
// lever the blacklist design exists to remove.
//
// WHY holder_root IS PROVEN AND NOT MERELY SUPPLIED. If the caller could name any holder root, an
// attacker would escrow a commitment to a secret of THEIR choosing against a VICTIM's identity.
// The victim's own withdrawal, which proves its `s` matches the escrowed commitment, would then
// fail forever. Requiring knowledge of `sk_identity` is what makes escrow self-service only.
use pp::envelope::{seal_payload, secret_commitment};
use pp::holder_root::extract_pk_identity_hash;

fn main(
    // The controller's published sealing key.
    controller_x: pub Field,
    controller_y: pub Field,
    // The identity being made revocable. PROVEN from sk_identity below, never taken on trust.
    holder_root: pub Field,
    // Goes into the registered-identity leaf as `holder_root -> commitment`. The withdrawal circuit
    // re-derives it from its own `s`, which is what binds a withdrawal to an escrowed secret.
    commitment: pub Field,
    // The published ciphertext.
    c1_x: pub Field,
    c1_y: pub Field,
    sealed_secret: pub Field,
    sealed_document: pub Field,
    // Private.
    sk_identity: Field,
    revocation_secret: Field,
    ephemeral: Field,
    // An attribute the controller needs in order to attribute this registration to a PERSON
    // (TODO.md sec. 2.13f). Sealed rather than published, because it is exactly the linkage the
    // chain must not carry in the clear.
    document_attribute: Field,
) {
    assert(extract_pk_identity_hash(sk_identity) == holder_root, "escrow: holder_root is not derived from sk_identity");
    assert(secret_commitment(revocation_secret) == commitment, "escrow: commitment does not match the sealed secret");

    let envelope = seal_payload(
        [revocation_secret, document_attribute],
        ephemeral,
        controller_x,
        controller_y,
    );

    assert(envelope.c1_x == c1_x, "escrow: C1.x mismatch");
    assert(envelope.c1_y == c1_y, "escrow: C1.y mismatch");
    assert(envelope.payload[0] == sealed_secret, "escrow: sealed secret mismatch");
    assert(envelope.payload[1] == sealed_document, "escrow: sealed document attribute mismatch");
}
