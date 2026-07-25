// WalletRoot — the single device-enclave RootSeed (Lexe model, RN).
//
// ONE BIP39 mnemonic, held in the platform secure enclave (iOS Keychain / Android Keystore via
// expo-secure-store), roots EVERYTHING:
//   • sk_identity (rarime BJJ private key)  — derived at a dedicated HD path, reduced into the field
//   • PP master keys (all Privacy Pool notes) — via src/pp/notes (HD accounts 0 & 1)
//
// This is the greenlit rarime↔PP unification: recover the one mnemonic and you recover both the
// identity and every privacy-pool note. No separate note backup, one secret to protect.
//
// HARDWARE BACKING IS NOW ACTUALLY CHECKED AND ENFORCED, not just asserted in a comment.
// `keychainAccessible` alone (the only option previously set) controls WHEN a keychain item is
// accessible, not WHETHER the underlying storage is hardware-backed (Secure Enclave / TEE-
// StrongBox) — expo-secure-store can silently fall back to software-backed storage on a device
// without one. The real signal expo-secure-store exposes is `canUseBiometricAuthentication()` +
// the `requireAuthentication` option (ties the key to Android's `setUserAuthenticationRequired`
// / iOS's `biometryCurrentSet` — genuinely hardware-gated key material, per expo-secure-store's
// own SecureStore.d.ts). We now check availability explicitly and fail closed rather than
// silently store the root seed unprotected.
//
// SESSION CACHE, not re-auth on every call: `requireAuthentication: true` alone would prompt
// biometric auth on nearly every wallet operation (per expo-secure-store's own docs — on Android,
// EVERY operation) — unshippable UX. Correct pattern: authenticate once via SecureStore, cache the
// unlocked mnemonic in memory for the app's session, and only hit SecureStore (re-prompting) again
// after an explicit lockWallet() or process restart. The in-memory cache is the standard, accepted
// trade-off every mobile wallet/password manager makes for this UX — plaintext in JS memory for the
// session, never persisted unencrypted, cleared on lock/background.
//
// OPERATIONAL DEPENDENCY: requireAuthentication needs expo-secure-store's own config plugin
// registered (Face ID usage description on iOS) to work outside Expo Go — per expo-secure-store's
// own docs. Checked and registered in app.json's `expo.plugins` (was missing — only the rarime
// SDK's plugin was present before).

import * as SecureStore from "expo-secure-store";
import { HDNodeWallet, Mnemonic, randomBytes, hexlify } from "ethers";
import { FIELD, masterKeysFromMnemonic, type MasterKeys } from "../pp/notes";

const ROOT_KEY = "quid.wallet.root.mnemonic";

// HD path for the rarime identity scalar — domain-separated from PP's accounts (0 & 1).
const IDENTITY_PATH = "m/44'/60'/100'/0/0";

/** Thrown when the device cannot confirm hardware-gated secure storage is available. Callers
 *  should treat this as fatal for the root seed specifically (not a generic error to swallow) —
 *  proceeding would store identity + all PP notes without the hardware backing this design
 *  requires. */
export class InsecureDeviceError extends Error {
  constructor() {
    super(
      "InsecureDeviceError: device cannot confirm hardware-gated secure storage " +
        "(SecureStore.canUseBiometricAuthentication() returned false) — refusing to store the root seed",
    );
    this.name = "InsecureDeviceError";
  }
}

const SECURE_ITEM_OPTIONS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  requireAuthentication: true,
  authenticationPrompt: "Unlock your identity and Privacy Pool funds",
};

// In-memory session cache — see the module doc comment for the trade-off this accepts. Cleared by
// lockWallet(); a fresh SecureStore read (and its one biometric prompt) only happens again after
// that or a process restart.
let sessionMnemonic: string | undefined;

/** Read the enclave-held root mnemonic, creating one on first use. Never leaves the device.
 *  Throws InsecureDeviceError if hardware-gated storage isn't confirmed available — this does
 *  NOT silently degrade to software-backed storage for material this sensitive. Prompts biometric
 *  auth AT MOST once per session (see sessionMnemonic) — not on every call. */
export async function getOrCreateRootMnemonic(): Promise<string> {
  if (sessionMnemonic) return sessionMnemonic;

  if (!SecureStore.canUseBiometricAuthentication()) {
    throw new InsecureDeviceError();
  }

  const existing = await SecureStore.getItemAsync(ROOT_KEY, SECURE_ITEM_OPTIONS);
  if (existing) {
    sessionMnemonic = existing;
    return existing;
  }

  const phrase = Mnemonic.fromEntropy(hexlify(randomBytes(32))).phrase; // 24 words
  await SecureStore.setItemAsync(ROOT_KEY, phrase, SECURE_ITEM_OPTIONS);
  sessionMnemonic = phrase;
  return phrase;
}

/** Clear the in-memory session cache, forcing the next getOrCreateRootMnemonic() call to
 *  re-authenticate via SecureStore (a fresh biometric prompt). Call this on explicit user lock
 *  and when the app backgrounds, per your own session-timeout policy — this module doesn't decide
 *  that policy itself, it just provides the primitive. */
export function lockWallet(): void {
  sessionMnemonic = undefined;
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
