#!/usr/bin/env node
/*
 * Emit N escrow_envelope witnesses (Prover.escrow<i>.toml) for distinct identities.
 *
 * WHY MORE THAN ONE. The identity registry admits a commitment ONLY via `register`, which requires
 * a real escrow proof - there is deliberately no privileged insert, and adding a test-only one
 * would be exactly the mock this project forbids. A single registration leaves a one-leaf SMT whose
 * inclusion path is empty, so the withdrawal fixture built on it would hash NO SIBLINGS and prove
 * nothing about the Merkle path. Several genuine registrations are the only way to get a
 * non-degenerate tree out of the real contract.
 *
 * Deterministic: secrets are derived from the index, never random, because these become committed
 * fixtures and a random value makes them unreproducible.
 *
 *   node tools/build-escrow-fixtures.js 3
 */
const path = require('path');
const fs = require('fs');
const { createRequire } = require('module');
const walletRequire = createRequire(
  path.join(__dirname, '..', 'frontend', 'identity-wallet', 'package.json'),
);
const { babyJub, poseidon } = walletRequire('@iden3/js-crypto');
const crypto = require('crypto');

const N = parseInt(process.argv[2] || '3', 10);
const G = babyJub.Base8;
const F = babyJub.F;
const CIRCUIT = path.join(__dirname, '..', 'backend', 'circuits', 'escrow_envelope');

// The controller keypair pinned in pp/src/envelope.nr's tests.
const CONTROLLER_SK = 1234n;
const PK = babyJub.mulPointEScalar(G, CONTROLLER_SK);

// Identity 0 reuses pp/src/identity_asp.nr's published sk_identity, so the primary fixture stays
// the same identity every other test refers to.
const SK_IDENTITIES = [
  287325206580568373396753082727527032974277810276511506339905121597618812140n,
  111222333444555666777888999n,
  999888777666555444333222111n,
];

for (let i = 0; i < N; i++) {
  const sk = SK_IDENTITIES[i] ?? BigInt(1000 + i);
  const s = 987654321n + BigInt(i) * 1000n;   // revocation secret
  const r = 55555n + BigInt(i) * 7n;          // ephemeral - never 0, see envelope.nr

  // A distinct MRZ per identity, so each has its own dg1Hash and can be registered separately.
  const mrz =
    'P<GBRSMITH<<JOHN<ALEXANDER<<<<<<<<<<<<<<<<<<<' +
    // The passport NUMBER is what varies per identity. Nine digits, and it must land inside the
    // 88 chars kept below - an earlier version used .slice(0, 9) on a ten-digit string, which
    // truncated the very digit being varied and gave all three identities the SAME dg1Hash. That
    // would have surfaced far downstream as a DocumentBoundToAnotherHolder revert, since a document
    // hash may bind to exactly one holder.
    String(123456789 + i) + '7GBR8001019M3001017<<<<<<<<<<<<<<02';
  const dg1 = Buffer.alloc(95);
  Buffer.from(mrz.slice(0, 88), 'ascii').copy(dg1, 5);
  const digest = crypto.createHash('sha256').update(dg1).digest();

  // Registration's own packing: skip digest[0], read the remaining 31 bytes big-endian.
  let dg1Hash = 0n, place = 1n;
  for (let k = 0; k < 31; k++) { dg1Hash += place * BigInt(digest[31 - k]); place *= 256n; }

  const packed = [];
  for (let w = 0; w < 4; w++) {
    let acc = 0n;
    for (let j = 0; j < 31; j++) {
      const idx = w * 31 + j;
      acc = idx < 95 ? acc * 256n + BigInt(dg1[idx]) : acc * 256n;
    }
    packed.push(acc);
  }

  const pub = babyJub.mulPointEScalar(G, sk);
  const holderRoot = poseidon.hash([pub[0], pub[1]]);
  const c1 = babyJub.mulPointEScalar(G, r);
  const shared = babyJub.mulPointEScalar(PK, r);
  const sealed = [s, ...packed].map((v, k) =>
    F.add(v, poseidon.hash([shared[0], shared[1], BigInt(k)])));

  const toml = [
    `controller_x = "${PK[0]}"`, `controller_y = "${PK[1]}"`,
    `holder_root = "${holderRoot}"`, `commitment = "${poseidon.hash([s])}"`,
    `dg1_hash = "${dg1Hash}"`,
    `c1_x = "${c1[0]}"`, `c1_y = "${c1[1]}"`,
    `sealed = [${sealed.map((v) => `"${v}"`).join(', ')}]`,
    `sk_identity = "${sk}"`, `revocation_secret = "${s}"`, `ephemeral = "${r}"`,
    `dg1 = [${[...dg1].join(', ')}]`,
  ].join('\n') + '\n';

  fs.writeFileSync(path.join(CIRCUIT, `Prover.escrow${i}.toml`), toml);
  console.log(`escrow${i}: commitment=${poseidon.hash([s])} holderRoot=${holderRoot} dg1Hash=${dg1Hash}`);
}
console.log(`\nWrote ${N} witnesses. Prove each with bb, then register them via IdentityRegistry.`);
