// IdentityVault — one holder key, MANY documents. The "one-key-multiple-documents" core
// (multi-citizenship + renewed/revoked/expired passports). See app contracts: HolderStateKeeper.
//
// Model:
//   device-enclave RootSeed  ──►  sk_identity  ──►  holder root (profileKey)  ──►  many document leaves
//     (one BIP39 mnemonic, see        (derived)       (Poseidon(pubkey(sk)))        passport · national ID · ...
//      identity/root.ts; ALSO roots
//      the Privacy Pool notes)
//
// All documents bind to the SAME holder key, so multi-citizenship = register N passports under
// one key; renewal = register the new passport + supersede the old, holder key unchanged.
// The holder secret is NOT independent randomness — it is derived from the same enclave RootSeed
// that derives the PP note master keys (rarime↔PP fusion: one seed recovers identity + funds).
//
// WHAT IS REAL HERE: holder-key lifecycle, the document set + status management, and driving the
// forked Rarime SDK for key derivation / passport status / registration.
// WHAT NEEDS THE OTHER TWO FORKS (flagged TODO, not faked):
//   - register-additional / renew / revoke ON-CHAIN must call OUR HolderRegistration
//     (registerDocumentViaNoir / renewDocumentViaNoir / revokeDocumentViaSigner) at OUR deployed
//     HolderStateKeeper — NOT upstream RegistrationSimple (whose addBond forbids a 2nd doc per key).
//   - the "is this document CURRENT" query proof needs the forked Groth16/Noir circuit.

import { JsonRpcProvider } from "ethers";
import { Rarime, RarimeConfiguration } from "../sdk/Rarime";
import { RarimePassport, DocumentStatus } from "../sdk/RarimePassport";
import { HolderRoot, DocumentType, LeafStatus } from "../sdk/HolderTree";
import { getOrCreateRootMnemonic, deriveSkIdentity, deriveProfileMasterKeys } from "./root";
import type { MasterKeys } from "../pp/notes";
import { discoverNotes, DiscoveryResult, DiscoveryOptions } from "../pp/discovery";
import { toPaddedHex32 } from "../sdk/utils";
import {
  holderStateKeeper,
  getHolderDocuments,
  getDocumentBond,
  DocStatus,
  DOC_TYPE,
} from "../sdk/holder/HolderContracts";

/** A document held under the single holder key. `documentKey` is the on-chain key
 *  (Poseidon-derived passport key, hex). */
export interface StoredDocument {
  documentKey: string;
  docType: DocumentType;
  /** Issuing country (ISO-3166), the multi-citizenship discriminator. */
  country?: string;
  registeredAt?: number;
  /** Passport expiry (epoch seconds) — drives the "expired" status. */
  notAfter?: number;
  status: LeafStatus;
  /** id returned by the registration relayer, if any. */
  registrationId?: string;
}

/** Persistence the host app provides for the document set (e.g. async-storage). The holder secret
 *  is NOT stored here — it is derived from the enclave RootSeed (see identity/root.ts). */
export interface IdentityVaultStore {
  getDocuments(): Promise<StoredDocument[]>;
  setDocuments(docs: StoredDocument[]): Promise<void>;
}

/** Config minus the user key — the key is the vault's durable holder secret, managed here. */
export type IdentityVaultConfig = Omit<RarimeConfiguration, "userConfiguration">;

export class IdentityVault {
  constructor(
    private readonly config: IdentityVaultConfig,
    private readonly store: IdentityVaultStore,
  ) {}

  // ── Holder key (the ONE key) ──────────────────────────────────────────────────────────────

  /** The durable holder secret (sk_identity), derived from the device-enclave RootSeed.
   *  Same seed that derives the PP note master keys — see ppMasterKeys(). */
  async ensureHolderSecret(): Promise<string> {
    return deriveSkIdentity(await getOrCreateRootMnemonic());
  }

  /** Privacy Pool note master keys, derived from the SAME enclave RootSeed as sk_identity.
   *  This is the rarime↔PP fusion: one seed → identity AND all privacy-pool notes. */
  async ppMasterKeys(): Promise<MasterKeys> {
    return deriveProfileMasterKeys(await getOrCreateRootMnemonic());
  }

  /** Recover this holder's Privacy Pool notes for a pool/scope by scanning on-chain events and
   *  re-deriving from the enclave seed (HD-wallet-style; no server-side note storage). Returns the
   *  notes with spent status + spendable balance. */
  async discoverPoolNotes(
    poolAddress: string,
    scope: bigint,
    opts?: DiscoveryOptions,
  ): Promise<DiscoveryResult> {
    const provider = new JsonRpcProvider(this.config.apiConfiguration.jsonRpcEvmUrl);
    return discoverNotes(provider, poolAddress, await this.ppMasterKeys(), scope, opts);
  }

  /** The durable holder root (profileKey) every document binds to. */
  async holderRoot(): Promise<HolderRoot> {
    return HolderRoot.fromIdentitySecret(await this.ensureHolderSecret());
  }

  /** A Rarime instance bound to the single holder secret. */
  private async rarime(): Promise<Rarime> {
    return new Rarime({
      ...this.config,
      userConfiguration: { userPrivateKey: await this.ensureHolderSecret() },
    });
  }

  // ── Documents (MANY) ──────────────────────────────────────────────────────────────────────

  async listDocuments(): Promise<StoredDocument[]> {
    return this.store.getDocuments();
  }

  /**
   * Read the holder's documents straight from OUR HolderStateKeeper (the source of truth):
   * every leaf ever bound under this holder root, with its on-chain status. This is the real
   * multi-document enumeration (multi-citizenship + superseded/revoked visible).
   */
  async documentsOnChain(): Promise<StoredDocument[]> {
    const root = await this.holderRoot();
    const provider = new JsonRpcProvider(this.config.apiConfiguration.jsonRpcEvmUrl);
    const sk = holderStateKeeper(this.config.contractsConfiguration.stateKeeperAddress, provider);

    const keys = await getHolderDocuments(sk, "0x" + root.profileKey);
    const out: StoredDocument[] = [];
    for (const documentKey of keys) {
      const b = await getDocumentBond(sk, documentKey);
      out.push({
        documentKey,
        docType: docTypeFromHash(b.docType),
        notAfter: b.notAfter > 0n ? Number(b.notAfter) : undefined,
        registeredAt: Number(b.issueTimestamp),
        status: leafStatusFromChain(b.status),
      });
    }
    return out;
  }

  /** Reconcile the local store with on-chain truth (statuses, newly-seen documents). */
  async syncFromChain(): Promise<StoredDocument[]> {
    const chain = await this.documentsOnChain();
    const local = await this.store.getDocuments();
    // chain status wins; keep local-only fields (country) where we have them.
    const byKey = new Map(local.map((d) => [d.documentKey, d]));
    const merged = chain.map((c) => ({ ...byKey.get(c.documentKey), ...c }));
    await this.store.setDocuments(merged);
    return merged;
  }

  /** Current = registered, not superseded/revoked, not past expiry. */
  async currentDocuments(nowSec = nowSeconds()): Promise<StoredDocument[]> {
    return (await this.listDocuments()).filter(
      (d) => d.status === LeafStatus.Current && !isExpired(d, nowSec),
    );
  }

  /** Documents grouped by issuing country — the multi-citizenship view. */
  async citizenships(): Promise<string[]> {
    const set = new Set<string>();
    for (const d of await this.currentDocuments()) if (d.country) set.add(d.country);
    return [...set];
  }

  /**
   * Add (register) a NEW document under the holder key. Repeatable with different passports →
   * multi-citizenship. This is the per-document registration; once OUR HolderStateKeeper is the
   * target it no longer hits upstream's one-doc-per-identity wall.
   */
  async addDocument(
    passport: RarimePassport,
    docType: DocumentType,
    opts: { country?: string; notAfter?: number } = {},
  ): Promise<StoredDocument> {
    const rarime = await this.rarime();

    const status = await rarime.getDocumentStatus(passport);
    if (status === DocumentStatus.RegisteredWithOtherPk) {
      throw new Error("IdentityVault: document is bound to a different holder key");
    }

    // TODO(fork #3 wiring): point registration at OUR HolderRegistration.registerDocumentViaNoir
    // (docType + holderRoot) on OUR deployed HolderStateKeeper, not upstream RegistrationSimple.
    // Until then this drives the upstream lite-registration path (single-doc on upstream chain).
    let registrationId: string | undefined;
    if (status === DocumentStatus.NotRegistered) {
      registrationId = String(await rarime.registerIdentity(passport));
    }

    const doc: StoredDocument = {
      documentKey: toPaddedHex32(passport.getPassportKey()),
      docType,
      country: opts.country,
      notAfter: opts.notAfter,
      registeredAt: nowSeconds(),
      status: LeafStatus.Current,
      registrationId,
    };

    const docs = await this.store.getDocuments();
    if (docs.some((d) => d.documentKey === doc.documentKey)) {
      throw new Error("IdentityVault: document already in this vault");
    }
    await this.store.setDocuments([...docs, doc]);
    return doc;
  }

  /**
   * Renew: register `newPassport` and supersede the old document under the SAME holder key.
   * Identity continuity is preserved (holder root unchanged) — pseudonyms/state carry over.
   */
  async renewDocument(
    oldDocumentKey: string,
    newPassport: RarimePassport,
    docType: DocumentType,
    opts: { country?: string; notAfter?: number } = {},
  ): Promise<StoredDocument> {
    const docs = await this.store.getDocuments();
    const old = docs.find((d) => d.documentKey === oldDocumentKey);
    if (!old) throw new Error("IdentityVault: old document not found");

    // TODO(fork #2 + #3): on-chain this is HolderRegistration.renewDocumentViaNoir(oldKey, newPassport,
    // holderRoot) — atomic supersede-old + bind-new + link proof. The query circuit must then treat
    // the old leaf as non-current. Here we register the new doc and mark the old superseded locally.
    const fresh = await this.addDocument(newPassport, docType, opts);

    const updated = (await this.store.getDocuments()).map((d) =>
      d.documentKey === oldDocumentKey ? { ...d, status: LeafStatus.Superseded } : d,
    );
    await this.store.setDocuments(updated);
    return fresh;
  }

  /** Revoke a document (lost/stolen/compromised). On-chain: HolderRegistration.revokeDocumentViaSigner. */
  async revokeDocument(documentKey: string): Promise<void> {
    // TODO(fork #2 + #3): on-chain revoke marks the SMT leaf REVOKED; the query circuit must reject it.
    const updated = (await this.store.getDocuments()).map((d) =>
      d.documentKey === documentKey ? { ...d, status: LeafStatus.Revoked } : d,
    );
    await this.store.setDocuments(updated);
  }
}

/** Reverse the on-chain docType hash (keccak of the name) back to the DocumentType enum. */
function docTypeFromHash(hash: string): DocumentType {
  const h = hash.toLowerCase();
  if (h === DOC_TYPE.PASSPORT.toLowerCase()) return DocumentType.Passport;
  if (h === DOC_TYPE.NATIONAL_ID.toLowerCase()) return DocumentType.NationalId;
  if (h === DOC_TYPE.MDL.toLowerCase()) return DocumentType.Mdl;
  if (h === DOC_TYPE.EUDI_PID.toLowerCase()) return DocumentType.EudiPid;
  if (h === DOC_TYPE.NOTARIAL_TITLE.toLowerCase()) return DocumentType.NotarialTitle;
  return DocumentType.Passport; // unknown docType hash → default
}

/** Map the on-chain DocStatus to the wallet's LeafStatus. */
function leafStatusFromChain(s: DocStatus): LeafStatus {
  if (s === DocStatus.Current) return LeafStatus.Current;
  if (s === DocStatus.Superseded) return LeafStatus.Superseded;
  return LeafStatus.Revoked; // Revoked or None → non-current
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function isExpired(d: StoredDocument, nowSec: number): boolean {
  return d.notAfter !== undefined && d.notAfter > 0 && d.notAfter < nowSec;
}
