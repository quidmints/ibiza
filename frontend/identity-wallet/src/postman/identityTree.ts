// The single identity tree, off-chain mirror (TODO.md sec. 2.13k).
//
// Replaces IdentityAspTree. That was a LeanIMT of cleared `holderRoot`s, paired with a SEPARATE
// revocation SMT a withdrawal proved non-inclusion in. Both collapse into ONE SparseMerkleTree
// keyed by the ESCROW COMMITMENT, with status in the leaf VALUE:
//
//     commitment -> 0          registered and clean
//     commitment -> predicate  revoked, and the value says WHY
//
// So a withdrawal proves a single INCLUSION of `commitment -> 0`, which is simultaneously
// "registered" and "not revoked". There is no state a revoked identity can prove.
//
// NOT HAND-ROLLED, for the same reason identityAsp.ts is not: `@zk-kit/smt` is the reference
// implementation, from the same family as the `@zk-kit/lean-imt` this repo already depends on, with
// Poseidon (@iden3/js-crypto) injected as its pluggable hash.
//
// VALIDATED THREE WAYS BEFORE BEING TRUSTED, because a tree that is subtly wrong produces proofs
// that fail on-chain with no diagnostic pointing back here:
//   1. ROOT vs circomlibjs - {1:11, 2:22, 7:77, 9:99} gives
//      518494836555806875742446376098343000486175381741467406929375446995815951571, the vector
//      committed in pp/src/smt.nr::REF_ROOT.
//   2. ROOT vs @solarity on-chain - a single leaf `5 -> 0` gives
//      15739329723942587145467652550645860604592570947603611249889485952228479492237, which
//      test/registry/SmtCompat.t.sol asserts the REGISTRY produces for the same insert. That is
//      the zero-value case specifically, which nothing had exercised before this design.
//   3. SIBLING ORDERING vs the Noir gadget - the proof for key 7 in that tree is
//      [3538372437315232912232383076351801231931604997820687320170917796819460581158,
//       7219773115889511897248370091680383759521588836236378252329610603114958225446],
//      matching pp/src/smt.nr::ref_siblings_key7() element-for-element. A REVERSED array would
//      still look like a plausible proof and would verify against nothing.
// These are re-asserted as tests rather than left as a claim in a comment - see identityTree.test.ts.

import { SMT } from '@zk-kit/smt';
import { poseidon } from '@iden3/js-crypto';

/**
 * SMT depth. MUST equal `withdraw_identity`'s IDENTITY_TREE_DEPTH and IdentityRegistry's
 * constructor `treeHeight_`. A mismatch fails every proof with no useful diagnostic.
 *
 * 32, not 20: this tree holds EVERY registered identity, not only revoked ones, so it is the large
 * tree. Depth 20 caps at ~1M identities and is cheaper in-circuit (7,889 vs 11,856 ACIR opcodes),
 * but a tree's depth cannot be raised without invalidating every outstanding proof.
 */
export const IDENTITY_TREE_DEPTH = 32;

/** The leaf value of a clean identity. Non-zero means revoked, and the value IS the predicate. */
export const STATUS_CLEAN = 0n;

const hash = (...values: unknown[]): bigint =>
  poseidon.hash(values.flat().map((v) => BigInt(v as string | number | bigint)));

export interface IdentityInclusion {
  /** Padded to IDENTITY_TREE_DEPTH, top level first - the order the Noir gadget indexes. */
  siblings: bigint[];
  root: bigint;
}

export class IdentityTree {
  private readonly tree: SMT;

  constructor() {
    // `true` selects big-number mode, which is what keeps keys/values as field elements rather
    // than hex strings.
    this.tree = new SMT(hash as never, true);
  }

  /** Register an identity: its commitment enters carrying STATUS_CLEAN. */
  register(commitment: bigint): void {
    this.tree.add(commitment, STATUS_CLEAN);
  }

  /**
   * Revoke: the leaf VALUE becomes the predicate.
   *
   * An UPDATE, never a remove-and-re-add. Removing would erase the registration entirely, which is
   * censorship by deletion, and re-adding would reset a revoked identity to clean - both are
   * refused on-chain (IdentityRegistry has no removal path, and the SMT rejects a duplicate key).
   */
  revoke(commitment: bigint, predicate: bigint): void {
    if (predicate === 0n) {
      throw new Error(
        'IdentityTree.revoke: predicate must be non-zero - zero is the CLEAN sentinel, so a zero ' +
          'predicate would revoke an identity into good standing rather than out of it.',
      );
    }
    this.tree.update(commitment, predicate);
  }

  get root(): bigint {
    return BigInt(this.tree.root as unknown as string);
  }

  /**
   * The inclusion witness a withdrawal needs.
   *
   * THROWS rather than returning a non-membership proof. A withdrawal can only be built for an
   * identity that is registered AND clean; handing back a proof of the wrong shape would produce a
   * witness that fails in-circuit with no indication that the real problem is the identity's
   * status.
   */
  inclusionProof(commitment: bigint): IdentityInclusion {
    const proof = this.tree.createProof(commitment) as unknown as {
      membership: boolean;
      siblings: (bigint | string)[];
      entry: (bigint | string)[];
    };

    if (!proof.membership) {
      throw new Error(
        `IdentityTree.inclusionProof: commitment ${commitment} is NOT in the identity tree. It has ` +
          'either never been escrowed, or the local mirror is stale - re-sync before proving.',
      );
    }
    // entry is [key, value, 1]; a non-zero value means revoked.
    const value = BigInt(proof.entry[1] as string);
    if (value !== STATUS_CLEAN) {
      throw new Error(
        `IdentityTree.inclusionProof: commitment ${commitment} is REVOKED under predicate ${value}. ` +
          'No withdrawal proof exists for a revoked identity.',
      );
    }

    const siblings = proof.siblings.map((s) => BigInt(s as string));
    if (siblings.length > IDENTITY_TREE_DEPTH) {
      throw new Error(
        `IdentityTree.inclusionProof: path is ${siblings.length} deep but the circuit is fixed at ` +
          `${IDENTITY_TREE_DEPTH}. The tree has outgrown the circuit; both must be regenerated together.`,
      );
    }
    while (siblings.length < IDENTITY_TREE_DEPTH) siblings.push(0n);

    return { siblings, root: this.root };
  }
}
