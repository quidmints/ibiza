"use strict";
// Deterministic note discovery — re-derive all of this seed's Privacy Pool notes by scanning the
// pool's on-chain events and matching against seed-derived secrets. HD-wallet-style recovery: the
// seed alone reconstructs the full balance, with NO server-side note storage. Completes the
// enclave-rooted-notes work (src/pp/notes + src/identity/root): one recovered mnemonic restores
// identity AND every privacy-pool note.
//
// Matching conventions:
//   • Deposit notes  — matched by precommitment (Poseidon(nullifier,secret) == Deposited._precommitmentHash).
//                       This convention is PINNED by PrivacyPool, so recovery is exact.
//   • Spent status   — Withdrawn._spentNullifier == Poseidon(nullifier), or Ragequit._commitment.
//   • Change notes   — chained from Withdrawn events using OUR wallet's withdrawal-index convention:
//                       the k-th withdrawal on a label uses withdrawalSecrets(keys, label, k). Since our
//                       wallet performs both the deposit and the withdrawal, this is self-consistent
//                       (it is a fixed derivation path, like an HD account, not an external standard).
Object.defineProperty(exports, "__esModule", { value: true });
exports.PRECOMMITMENT_BUCKETS = void 0;
exports.discoverNotes = discoverNotes;
const ethers_1 = require("ethers");
const notes_ts_1 = require("./notes.js");
// @contract PrivacyPoolSimple
const POOL_EVENTS_ABI = [
    "event Deposited(address indexed _depositor, uint256 indexed _precommitmentBucket, uint256 _commitment, uint256 _label, uint256 _value, uint256 _precommitmentHash)",
    "event Withdrawn(address indexed _processooor, uint256 _value, uint256 _spentNullifier, uint256 _newCommitment)",
    "event Ragequit(address indexed _ragequitter, uint256 _commitment, uint256 _label, uint256 _value)",
];
/** MUST match PrivacyPool.PRECOMMITMENT_BUCKETS. A mismatch silently finds nothing. */
exports.PRECOMMITMENT_BUCKETS = 256n;
/** Recover every note this seed owns in `pool` for `scope`, with spent status + spendable balance. */
async function discoverNotes(provider, poolAddress, masterKeys, scope, opts = {}) {
    const maxIndex = opts.maxIndex ?? 100;
    const fromBlock = opts.fromBlock ?? 0;
    const toBlock = opts.toBlock ?? "latest";
    const pool = new ethers_1.Contract(poolAddress, POOL_EVENTS_ABI, provider);
    // 1. Candidate deposit precommitments for indices [0, maxIndex).
    //
    // Note derivation is DETERMINISTIC from the seed, so the wallet knows every precommitment it
    // could possibly own before touching the network. That is what makes bucketed lookup possible:
    // we can compute exactly which `Deposited` topics could contain our notes and ask only for
    // those, instead of downloading every deposit ever made and filtering locally.
    const candidates = new Map();
    const buckets = new Set();
    for (let i = 0; i < maxIndex; i++) {
        const note = (0, notes_ts_1.depositSecrets)(masterKeys, scope, BigInt(i));
        const pc = (0, notes_ts_1.precommitment)(note);
        candidates.set(pc.toString(), { index: i, note });
        buckets.add(pc % exports.PRECOMMITMENT_BUCKETS);
    }
    // 2. Recover deposit notes by precommitment match. Sort by on-chain order: queryFilter's result
    // order is not part of the JSON-RPC spec (eth_getLogs) and isn't guaranteed ascending by every
    // provider. Deposit order doesn't affect correctness here (matched by precommitment, independent
    // of iteration order) but withdrawals below chain a per-label index off processing order, so we
    // sort everything defensively and consistently.
    const byChainOrder = (a, b) => a.blockNumber - b.blockNumber || a.transactionIndex - b.transactionIndex || a.index - b.index;
    // Query only the buckets our candidates fall into (or everything, if asked). ethers accepts an
    // array for an indexed topic, which the node ORs - so this is a single eth_getLogs call, not one
    // per bucket. With 100 candidate indices over 256 buckets we typically touch well under half of
    // them, and each returned log set is dominated by other users' deposits, which is the point.
    const depositFilter = opts.scanAllBuckets
        ? pool.filters.Deposited()
        : pool.filters.Deposited(null, [...buckets]);
    const deposits = (await pool.queryFilter(depositFilter, fromBlock, toBlock)).sort(byChainOrder);
    const notes = [];
    const headByLabel = new Map(); // latest unspent note per label
    for (const ev of deposits) {
        const pc = ev.args._precommitmentHash.toString();
        const hit = candidates.get(pc);
        if (!hit)
            continue;
        const note = {
            scope,
            label: ev.args._label,
            index: hit.index,
            kind: "deposit",
            nullifier: hit.note.nullifier,
            secret: hit.note.secret,
            value: ev.args._value,
            commitment: ev.args._commitment,
            spent: false,
        };
        notes.push(note);
        headByLabel.set(note.label.toString(), note);
    }
    // 3. Apply withdrawals: mark the spent note and chain its change note (our index convention).
    // Order here is load-bearing (see byChainOrder above) — wIndexByLabel assigns derivation index k
    // to the k-th withdrawal actually processed, which must match on-chain order or the recovered
    // change note's nullifier/secret silently desyncs from the real on-chain spend.
    const withdrawals = (await pool.queryFilter(pool.filters.Withdrawn(), fromBlock, toBlock)).sort(byChainOrder);
    const wIndexByLabel = new Map();
    for (const ev of withdrawals) {
        const spentNullifier = ev.args._spentNullifier;
        // Which of our per-label heads does this withdrawal spend?
        let head;
        for (const h of headByLabel.values()) {
            if (!h.spent && (0, notes_ts_1.nullifierHash)(h.nullifier) === spentNullifier) {
                head = h;
                break;
            }
        }
        if (!head)
            continue;
        head.spent = true;
        const labelKey = head.label.toString();
        const wi = wIndexByLabel.get(labelKey) ?? 0;
        wIndexByLabel.set(labelKey, wi + 1);
        const ws = (0, notes_ts_1.withdrawalSecrets)(masterKeys, head.label, BigInt(wi));
        const change = {
            scope,
            label: head.label,
            index: wi,
            kind: "withdrawal-change",
            nullifier: ws.nullifier,
            secret: ws.secret,
            value: head.value - ev.args._value,
            commitment: ev.args._newCommitment,
            spent: false,
        };
        notes.push(change);
        headByLabel.set(labelKey, change); // change note becomes the new spendable head for this label
    }
    // 4. Ragequits spend by commitment.
    const ragequits = (await pool.queryFilter(pool.filters.Ragequit(), fromBlock, toBlock));
    const rqCommitments = new Set(ragequits.map((e) => e.args._commitment.toString()));
    for (const n of notes)
        if (rqCommitments.has(n.commitment.toString()))
            n.spent = true;
    const balance = notes.reduce((acc, n) => (n.spent ? acc : acc + n.value), 0n);
    return { notes, balance };
}
