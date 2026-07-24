module.exports = (api) => {
  api.cache(true);
  return {
    presets: [["babel-preset-expo", { jsxRuntime: "automatic" }]],
    plugins: [
      [
        "module:react-native-dotenv",
        {
          moduleName: "@env",
          path: ".env",
          allowUndefined: true,
          safe: false,
        },
      ],
      [
        "module-resolver",
        {
          root: ["./"],
          alias: {
            // The rarime SDK is FORKED into this project (editable layer). Keep this alias so any
            // forked code that self-references the package name resolves to our local copy.
            "@rarimo/rarime-rn-sdk": "./src/sdk/index",
            // Use the browser ESM build of js-crypto under React Native (matches rarime's setup).
            "@iden3/js-crypto": "@iden3/js-crypto/dist/browser/esm/index.js",
          },
          extensions: [
            ".ios.ts",
            ".android.ts",
            ".ts",
            ".ios.tsx",
            ".android.tsx",
            ".tsx",
            ".jsx",
            ".js",
            ".json",
          ],
        },
      ],
    ],
  };
};
