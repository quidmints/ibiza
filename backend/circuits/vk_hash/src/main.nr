//! Poseidon2 over a verification key's field elements - the `key_hash` a chonk kernel must be given.
//!
//! WHY THIS IS A CIRCUIT AND NOT TEN LINES OF PYTHON. `bb write_vk -s chonk` leaves the hash EMPTY:
//! the binary form writes no `vk_hash` file at all, and `--output_format json` writes `"hash": ""`.
//! The recursive verifier checks it anyway - a wrong or zero value surfaces as
//! `Recursive Ultra Verifier: VK Hash Mismatch` followed by a failed fold. So the value has to be
//! computed somewhere, and the only implementation guaranteed to agree with the one doing the
//! checking is the one the kernels themselves compile against. Reimplementing Poseidon2's sponge in
//! the orchestration script would be a second implementation of a hash whose whole job is to make
//! two parties agree.
//!
//! IT IS NOT COMPUTED INSIDE THE KERNEL, which is the tempting shortcut. A kernel that hashed the key
//! it was handed would be checking `hash(key) == hash(key)` and the check would hold for any key at
//! all - which is worse than no check, because the failure is silent and the log still says the fold
//! verified. The hash is supplied from outside so that it can DISAGREE.
//!
//! ONE CIRCUIT, TWO KEY SIZES. Mega app and kernel keys are 151 fields; chonk keys (the hiding
//! kernel's, and the one the wrapper verifies) are 119. `Poseidon2::hash` takes the message length
//! and both derives the IV from it and stops absorbing there, so a 151-slot array carrying 119 real
//! fields hashes exactly as a 119-field key does. Trailing slots are not read.
use poseidon::poseidon2::Poseidon2;

/// Widest key this has to carry: MEGA_VK_LENGTH_IN_FIELDS. Shorter keys pass their own `len`.
global MAX_VK_FIELDS: u32 = 151;

fn main(key: [Field; MAX_VK_FIELDS], len: u32) -> pub Field {
    assert(len <= MAX_VK_FIELDS, "vk longer than MAX_VK_FIELDS");
    Poseidon2::hash(key, len)
}
