#!/usr/bin/env node
/*
 * Validates the identity-tree builder against THREE INDEPENDENT references.
 *
 * WHY THIS EXISTS AS A STANDALONE CHECK. A sparse Merkle tree that is subtly wrong - reversed
 * siblings, a different empty-node convention, a leaf hash off by one field - still produces
 * plausible-looking proofs. They simply verify against nothing, on-chain, with no diagnostic
 * pointing back at the builder. The whole withdrawal path now rests on this tree, so it is checked
 * against implementations that were written independently of it rather than against itself.
 *
 * The wallet package has no test runner configured (this would have been its first test file), and
 * the established pattern in this repo for verification that must actually RUN is a standalone
 * script - see tools/check-client-abis.py. Run:
 *
 *   node tools/check-identity-tree.js
 */
// Resolved THROUGH the wallet's package.json: both packages use an exports map, so a direct
// node_modules path bypasses it and fails to resolve. This also guarantees the exact versions the
// wallet itself will use, rather than whatever a hoisted install happens to provide.
const { createRequire } = require('module');
const path = require('path');
const walletRequire = createRequire(
  path.join(__dirname, '..', 'frontend', 'identity-wallet', 'package.json'),
);
const { SMT } = walletRequire('@zk-kit/smt');
const { poseidon } = walletRequire('@iden3/js-crypto');

const hash = (...values) => poseidon.hash(values.flat().map((v) => BigInt(v)));
const newTree = () => new SMT(hash, true);

let failures = 0;
function check(name, actual, expected) {
  const ok = actual === expected;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}`);
  if (!ok) {
    console.log(`        expected ${expected}`);
    console.log(`        actual   ${actual}`);
    failures++;
  }
}

// 1. ROOT vs circomlibjs - the vector committed in backend/circuits/pp/src/smt.nr::REF_ROOT.
const t = newTree();
for (const [k, v] of [[1n, 11n], [2n, 22n], [7n, 77n], [9n, 99n]]) t.add(k, v);
check(
  'root matches circomlibjs (pp/src/smt.nr::REF_ROOT)',
  BigInt(t.root),
  518494836555806875742446376098343000486175381741467406929375446995815951571n,
);

// 2. ROOT vs @solarity ON-CHAIN, for a ZERO value. This is the case nothing had exercised before
// the merged design: RevocationRegistry only ever added a NON-ZERO predicate. The same insert is
// asserted against the real registry in test/registry/SmtCompat.t.sol.
const z = newTree();
z.add(5n, 0n);
check(
  'zero-value root matches @solarity on-chain (SmtCompat.t.sol)',
  BigInt(z.root),
  15739329723942587145467652550645860604592570947603611249889485952228479492237n,
);

// 3. SIBLING ORDERING vs the Noir gadget. A reversed array looks equally plausible and verifies
// against nothing; pp/src/smt.nr::ref_siblings_key7() is the committed reference.
const siblings = t.createProof(7n).siblings.map((s) => BigInt(s));
check('sibling[0] matches pp/src/smt.nr::ref_siblings_key7()', siblings[0],
  3538372437315232912232383076351801231931604997820687320170917796819460581158n);
check('sibling[1] matches pp/src/smt.nr::ref_siblings_key7()', siblings[1],
  7219773115889511897248370091680383759521588836236378252329610603114958225446n);
check('path length for key 7', siblings.length, 2);

// 4. A zero-valued leaf must NOT look like an empty tree, or "registered and clean" would be
// indistinguishable from "never registered" and every unregistered party could withdraw.
check('a zero-valued leaf is distinguishable from an empty tree',
  BigInt(z.root) !== BigInt(newTree().root), true);

// 5. Revocation must move the root, or a revocation would silently fail to take effect.
const r = newTree();
r.add(5n, 0n);
const cleanRoot = BigInt(r.root);
r.update(5n, 77n);
check('revoking (update 0 -> predicate) changes the root', BigInt(r.root) !== cleanRoot, true);
check('the revoked root matches the circuit leaf hash Poseidon([5,77,1])', BigInt(r.root),
  14129927926970119856674073289737812168216833984581917537350058345827753032716n);

console.log();
if (failures) {
  console.error(`${failures} check(s) FAILED - do not build witnesses on this tree.`);
  process.exit(1);
}
console.log('OK - the identity tree agrees with circomlibjs, @solarity on-chain, and the Noir gadget.');
