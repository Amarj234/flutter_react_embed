# flutter_react_embed

[![pub package](https://img.shields.io/pub/v/flutter_react_embed.svg)](https://pub.dev/packages/flutter_react_embed)
[![pub points](https://img.shields.io/pub/points/flutter_react_embed)](https://pub.dev/packages/flutter_react_embed/score)
[![license: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](https://github.com/Amarj234/flutter_react_embed/blob/main/LICENSE)

Embed production React web apps in Flutter as native platform views, and talk to them over a typed, bidirectional JSON-RPC bridge.

Ship an existing React micro-frontend (a dashboard, a checkout flow, a CMS page) inside your Flutter app without rewriting it. The React build is bundled as Flutter assets and served to a plugin-owned WebView from an in-app origin. No local HTTP server is involved, and the bundle never touches the network.

## Features

- **`ReactView` widget**: renders a React bundle as an Android or iOS platform view.
- **Two-way messaging**: call JavaScript from Dart and Dart from JavaScript, with typed results and errors mapped to Dart exceptions.
- **Events and props**: stream JavaScript events into Dart; push props from Flutter state into React.
- **Integrity pinning**: an optional SHA-256 of `index.html` makes the native host refuse a tampered or stale bundle.
- **Surface cache**: keep a React app alive while its view is off screen and reattach it instantly.
- **Error boundary**: boot failures, invalid props and JavaScript crashes become typed exceptions and a retryable error state.
- **Leak-safe hosting**: WebViews never retain an Activity or view controller after detaching, and are fully torn down on dispose.

## Platform support

| Platform | Engine | Status |
| --- | --- | --- |
| Android | Android System WebView (API 24+) | Supported |
| iOS | WKWebView (iOS 15+) | Supported |
| Web, desktop | - | Not supported yet |

Requires Flutter 3.47 or later. The `ReactEngineKind.reactNative` engine is part of the API for a future release; initializing it today fails with `UNSUPPORTED_ENGINE`.

## Installation

```sh
flutter pub add flutter_react_embed
```

No Android manifest or iOS `Info.plist` changes are required. Add the `INTERNET` permission on Android only if the embedded app calls remote APIs.

## How it works

The bridge does not compile Dart to JavaScript. Dart and JavaScript run in separate runtimes and exchange JSON-RPC 2.0 messages, which native code relays without re-encoding.

```text
 FLUTTER (Dart)                  NATIVE HOST                       WEBVIEW (JavaScript)
 ─────────────────────           ─────────────────────────         ──────────────────────────

 ReactView ─────────────────────► platform view factory ─────────► attaches the WebView
     │                                                              to the view hierarchy
     ▼
 ReactViewController
     │  invoke() / emit()
     ▼
 JsonRpcEndpoint                  MethodChannel relay                React app
   validates JSON,  ── frame ──►  checks size on a      ── frame ──► window.__freReceive(frame)
   correlates ids,                background thread,
   enforces timeouts              posts on main thread
     ▲                                                                   │
     │                            WebMessageListener (Android)           │ window.__freNative
     └──────────── frame ──────── WKScriptMessageHandler (iOS) ◄─────────┘   .postMessage(frame)

 Bundle hosting:  Flutter assets ──► WebViewAssetLoader  ──► https://appassets.androidplatform.net/
                                 └─► WKURLSchemeHandler  ──► fre-app://bundle/
```

1. `ReactView` boots a JavaScript runtime: a WebView loads `index.html` from your asset directory.
2. The page's first message to the host marks it ready, and `initializeEngine` completes.
3. The platform view attaches the WebView, and the host sends `$/mount` with your route and props.
4. From then on, both sides exchange JSON-RPC requests, responses and notifications.

## Getting started

### 1. Bundle your React build as Flutter assets

Build the React app (`npm run build`) and copy its output, for example `build/` or `dist/`, into your Flutter project:

```text
your_flutter_app/
└── assets/
    └── react_app/
        ├── index.html
        └── assets/
            ├── index-3f9c1a.js
            └── index-8b2e44.css
```

Flutter does not include subdirectories of an asset directory, so list every directory:

```yaml
flutter:
  assets:
    - assets/react_app/
    - assets/react_app/assets/
```

The bundle is served from the root of an in-app origin, so build it with base path `/` or `./`. For Vite, set `base`; for Create React App, set `homepage`.

### 2. Connect the React app to the bridge

The host completes boot when the page sends its first message. Add this before your app's scripts, or adapt it into a React hook:

```js
// bridge.js: load it with <script src="./bridge.js"></script> at the top of <head>.
(function () {
  const native = window.__freNative;
  if (!native) return; // Running in a normal browser.

  const handlers = {
    getCart: async () => ({ items: 3, totalMinor: 12900 }),
  };

  const send = (message) => native.postMessage(JSON.stringify(message));

  window.__freReceive = async (frame) => {
    const message = JSON.parse(frame);
    if (message.method === '$/mount' || message.method === '$/updateProps') {
      window.dispatchEvent(new CustomEvent('fre:props', { detail: message.params.props }));
      return;
    }
    if (message.id === undefined) return; // Notification from Dart.
    const handler = handlers[message.method];
    if (!handler) {
      send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } });
      return;
    }
    try {
      send({ jsonrpc: '2.0', id: message.id, result: await handler(message.params) });
    } catch (error) {
      send({
        jsonrpc: '2.0',
        id: message.id,
        error: { code: -32000, message: String(error.message), data: { stack: String(error.stack) } },
      });
    }
  };

  // First frame: tells the host the bridge is ready.
  send({ jsonrpc: '2.0', method: 'hello', params: {} });
})();
```

To report events to Dart, send a notification: `send({ jsonrpc: '2.0', method: 'cartChanged', params: { items: 4 } })`.

### 3. Embed it in Flutter

```dart
import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';

class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key});

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  String _locale = 'en';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ReactView(
        configuration: ReactViewConfiguration(
          engine: const ReactEngineConfig(
            engine: ReactEngineKind.web,
            bundle: 'assets/react_app/',
          ),
          moduleName: '/checkout',
          initialProps: <String, Object?>{'locale': _locale},
        ),
        onViewCreated: (ReactViewController controller) async {
          controller.events(name: 'cartChanged').listen((ReactBridgeEvent event) {
            debugPrint('Cart changed: ${event.data}');
          });
          final Map<String, Object?> cart = await controller.invoke<Map<String, Object?>>('getCart');
          debugPrint('Cart: $cart');
        },
        onError: (ReactEmbedException error, StackTrace stackTrace) {
          debugPrint('React view failed: $error');
        },
      ),
      floatingActionButton: FloatingActionButton(
        // Changing initialProps re-renders the React root without remounting it.
        onPressed: () => setState(() => _locale = _locale == 'en' ? 'de' : 'en'),
        child: const Icon(Icons.translate),
      ),
    );
  }
}
```

A `ReactViewController` stays valid until its view is disposed or reconfigured. Calls after that throw `ReactRuntimeDisposedException`.

## API reference

### `ReactView`

| Property | Type | Description |
| --- | --- | --- |
| `configuration` | `ReactViewConfiguration` | What to render and how. Required. |
| `runtime` | `ReactRuntimeHandle?` | Shared runtime to render into. When null, the view boots and owns its own runtime. |
| `surfaceCache` | `ReactSurfaceCache?` | Cache used when `configuration.cacheKey` is set. Defaults to `ReactSurfaceCache.shared`. |
| `gestureRecognizers` | `Set<Factory<OneSequenceGestureRecognizer>>` | Gestures the platform view claims from Flutter's gesture arena. |
| `onViewCreated` | `ValueChanged<ReactViewController>?` | Called once per mounted surface with its controller. |
| `onError` | `ReactViewErrorCallback?` | Receives every error. When null, errors go to `FlutterError.reportError`. |
| `placeholderBuilder` | `WidgetBuilder?` | Shown while the runtime boots. |
| `errorBuilder` | `ReactViewErrorBuilder?` | Shown on failure; receives the error and a `retry` callback. |

### `ReactViewConfiguration`

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `engine` | `ReactEngineConfig` | Required | Runtime configuration. |
| `moduleName` | `String` | Required | Initial route or root component name, sent to JavaScript in `$/mount`. |
| `initialProps` | `Map<String, Object?>` | `{}` | Root props. Changes are pushed with `$/updateProps`, without remounting. |
| `cacheKey` | `String?` | `null` | Keeps the surface alive across unmounts under this key. |
| `androidComposition` | `AndroidCompositionMode` | `textureLayer` | `hybrid` for content with `SurfaceView` children. |
| `hitTestBehavior` | `PlatformViewHitTestBehavior` | `opaque` | Hit testing of the platform view. |

`ReactViewConfiguration.fromAttributes(Map<String, Object?>)` builds a configuration from loosely typed data, such as a remote manifest. It throws `ReactConfigurationException` on any missing or mistyped attribute.

### `ReactEngineConfig`

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `engine` | `ReactEngineKind` | Required | `ReactEngineKind.web`. |
| `bundle` | `String` | Required | Flutter asset directory containing `index.html`. |
| `bundleSha256` | `String?` | `null` | Expected SHA-256 of `index.html`; boot fails with `BUNDLE_INTEGRITY` on mismatch. |
| `requestTimeout` | `Duration` | 10 s | Default deadline for Dart-to-JavaScript calls. |
| `maxMessageBytes` | `int` | 1 MiB | Largest accepted frame, in UTF-8 bytes. |
| `enableDebugging` | `bool` | `false` | Enables Chrome DevTools / Safari Web Inspector for the WebView. |
| `contractVersion` | `String` | `'1.0.0'` | Bridge contract version exposed to JavaScript as `__FRE_BOOT__.contractVersion`. |

### `ReactViewController`

| Method | Returns | Description |
| --- | --- | --- |
| `invoke<T>(method, {params, timeout})` | `Future<T>` | Calls a JavaScript handler and casts its result to `T`. |
| `emit(name, [data])` | `Future<void>` | Sends an event (JSON-RPC notification) to JavaScript. |
| `events({name})` | `Stream<ReactBridgeEvent>` | Events from JavaScript, optionally filtered by name. |
| `registerHandler(method, handler)` | `ReactHandlerDisposer` | Serves JavaScript requests from Dart. Removed automatically on dispose. |
| `updateProps(props)` | `Future<void>` | Replaces the root props. |
| `runtime`, `viewId`, `isDisposed` | - | Runtime handle, platform view id and lifecycle state. |

### `FlutterReactEmbedPlatform`

Use the platform API directly to share one runtime between views, or to talk to a runtime without a view.

| Method | Description |
| --- | --- |
| `initializeEngine(config)` | Boots a runtime and completes once JavaScript is ready. |
| `disposeEngine(runtime)` | Releases a runtime. Idempotent. |
| `invoke(runtime, method, {params, timeout})` | Calls JavaScript. |
| `emit(runtime, name, {data})` | Sends an event to JavaScript. |
| `registerHandler(runtime, method, handler)` | Serves JavaScript requests. |
| `events(runtime, {name})` | JavaScript events. Events sent before the first listener subscribes are buffered for it. |
| `runtimeStates(runtime)` | Lifecycle changes: `initializing`, `ready`, `paused`, `crashed`, `disposed`. |
| `runtimeErrors(runtime)` | Uncaught JavaScript errors, flagged fatal or non-fatal. |
| `evictCachedSurface(cacheKey)` | Drops a retained surface. |

### Errors

All failures are subtypes of the sealed `ReactEmbedException`:

| Exception | Raised when |
| --- | --- |
| `ReactEngineInitializationException` | The bundle is missing or fails integrity, the WebView is unavailable, or boot times out. `code` holds the native reason. |
| `ReactEngineUnavailableException` | No native implementation is registered on this platform. |
| `ReactConfigurationException` | A configuration is invalid for the current platform. |
| `ReactJsRuntimeException` | JavaScript threw, or the renderer crashed. Carries `jsStack` and `isFatal`. |
| `ReactRpcException` | JavaScript answered with a JSON-RPC error. Carries `code` and `data`. |
| `ReactRpcTimeoutException` | No response before the deadline. JavaScript receives `$/cancelRequest`. |
| `ReactSerializationException` | A Dart value is not valid JSON for the bridge. `path` locates it, for example `$.items[2].date`. |
| `ReactRuntimeDisposedException` | The runtime was disposed or crashed while a call was pending. |
| `ReactProtocolException` | A peer sent a malformed message. |

## JavaScript contract

| Global or message | Direction | Purpose |
| --- | --- | --- |
| `window.__FRE_BOOT__` | Host to JS | `{runtimeId, contractVersion, transport, platform}`, defined before any page script runs. |
| `window.__freNative.postMessage(frame)` | JS to host | Sends a JSON-RPC frame (a string). |
| `window.__freReceive(frame)` | Host to JS | Defined by your app; receives JSON-RPC frames. Define it before sending the first frame. |
| `$/mount` | Host to JS | `{viewId, moduleName, props, cacheKey, reattached}` when a view attaches. |
| `$/updateProps` | Host to JS | `{viewId, props}` when `initialProps` change. |
| `$/unmount` | Host to JS | `{viewId}` or `{cacheKey}` when a surface is released. |
| `$/cancelRequest` | Host to JS | `{id}` when a Dart call timed out. |

Frames sent by Dart before the page's first message are queued and delivered once it arrives.

## Example

The [example app](https://github.com/Amarj234/flutter_react_embed/tree/main/packages/flutter_react_embed/example) embeds the open-source [CoreUI React admin dashboard](https://github.com/coreui/coreui-free-react-admin-template) next to an internal state view, with a live log of every message from JavaScript. Its `tool/setup_test_react.sh` script clones and builds the dashboard, installs it as assets, and pins its hash. On-device integration tests cover both surfaces on Android and iOS.

```sh
cd example
tool/setup_test_react.sh
flutter run
```

## Limitations

- One WebView document is shown in one view at a time; attaching a second view to the same runtime is reported as an error.
- On Android, every bundle is served from the same origin, so `localStorage` is shared between bundles.
- On iOS, the page origin is `fre-app://bundle`; remote APIs called by the page must allow it in their CORS policy.

## License

BSD 3-Clause. See [LICENSE](https://github.com/Amarj234/flutter_react_embed/blob/main/LICENSE).
