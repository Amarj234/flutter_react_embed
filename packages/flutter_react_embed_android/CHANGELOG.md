# Changelog

## 1.1.0

- **React Native engine** (`react_native`), next to the unchanged WebView engine:
  - `NativeRuntime` renders `ReactSurface`s from a lazily created, process-wide `ReactHost`. If the app's `Application` implements `ReactApplication`, its `reactHost` is used. Otherwise the plugin builds one over the Flutter asset `index.android.bundle`, initialized through the app's generated `ReactNativeApplicationEntryPoint` and its autolinked `PackageList`.
  - `react-android` is a `compileOnly` dependency. The app must apply the React Native Gradle plugin, which builds `libappmodules.so`. When React Native or `libappmodules.so` is missing, no React Native class is loaded and the engine fails with `UNSUPPORTED_ENGINE`, with a message that names what's missing.
  - `FlutterReactEmbedPackage` / `FlutterReactEmbedModule` (`NativeModules.FlutterReactEmbed`) carry JSON-RPC frames, with per-runtime readiness handshakes and outbound queues that reset on JS reload.
  - Props updates re-render the root natively through `ReactSurfaceImpl.updateInitProps`.
- `ReactPlatformView` now switches on the engine. One factory is registered for `dev.flutter_react_embed/view/web` and one for `dev.flutter_react_embed/view/react_native`.
- Context recycling: surfaces are created over a `MutableContextWrapper` that points back at the application on detach. The plugin is `ActivityAware` and forwards resume, pause and destroy (including configuration changes) to the React Native host, so no Activity is retained.
- `EmbedRuntime` interface shared by `WebRuntime` and `NativeRuntime`. The registry can evict a cache key on every runtime that retains it.

## 1.0.0

Initial release.

- WebView engine serving bundles from Flutter assets through `WebViewAssetLoader`, with SPA route fallback and path-traversal protection.
- `WebMessageListener` transport with a `@JavascriptInterface` fallback for older WebViews.
- Boot handshake, outbound frame queue, renderer crash handling and SHA-256 bundle verification.
- `ReactPlatformView` with Activity-safe context swapping and full WebView teardown on dispose.
