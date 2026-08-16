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
//   🔑 **THE RELAY IS FLASHBOTS PROTECT / SUAVE, AND NOTHING ELSE** (owner, 2026-08-16: "we
//   must use the existing mev protect suave"). An earlier pass added an `alchemy-private` mode
//   calling `eth_sendPrivateTransaction`; it is DELETED. Two reasons, and the second is the
//   durable one:
//     * its parameter shape was never verified — Alchemy's reference 404s at both documented
//       URLs — so it was speculative code on the write path, which is the worst place for it;
//     * **Alchemy's standard endpoint is a general RPC: privacy there is a property of the
//       METHOD.** Flashbots Protect is the opposite — privacy is a property of the URL, so a
//       plain `eth_sendRawTransaction` is already private and there is no vendor call to get
//       wrong. One endpoint, one send path, nothing to probe for but reachability.
//   ⇒ Do not reintroduce a per-vendor send method. If the relay ever changes, change the URL.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'

/// The active relay, exported under its original name because `page.tsx` reads `PROTECT.name`.
/// Mutated by `configureProtection` rather than replaced, so an imported reference stays live.
export const PROTECT: { url: string; name: string } = {
  url: 'https://rpc.flashbots.net',
  name: 'Ethereum (Flashbots Protect)',
}

let provider: ethers.JsonRpcProvider | null = null
let signer: ethers.Signer | null = null
let enabled = false
let probed = false

/// Point protection at a different protected endpoint — another Flashbots Protect URL (its
/// hint/builder query parameters are set here), a SUAVE endpoint, or MEV Blocker. ⚠️ It must be
/// an endpoint whose URL IS the protection; a general-purpose RPC here silently makes every send
/// public, and nothing downstream can tell the difference.
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
/// 🔑 REACHABILITY IS THE WHOLE PROBE, and that is a consequence of using Protect/SUAVE rather
/// than a vendor method: the endpoint's URL IS the protection, so a node that answers IS the
/// protected path. There is no capability to interrogate and nothing to get wrong.
/// ⚠️ What it CANNOT tell you is whether `PROTECT.url` is genuinely a protected endpoint — point
/// it at a public RPC and this returns true. That check is `configureProtection`'s caller's job.
export async function enableProtection(force = false): Promise<boolean> {
  if (probed && !force) return enabled
  probed = true
  try {
    await relayProvider().send('eth_chainId', [])
    enabled = true
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
/// 🔑 **THERE IS NO PUBLIC FALLBACK, AND THAT IS A CHANGE FROM THE SPA — the right way round.**
/// The browser version called `enableProtection()` and then sent REGARDLESS of the answer, so a
/// declined prompt meant the tx went out over the public mempool anyway; protection was
/// best-effort because the wallet owned the broadcast. Here the signer is bound to the relay and
/// nothing else, so if the relay is unreachable the send THROWS. **A write either takes the
/// protected path or does not happen** — privacy stops being best-effort without anyone having
/// to remember to check a flag.
/// ⚠️ So `enableProtection` is now purely a UI signal, not a gate: `sendTx` does not consult its
/// result, and could not act on it if it did. Do not add a branch here that "falls back" — that
/// would reintroduce exactly the silent downgrade this shape removes.
export async function sendTx(tx: Tx): Promise<string> {
  if (!signer) throw new Error('protect: no signer installed (call setSigner first)')
  await enableProtection()

  const req = {
    to: tx.to,
    data: tx.data,
    value: tx.value ? BigInt(tx.value) : undefined,
    gasLimit: tx.gas ? BigInt(tx.gas) : undefined,
  }

  const sent = await signer.sendTransaction(req)
  return sent.hash
}
