// Deposits, split into standard denominations.
//
// THE GAP THIS FILLED. Notes are created by exactly two on-chain paths — `PrivacyPool.deposit`
// (:170) and the CHANGE NOTE a withdrawal inserts (:192). The wallet already created the second
// (withdrawWitness derives `out_nullifier`/`out_secret` and the new commitment); what it had no
// path for was the first. So this is the deposit half specifically, not "note creation" in general.
//
// WHY SPLITTING IS THE DEFAULT. PP is variable-amount, and the withdrawn value is a PUBLIC signal.
// A distinctive amount therefore links a withdrawal to the deposit that funded it regardless of
// every other precaution, which is the one weakness a fixed-denomination pool does not have.
//
// HOW FAR SPLITTING ACTUALLY GETS YOU — see DepositMode. Mixed denominations leave a distinctive
// MULTISET (1 + 0.1 + 0.1 is less identifying than 1.3, but it is not nothing). `Uniform` mode
// removes that: every note is the same size, so the only remaining signal is a COUNT, which is
// shared with everyone else depositing the same total in the same unit. That is the strongest
// anonymity this design can offer, and it is the default.

import { Contract, ContractRunner, EventLog, Interface, type Log } from "ethers";
import { MasterKeys, NoteSecrets, depositSecrets, precommitment } from "./notes";
import { RecoveredNote } from "./discovery";

/** Standard denominations, largest first. Each divides the next, which is what makes greedy optimal. */
export const DENOMINATIONS: readonly bigint[] = [
  10n ** 19n, // 10 ETH
  10n ** 18n, // 1 ETH
  10n ** 17n, // 0.1 ETH
] as const;

export const MIN_DENOMINATION = DENOMINATIONS[DENOMINATIONS.length - 1]!;

export enum DepositMode {
  /**
   * Every note the SAME size (the largest denomination that divides the total).
   *
   * The multiset collapses to a count, so two users depositing the same total in the same unit are
   * indistinguishable. Costs more transactions than `Mixed` — 10 ETH becomes one note, but 9.9 ETH
   * becomes 99 notes of 0.1. That trade is the point: `Mixed` would emit 9 + 9x0.1, a shape few
   * others will share.
   */
  Uniform = "uniform",

  /**
   * Fewest notes, mixing denominations.
   *
   * ONLY use when transaction cost genuinely outweighs anonymity. The resulting multiset is close
   * to a fingerprint for unusual totals.
   */
  Mixed = "mixed",
}

export interface SplitOptions {
  mode?: DepositMode;
  /**
   * Permit a final note that is NOT a standard denomination.
   *
   * Defaults to false. A remainder note is a unique amount — the exact fingerprint splitting exists
   * to remove — and it identifies its owner on both deposit and withdrawal no matter how well the
   * rest is split. Emitting one silently would hand the user a false sense of privacy.
   */
  allowRemainder?: boolean;
}

/** Largest denomination that divides `value` exactly, or null if none does. */
function uniformUnitFor(value: bigint): bigint | null {
  for (const d of DENOMINATIONS) if (value % d === 0n) return d;
  return null;
}

/**
 * Decompose `value` into note amounts.
 *
 * Uniform mode yields `value / unit` identical notes. Mixed mode is greedy, which is optimal here
 * because each denomination divides the next.
 */
export function splitIntoDenominations(value: bigint, opts: SplitOptions = {}): bigint[] {
  if (value <= 0n) throw new Error("splitIntoDenominations: value must be > 0");
  const mode = opts.mode ?? DepositMode.Uniform;

  if (mode === DepositMode.Uniform) {
    const unit = uniformUnitFor(value);
    if (unit === null) {
      if (!opts.allowRemainder) {
        throw new Error(
          `splitIntoDenominations: ${value} wei is not a whole multiple of any standard ` +
            `denomination, so it cannot be split into identical notes. Deposit a multiple of ` +
            `${MIN_DENOMINATION} wei, or pass mode: Mixed / allowRemainder to accept a ` +
            `distinctive note shape.`,
        );
      }
      return splitIntoDenominations(value, { ...opts, mode: DepositMode.Mixed });
    }
    return new Array(Number(value / unit)).fill(unit);
  }

  const out: bigint[] = [];
  let left = value;
  for (const d of DENOMINATIONS) {
    while (left >= d) {
      out.push(d);
      left -= d;
    }
  }
  if (left > 0n) {
    if (!opts.allowRemainder) {
      throw new Error(
        `splitIntoDenominations: ${value} leaves a remainder of ${left} wei, which is not a ` +
          `standard denomination. A uniquely-sized note is a fingerprint on both deposit and ` +
          `withdrawal. Deposit ${value - left} instead, or pass allowRemainder to accept the leak.`,
      );
    }
    out.push(left);
  }
  return out;
}

export interface PlannedDeposit {
  index: number;
  value: bigint;
  secrets: NoteSecrets;
  precommitment: bigint;
}

export function planDeposits(
  masterKeys: MasterKeys,
  scope: bigint,
  startIndex: number,
  value: bigint,
  opts: SplitOptions = {},
): PlannedDeposit[] {
  return splitIntoDenominations(value, opts).map((amount, i) => {
    const index = startIndex + i;
    const secrets = depositSecrets(masterKeys, scope, BigInt(index));
    return { index, value: amount, secrets, precommitment: precommitment(secrets) };
  });
}

/**
 * The next free deposit index.
 *
 * DERIVED FROM DISCOVERY, never stored — a local counter drifts the moment the seed is restored on
 * another device, and the consequence is not cosmetic: a reused index re-derives a spent
 * precommitment, which `Entrypoint.usedPrecommitments` rejects.
 *
 * TRUNCATION IS THE REAL HAZARD, and it is why `scannedMaxIndex` is REQUIRED rather than optional.
 * `discoverNotes` scans a bounded window (default 100). If the highest note found sits at that
 * boundary, the scan may simply have stopped early and later notes exist that this function cannot
 * see — so it would hand back an index that is already spent. Refusing is the only safe answer;
 * the caller must re-scan with a wider window.
 */
export function nextDepositIndex(
  notes: readonly RecoveredNote[],
  scope: bigint,
  scannedMaxIndex: number,
): number {
  let next = 0;
  for (const n of notes) {
    if (n.kind === "deposit" && n.scope === scope && n.index >= next) next = n.index + 1;
  }

  if (next >= scannedMaxIndex) {
    throw new Error(
      `nextDepositIndex: highest known deposit index is ${next - 1}, at the edge of a scan that ` +
        `only covered ${scannedMaxIndex} indices — later notes may exist but be invisible. ` +
        `Re-run discoverNotes with a larger maxIndex before depositing, or the next deposit will ` +
        `reuse a spent precommitment and revert.`,
    );
  }
  return next;
}

// @contract Entrypoint
const ENTRYPOINT_DEPOSIT_ABI = [
  "function deposit(uint256 _precommitment) external payable returns (uint256 _commitment)",
  "function usedPrecommitments(uint256 _precommitment) external view returns (bool)",
] as const;

// @contract PrivacyPoolSimple
const POOL_DEPOSITED_ABI = [
  "event Deposited(address indexed _depositor, uint256 indexed _precommitmentBucket, uint256 _commitment, uint256 _label, uint256 _value, uint256 _precommitmentHash)",
] as const;

export interface DepositResult {
  index: number;
  value: bigint;
  /** Read from the tx's own `Deposited` event — never a placeholder. */
  commitment: bigint;
  /** The deposit's label, also from the event. Needed to spend the note, and to chain change notes. */
  label: bigint;
  txHash: string;
  /** True when the precommitment was already on-chain, so this deposit was skipped as a replay. */
  skipped: boolean;
}

/**
 * Submit the planned deposits.
 *
 * SEQUENTIAL, because `Entrypoint` derives each note's `label` from an incrementing pool nonce, so
 * a commitment depends on the order transactions land. Sending concurrently would make labels
 * unattributable without a re-scan.
 *
 * IDEMPOTENT, so a retry after a partial failure is safe. Each precommitment is checked against
 * `Entrypoint.usedPrecommitments` first and skipped if already spent, rather than reverting the
 * whole batch. Re-running the same plan converges instead of failing — which is what makes the
 * failure path recoverable at all, since precommitments are single-use.
 *
 * EVERY RESULT CARRIES ITS LABEL AND COMMITMENT, parsed from that transaction's own `Deposited`
 * event. The wallet therefore never needs a re-scan to attribute a note it just created.
 */
export async function submitDeposits(
  entrypointAddress: string,
  poolAddress: string,
  runner: ContractRunner,
  planned: readonly PlannedDeposit[],
): Promise<DepositResult[]> {
  const entrypoint = new Contract(entrypointAddress, ENTRYPOINT_DEPOSIT_ABI, runner);
  const poolIface = new Interface(POOL_DEPOSITED_ABI as unknown as string[]);
  const out: DepositResult[] = [];

  for (const p of planned) {
    if (await entrypoint.usedPrecommitments(p.precommitment)) {
      // Already landed on a previous attempt. Recover its label/commitment from the log rather
      // than guessing, so a resumed run is indistinguishable from one that never failed.
      const prior = await findDepositedByPrecommitment(poolAddress, runner, p.precommitment);
      out.push({ ...prior, index: p.index, value: p.value, skipped: true });
      continue;
    }

    const tx = await entrypoint.deposit(p.precommitment, { value: p.value });
    const receipt = await tx.wait();

    let parsed: { commitment: bigint; label: bigint } | null = null;
    for (const log of (receipt?.logs ?? []) as Log[]) {
      try {
        const ev = poolIface.parseLog(log);
        if (ev?.name === "Deposited" && BigInt(ev.args._precommitmentHash) === p.precommitment) {
          parsed = { commitment: BigInt(ev.args._commitment), label: BigInt(ev.args._label) };
          break;
        }
      } catch {
        continue; // a log from another contract - not ours to decode
      }
    }

    if (!parsed) {
      throw new Error(
        `submitDeposits: deposit at index ${p.index} was mined (tx ${receipt?.hash ?? tx.hash}) ` +
          `but emitted no matching Deposited event. The note may exist on-chain; re-run ` +
          `discoverNotes before retrying rather than resubmitting.`,
      );
    }

    out.push({
      index: p.index,
      value: p.value,
      commitment: parsed.commitment,
      label: parsed.label,
      txHash: receipt?.hash ?? tx.hash,
      skipped: false,
    });
  }

  return out;
}

/** Recover a previously-landed deposit's commitment/label from its `Deposited` log. */
async function findDepositedByPrecommitment(
  poolAddress: string,
  runner: ContractRunner,
  target: bigint,
): Promise<{ commitment: bigint; label: bigint; txHash: string }> {
  const pool = new Contract(poolAddress, POOL_DEPOSITED_ABI, runner);
  // Filter by the indexed bucket the precommitment falls into - the same narrowing discovery.ts
  // uses, so this stays one cheap eth_getLogs rather than a full history scan.
  const bucket = target % 256n;
  const logs = (await pool.queryFilter(pool.filters.Deposited(null, [bucket]), 0, "latest")) as EventLog[];

  for (const ev of logs) {
    if (BigInt(ev.args._precommitmentHash as bigint) === target) {
      return {
        commitment: BigInt(ev.args._commitment as bigint),
        label: BigInt(ev.args._label as bigint),
        txHash: ev.transactionHash,
      };
    }
  }
  throw new Error(
    `findDepositedByPrecommitment: Entrypoint reports precommitment ${target} as used, but no ` +
      `matching Deposited event was found. The log range may be incomplete.`,
  );
}
