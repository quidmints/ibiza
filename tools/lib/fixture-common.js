/*
 * Shared by tools/build-withdrawal-fixture.js and tools/build-e2e-fixture.js.
 *
 * WHY TWO ENTRY POINTS AND ONE LIBRARY. The e2e generator has to live at
 * `tools/build-e2e-fixture.js` specifically, because WithdrawEndToEnd.t.sol names that exact path as
 * its fixture provenance - folding it into the other script as a flag would leave that reference
 * pointing at nothing, which is the very defect that made it necessary to write. But the two
 * scripts were then carrying the same mnemonic, the same escrow secret, the same identity-witness
 * loader and the same TOML writer, so a change to any of them had to be made twice or silently
 * drift. The entry points stay separate; the logic does not.
 */
const path = require('path');
const fs = require('fs');

/** Foundry's standard test mnemonic. Nothing here guards value; it must simply be FIXED. */
const MNEMONIC = 'test test test test test test test test test test test junk';

/**
 * escrow0's revocation secret. Its Poseidon commitment IS the identity tree's key, so every
 * withdrawal fixture must use THIS secret or its inclusion proof is for someone else's leaf.
 * Must match tools/build-escrow-fixtures.js.
 */
const REVOCATION_SECRET = 987654321n;

const IDENTITY_WITNESS_PATH = path.join(
  __dirname, '..', '..', 'backend', 'contracts', 'test', 'fixtures', 'identity_witness.json',
);

/**
 * Load the compiled wallet modules.
 *
 * The build MUST sit inside frontend/identity-wallet, or these cannot resolve @iden3/js-crypto -
 * node walks UP from a file's own directory looking for node_modules, and tools/ has none above it.
 */
function loadWallet(buildDir) {
  if (!fs.existsSync(buildDir)) {
    console.error(
      `No compiled wallet modules at ${buildDir}.\n` +
      'cd frontend/identity-wallet && npx tsc src/pp/withdrawWitness.ts --outDir ./build \\\n' +
      '  --rootDir src --module commonjs --target es2022 --moduleResolution node \\\n' +
      '  --esModuleInterop --skipLibCheck\n\n' +
      '--rootDir src is REQUIRED: with a single input file tsc infers the root as src/pp and emits a\n' +
      'FLAT build, so the pp/ prefix these scripts require disappears.',
    );
    process.exit(1);
  }
  return {
    ...require(path.join(buildDir, 'pp/notes.js')),
    ...require(path.join(buildDir, 'pp/stateTree.js')),
    ...require(path.join(buildDir, 'pp/withdrawWitness.js')),
  };
}

/**
 * The identity inclusion witness, emitted by the REAL registry.
 *
 * Never rebuilt off-chain: the identity tree is a @solarity SparseMerkleTree and there is
 * deliberately no JS reimplementation of one (see frontend/identity-wallet/src/pp/identityProof.ts).
 * A witness built here would only prove that two of our own implementations agree.
 */
function loadIdentityWitness() {
  if (!fs.existsSync(IDENTITY_WITNESS_PATH)) {
    console.error(
      `No identity witness at ${IDENTITY_WITNESS_PATH}.\n` +
      'Run:  forge test --match-test test_EmitIdentityWitnessFixture',
    );
    process.exit(1);
  }
  const raw = JSON.parse(fs.readFileSync(IDENTITY_WITNESS_PATH, 'utf8'));
  const witness = {
    identityRoot: BigInt(raw.root),
    siblings: raw.siblings.map((x) => BigInt(x)),
  };
  // A tree with one leaf has an EMPTY path, so nothing would ever be hashed and the fixture would
  // prove nothing about the Merkle path it claims to walk.
  if (witness.siblings.every((x) => x === 0n)) {
    throw new Error(
      'identity witness is DEGENERATE - every sibling is zero. The emitter must register more than ' +
      'one identity.',
    );
  }
  return witness;
}

/** Write a Noir Prover.toml from an inputs map. */
function writeProverToml(outPath, inputs) {
  const toml = Object.entries(inputs).map(([k, v]) =>
    Array.isArray(v) ? `${k} = [${v.map((x) => `"${x}"`).join(', ')}]` : `${k} = "${v}"`
  ).join('\n') + '\n';
  fs.writeFileSync(outPath, toml);
  return outPath;
}

/** The seven public signals, named, for logging a generated witness. */
const PUBLIC_SIGNAL_NAMES = [
  'new_commitment', 'existing_nullifier_hash', 'withdrawn_value', 'state_root',
  'state_tree_depth', 'identity_root', 'context',
];

function logPublicSignals(pubSignals) {
  PUBLIC_SIGNAL_NAMES.forEach((n, i) => console.log(`  [${i}] ${n} = ${pubSignals[i]}`));
}

module.exports = {
  MNEMONIC, REVOCATION_SECRET, IDENTITY_WITNESS_PATH,
  loadWallet, loadIdentityWitness, writeProverToml, PUBLIC_SIGNAL_NAMES, logPublicSignals,
};
