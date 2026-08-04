#!/usr/bin/env node
/*
 * Builds N DISTINCT withdrawal witnesses for the folded batch, into withdraw_ivc_app/Prover.<i>.toml.
 *
 *   node tools/build-fold-witnesses.js --build <walletBuild> [--count 16]
 *
 * WHY THIS EXISTS RATHER THAN A LOOP OVER build-withdrawal-fixture.js. That script emits two
 * standalone fixtures, each against its OWN state tree. A batch is not two standalone withdrawals -
 * it is N spends against ONE tree at ONE root, and the shared root is the part that makes folding
 * them together mean anything. So the tree is built once here, filled with every note in the batch,
 * and only then are the N witnesses read out of it.
 *
 * WHAT THE OLD N=16 AGGREGATION FIXTURE ACTUALLY WAS, since it is easy to over-read: sixteen
 * IDENTICAL copies of one withdrawal (aggregate_withdrawals/Prover.toml holds the same 458 fields
 * and the same seven public signals sixteen times). It proved the aggregation circuit accepts
 * sixteen valid proofs. It could not have caught a fold that silently collapses its members - the
 * accumulator over sixteen copies of X is indistinguishable from one that keeps only the last X.
 * These witnesses differ in every signal that can differ, so that failure mode is visible.
 *
 * WHAT VARIES PER MEMBER, and what deliberately does not:
 *   varies:  note secrets, label, value, withdrawn_value, leaf index, change note, context, and the
 *            identity (cycling the three registered ones, each with its own sibling path)
 *   shared:  state_root and identity_root - forced, not chosen. Every member of a batch is settled
 *            against one pool state and one registry state, so a member carrying a different root is
 *            a member that cannot be in this batch.
 *
 * ONLY THREE IDENTITIES EXIST, so at N=16 they cycle. That is not a stand-in for sixteen people: one
 * identity making several withdrawals in a batch is ordinary, and three sibling paths is enough to
 * catch a fold that assumes one. Sixteen would need sixteen genuine escrow proofs, and those come
 * from build-escrow-fixtures.js + a passport proof each.
 *
 * PREREQUISITES, both of which fail loudly rather than silently:
 *   cd frontend/identity-wallet && npm run build:pp
 *   forge test --match-test test_EmitIdentityWitnessFixture      # writes identity_witness.json
 */
const path = require('path');
const common = require('./lib/fixture-common');

const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i > -1 ? process.argv[i + 1] : fallback;
};

const BUILD = path.resolve(arg('--build', path.join(__dirname, 'build')));
const COUNT = Number(arg('--count', '16'));

const { masterKeysFromMnemonic, depositSecrets, commitment, nullifierHash, StateTree,
  buildWithdrawalWitness } = common.loadWallet(BUILD);

const { MNEMONIC, SK_IDENTITIES, deriveRevocationSecret } = common;
const keys = masterKeysFromMnemonic(MNEMONIC);

const IDENTITY_COUNT = common.identityWitnessCount();
if (IDENTITY_COUNT > SK_IDENTITIES.length) {
  throw new Error(
    `the fixture holds ${IDENTITY_COUNT} identity witnesses but only ${SK_IDENTITIES.length} ` +
    'identity scalars are known - the two lists come from the same escrow fixtures and must match',
  );
}

const OUT_DIR = path.join(__dirname, '..', 'backend', 'circuits', 'withdraw_ivc_app');

/*
 * The batch, described before anything is derived.
 *
 * `value` and `withdrawn` both vary, so the change note is a different nonzero remainder for each
 * member. A batch where every member withdrew its note in full would never exercise the change-note
 * branch, and that branch is where the remainder lives.
 */
const members = Array.from({ length: COUNT }, (_, i) => ({
  index: i,
  identity: i % IDENTITY_COUNT,
  scope: 1000n + BigInt(i),
  label: 500_000n + BigInt(i) * 37n,
  value: (10n ** 18n) * BigInt(i + 1),
  withdrawn: (10n ** 17n) * BigInt(i + 1),
  // Distinct per member and nonzero. In production this binds the recipient and relayer fee; here it
  // only has to differ, so that two members can never produce the same seven signals.
  context: 42_424_242n + BigInt(i) * 101n,
}));

// ── one tree, built before any witness is read out of it ──────────────────────────────────────
// Filler leaves before and after the batch, for the same reason build-withdrawal-fixture.js uses
// them: a tree holding only our own leaves can be degenerate at the edges, and depth 0 hashes no
// sibling at all.
const stateTree = new StateTree();
for (const filler of [111n, 222n, 333n]) stateTree.insert(filler);

for (const m of members) {
  const secrets = depositSecrets(keys, m.scope, 0n);
  m.note = {
    scope: m.scope, label: m.label, index: 0, kind: 'deposit',
    nullifier: secrets.nullifier, secret: secrets.secret, value: m.value,
    commitment: commitment(m.value, m.label, secrets), spent: false,
  };
  m.leafIndex = BigInt(stateTree.leaves.length);
  stateTree.insert(m.note.commitment);
}
stateTree.insert(444n); // further pool activity after the batch closed

const seenNullifier = new Set();
const seenCommitment = new Set();
let sharedStateRoot = null;
let sharedIdentityRoot = null;

for (const m of members) {
  const identity = common.loadIdentityWitness(m.identity);
  const revocationSecret = deriveRevocationSecret(SK_IDENTITIES[m.identity]);

  const w = buildWithdrawalWitness({
    note: m.note,
    stateLeafIndex: m.leafIndex,
    stateTree,
    masterKeys: keys,
    identity,
    revocationSecret,
    withdrawnValue: m.withdrawn,
    context: m.context,
    withdrawalIndex: 0n,
  });

  // Cross-checks against something other than the assembler, member by member.
  const eq = (a, b, msg) => { if (a !== b) throw new Error(`member ${m.index}: ${msg}: ${a} != ${b}`); };
  eq(w.pubSignals[1], nullifierHash(m.note.nullifier), 'nullifier hash');
  eq(w.pubSignals[3], stateTree.root, 'state_root');
  eq(w.pubSignals[5], identity.identityRoot, 'identity_root');
  eq(w.pubSignals[0], commitment(m.value - m.withdrawn, m.label, w.changeNote), 'change note');
  eq(stateTree.leaves[Number(m.leafIndex)], m.note.commitment, 'state leaf index');
  if (w.pubSignals[4] === 0n) {
    throw new Error(`member ${m.index}: DEGENERATE - state tree depth 0, no sibling is hashed`);
  }

  // THE INVARIANT THE FOLD RESTS ON. One root for the whole batch; a member proving membership in a
  // different tree is proving something about a pool state this settlement is not settling.
  if (sharedStateRoot === null) {
    sharedStateRoot = w.pubSignals[3];
    sharedIdentityRoot = w.pubSignals[5];
  } else {
    eq(w.pubSignals[3], sharedStateRoot, 'state_root differs across the batch');
    eq(w.pubSignals[5], sharedIdentityRoot, 'identity_root differs across the batch');
  }

  // AND THE ONE THAT MAKES THE BATCH NON-TRIVIAL. Two members sharing a nullifier hash would be the
  // same note spent twice; two sharing a change commitment would collide in the state tree. Either
  // means the members are not actually distinct, which is the exact weakness of the old fixture.
  const nh = w.pubSignals[1].toString();
  if (seenNullifier.has(nh)) throw new Error(`member ${m.index}: duplicate nullifier hash ${nh}`);
  seenNullifier.add(nh);
  const nc = w.pubSignals[0].toString();
  if (seenCommitment.has(nc)) throw new Error(`member ${m.index}: duplicate change commitment ${nc}`);
  seenCommitment.add(nc);

  common.writeProverToml(path.join(OUT_DIR, `Prover.${m.index}.toml`), w.inputs);
  console.log(
    `  [${String(m.index).padStart(2)}] identity=${m.identity} leaf=${m.leafIndex} ` +
    `value=${m.value} withdrawn=${m.withdrawn} nullifierHash=0x${w.pubSignals[1].toString(16).slice(0, 12)}`,
  );
}

console.log(`\n${COUNT} distinct withdrawals -> ${path.relative(path.join(__dirname, '..'), OUT_DIR)}/Prover.<i>.toml`);
console.log(`  shared state_root    ${sharedStateRoot}`);
console.log(`  shared identity_root ${sharedIdentityRoot}`);
console.log(`  state tree: ${stateTree.leaves.length} leaves, depth ${stateTree.depth}`);
console.log(`  ${seenNullifier.size} distinct nullifier hashes, ${seenCommitment.size} distinct change commitments`);
