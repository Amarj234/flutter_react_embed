// Tells the React Native CLI where the host Android app lives. In a regular
// brownfield app node_modules sits next to android/ and this is detected; here
// the probe is installed into example/.rn_mock, so it is spelled out. The
// React Native Gradle plugin needs packageName to generate PackageList and
// the entry point.
module.exports = {
  project: {
    android: {
      sourceDir: '../android',
      packageName: 'dev.flutterreactembed.flutter_react_embed_example',
    },
  },
};
