# Changelog

## 1.1.0

- **React Native engine** (`react_native`) in the opt-in `flutter_react_embed_ios/ReactNative` CocoaPods subspec. The default `Core` subspec, which Flutter installs, is the unchanged WKWebView engine.
  - `NativeRuntime` renders root views from a lazily created, process-wide `RCTReactNativeFactory` (New Architecture) that loads the Flutter asset `main.jsbundle`, or from a factory the app passes to `FlutterReactEmbedReactNativeHost.use(_:)`.
  - `FlutterReactEmbedModule` (`NativeModules.FlutterReactEmbed`) carries JSON-RPC frames, with per-runtime readiness handshakes and outbound queues that reset on JS reload.
  - Props updates re-render the root natively through `appProperties`. Released surfaces are stopped explicitly.
  - Without the subspec the engine fails with `UNSUPPORTED_ENGINE`. Swift Package Manager builds include the web engine only.
- `ReactPlatformView` now switches on the engine. Factories are registered for `dev.flutter_react_embed/view/web` and `dev.flutter_react_embed/view/react_native`.
- `EmbedRuntime` protocol shared by `WebRuntime` and `NativeRuntime`. `BUNDLE_INTEGRITY` messages name the file that was checked.

## 1.0.0

Initial release.

- `WKWebView` engine serving bundles from Flutter assets through a `WKURLSchemeHandler`, with SPA route fallback and path-traversal protection.
- `WKScriptMessageHandler` transport through weak proxies; uncaught errors and promise rejections reported to Dart.
- Boot handshake, outbound frame queue, content-process termination handling and SHA-256 bundle verification.
- `ReactPlatformViewFactory` and platform view teardown on release.
