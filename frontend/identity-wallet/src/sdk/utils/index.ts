import {CertificateSet} from '@peculiar/asn1-cms';
import {AsnConvert} from '@peculiar/asn1-schema';
import {Buffer} from 'buffer';

export * from './sod';
export * from './hex';

export function wrapPem(certificates: CertificateSet): string {
  const LINE_LENGTH = 64;

  const pemBlocks: string[] = [];

  for (const choice of certificates) {
    const cert = (choice as any).certificate;
    if (!cert) continue;

    const derBytes = new Uint8Array(AsnConvert.serialize(cert));
    const base64Content = Buffer.from(derBytes).toString('base64');

    let formattedBase64 = '';
    for (let i = 0; i < base64Content.length; i += LINE_LENGTH) {
      formattedBase64 += base64Content.slice(i, i + LINE_LENGTH) + '\n';
    }

    pemBlocks.push(
        `-----BEGIN CERTIFICATE-----\n${formattedBase64}-----END CERTIFICATE-----`,
    );
  }

  if (pemBlocks.length === 0) {
    throw new Error('No X.509 certificates found in CertificateSet');
  }

  // Separate multiple certificates with a blank line
  return pemBlocks.join('\n');
}
