// Identity-based ASP tooling - the off-chain half of the rescoped P2 upgrade (see
// backend/circuits/pp/src/identity_asp.nr and backend/circuits/withdraw_identity/src/main.nr for
// the on-chain/circuit half, and PP-NOIR-FUSION.md P2 / the 2026-07-24 directive: "build the
// identity-based upgrade now using ERC identity standard").
//
// Builds the identity ASP LeanIMT (leaves = cleared holderRoots, NOT upstream's per-deposit
// `label`) and produces the inclusion path a withdrawer's Noir proof needs
// (pp::identity_asp::identity_asp_membership's asp_leaf_index/asp_siblings).
//
// Tree construction/proof generation is `@zk-kit/lean-imt` (official, MIT, the SAME reference
// implementation PP-NOIR-FUSION.md's own P1 differential tests already validate `lean_imt.nr`
// against, via its Solidity port `@zk-kit/lean-imt.sol`) - NOT a hand-rolled reimplementation
// (an earlier version of this file wrote its own tree-building/proof-generation logic; caught and
// replaced 2026-07-24, since the library already does exactly this, with the same
// carry-up-on-empty-sibling rule, and is the more trustworthy source of truth to depend on than a
// second, independent implementation of the same algorithm). Poseidon (@iden3/js-crypto) is
// injected as the library's pluggable hash function - already cross-checked in this fusion
// against noir-lang/poseidon and poseidon-solidity (see notes.ts / identity_asp.nr's own headers).
//
// NOT the same actor as the wallet holder: this is the ASP_POSTMAN operator's tooling (whoever
// holds Entrypoint.sol's ASP_POSTMAN role calls admitIdentity() per cleared identity - see the
// CRE-based notary source in src/postman/notaryRegistry.ts for one concrete eligibility feed). It
// lives in the wallet package only because that's where ethers + the pinned Poseidon dependency
// already exist and are known-good; split into a dedicated operator package if/when this needs its
// own deploy lifecycle separate from the wallet's.
//
// MOVED 2026-07-27 - the ASP tree is no longer in Entrypoint at all. It lives in its own
// NON-UPGRADEABLE, unowned IdentityAspRegistry, and these calls target THAT address. Keeping it in
// the Entrypoint made the append-only claim untrue: Entrypoint._authorizeUpgrade is
// onlyRole(_OWNER_ROLE), so the owner could upgrade and rewrite the membership set. See TODO.md
// sec. 2.5a. Pass the REGISTRY address here, not the Entrypoint's.
//
// CORRECTED 2026-07-26 - this header previously claimed "Entrypoint.sol itself needs NO changes
// for this upgrade", on the reasoning that `updateRoot`/`latestActiveRoot` were leaf-semantics-
// agnostic. That was true of the IDENTITY re-keying, but it is no longer true of the contract at
// all: Entrypoint DID change, substantially. It now maintains the ASP tree on-chain and
// append-only (`admitIdentity`), and `updateRoot`/`latestActiveRoot`/`rootByIndex`/
// `associationSets` are GONE - removed, not deprecated, so the postman can no longer publish an
// arbitrary root and thereby drop an existing member. See TODO.md sec. 2.13 / sec. 2A Phase 1b.
//
// The tree class below is unaffected by that change and still does what it always did: build the
// local LeanIMT mirror and emit circuit-ready inclusion paths. What changed is how that mirror is
// SOURCED (replay `IdentityAdmitted` events via loadIdentityAspTree, rather than holding the
// canonical copy off-chain) and how admission is PUBLISHED (one admitIdentity tx per identity,
// rather than one batched root push).

import { LeanIMT } from "@zk-kit/lean-imt";
import { Poseidon } from "@iden3/js-crypto";
import { Contract, ContractRunner, Interface, type Log } from "ethers";

/** BN254 scalar field - leaves and internal nodes both live here (same field commitment.nr /
 *  identity_asp.nr operate in). */
export const FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export interface IdentityAspProof {
  leafIndex: bigint;
  /** Padded with 0 up to `maxDepth` - a correct no-op per the LeanIMT carry-up-on-empty rule, not
   *  a fudge (see lean_imt.nr's header comment for why 0 specifically means "no sibling here"). */
  siblings: bigint[];
  /** The tree's actual depth (<= maxDepth) - what the circuit's `asp_tree_depth` public input
   *  should carry, distinct from `siblings.length` (always `maxDepth` after padding). */
  depth: number;
}

/** Poseidon2, injected into @zk-kit/lean-imt as its pluggable hash function - this IS the
 *  "carry-up-on-empty-sibling" LeanIMT rule (the library implements that construction rule
 *  itself; only the hash used at each internal node is pluggable). */
const hash2 = (a: bigint, b: bigint): bigint => Poseidon.hash([a, b]);

/** Identity-based ASP tree: a LeanIMT over cleared-identity `holderRoot` leaves, built with
 *  @zk-kit/lean-imt (see this file's header for why - not a hand-rolled reimplementation). A
 *  thin wrapper, not a reimplementation: adds this fusion's own validation (field-membership,
 *  no-duplicate-admission) and the fixed-`maxDepth`-padded proof shape the Noir circuit expects,
 *  on top of the library's real tree logic. */
export class IdentityAspTree {
  private tree: LeanIMT<bigint>;

  constructor(holderRoots: bigint[] = []) {
    this.tree = new LeanIMT<bigint>(hash2);
    for (const leaf of holderRoots) this.insert(leaf);
  }

  get size(): number {
    return this.tree.size;
  }

  get depth(): number {
    return this.tree.depth;
  }

  get leaves(): bigint[] {
    return this.tree.leaves;
  }

  get root(): bigint {
    return this.tree.size === 0 ? 0n : this.tree.root;
  }

  /** Admit a newly-cleared identity's holderRoot as an ASP leaf. */
  insert(holderRoot: bigint): void {
    if (holderRoot <= 0n || holderRoot >= FIELD) {
      throw new Error("IdentityAspTree: leaf must be a nonzero BN254 field element");
    }
    if (this.tree.has(holderRoot)) {
      throw new Error("IdentityAspTree: this identity is already an ASP member");
    }
    this.tree.insert(holderRoot);
  }

  /** Inclusion path for `holderRoot`, formatted for the Noir circuit's
   *  asp_leaf_index/asp_siblings inputs (pp::identity_asp::identity_asp_membership). Throws if
   *  the identity isn't (or is no longer) an ASP member, or if this tree's real depth exceeds the
   *  circuit's compiled MAX_DEPTH. Padded with 0 up to `maxDepth` - a correct no-op per the
   *  LeanIMT carry-up-on-empty rule (see lean_imt.nr's header comment for why 0 specifically
   *  means "no sibling here"), matching @zk-kit/lean-imt's own unpadded `generateProof` output
   *  extended to the circuit's fixed compiled depth. */
  proof(holderRoot: bigint, maxDepth: number): IdentityAspProof {
    const index = this.tree.indexOf(holderRoot);
    if (index === -1) throw new Error("IdentityAspTree: holderRoot is not a member of this tree");
    if (this.tree.depth > maxDepth) {
      throw new Error(`IdentityAspTree: tree depth ${this.tree.depth} exceeds circuit maxDepth ${maxDepth}`);
    }

    const { siblings } = this.tree.generateProof(index);
    const padded = [...siblings, ...Array(maxDepth - siblings.length).fill(0n)];

    return { leafIndex: BigInt(index), siblings: padded, depth: this.tree.depth };
  }
}

const ASP_REGISTRY_ABI = [
  "function admitIdentity(uint256 _holderRoot) external returns (uint256 _root)",
  "function isKnownAspRoot(uint256 _root) external view returns (bool)",
  "function aspTreeSize() external view returns (uint256)",
  "function aspTreeDepth() external view returns (uint256)",
  "event IdentityAdmitted(uint256 _holderRoot, uint256 _root, uint256 _index)",
] as const;

/** Admit a newly-cleared identity into the on-chain, append-only ASP tree.
 *
 *  REPLACES the old `publishIdentityAspRoot(...)`, which pushed a locally-built root via
 *  `Entrypoint.updateRoot(root, ipfsCID)` and mirrored the leaf set into IdentityAspLeafRegistry.
 *  That entire flow is gone, and the change is not cosmetic:
 *
 *  - `Entrypoint` now maintains the ASP tree ITSELF, one insertion at a time, so there is no
 *    locally-computed root to push. This is what makes the tree append-only by construction and
 *    removes the operator's ability to drop an existing member by publishing a tree without them
 *    (see TODO.md sec. 2.13 / sec. 2A Phase 1b).
 *  - The separate leaf-registry publish is obsolete. Every leaf is now emitted by the Entrypoint
 *    in `IdentityAdmitted`, in insertion order, which is strictly better data availability: it is
 *    authoritative, whereas the old registry was permissionless and could be fed a wrong leaf set
 *    that consumers had to detect by recomputing the root themselves.
 *  - The IPFS-CID locator dance is gone with it; there is no CID field left to satisfy.
 *
 *  Requires the caller to hold Entrypoint's ASP_POSTMAN role - enforced on-chain, not re-checked
 *  here. Costs one transaction per identity (an O(log n) on-chain insert), where the old design
 *  batched an arbitrary number of admissions into one root push; that throughput loss is the
 *  deliberate price of the append-only property. Returns the leaf index the identity landed at,
 *  decoded from the real event rather than assumed from call ordering.
 */
export async function admitIdentity(
  aspRegistryAddress: string,
  runner: ContractRunner,
  holderRoot: bigint,
): Promise<{ index: bigint; root: bigint }> {
  if (holderRoot <= 0n || holderRoot >= FIELD) {
    throw new Error("admitIdentity: holderRoot must be a nonzero BN254 field element");
  }

  const registry = new Contract(aspRegistryAddress, ASP_REGISTRY_ABI, runner);
  const tx = await registry.admitIdentity(holderRoot);
  const receipt = await tx.wait();

  const iface = new Interface(ASP_REGISTRY_ABI as unknown as string[]);
  for (const log of (receipt?.logs ?? []) as Log[]) {
    let parsed;
    try {
      parsed = iface.parseLog(log);
    } catch {
      continue; // a log from a different contract/topic - not ours to decode
    }
    if (parsed?.name === "IdentityAdmitted") {
      return { index: BigInt(parsed.args._index), root: BigInt(parsed.args._root) };
    }
  }
  throw new Error("admitIdentity: IdentityAdmitted event not found in the transaction receipt");
}

/** Rebuild the local ASP tree mirror from chain state, so a withdrawer can generate the
 *  asp_leaf_index/asp_siblings inputs their Noir proof needs.
 *
 *  The Entrypoint holds only the tree's ROOT and internal accumulator, not its leaves - reading a
 *  membership path out of contract storage is not possible. `IdentityAdmitted` is the leaf feed,
 *  and replaying it in index order reconstructs exactly the tree the contract built, because
 *  insertion order fully determines a LeanIMT.
 *
 *  VERIFY, DON'T TRUST: the caller should check the reconstructed root against
 *  `isKnownAspRoot(tree.root)` before proving against it. A wrong or incomplete log range silently
 *  produces a valid-looking tree with a root the contract has never seen, which would fail on-chain
 *  at withdrawal time with no indication of why - so it is worth catching here.
 */
export async function loadIdentityAspTree(
  aspRegistryAddress: string,
  runner: ContractRunner,
  fromBlock: number | bigint = 0,
  toBlock: number | bigint | "latest" = "latest",
): Promise<IdentityAspTree> {
  const registry = new Contract(aspRegistryAddress, ASP_REGISTRY_ABI, runner);
  const events = await registry.queryFilter(
    registry.filters.IdentityAdmitted(),
    fromBlock,
    toBlock,
  );

  // Sort by the contract's own leaf index rather than by log ordering: a LeanIMT is fully
  // determined by insertion order, so replaying out of order yields a different (wrong) root.
  const admitted = events
    .map((e) => {
      const args = (e as unknown as { args: { _holderRoot: bigint; _index: bigint } }).args;
      return { holderRoot: BigInt(args._holderRoot), index: BigInt(args._index) };
    })
    .sort((a, b) => (a.index < b.index ? -1 : a.index > b.index ? 1 : 0));

  admitted.forEach((entry, i) => {
    if (entry.index !== BigInt(i)) {
      throw new Error(
        `loadIdentityAspTree: gap in IdentityAdmitted log - expected leaf index ${i}, got ${entry.index}. ` +
          "Widen the fromBlock/toBlock range; a partial log range cannot reconstruct the tree.",
      );
    }
  });

  return new IdentityAspTree(admitted.map((entry) => entry.holderRoot));
}
