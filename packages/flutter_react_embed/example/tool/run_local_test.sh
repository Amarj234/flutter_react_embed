#!/usr/bin/env bash
#
# Local verification of flutter_react_embed's hybrid engines (React Web +
# React Native) on an Android emulator or device.
#
#   tool/run_local_test.sh [stage] [options]
#
# Stages (default: all):
#   all      pub-get, bundle, device, test, soak
#   pub-get  flutter pub get in the workspace root and every package, plus
#            release-manifest checks (versions, constraints, CHANGELOG entries)
#   bundle   build the mock React Native app (tool/rn_probe + fre-bridge-native.js)
#            into assets/rn/index.android.bundle
#   device   use a connected device or boot an AVD, and wait until it is ready
#   test     integration_test/hybrid_switch_test.dart on the device
#   soak     build lib/hybrid_switch_main.dart, switch web <-> native for
#            --rounds x --cycles, sample memory after each round, scan logcat
#   run      flutter run the harness interactively (manual checklist)
#
# Options:
#   --device SERIAL   adb serial to use (default: first online device, else boot an AVD)
#   --avd NAME        AVD to boot when no device is online (default: first listed)
#   --cycles N        engine switches per soak round (default: 20)
#   --rounds N        soak rounds (default: 4)
#   --keep-emulator   do not shut down an emulator this script booted
#   -h, --help        show this help
#
# Output: .fre_test_logs/<timestamp>/ (logcat captures, meminfo samples,
# summary.txt). Exit status is non-zero if any check failed.
#
# Requirements: Flutter, Node.js 22.11+, npm, JDK 17+, Android SDK with
# platform-tools and emulator (ANDROID_HOME, ANDROID_SDK_ROOT, or the default
# ~/Library/Android/sdk / ~/Android/Sdk).

set -euo pipefail

EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$(cd "$EXAMPLE_DIR/.." && pwd)"
PACKAGES_DIR="$(cd "$PLUGIN_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$PACKAGES_DIR/.." && pwd)"

APP_ID="dev.flutterreactembed.flutter_react_embed_example"
RN_MOCK_DIR="$EXAMPLE_DIR/.rn_mock"
RN_BUNDLE="$EXAMPLE_DIR/assets/rn/index.android.bundle"
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=11

STAGE="all"
DEVICE=""
AVD=""
CYCLES=20
ROUNDS=4
KEEP_EMULATOR=0
BOOTED_EMULATOR=0

# Leak thresholds, checked between the first and the last soak round (after GC).
MAX_JAVA_HEAP_GROWTH_KB=8192
MAX_VIEW_GROWTH=50

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$EXAMPLE_DIR/.fre_test_logs/$RUN_ID"
SUMMARY="$LOG_DIR/summary.txt"
FAILURES=0
WARNINGS=0

# Lines that fail the run. Thread-confinement violations come first: they are
# what a wrong-thread call into WebView, a View or React Native looks like.
FATAL_PATTERNS=(
  'FATAL EXCEPTION'
  'CalledFromWrongThreadException'
  'Only the original thread that created a view hierarchy'
  'A WebView method was called on thread'
  'must be called on the main thread'
  'must be called from the main thread'
  'Methods marked with @UiThread must be executed on the main thread'
  'ANR in '
  'UnsatisfiedLinkError'
  'NoClassDefFoundError'
  'NoSuchMethodError'
  'Unhandled Exception'
  'Ignored a second reply to the same method call'
  'has leaked'
)

# Lines reported as warnings. React Native soft exceptions and JS console
# errors are not crashes, but every one of them deserves a look.
WARN_PATTERNS=(
  'ReactNativeJS.*Error'
  'SoftException'
  'E FlutterReactEmbed'
  'E/FlutterReactEmbed'
  'Dropped a .*-byte frame'
  'StrictMode policy violation'
)

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; echo "PASS  $*" >>"$SUMMARY"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; echo "WARN  $*" >>"$SUMMARY"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; echo "FAIL  $*" >>"$SUMMARY"; FAILURES=$((FAILURES + 1)); }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 2; }

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then
    STAGE="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) DEVICE="${2:?--device needs a serial}"; shift 2 ;;
      --avd) AVD="${2:?--avd needs a name}"; shift 2 ;;
      --cycles) CYCLES="${2:?--cycles needs a number}"; shift 2 ;;
      --rounds) ROUNDS="${2:?--rounds needs a number}"; shift 2 ;;
      --keep-emulator) KEEP_EMULATOR=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  case "$STAGE" in
    all | pub-get | bundle | device | test | soak | run) ;;
    *) die "unknown stage: $STAGE (see --help)" ;;
  esac
  [[ "$CYCLES" =~ ^[1-9][0-9]*$ ]] || die "--cycles must be a positive integer"
  [[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "--rounds must be a positive integer"
  if [[ "$ROUNDS" -lt 2 ]]; then
    log "note: --rounds 1 samples memory once; leak growth checks need at least 2"
  fi
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

resolve_sdk() {
  local candidate
  for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [[ -n "$candidate" && -x "$candidate/platform-tools/adb" ]]; then
      ANDROID_SDK="$candidate"
      ADB="$candidate/platform-tools/adb"
      EMULATOR="$candidate/emulator/emulator"
      return
    fi
  done
  die "Android SDK not found; set ANDROID_HOME"
}

preflight() {
  log "Preflight"
  command -v flutter >/dev/null || die "flutter is not on PATH"
  command -v node >/dev/null || die "node is not on PATH (Node.js ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR}+ required)"
  command -v npm >/dev/null || die "npm is not on PATH"
  command -v java >/dev/null || die "java is not on PATH (JDK 17+ required)"
  local node_version major minor
  node_version="$(node -p 'process.versions.node')"
  major="${node_version%%.*}"
  minor="$(echo "$node_version" | cut -d. -f2)"
  if ((major < MIN_NODE_MAJOR || (major == MIN_NODE_MAJOR && minor < MIN_NODE_MINOR))); then
    die "Node.js $node_version found; React Native 0.87 needs ${MIN_NODE_MAJOR}.${MIN_NODE_MINOR}+"
  fi
  resolve_sdk
  mkdir -p "$LOG_DIR"
  : >"$SUMMARY"
  {
    echo "flutter_react_embed hybrid verification $RUN_ID"
    echo "stage=$STAGE cycles=$CYCLES rounds=$ROUNDS"
    flutter --version 2>/dev/null | head -1 || true
    echo "node $node_version, sdk $ANDROID_SDK"
    echo
  } >>"$SUMMARY"
  ok "toolchain: $(flutter --version 2>/dev/null | head -1 | cut -c1-40 || true), node $node_version"
}

# -----------------------------------------------------------------------------
# Stage: pub-get and release manifest checks
# -----------------------------------------------------------------------------

stage_pub_get() {
  log "Dependency validation"
  local dir name
  for dir in \
    "$WORKSPACE_DIR" \
    "$PACKAGES_DIR/flutter_react_embed_platform_interface" \
    "$PACKAGES_DIR/flutter_react_embed_android" \
    "$PACKAGES_DIR/flutter_react_embed_ios" \
    "$PLUGIN_DIR" \
    "$EXAMPLE_DIR"; do
    name="${dir#"$WORKSPACE_DIR"}"
    name="${name:-/ (workspace root)}"
    if (cd "$dir" && flutter pub get >"$LOG_DIR/pub-get$(echo "$name" | tr '/ ()' '____').log" 2>&1); then
      ok "flutter pub get $name"
    else
      fail "flutter pub get $name (see $LOG_DIR)"
    fi
  done

  # Packages are versioned independently (a patch release ships only what
  # changed). Each must have a CHANGELOG entry for its own version, and
  # flutter_react_embed must depend on each sibling at ^<its version>.
  local package version
  for package in flutter_react_embed flutter_react_embed_platform_interface flutter_react_embed_android flutter_react_embed_ios; do
    version="$(sed -n 's/^version: *//p' "$PACKAGES_DIR/$package/pubspec.yaml")"
    if grep -q "^## $version\$" "$PACKAGES_DIR/$package/CHANGELOG.md"; then
      ok "$package $version has a CHANGELOG entry"
    else
      fail "$package CHANGELOG has no '## $version' entry"
    fi
  done
  for package in flutter_react_embed_android flutter_react_embed_ios flutter_react_embed_platform_interface; do
    version="$(sed -n 's/^version: *//p' "$PACKAGES_DIR/$package/pubspec.yaml")"
    if grep -q "^  $package: \^$version\$" "$PLUGIN_DIR/pubspec.yaml"; then
      ok "flutter_react_embed depends on $package ^$version"
    else
      fail "flutter_react_embed does not constrain $package to ^$version"
    fi
  done
  version="$(sed -n 's/^version: *//p' "$PACKAGES_DIR/flutter_react_embed_ios/pubspec.yaml")"
  if grep -q "s.version *= *'$version'" "$PACKAGES_DIR/flutter_react_embed_ios/ios/flutter_react_embed_ios.podspec"; then
    ok "podspec version $version matches flutter_react_embed_ios"
  else
    fail "flutter_react_embed_ios.podspec version is not $version"
  fi

  if (cd "$WORKSPACE_DIR" && flutter analyze packages >"$LOG_DIR/analyze.log" 2>&1); then
    ok "flutter analyze (all packages)"
  else
    fail "flutter analyze reported issues (see $LOG_DIR/analyze.log)"
  fi
}

# -----------------------------------------------------------------------------
# Stage: React Native probe bundle
# -----------------------------------------------------------------------------

stage_bundle() {
  log "React Native probe bundle"
  mkdir -p "$RN_MOCK_DIR" "$(dirname "$RN_BUNDLE")"
  cp "$EXAMPLE_DIR/tool/rn_probe/index.js" \
    "$EXAMPLE_DIR/tool/rn_probe/babel.config.js" \
    "$EXAMPLE_DIR/tool/rn_probe/metro.config.js" \
    "$EXAMPLE_DIR/tool/rn_probe/react-native.config.js" \
    "$EXAMPLE_DIR/tool/fre-bridge-native.js" \
    "$RN_MOCK_DIR/"

  # Reinstall only when the pinned dependencies change.
  local stamp="$RN_MOCK_DIR/.package.json.installed"
  if [[ ! -d "$RN_MOCK_DIR/node_modules" ]] || ! cmp -s "$EXAMPLE_DIR/tool/rn_probe/package.json" "$stamp"; then
    cp "$EXAMPLE_DIR/tool/rn_probe/package.json" "$RN_MOCK_DIR/package.json"
    rm -rf "$RN_MOCK_DIR/node_modules" "$RN_MOCK_DIR/package-lock.json"
    log "npm install (React Native 0.87.1; first run takes a few minutes)"
    if (cd "$RN_MOCK_DIR" && npm install --no-audit --no-fund >"$LOG_DIR/npm-install.log" 2>&1); then
      cp "$EXAMPLE_DIR/tool/rn_probe/package.json" "$stamp"
      ok "npm install"
    else
      fail "npm install (see $LOG_DIR/npm-install.log)"
      return 1
    fi
  else
    ok "npm dependencies up to date"
  fi

  rm -f "$RN_BUNDLE"
  if (cd "$RN_MOCK_DIR" && npx react-native bundle \
    --platform android \
    --dev false \
    --minify false \
    --entry-file index.js \
    --bundle-output "$RN_BUNDLE" \
    --assets-dest "$RN_MOCK_DIR/build/res" \
    --reset-cache >"$LOG_DIR/rn-bundle.log" 2>&1); then
    :
  else
    fail "react-native bundle (see $LOG_DIR/rn-bundle.log)"
    return 1
  fi
  if [[ -s "$RN_BUNDLE" ]] && grep -q "FreProbe" "$RN_BUNDLE" && grep -q "freFrame" "$RN_BUNDLE"; then
    ok "assets/rn/index.android.bundle ($(wc -c <"$RN_BUNDLE" | tr -d ' ') bytes, FreProbe + bridge included)"
  else
    fail "bundle is empty or misses FreProbe / the bridge"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Stage: device
# -----------------------------------------------------------------------------

online_devices() {
  "$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

stage_device() {
  log "Android target"
  if [[ -n "$DEVICE" ]]; then
    online_devices | grep -qx "$DEVICE" || die "device $DEVICE is not online (adb devices)"
  else
    DEVICE="$(online_devices | head -1)"
  fi

  if [[ -z "$DEVICE" ]]; then
    [[ -x "$EMULATOR" ]] || die "no device online and no emulator binary at $EMULATOR"
    if [[ -z "$AVD" ]]; then
      AVD="$("$EMULATOR" -list-avds | head -1)"
    fi
    [[ -n "$AVD" ]] || die "no device online and no AVD defined (create one in Android Studio)"
    log "booting AVD $AVD"
    "$EMULATOR" -avd "$AVD" -no-snapshot-save -no-audio -no-boot-anim >"$LOG_DIR/emulator.log" 2>&1 &
    BOOTED_EMULATOR=1
    local waited=0
    while [[ -z "$DEVICE" ]]; do
      sleep 2
      waited=$((waited + 2))
      DEVICE="$(online_devices | grep '^emulator-' | head -1 || true)"
      ((waited < 180)) || die "emulator did not come online within 180 s (see $LOG_DIR/emulator.log)"
    done
  fi

  local waited=0
  until [[ "$("$ADB" -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    sleep 2
    waited=$((waited + 2))
    ((waited < 300)) || die "$DEVICE did not finish booting within 300 s"
  done
  # Wake and unlock so the app's Activity reaches RESUMED.
  "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  "$ADB" -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  local model sdk
  model="$("$ADB" -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')"
  sdk="$("$ADB" -s "$DEVICE" shell getprop ro.build.version.sdk | tr -d '\r')"
  ok "device $DEVICE ($model, API $sdk)"
}

# -----------------------------------------------------------------------------
# Log scanning
# -----------------------------------------------------------------------------

# scan_logcat FILE LABEL: fails on FATAL_PATTERNS, warns on WARN_PATTERNS.
scan_logcat() {
  local file="$1" label="$2" pattern matches found=0
  for pattern in "${FATAL_PATTERNS[@]}"; do
    matches="$(grep -E -- "$pattern" "$file" || true)"
    if [[ -n "$matches" ]]; then
      found=1
      fail "$label logcat: '$pattern' ($(echo "$matches" | wc -l | tr -d ' ') lines)"
      echo "$matches" | head -5 | sed 's/^/        /' | tee -a "$SUMMARY"
    fi
  done
  for pattern in "${WARN_PATTERNS[@]}"; do
    matches="$(grep -E -- "$pattern" "$file" || true)"
    if [[ -n "$matches" ]]; then
      warn "$label logcat: '$pattern' ($(echo "$matches" | wc -l | tr -d ' ') lines)"
      echo "$matches" | head -3 | sed 's/^/        /' | tee -a "$SUMMARY"
    fi
  done
  ((found == 0)) && ok "$label logcat: no platform-thread exceptions, crashes or leak reports"
  return 0
}

# -----------------------------------------------------------------------------
# Stage: integration test
# -----------------------------------------------------------------------------

stage_test() {
  log "Integration test: integration_test/hybrid_switch_test.dart"
  [[ -s "$RN_BUNDLE" ]] || die "no React Native bundle; run the 'bundle' stage first"
  "$ADB" -s "$DEVICE" logcat -c
  if (cd "$EXAMPLE_DIR" && FRE_REACT_NATIVE=1 flutter test integration_test/hybrid_switch_test.dart \
    -d "$DEVICE" \
    --dart-define=FRE_REACT_NATIVE=true \
    2>&1 | tee "$LOG_DIR/integration-test.log"); then
    ok "hybrid_switch_test: $(grep -Eo '\+[0-9]+(: | ~[0-9]+: )?All tests passed!' "$LOG_DIR/integration-test.log" | tail -1 || echo 'passed')"
  else
    fail "hybrid_switch_test failed (see $LOG_DIR/integration-test.log)"
  fi
  if grep -q '~[0-9]' "$LOG_DIR/integration-test.log"; then
    warn "some integration tests were skipped; was FRE_REACT_NATIVE=true passed?"
  fi
  "$ADB" -s "$DEVICE" logcat -d -v threadtime >"$LOG_DIR/logcat-test.txt"
  scan_logcat "$LOG_DIR/logcat-test.txt" "integration test"
}

# -----------------------------------------------------------------------------
# Stage: soak (engine switching + memory sampling)
# -----------------------------------------------------------------------------

# PID of the app, or nothing. pidof exits 1 when the process is gone, which
# must not trip `set -o pipefail`.
app_pid() {
  "$ADB" -s "$DEVICE" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r' || true
}

meminfo_value() {
  # meminfo_value FILE LABEL -> first integer after "LABEL:" (0 if absent).
  # The leading boundary keeps "Views:" from matching inside "WebViews:".
  local value
  value="$(grep -Eo "(^|[^A-Za-z])$2: +[0-9]+" "$1" | head -1 | grep -Eo '[0-9]+$' || true)"
  echo "${value:-0}"
}

sample_memory() {
  # sample_memory ROUND: force a GC in the app, then save dumpsys meminfo.
  local round="$1" pid file="$LOG_DIR/meminfo-round-$1.txt"
  pid="$(app_pid)"
  [[ -n "$pid" ]] || { fail "app process died before round $round sample"; return 1; }
  # SIGUSR1 makes ART run a full GC; run-as works because the build is debuggable.
  "$ADB" -s "$DEVICE" shell run-as "$APP_ID" kill -10 "$pid" >/dev/null 2>&1 || true
  sleep 3
  "$ADB" -s "$DEVICE" shell dumpsys meminfo "$APP_ID" >"$file"
  printf '        round %s: Java Heap %s KB, Native Heap %s KB, TOTAL PSS %s KB, Views %s, WebViews %s, Activities %s, AppContexts %s\n' \
    "$round" \
    "$(meminfo_value "$file" 'Java Heap')" "$(meminfo_value "$file" 'Native Heap')" \
    "$(meminfo_value "$file" 'TOTAL PSS')" "$(meminfo_value "$file" 'Views')" \
    "$(meminfo_value "$file" 'WebViews')" "$(meminfo_value "$file" 'Activities')" \
    "$(meminfo_value "$file" 'AppContexts')" | tee -a "$SUMMARY"
}

wait_for_log_line() {
  # wait_for_log_line PATTERN TIMEOUT_SECONDS -> 0 when PATTERN appears in the app's log
  local pattern="$1" timeout="$2" waited=0
  while ! "$ADB" -s "$DEVICE" logcat -d -s flutter:I | grep -q -- "$pattern"; do
    sleep 2
    waited=$((waited + 2))
    if [[ -z "$(app_pid)" ]]; then
      return 2
    fi
    ((waited < timeout)) || return 1
  done
}

stage_soak() {
  log "Soak: $ROUNDS rounds x $CYCLES web <-> native switches"
  [[ -s "$RN_BUNDLE" ]] || die "no React Native bundle; run the 'bundle' stage first"
  if ! (cd "$EXAMPLE_DIR" && FRE_REACT_NATIVE=1 flutter build apk --debug \
    -t lib/hybrid_switch_main.dart \
    --dart-define=FRE_REACT_NATIVE=true \
    --dart-define=FRE_AUTOCYCLE="$CYCLES" \
    --dart-define=FRE_ROUNDS="$ROUNDS" \
    >"$LOG_DIR/soak-build.log" 2>&1); then
    fail "harness build failed (see $LOG_DIR/soak-build.log)"
    return 1
  fi
  ok "harness APK built"

  "$ADB" -s "$DEVICE" install -r "$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-debug.apk" >"$LOG_DIR/soak-install.log" 2>&1 \
    || { fail "adb install failed (see $LOG_DIR/soak-install.log)"; return 1; }
  "$ADB" -s "$DEVICE" shell am force-stop "$APP_ID"
  "$ADB" -s "$DEVICE" logcat -c
  "$ADB" -s "$DEVICE" shell am start -W -n "$APP_ID/.MainActivity" >/dev/null

  # Each switch takes a few seconds; allow 15 s per switch plus the idle time.
  local per_round=$((CYCLES * 15 + 30)) round status
  for ((round = 1; round <= ROUNDS; round++)); do
    status=0
    wait_for_log_line "FRE_HARNESS ROUND $round/$ROUNDS DONE" "$per_round" || status=$?
    case "$status" in
      0) ;;
      2) fail "app process died during round $round"; break ;;
      *) fail "round $round did not finish within ${per_round} s"; break ;;
    esac
    "$ADB" -s "$DEVICE" logcat -d -s flutter:I | grep "FRE_HARNESS ROUND $round/$ROUNDS DONE" | tail -1 \
      | sed 's/.*FRE_HARNESS /        /' | tee -a "$SUMMARY"
    sample_memory "$round" || break
  done
  wait_for_log_line "FRE_HARNESS DONE" 30 || true

  local pid
  pid="$(app_pid)"
  "$ADB" -s "$DEVICE" logcat -d -v threadtime >"$LOG_DIR/logcat-soak.txt"
  "$ADB" -s "$DEVICE" logcat -d -s flutter:I | grep 'FRE_HARNESS' >"$LOG_DIR/harness.txt" || true

  local passes failures
  passes="$(grep -c 'FRE_HARNESS PASS' "$LOG_DIR/harness.txt" || true)"
  failures="$(grep -Ec 'FRE_HARNESS (FAIL|ERROR|CYCLE)' "$LOG_DIR/harness.txt" || true)"
  local expected=$((CYCLES * ROUNDS))
  if [[ "$failures" -eq 0 && "$passes" -eq "$expected" ]]; then
    ok "soak: $passes/$expected surfaces passed the contract checks"
  else
    fail "soak: $passes/$expected surfaces passed, $failures failures (see $LOG_DIR/harness.txt)"
    grep -E 'FRE_HARNESS (FAIL|ERROR|CYCLE)' "$LOG_DIR/harness.txt" | head -5 | sed 's/^/        /' | tee -a "$SUMMARY"
  fi
  local web_passes native_passes
  web_passes="$(grep -c 'FRE_HARNESS PASS web' "$LOG_DIR/harness.txt" || true)"
  native_passes="$(grep -c 'FRE_HARNESS PASS native' "$LOG_DIR/harness.txt" || true)"
  if [[ "$web_passes" -gt 0 && "$native_passes" -gt 0 ]]; then
    ok "engine switch exercised both ways (web $web_passes, native $native_passes)"
  else
    fail "engine switch did not exercise both engines (web $web_passes, native $native_passes)"
  fi

  check_leaks
  scan_logcat "$LOG_DIR/logcat-soak.txt" "soak"
  [[ -n "$pid" ]] && "$ADB" -s "$DEVICE" shell am force-stop "$APP_ID"
  return 0
}

check_leaks() {
  local first="$LOG_DIR/meminfo-round-1.txt" last="$LOG_DIR/meminfo-round-$ROUNDS.txt"
  [[ -f "$first" && -f "$last" ]] || { fail "leak check: missing meminfo samples"; return; }

  local webviews activities
  webviews="$(meminfo_value "$last" 'WebViews')"
  activities="$(meminfo_value "$last" 'Activities')"
  # The view is unmounted when the sample is taken: no WebView may survive GC.
  if [[ "$webviews" -eq 0 ]]; then
    ok "leak check: 0 WebViews alive after the last round"
  else
    fail "leak check: $webviews WebView(s) alive with no surface mounted"
  fi
  if [[ "$activities" -le 1 ]]; then
    ok "leak check: $activities Activity alive"
  else
    fail "leak check: $activities Activities alive (a retained context pins an old Activity)"
  fi

  if [[ "$ROUNDS" -lt 2 ]]; then
    warn "leak check: growth not measured (needs --rounds 2 or more)"
    return
  fi
  # Round 1 includes one-time costs (Hermes, bundle, WebView provider), so
  # growth is measured from round 2 on when there are enough rounds.
  local base="$first"
  [[ "$ROUNDS" -ge 3 ]] && base="$LOG_DIR/meminfo-round-2.txt"
  local java_growth view_growth context_growth native_growth
  java_growth=$(($(meminfo_value "$last" 'Java Heap') - $(meminfo_value "$base" 'Java Heap')))
  view_growth=$(($(meminfo_value "$last" 'Views') - $(meminfo_value "$base" 'Views')))
  context_growth=$(($(meminfo_value "$last" 'AppContexts') - $(meminfo_value "$base" 'AppContexts')))
  native_growth=$(($(meminfo_value "$last" 'Native Heap') - $(meminfo_value "$base" 'Native Heap')))
  if ((java_growth <= MAX_JAVA_HEAP_GROWTH_KB)); then
    ok "leak check: Java heap growth ${java_growth} KB (limit ${MAX_JAVA_HEAP_GROWTH_KB} KB)"
  else
    fail "leak check: Java heap grew ${java_growth} KB over the soak (limit ${MAX_JAVA_HEAP_GROWTH_KB} KB)"
  fi
  if ((view_growth <= MAX_VIEW_GROWTH)); then
    ok "leak check: View count growth ${view_growth} (limit ${MAX_VIEW_GROWTH})"
  else
    fail "leak check: ${view_growth} more Views alive after the soak (limit ${MAX_VIEW_GROWTH})"
  fi
  if ((context_growth <= 0)); then
    ok "leak check: AppContexts stable"
  else
    fail "leak check: ${context_growth} more AppContexts alive after the soak"
  fi
  # Hermes and the WebView renderer manage native memory themselves; growth
  # here is reported, not failed.
  echo "        native heap growth ${native_growth} KB (informational)" | tee -a "$SUMMARY"
}

# -----------------------------------------------------------------------------
# Stage: run (interactive)
# -----------------------------------------------------------------------------

stage_run() {
  log "flutter run (interactive). Work through the checklist in tool/HYBRID_TEST_CHECKLIST.md"
  [[ -s "$RN_BUNDLE" ]] || die "no React Native bundle; run the 'bundle' stage first"
  "$ADB" -s "$DEVICE" logcat -c
  # Mirror the device log next to the run so the scan below sees the whole session.
  "$ADB" -s "$DEVICE" logcat -v threadtime >"$LOG_DIR/logcat-run.txt" &
  local logcat_pid=$!
  local status=0
  (cd "$EXAMPLE_DIR" && FRE_REACT_NATIVE=1 flutter run -d "$DEVICE" \
    -t lib/hybrid_switch_main.dart \
    --dart-define=FRE_REACT_NATIVE=true) || status=$?
  kill "$logcat_pid" 2>/dev/null || true
  scan_logcat "$LOG_DIR/logcat-run.txt" "interactive run"
  ((status == 0)) || fail "flutter run exited with status $status"
}

# -----------------------------------------------------------------------------

cleanup() {
  if ((BOOTED_EMULATOR == 1 && KEEP_EMULATOR == 0)) && [[ -n "$DEVICE" ]]; then
    "$ADB" -s "$DEVICE" emu kill >/dev/null 2>&1 || true
  fi
}

finish() {
  echo >>"$SUMMARY"
  echo "failures=$FAILURES warnings=$WARNINGS" >>"$SUMMARY"
  echo
  if ((FAILURES == 0)); then
    printf '\033[1;32mAll checks passed\033[0m (%s warnings). Logs: %s\n' "$WARNINGS" "$LOG_DIR"
  else
    printf '\033[1;31m%s check(s) failed\033[0m (%s warnings). Summary: %s\n' "$FAILURES" "$WARNINGS" "$SUMMARY"
  fi
  ((FAILURES == 0))
}

main() {
  parse_args "$@"
  preflight
  trap cleanup EXIT
  case "$STAGE" in
    all)
      stage_pub_get
      stage_bundle || true
      stage_device
      if [[ -s "$RN_BUNDLE" ]]; then
        stage_test
        stage_soak
      else
        fail "skipping device stages: no React Native bundle"
      fi
      ;;
    pub-get) stage_pub_get ;;
    bundle) stage_bundle || true ;;
    device) stage_device ;;
    test) stage_device; stage_test ;;
    soak) stage_device; stage_soak ;;
    run) stage_device; stage_run ;;
  esac
  finish
}

main "$@"
