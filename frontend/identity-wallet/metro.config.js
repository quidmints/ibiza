// Learn more https://docs.expo.io/guides/customizing-metro
const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const config = getDefaultConfig(__dirname);

// npm v7+ will install ../node_modules/react and ../node_modules/react-native because of peerDependencies.
// To prevent the incompatible react-native between ./node_modules/react-native and ../node_modules/react-native,
// excludes the one from the parent folder when bundling.
config.resolver.blockList = [
  ...Array.from(config.resolver.blockList ?? []),
  new RegExp(path.resolve('..', 'node_modules', 'react')),
  new RegExp(path.resolve('..', 'node_modules', 'react-native')),
];

config.resolver.nodeModulesPaths = [
  path.resolve(__dirname, './node_modules'),
  path.resolve(__dirname, '../node_modules'),
];

config.resolver.extraNodeModules = {
  crypto: require.resolve('crypto-browserify'),
  stream: require.resolve('readable-stream'),
  buffer: require.resolve('buffer/'),
  // The '@rarimo/rarime-rn-sdk' -> path.resolve(__dirname, '..') mapping that used to live here
  // was REMOVED 2026-07-27, and it was wrong: __dirname is frontend/identity-wallet, so it pointed
  // the package name at frontend/ - a directory containing only identity-wallet/ and
  // secure-recovery/, not the SDK. A leftover from a layout where the SDK was an autolinked
  // sibling. The SDK is now a normal npm dependency ("github:quidmints/rarime-rn-sdk#main") that
  // resolves out of node_modules, so no mapping is needed at all.
};

// Ship this fusion's OWN Noir circuits (assets/circuits/*.circuit) inside the app bundle.
//
// They are ACIR artifacts built by backend/circuits/codegen-verifiers.sh and, unlike upstream
// rarimo's circuits, are not published anywhere - so `downloadByteCode` has nothing to fetch. See
// TODO.md sec. 2.1a.
//
// The `.circuit` extension is deliberate: these files ARE JSON, but Metro treats `.json` as SOURCE
// and would inline + parse a 3.3 MB object into the JS bundle at require time. Registering a
// distinct extension in assetExts keeps them as opaque assets, resolvable to a local URI via
// expo-asset and readable with expo-file-system - which is what the native prover wants anyway
// (it takes the bytecode as a string).
config.resolver.assetExts = [...config.resolver.assetExts, 'circuit'];

config.watchFolders = [path.resolve(__dirname, '..')];

config.transformer.getTransformOptions = async () => ({
  transform: {
    experimentalImportSupport: false,
    inlineRequires: true,
  },
});

module.exports = config;
