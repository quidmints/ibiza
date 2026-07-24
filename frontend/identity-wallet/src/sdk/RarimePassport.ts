import { Buffer } from "buffer";
import * as asn1js from "asn1js";
import { Poseidon } from "@iden3/js-crypto";
import { HashAlgorithm } from "./helpers/HashAlgorithm";
import { Sod } from "./utils";
import { DG1, DG15, SOD } from "@li0ard/tsemrtd";
import { CertificateSet } from "@peculiar/asn1-cms";
import { ProposalInfo } from "./types";
import { MRZ_ZERO_DATE } from "./Freedomtool";

export interface MRZData {
  documentType: string;
  issuingCountry: string;
  documentNumber: string;
  birthDate: string;
  sex: string;
  expiryDate: string;
  lastName: string;
  firstName: string;
}

export type ActiveAuthKey =
  | { type: "Rsa"; modulus: bigint; exponent: bigint }
  | { type: "Ecdsa"; keyBytes: Uint8Array };

export enum DocumentStatus {
  NotRegistered = "NOT_REGISTERED",
  RegisteredWithThisPk = "REGISTERED_WITH_THIS_PK",
  RegisteredWithOtherPk = "REGISTERED_WITH_OTHER_PK",
}

export interface RarimePassportProps {
  dataGroup1: Uint8Array;
  sod: Uint8Array;
  dataGroup15?: Uint8Array;
  aaSignature?: Uint8Array;
  aaChallenge?: Uint8Array;
}

export interface VotingCriteria {
  citizenshipWhitelist: string[];
  sex: string;
  birthDateLowerbound: string;
  birthDateUpperbound: string;
  expirationDateLowerbound: string;
}

export class RarimePassport {
  public dataGroup1: Uint8Array;
  public dataGroup15?: Uint8Array;
  public aaSignature?: Uint8Array;
  public aaChallenge?: Uint8Array;
  public sod: Uint8Array;

  constructor(props: RarimePassportProps) {
    this.dataGroup1 = props.dataGroup1;
    this.sod = props.sod;
    this.dataGroup15 = props.dataGroup15;
    this.aaSignature = props.aaSignature;
    this.aaChallenge = props.aaChallenge;
  }

  public getPassportKey(): bigint {
    if (this.dataGroup15) {
      const key = this.parseDg15Pubkey();

      if (key.type === "Ecdsa") {
        return this.extractEcdsaPassportKey(key.keyBytes);
      } else {
        return this.extractRsaPassportKey(key.modulus, key.exponent);
      }
    }

    return this.getPassportHash();
  }

  public getPassportHash(): bigint {
    const signedAttributes = this.extractSignedAttributes();

    let hashBlock = HashAlgorithm.fromOID(this.getSignatureAlgorithm());

    let hashBytes = hashBlock.getHashFixed32(signedAttributes);

    let out = 0n;
    let acc = 0n;
    let accBits = 0;

    for (let i = 251; i >= 0; i--) {
      const byteIndex = Math.floor(i / 8);
      const bitIndex = 7 - (i % 8);
      const bit = (BigInt(hashBytes[byteIndex]) >> BigInt(bitIndex)) & 1n;

      // acc = (acc << 1) | bit
      acc = (acc << 1n) | bit;
      accBits += 1;

      if (accBits === 64) {
        out = (out << 64n) | acc;
        acc = 0n;
        accBits = 0;
      }
    }

    if (accBits > 0) {
      out = (out << BigInt(accBits)) | acc;
    }

    return Poseidon.hash([out]);
  }

  public extractSignedAttributes(): Uint8Array {
    const buffer = this.sod;
    const sod = new Sod(buffer);
    const signedAttributes = sod.signedAttributes;
    return signedAttributes;
  }

  public extractDGHashAlgo(): string {
    const buffer = Buffer.from(this.sod); // Use tsmrtd's SOD parser
    const sod = SOD.load(buffer);
    return sod.ldsObject.algorithm.algorithm;
  }

  public getSignatureAlgorithm(): string {
    const buffer = Buffer.from(this.sod);
    const sod = SOD.load(buffer);

    const signatureAlgorithmOID =
      sod.signatures[0].signatureAlgorithm.algorithm;

    if (!signatureAlgorithmOID.startsWith("1.2.840.")) {
      throw new Error("Signature algorithm OID does not start with 1.2.840.");
    }

    return signatureAlgorithmOID;
  }

  public extractEncapsulatedContent(): Uint8Array {
    const buffer = this.sod;
    const sod = new Sod(buffer);
    const encapsulatedContent = sod.encapsulatedContent;
    return encapsulatedContent;
  }

  public extractSignature(): Uint8Array {
    const buffer = this.sod;
    const sod = new Sod(buffer);
    const signature = sod.signature;
    return signature;
  }

  public getMRZData(): MRZData {
    const mrz = DG1.load(this.dataGroup1);
    /**
     * Example of MRZ String
     *
     * IDUTO<<<<<<<<<<<<<<<<<<<<<<<<<<
     * 1234567897UTO9001019M3001018<<
     * JOHN<<DOE<<<<<<<<<<<<<<<<<<<
     *
     */
    const documentType = mrz.slice(0, 2);
    const issuingCountry = mrz.slice(2, 5);
    const documentNumber = mrz.slice(5, 14);

    const birthDate = mrz.slice(30, 36);

    const sexChar = mrz.charAt(37);

    const sex = sexChar;

    const expiryDate = mrz.slice(38, 44);

    const namesPart = mrz.slice(60);
    // split by '<<' like in Rust .split("<<")
    const [firstName = "", lastName = ""] = namesPart.split("<<");

    const result: MRZData = {
      documentType,
      issuingCountry,
      documentNumber,
      birthDate,
      sex,
      expiryDate,
      lastName: firstName,
      firstName: lastName,
    };
    return result;
  }

  public getCertificate(): CertificateSet {
    const buffer = Buffer.from(this.sod);
    const sod = SOD.load(buffer);
    const certificates = sod.certificates;
    return certificates;
  }

  public verifyPassport(proposalInfo: ProposalInfo) {
    const mrz = this.getMRZData();

    if (
      proposalInfo.criteria.citizenshipWhitelist.length &&
      !proposalInfo.criteria.citizenshipWhitelist.includes(
        BigInt("0x" + Buffer.from(mrz.issuingCountry).toString("hex"))
      )
    ) {
      throw new Error("Citizen is not in whitelist");
    }

    if (
      proposalInfo.criteria.sex !== 0n &&
      proposalInfo.criteria.sex !== BigInt(mrz.sex)
    ) {
      throw new Error(
        `Sex mismatch, expected ${proposalInfo.criteria.sex}, received ${BigInt(
          mrz.sex
        )}`
      );
    }

    if (
      proposalInfo.criteria.birthDateLowerbound !== MRZ_ZERO_DATE &&
      proposalInfo.criteria.birthDateLowerbound > BigInt(mrz.birthDate)
    ) {
      throw new Error("Birth date is lower than lowerbound");
    }

    if (
      proposalInfo.criteria.birthDateUpperbound !== MRZ_ZERO_DATE &&
      proposalInfo.criteria.birthDateUpperbound < BigInt(mrz.birthDate)
    ) {
      throw new Error("Birth date is higher than upperbound");
    }

    if (
      proposalInfo.criteria.expirationDateLowerbound !== MRZ_ZERO_DATE &&
      proposalInfo.criteria.expirationDateLowerbound >
        BigInt("0x" + Buffer.from(mrz.expiryDate).toString("hex"))
    ) {
      throw new Error("Expiration date is lower than lowerbound");
    }
  }

  private extractEcdsaPassportKey(keyBytes: Uint8Array): bigint {
    if (keyBytes.length !== 65 || keyBytes[0] !== 0x04) {
      throw new Error("UnsupportedPassportKey: Invalid ECDSA key format");
    }

    const xBytes = keyBytes.slice(1, 33);
    const yBytes = keyBytes.slice(33, 65);

    const xHex = Array.from(xBytes, (b) =>
      b.toString(16).padStart(2, "0")
    ).join("");
    const yHex = Array.from(yBytes, (b) =>
      b.toString(16).padStart(2, "0")
    ).join("");

    const x = BigInt("0x" + xHex);
    const y = BigInt("0x" + yHex);

    // 2^248
    const modulus = 1n << 248n;

    const xMod = x % modulus;
    const yMod = y % modulus;

    return Poseidon.hash([xMod, yMod]);
  }

  private extractRsaPassportKey(modulus: bigint, exponent: bigint): bigint {
    const bitLen = modulus.toString(2).length;
    const requiredBits = 200 * 4 + 224; // 1024

    if (bitLen < requiredBits) {
      throw new Error("UnsupportedPassportKey: Modulus too short");
    }

    const shift = BigInt(bitLen - requiredBits);
    let topBits = modulus >> shift;

    const chunkSizes = [224, 200, 200, 200, 200];
    const chunks: bigint[] = [];

    for (const size of chunkSizes) {
      const mask = (1n << BigInt(size)) - 1n;
      const chunk = topBits & mask;
      chunks.push(chunk);

      topBits >>= BigInt(size);
    }

    chunks.reverse();

    return Poseidon.hash(chunks);
  }

  private parseDg15Pubkey(): ActiveAuthKey {
    if (!this.dataGroup15) {
      throw new Error("DG15 data is not provided");
    }

    // DG15 contains SubjectPublicKeyInfo (SPKI)
    const spki = DG15.load(Buffer.from(this.dataGroup15));
    const algorithmOid = spki.algorithm.algorithm; // OID string

    // BIT STRING in SPKI: first octet is 'unused bits' count (usually 0)
    let spkBytes = new Uint8Array(spki.subjectPublicKey);
    if (spkBytes.length > 0 && spkBytes[0] === 0x00) {
      spkBytes = spkBytes.slice(1);
    }

    // RSA public key
    if (algorithmOid === "1.2.840.113549.1.1.1") {
      const der = spkBytes.buffer.slice(
        spkBytes.byteOffset,
        spkBytes.byteOffset + spkBytes.byteLength
      );
      const asn = asn1js.fromBER(der);
      if (asn.offset === -1 || !(asn.result instanceof asn1js.Sequence)) {
        throw new Error("Failed to parse RSA public key from DG15");
      }

      const seq = asn.result as asn1js.Sequence;
      const values = (seq.valueBlock as any).value as any[];
      if (!values || values.length < 2) {
        throw new Error("Invalid RSA public key structure");
      }

      const modulusBlock = values[0] as asn1js.Integer;
      const exponentBlock = values[1] as asn1js.Integer;

      const modBuf = Buffer.from(
        (modulusBlock.valueBlock as any).valueHex as ArrayBuffer
      );
      const expBuf = Buffer.from(
        (exponentBlock.valueBlock as any).valueHex as ArrayBuffer
      );

      const modulus = BigInt("0x" + modBuf.toString("hex"));
      const exponent = BigInt("0x" + expBuf.toString("hex"));

      return { type: "Rsa", modulus, exponent };
    }

    // EC public key (uncompressed EC point)
    if (algorithmOid === "1.2.840.10045.2.1") {
      return { type: "Ecdsa", keyBytes: spkBytes };
    }

    throw new Error(`Unsupported public key algorithm OID: ${algorithmOid}`);
  }
}
