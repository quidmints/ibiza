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
// holds Entrypoint.sol's ASP_POSTMAN role calls updateRoot() with what this module produces, e.g.
// after admitting a newly-verified identity, or on a refresh cycle - see the CRE-based notary
// source in src/postman/notaryRegistry.ts for one concrete eligibility feed). It lives in the
// wallet package only because that's where ethers + the pinned Poseidon dependency already exist
// and are known-good; split into a dedicated operator package if/when this needs its own deploy
// lifecycle separate from the wallet's.
//
// Entrypoint.sol itself needs NO changes for this upgrade - `updateRoot`/`latestActiveRoot` are
// already leaf-semantics-agnostic (confirmed by reading Entrypoint.sol: it only ever handles
// `uint256 root`, never a leaf). Only what the leaves MEAN changes - identity commitments instead
// of address-scoped labels - which is exactly why this upgrade is entirely a
// circuit-plus-tree-builder change, not a contract migration.

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

const ENTRYPOINT_ABI = [
  "function updateRoot(uint256 _root, string memory _ipfsCID) external returns (uint256 _index)",
  "event RootAnchored(uint256 root, uint256 index, bytes32 statementKey)",
] as const;

const LEAF_REGISTRY_ABI = [
  "function publishLeaves(bytes32 root, bytes32[] calldata leaves) external",
  "function published(bytes32 root) external view returns (bool)",
] as const;

/** Push a newly-built identity ASP root on-chain via Entrypoint.updateRoot, and make the full
 *  leaf set genuinely available via IdentityAspLeafRegistry.publishLeaves - NOT via an IPFS CID
 *  (dropped, 2026-07-24: an external pinning service is an unnecessary and less reliable
 *  dependency for data cheap enough to just put on-chain, same reasoning RegistrySourceAnchor's
 *  redesign already applied to the notary registry). Entrypoint.sol itself is pre-existing and
 *  unmodified by this fusion, so its `_ipfsCID` parameter still exists and still enforces a
 *  32-64 byte length - it's populated with a locator string pointing at the leaf registry instead
 *  of a real IPFS CID, since Entrypoint can't be changed to accept an empty one.
 *
 *  Requires the caller to hold Entrypoint's ASP_POSTMAN role - enforced on-chain, not re-checked
 *  client-side. Leaves are published BEFORE the root is anchored: if `updateRoot` then fails, the
 *  only cost is one wasted leaf-publish transaction (harmless); publishing leaves AFTER an
 *  already-anchored root would risk the worse failure mode of a root with no available
 *  reconstruction path if that second call failed. Returns the root's association-set index
 *  (decoded from the real `RootAnchored` event, not assumed from call ordering). */
export async function publishIdentityAspRoot(
  entrypointAddress: string,
  leafRegistryAddress: string,
  runner: ContractRunner,
  tree: IdentityAspTree,
): Promise<bigint> {
  const rootBytes32 = "0x" + tree.root.toString(16).padStart(64, "0");

  const leafRegistry = new Contract(leafRegistryAddress, LEAF_REGISTRY_ABI, runner);
  const alreadyPublished: boolean = await leafRegistry.published(rootBytes32);
  if (!alreadyPublished) {
    const leavesBytes32 = tree.leaves.map((leaf) => "0x" + leaf.toString(16).padStart(64, "0"));
    const leafTx = await leafRegistry.publishLeaves(rootBytes32, leavesBytes32);
    await leafTx.wait();
  }

  const entrypoint = new Contract(entrypointAddress, ENTRYPOINT_ABI, runner);
  // Entrypoint.sol enforces a 32-64 BYTE length on this field (InvalidIPFSCIDLength) - a real
  // IPFS CID's natural range, which this locator must also fit even though it isn't one.
  // "onchain:" (8) + a lowercase 40-hex-char address (40) = 48 bytes, comfortably inside that
  // range; the label is intentionally terse (just the registry address, not a description) to
  // leave headroom.
  const locator = `onchain:${leafRegistryAddress.toLowerCase().replace(/^0x/, "")}`;
  const tx = await entrypoint.updateRoot(tree.root, locator);
  const receipt = await tx.wait();

  const iface = new Interface(ENTRYPOINT_ABI as unknown as string[]);
  for (const log of (receipt?.logs ?? []) as Log[]) {
    let parsed;
    try {
      parsed = iface.parseLog(log);
    } catch {
      continue; // a log from a different contract/topic - not ours to decode
    }
    if (parsed?.name === "RootAnchored") return BigInt(parsed.args.index);
  }
  throw new Error("publishIdentityAspRoot: RootAnchored event not found in the transaction receipt");
}
