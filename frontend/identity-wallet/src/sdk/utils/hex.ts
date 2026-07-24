export function toPaddedHex32(input: string | bigint): string {
  return "0x" + BigInt(input).toString(16).padStart(64, "0");
}
