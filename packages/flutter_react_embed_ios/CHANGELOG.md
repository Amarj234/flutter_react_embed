# Changelog

## 1.0.0

Initial release.

- `WKWebView` engine serving bundles from Flutter assets through a `WKURLSchemeHandler`, with SPA route fallback and path-traversal protection.
- `WKScriptMessageHandler` transport through weak proxies; uncaught errors and promise rejections reported to Dart.
- Boot handshake, outbound frame queue, content-process termination handling and SHA-256 bundle verification.
- `ReactPlatformViewFactory` and platform view teardown on release.
