# Hybrid engine test checklist (v1.1.0)

Verifies that `ReactView` switches between `ReactEmbedType.web` (WebView) and
`ReactEmbedType.native` (ReactHost) on Android without platform-thread
exceptions or leaks. Run everything from `packages/flutter_react_embed/example`.

## 1. Automated gates

```sh
tool/run_local_test.sh all            # pub-get → bundle → device → test → soak
```

Each line below is a `PASS`/`FAIL` row in `.fre_test_logs/<run>/summary.txt`.
A release candidate needs every row to pass.

| # | Gate | Stage | Pass condition |
| --- | --- | --- | --- |
| A1 | `flutter pub get` in the workspace root and each of the 5 packages | pub-get | All resolve |
| A2 | Release manifests | pub-get | Every package has a CHANGELOG entry for its own version; `flutter_react_embed` depends on each sibling at `^<its version>`; the podspec matches `flutter_react_embed_ios` |
| A3 | Static analysis | pub-get | `flutter analyze packages` is clean |
| A4 | Probe bundle | bundle | `assets/rn/index.android.bundle` exists and contains `FreProbe` and the bridge (`freFrame`) |
| A5 | Web contract | test | `add`, `echo`, `throwError`, `ping`→`pong`, `propsApplied` pass on the WebView |
| A6 | Native contract | test | Same checks pass on the React Native surface; the runtime reports `ReactEngineKind.reactNative` |
| A7 | Switching | test | 10 alternating mounts with no `onError`; every runtime rejects calls after disposal |
| A8 | Soak | soak | `rounds × cycles` surfaces all `PASS`; both engines exercised |
| A9 | Thread safety | test, soak | logcat has none of: `CalledFromWrongThreadException`, `Only the original thread…`, `A WebView method was called on thread`, `must be called on the main thread`, `FATAL EXCEPTION`, `ANR in`, `Unhandled Exception`, `Ignored a second reply` |
| A10 | Linking | test, soak | logcat has no `UnsatisfiedLinkError`, `NoClassDefFoundError`, `NoSuchMethodError` |
| A11 | No leaked WebView | soak | `WebViews: 0` after GC with nothing mounted |
| A12 | No leaked Activity | soak | `Activities: ≤ 1` after GC |
| A13 | Bounded growth | soak | From round 2 to the last round: Java heap `≤ 8 MB`, Views `≤ 50`, AppContexts `≤ 0`. Native heap is reported only |

Warnings (`WARN` rows) don't fail the run, but read each one before you sign off:
React Native `SoftException`s, `ReactNativeJS` errors, `FlutterReactEmbed`
error logs, dropped frames, and StrictMode violations.

Useful variations:

```sh
tool/run_local_test.sh soak --cycles 40 --rounds 6   # longer soak
tool/run_local_test.sh test --device emulator-5554   # one stage, one device
```

## 2. Manual checks (`tool/run_local_test.sh run`)

This runs `flutter run -d <device> -t lib/hybrid_switch_main.dart`. Every
action logs a `FRE_HARNESS` line on screen and in logcat. After you quit with
`q`, the script scans the session's logcat (gate A9/A10).

| # | Action | Expected |
| --- | --- | --- |
| M1 | Launch | Web surface (demo page) shows; log shows `CREATED web` then `PASS web` |
| M2 | Tap **Native** | Blue "React Native probe" card shows its runtime id and props; `PASS native` |
| M3 | Tap **Web**, then **Native** 5 times quickly | Only the last tap's surface remains; no `ERROR`; no frozen frame |
| M4 | Tap **Auto-cycle ×20** | `CYCLES DONE … failed=0` |
| M5 | Rotate the device while Native is shown | Surface is redrawn; no crash; tapping Web afterwards still passes (Activity lifecycle forwarding) |
| M6 | Press Home, wait 10 s, reopen | Surface is still interactive; next switch passes (`onHostPause` / `onHostResume`) |
| M7 | Tap **Unmount**, then in another terminal: `adb shell run-as dev.flutterreactembed.flutter_react_embed_example kill -10 $(adb shell pidof dev.flutterreactembed.flutter_react_embed_example)` and `adb shell dumpsys meminfo dev.flutterreactembed.flutter_react_embed_example \| grep -E 'WebViews\|Activities'` | `WebViews: 0`, `Activities: 1` |
| M8 | Press `r` (hot reload) and `R` (hot restart) in the `flutter run` terminal, then switch both ways | Both engines still pass. After a hot restart, Dart reboots runtimes; React Native's JS instance stays resident |
| M9 | Android Studio › Profiler › Memory: capture a heap dump after M4 + M7 | No `WebView`, `ReactSurfaceView` or `MainActivity` instance beyond the live one |

## 3. Interpreting failures

| Symptom | Likely cause | Where to look |
| --- | --- | --- |
| `UNSUPPORTED_ENGINE` on Native | Built without `FRE_REACT_NATIVE=1` (react-android not linked) | `soak-build.log`; `android/app/build.gradle.kts` |
| `BUNDLE_NOT_FOUND` | Bundle missing or `assets/rn/` not in pubspec | `rn-bundle.log` |
| Native times out waiting for `mounted` | JS did not connect: probe crashed or bridge mismatch | `logcat-*.txt`, tag `ReactNativeJS` |
| `UnsatisfiedLinkError` | `react-android` / `hermes-android` versions don't match each other or the bundle's `react-native` | `tool/rn_probe/package.json` vs `build.gradle.kts` |
| `WebViews > 0` after the soak | A WebView survived `WebRuntime.dispose` | heap dump, `WebRuntime.destroyWebView` |
| `Activities > 1` | A surface's context wrapper or the ReactHost holds an old Activity | heap dump, `NativeRuntime.detach`, `ReactNativeHostHolder` |
