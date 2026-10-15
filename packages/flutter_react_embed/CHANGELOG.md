# Changelog

All notable changes to this package are documented here. This project follows [Semantic Versioning](https://semver.org/).

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
