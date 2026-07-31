// App entry point.
//
// package.json's `main` has always said `index.ts`, but this file DID NOT EXIST and was never
// tracked in git — so `expo export` / `expo start` failed immediately with "Cannot resolve entry
// file: The `main` field defined in your package.json points to an unresolvable or non-existent
// path." The app could not be bundled at all, on any platform. Added 2026-07-27.
//
// `registerRootComponent` is the Expo SDK 50+ entry convention: it calls AppRegistry.registerComponent
// and additionally sets up the environment correctly whether the app is loaded in Expo Go or in a
// native build.

// MUST BE FIRST. `polyfills.ts` installs `crypto.getRandomValues` (via
// react-native-get-random-values) and `global.Buffer`. It existed but WAS NEVER IMPORTED - nothing
// in index.ts, App.tsx, src/, metro.config.js or babel.config.js referenced it (sec. 2.18bd).
//
// The failure this caused is loud rather than dangerous: metro aliases `crypto` to
// crypto-browserify, whose `randombytes` exports a function that THROWS ("Secure random number
// generation is not supported") when `global.crypto.getRandomValues` is missing. It does NOT fall
// back to Math.random, so a weak mnemonic was never possible - identity creation would simply fail.
// But an import that must precede all others is exactly the kind that gets dropped, so its position
// here is load-bearing and not stylistic.
import "./polyfills";

import { registerRootComponent } from "expo";

import App from "./App";

registerRootComponent(App);
