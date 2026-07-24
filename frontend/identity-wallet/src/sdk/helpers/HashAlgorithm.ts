import {sha1} from '@noble/hashes/sha1';
import {sha224, sha256} from '@noble/hashes/sha256';
import {sha384, sha512} from '@noble/hashes/sha512';

const ID_SHA_1 = '1.3.14.3.2.26';
const SHA_1_WITH_RSA_ENCRYPTION = '1.2.840.113549.1.1.5';

const ID_SHA_224 = '2.16.840.1.101.3.4.2.4';
const SHA_224_WITH_RSA_ENCRYPTION = '1.2.840.113549.1.1.14';
const ECDSA_WITH_SHA_224 = '1.2.840.10045.4.3.1';

const ID_SHA_256 = '2.16.840.1.101.3.4.2.1';
const SHA_256_WITH_RSA_ENCRYPTION = '1.2.840.113549.1.1.11';
const ECDSA_WITH_SHA_256 = '1.2.840.10045.4.3.2';

const ID_SHA_384 = '2.16.840.1.101.3.4.2.2';
const SHA_384_WITH_RSA_ENCRYPTION = '1.2.840.113549.1.1.12';
const ECDSA_WITH_SHA_384 = '1.2.840.10045.4.3.3';

const ID_SHA_512 = '2.16.840.1.101.3.4.2.3';
const SHA_512_WITH_RSA_ENCRYPTION = '1.2.840.113549.1.1.13';
const ECDSA_WITH_SHA_512 = '1.2.840.10045.4.3.4';

export enum HashAlgorithmType {
  SHA1 = 'SHA1',
  SHA224 = 'SHA224',
  SHA256 = 'SHA256',
  SHA384 = 'SHA384',
  SHA512 = 'SHA512',
}

export class HashAlgorithm {
  private type: HashAlgorithmType;

  constructor(type: HashAlgorithmType) {
    this.type = type;
  }

  public static fromOID(oid: string): HashAlgorithm {
    switch (oid) {
      case ID_SHA_1:
      case SHA_1_WITH_RSA_ENCRYPTION:
        return new HashAlgorithm(HashAlgorithmType.SHA1);

      case ID_SHA_224:
      case SHA_224_WITH_RSA_ENCRYPTION:
      case ECDSA_WITH_SHA_224:
        return new HashAlgorithm(HashAlgorithmType.SHA224);

      case ID_SHA_256:
      case SHA_256_WITH_RSA_ENCRYPTION:
      case ECDSA_WITH_SHA_256:
        return new HashAlgorithm(HashAlgorithmType.SHA256);

      case ID_SHA_384:
      case SHA_384_WITH_RSA_ENCRYPTION:
      case ECDSA_WITH_SHA_384:
        return new HashAlgorithm(HashAlgorithmType.SHA384);

      case ID_SHA_512:
      case SHA_512_WITH_RSA_ENCRYPTION:
      case ECDSA_WITH_SHA_512:
        return new HashAlgorithm(HashAlgorithmType.SHA512);

      default:
        throw new Error(
            `Not supported ObjectIdentifier for hash algorithm: ${oid}`,
        );
    }
  }

  public toString(): string {
    return this.type;
  }

  public getByteLength(): number {
    switch (this.type) {
      case HashAlgorithmType.SHA1:
        return 160;
      case HashAlgorithmType.SHA224:
        return 224;
      case HashAlgorithmType.SHA256:
        return 256;
      case HashAlgorithmType.SHA384:
        return 384;
      case HashAlgorithmType.SHA512:
        return 512;
    }
  }

  /**
   * Hashes data and returns exactly 32 bytes (padded or truncated).
   * Used for ZK inputs preparation.
   */
  public getHashFixed32(dataBytes: Uint8Array): Uint8Array {
    let digest: Uint8Array;

    switch (this.type) {
      case HashAlgorithmType.SHA1:
        digest = sha1(dataBytes);
        break;
      case HashAlgorithmType.SHA224:
        digest = sha224(dataBytes);
        break;
      case HashAlgorithmType.SHA256:
        digest = sha256(dataBytes);
        break;
      case HashAlgorithmType.SHA384:
        digest = sha384(dataBytes);
        break;
      case HashAlgorithmType.SHA512:
        digest = sha512(dataBytes);
        break;
      default:
        throw new Error(`Unsupported hash algorithm type`);
    }

    const paddedHash = new Uint8Array(32);
    const len = Math.min(digest.length, 32);

    paddedHash.set(digest.subarray(0, len), 0);

    return paddedHash;
  }
}
