// Privacy Pool note derivation — rooted in the SAME device-enclave seed as the rarime identity.
// This is the rarime↔PP "fusion" (greenlit): one RootSeed → identity AND all PP notes, so the
// notes are recoverable from the seed (no separate note backup), and the wallet has one secret.
//
// Mirrors Privacy Pools' scheme EXACTLY (PP packages/sdk/src/crypto.ts + circuits/commitment.circom):
//   masterNullifier = Poseidon(hdKey(seed, acct 0))     masterSecret = Poseidon(hdKey(seed, acct 1))
//   deposit:    nullifier = Poseidon(masterNullifier, scope, index)   secret = Poseidon(masterSecret, scope, index)
//   withdrawal: nullifier = Poseidon(masterNullifier, label, index)   secret = Poseidon(masterSecret, label, index)
//   commitment  = Poseidon(value, label, Poseidon(nullifier, secret))   nullifierHash = Poseidon(nullifier)
//
// Implemented with deps the wallet already has (RN-safe): ethers HD (canonical BIP32/44, == viem's
// mnemonicToAccount) + @iden3 Poseidon (canonical circomlib, == PP's maci-crypto poseidon). The one
// value that must be vector-checked against PP's SDK is the account-key reduction below (privkeys can
// exceed the BN254 field); we reduce mod the field, which is what a circomlib Poseidon input requires.

import { HDNodeWallet } from "ethers";
import { Poseidon } from "@iden3/js-crypto";

/** BN254 scalar field (SNARK_SCALAR_FIELD) — Poseidon inputs live here. */
export const FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export interface MasterKeys {
  masterNullifier: bigint;
  masterSecret: bigint;
}

export interface NoteSecrets {
  nullifier: bigint;
  secret: bigint;
}

/** BIP44 account private key from the root mnemonic, reduced into the field (PP uses acct 0 & 1). */
function accountKey(mnemonic: string, accountIndex: number): bigint {
  const node = HDNodeWallet.fromPhrase(mnemonic, "", `m/44'/60'/${accountIndex}'/0/0`);
  return BigInt(node.privateKey) % FIELD;
}

/** Master keypair from the device-enclave RootSeed mnemonic. PP-compatible. */
export function masterKeysFromMnemonic(mnemonic: string): MasterKeys {
  return {
    masterNullifier: Poseidon.hash([accountKey(mnemonic, 0)]),
    masterSecret: Poseidon.hash([accountKey(mnemonic, 1)]),
  };
}

/** Deposit note (nullifier, secret) for a given pool scope + account index. */
export function depositSecrets(keys: MasterKeys, scope: bigint, index: bigint): NoteSecrets {
  return {
    nullifier: Poseidon.hash([keys.masterNullifier, scope, index]),
    secret: Poseidon.hash([keys.masterSecret, scope, index]),
  };
}

/** Withdrawal note (nullifier, secret) for a given deposit label + withdrawal index. */
export function withdrawalSecrets(keys: MasterKeys, label: bigint, index: bigint): NoteSecrets {
  return {
    nullifier: Poseidon.hash([keys.masterNullifier, label, index]),
    secret: Poseidon.hash([keys.masterSecret, label, index]),
  };
}

/** Precommitment = Poseidon(nullifier, secret) — the value bound at deposit (Deposited._precommitmentHash). */
export function precommitment(note: NoteSecrets): bigint {
  return Poseidon.hash([note.nullifier, note.secret]);
}

/** Commitment hash = Poseidon(value, label, Poseidon(nullifier, secret)). Matches commitment.circom. */
export function commitment(value: bigint, label: bigint, note: NoteSecrets): bigint {
  return Poseidon.hash([value, label, precommitment(note)]);
}

/** Public nullifier hash spent on withdrawal = Poseidon(nullifier). */
export function nullifierHash(nullifier: bigint): bigint {
  return Poseidon.hash([nullifier]);
}
