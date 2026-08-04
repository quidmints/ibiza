#!/usr/bin/env node
/*
 * Builds N DISTINCT withdrawal witnesses for a batch, into batch-witnesses/Prover.<i>.toml.
 *
 *   node tools/build-fold-witnesses.js --build <walletBuild> [--count 16]
 *
 * WHY THIS EXISTS RATHER THAN A LOOP OVER build-withdrawal-fixture.js. That script emits two
 * standalone fixtures, each against its OWN state tree. A batch is not two standalone withdrawals -
 * it is N spends against ONE tree at ONE root, and the shared root is the part that makes batching
 * them mean anything. So the tree is built once here, filled with every note in the batch,
 * and only then are the N witnesses read out of it.
 *
 * WHAT THE OLD N=16 AGGREGATION FIXTURE ACTUALLY WAS, since it is easy to over-read: sixteen
 * IDENTICAL copies of one withdrawal. It proved the aggregation circuit accepts sixteen valid
 * proofs. It could not have caught a batch that silently collapses its members - a commitment over
 * sixteen copies of X is indistinguishable from one that keeps only the last X. These witnesses
 * differ in every signal that can differ, so that failure mode is visible.
 *
 * WHAT VARIES PER MEMBER, and what deliberately does not:
 *   varies:  note secrets, label, value, withdrawn_value, leaf index, change note, context, and the
 *            identity - one GENUINE registered identity per member, each with its own sibling path
 *   shared:  state_root and identity_root - forced, not chosen. Every member of a batch is settled
 *            against one pool state and one registry state, so a member carrying a different root is
 *            a member that cannot be in this batch.
 *
 * SIXTEEN GENUINE IDENTITIES, NOT THREE CYCLED. Every one is a real `register` through the real
 * contract with its own escrow proof - `build-escrow-fixtures.js --documents 16` then `16`, then
 * prove-escrow-fixtures.sh, then the registry emits all sixteen witnesses against ONE root. So a
 * batch of sixteen is sixteen different people, and the identity path is exercised sixteen different
 * ways rather than three.
 *
 * Past the number of registered identities they do cycle (`i % IDENTITY_COUNT`), which is ordinary -
 * one person making two withdrawals in a batch is a normal thing, not a weakened fixture.
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

/*
 * PADDING. A recursion tree settles POWER-OF-TWO batches, so a batch of five is proved as a tree of
 * eight. The three spare leaves need GENUINE withdrawal proofs - a tree cannot hold an empty slot -
 * so they are real zero-value spends, marked by `withdrawn_value == 0` and skipped by the contract
 * before it spends any nullifier.
 *
 * THEY CANNOT BE PRECOMPUTED ONCE AND REUSED FOREVER, which is the obvious idea and the wrong one:
 * every member of a batch must carry the SAME state_root, and that root changes with the pool. So
 * padding is generated per batch, against this batch's tree, exactly like a real member.
 *
 * EACH PADDING SLOT GETS ITS OWN NOTE, so their nullifiers are distinct and nothing collides. The
 * contract skips them anyway, and that skip is a correctness requirement rather than an
 * optimisation: a padding slot has NO corresponding `Withdrawal` struct to be bound to, so settling
 * one would read a fabricated recipient and pay it zero while burning a real note.
 */
const padTo = (n) => (n <= 1 ? 1 : 2 ** Math.ceil(Math.log2(n)));
const PADDED = padTo(COUNT);

const { masterKeysFromMnemonic, depositSecrets, commitment, nullifierHash, StateTree,
  buildWithdrawalWitness } = common.loadWallet(BUILD);

const { MNEMONIC, skIdentity, deriveRevocationSecret } = common;
const keys = masterKeysFromMnemonic(MNEMONIC);

const IDENTITY_COUNT = common.identityWitnessCount();

const OUT_DIR = path.join(__dirname, '..', 'backend', 'circuits', 'batch-witnesses');

/*
 * The batch, described before anything is derived.
 *
 * `value` and `withdrawn` both vary, so the change note is a different nonzero remainder for each
 * member. A batch where every member withdrew its note in full would never exercise the change-note
 * branch, and that branch is where the remainder lives.
 */
const members = Array.from({ length: PADDED }, (_, i) => ({
  index: i,
  padding: i >= COUNT,
  identity: i % IDENTITY_COUNT,
  scope: 1000n + BigInt(i),
  label: 500_000n + BigInt(i) * 37n,
  value: (10n ** 18n) * BigInt(i + 1),
  // Zero for a padding slot. The circuit permits it - `withdrawn_value` is only range-checked - and
  // the change note then equals the spent one, so the spend is a no-op even if it were settled.
  withdrawn: i >= COUNT ? 0n : (10n ** 17n) * BigInt(i + 1),
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
  const revocationSecret = deriveRevocationSecret(skIdentity(m.identity));

  const w = buildWithdrawalWitness({
    allowZeroForPadding: m.padding,
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
  if (m.padding) eq(w.pubSignals[2], 0n, 'a padding slot must withdraw zero');
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
  if (!m.padding) {
    if (seenNullifier.has(nh)) throw new Error(`member ${m.index}: duplicate nullifier hash ${nh}`);
    seenNullifier.add(nh);
  }
  // Padding slots deliberately share a note, so they share a nullifier and a change commitment.
  // That is safe ONLY because the contract skips them before spending; see the header.
  if (!m.padding) {
    const nc = w.pubSignals[0].toString();
    if (seenCommitment.has(nc)) throw new Error(`member ${m.index}: duplicate change commitment ${nc}`);
    seenCommitment.add(nc);
  }

  common.writeProverToml(path.join(OUT_DIR, `Prover.${m.index}.toml`), w.inputs);
  console.log(
    `  [${String(m.index).padStart(2)}] identity=${m.identity} leaf=${m.leafIndex} ` +
    `value=${m.value} withdrawn=${m.withdrawn} nullifierHash=0x${w.pubSignals[1].toString(16).slice(0, 12)}`,
  );
}

console.log(`\n${COUNT} distinct withdrawals + ${PADDED - COUNT} padding -> ` +
  `${path.relative(path.join(__dirname, '..'), OUT_DIR)}/Prover.<i>.toml (tree of ${PADDED})`);
console.log(`  shared state_root    ${sharedStateRoot}`);
console.log(`  shared identity_root ${sharedIdentityRoot}`);
console.log(`  state tree: ${stateTree.leaves.length} leaves, depth ${stateTree.depth}`);
console.log(`  ${seenNullifier.size} distinct nullifier hashes, ${seenCommitment.size} distinct change commitments (real members only)`);
