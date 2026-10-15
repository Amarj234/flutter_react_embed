# Changelog

All notable changes to this package are documented here. This project follows [Semantic Versioning](https://semver.org/).

## 1.1.0

Adds a React Native engine next to the React Web engine. No breaking changes: 1.0 code, the web engine and its JavaScript contract work unchanged.

### Features

- **React Native engine.** `ReactView` now renders React Native apps (New Architecture, React Native 0.82+) as well as React web builds. The engine is opt-in: web-only apps don't ship any React Native code. See "React Native engine" in the README.
- `ReactEmbedType { web, native }`: the framework-level alias of `ReactEngineKind`, available as `ReactViewConfiguration.type` and `ReactEngineKind.embedType`.
- `ReactViewConfiguration.web(assetPath:, route:, ...)` and `ReactViewConfiguration.native(bundleName:, iosBundleName:, componentName:, initialProps:, ...)` convenience constructors.
- `ReactViewConfiguration.fromAttributes` accepts `type` (`web` | `native`), `bundleName` and `componentName` as aliases. Setting both an attribute and its alias is rejected.
- `bundleSha256` pins the React Native bundle file, too.
- `example/tool/fre-bridge-native.js`: a JSON-RPC bridge and `useFlutterBridge` hook for React Native components.
- The example app can opt into the React Native Gradle plugin (`FRE_REACT_NATIVE=1`), with a mock React Native app (`tool/rn_probe`), a switching harness (`lib/hybrid_switch_main.dart`), `integration_test/hybrid_switch_test.dart` and `tool/run_local_test.sh`.

### Verified

- The React Web module is unchanged and still passes its 1.0 integration tests.
- Android, on an API 37 emulator with React Native 0.87.1 (`example/tool/run_local_test.sh`): contract tests on both engines and 80 alternating web/native switches pass. No wrong-thread exceptions, no leaked WebView or Activity, and Java heap and View counts are flat between rounds.
- iOS builds with the default (web) subspec. The React Native subspec is not yet compiled or run on a device.

### Removed limitation

- `ReactEngineKind.reactNative` no longer always fails with `UNSUPPORTED_ENGINE`. It still does when the app doesn't include React Native, with a message that explains what to add.

## 1.0.2

- Updated the author section in the README.

## 1.0.1

Documentation only. No code changes.

- Rewrote the README as a step-by-step beginner guide: prerequisites, a full Vite walkthrough, a drop-in `bridge.js`, a React hook, recipes, debugging, troubleshooting and FAQ.
- Added an author section with GitHub and LinkedIn links.

## 1.0.0

Initial release.

### Features

- `ReactView` widget that embeds a production React web build as a platform view: `PlatformViewLink` with texture-layer or hybrid composition on Android, `UiKitView` on iOS.
- `ReactViewConfiguration`, including `fromAttributes` for strict parsing of loosely typed manifests.
- `ReactViewController` for calling JavaScript (`invoke`), sending events (`emit`), receiving events (`events`), serving JavaScript requests (`registerHandler`) and updating props.
- Props updates without remounting: `initialProps` changes are diffed deeply and pushed as `$/updateProps`.
- `ReactSurfaceCache`: keeps surfaces and their runtimes alive across unmounts under a `cacheKey`, with LRU eviction.
- Error boundary with `errorBuilder` and a `retry` callback, covering boot failures, invalid props, platform view creation failures and fatal JavaScript errors.
- Optional bundle integrity pinning via `ReactEngineConfig.bundleSha256`.

### Native bridges

- Federated architecture: `flutter_react_embed_platform_interface`, `flutter_react_embed_android` and `flutter_react_embed_ios`.
- JSON-RPC 2.0 over MethodChannels. Strict validation rejects non-finite numbers, integers outside the JavaScript safe range, non-string keys and cyclic data, and reports the JSON path of the offending value. Includes request timeouts with `$/cancelRequest`, batch decoding and typed exception mapping.
- Android: WebView hosted from Flutter assets through `WebViewAssetLoader`; `WebMessageListener` transport with a `@JavascriptInterface` fallback; document-start boot script; renderer crash recovery; Activity-safe context swapping and full teardown on dispose.
- iOS: `WKWebView` hosted through a `WKURLSchemeHandler` with path-traversal protection; `WKScriptMessageHandler` transport through weak proxies; content-process termination handling; teardown on dispose.
- Frame validation runs on background queues; WebView and channel work stays on the main thread.

### Example and tests

- Example app embedding the open-source CoreUI React admin dashboard next to an internal state view, with a live JavaScript log overlay.
- `tool/setup_test_react.sh`: clones a pinned React app, runs `npm install` and `npm run build`, installs the output as assets, injects the bridge shim, regenerates the pubspec asset list and pins the `index.html` hash.
- On-device integration tests for the native hosts and the dashboard, passing on Android and iOS.
- Unit and widget tests for the protocol, the MethodChannel layer and `ReactView`.

### Known limitations

- Web and desktop platforms are not supported yet.
- The `reactNative` engine kind is reserved; initializing it fails with `UNSUPPORTED_ENGINE`.
