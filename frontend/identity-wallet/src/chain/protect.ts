// ════════════════════════════════════════════════════════════════════════
//   FRONTRUNNING PROTECTION — route every state-changing tx through a private,
//   MEV-protected relay so it skips the PUBLIC mempool (where searchers can
//   sandwich / frontrun it) and goes straight to block builders.
//
//   🔴 PORTED, NOT DISSOLVED (2026-08-16, corrected). My first pass at this file DELETED
//   `enableProtection` and renamed `PROTECT`, on the argument that the SPA's caveat — a browser
//   wallet signs AND broadcasts, so a dApp cannot force the path — stops applying once the app
//   holds the key. The premise is true and the conclusion was wrong twice over:
//
//     1. `page.tsx` IMPORTS BOTH. `:292` does `setProtect(await enableProtection())` to drive the
//        UI badge and `:1002` reads `PROTECT.name` for its tooltip. Dropping them does not
//        simplify the port, it breaks ~20 call sites' module the moment the view layer lands.
//     2. "The app picks the endpoint" is NOT the same as "the endpoint is private". Pointing at a
//        general-purpose RPC and signing locally gets you a PUBLIC mempool broadcast with extra
//        steps. What buys privacy is the endpoint being a protected one — so the question
//        `enableProtection` answers is still real, it just has a better answer available.
//
//   ⇒ The API is unchanged. What changed is that `enableProtection` now MEASURES instead of
//   ASKING. In the browser it fired `wallet_addEthereumChain` and returned whether the user
//   accepted a prompt — a proxy for the thing we care about. Here it probes the configured
//   endpoint and reports whether it will actually take a private send.
//
//   ⚠️ **ALCHEMY'S STANDARD ENDPOINT IS NOT PRIVATE.** `https://eth-mainnet.g.alchemy.com/v2/KEY`
//   is a general RPC; on Alchemy the privacy comes from their private-transaction METHOD, not
//   from the URL. That is the opposite of Flashbots Protect / MEV Blocker, where privacy is a
//   property of the URL and a plain `eth_sendRawTransaction` is already private. Both shapes are
//   supported below, because assuming either one is how a build silently loses its protection.
//
//   ⚠️ **THE VENDOR METHOD'S PARAMETER SHAPE IS UNVERIFIED AND IS TREATED AS SUCH.** Alchemy's
//   private-transaction reference 404s at both documented URLs as of 2026-08-16 and a search did
//   not surface the params, so `eth_sendPrivateTransaction`'s exact body is a HYPOTHESIS here,
//   not a citation. It is therefore (a) off by default, (b) reached only when the probe says the
//   node knows the method, and (c) marked below with what to confirm. Do not enable it on
//   mainnet against real value until the shape is checked against live docs.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'

/// How a signed transaction reaches a builder.
///
/// * `raw` — plain `eth_sendRawTransaction` at the configured URL. Correct, and already private,
///   for an endpoint whose URL IS the protection (Flashbots Protect, MEV Blocker).
/// * `alchemy-private` — a vendor method on an endpoint that is otherwise public. ⚠️ See the
///   header: the parameter shape is unconfirmed.
export type SendMode = 'raw' | 'alchemy-private'

/// The active relay, exported under its original name because `page.tsx` reads `PROTECT.name`.
/// Mutated by `configureProtection` rather than replaced, so an imported reference stays live.
export const PROTECT: { url: string; name: string; mode: SendMode } = {
  url: 'https://rpc.flashbots.net',
  name: 'Ethereum (Flashbots Protect)',
  mode: 'raw',
}

let provider: ethers.JsonRpcProvider | null = null
let signer: ethers.Signer | null = null
let enabled = false
let probed = false

/// Point protection at a different endpoint — e.g. Alchemy secure RPC:
///   configureProtection({ url: `https://eth-mainnet.g.alchemy.com/v2/${key}`,
///                         name: 'Alchemy (private)', mode: 'alchemy-private' })
///
/// Must be called BEFORE `setSigner`: the signer is bound to the endpoint at install time, so
/// reconfiguring afterwards would leave it broadcasting to the previous one. That throws rather
/// than rebinding silently, because a signer still pointed at the old URL is exactly the failure
/// this file exists to prevent and it would not show up anywhere.
export function configureProtection(opts: Partial<typeof PROTECT>): void {
  if (signer) {
    throw new Error(
      'protect: configureProtection after setSigner would leave the signer bound to the OLD ' +
      'endpoint — configure first, then install the signer',
    )
  }
  Object.assign(PROTECT, opts)
  provider = null
  enabled = false
  probed = false
}

function relayProvider(): ethers.JsonRpcProvider {
  if (!provider) provider = new ethers.JsonRpcProvider(PROTECT.url)
  return provider
}

/// Install the app's signer. Its provider is REPLACED with the relay's.
///
/// ⚠️ By construction, not by a check: whatever provider the caller's signer carried is
/// discarded, so a signer wired to a public RPC cannot be installed here. There is no code path
/// that keeps it — the bad state is unconstructible rather than detectable.
export function setSigner(s: ethers.Signer | null): void {
  signer = s ? s.connect(relayProvider()) : null
}

/// Whether the last probe found a working private path. Same meaning to the UI as the SPA's
/// version — "is this session protected" — with a measurement behind it instead of a prompt.
export function protectionEnabled(): boolean {
  return enabled
}

/// Establish whether the configured endpoint will take a private send. Idempotent; re-probes
/// only when `force`.
///
/// 🔑 THE PROBE FOR THE VENDOR METHOD IS `method not found` vs ANY OTHER ERROR, which is a real
/// discriminator rather than a guess: a node that does not implement a method answers JSON-RPC
/// −32601, while one that does rejects our deliberately-empty params with an invalid-params
/// error instead. So "the node knows this method" is answerable WITHOUT sending value and
/// WITHOUT knowing the parameter shape — which is what lets the unverified shape stay quarantined
/// behind a fact rather than behind an assumption.
///
/// For `raw` there is nothing to probe beyond reachability: the endpoint's URL is the protection,
/// so a responding node IS the protected path.
export async function enableProtection(force = false): Promise<boolean> {
  if (probed && !force) return enabled
  probed = true
  try {
    const p = relayProvider()
    if (PROTECT.mode === 'raw') {
      await p.send('eth_chainId', [])
      enabled = true
    } else {
      try {
        await p.send('eth_sendPrivateTransaction', [])
        enabled = true // accepted empty params: unexpected, but the method exists
      } catch (e: any) {
        const code = e?.error?.code ?? e?.code
        const msg = String(e?.error?.message ?? e?.message ?? '')
        const unknownMethod = code === -32601 || /method not (found|supported)/i.test(msg)
        enabled = !unknownMethod
      }
    }
  } catch { enabled = false }
  return enabled
}

export interface Tx { from?: string; to: string; data?: string; value?: string; gas?: string }

/// THE single chokepoint for every state-changing tx. All writes route through here so the
/// protection cannot be bypassed by an un-wrapped call site.
///
/// Takes the SAME hex-string `Tx` the SPA used, so the ~20 ported call sites need no edit; the
/// conversion to ethers' bigint fields happens here rather than at each of them.
///
/// ⚠️ FALLS BACK TO A PUBLIC-PATH SEND RATHER THAN FAILING, which is what the SPA did too
/// (`sendTx` called `enableProtection()` and sent regardless of the answer). Liveness wins over
/// privacy here deliberately — but `protectionEnabled()` then reports FALSE, so the badge tells
/// the truth instead of the send silently losing its protection. If that trade is ever wrong for
/// a given action, the caller is the place to refuse, not this function.
export async function sendTx(tx: Tx): Promise<string> {
  if (!signer) throw new Error('protect: no signer installed (call setSigner first)')
  await enableProtection()

  const req = {
    to: tx.to,
    data: tx.data,
    value: tx.value ? BigInt(tx.value) : undefined,
    gasLimit: tx.gas ? BigInt(tx.gas) : undefined,
  }

  if (PROTECT.mode === 'alchemy-private' && enabled) {
    // ⚠️ UNVERIFIED SHAPE — see the file header. `{ tx: <signed hex> }` is the shape to CONFIRM
    // against Alchemy's live reference (along with whether `maxBlockNumber` / `preferences` are
    // accepted and whether it is mainnet-only) before this branch is trusted with real value.
    const populated = await signer.populateTransaction(req)
    const signed = await signer.signTransaction(populated)
    return relayProvider().send('eth_sendPrivateTransaction', [{ tx: signed }])
  }

  const sent = await signer.sendTransaction(req)
  return sent.hash
}
