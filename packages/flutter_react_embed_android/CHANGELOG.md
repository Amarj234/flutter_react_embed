# Changelog

## 1.0.0

Initial release.

- WebView engine serving bundles from Flutter assets through `WebViewAssetLoader`, with SPA route fallback and path-traversal protection.
- `WebMessageListener` transport with a `@JavascriptInterface` fallback for older WebViews.
- Boot handshake, outbound frame queue, renderer crash handling and SHA-256 bundle verification.
- `ReactPlatformView` with Activity-safe context swapping and full WebView teardown on dispose.
