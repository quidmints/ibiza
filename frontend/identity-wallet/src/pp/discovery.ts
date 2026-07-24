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

import { Contract, JsonRpcProvider, EventLog } from "ethers";
import {
  MasterKeys,
  NoteSecrets,
  depositSecrets,
  withdrawalSecrets,
  precommitment,
  nullifierHash,
} from "./notes";

const POOL_EVENTS_ABI = [
  "event Deposited(address indexed _depositor, uint256 _commitment, uint256 _label, uint256 _value, uint256 _precommitmentHash)",
  "event Withdrawn(address indexed _processooor, uint256 _value, uint256 _spentNullifier, uint256 _newCommitment)",
  "event Ragequit(address indexed _ragequitter, uint256 _commitment, uint256 _label, uint256 _value)",
];

export type NoteKind = "deposit" | "withdrawal-change";

export interface RecoveredNote {
  scope: bigint;
  label: bigint;
  /** derivation index within its kind */
  index: number;
  kind: NoteKind;
  nullifier: bigint;
  secret: bigint;
  value: bigint;
  commitment: bigint;
  spent: boolean;
}

export interface DiscoveryOptions {
  /** how many deposit indices to scan per scope (HD gap limit) */
  maxIndex?: number;
  fromBlock?: number;
  toBlock?: number | "latest";
}

export interface DiscoveryResult {
  notes: RecoveredNote[];
  /** spendable balance = sum of unspent note values */
  balance: bigint;
}

/** Recover every note this seed owns in `pool` for `scope`, with spent status + spendable balance. */
export async function discoverNotes(
  provider: JsonRpcProvider,
  poolAddress: string,
  masterKeys: MasterKeys,
  scope: bigint,
  opts: DiscoveryOptions = {},
): Promise<DiscoveryResult> {
  const maxIndex = opts.maxIndex ?? 100;
  const fromBlock = opts.fromBlock ?? 0;
  const toBlock = opts.toBlock ?? "latest";
  const pool = new Contract(poolAddress, POOL_EVENTS_ABI, provider);

  // 1. Candidate deposit precommitments for indices [0, maxIndex).
  const candidates = new Map<string, { index: number; note: NoteSecrets }>();
  for (let i = 0; i < maxIndex; i++) {
    const note = depositSecrets(masterKeys, scope, BigInt(i));
    candidates.set(precommitment(note).toString(), { index: i, note });
  }

  // 2. Recover deposit notes by precommitment match.
  const deposits = (await pool.queryFilter(pool.filters.Deposited(), fromBlock, toBlock)) as EventLog[];
  const notes: RecoveredNote[] = [];
  const headByLabel = new Map<string, RecoveredNote>(); // latest unspent note per label
  for (const ev of deposits) {
    const pc = (ev.args._precommitmentHash as bigint).toString();
    const hit = candidates.get(pc);
    if (!hit) continue;
    const note: RecoveredNote = {
      scope,
      label: ev.args._label as bigint,
      index: hit.index,
      kind: "deposit",
      nullifier: hit.note.nullifier,
      secret: hit.note.secret,
      value: ev.args._value as bigint,
      commitment: ev.args._commitment as bigint,
      spent: false,
    };
    notes.push(note);
    headByLabel.set(note.label.toString(), note);
  }

  // 3. Apply withdrawals: mark the spent note and chain its change note (our index convention).
  const withdrawals = (await pool.queryFilter(pool.filters.Withdrawn(), fromBlock, toBlock)) as EventLog[];
  const wIndexByLabel = new Map<string, number>();
  for (const ev of withdrawals) {
    const spentNullifier = ev.args._spentNullifier as bigint;
    // Which of our per-label heads does this withdrawal spend?
    let head: RecoveredNote | undefined;
    for (const h of headByLabel.values()) {
      if (!h.spent && nullifierHash(h.nullifier) === spentNullifier) {
        head = h;
        break;
      }
    }
    if (!head) continue;
    head.spent = true;

    const labelKey = head.label.toString();
    const wi = wIndexByLabel.get(labelKey) ?? 0;
    wIndexByLabel.set(labelKey, wi + 1);
    const ws = withdrawalSecrets(masterKeys, head.label, BigInt(wi));
    const change: RecoveredNote = {
      scope,
      label: head.label,
      index: wi,
      kind: "withdrawal-change",
      nullifier: ws.nullifier,
      secret: ws.secret,
      value: head.value - (ev.args._value as bigint),
      commitment: ev.args._newCommitment as bigint,
      spent: false,
    };
    notes.push(change);
    headByLabel.set(labelKey, change); // change note becomes the new spendable head for this label
  }

  // 4. Ragequits spend by commitment.
  const ragequits = (await pool.queryFilter(pool.filters.Ragequit(), fromBlock, toBlock)) as EventLog[];
  const rqCommitments = new Set(ragequits.map((e) => (e.args._commitment as bigint).toString()));
  for (const n of notes) if (rqCommitments.has(n.commitment.toString())) n.spent = true;

  const balance = notes.reduce((acc, n) => (n.spent ? acc : acc + n.value), 0n);
  return { notes, balance };
}
