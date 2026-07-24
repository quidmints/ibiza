// WalletRoot — the single device-enclave RootSeed (Lexe model, RN).
//
// ONE BIP39 mnemonic, held in the platform secure enclave (iOS Keychain / Android Keystore via
// expo-secure-store), roots EVERYTHING:
//   • sk_identity (rarime BJJ private key)  — derived at a dedicated HD path, reduced into the field
//   • PP master keys (all Privacy Pool notes) — via src/pp/notes (HD accounts 0 & 1)
//
// This is the greenlit rarime↔PP unification: recover the one mnemonic and you recover both the
// identity and every privacy-pool note. No separate note backup, one secret to protect.

import * as SecureStore from "expo-secure-store";
import { HDNodeWallet, Mnemonic, randomBytes, hexlify } from "ethers";
import { FIELD, masterKeysFromMnemonic, type MasterKeys } from "../pp/notes";

const ROOT_KEY = "quid.wallet.root.mnemonic";

// HD path for the rarime identity scalar — domain-separated from PP's accounts (0 & 1).
const IDENTITY_PATH = "m/44'/60'/100'/0/0";

/** Read the enclave-held root mnemonic, creating one on first use. Never leaves the device. */
export async function getOrCreateRootMnemonic(): Promise<string> {
  const existing = await SecureStore.getItemAsync(ROOT_KEY, {
    keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  });
  if (existing) return existing;

  const phrase = Mnemonic.fromEntropy(hexlify(randomBytes(32))).phrase; // 24 words
  await SecureStore.setItemAsync(ROOT_KEY, phrase, {
    keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  });
  return phrase;
}

/** rarime BJJ private key (64-char hex) derived from the root mnemonic. */
export function deriveSkIdentity(mnemonic: string): string {
  const node = HDNodeWallet.fromPhrase(mnemonic, "", IDENTITY_PATH);
  const scalar = BigInt(node.privateKey) % FIELD;
  return scalar.toString(16).padStart(64, "0");
}

/** Privacy Pool master keys derived from the SAME root mnemonic. */
export function deriveProfileMasterKeys(mnemonic: string): MasterKeys {
  return masterKeysFromMnemonic(mnemonic);
}

export interface WalletRoot {
  mnemonic: string;
  skIdentity: string;
  ppMasterKeys: MasterKeys;
}

/** Load the enclave root and derive both identity + PP material from it. */
export async function loadWalletRoot(): Promise<WalletRoot> {
  const mnemonic = await getOrCreateRootMnemonic();
  return {
    mnemonic,
    skIdentity: deriveSkIdentity(mnemonic),
    ppMasterKeys: deriveProfileMasterKeys(mnemonic),
  };
}
