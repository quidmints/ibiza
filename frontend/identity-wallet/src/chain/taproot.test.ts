// Run: node --test src/chain/taproot.test.ts
//
// THE BINDING ASSERTION IS THE SHARED FIXTURE. `tapBranch` is pinned to the SAME value that
// `SPV/evm/test/TapBranch.t.sol` and `quid-hop/src/swap_in_onchain.rs` assert — a number already
// agreed by three independent implementations (Solidity `taggedHash`, a python rebuild from raw
// sha256, and rust-bitcoin's consensus-tested `TapNodeHash`). A fourth implementation agreeing
// with them is worth something; a fourth agreeing only with itself is not.
import test from 'node:test'
import assert from 'node:assert'
import { ethers } from 'ethers'

import { taggedHash, tapLeafHash, tapBranch, termsLeafScript, depositMerkleRoot, scriptNum, refundLeafScript } from './taproot.ts'

const A = ethers.keccak256(ethers.toUtf8Bytes('leaf-a'))
const B = ethers.keccak256(ethers.toUtf8Bytes('leaf-b'))
const CROSS_VERIFIED =
  '0x210f9a7d980626b9556bbc01c6a1bbf0a3aa311f8ba36181ae6477a47df8d206'

test('tapBranch matches the value Solidity, python and rust-bitcoin already agree on', () => {
  assert.strictEqual(tapBranch(A, B), CROSS_VERIFIED)
})

test('children are sorted, so call order cannot change the parent', () => {
  assert.strictEqual(tapBranch(A, B), tapBranch(B, A))
})

test('a branch is not a leaf — the tagged hash must domain-separate', () => {
  assert.notStrictEqual(tapBranch(A, A), tapLeafHash(A))
})

test('taggedHash is the BIP-340 construction, not sha256 of the tag and message', () => {
  // Guards the doubled tag hash specifically: dropping one copy is a silent, plausible bug.
  const t = ethers.sha256(ethers.toUtf8Bytes('TapBranch'))
  assert.strictEqual(
    taggedHash('TapBranch', ethers.getBytes(ethers.concat([A, B]))),
    ethers.sha256(ethers.concat([t, t, A, B])),
  )
  assert.notStrictEqual(
    taggedHash('TapBranch', ethers.getBytes(A)),
    ethers.sha256(ethers.concat([t, A])),
  )
})

test('an over-long leaf script is refused rather than mis-prefixed', () => {
  assert.throws(() => tapLeafHash('0x' + 'ab'.repeat(253)), /too long/)
})

test('the terms leaf is OP_RETURN + PUSH32 and is sensitive to every field', () => {
  const s = '0x' + '11'.repeat(20)
  const t = '0x' + '22'.repeat(20)
  const base = termsLeafScript(s, t, 1000n)

  assert.ok(base.startsWith('0x6a20'), `expected OP_RETURN PUSH32, got ${base.slice(0, 6)}`)
  assert.strictEqual(ethers.getBytes(base).length, 34)

  // ⚠️ THE POINT OF THE LEAF: changing ANY committed term must change the address. If one of
  // these ever stops differing, the hop can restate that field and the deposit still matches.
  assert.notStrictEqual(base, termsLeafScript('0x' + '33'.repeat(20), t, 1000n), 'seller')
  assert.notStrictEqual(base, termsLeafScript(s, '0x' + '44'.repeat(20), 1000n), 'token')
  assert.notStrictEqual(base, termsLeafScript(s, t, 1001n), 'minDeliveredUsd')
})

test('the merkle root changes when either leaf does', () => {
  const refund = '0x' + 'cd'.repeat(40)
  const terms = termsLeafScript('0x' + '11'.repeat(20), '0x' + '22'.repeat(20), 7n)
  const root = depositMerkleRoot(refund, terms)

  assert.notStrictEqual(root, depositMerkleRoot('0x' + 'ce'.repeat(40), terms), 'refund leaf')
  assert.notStrictEqual(
    root,
    depositMerkleRoot(refund, termsLeafScript('0x' + '11'.repeat(20), '0x' + '22'.repeat(20), 8n)),
    'terms leaf',
  )
})

test('scriptNum is little-endian, minimal, and pads only when the top bit is set', () => {
  // Derived from Bitcoin's rule rather than from the implementation, so this is a real check.
  assert.strictEqual(scriptNum(0), '0x00', 'ExitLib returns a single 0x00, not an empty push')
  assert.strictEqual(scriptNum(1), '0x01')
  assert.strictEqual(scriptNum(0x7f), '0x7f', 'high bit clear: no pad')
  assert.strictEqual(scriptNum(0x80), '0x8000', 'high bit SET: pad, or it reads negative')
  assert.strictEqual(scriptNum(0xff), '0xff00')
  assert.strictEqual(scriptNum(0x0100), '0x0001', 'little-endian')
  assert.strictEqual(scriptNum(500000), '0x20a107', '0x07A120 LE, top byte 0x07, no pad')
  assert.strictEqual(scriptNum(0xffffffff), '0xffffffff00')
  assert.throws(() => scriptNum(-1), /uint32/)
  assert.throws(() => scriptNum(0x1_0000_0000), /uint32/)
})

test('the refund leaf is the exact opcode sequence ExitLib builds', () => {
  const key = '0x' + 'ab'.repeat(32)
  const leaf = refundLeafScript(key, 500000)
  // PUSH3 20a107 | b1 OP_CLTV | 75 OP_DROP | 20 PUSH32 <key> | ac OP_CHECKSIG
  assert.strictEqual(leaf, '0x0320a107b17520' + 'ab'.repeat(32) + 'ac')
  assert.strictEqual(ethers.getBytes(leaf).length, 1 + 3 + 1 + 1 + 1 + 32 + 1)
})

test('the padded height changes the leaf, so the pad is load-bearing', () => {
  const key = '0x' + 'cd'.repeat(32)
  assert.notStrictEqual(refundLeafScript(key, 0x80), refundLeafScript(key, 0x0080 + 1))
  assert.ok(refundLeafScript(key, 0x80).startsWith('0x028000b175'), 'pad byte missing')
})

test('a wrong-width refund key is refused', () => {
  assert.throws(() => refundLeafScript('0xdeadbeef', 1), /32 bytes/)
})
