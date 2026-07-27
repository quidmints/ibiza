#!/usr/bin/env node
/*
 * Regenerates BOTH withdraw_identity Forge fixtures, deterministically.
 *
 * WHY THIS EXISTS. The original baseline fixture was weak on two counts, and both are the kind of
 * weakness that keeps a suite green while removing its meaning:
 *
 *  1. DEGENERATE TREES. It used size-1 state and ASP trees. With one leaf and all-zero siblings the
 *     LeanIMT carry-up rule makes the root EQUAL the leaf, so `state_tree_depth`/`asp_tree_depth`
 *     were 0 and NO sibling was ever hashed. The proof verified, but the Merkle path - the thing a
 *     withdrawal actually depends on - was never exercised at any depth.
 *  2. NOT REPRODUCIBLE. Its provenance comment said "regenerate: withdraw_identity/Prover.toml",
 *     but no Prover.toml was ever tracked. The fixture could not be rebuilt from the repo, so it
 *     could not be audited or regenerated after a circuit change.
 *
 * Both fixtures produced here use MULTI-LEVEL trees (state depth 3, ASP depth 2) over trees holding
 * unrelated filler leaves, so real sibling hashing is on the proven path in both.
 *
 * The two differ in the PROVENANCE of the spent note, deliberately - that is why both are kept:
 *   - baseline: the spent note is the hand vector (value 10, label 20, nullifier 30, secret 40) from
 *     pp/src/commitment.nr's differential test, whose commitment/nullifier_hash were cross-checked
 *     against poseidon-solidity. Independent of the wallet's derivation, so it still catches a
 *     wallet that is self-consistently wrong.
 *   - wallet: the spent note is derived through the wallet's own seed derivation. Proves the client
 *     can produce a withdrawal the chain accepts.
 *
 * USAGE (from the repo root):
 *   cd frontend/identity-wallet && npx tsc src/pp/withdrawWitness.ts \
 *     src/postman/identityAsp.ts --outDir <build> --module commonjs --target es2022 \
 *     --moduleResolution node --esModuleInterop --skipLibCheck
 *   node tools/build-withdrawal-fixture.js --build <build>
 *
 * then, per fixture:
 *   cd backend/circuits/withdraw_identity
 *   cp Prover.baseline.toml Prover.toml && nargo execute witness
 *   bb prove --scheme ultra_honk --oracle_hash keccak -b target/withdraw_identity.json \
 *     -w target/witness.gz -k target/vk -o target
 *   cp target/proof ../../contracts/test/fixtures/withdraw_identity.proof
 *   # ...and again with Prover.wallet.toml -> withdraw_identity_wallet.proof
 *
 * bb MUST be 1.2.0 - there are several installs on the dev machine, and the wrong one silently
 * produces a proof that bb's own verifier rejects (see backend/circuits/codegen-verifiers.sh).
 */
const path = require('path');
const fs = require('fs');

const argIdx = process.argv.indexOf('--build');
const BUILD = argIdx > -1 ? path.resolve(process.argv[argIdx + 1]) : path.join(__dirname, 'build');
if (!fs.existsSync(BUILD)) {
  console.error(`No compiled wallet modules at ${BUILD}. Run the tsc step in this file's header first.`);
  process.exit(1);
}

const { masterKeysFromMnemonic, depositSecrets, commitment, nullifierHash } = require(path.join(BUILD, 'pp/notes.js'));
const { StateTree } = require(path.join(BUILD, 'pp/stateTree.js'));
const { IdentityAspTree } = require(path.join(BUILD, 'postman/identityAsp.js'));
const { buildWithdrawalWitness } = require(path.join(BUILD, 'pp/withdrawWitness.js'));
// holderRoot derivation comes from the ASSEMBLER ITSELF (holderRootFromSk), not a local copy and
// not the SDK. The ASP tree is keyed by this value, so the tree-builder and the circuit must agree
// exactly; exporting one function is what stops a second implementation drifting. It also keeps
// this script loadable in plain Node - the SDK is a React Native package whose Noir module pulls in
// expo, which cannot load outside RN.
const { holderRootFromSk } = require(path.join(BUILD, 'pp/withdrawWitness.js'));

// Foundry's standard test mnemonic. Nothing here guards value; it must simply be fixed.
const MNEMONIC = 'test test test test test test test test test test test junk';
const keys = masterKeysFromMnemonic(MNEMONIC);

// Pinned to pp/src/identity_asp.nr's published vector. FIXED, never random - these witnesses become
// committed fixtures, so a random value would make them unreproducible.
const SK_IDENTITY = 1234n;
const HOLDER_ROOT = holderRootFromSk(SK_IDENTITY);

const CONTEXT = 42_424_242n;
const CIRCUIT_DIR = path.join(__dirname, '..', 'backend', 'circuits', 'withdraw_identity');

/** Trees that are NEVER degenerate: filler leaves before and after ours force real depth. */
function buildTrees(spentCommitment) {
  const stateTree = new StateTree();
  for (const filler of [111n, 222n, 333n]) stateTree.insert(filler);
  stateTree.insert(spentCommitment);
  const stateLeafIndex = BigInt(stateTree.leaves.length - 1);
  stateTree.insert(444n); // further activity after ours

  const aspTree = new IdentityAspTree([777n, 888n]);
  aspTree.insert(HOLDER_ROOT);
  aspTree.insert(999n);

  return { stateTree, stateLeafIndex, aspTree };
}

function emit(name, note, withdrawnValue) {
  const { stateTree, stateLeafIndex, aspTree } = buildTrees(note.commitment);

  const w = buildWithdrawalWitness({
    note, stateLeafIndex, stateTree, aspTree,
    masterKeys: keys, skIdentity: SK_IDENTITY, withdrawnValue, context: CONTEXT,
    withdrawalIndex: 0n,
  });

  // Independent cross-checks - not "the assembler agrees with itself".
  const eq = (a, b, m) => { if (a !== b) throw new Error(`${name}: ${m}: ${a} != ${b}`); };
  eq(w.pubSignals[1], nullifierHash(note.nullifier), 'nullifier hash');
  eq(w.pubSignals[3], stateTree.root, 'state_root');
  eq(w.pubSignals[5], aspTree.root, 'asp_root');
  eq(w.pubSignals[0], commitment(note.value - withdrawnValue, note.label, w.changeNote), 'change note');
  eq(stateTree.leaves[Number(stateLeafIndex)], note.commitment, 'state leaf index');

  // The guard this whole file exists for.
  if (w.pubSignals[4] === 0n || w.pubSignals[6] === 0n) {
    throw new Error(`${name}: DEGENERATE - a tree has depth 0, so no sibling is hashed. Add filler leaves.`);
  }

  const toml = Object.entries(w.inputs).map(([k, v]) =>
    Array.isArray(v) ? `${k} = [${v.map(x => `"${x}"`).join(', ')}]` : `${k} = "${v}"`
  ).join('\n') + '\n';
  const out = path.join(CIRCUIT_DIR, `Prover.${name}.toml`);
  fs.writeFileSync(out, toml);

  console.log(`\n${name}:  state_depth=${w.pubSignals[4]}  asp_depth=${w.pubSignals[6]}`);
  ['new_commitment', 'existing_nullifier_hash', 'withdrawn_value', 'state_root',
   'state_tree_depth', 'asp_root', 'asp_tree_depth', 'context']
    .forEach((n, i) => console.log(`  [${i}] ${n} = 0x${w.pubSignals[i].toString(16).padStart(64, '0')}`));
  console.log(`  -> ${path.relative(path.join(__dirname, '..'), out)}`);
}

// baseline: independent hand vector from pp/src/commitment.nr's differential test
const HAND = { value: 10n, label: 20n, nullifier: 30n, secret: 40n };
emit('baseline', {
  scope: 0n, label: HAND.label, index: 0, kind: 'deposit',
  nullifier: HAND.nullifier, secret: HAND.secret, value: HAND.value,
  commitment: commitment(HAND.value, HAND.label, { nullifier: HAND.nullifier, secret: HAND.secret }),
  spent: false,
}, 4n);

// wallet: the client's own seed derivation
const scope = 12345n, label = 67890n;
const note0 = depositSecrets(keys, scope, 0n);
const value = 10n ** 18n;
emit('wallet', {
  scope, label, index: 0, kind: 'deposit',
  nullifier: note0.nullifier, secret: note0.secret, value,
  commitment: commitment(value, label, note0), spent: false,
}, 3n * 10n ** 17n);
