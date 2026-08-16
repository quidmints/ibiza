// BIP-341 hashing for the swap-in deposit address — the part of the QR verifier that decides
// whether the hop is bound to the terms it showed you.
//
// 🔑 **THE ADDRESS IS THE OUTPUT, NEVER AN INPUT.** A verifier that recomputes a hop-supplied
// address from hop-supplied values proves only that the hop is self-consistent, which was never
// in doubt. Everything here is fed from what the WALLET owns (`userRefund`, `seller`) or what the
// USER WAS SHOWN AND ACCEPTED (`token`, `minDeliveredUsd`, `cltvHeight`) — and the quoted address
// is compared against the result, never mixed into it.
//
// ⚠️ **THIS FILE IS THE HASH LAYER ONLY, AND THAT IS DELIBERATE.** Turning a merkle root into a
// `bc1p…` address additionally needs (a) the BIP-341 TapTweak, which is an EC point add over
// secp256k1, and (b) bech32m. Neither is here, because neither should be hand-rolled —
// `@scure/btc-signer` (same maintainer as the `@noble/*` packages already in this wallet) is the
// intended source and is not yet a dependency. **Landing the hashing separately is what lets it
// be pinned against the Solidity and Rust suites today** rather than waiting on that decision.
//
// ⚠️ **`refundLeafScript` IS NOT HERE EITHER, AND MUST BE TRANSCRIBED, NOT GUESSED.** The refund
// leaf is `<cltvHeight> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG`, built by
// `ExitLib._cltvRefundLeaf` in SPV — but the exact minimal-push encoding of `cltvHeight` decides
// the leaf hash, and a wrong encoding yields a valid-looking leaf that simply is not the one on
// chain. Copy it from `ExitLib`, byte for byte, and pin it with a shared fixture.

import { ethers } from 'ethers'

const bytes = (hex: string) => ethers.getBytes(hex.startsWith('0x') ? hex : `0x${hex}`)

/// BIP-340 tagged hash: `sha256(sha256(tag) ‖ sha256(tag) ‖ msg)`.
///
/// The doubled tag hash is not decoration — it is what domain-separates a leaf from a branch, so
/// a leaf cannot be presented as an internal node and a merkle proof cannot admit a script that
/// was never committed.
export function taggedHash(tag: string, msg: Uint8Array): string {
  const t = ethers.sha256(ethers.toUtf8Bytes(tag))
  return ethers.sha256(ethers.concat([t, t, msg]))
}

/// BIP-341 TapLeaf hash for one script leaf, at the only leaf version taproot defines (`0xc0`).
///
/// ⚠️ Scripts of 253 bytes or more are refused rather than given a wrong compact-size prefix: a
/// mis-encoded length hashes to a plausible leaf that is not the one on chain, which is precisely
/// the silent failure this verifier exists to catch. Mirrors `MuSig2Agg.tapLeafHash`'s guard.
export function tapLeafHash(scriptHex: string): string {
  const script = bytes(scriptHex)
  if (script.length >= 0xfd) throw new Error('tapLeafHash: leaf script too long')
  return taggedHash(
    'TapLeaf',
    ethers.getBytes(ethers.concat([new Uint8Array([0xc0, script.length]), script])),
  )
}

/// BIP-341 TapBranch: combine two child hashes into their parent, children sorted.
///
/// 🔑 The sort is consensus, not tidiness — BIP-341 orders children lexicographically so a merkle
/// path need not record which side each sibling was on. Concatenating in call order computes a
/// root Bitcoin does not agree with, and the address derived from it is simply never paid.
export function tapBranch(a: string, b: string): string {
  const [lo, hi] = BigInt(a) <= BigInt(b) ? [a, b] : [b, a]
  return taggedHash('TapBranch', ethers.getBytes(ethers.concat([lo, hi])))
}

/// The unspendable leaf that commits the swap's TERMS, so the hop cannot restate them.
///
/// `OP_RETURN <32-byte commitment>` — provably unspendable, present purely so the deposit address
/// commits to who is credited and on what basis. §T2 in `SPV/docs/actionable/HOP-TRUST-AUDIT.md`.
///
/// ⚠️ The ABI encoding must match the Solidity side EXACTLY (`abi.encode`, not `encodePacked` —
/// packed encoding is ambiguous across dynamic types and two different quotes could collide).
export function termsLeafScript(
  seller: string,
  token: string,
  minDeliveredUsd: bigint,
): string {
  const commitment = ethers.sha256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'uint256'],
      [seller, token, minDeliveredUsd],
    ),
  )
  // 0x6a = OP_RETURN, 0x20 = PUSH32.
  return ethers.concat(['0x6a20', commitment])
}

/// The merkle root a two-leaf deposit address commits to.
export function depositMerkleRoot(refundLeafHex: string, termsLeafHex: string): string {
  return tapBranch(tapLeafHash(refundLeafHex), tapLeafHash(termsLeafHex))
}
