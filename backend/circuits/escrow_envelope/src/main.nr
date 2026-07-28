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
//
// WHY THE WHOLE DG1 IS SEALED, NOT A DIGEST (TODO.md sec. 2.13f). A person may hold several
// passports under different names, and nothing in ICAO 9303 links two states' documents for one
// person. The controller therefore has to do that attribution itself, which it can only do from the
// ACTUAL MRZ - name, date of birth, nationality, document number. A hash would let it verify a
// guess but never form one. So the MRZ rides inside the envelope: opaque on-chain, readable only by
// the controller, and bound by `dg1_hash` to the same bytes the registration proof already pinned.
//
// MEASURED, because sealing this much looked expensive and is not: the sha256 binding costs 396
// ACIR opcodes (25,542 with it vs 25,146 without) since sha256 is a blackbox gadget rather than
// unrolled arithmetic, and each extra sealed field is ~8 opcodes because ONE shared secret covers
// the whole payload. The two scalar multiplications dominate everything else.
use noir_dl::not_passports_zk_circuits::passport_hash;
use pp::envelope::{seal_payload, secret_commitment};
use pp::holder_root::extract_pk_identity_hash;

/// DG1 length for the TD3 (passport) layout, matching register_identity_light_td1.
global DG1_LEN: u32 = 95;
/// sha256.
global DG_HASH_ALGO: u32 = 32;
/// Bytes packed per field element. 31 keeps every packed value below the BN254 modulus.
global BYTES_PER_FIELD: u32 = 31;
/// ceil(95 / 31) = 4.
global DG1_WORDS: u32 = 4;
/// One slot for the revocation secret, then the packed MRZ.
global PAYLOAD_LEN: u32 = 5;

/// Reduce a sha256 digest to a field EXACTLY as `noir_dl::lite::register_identity_light` does.
///
/// COPIED DELIBERATELY rather than reimplemented "more cleanly": that function skips digest[0] and
/// reads the remaining 31 bytes big-endian. Any other packing - including the obvious
/// `digest[0..31]` - produces a DIFFERENT field element, so `dg1_hash` here would not equal the
/// `dg1Hash` that RegistrationSimple._verifyNoirZKProof binds and that HolderStateKeeper now stores
/// as the document's anti-replay key. The escrow would then bind the MRZ to a value nothing else
/// agrees with, and no test outside this file would catch it.
fn dg1_hash_field(digest: [u8; DG_HASH_ALGO]) -> Field {
    let mut acc: Field = 0;
    let mut place: Field = 1;
    for i in 0..BYTES_PER_FIELD {
        acc += place * digest[DG_HASH_ALGO - 1 - i] as Field;
        place *= 256;
    }
    acc
}

/// Pack the MRZ bytes into field elements, big-endian, 31 bytes at a time.
fn pack_dg1(dg1: [u8; DG1_LEN]) -> [Field; DG1_WORDS] {
    let mut packed: [Field; DG1_WORDS] = [0; DG1_WORDS];
    for w in 0..DG1_WORDS {
        let mut acc: Field = 0;
        for j in 0..BYTES_PER_FIELD {
            let idx = w * BYTES_PER_FIELD + j;
            // The final word is short (95 = 3*31 + 2), so pad rather than read out of bounds.
            if idx < DG1_LEN {
                acc = acc * 256 + dg1[idx] as Field;
            } else {
                acc = acc * 256;
            }
        }
        packed[w] = acc;
    }
    packed
}

fn main(
    // The controller's published sealing key.
    controller_x: pub Field,
    controller_y: pub Field,
    // The identity being made revocable. PROVEN from sk_identity below, never taken on trust.
    holder_root: pub Field,
    // Goes into the registered-identity leaf as `holder_root -> commitment`. The withdrawal circuit
    // re-derives it from its own `s`, which is what binds a withdrawal to an escrowed secret.
    commitment: pub Field,
    // The SAME value RegistrationSimple already bound for this document. Tying the sealed MRZ to it
    // is what stops a user sealing someone else's - or fabricated - passport data.
    dg1_hash: pub Field,
    // The published ciphertext: ephemeral point, then payload[0] = revocation secret,
    // payload[1..5] = the packed MRZ.
    c1_x: pub Field,
    c1_y: pub Field,
    sealed: pub [Field; PAYLOAD_LEN],
    // Private.
    sk_identity: Field,
    revocation_secret: Field,
    ephemeral: Field,
    dg1: [u8; DG1_LEN],
) {
    assert(
        extract_pk_identity_hash(sk_identity) == holder_root,
        "escrow: holder_root is not derived from sk_identity",
    );
    assert(
        secret_commitment(revocation_secret) == commitment,
        "escrow: commitment does not match the sealed secret",
    );

    let digest: [u8; DG_HASH_ALGO] = passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1);
    assert(dg1_hash_field(digest) == dg1_hash, "escrow: sealed MRZ does not hash to dg1_hash");

    let packed = pack_dg1(dg1);
    let mut payload: [Field; PAYLOAD_LEN] = [0; PAYLOAD_LEN];
    payload[0] = revocation_secret;
    for w in 0..DG1_WORDS {
        payload[w + 1] = packed[w];
    }

    let envelope = seal_payload(payload, ephemeral, controller_x, controller_y);

    assert(envelope.c1_x == c1_x, "escrow: C1.x mismatch");
    assert(envelope.c1_y == c1_y, "escrow: C1.y mismatch");
    for i in 0..PAYLOAD_LEN {
        assert(envelope.payload[i] == sealed[i], "escrow: sealed payload mismatch");
    }
}
