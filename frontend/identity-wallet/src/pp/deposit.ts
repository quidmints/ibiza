// Deposits, split into standard denominations.
//
// TWO GAPS IN ONE. The wallet could discover notes, assemble witnesses, prove and withdraw — but it
// had no way to CREATE a note. There was no deposit path at all. And PP is variable-amount, which
// is its real privacy weakness against fixed-denomination pools: a distinctive value is a
// fingerprint that survives every other precaution, because the withdrawn amount is a public
// signal and links a withdrawal to the deposit that funded it.
//
// So the deposit builder and denomination splitting are the same piece of work, and splitting is
// the DEFAULT here rather than an option — a wallet that quietly deposits 3.7314 ETH as one note
// has already lost the anonymity the pool exists to provide.
//
// WHAT SPLITTING DOES NOT FIX, stated plainly because it is easy to oversell: the MULTISET of
// denominations still leaks. Depositing 1 + 0.1 + 0.1 + 0.1 is less distinctive than 1.3, but it is
// not nothing, and a withdrawer spending exactly those notes is correlatable. Real
// fixed-denomination pools avoid this by refusing amounts that are not clean multiples. That is why
// `allowRemainder` defaults to FALSE — see splitIntoDenominations.

import { Contract, ContractRunner } from "ethers";
import { MasterKeys, NoteSecrets, depositSecrets, precommitment } from "./notes";
import { RecoveredNote } from "./discovery";

/**
 * Standard denominations, largest first.
 *
 * Chosen to span the range with few notes rather than to be clever: each extra note is another
 * deposit transaction, another leaf in the state tree, and another proof at withdrawal time. Three
 * tiers covers 0.1–99.9 ETH in at most ~18 notes.
 */
export const DENOMINATIONS: readonly bigint[] = [
  10n ** 19n, // 10 ETH
  10n ** 18n, // 1 ETH
  10n ** 17n, // 0.1 ETH
] as const;

/** The smallest unit anything can be split into — anything below this cannot be anonymised. */
export const MIN_DENOMINATION = DENOMINATIONS[DENOMINATIONS.length - 1]!;

export interface SplitOptions {
  /**
   * Permit a final note that is NOT a standard denomination.
   *
   * Defaults to false, deliberately. A remainder note is a unique amount, which is exactly the
   * fingerprint splitting exists to remove — one 0.0314 ETH note in the pool identifies its owner
   * on both deposit and withdrawal regardless of how well the rest is split. Silently emitting one
   * would hand the user a false sense of privacy, so by default an inexpressible amount is an
   * error the caller has to decide about (round down, or accept the leak knowingly).
   */
  allowRemainder?: boolean;
}

/**
 * Decompose `value` into standard denominations, largest first.
 *
 * Greedy is optimal here because each denomination divides the next (10 / 1 / 0.1), so there is no
 * case where taking a smaller coin first yields fewer notes.
 */
export function splitIntoDenominations(value: bigint, opts: SplitOptions = {}): bigint[] {
  if (value <= 0n) throw new Error("splitIntoDenominations: value must be > 0");

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
  /** HD index within this scope — discovery re-derives notes by scanning these. */
  index: number;
  value: bigint;
  secrets: NoteSecrets;
  precommitment: bigint;
}

/**
 * Plan the deposits for `value` without submitting anything.
 *
 * `startIndex` MUST be the next unused index for this scope, because `Entrypoint` rejects a
 * precommitment it has seen before (`usedPrecommitments`) — reusing an index does not create a
 * second note, it reverts. Use `nextDepositIndex` rather than tracking this by hand.
 */
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
 * The next free deposit index, from notes discovery already returned.
 *
 * Derived rather than stored: discovery is the wallet's source of truth for which indices are
 * live, and a locally-remembered counter would drift the moment the seed is restored on another
 * device. Returns 0 for a fresh seed.
 */
export function nextDepositIndex(notes: readonly RecoveredNote[], scope: bigint): number {
  let next = 0;
  for (const n of notes) {
    if (n.kind === "deposit" && n.scope === scope && n.index >= next) next = n.index + 1;
  }
  return next;
}

// @contract Entrypoint
const ENTRYPOINT_DEPOSIT_ABI = [
  "function deposit(uint256 _precommitment) external payable returns (uint256 _commitment)",
] as const;

export interface DepositResult {
  index: number;
  value: bigint;
  commitment: bigint;
  txHash: string;
}

/**
 * Submit the planned deposits, one transaction each.
 *
 * SEQUENTIAL, NOT BATCHED, and not parallel. `Entrypoint.deposit` computes the note's `label` from
 * an incrementing pool nonce, so the commitment depends on the order the transactions actually
 * land. Firing them concurrently would leave the wallet unable to say which note got which label
 * until it re-scanned, and a failure midway would leave a gap it could not attribute.
 *
 * A partial failure is reported, not swallowed: the successful deposits are real notes and the
 * caller must know which ones landed before retrying, or it will re-derive already-used
 * precommitments and revert.
 */
export async function submitDeposits(
  entrypointAddress: string,
  runner: ContractRunner,
  planned: readonly PlannedDeposit[],
): Promise<DepositResult[]> {
  const entrypoint = new Contract(entrypointAddress, ENTRYPOINT_DEPOSIT_ABI, runner);
  const done: DepositResult[] = [];

  for (const p of planned) {
    try {
      const tx = await entrypoint.deposit(p.precommitment, { value: p.value });
      const receipt = await tx.wait();
      done.push({
        index: p.index,
        value: p.value,
        commitment: 0n, // read from the Deposited event by discovery; not needed to spend
        txHash: receipt?.hash ?? tx.hash,
      });
    } catch (err) {
      throw new Error(
        `submitDeposits: deposit ${done.length + 1}/${planned.length} (index ${p.index}, ` +
          `${p.value} wei) failed after ${done.length} succeeded. The successful ones ARE real ` +
          `notes — re-run discovery before retrying, or the next attempt will reuse a spent ` +
          `precommitment and revert. Cause: ${(err as Error).message}`,
      );
    }
  }

  return done;
}
