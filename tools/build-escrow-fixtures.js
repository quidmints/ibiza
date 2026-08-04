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
 * ───────────────────────────────────────────────────────────────────────────────────────────────
 * TWO PASSES, BECAUSE THE CIRCUIT NOW PROVES SMT INCLUSION (TODO.md sec. 2.18).
 *
 * escrow_envelope no longer publishes `holder_root`/`dg1_hash`; it proves the document's own leaf
 * is in `StateKeeper.registrationSmt`. That witness cannot be computed here - it comes from the
 * REAL contract, for exactly the reason fixture-common.js's `loadIdentityWitness` already gives:
 * a witness built off-chain would only prove that two of our own implementations agree, and would
 * need a second sparse-trie implementation kept byte-compatible forever.
 *
 *   1.  node tools/build-escrow-fixtures.js --documents 3
 *         -> backend/contracts/test/fixtures/escrow_documents.json
 *   2.  forge test --match-test test_EmitRegistrationWitnessFixture
 *         -> backend/contracts/test/fixtures/registration_witness.json
 *   3.  node tools/build-escrow-fixtures.js 3
 *         -> backend/circuits/escrow_envelope/Prover.escrow<i>.toml
 *
 * ───────────────────────────────────────────────────────────────────────────────────────────────
 * `dgCommit` IS TAKEN FROM THE CIRCUIT, NOT REIMPLEMENTED HERE.
 *
 * The leaf value is `Poseidon(dgCommit, seq, timestamp)` where
 * `dgCommit = extract_dg1_commitment(dg1, sk_identity)` - four chunks of the DG1 BIT stream, packed
 * LSB-first over MSB-first bytes, then a Poseidon of `sk_identity` appended. Writing that in
 * JavaScript would be a second implementation of a convention with three separate places to get the
 * endianness wrong, and a mistake would surface only as an inclusion failure with no diagnostic.
 *
 * So this script SHELLS OUT to `nargo execute` on register_identity_light_td1 - the very circuit
 * whose output the contract stores - and reads `dgCommit` from it. Slower, and correct by
 * construction. (Cross-checked: for identity 0 the circuit's `dg1_hash` and `sk_hash` outputs equal
 * the values this script computes independently, so the DG1 byte layout below is confirmed against
 * the circuit rather than assumed.)
 */
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { createRequire } = require('module');
const walletRequire = createRequire(
  path.join(__dirname, '..', 'frontend', 'identity-wallet', 'package.json'),
);
const { babyJub, poseidon } = walletRequire('@iden3/js-crypto');
const crypto = require('crypto');

const DOCUMENTS_MODE = process.argv.includes('--documents');
const N = parseInt(process.argv.find((a) => /^\d+$/.test(a)) || '3', 10);

const G = babyJub.Base8;
const F = babyJub.F;
const ROOT = path.join(__dirname, '..');
const CIRCUIT = path.join(ROOT, 'backend', 'circuits', 'escrow_envelope');
const LIGHT_CIRCUIT = path.join(ROOT, 'backend', 'circuits', 'register_identity_light_td1');
const FIXTURES = path.join(ROOT, 'backend', 'contracts', 'test', 'fixtures');
const DOCUMENTS_JSON = path.join(FIXTURES, 'escrow_documents.json');
const WITNESS_JSON = path.join(FIXTURES, 'registration_witness.json');

/** Height of StateKeeper.registrationSmt. MUST equal escrow_envelope's REGISTRATION_TREE_DEPTH. */
const REGISTRATION_TREE_DEPTH = 80;

// The revocation secret is DERIVED, no longer chosen (TODO.md sec. 2.18a) - see fixture-common.js,
// which owns the derivation because the withdrawal and e2e generators need the identical value.
// SK_IDENTITIES moved there too once the fold generator began spending against these same
// registrations - it must derive the secret this file escrowed, so there can only be one list.
const { deriveRevocationSecret, skIdentity } = require('./lib/fixture-common');

// The controller keypair pinned in pp/src/envelope.nr's tests.
const CONTROLLER_SK = 1234n;
const PK = babyJub.mulPointEScalar(G, CONTROLLER_SK);

/** The 95-byte TD1 DG1 for identity `i`. */
function buildDg1(i) {
  // A distinct MRZ per identity, so each has its own dg1Hash and can be registered separately.
  const mrz =
    'P<GBRSMITH<<JOHN<ALEXANDER<<<<<<<<<<<<<<<<<<<' +
    // The passport NUMBER is what varies per identity. Nine digits, and it must land inside the
    // 88 chars kept below - an earlier version used .slice(0, 9) on a ten-digit string, which
    // truncated the very digit being varied and gave all three identities the SAME dg1Hash. That
    // would have surfaced far downstream as a document-hash collision, since a document hash may
    // bind to exactly one holder.
    String(123456789 + i) + '7GBR8001019M3001017<<<<<<<<<<<<<<02';
  const dg1 = Buffer.alloc(95);
  Buffer.from(mrz.slice(0, 88), 'ascii').copy(dg1, 5);
  return dg1;
}

/** Registration's own digest packing: skip digest[0], read the remaining 31 bytes big-endian. */
function dg1HashOf(dg1) {
  const digest = crypto.createHash('sha256').update(dg1).digest();
  let h = 0n, place = 1n;
  for (let k = 0; k < 31; k++) { h += place * BigInt(digest[31 - k]); place *= 256n; }
  return h;
}

/** The MRZ packed for the envelope payload: big-endian, 31 bytes per field. */
function packDg1(dg1) {
  const packed = [];
  for (let w = 0; w < 4; w++) {
    let acc = 0n;
    for (let j = 0; j < 31; j++) {
      const idx = w * 31 + j;
      acc = idx < 95 ? acc * 256n + BigInt(dg1[idx]) : acc * 256n;
    }
    packed.push(acc);
  }
  return packed;
}

/**
 * Ask register_identity_light_td1 for `(dgCommit, dg1Hash, skHash)`.
 *
 * THE OUTPUTS ARE CROSS-CHECKED against this script's own `dg1HashOf` and `holderRoot`. Those two
 * we CAN compute here (sha256 and a Poseidon of a curve point, both unambiguous), so if they agree
 * with the circuit then the DG1 byte layout fed to it is the same one this script built - which is
 * what licenses trusting the circuit for `dgCommit`, the one value we cannot independently derive.
 */
function dgCommitFromCircuit(dg1, sk, expectedDg1Hash, expectedHolderRoot) {
  fs.writeFileSync(
    path.join(LIGHT_CIRCUIT, 'Prover.toml'),
    `dg1 = [${[...dg1].join(', ')}]\nsk_identity = "${sk}"\n`,
  );
  const out = execFileSync('nargo', ['execute', 'escrowfixture'], {
    cwd: LIGHT_CIRCUIT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  });
  const m = out.match(/Circuit output: \((0x[0-9a-f]+), (0x[0-9a-f]+), (0x[0-9a-f]+)\)/);
  if (!m) throw new Error(`could not parse nargo output:\n${out}`);
  const [dgCommit, dg1Hash, skHash] = [BigInt(m[1]), BigInt(m[2]), BigInt(m[3])];

  if (dg1Hash !== expectedDg1Hash) {
    throw new Error(
      `dg1Hash disagrees with the circuit (${dg1Hash} vs ${expectedDg1Hash}) - the DG1 byte layout ` +
      'built here is not the one the circuit hashed, so dgCommit cannot be trusted either',
    );
  }
  if (skHash !== expectedHolderRoot) {
    throw new Error(`holderRoot disagrees with the circuit: ${skHash} vs ${expectedHolderRoot}`);
  }
  return dgCommit;
}

/** Everything about identity `i` that does not depend on the registration tree. */
function identity(i) {
  const sk = skIdentity(i);
  const r = 55555n + BigInt(i) * 7n; // ephemeral - never 0, see envelope.nr
  const s = deriveRevocationSecret(sk);

  const dg1 = buildDg1(i);
  const dg1Hash = dg1HashOf(dg1);
  const pub = babyJub.mulPointEScalar(G, sk);
  const holderRoot = poseidon.hash([pub[0], pub[1]]);

  const c1 = babyJub.mulPointEScalar(G, r);
  const shared = babyJub.mulPointEScalar(PK, r);
  const sealed = [s, ...packDg1(dg1)].map((v, k) =>
    F.add(v, poseidon.hash([shared[0], shared[1], BigInt(k)])));

  return {
    index: i,
    skIdentity: sk,
    ephemeral: r,
    revocationSecret: s,
    commitment: poseidon.hash([s]),
    dg1: [...dg1],
    dg1Hash,
    holderRoot,
    // Chosen here, not derived: `documentKey` is unconstrained by any proof (TODO.md sec. 2.13f).
    // Soundness rests on the leaf VALUE, which carries dgCommit.
    documentKey: BigInt(0xd0c) + BigInt(i),
    c1x: c1[0],
    c1y: c1[1],
    sealed,
  };
}

const identities = Array.from({ length: N }, (_, i) => identity(i));

if (DOCUMENTS_MODE) {
  for (const id of identities) {
    id.dgCommit = dgCommitFromCircuit(
      Buffer.from(id.dg1), id.skIdentity, id.dg1Hash, id.holderRoot,
    );
    console.log(
      `escrow${id.index}: commitment=${id.commitment} dgCommit=${id.dgCommit} ` +
      `documentKey=${id.documentKey}`,
    );
  }
  fs.mkdirSync(FIXTURES, { recursive: true });
  fs.writeFileSync(DOCUMENTS_JSON, JSON.stringify({
    documents: identities.map((id) => ({
      documentKey: '0x' + id.documentKey.toString(16).padStart(64, '0'),
      documentHash: '0x' + id.dg1Hash.toString(16).padStart(64, '0'),
      holderRoot: '0x' + id.holderRoot.toString(16).padStart(64, '0'),
      dgCommit: id.dgCommit.toString(),
    })),
  }, null, 2) + '\n');
  console.log(
    `\nWrote ${N} documents to ${path.relative(ROOT, DOCUMENTS_JSON)}.\n` +
    'Next:  forge test --match-test test_EmitRegistrationWitnessFixture\n' +
    `Then:  node ${path.relative(ROOT, __filename)} ${N}`,
  );
  process.exit(0);
}

// ── pass 2: the registration witness exists, so the Prover.toml files can be written ──────────

if (!fs.existsSync(WITNESS_JSON)) {
  console.error(
    `No registration witness at ${WITNESS_JSON}.\nRun, in order:\n` +
    `  node ${path.relative(ROOT, __filename)} --documents ${N}\n` +
    '  forge test --match-test test_EmitRegistrationWitnessFixture',
  );
  process.exit(1);
}
const witness = JSON.parse(fs.readFileSync(WITNESS_JSON, 'utf8'));
const documents = JSON.parse(fs.readFileSync(DOCUMENTS_JSON, 'utf8')).documents;

if (witness.count < N) {
  console.error(`witness has ${witness.count} entries, need ${N}`);
  process.exit(1);
}

for (const id of identities) {
  const siblings = witness[`siblings${id.index}`].map((x) => BigInt(x));
  const seq = BigInt(witness[`seq${id.index}`]);
  const timestamp = BigInt(witness[`timestamp${id.index}`]);

  // A witness longer than the circuit's fixed array cannot be padded into one; a shorter one pads
  // with zeros, which is what the gadget's `smt_level_ins` expects at the top of the path.
  if (siblings.length > REGISTRATION_TREE_DEPTH) {
    throw new Error(
      `escrow${id.index}: witness depth ${siblings.length} exceeds the circuit's ` +
      `${REGISTRATION_TREE_DEPTH} - tree and circuit must be regenerated together`,
    );
  }
  // Every-sibling-zero means a single-leaf tree: nothing would ever be hashed, so the inclusion
  // proof would assert nothing about the path it claims to walk. The same degeneracy check
  // fixture-common.js already applies to the identity tree.
  if (siblings.every((x) => x === 0n)) {
    throw new Error(
      `escrow${id.index}: DEGENERATE witness - every sibling is zero. The emitter must bind more ` +
      'than one document.',
    );
  }
  while (siblings.length < REGISTRATION_TREE_DEPTH) siblings.push(0n);

  const expected = BigInt(documents[id.index].dgCommit);

  const toml = [
    `controller_x = "${PK[0]}"`, `controller_y = "${PK[1]}"`,
    `commitment = "${id.commitment}"`,
    `registration_root = "${BigInt(witness.root)}"`,
    `c1_x = "${id.c1x}"`, `c1_y = "${id.c1y}"`,
    `sealed = [${id.sealed.map((v) => `"${v}"`).join(', ')}]`,
    `sk_identity = "${id.skIdentity}"`, `ephemeral = "${id.ephemeral}"`,
    `dg1 = [${id.dg1.join(', ')}]`,
    `document_key = "${id.documentKey}"`,
    `document_seq = "${seq}"`,
    `document_timestamp = "${timestamp}"`,
    `registration_siblings = [${siblings.map((v) => `"${v}"`).join(', ')}]`,
  ].join('\n') + '\n';

  fs.writeFileSync(path.join(CIRCUIT, `Prover.escrow${id.index}.toml`), toml);
  console.log(
    `escrow${id.index}: commitment=${id.commitment} dgCommit=${expected} ` +
    `seq=${seq} ts=${timestamp}`,
  );
}
console.log(
  `\nWrote ${N} witnesses against registration root ${BigInt(witness.root)}.\n` +
  'Prove each with bb, then register them via IdentityRegistry.',
);
