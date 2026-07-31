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
import { assertValidMnemonic, openBackup, sealMnemonic } from "./recovery";

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

  // ASSERT THE CSPRNG BEFORE GENERATING, with a message that names the real cause.
  //
  // Without `polyfills.ts` loaded, metro's `crypto` -> crypto-browserify alias resolves randomBytes
  // to a function that throws "Secure random number generation is not supported by this browser.
  // Use Chrome, Firefox or Internet Explorer 11" - accurate for a browser, baffling in a mobile
  // wallet, and it names neither the polyfill nor the file that should have imported it.
  //
  // THE FAILURE IS SAFE EITHER WAY, and that is the property worth stating: crypto-browserify
  // THROWS rather than falling back to Math.random, so a weak, guessable mnemonic is not a reachable
  // state (sec. 2.18bd). This check exists to make the diagnosis instant, not to add safety.
  if (typeof globalThis.crypto?.getRandomValues !== "function") {
    throw new Error(
      "No cryptographic RNG: crypto.getRandomValues is unavailable. index.ts must import " +
        "'./polyfills' BEFORE anything else - it installs react-native-get-random-values. " +
        "Refusing to generate a mnemonic without a CSPRNG.",
    );
  }

  // 32 bytes = 256 bits = 24 words. Not 12 (128 bits): the extra margin costs the user nothing to
  // store and doubles the exponent against any future attack, including Grover's square-root
  // speed-up, which would take 128-bit entropy to a 2^64 search.
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

// ───────────────────────────────────────────────────────────────────────────────────────────────
// RECOVERY. Everything below exists because, until it did, THERE WAS NONE - see recovery.ts's
// header for the full shape of that gap. The crypto lives there, pure and node-testable
// (tools/check-recovery.js); this half is the part that touches SecureStore and therefore cannot
// be exercised off-device.
// ───────────────────────────────────────────────────────────────────────────────────────────────

/** Thrown when a restore would destroy a wallet that already holds funds. */
export class WalletAlreadyExistsError extends Error {
  constructor() {
    super(
      "WalletAlreadyExistsError: a root seed is already stored on this device. Restoring over it " +
        "would PERMANENTLY LOSE every identity and Privacy Pool note derived from the current " +
        "seed. Back up the existing seed first, then pass { replaceExistingWallet: true }.",
    );
    this.name = "WalletAlreadyExistsError";
  }
}

/** Whether this device already holds a root seed. Prompts biometric auth. */
export async function hasRootMnemonic(): Promise<boolean> {
  if (sessionMnemonic) return true;
  return (await SecureStore.getItemAsync(ROOT_KEY, SECURE_ITEM_OPTIONS)) !== null;
}

/**
 * Reveal the root phrase so the user can WRITE IT DOWN.
 *
 * THE WALLET WAS PREVIOUSLY UNBACKUPABLE BY CONSTRUCTION: the phrase was generated on-device and
 * never displayed, so no amount of diligence let a user protect themselves. This is the whole
 * mechanism behind "24 words on paper", which needs no passphrase, no file and no service - and is
 * the only recovery path that still works when the user has lost the device AND cannot reach a
 * network.
 *
 * DELIBERATELY A SEPARATE FUNCTION from the internal derivation calls, so that "show the user their
 * secret" is a distinct, greppable, auditable action rather than an incidental use of
 * `loadWalletRoot().mnemonic`. Callers must treat the return value as display-only: never log it,
 * never put it in a screenshot-able view without warning, never send it anywhere.
 */
export async function revealRootMnemonic(): Promise<string> {
  return getOrCreateRootMnemonic();
}

/**
 * Store a user-supplied phrase as the root seed - the "I wrote down 24 words" path.
 *
 * VALIDATED BEFORE IT IS STORED. A mistyped phrase would derive keys perfectly well; they would
 * simply be the wrong keys, and the user would see an empty wallet rather than an error, with the
 * real phrase already overwritten. See recovery.ts::assertValidMnemonic.
 */
export async function importRootMnemonic(
  phrase: string,
  opts: { replaceExistingWallet?: boolean } = {},
): Promise<void> {
  const normalised = assertValidMnemonic(phrase);

  if (!SecureStore.canUseBiometricAuthentication()) throw new InsecureDeviceError();
  if (!opts.replaceExistingWallet && (await hasRootMnemonic())) {
    throw new WalletAlreadyExistsError();
  }

  await SecureStore.setItemAsync(ROOT_KEY, normalised, SECURE_ITEM_OPTIONS);
  sessionMnemonic = normalised;
}

/**
 * Produce an encrypted backup file the user can store anywhere.
 *
 * The ciphertext is useless without the passphrase, and carries no address, device identifier or
 * timestamp (recovery.ts strips them - the unmodified keystore would have published an address
 * derived from the same seed as the user's note secrets). Nothing here contacts a server: the user
 * holds the only copy and there is no party to ask for it back.
 */
export async function exportEncryptedBackup(passphrase: string): Promise<string> {
  return sealMnemonic(await getOrCreateRootMnemonic(), passphrase);
}

/**
 * Restore from an encrypted backup.
 *
 * REFUSES BY DEFAULT IF A WALLET ALREADY EXISTS. Restoring an older backup over a live wallet is
 * irreversible and silent: every note derived from the current seed becomes unspendable, and the
 * user's next screen looks like an ordinary balance rather than a loss. Overwriting has to be an
 * explicit decision taken with that spelled out, not a default that happens to be convenient.
 */
export async function restoreFromEncryptedBackup(
  backupJson: string,
  passphrase: string,
  opts: { replaceExistingWallet?: boolean } = {},
): Promise<void> {
  // Decrypt BEFORE touching storage, so a wrong passphrase or corrupt file cannot leave the device
  // in a half-restored state.
  const phrase = await openBackup(backupJson, passphrase);
  await importRootMnemonic(phrase, opts);
}
