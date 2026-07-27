// Non-inclusion witness for the revocation registry — the `revocation_*` inputs a withdrawal proof
// needs to show "this identity is NOT revoked" (TODO.md sec. 2.5).
//
// NO LOCAL TREE MIRROR, DELIBERATELY. stateTree.ts and identityAsp.ts both rebuild their trees
// off-chain because those are LeanIMTs whose contracts expose only a root — a membership path
// cannot be read out of contract storage, so the wallet has no choice.
//
// The revocation registry is different: it is a `@solarity` SparseMerkleTree, and `getProof(key)`
// is a VIEW FUNCTION that returns the whole witness — siblings, existence, and the auxiliary leaf
// used to prove absence. Rebuilding it locally would mean writing a second implementation of a
// sparse trie and keeping it byte-compatible forever, for no benefit. Asking the contract is both
// less code and impossible to drift.
//
// COMPATIBILITY IS PROVEN, NOT ASSUMED. The circuit gadget (pp/src/smt.nr) is a circomlib
// SMTVerifier port, while the registry is solarity. `test/registry/SmtCompat.t.sol` builds the same
// key set through both and asserts byte-identical roots — identical hashing alone would not have
// been enough, since bit order and subtree collapsing are free choices.

import { Contract, ContractRunner } from "ethers";

/** MUST equal the circuit's compiled SMT depth AND the registry's constructor `treeHeight_`.
 *  A mismatch makes every non-inclusion proof fail with no useful diagnostic. */
export const REVOCATION_TREE_DEPTH = 20;

// @contract RevocationRegistry
const REVOCATION_ABI = [
  "function root() external view returns (bytes32)",
  "function isValidRoot(bytes32 _root) external view returns (bool)",
  "function isRevoked(bytes32 _holderRoot) external view returns (bool)",
  "function getProof(bytes32 _holderRoot) external view returns (tuple(bytes32 root, bytes32[] siblings, bool existence, bytes32 key, bytes32 value, bool auxExistence, bytes32 auxKey, bytes32 auxValue))",
] as const;

export interface RevocationWitness {
  /** Public input: the root the proof is built against. */
  revocationRoot: bigint;
  /** The leaf occupying the path end, when one does. Zero when the slot is empty. */
  oldKey: bigint;
  oldValue: bigint;
  /** 1 when the path terminates at an EMPTY subtree, 0 when another leaf sits there. */
  isOld0: bigint;
  /** Padded to REVOCATION_TREE_DEPTH. */
  siblings: bigint[];
}

/**
 * Fetch the non-inclusion witness for `holderRoot`.
 *
 * Throws if the identity IS revoked — there is no honest witness in that case, and the circuit's
 * `assert_keys_ok` would reject it anyway. Failing here turns "unprovable witness" into a named
 * error at the point the wallet can still explain it to the user.
 */
export async function fetchNonRevocationWitness(
  registryAddress: string,
  runner: ContractRunner,
  holderRoot: bigint,
): Promise<RevocationWitness> {
  const registry = new Contract(registryAddress, REVOCATION_ABI, runner);
  const key = "0x" + holderRoot.toString(16).padStart(64, "0");

  if (await registry.isRevoked(key)) {
    throw new Error(
      "fetchNonRevocationWitness: this identity IS revoked — no non-inclusion proof exists for it",
    );
  }

  const p = await registry.getProof(key);

  if (p.existence) {
    // Should be unreachable given the isRevoked check above; if it fires, the registry's tree and
    // its isRevoked mapping disagree, which is a contract bug worth surfacing loudly.
    throw new Error(
      "fetchNonRevocationWitness: registry reports the key as PRESENT while isRevoked() said no",
    );
  }

  const siblings: bigint[] = (p.siblings as string[]).map((s) => BigInt(s));
  if (siblings.length > REVOCATION_TREE_DEPTH) {
    throw new Error(
      `fetchNonRevocationWitness: registry depth ${siblings.length} exceeds the circuit's ${REVOCATION_TREE_DEPTH}`,
    );
  }
  while (siblings.length < REVOCATION_TREE_DEPTH) siblings.push(0n);

  return {
    revocationRoot: BigInt(p.root),
    // solarity's `auxExistence` means "another leaf sits at the path end". The circuit's `is_old0`
    // is the inverse: "the slot is EMPTY". Getting this backwards produces a witness that fails
    // with no explanation, so the mapping is spelled out rather than inlined.
    isOld0: p.auxExistence ? 0n : 1n,
    oldKey: p.auxExistence ? BigInt(p.auxKey) : 0n,
    oldValue: p.auxExistence ? BigInt(p.auxValue) : 0n,
    siblings,
  };
}

/**
 * Check a root is still acceptable before proving against it.
 *
 * The registry expires superseded roots after MAX_ROOT_AGE (the latest root never expires — see
 * RevocationRegistry, and TODO.md sec. 2.5a on why a pure age check would be fail-closed). A proof
 * built against a root that ages out mid-flight is rejected on-chain; checking first turns that
 * into a retry rather than a lost gas payment.
 */
export async function isRevocationRootStillValid(
  registryAddress: string,
  runner: ContractRunner,
  root: bigint,
): Promise<boolean> {
  const registry = new Contract(registryAddress, REVOCATION_ABI, runner);
  return registry.isValidRoot("0x" + root.toString(16).padStart(64, "0"));
}
