# flutter_react_embed

[![pub package](https://img.shields.io/pub/v/flutter_react_embed.svg)](https://pub.dev/packages/flutter_react_embed)
[![pub points](https://img.shields.io/pub/points/flutter_react_embed)](https://pub.dev/packages/flutter_react_embed/score)
[![license: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](https://github.com/Amarj234/flutter_react_embed/blob/main/LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-Amarj234-181717?logo=github)](https://github.com/Amarj234)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-amarj234-0A66C2?logo=linkedin)](https://www.linkedin.com/in/amarj234)

**Show a React web app inside your Flutter app, and let Dart and JavaScript talk to each other.**

Already have a React dashboard, checkout flow or admin page? Put it inside your Flutter app without rewriting it in Dart. The React build ships inside your app as Flutter assets and runs in a WebView. It is not loaded from the internet, and you don't need a local web server.

---

## Table of contents

1. [What can it do?](#what-can-it-do)
2. [Platform support](#platform-support)
3. [Before you start](#before-you-start)
4. [Quick start: from zero to a running app](#quick-start-from-zero-to-a-running-app)
5. [Talking between Dart and React](#talking-between-dart-and-react)
6. [Using the bridge from React components](#using-the-bridge-from-react-components)
7. [Common recipes](#common-recipes)
8. [React Native engine](#react-native-engine)
9. [Debugging](#debugging)
10. [Troubleshooting](#troubleshooting)
11. [FAQ](#faq)
12. [How it works](#how-it-works)
13. [API reference](#api-reference)
14. [JavaScript contract](#javascript-contract)
15. [Example app](#example-app)
16. [Limitations](#limitations)
17. [Author](#author)
18. [License](#license)

---

## What can it do?

- **`ReactView` widget**: shows your React app like any other Flutter widget. One widget handles both React web builds (`ReactEmbedType.web`) and React Native apps (`ReactEmbedType.native`).
- **Dart → JavaScript calls**: call a JavaScript function from Dart and `await` its result.
- **JavaScript → Dart calls**: call a Dart function from JavaScript and get its result back.
- **Events**: send events from React to Flutter (for example "user clicked buy"), and from Flutter to React.
- **Props**: pass data from Flutter to React. When your Flutter state changes, React gets the new props without reloading.
- **Integrity pinning** (optional): give the SHA-256 hash of `index.html`, and the app refuses to load a modified or outdated bundle.
- **Surface cache**: keep a React app alive while the user is on another screen, so it shows instantly when they come back.
- **Error handling**: loading failures and JavaScript crashes become typed Dart exceptions. You can show an error screen with a "Retry" button.
- **No memory leaks**: WebViews are released when they leave the screen and fully destroyed on dispose.

## Platform support

| Platform | Engine | Status |
| --- | --- | --- |
| Android | Android System WebView (API 24+) | ✅ Supported |
| iOS | WKWebView (iOS 15+) | ✅ Supported |
| Android | React Native 0.82+ (New Architecture), opt-in | ✅ Supported since 1.1.0 |
| iOS | React Native 0.82+ (New Architecture), opt-in | ✅ Supported since 1.1.1 |
| Web, macOS, Windows, Linux | - | ❌ Not supported yet |

Requires **Flutter 3.47 or later**.

---

## Before you start

You need:

| Tool | Why | Check it with |
| --- | --- | --- |
| Flutter 3.47+ | To build the Flutter app | `flutter --version` |
| Node.js 20+ and npm | To build the React app | `node --version` |
| Android Studio or Xcode | To run on a device or emulator | `flutter doctor` |

**No Android manifest or iOS `Info.plist` changes are required.** On Android, add the `INTERNET` permission only if your React app calls remote APIs:

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<uses-permission android:name="android.permission.INTERNET" />
```

---

## Quick start: from zero to a running app

This walkthrough creates a new Flutter app and a new React app, and shows the React app inside Flutter. It takes about 10 minutes. If you already have a React app, skip step 2.

The final folder layout looks like this:

```text
projects/
├── my_flutter_app/        ← Flutter app
│   ├── assets/
│   │   └── react_app/     ← the React build is copied here
│   ├── lib/main.dart
│   └── pubspec.yaml
└── my_react_app/          ← React app (Vite)
    ├── public/bridge.js
    ├── index.html
    └── vite.config.js
```

### Step 1: Create the Flutter app and add the package

```sh
flutter create my_flutter_app
cd my_flutter_app
flutter pub add flutter_react_embed
cd ..
```

### Step 2: Create a React app

We use [Vite](https://vite.dev/), but any React setup that produces static files (`index.html` + JS + CSS) works.

```sh
npm create vite@latest my_react_app -- --template react
cd my_react_app
npm install
```

### Step 3: Make the React build work offline

The React app is loaded from inside your Flutter app, not from a website root, so its files must use **relative paths**. Open `vite.config.js` and add `base: './'`:

```js
// my_react_app/vite.config.js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  base: './', // ← important: use relative paths
})
```

> Using Create React App instead? Add `"homepage": "."` to `package.json`.

### Step 4: Add the bridge script to React

The bridge script is the small piece of JavaScript that lets React talk to Flutter. Create `my_react_app/public/bridge.js` and paste this in. You don't need to change anything in it.

```js
// my_react_app/public/bridge.js
// Connects this page to flutter_react_embed. Does nothing in a normal browser.
(function () {
  var native = window.__freNative;
  var pending = {};   // JS → Dart calls waiting for an answer
  var handlers = {};  // functions Dart can call
  var nextId = 1;

  function send(message) {
    if (native) native.postMessage(JSON.stringify(message));
  }

  window.FlutterBridge = {
    // True when running inside the Flutter app.
    isAvailable: !!native,

    // Latest props sent by Flutter (initialProps in Dart).
    props: {},

    // Let Dart call a JavaScript function: controller.invoke('name', params: ...)
    handle: function (method, fn) { handlers[method] = fn; },

    // Send an event to Dart: controller.events(name: 'name')
    emit: function (name, data) {
      send({ jsonrpc: '2.0', method: name, params: data === undefined ? {} : data });
    },

    // Call a Dart function and get a Promise: controller.registerHandler('name', ...)
    call: function (method, params) {
      if (!native) return Promise.reject(new Error('Not running inside Flutter'));
      var id = 'js-' + nextId++;
      return new Promise(function (resolve, reject) {
        pending[id] = { resolve: resolve, reject: reject };
        send({ jsonrpc: '2.0', id: id, method: method, params: params === undefined ? {} : params });
      });
    },
  };

  if (!native) return; // Opened in a normal browser: nothing else to do.

  window.__freReceive = async function (frame) {
    var message = JSON.parse(frame);
    var params = message.params || {};

    // Flutter sent new props.
    if (message.method === '$/mount' || message.method === '$/updateProps') {
      window.FlutterBridge.props = params.props || {};
      window.dispatchEvent(new CustomEvent('flutter:props', { detail: window.FlutterBridge.props }));
      return;
    }
    if (message.method === '$/unmount' || message.method === '$/cancelRequest') return;

    // Dart answered one of our FlutterBridge.call(...) calls.
    if (message.method === undefined && pending[message.id]) {
      var p = pending[message.id];
      delete pending[message.id];
      if (message.error) p.reject(Object.assign(new Error(message.error.message), message.error));
      else p.resolve(message.result);
      return;
    }

    // Dart sent an event: controller.emit('name', data)
    if (message.id === undefined || message.id === null) {
      window.dispatchEvent(new CustomEvent('flutter:event', { detail: { name: message.method, data: params } }));
      return;
    }

    // Dart called a JavaScript function: controller.invoke('name')
    var handler = handlers[message.method];
    if (!handler) {
      send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'No JS handler for ' + message.method } });
      return;
    }
    try {
      var result = await handler(message.params);
      send({ jsonrpc: '2.0', id: message.id, result: result === undefined ? null : result });
    } catch (error) {
      send({
        jsonrpc: '2.0',
        id: message.id,
        error: { code: -32000, message: String(error && error.message || error), data: { stack: String(error && error.stack || '') } },
      });
    }
  };

  // First message: tells Flutter the page is ready. Required!
  send({ jsonrpc: '2.0', method: 'hello', params: {} });
})();
```

Load it **first** in `my_react_app/index.html`, inside `<head>`, before any other script:

```html
<head>
  <meta charset="UTF-8" />
  <script src="./bridge.js"></script>  <!-- ← add this line -->
  <title>My React App</title>
</head>
```

> **Why "first"?** Flutter waits for the page's first message (`hello`) before showing it. If the bridge never loads, the view times out with an error.

### Step 5: Build React and copy it into Flutter

```sh
# inside my_react_app/
npm run build

# copy the build output (dist/) into the Flutter app
mkdir -p ../my_flutter_app/assets/react_app
cp -R dist/. ../my_flutter_app/assets/react_app/
```

You should now have:

```text
my_flutter_app/assets/react_app/
├── index.html
├── bridge.js
├── vite.svg
└── assets/
    ├── index-3f9c1a.js
    └── index-8b2e44.css
```

> Repeat this step every time you change the React code.

### Step 6: Register the assets in `pubspec.yaml`

Flutter does **not** include sub-folders automatically, so list every folder that has files in it:

```yaml
# my_flutter_app/pubspec.yaml
flutter:
  uses-material-design: true
  assets:
    - assets/react_app/
    - assets/react_app/assets/
```

> If your build has more folders (for example `assets/react_app/assets/fonts/`), add a line for each one.

### Step 7: Show it in Flutter

Replace `my_flutter_app/lib/main.dart` with:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';

void main() => runApp(const MaterialApp(home: ReactPage()));

class ReactPage extends StatelessWidget {
  const ReactPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('React inside Flutter')),
      body: ReactView(
        configuration: const ReactViewConfiguration(
          engine: ReactEngineConfig(
            engine: ReactEngineKind.web,
            bundle: 'assets/react_app/', // folder from step 5
          ),
          moduleName: '/', // the route to open
        ),
        // Shown while the React app loads.
        placeholderBuilder: (context) => const Center(child: CircularProgressIndicator()),
        // Shown if something goes wrong. `retry` reloads the app.
        errorBuilder: (context, error, retry) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load: $error', textAlign: TextAlign.center),
              ElevatedButton(onPressed: retry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
```

### Step 8: Run it

```sh
cd my_flutter_app
flutter run
```

🎉 You should see your React app inside the Flutter screen.

If you see an error instead, check [Troubleshooting](#troubleshooting).

---

## Talking between Dart and React

Everything goes through a `ReactViewController`. You get it from `onViewCreated`:

```dart
ReactView(
  configuration: ...,
  onViewCreated: (ReactViewController controller) {
    // Use controller here, or save it in your State to use later.
  },
)
```

Here are the four directions, with the Dart side and the matching JavaScript side (using `window.FlutterBridge` from step 4).

### 1. Flutter → React: pass data as props

**Dart:**

```dart
ReactViewConfiguration(
  engine: const ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/react_app/'),
  moduleName: '/',
  initialProps: {'userName': 'Alex', 'theme': 'dark'},
)
```

When you rebuild the widget with different `initialProps` (for example after `setState`), React receives the new props automatically. The page is **not** reloaded.

You can also push props from the controller: `await controller.updateProps({'theme': 'light'});`

**JavaScript:**

```js
console.log(window.FlutterBridge.props.userName); // 'Alex'

window.addEventListener('flutter:props', (e) => {
  console.log('New props:', e.detail);
});
```

### 2. Dart → JavaScript: call a function and get a result

**JavaScript** (register the function):

```js
window.FlutterBridge.handle('getCart', async (params) => {
  return { items: 3, total: 129.0 };
});
```

**Dart** (call it):

```dart
final cart = await controller.invoke<Map<String, Object?>>('getCart');
print(cart['items']); // 3

// With parameters and a custom timeout:
final user = await controller.invoke<Map<String, Object?>>(
  'getUser',
  params: {'id': 42},
  timeout: const Duration(seconds: 5),
);
```

If the JavaScript function throws, `invoke` throws a `ReactRpcException` in Dart. If it takes too long, it throws `ReactRpcTimeoutException`.

### 3. JavaScript → Dart: call a Dart function

**Dart** (register the function):

```dart
controller.registerHandler('getAuthToken', (params) async {
  return {'token': await myAuthService.token()};
});
```

**JavaScript** (call it):

```js
const { token } = await window.FlutterBridge.call('getAuthToken');
```

Handlers are removed automatically when the view is disposed. To remove one earlier, call the function `registerHandler` returns.

### 4. Events (fire and forget)

**React → Flutter:**

```js
window.FlutterBridge.emit('cartChanged', { items: 4 });
```

```dart
controller.events(name: 'cartChanged').listen((ReactBridgeEvent event) {
  print('Cart changed: ${event.data}'); // {items: 4}
});

// Or listen to every event:
controller.events().listen((event) => print('${event.name}: ${event.data}'));
```

**Flutter → React:**

```dart
await controller.emit('themeChanged', {'dark': true});
```

```js
window.addEventListener('flutter:event', (e) => {
  if (e.detail.name === 'themeChanged') console.log(e.detail.data); // {dark: true}
});
```

### What data can I send?

Anything JSON can hold: `null`, `bool`, `int`, `double`, `String`, `List`, and `Map<String, ...>`.

Not allowed (you get a `ReactSerializationException` with the exact location, like `$.items[2].date`):

- `DateTime`: send `date.toIso8601String()` instead.
- Your own classes: send `myObject.toJson()` instead.
- `double.nan` / `double.infinity`.
- Integers bigger than 2^53 (JavaScript can't represent them exactly). Send them as strings.
- Maps with non-`String` keys.

---

## Using the bridge from React components

Put this hook in `src/useFlutter.js`:

```js
// src/useFlutter.js
import { useEffect, useState } from 'react';

const bridge = window.FlutterBridge;

/** Current props from Flutter. Re-renders when Flutter changes them. */
export function useFlutterProps() {
  const [props, setProps] = useState(bridge?.props ?? {});
  useEffect(() => {
    const onProps = (e) => setProps(e.detail);
    window.addEventListener('flutter:props', onProps);
    setProps(bridge?.props ?? {}); // in case props arrived before this component mounted
    return () => window.removeEventListener('flutter:props', onProps);
  }, []);
  return props;
}

/** Runs `callback(data)` whenever Flutter calls controller.emit(name, data). */
export function useFlutterEvent(name, callback) {
  useEffect(() => {
    const onEvent = (e) => { if (e.detail.name === name) callback(e.detail.data); };
    window.addEventListener('flutter:event', onEvent);
    return () => window.removeEventListener('flutter:event', onEvent);
  }, [name, callback]);
}

export const isInFlutter = !!bridge?.isAvailable;
export const emitToFlutter = (name, data) => bridge?.emit(name, data);
export const callFlutter = (method, params) => bridge.call(method, params);
```

Use it in a component:

```jsx
// src/App.jsx
import { useFlutterProps, emitToFlutter, callFlutter, isInFlutter } from './useFlutter';

export default function App() {
  const { userName = 'guest', theme = 'light' } = useFlutterProps();

  async function handleBuy() {
    emitToFlutter('buyClicked', { productId: 'abc' });
    const { token } = await callFlutter('getAuthToken');
    console.log('Token from Flutter:', token);
  }

  return (
    <div className={theme}>
      <h1>Hello, {userName}!</h1>
      <p>{isInFlutter ? 'Running inside Flutter' : 'Running in a browser'}</p>
      <button onClick={handleBuy}>Buy</button>
    </div>
  );
}
```

> **Tip:** Because `bridge.js` does nothing in a normal browser, you can still develop with `npm run dev` in Chrome. Use `isInFlutter` to fake data while developing.

---

## Common recipes

### A complete page with state, events and calls

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
  ReactViewController? _controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Checkout'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final cart = await _controller?.invoke<Map<String, Object?>>('getCart');
              debugPrint('Cart: $cart');
            },
          ),
        ],
      ),
      body: ReactView(
        configuration: ReactViewConfiguration(
          engine: const ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/react_app/'),
          moduleName: '/checkout',
          initialProps: {'locale': _locale},
        ),
        onViewCreated: (controller) {
          _controller = controller;
          controller.events(name: 'cartChanged').listen((event) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cart: ${event.data}')));
          });
          controller.registerHandler('getLocale', (_) => _locale);
        },
        onError: (error, stackTrace) => debugPrint('React view failed: $error'),
      ),
      floatingActionButton: FloatingActionButton(
        // Changing initialProps updates React without reloading it.
        onPressed: () => setState(() => _locale = _locale == 'en' ? 'de' : 'en'),
        child: const Icon(Icons.translate),
      ),
    );
  }
}
```

### Open a specific page (routing)

`moduleName` is sent to React as the starting route. Read it in the `$/mount` message, or simply use the hash router so the URL drives the page:

```jsx
// React: use HashRouter (recommended inside apps)
import { HashRouter, Routes, Route } from 'react-router-dom';
```

```dart
// Dart: open the settings page
moduleName: '#/settings',
```

> **Use `HashRouter`, not `BrowserRouter`.** The app is served from files, so a reload on `/settings` would look for a file called `settings`. Hash URLs (`#/settings`) always load `index.html`.

### Keep the React app alive when leaving the screen

Without a cache, leaving the screen destroys the React app, and coming back loads it again. Add a `cacheKey` to keep it in memory:

```dart
ReactViewConfiguration(
  engine: const ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/react_app/'),
  moduleName: '/',
  cacheKey: 'dashboard', // any unique name
)
```

By default, up to 2 surfaces are kept (least recently used ones are released first). To change that, pass your own cache:

```dart
final myCache = ReactSurfaceCache(maxRetainedSurfaces: 4);

ReactView(configuration: ..., surfaceCache: myCache)
```

To free one manually: `await myCache.evict('dashboard')` or `FlutterReactEmbedPlatform.instance.evictCachedSurface('dashboard')`.

### Make sure nobody changed the bundle (integrity check)

Get the SHA-256 of your built `index.html`:

```sh
shasum -a 256 assets/react_app/index.html     # macOS
sha256sum assets/react_app/index.html         # Linux
```

Pass it to the engine:

```dart
const ReactEngineConfig(
  engine: ReactEngineKind.web,
  bundle: 'assets/react_app/',
  bundleSha256: 'paste-the-64-character-hash-here',
)
```

If the file doesn't match, loading fails with `ReactEngineInitializationException` (code `BUNDLE_INTEGRITY`). **Remember to update the hash every time you rebuild React.**

### Scrolling inside the React app (inside a scrollable Flutter page)

If the `ReactView` is inside a `ListView` or another scrollable widget, Flutter may "steal" the scroll gestures. Give them to the web view:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

ReactView(
  configuration: ...,
  gestureRecognizers: {
    Factory<VerticalDragGestureRecognizer>(() => VerticalDragGestureRecognizer()),
  },
)
```

### Load the configuration from JSON (for example from your server)

```dart
final config = ReactViewConfiguration.fromAttributes({
  'engine': 'web',
  'bundle': 'assets/react_app/',
  'moduleName': '/',
  'initialProps': {'userName': 'Alex'},
  // Optional: 'bundleSha256', 'cacheKey', 'enableDebugging', 'requestTimeoutMs', 'androidComposition'
});
```

It throws `ReactConfigurationException` if a field is missing or has the wrong type.

### Handle errors

```dart
try {
  await controller.invoke('saveForm', params: form);
} on ReactRpcTimeoutException {
  showMessage('React did not answer in time');
} on ReactRpcException catch (e) {
  showMessage('React returned an error: ${e.message}');
} on ReactRuntimeDisposedException {
  // The view was closed. Nothing to do.
} on ReactEmbedException catch (e) {
  showMessage('Something went wrong: $e');
}
```

See the [full list of errors](#errors).

---

## React Native engine

Since 1.1.0, `ReactView` can also show screens from a React Native app. Pick the framework with the configuration's type:

```dart
// React web build (unchanged from 1.0)
ReactView(configuration: ReactViewConfiguration.web(assetPath: 'assets/react_app/'));

// React Native app
ReactView(
  configuration: ReactViewConfiguration.native(
    bundleName: 'assets/rn/index.android.bundle', // Android
    iosBundleName: 'assets/rn/main.jsbundle',     // iOS
    componentName: 'Checkout',                    // AppRegistry.registerComponent name
    initialProps: {'total': 42},
  ),
);
```

`ReactViewConfiguration.web(...)` and `ReactViewConfiguration.native(...)` only build a `ReactViewConfiguration`. The existing constructor with `ReactEngineKind.web` / `ReactEngineKind.reactNative` still works, and `ReactEmbedType.web` / `ReactEmbedType.native` map one to one onto those engines.

React Native is **opt-in**. Web-only apps do not change and do not ship any React Native code. To enable it, your Flutter app must already build React Native (New Architecture, 0.82 or later) and then:

### 1. Build the bundles into Flutter assets

```sh
npx react-native bundle --platform android --dev false --entry-file index.js \
  --bundle-output ../my_flutter_app/assets/rn/index.android.bundle
npx react-native bundle --platform ios --dev false --entry-file index.js \
  --bundle-output ../my_flutter_app/assets/rn/main.jsbundle
```

```yaml
flutter:
  assets:
    - assets/rn/
```

### 2. Android

Your Android app must apply React Native's Gradle plugin. Adding the `react-android` library alone is **not enough**: the Gradle plugin builds `libappmodules.so`, which registers React Native's core modules. Without it, every bundle crashes on load. The plugin detects this and fails with `UNSUPPORTED_ENGINE` instead.

The setup below is the one the example app uses and is tested on Android (`example/tool/run_local_test.sh`). The example applies it only when `FRE_REACT_NATIVE=1`; your app applies it always. It assumes `package.json` and `node_modules` sit in your Flutter app's root, next to `android/`.

**`react-native.config.js`** (next to `package.json`). This tells the React Native CLI where your Android app is:

```js
module.exports = {
  project: {
    android: { sourceDir: './android', packageName: 'com.example.myapp' }, // your app's namespace
  },
};
```

**`android/settings.gradle.kts`**, after `include(":app")`. This does what React Native's settings plugin does. That plugin can't be used as-is in a Flutter app: Flutter moves the root build directory to `../build`, and the React Native app plugin reads `autolinking.json` from there.

```kotlin
includeBuild("../node_modules/@react-native/gradle-plugin")

val autolinkingConfig = providers.exec {
    commandLine("npx", "@react-native-community/cli", "config")
    workingDir = file("..")
}.standardOutput.asText.get()
file("../build/generated/autolinking/autolinking.json").apply {
    parentFile.mkdirs()
    writeText(autolinkingConfig)
}

// Include autolinked native libraries (same naming as React Native's settings plugin).
@Suppress("UNCHECKED_CAST")
val dependencies = (groovy.json.JsonSlurper().parseText(autolinkingConfig) as Map<String, Any?>)["dependencies"]
    as Map<String, Map<String, Any?>>? ?: emptyMap()
for ((name, dependency) in dependencies) {
    @Suppress("UNCHECKED_CAST")
    val android = (dependency["platforms"] as Map<String, Any?>?)?.get("android") as Map<String, Any?>?
    val sourceDir = android?.get("sourceDir") as String? ?: continue
    if (android["isPureCxxDependency"] == true) continue
    val path = ":" + name.replace(Regex("[~*!'()]+"), "_").replace(Regex("^@([\\w-.]+)/"), "$1_")
    include(path)
    project(path).projectDir = file(sourceDir)
}
```

**`android/build.gradle.kts`**, at the top:

```kotlin
buildscript {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
    dependencies { classpath("com.facebook.react:react-native-gradle-plugin") }
}
```

**`android/app/build.gradle.kts`**, at the end:

```kotlin
apply(plugin = "com.facebook.react")
val react = extensions.getByName("react")
fun <T : Any> reactProperty(name: String): T {
    @Suppress("UNCHECKED_CAST")
    return react.withGroovyBuilder { getProperty(name) } as T
}
reactProperty<DirectoryProperty>("root").set(rootProject.file(".."))
// The bundle ships as a Flutter asset, so React Native never bundles it itself.
reactProperty<ListProperty<String>>("debuggableVariants").set(listOf("debug", "profile", "release"))
react.withGroovyBuilder { "autolinkLibrariesWithApp"() }

dependencies {
    "implementation"("com.facebook.react:react-android") // version pinned by the plugin
    "implementation"("com.facebook.react:hermes-android")
}
```

**`android/gradle.properties`**:

```properties
newArchEnabled=true
hermesEnabled=true
# Flutter already pins Java 17; React Native's toolchain alignment fails under AGP 9.
react.internal.disableJavaVersionAlignment=true
```

The plugin creates one `ReactHost` the first time it is needed, using the entry point and `PackageList` that React Native's Gradle plugin generates. It loads `bundleName` from the Flutter assets and forwards the Activity's resume, pause and destroy to the host.

If your `Application` already implements `ReactApplication`, the plugin uses **your** `reactHost` and its bundle. Add the bridge package to its package list:

```kotlin
override val reactHost: ReactHost by lazy {
    getDefaultReactHost(applicationContext, PackageList(this).packages + FlutterReactEmbedPackage())
}
```

### 3. iOS

React Native 0.87 needs iOS 15.1 or later. Set **Minimum Deployments** of the `Runner` target to 15.1 in Xcode (`IPHONEOS_DEPLOYMENT_TARGET = 15.1`).

In `ios/Podfile`, combine Flutter's setup with React Native's and add the plugin's `ReactNative` subspec. These are the parts to add to Flutter's generated Podfile:

```ruby
# At the top: resolve react_native_pods.rb with node.
require Pod::Executable.execute_command('node', ['-p',
  'require.resolve(
    "react-native/scripts/react_native_pods.rb",
    {paths: [process.argv[1]]},
  )', __dir__]).strip

platform :ios, min_ios_version_supported
prepare_react_native_project!

# ...Flutter's generated flutter_root / podhelper / flutter_ios_podfile_setup...

target 'Runner' do
  use_frameworks! :linkage => :static
  config = use_native_modules!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  use_react_native!(
    :path => config[:reactNativePath],
    :app_path => "#{Pod::Config.instance.installation_root}/.."
  )
  pod 'flutter_react_embed_ios/ReactNative', :path => '.symlinks/plugins/flutter_react_embed_ios/ios'

  # ...Flutter's RunnerTests target...
end

post_install do |installer|
  react_native_post_install(installer, '../node_modules/react-native', :mac_catalyst_enabled => false)
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
```

Next to `package.json`, `react-native.config.js` also needs `ios: { sourceDir: './ios' }` under `project`.

The plugin creates one `RCTReactNativeFactory` that loads `iosBundleName` from the Flutter assets. To use your own factory instead, call this before the first native `ReactView` mounts:

```swift
import flutter_react_embed_ios

FlutterReactEmbedReactNativeHost.use(myFactory)
```

The React Native engine needs CocoaPods. Swift Package Manager builds of the plugin include the web engine only.

### 4. Connect your React Native components

Copy [`example/tool/fre-bridge-native.js`](https://github.com/Amarj234/flutter_react_embed/blob/main/packages/flutter_react_embed/example/tool/fre-bridge-native.js) into your React Native project:

```jsx
import { useFlutterBridge } from './fre-bridge-native';

export default function Checkout(props) {
  const bridge = useFlutterBridge(props.__fre, {
    getTotal: () => ({ total: props.total }),            // Dart: controller.invoke('getTotal')
  });
  return <Button title="Pay" onPress={() => bridge.emit('paid', { total: props.total })} />;
}
AppRegistry.registerComponent('Checkout', () => Checkout);
```

`invoke`, `emit`, `events`, `registerHandler` and `updateProps` on `ReactViewController` work the same way as with the web engine. From React Native, call a Dart handler registered with `registerHandler` with `await bridge.call('method', params)`. Props updates re-render the root component natively; your code doesn't need to handle them.

### How it differs from the web engine

- All React Native runtimes share one JavaScript instance (one bundle per app process). They are kept apart by `props.__fre.runtimeId`.
- One runtime can show **several** views at once.
- The React Native host stays loaded after its last view closes, because starting it again costs more than keeping it. Views, retained surfaces and Activity references are released.
- On iOS, fatal JavaScript errors are handled by React Native itself (red box in debug builds) and are not reported to Dart. On Android they are reported to Dart when the plugin created the host.

---

## Debugging

Turn on the browser developer tools for the WebView:

```dart
ReactEngineConfig(
  engine: ReactEngineKind.web,
  bundle: 'assets/react_app/',
  enableDebugging: true, // ← turn off in release builds
)
```

You can use `kDebugMode` from `package:flutter/foundation.dart` so it's only on in debug: `enableDebugging: kDebugMode`.

Then:

- **Android:** open Chrome on your computer, go to `chrome://inspect`, and click **inspect** under your app.
- **iOS:** open Safari on your Mac → **Settings → Advanced → Show features for web developers**. Then **Develop → [your device or simulator] → your page**.

You get the console, network tab, elements and breakpoints, just like on a website.

---

## Troubleshooting

| Problem | Likely cause and fix |
| --- | --- |
| **Blank white screen** | Asset paths are absolute. Set `base: './'` in `vite.config.js` (or `"homepage": "."` for CRA), rebuild, and copy again. |
| **Error: boot timed out / view never loads** | The page never sent its first message. Check that `bridge.js` is in the build folder and loaded in `<head>` **before** other scripts. |
| **`Unable to load asset` or 404 for a JS/CSS file** | A folder is missing in `pubspec.yaml`. List **every** sub-folder under `assets/react_app/`. Then run `flutter clean` and `flutter run`. |
| **Old version of React still shows** | You forgot to copy the new build, or Flutter cached the assets. Copy again, then do a full restart (not hot reload). |
| **`BUNDLE_INTEGRITY` error** | You rebuilt React but didn't update `bundleSha256`. Compute the new hash and paste it in. |
| **`MissingPluginException` / `ReactEngineUnavailableException`** | You're running on an unsupported platform (web or desktop), or you hot reloaded right after adding the package. Stop the app and run `flutter run` again on Android or iOS. |
| **`ReactRpcException: No JS handler for ...`** | You called `invoke('x')` but React never called `FlutterBridge.handle('x', ...)`. Check the name (it is case-sensitive). |
| **Remote API calls fail (CORS) on iOS** | On iOS the page's origin is `fre-app://bundle`. Your API server must allow that origin. |
| **Remote API calls fail on Android** | Add the `INTERNET` permission (see [Before you start](#before-you-start)). |
| **Page breaks after refreshing a route** | Use `HashRouter` instead of `BrowserRouter`. |
| **`ReactSerializationException`** | You sent something that isn't JSON (a `DateTime`, a class, `NaN`). The error message shows where it is. See [What data can I send?](#what-data-can-i-send). |

Still stuck? [Open an issue](https://github.com/Amarj234/flutter_react_embed/issues) with your Flutter version (`flutter --version`), platform, and the error message.

---

## FAQ

**Does it work with Next.js, Angular, Vue or plain HTML?**
Yes, as long as the build is a static site (`index.html` + JS + CSS) that loads the bridge script. For Next.js, use static export (`output: 'export'`) and make sure asset URLs are relative. The package name says React, but anything that runs in a browser works.

**Does my React app need internet?**
No. The files are inside your Flutter app. Internet is only needed if your React code calls remote APIs.

**Can I load a React app from a URL instead?**
Not currently. Bundles are loaded from Flutter assets, which makes them fast, offline-ready and safe from tampering.

**Can I show two `ReactView`s at the same time?**
Yes, as long as each one has its own runtime (the default). One runtime can only be shown in one view at a time.

**Does it support React Native?**
Yes, since 1.1.0. It's opt-in; see [React Native engine](#react-native-engine). If the app doesn't include React Native, a native configuration fails with `UNSUPPORTED_ENGINE` and a message that explains what to add.

**Is `localStorage` supported?**
Yes. On Android, all bundles share the same origin, so they also share `localStorage`.

**How big is the overhead?**
Each runtime is one system WebView. Messages are plain JSON strings that native code passes along without re-encoding.

---

## How it works

Dart is **not** compiled to JavaScript. Dart and JavaScript run separately and send each other [JSON-RPC 2.0](https://www.jsonrpc.org/specification) messages. The native code (Kotlin/Swift) passes them along.

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

1. `ReactView` starts a WebView that loads `index.html` from your asset folder.
2. The page's first message (`hello`) tells Flutter it is ready.
3. Flutter attaches the WebView to the screen and sends `$/mount` with your route and props.
4. From then on, both sides send requests, responses and events to each other.

---

## API reference

### `ReactView`

| Property | Type | Description |
| --- | --- | --- |
| `configuration` | `ReactViewConfiguration` | What to show and how. Required. |
| `runtime` | `ReactRuntimeHandle?` | Shared runtime to render into. When null, the view starts and owns its own runtime. |
| `surfaceCache` | `ReactSurfaceCache?` | Cache used when `configuration.cacheKey` is set. Defaults to `ReactSurfaceCache.shared`. |
| `gestureRecognizers` | `Set<Factory<OneSequenceGestureRecognizer>>` | Gestures the web view takes from Flutter. |
| `onViewCreated` | `ValueChanged<ReactViewController>?` | Called once per mounted surface with its controller. |
| `onError` | `ReactViewErrorCallback?` | Receives every error. When null, errors go to `FlutterError.reportError`. |
| `placeholderBuilder` | `WidgetBuilder?` | Shown while loading. |
| `errorBuilder` | `ReactViewErrorBuilder?` | Shown on failure; receives the error and a `retry` callback. |

### `ReactViewConfiguration`

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `engine` | `ReactEngineConfig` | Required | Runtime configuration. |
| `moduleName` | `String` | Required | Starting route or component name, sent to JavaScript in `$/mount`. |
| `initialProps` | `Map<String, Object?>` | `{}` | Root props. Changes are sent with `$/updateProps`, without reloading. |
| `cacheKey` | `String?` | `null` | Keeps the surface alive after it leaves the screen, under this key. |
| `androidComposition` | `AndroidCompositionMode` | `textureLayer` | Use `hybrid` if your page has video or other `SurfaceView` content. |
| `hitTestBehavior` | `PlatformViewHitTestBehavior` | `opaque` | Hit testing of the platform view. |

| `type` (getter) | `ReactEmbedType` | - | `web` or `native`, derived from `engine`. |

Shortcuts: `ReactViewConfiguration.web(assetPath:, route:, ...)` and `ReactViewConfiguration.native(bundleName:, iosBundleName:, componentName:, initialProps:, ...)`.

`ReactViewConfiguration.fromAttributes(Map<String, Object?>)` builds a configuration from JSON-like data. Besides `engine`, `bundle` and `moduleName`, it accepts `type` (`web` | `native`), `bundleName` and `componentName`. It throws `ReactConfigurationException` on any missing, mistyped or conflicting field.

### `ReactEngineConfig`

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `engine` | `ReactEngineKind` | Required | `ReactEngineKind.web` or `ReactEngineKind.reactNative`. |
| `bundle` | `String` | Required | Web: Flutter asset folder that contains `index.html`. React Native: the bundle file (`index.android.bundle` / `main.jsbundle`). |
| `bundleSha256` | `String?` | `null` | Expected SHA-256 of `index.html` (web) or of the bundle file (React Native); loading fails with `BUNDLE_INTEGRITY` if it differs. |
| `requestTimeout` | `Duration` | 10 s | Default time limit for Dart → JavaScript calls. |
| `maxMessageBytes` | `int` | 1 MiB | Largest accepted message, in UTF-8 bytes. |
| `enableDebugging` | `bool` | `false` | Enables Chrome DevTools / Safari Web Inspector. |
| `contractVersion` | `String` | `'1.0.0'` | Bridge version, available in JavaScript as `__FRE_BOOT__.contractVersion`. |

### `ReactViewController`

| Method | Returns | Description |
| --- | --- | --- |
| `invoke<T>(method, {params, timeout})` | `Future<T>` | Calls a JavaScript handler and casts its result to `T`. |
| `emit(name, [data])` | `Future<void>` | Sends an event to JavaScript. |
| `events({name})` | `Stream<ReactBridgeEvent>` | Events from JavaScript, optionally filtered by name. |
| `registerHandler(method, handler)` | `ReactHandlerDisposer` | Lets JavaScript call Dart. Removed automatically on dispose. |
| `updateProps(props)` | `Future<void>` | Replaces the root props. |
| `runtime`, `viewId`, `isDisposed` | - | Runtime handle, platform view id and lifecycle state. |

A controller is valid until its view is disposed or reconfigured. Calls after that throw `ReactRuntimeDisposedException`.

### `FlutterReactEmbedPlatform`

Advanced: use the platform API directly to share one runtime between views, or to talk to a runtime without showing it. Access it with `FlutterReactEmbedPlatform.instance`.

| Method | Description |
| --- | --- |
| `initializeEngine(config)` | Starts a runtime and completes once JavaScript is ready. |
| `disposeEngine(runtime)` | Releases a runtime. Safe to call more than once. |
| `invoke(runtime, method, {params, timeout})` | Calls JavaScript. |
| `emit(runtime, name, {data})` | Sends an event to JavaScript. |
| `registerHandler(runtime, method, handler)` | Lets JavaScript call Dart. |
| `events(runtime, {name})` | JavaScript events. Events sent before the first listener subscribes are buffered for it. |
| `runtimeStates(runtime)` | Lifecycle changes: `initializing`, `ready`, `paused`, `crashed`, `disposed`. |
| `runtimeErrors(runtime)` | Uncaught JavaScript errors, flagged fatal or non-fatal. |
| `evictCachedSurface(cacheKey)` | Drops a cached surface. |

### Errors

All errors extend the sealed class `ReactEmbedException`, so you can catch them all with `on ReactEmbedException`.

| Exception | Thrown when |
| --- | --- |
| `ReactEngineInitializationException` | The bundle is missing or fails the integrity check, the WebView is unavailable, or loading times out. `code` holds the reason. |
| `ReactEngineUnavailableException` | No native implementation exists for this platform. |
| `ReactConfigurationException` | A configuration is invalid for the current platform. |
| `ReactJsRuntimeException` | JavaScript threw, or the WebView crashed. Has `jsStack` and `isFatal`. |
| `ReactRpcException` | JavaScript answered with an error. Has `code` and `data`. |
| `ReactRpcTimeoutException` | No answer before the time limit. JavaScript receives `$/cancelRequest`. |
| `ReactSerializationException` | A Dart value is not valid JSON. `path` shows where, for example `$.items[2].date`. |
| `ReactRuntimeDisposedException` | The runtime was disposed or crashed while a call was waiting. |
| `ReactProtocolException` | A malformed message was received. |

---

## JavaScript contract

You only need this if you write your own bridge instead of the `bridge.js` above.

| Global or message | Direction | Purpose |
| --- | --- | --- |
| `window.__FRE_BOOT__` | Host → JS | `{runtimeId, contractVersion, transport, platform}`, defined before any page script runs. |
| `window.__freNative.postMessage(frame)` | JS → host | Sends a JSON-RPC message (as a string). |
| `window.__freReceive(frame)` | Host → JS | Defined by your page; receives JSON-RPC messages. Define it before sending the first message. |
| `$/mount` | Host → JS | `{viewId, moduleName, props, cacheKey, reattached}` when a view attaches. |
| `$/updateProps` | Host → JS | `{viewId, props}` when `initialProps` change. |
| `$/unmount` | Host → JS | `{viewId}` or `{cacheKey}` when a surface is released. |
| `$/cancelRequest` | Host → JS | `{id}` when a Dart call timed out. |

Messages sent by Dart before the page's first message are queued and delivered once it arrives.

For the React Native engine:

| API or message | Direction | Purpose |
| --- | --- | --- |
| `props.__fre` | Host → JS | `{runtimeId, viewId, contractVersion, platform, cacheKey}` on every root component. |
| `NativeModules.FlutterReactEmbed.postMessage(runtimeId, frame)` | JS → host | Sends a JSON-RPC message (as a string). |
| `freFrame` event on `new NativeEventEmitter(NativeModules.FlutterReactEmbed)` | Host → JS | `{runtimeId, frame}`; ignore frames for other runtime ids. |

The first message JavaScript sends for a runtime marks it ready. Dart's messages are queued until then, and again after a JavaScript reload.

---

## Example app

The [example app](https://github.com/Amarj234/flutter_react_embed/tree/main/packages/flutter_react_embed/example) embeds the open-source [CoreUI React admin dashboard](https://github.com/coreui/coreui-free-react-admin-template), with a live log of every message from JavaScript. Its `tool/setup_test_react.sh` script clones and builds the dashboard, copies it into the assets, registers every folder in `pubspec.yaml`, and pins its hash. Use it as a reference for automating steps 5 and 6.

```sh
git clone https://github.com/Amarj234/flutter_react_embed.git
cd flutter_react_embed/packages/flutter_react_embed/example
tool/setup_test_react.sh   # needs git and Node.js 20+
flutter run
```

---

## Limitations

- A web runtime can be shown in only one view at a time; attaching a second view to the same runtime is reported as an error. React Native runtimes can show several views.
- One React Native bundle per app process (React Native runs one JavaScript instance).
- On Android, all bundles are served from the same origin, so they share `localStorage`.
- On iOS, the page origin is `fre-app://bundle`; remote APIs must allow it in their CORS policy.
- Web and desktop platforms are not supported yet.

---

## Author

Created and maintained by **Amarjeet** ([@Amarj234](https://github.com/Amarj234)), Flutter developer.

- 💼 LinkedIn: [linkedin.com/in/amarj234](https://www.linkedin.com/in/amarj234)
- 🐙 GitHub: [github.com/Amarj234](https://github.com/Amarj234)
- 🐛 Issues and feature requests: [GitHub Issues](https://github.com/Amarj234/flutter_react_embed/issues)

If this package helps you, please give it a 👍 on [pub.dev](https://pub.dev/packages/flutter_react_embed) and a ⭐ on [GitHub](https://github.com/Amarj234/flutter_react_embed).

## License

BSD 3-Clause. See [LICENSE](https://github.com/Amarj234/flutter_react_embed/blob/main/LICENSE).
