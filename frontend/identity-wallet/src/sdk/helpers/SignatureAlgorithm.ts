// OID Constants (Object Identifiers) for signature algorithms.
// These values are standard OIDs for various digital signature schemes used in X.509/CMS (SoD).
const SHA_1_WITH_RSA_ENCRYPTION = "1.2.840.113549.1.1.5";
const SHA_224_WITH_RSA_ENCRYPTION = "1.2.840.113549.1.1.14";
const SHA_256_WITH_RSA_ENCRYPTION = "1.2.840.113549.1.1.11";
const SHA_384_WITH_RSA_ENCRYPTION = "1.2.840.113549.1.1.12";
const SHA_512_WITH_RSA_ENCRYPTION = "1.2.840.113549.1.1.13";
const RSA_ENCRYPTION = "1.2.840.113549.1.1.1";
const ID_RSASSA_PSS = "1.2.840.113549.1.1.10";

const ECDSA_WITH_SHA_224 = '1.2.840.10045.4.3.1';
const ECDSA_WITH_SHA_256 = "1.2.840.10045.4.3.2";
const ECDSA_WITH_SHA_384 = "1.2.840.10045.4.3.3";
const ECDSA_WITH_SHA_512 = "1.2.840.10045.4.3.4";


export enum SignatureAlgorithmType {
    RSA = 'RSA',
    RsaPss = 'RSA-PSS',
    ECDSA = 'ECDSA',
}


export class SignatureAlgorithm {
    private type: SignatureAlgorithmType;

    constructor(type: SignatureAlgorithmType) {
        this.type = type;
    }

    public static fromOID(oid: string): SignatureAlgorithm {
        switch (oid) {
            // RSA family algorithms
            case SHA_1_WITH_RSA_ENCRYPTION:
            case SHA_224_WITH_RSA_ENCRYPTION:
            case SHA_256_WITH_RSA_ENCRYPTION:
            case SHA_384_WITH_RSA_ENCRYPTION:
            case SHA_512_WITH_RSA_ENCRYPTION:
            case RSA_ENCRYPTION:
                return new SignatureAlgorithm(SignatureAlgorithmType.RSA);

            // RSA-PSS (Probabilistic Signature Scheme)
            case ID_RSASSA_PSS:
                return new SignatureAlgorithm(SignatureAlgorithmType.RsaPss);

            // ECDSA (Elliptic Curve Digital Signature Algorithm) family
            case ECDSA_WITH_SHA_224:
            case ECDSA_WITH_SHA_256:
            case ECDSA_WITH_SHA_384:
            case ECDSA_WITH_SHA_512:
                return new SignatureAlgorithm(SignatureAlgorithmType.ECDSA);

            default:
                throw new Error(`Not supported ObjectIdentifier for signature algorithm: ${oid}`);
        }
    }

    public toString(): string {
        return this.type;
    }
}