// ════════════════════════════════════════════════════════════════════════
//   FRONTRUNNING PROTECTION — route every state-changing tx through a private,
//   MEV-protected relay so it skips the PUBLIC mempool (where searchers can
//   sandwich / frontrun it) and goes straight to block builders.
//
//   Free relay, configurable: Flashbots Protect (default) or MEV Blocker.
//
//   🔑 PORTING THIS FILE TURNED ITS CENTRAL CAVEAT INTO A GUARANTEE, and that is the single
//   biggest thing the move to React Native buys. The SPA version said:
//
//     "HONEST CONSTRAINT: with an EOA wallet (MetaMask), `eth_sendTransaction` signs AND
//      broadcasts in the wallet, so the dApp can't force the broadcast path per-call. The only
//      programmatic lever is switching the wallet's mainnet RPC to the relay via
//      `wallet_addEthereumChain` (best-effort — the user must accept). A HARD guarantee needs
//      the AA layer (a dApp-controlled ERC-4337 bundler that submits through the private relay)."
//
//   ⇒ **THAT CONSTRAINT WAS A PROPERTY OF THE BROWSER WALLET, NOT OF THE PROBLEM.** Here the app
//   holds the key, so it SIGNS LOCALLY and CHOOSES THE ENDPOINT: sign → `eth_sendRawTransaction`
//   at the relay. There is no separate wallet to ask, nothing for a user to decline, and no
//   per-call escape. The protection stops being best-effort defence-in-depth and becomes
//   structural — **and the ERC-4337 bundler that was named as the only route to a hard guarantee
//   is no longer needed for this purpose.** Check that TODO before building it.
//
//   ⚠️ THE GUARANTEE IS ENFORCED BY CONSTRUCTION, NOT BY A CHECK. `setSigner` DISCARDS whatever
//   provider the caller's signer carried and re-connects it to the relay itself. A signer wired
//   to a public RPC cannot be installed here, because there is no code path that keeps it — the
//   bad state is unconstructible rather than detectable, which is the stronger of the two.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'

/// Relay defaults. ⚠️ NOT read from `process.env` any more: those were `NEXT_PUBLIC_*`, which is
/// a Next build-time convention that does not exist in Expo. The app passes overrides through
/// `configureProtection` at boot, so this file has no opinion about how the app stores config.
export const DEFAULT_PROTECT = {
  url: 'https://rpc.flashbots.net',
  name: 'Ethereum (Flashbots Protect)',
}

let relay = { ...DEFAULT_PROTECT }
let provider: ethers.JsonRpcProvider | null = null
let signer: ethers.Signer | null = null

/// Point the relay somewhere else (MEV Blocker, or a testnet endpoint). Must be called BEFORE
/// `setSigner`, because the signer is bound to the relay at install time — calling it after
/// throws rather than silently leaving a signer attached to the previous endpoint.
export function configureProtection(opts: { url?: string; name?: string }): void {
  if (signer) {
    throw new Error(
      'protect: configureProtection after setSigner would leave the signer bound to the OLD ' +
      'relay — configure first, then install the signer',
    )
  }
  relay = { ...relay, ...opts }
  provider = null
}

function relayProvider(): ethers.JsonRpcProvider {
  if (!provider) provider = new ethers.JsonRpcProvider(relay.url)
  return provider
}

/// Install the app's signer. Its provider is REPLACED with the relay's — see the header.
export function setSigner(s: ethers.Signer | null): void {
  signer = s ? s.connect(relayProvider()) : null
}

/// Whether writes can be broadcast. Unlike the SPA's version this is not "did the user accept a
/// prompt" — it is simply whether a signer has been installed, because acceptance is not part of
/// the flow any more.
export function protectionEnabled(): boolean {
  return signer !== null
}

/// The relay this app broadcasts through, for display.
export function protectionRelay(): { url: string; name: string } {
  return { ...relay }
}

export interface Tx { from?: string; to: string; data?: string; value?: string; gas?: string }

/// THE single chokepoint for every state-changing tx. All writes route through here so the
/// protection cannot be bypassed by an un-wrapped call site.
///
/// Takes the SAME hex-string `Tx` the SPA used, so ported call sites need no edit; the
/// conversion to ethers' bigint fields happens here rather than at 30 call sites.
export async function sendTx(tx: Tx): Promise<string> {
  if (!signer) throw new Error('protect: no signer installed (call setSigner first)')
  const sent = await signer.sendTransaction({
    to: tx.to,
    data: tx.data,
    value: tx.value ? BigInt(tx.value) : undefined,
    gasLimit: tx.gas ? BigInt(tx.gas) : undefined,
  })
  return sent.hash
}
