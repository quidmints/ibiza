# identity-wallet — our fork of rarimo (one key, many documents)

React Native (Expo) identity wallet. First step: **one holder key managing multiple documents**
— multi-citizenship + renewed / revoked / expired passports. (Website-SPA scope parity is later.)

## The fork is THREE layers, not one
"One key, multiple documents" is a structural change that spans the whole rarimo stack:

| Layer | Where | Why it must fork | Status |
|---|---|---|---|
| **1. Contracts (Solidity)** | `app/contracts/holder/` | Upstream `StateKeeper.addBond` requires `_identityInfo.activePassport == 0` → **one identity = one passport**. `HolderStateKeeper` removes that wall + adds renew/supersede/revoke. | ✅ done (11/11 tests) |
| **2. Circuits (Noir)** | `app/circuits/` (forked `passport-zk-circuits-noir`) | The `query_identity` circuit proves SMT membership of `value = Poseidon3(dgCommit, seq, timestamp)` at `position = Poseidon(passportKey, profileKey)` — **byte-for-byte what `HolderStateKeeper` writes**. So revoked/superseded leaves (value overwritten to a marker) **auto-fail** the proof; multi-citizenship = separate leaves under one key. | ✅ **compatible as-is — NO source change** (see `app/circuits/HOLDER-TREE-NOTES.md`). Fork only to self-host/audit bytecode. |
| **3. SDK (TS) — THIS project** | `identity-wallet/src/` | One holder key + a document SET: add (multi-citizenship), renew, revoke, status. | ⏳ this project |

## Layout
```
identity-wallet/
├─ App.tsx                     # multi-document wallet shell (drives IdentityVault)
├─ src/
│  ├─ sdk/                     # FORKED rarime TS (editable layer) — Rarime, RarimePassport,
│  │                          #   RarimeUtils, RnNoirModule, HolderTree, helpers, types, utils
│  └─ identity/
│     ├─ IdentityVault.ts      # ★ one-key-multiple-documents core (add/renew/revoke/list/status)
│     └─ store.ts              # persistence (in-memory demo; SecureStore sketch for prod)
├─ package.json, app.json, babel.config.js, metro.config.js, polyfills.ts, tsconfig.json
```

## What is forked vs depended-on
- **Forked (we edit these):** the rarime **TS SDK** (`src/sdk/`) + the **contracts** (`app/contracts/holder/`) + the **circuits** (TODO). The EUDI adapter (`Eudi.ts`) was dropped — out of scope.
- **Depended-on (we do NOT duplicate):** the **native Noir prover** is ~140 MB of binaries
  (`SwoirenbergLib.xcframework` 140 MB + `noir.aar` 6.9 MB) and is **generic** — it runs whatever
  circuit bytecode we feed it. So we autolink it from the sibling module
  (`expo.autolinking.nativeModulesDir: "../"` → `../rarime-rn-sdk-main`) rather than copy binaries.

## Native-wiring TODOs (need a device build to verify — can't be tested headless)
- `app.plugin.js` flatDir path points at `node_modules/@rarimo/rarime-rn-sdk/android/libs`; for the
  autolinked sibling it must point at `../rarime-rn-sdk-main/android/libs`.
- Confirm the sibling native module (`RnNoir`) autolinks into this app on iOS + Android.
- Passport NFC scanning is **not** in the rarime SDK — add an NFC reader to produce the raw
  `dataGroup1` / `sod` bytes that build a `RarimePassport`.

## Wiring TODOs for true multi-document (fork #2 + deploy)
- Point registration at **our** `HolderRegistration.registerDocumentViaNoir` (docType + holderRoot)
  on **our** deployed `HolderStateKeeper` — not upstream `RegistrationSimple` (the addBond wall).
- `renewDocument` → `HolderRegistration.renewDocumentViaNoir`; `revokeDocument` → `revokeDocumentViaSigner`.
- Fork the **query circuit** so presentations prove "current document under my holder root".
- Fill real addresses/RPC/relayer in `App.tsx CONFIG`.

## Run (device required — native prover)
```
cd identity-wallet
npm install         # or pnpm/yarn
npm run prebuild
npm run ios         # or: npm run android   (real device; native modules don't run in simulators/web)
```
