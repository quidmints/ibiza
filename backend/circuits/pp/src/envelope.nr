// Sealed envelope: hashed ElGamal over Baby Jubjub, for escrowing the revocation secret.
//
// WHAT THIS IS FOR (TODO.md sec. 2.13c-f). The blacklist's CONTENTS must stay confidential, but a
// non-inclusion proof needs a PUBLIC set to build a path against. That is resolved by publishing a
// set whose ENTRIES are opaque: each listed identity appears as `Poseidon(s)` for a per-identity
// revocation secret `s`. Anyone can prove absence; nobody but the controller can tell WHO is
// present.
//
// THE HOLE THAT MAKES THIS FILE NECESSARY. If `s` were freely chosen, a user would simply pick one
// the controller has never seen, and their absence from the list would be guaranteed forever - the
// check becomes vacuous. So the controller must be ABLE to compute `Poseidon(s)` for anyone. That
// requires it to learn `s`.
//
// WHY SEALED-AND-POSTED RATHER THAN HANDED OVER. Any scheme where the controller ATTESTS to `s` at
// registration gives it a refusal lever: decline to sign, and the user can never withdraw -
// censorship by inaction, indistinguishable from being slow. That is precisely the failure the
// blacklist design exists to remove, and it must not re-enter through the escrow step. So the user
// SEALS `s` to the controller's published key and POSTS the ciphertext on-chain. There is no
// approval step, hence nothing to withhold.
//
// WHY HASHED ELGAMAL AND NOT TEXTBOOK ELGAMAL. Textbook ElGamal encrypts a POINT (C2 = M + r*PK),
// which would force `s` to be encoded as a curve point and decoded on the way out. Hashing the
// shared secret to a field mask instead (C2 = s + Poseidon(r*PK)) keeps `s` a plain field element,
// costs one hash instead of a point encoding, and lets a whole PAYLOAD ride on ONE pair of scalar
// multiplications - see `seal_payload`. The scalar mults dominate the circuit, so additional sealed
// fields are nearly free.

use crate::jubjub::mul_point;
use poseidon::poseidon::PoseidonHasher;
use std::hash::Hasher;

/// Baby Jubjub's generator, as used by `priv_to_pub` and @iden3/js-crypto's `babyJub.Base8`.
global BASE_X: Field = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
global BASE_Y: Field = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

/// A sealed envelope. `c1` is the ephemeral public point; `payload` is the masked plaintext.
pub struct Envelope<let N: u32> {
    pub c1_x: Field,
    pub c1_y: Field,
    pub payload: [Field; N],
}

/// The public commitment to a revocation secret.
///
/// This is BOTH the value bound into the registered-identity leaf (so a withdrawal proves, via an
/// inclusion proof it already performs, that its `s` is the escrowed one) AND the key under which
/// the controller lists a revoked identity. One value serving both roles is what lets the
/// withdrawal circuit add only a couple of hashes rather than a whole second tree.
pub fn secret_commitment(revocation_secret: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(revocation_secret);
    hasher.finish()
}

/// The per-index mask derived from a shared secret point.
///
/// INDEXED so that a payload of several fields cannot have its elements PERMUTED or REPLAYED across
/// positions: without the index every slot would share one mask, and swapping two ciphertext fields
/// would decrypt to a swapped - but perfectly valid-looking - plaintext.
fn mask(shared_x: Field, shared_y: Field, index: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(shared_x);
    hasher.write(shared_y);
    hasher.write(index);
    hasher.finish()
}

/// Seal `payload` to the controller's public key under ephemeral scalar `ephemeral`.
///
/// THE `ephemeral != 0` ASSERTION IS LOAD-BEARING AND IS NOT A SANITY CHECK. `mul_point(P, 0)`
/// returns this ladder's empty-accumulator sentinel `(0,0)` - measured, see
/// jubjub.nr::test_mul_point_by_zero_returns_the_sentinel_not_the_identity - for EVERY base point.
/// So with `ephemeral = 0` the shared secret is `(0,0)` regardless of whose key is being sealed to,
/// the mask collapses to the constant `Poseidon(0, 0, i)`, and the payload is readable by anyone who
/// looks. It would still produce a well-formed envelope that passes every other check, which is
/// exactly why it has to be rejected here rather than assumed away.
pub fn seal_payload<let N: u32>(
    payload: [Field; N],
    ephemeral: Field,
    controller_x: Field,
    controller_y: Field,
) -> Envelope<N> {
    assert(ephemeral != 0, "envelope: ephemeral scalar must be non-zero");

    let c1 = mul_point(BASE_X, BASE_Y, ephemeral);
    let shared = mul_point(controller_x, controller_y, ephemeral);

    let mut sealed: [Field; N] = [0; N];
    for i in 0..N {
        sealed[i] = payload[i] + mask(shared.0, shared.1, i as Field);
    }

    Envelope { c1_x: c1.0, c1_y: c1.1, payload: sealed }
}

/// Open an envelope with the controller's PRIVATE key.
///
/// Present so the sealing direction can be tested against a real round trip rather than against
/// hand-copied constants - a mask that is wrong in both directions would otherwise look correct.
/// The controller runs this OFF-CHAIN; no circuit proves it.
pub fn open_payload<let N: u32>(
    envelope: Envelope<N>,
    controller_secret: Field,
) -> [Field; N] {
    let shared = mul_point(envelope.c1_x, envelope.c1_y, controller_secret);

    let mut opened: [Field; N] = [0; N];
    for i in 0..N {
        opened[i] = envelope.payload[i] - mask(shared.0, shared.1, i as Field);
    }

    opened
}

// ---------------------------------------------------------------------------------------------
// TESTS
// ---------------------------------------------------------------------------------------------

// A controller keypair. The secret is arbitrary; the point is @iden3/js-crypto's
// babyJub.mulPointEScalar(babyJub.Base8, CONTROLLER_SK), so the curve arithmetic here is pinned to
// the same implementation the wallet and HolderStateKeeper agree with.
global CONTROLLER_SK: Field = 1234;
global CONTROLLER_X: Field =
    4880901335776166390443888589907570248644423541468541082967598048550539024543;
global CONTROLLER_Y: Field =
    6509666988291764283313685078036329297907336602650572952945826675203643401307;

#[test]
fn test_controller_key_matches_babyjub() {
    // If this drifts, every envelope below is sealed to a key nobody holds.
    let pk = mul_point(BASE_X, BASE_Y, CONTROLLER_SK);
    assert(pk.0 == CONTROLLER_X, "controller pubkey x disagrees with @iden3/js-crypto");
    assert(pk.1 == CONTROLLER_Y, "controller pubkey y disagrees with @iden3/js-crypto");
}

#[test]
fn test_seal_then_open_roundtrips() {
    let payload = [42, 7, 999];
    let env = seal_payload(payload, 5555, CONTROLLER_X, CONTROLLER_Y);
    let opened = open_payload(env, CONTROLLER_SK);

    assert(opened[0] == 42, "roundtrip lost payload[0]");
    assert(opened[1] == 7, "roundtrip lost payload[1]");
    assert(opened[2] == 999, "roundtrip lost payload[2]");
}

#[test]
fn test_ciphertext_actually_hides_the_payload() {
    // A mask that was accidentally zero, or an addition that was dropped, would round-trip
    // PERFECTLY while encrypting nothing. So assert the ciphertext differs from the plaintext.
    let payload = [42, 7, 999];
    let env = seal_payload(payload, 5555, CONTROLLER_X, CONTROLLER_Y);

    assert(env.payload[0] != 42, "payload[0] was not masked at all");
    assert(env.payload[1] != 7, "payload[1] was not masked at all");
    assert(env.payload[2] != 999, "payload[2] was not masked at all");
}

#[test]
fn test_each_slot_gets_a_DIFFERENT_mask() {
    // Identical plaintext in two slots must NOT produce identical ciphertext, or the index is not
    // reaching the mask and payload fields could be permuted undetectably.
    let env = seal_payload([77, 77], 5555, CONTROLLER_X, CONTROLLER_Y);
    assert(env.payload[0] != env.payload[1], "two slots shared one mask - index is not applied");
}

#[test]
fn test_a_different_ephemeral_gives_a_different_ciphertext() {
    // Ephemeral reuse across two envelopes would let an observer subtract them and recover the
    // DIFFERENCE of the plaintexts. This pins that the ephemeral genuinely feeds the mask.
    let a = seal_payload([42], 5555, CONTROLLER_X, CONTROLLER_Y);
    let b = seal_payload([42], 6666, CONTROLLER_X, CONTROLLER_Y);

    assert(a.payload[0] != b.payload[0], "ephemeral does not affect the ciphertext");
    assert((a.c1_x != b.c1_x) | (a.c1_y != b.c1_y), "ephemeral does not affect C1");
}

#[test]
fn test_the_wrong_controller_key_does_not_open_it() {
    let env = seal_payload([42], 5555, CONTROLLER_X, CONTROLLER_Y);
    let opened = open_payload(env, CONTROLLER_SK + 1);
    assert(opened[0] != 42, "an envelope opened under the WRONG secret still yielded the plaintext");
}

#[test(should_fail_with = "envelope: ephemeral scalar must be non-zero")]
fn test_zero_ephemeral_is_rejected() {
    let _ = seal_payload([42], 0, CONTROLLER_X, CONTROLLER_Y);
}

#[test]
fn test_zero_ephemeral_would_have_leaked_the_payload() {
    // WHY the assertion above is not merely defensive. Reproduce what a zero ephemeral would
    // produce, WITHOUT going through seal_payload's guard, and show the mask is a public constant
    // that anyone can recompute with no secret at all - so the sealed value falls straight out.
    let shared_if_zero = mul_point(CONTROLLER_X, CONTROLLER_Y, 0);
    assert(shared_if_zero.0 == 0, "sentinel x changed");
    assert(shared_if_zero.1 == 0, "sentinel y changed");

    // Anyone can compute this: it involves no secret and no key.
    let public_mask = mask(0, 0, 0);
    let what_c2_would_be = 42 + public_mask;
    assert(what_c2_would_be - public_mask == 42, "the payload is trivially recoverable, as claimed");
}

#[test]
fn test_secret_commitment_is_deterministic_and_separating() {
    assert(secret_commitment(9) == secret_commitment(9), "commitment is not deterministic");
    assert(secret_commitment(9) != secret_commitment(10), "two secrets share one commitment");
}
