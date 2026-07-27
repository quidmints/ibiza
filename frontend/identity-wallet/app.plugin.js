const path = require('path');
const { withProjectBuildGradle } = require('@expo/config-plugins');

// Adds a Gradle `flatDir` repository pointing at rarime-rn-sdk's prebuilt AARs (noir.aar etc.),
// which ship inside the package rather than being published to a Maven repo.
//
// FIXED 2026-07-26: this used to hardcode `new File(rootDir, '../../android/libs')` - a leftover
// from the old layout where rarime-rn-sdk was an autolinked SIBLING module two directories up. It
// is now a GitHub npm dependency ("@rarimo/rarime-rn-sdk": "github:quidmints/rarime-rn-sdk#main"),
// so the AARs live under node_modules and that path resolves to nothing; Gradle would simply fail
// to find the AAR at device-build time.
//
// Rather than swap one hardcoded relative path for another, resolve where the package actually is:
// this plugin is plain Node, so it can ask the module resolver, which stays correct under
// hoisting, monorepo layouts and pnpm-style stores alike.
//
// NOT VERIFIED BY A REAL ANDROID BUILD - no JDK/Android SDK/NDK on the machine this was written on
// (TODO.md sec. 1). The resolution is checked at config time and warns loudly if the package is
// missing, but the resulting Gradle file has never been fed to Gradle. Confirm on a machine or CI
// runner that has the Android toolchain.
function resolveSdkLibsDir() {
  try {
    const pkgJson = require.resolve('@rarimo/rarime-rn-sdk/package.json', { paths: [__dirname] });
    return path.join(path.dirname(pkgJson), 'android', 'libs');
  } catch {
    return null;
  }
}

function addFlatDirToRootBuildGradle(buildGradle, libsDir) {
  // Groovy string literal - escape backslashes so Windows paths survive. An absolute resolved path
  // is used rather than one relative to `rootDir`, since node_modules may be hoisted anywhere above
  // the android/ directory.
  const groovyPath = libsDir.replace(/\\/g, '\\\\');
  const marker = `dirs '${groovyPath}'`;

  if (buildGradle.includes(marker)) return buildGradle;

  const flatDirCode = `
  flatDir {
    // rarime-rn-sdk ships prebuilt AARs (noir.aar) in the npm package; path resolved by app.plugin.js
    ${marker}
  }
  `;

  const pattern = /allprojects\s*\{[\s\S]*?repositories\s*\{/;
  if (!buildGradle.match(pattern)) {
    console.warn('WARNING: Could not find "allprojects { repositories {" in android/build.gradle');
    return buildGradle;
  }

  return buildGradle.replace(pattern, (match) => `${match}\n${flatDirCode}`);
}

const withAndroidFlatDir = (config) => {
  const libsDir = resolveSdkLibsDir();
  if (!libsDir) {
    console.warn(
      'WARNING: could not resolve @rarimo/rarime-rn-sdk - skipping the flatDir repository. ' +
        'The Android build will not find noir.aar. Run an install first.'
    );
    return config;
  }

  return withProjectBuildGradle(config, (cfg) => {
    if (cfg.modResults.language === 'groovy') {
      cfg.modResults.contents = addFlatDirToRootBuildGradle(cfg.modResults.contents, libsDir);
    }
    return cfg;
  });
};

module.exports = withAndroidFlatDir;
