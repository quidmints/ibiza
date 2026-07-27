use std::hash::Hasher;
use poseidon::poseidon::PoseidonHasher;
use super::utils::{switcher};

fn smt_hash1(
    key: Field,
    value: Field) -> Field{
    let mut hasher = PoseidonHasher::default();
    hasher.write(key);
    hasher.write(value);
    hasher.write(1);
    hasher.finish()
}


fn smt_hash2(
    l: Field,
    r: Field) -> Field{
    let mut hasher = PoseidonHasher::default();
    hasher.write(l);
    hasher.write(r);
    hasher.finish()
}

fn smt_level_ins<let N_LEVELS: u32>(
    siblings: [Field; N_LEVELS]) -> [Field; N_LEVELS]{
    let mut done: [Field; (N_LEVELS - 1)] = [0; N_LEVELS - 1];
    assert(siblings[N_LEVELS - 1].eq(0) as Field == 1, "SMT inner verification failure");
    let mut out = [0; N_LEVELS];

    out[N_LEVELS - 1] = 1 - siblings[N_LEVELS - 2].eq(0) as Field;
    done[N_LEVELS - 2] = out[N_LEVELS - 1];

    for i in 0..N_LEVELS - 2{
        out[N_LEVELS - 2 - i] = 
            (1 - done[N_LEVELS - 2 - i]) * 
            (1 - siblings[N_LEVELS - 3 - i].eq(0) as Field);
        done[N_LEVELS - 3 - i] = 
            out[N_LEVELS - 2 - i] + done[N_LEVELS - 2 - i];
    }
    out[0] = 1 - done[0];
    out
}

fn smt_verifier_sm(lev_ins: Field, prev_top: Field) -> (Field, Field){
    let st_inew = prev_top * lev_ins;
    (st_inew, prev_top - st_inew)
}

fn smt_verifier_level(
    st_top: Field,
    st_inew: Field,
    sibling: Field,
    new_1_leaf: Field,
    lrbit: u1,
    child: Field
) -> Field{

    let switcher = switcher(child, sibling, lrbit);
    let proof_hash = smt_hash2(switcher.0, switcher.1);
    let from_proof= proof_hash * st_top;

    from_proof + new_1_leaf * st_inew
}

pub fn smt_verifier<let N_LEVELS: u32>(
    root: Field,
    leaf: Field,
    key: Field,
    siblings: [Field; N_LEVELS]) -> u1{
    
    let hash1_new = smt_hash1(key, leaf);

    let key_bits: [u1; 254] = key.to_le_bits();
    
    let smt_lev_ins_out = smt_level_ins::<N_LEVELS>(siblings);

    let mut sm_outs: [(Field, Field); N_LEVELS] = [(0,0); N_LEVELS];

    sm_outs[0] = smt_verifier_sm(smt_lev_ins_out[0], 1);

    for i in 1..N_LEVELS{
        sm_outs[i] = smt_verifier_sm(smt_lev_ins_out[i], sm_outs[i - 1].1);
    }

    let mut levels: [Field; N_LEVELS] = [0; N_LEVELS];

    levels[N_LEVELS - 1] = smt_verifier_level(sm_outs[N_LEVELS - 1].1, sm_outs[N_LEVELS - 1].0, siblings[N_LEVELS - 1], hash1_new, key_bits[N_LEVELS - 1], 0);
    for i in 1..N_LEVELS{
        levels[N_LEVELS - 1 - i] = smt_verifier_level(sm_outs[N_LEVELS - 1 - i].1, sm_outs[N_LEVELS - 1 - i].0, siblings[N_LEVELS - 1 - i], hash1_new, key_bits[N_LEVELS - 1 - i], levels[N_LEVELS - i]);
    }
    (levels[0] == root) as u1
}

/*
 * DIFFERENTIAL TESTS against circomlibjs - the implementation this file is a port of.
 *
 * The previous test here was `print(smt_verifier::<80>(...))` with NO ASSERTION: it could not
 * fail, whatever the gadget returned. So the port had never actually been checked against its
 * reference. Vectors below come from circomlibjs 0.1.7, tree built by inserting
 * (1,11), (2,22), (7,77), (9,99) into an empty SMT.
 */
global REF_ROOT: Field =
    518494836555806875742446376098343000486175381741467406929375446995815951571;

// Inclusion path for key=7, padded to 10 levels.
fn ref_siblings_key7() -> [Field; 10] {
    [
        3538372437315232912232383076351801231931604997820687320170917796819460581158,
        7219773115889511897248370091680383759521588836236378252329610603114958225446,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]
}

#[test]
fn test_inclusion_matches_circomlibjs() {
    assert(
        smt_verifier::<10>(REF_ROOT, 77, 7, ref_siblings_key7()) == 1,
        "inclusion proof for key=7 was rejected",
    );
}

/*
 * NEGATIVE CONTROLS. Without these the test above proves nothing: a gadget that returned 1
 * unconditionally would pass it. Each perturbs exactly one input.
 */
#[test]
fn test_rejects_wrong_value() {
    assert(
        smt_verifier::<10>(REF_ROOT, 78, 7, ref_siblings_key7()) == 0,
        "a wrong VALUE was accepted",
    );
}

#[test]
fn test_rejects_wrong_key() {
    assert(
        smt_verifier::<10>(REF_ROOT, 77, 8, ref_siblings_key7()) == 0,
        "a wrong KEY was accepted",
    );
}

#[test]
fn test_rejects_wrong_root() {
    assert(
        smt_verifier::<10>(REF_ROOT + 1, 77, 7, ref_siblings_key7()) == 0,
        "a wrong ROOT was accepted",
    );
}

#[test]
fn test_rejects_tampered_sibling() {
    let mut sib = ref_siblings_key7();
    sib[0] = sib[0] + 1;
    assert(smt_verifier::<10>(REF_ROOT, 77, 7, sib) == 0, "a tampered SIBLING was accepted");
}
