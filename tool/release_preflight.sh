#!/usr/bin/env bash
#
# Pre-publish pipeline for the flutter_react_embed package suite.
#
#   tool/release_preflight.sh [options]
#
# Runs, in order, for platform_interface, android, ios and the main package:
#   1. format   dart format (page width 120 from analysis_options.yaml)
#   2. analyze  flutter analyze --fatal-infos --fatal-warnings, plus a Kotlin
#               compile of the Android plugin that fails on any compiler warning
#               (flutter analyze does not see Kotlin, where the React Native
#               compile-only code lives)
#   3. dry-run  flutter pub publish --dry-run, with the archive layout saved and
#               checked for forbidden paths and size
#   4. pana     optional (--pana): the pub.dev scoring tool, per package
#
# Options:
#   --check        do not rewrite files; fail if any file needs formatting
#   --pana         also run pana and require full pub points
#   --skip-kotlin  skip the Kotlin warning check (needs the Android SDK)
#   -h, --help     show this help
#
# Output: .release_preflight/<timestamp>/ with one log per step and summary.txt.
# Exit status is non-zero if any step failed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES=(
  flutter_react_embed_platform_interface
  flutter_react_embed_android
  flutter_react_embed_ios
  flutter_react_embed
)
# Publish order: the main package depends on the other three at ^VERSION, so
# they must be live on pub.dev first.
PUBLISH_ORDER="flutter_react_embed_platform_interface, flutter_react_embed_android, flutter_react_embed_ios, flutter_react_embed"

CHECK_ONLY=0
RUN_PANA=0
SKIP_KOTLIN=0
MAX_ARCHIVE_KB=10240

# File or directory names that must never be in a published archive (build
# output, local test tooling, secrets). Matched as whole tree entries, so
# `.gradle` does not match `build.gradle.kts`.
FORBIDDEN_ARCHIVE_PATHS=(
  'node_modules'
  '.rn_mock'
  '.fre_test_logs'
  '.react_src'
  '.dart_tool'
  'build'
  '.gradle'
  'Pods'
  '.symlinks'
  'local.properties'
  '.release_preflight'
  'index.android.bundle'
  'main.jsbundle'
)
# pub's dry-run warning for an uncommitted working tree. Expected while
# preparing a release; publishing itself requires committing first.
GIT_DIRTY_WARNING='checked-in files are modified in git'

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/.release_preflight/$RUN_ID"
SUMMARY="$LOG_DIR/summary.txt"
FAILURES=0
WARNINGS=0

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; echo "PASS  $*" >>"$SUMMARY"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; echo "WARN  $*" >>"$SUMMARY"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; echo "FAIL  $*" >>"$SUMMARY"; FAILURES=$((FAILURES + 1)); }
indent() { sed 's/^/        /' | tee -a "$SUMMARY"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --pana) RUN_PANA=1 ;;
    --skip-kotlin) SKIP_KOTLIN=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"
{
  echo "flutter_react_embed release preflight $RUN_ID"
  # `|| true`: head closes the pipe early; SIGPIPE must not trip pipefail.
  flutter --version 2>/dev/null | head -1 || true
  echo "git $(git -C "$ROOT" rev-parse --short HEAD) ($(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ') uncommitted paths)"
  echo
} >"$SUMMARY"

# -----------------------------------------------------------------------------
# 1. Format
# -----------------------------------------------------------------------------

stage_format() {
  log "1. Format (dart format, page width from analysis_options.yaml)"
  local package dir
  for package in "${PACKAGES[@]}"; do
    dir="$ROOT/packages/$package"
    if ((CHECK_ONLY)); then
      if (cd "$dir" && dart format --output=none --set-exit-if-changed . >"$LOG_DIR/format-$package.log" 2>&1); then
        ok "$package: already formatted"
      else
        fail "$package: files need formatting"
        grep '^Changed ' "$LOG_DIR/format-$package.log" | indent || true
      fi
    else
      (cd "$dir" && dart format . >"$LOG_DIR/format-$package.log" 2>&1) || {
        fail "$package: dart format failed (see $LOG_DIR/format-$package.log)"
        continue
      }
      if grep -q '^Formatted [^0-9]' "$LOG_DIR/format-$package.log"; then
        ok "$package: reformatted"
        grep '^Formatted [^0-9]' "$LOG_DIR/format-$package.log" | sed 's/^Formatted //' | indent
      else
        ok "$package: already formatted"
      fi
    fi
  done
}

# -----------------------------------------------------------------------------
# 2. Static analysis (Dart + Kotlin)
# -----------------------------------------------------------------------------

stage_analyze() {
  log "2. Static analysis"
  local package dir
  for package in "${PACKAGES[@]}"; do
    dir="$ROOT/packages/$package"
    if (cd "$dir" && flutter analyze --fatal-infos --fatal-warnings >"$LOG_DIR/analyze-$package.log" 2>&1); then
      ok "$package: flutter analyze clean"
    else
      fail "$package: flutter analyze reported issues"
      grep -E '^ *(error|warning|info) •' "$LOG_DIR/analyze-$package.log" | head -20 | indent || true
    fi
  done

  if ((SKIP_KOTLIN)); then
    warn "Kotlin warning check skipped (--skip-kotlin)"
    return
  fi
  kotlin_warnings
}

# Compiles flutter_react_embed_android (WebView + React Native compile-only
# sources) through the example app's Gradle project and fails on any Kotlin
# compiler warning in the plugin's own files.
kotlin_warnings() {
  local example="$ROOT/packages/flutter_react_embed/example"
  local log_file="$LOG_DIR/kotlin-compile.log"
  if ! (cd "$example" && flutter build apk --config-only >"$LOG_DIR/kotlin-config.log" 2>&1); then
    fail "Kotlin: could not generate the example's Gradle project (see $LOG_DIR/kotlin-config.log)"
    return
  fi
  if ! (cd "$example/android" && ./gradlew :flutter_react_embed_android:compileDebugKotlin --rerun \
    --console=plain >"$log_file" 2>&1); then
    fail "Kotlin: flutter_react_embed_android does not compile (see $log_file)"
    grep -E '^e: ' "$log_file" | head -10 | indent || true
    return
  fi
  local warnings
  warnings="$(grep -E '^w: .*flutter_react_embed_android/' "$log_file" || true)"
  if [[ -z "$warnings" ]]; then
    ok "Kotlin: flutter_react_embed_android compiles with no warnings (React Native compile-only included)"
  else
    fail "Kotlin: $(echo "$warnings" | wc -l | tr -d ' ') compiler warning(s) in flutter_react_embed_android"
    echo "$warnings" | sed "s|file://$ROOT/||" | head -20 | indent
  fi
}

# -----------------------------------------------------------------------------
# 3. Publish dry-run
# -----------------------------------------------------------------------------

stage_dry_run() {
  log "3. flutter pub publish --dry-run"
  local package dir log_file status warnings_line other_messages size_kb pattern hits tree
  for package in "${PACKAGES[@]}"; do
    dir="$ROOT/packages/$package"
    log_file="$LOG_DIR/dry-run-$package.log"
    status=0
    (cd "$dir" && flutter pub publish --dry-run >"$log_file" 2>&1) || status=$?

    # The archive layout is the tree printed between "Publishing ..." and the
    # validation output; keep it as its own artifact.
    tree="$LOG_DIR/archive-$package.txt"
    awk '/^Publishing /{p=1; next} /^(Total compressed archive size|Validating package)/{p=0} p' "$log_file" >"$tree"

    warnings_line="$(grep -Eo 'Package has [0-9]+ warnings?( and [0-9]+ hints?)?\.?' "$log_file" | tail -1 || true)"
    other_messages="$(grep -E '^\* ' "$log_file" | grep -vF -- "$GIT_DIRTY_WARNING" || true)"
    if [[ $status -eq 0 ]]; then
      ok "$package: dry-run passed (${warnings_line:-Package has 0 warnings.})"
    elif [[ -z "$other_messages" ]] && grep -qF -- "$GIT_DIRTY_WARNING" "$log_file"; then
      warn "$package: dry-run's only warning is the uncommitted working tree; commit and re-run before publishing"
    else
      fail "$package: dry-run exit $status (${warnings_line:-see log})"
    fi
    # Show every validator message, warnings and hints alike.
    grep -E '^\* ' "$log_file" | head -20 | indent || true

    size_kb="$(grep -Eo 'Total compressed archive size: [0-9.]+ (KB|MB)' "$log_file" | awk '{ v=$5; if ($6=="MB") v*=1024; printf "%d", v }' || true)"
    if [[ -n "$size_kb" ]]; then
      if ((size_kb <= MAX_ARCHIVE_KB)); then
        ok "$package: archive ${size_kb} KB (limit ${MAX_ARCHIVE_KB} KB), $(grep -c '' "$tree") tree lines saved to $(basename "$tree")"
      else
        fail "$package: archive ${size_kb} KB exceeds ${MAX_ARCHIVE_KB} KB"
      fi
    else
      warn "$package: could not read the archive size"
    fi

    hits=""
    for pattern in "${FORBIDDEN_ARCHIVE_PATHS[@]}"; do
      # A tree entry is "├── name (size)" or "└── name/"; match the whole name.
      if grep -qE -- "[─ ]$(printf '%s' "$pattern" | sed 's/[.]/\\./g')/?( \(.*\))?$" "$tree"; then
        hits+="$pattern "
      fi
    done
    if [[ -z "$hits" ]]; then
      ok "$package: archive has no build output, node_modules, test logs or local bundles"
    else
      fail "$package: archive contains forbidden paths: $hits"
    fi
  done
  check_archive_contents
}

# Spot checks that the files 1.1.0 depends on actually ship.
check_archive_contents() {
  local missing=""
  grep -q 'NativeRuntime.kt' "$LOG_DIR/archive-flutter_react_embed_android.txt" || missing+="android:NativeRuntime.kt "
  grep -q 'ReactNativeSupport.kt' "$LOG_DIR/archive-flutter_react_embed_android.txt" || missing+="android:ReactNativeSupport.kt "
  grep -q 'NativeRuntime.swift' "$LOG_DIR/archive-flutter_react_embed_ios.txt" || missing+="ios:ReactNative/NativeRuntime.swift "
  grep -q 'FlutterReactEmbedModule.m' "$LOG_DIR/archive-flutter_react_embed_ios.txt" || missing+="ios:ReactNative/FlutterReactEmbedModule.m "
  grep -q 'fre-bridge-native.js' "$LOG_DIR/archive-flutter_react_embed.txt" || missing+="main:example/tool/fre-bridge-native.js "
  if [[ -z "$missing" ]]; then
    ok "archives include the React Native engine sources and the JS bridge"
  else
    fail "archives are missing: $missing"
  fi
}

# -----------------------------------------------------------------------------
# 4. pana (optional)
# -----------------------------------------------------------------------------

stage_pana() {
  log "4. pana (pub.dev scoring)"
  dart pub global activate pana >"$LOG_DIR/pana-activate.log" 2>&1 || {
    fail "could not activate pana (see $LOG_DIR/pana-activate.log)"
    return
  }
  local package dir log_file points
  for package in "${PACKAGES[@]}"; do
    dir="$ROOT/packages/$package"
    log_file="$LOG_DIR/pana-$package.log"
    (cd "$dir" && dart pub global run pana --no-warning --exit-code-threshold 0 . >"$log_file" 2>&1) || true
    points="$(grep -Eo 'Points: [0-9]+/[0-9]+' "$log_file" | tail -1 || true)"
    if [[ -z "$points" ]]; then
      fail "$package: pana produced no score (see $log_file)"
    elif [[ "${points#Points: }" =~ ^([0-9]+)/([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
      ok "$package: pana $points"
    else
      fail "$package: pana $points"
      grep -E '^### \[[x*~ ]\]|^\* ' "$log_file" | grep -v '^### \[\*\]' | head -12 | indent || true
    fi
  done
}

# -----------------------------------------------------------------------------

stage_format
stage_analyze
stage_dry_run
((RUN_PANA)) && stage_pana

{
  echo
  echo "failures=$FAILURES warnings=$WARNINGS"
  echo "publish order: $PUBLISH_ORDER"
} >>"$SUMMARY"
echo
if ((FAILURES == 0)); then
  printf '\033[1;32mPreflight passed\033[0m (%s warnings). Publish in this order: %s\n' "$WARNINGS" "$PUBLISH_ORDER"
  printf 'Logs: %s\n' "$LOG_DIR"
else
  printf '\033[1;31m%s preflight check(s) failed\033[0m. Summary: %s\n' "$FAILURES" "$SUMMARY"
fi
((FAILURES == 0))
