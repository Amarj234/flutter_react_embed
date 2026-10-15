# flutter_react_embed example

Embeds an open-source React dashboard ([CoreUI Free React Admin Template](https://github.com/coreui/coreui-free-react-admin-template), pinned to `v5.7.0`) and a hand-written internal state view. A dropdown switches between them, and a log overlay shows every message the JS context sends over the plugin's MethodChannel bridge.

## Requirements

- Flutter 3.27+ and the Android/iOS toolchains (`flutter doctor`)
- git, Node.js 20+, npm, perl

## Workflow

All commands run from this directory (`packages/flutter_react_embed/example`).

1. Build and install the React app:

   ```sh
   tool/setup_test_react.sh
   ```

   This fetches the pinned revision into `.react_src/`, runs `npm install` and `npm run build`, and copies `build/` into `assets/react_app/`. It also injects `tool/fre-bridge.js`, rewrites the generated asset block in `pubspec.yaml`, and writes `lib/react_app_manifest.g.dart` with the SHA-256 of the installed `index.html`.

2. Run the app:

   ```sh
   flutter run -d <device-id>
   ```

3. Run the on-device tests (native host contract, then the dashboard end to end):

   ```sh
   flutter test integration_test -d <device-id>
   ```

4. Optionally, reset to a clean tree:

   ```sh
   tool/setup_test_react.sh --clean
   ```

To build a different app or revision, set environment variables:

```sh
REPO_URL=https://github.com/<owner>/<repo>.git REPO_REF=<tag-or-commit> tool/setup_test_react.sh
```

## Asset mapping

| Build output | Installed as | Flutter asset key |
| --- | --- | --- |
| `build/index.html` (+ bridge script tag) | `assets/react_app/index.html` | `assets/react_app/index.html` |
| `build/assets/*.js`, `*.css` | `assets/react_app/assets/` | `assets/react_app/assets/<file>` |
| `build/favicon.ico`, `manifest.json` | `assets/react_app/` | `assets/react_app/<file>` |
| `tool/fre-bridge.js` | `assets/react_app/fre-bridge.js` | `assets/react_app/fre-bridge.js` |

Flutter does not include subdirectories of a listed asset directory, so the script lists every directory between these markers in `pubspec.yaml`:

```yaml
    # >>> react_app assets
    - assets/react_app/
    - assets/react_app/assets/
    # <<< react_app assets
```

At runtime the native host serves `assets/react_app/` as the root of an in-app origin: `https://appassets.androidplatform.net/` on Android, `fre-app://bundle/` on iOS. The app must therefore be built with base `/` or `./`. The script fails if `index.html` references files outside the build output.

## Why the bridge shim

An unmodified SPA does not speak the plugin's bridge protocol, and the native host waits for JS's first frame before `initializeEngine` completes (a 20 s boot timeout). `fre-bridge.js` loads before the app's scripts and does three things:

- **Sends the first frame.** It implements the contract (`__freNative.postMessage` / `__freReceive`) and sends `hello`.
- **Reports app activity.** It forwards routes, console calls, clicks and load timing as events.
- **Serves calls from Dart.** It answers `ping`, `getState` and `navigate`.

Routes state their mode explicitly: `#/charts` uses hash routing (CoreUI's `HashRouter`), and `/charts` uses the History API.

## Using the plugin outside this workspace

This example is a member of the repository's pub workspace, so a path dependency on `../` is enough. A standalone app must also point the federated packages at the checkout:

```yaml
dependencies:
  flutter_react_embed:
    path: <checkout>/packages/flutter_react_embed

dependency_overrides:
  flutter_react_embed_platform_interface:
    path: <checkout>/packages/flutter_react_embed_platform_interface
  flutter_react_embed_android:
    path: <checkout>/packages/flutter_react_embed_android
  flutter_react_embed_ios:
    path: <checkout>/packages/flutter_react_embed_ios
```
