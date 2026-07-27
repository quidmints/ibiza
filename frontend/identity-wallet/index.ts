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

import { registerRootComponent } from "expo";

import App from "./App";

registerRootComponent(App);
