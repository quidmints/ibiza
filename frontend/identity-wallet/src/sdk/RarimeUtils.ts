import {babyJub, Poseidon} from '@iden3/js-crypto';

export class RarimeUtils {

  public static generateBJJPrivateKey(): string {
    return babyJub.F.random().toString(16).padStart(64, '0');
  }

  public static getProfileKey(pk: string): string {
    const pubPoint = babyJub.mulPointEScalar(babyJub.Base8, BigInt('0x' + pk));

    const profileKey = Poseidon.hash(pubPoint);

    return profileKey.toString(16).padStart(64, '0');
  }
}
