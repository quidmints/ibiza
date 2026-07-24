const { withProjectBuildGradle } = require('@expo/config-plugins');

const withAndroidFlatDir = (config) => {
  return withProjectBuildGradle(config, (config) => {
    if (config.modResults.language === 'groovy') {
      config.modResults.contents = addFlatDirToRootBuildGradle(config.modResults.contents);
    }
    return config;
  });
};

function addFlatDirToRootBuildGradle(buildGradle) {
 
  const flatDirCode = `
  flatDir {
    // Point directly to the local module's AARs - from example/android to ../../android/libs
    dirs new File(rootDir, '../../android/libs')
 }
  `;

  if (buildGradle.includes('dirs new File(rootDir, \'../../android/libs\')')) {
    return buildGradle;
  }

  const pattern = /allprojects\s*\{[\s\S]*?repositories\s*\{/;
  
  if (!buildGradle.match(pattern)) {
    console.warn('WARNING: Could not find "allprojects { repositories {" in android/build.gradle');
    return buildGradle;
  }

  return buildGradle.replace(pattern, match => `${match}\n${flatDirCode}`);
}

module.exports = withAndroidFlatDir;
