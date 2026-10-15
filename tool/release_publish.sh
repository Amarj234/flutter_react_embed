#!/usr/bin/env bash
#
# Commits, pushes and publishes the flutter_react_embed package suite.
#
#   tool/release_publish.sh [--dry-run] [--yes] [--version X.Y.Z]
#
# Releases every package whose pubspec is at --version; the others must
# already be on pub.dev at their own pubspec version (a patch release can
# ship only the packages that changed).
#
# Steps (each irreversible step asks for confirmation):
#   1. Preconditions: on main, in sync with origin, pub credentials present,
#      released packages have a CHANGELOG entry, flutter_react_embed depends
#      on each sibling at ^<its pubspec version>, the podspec matches the iOS
#      pubspec, and unreleased packages are already on pub.dev.
#   2. Commit the release (skipped if the tree is already clean).
#   3. Gate: tool/release_preflight.sh on the committed tree must report
#      zero failures and zero warnings (dry-runs included).
#   4. Push main to origin.
#   5. Publish in dependency order with `flutter pub publish` (interactive).
#      flutter_react_embed depends on the other three, so it goes last, and
#      only once pub.dev serves each of them at its pubspec version.
#   6. Tag each published package (<package>-v<VERSION>) and push the tags.
#
# Re-runnable: packages already on pub.dev at VERSION are skipped, so after a
# failure in the middle of step 5, fix the cause and run it again.
#
# --dry-run  run every check and show what would happen; change nothing
#            (no commit, push, publish or tag).
# --yes      answer yes to every confirmation and run `flutter pub publish
#            --force`. For an already approved release only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.1.0"
DRY_RUN=0
ASSUME_YES=0
BRANCH="main"
REMOTE="origin"
PUB_CREDENTIALS="$HOME/Library/Application Support/dart/pub-credentials.json"
PROPAGATION_TIMEOUT_S=900

# Leaves first; flutter_react_embed depends on all three and must be last.
PUBLISH_ORDER=(
  flutter_react_embed_platform_interface
  flutter_react_embed_android
  flutter_react_embed_ios
  flutter_react_embed
)

# Nothing matching these may be committed (local test output, bundles, deps).
FORBIDDEN_IN_COMMIT='(^|/)(node_modules|\.rn_mock|\.fre_test_logs|\.release_preflight|\.dart_tool|build|Pods|\.gradle)/|\.(jsbundle|bundle|hbc|apk|aab|ipa)$|(^|/)local\.properties$|pub-credentials'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --version) VERSION="${2:?--version needs X.Y.Z}"; shift ;;
    -h | --help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

changelog_entry() {
  # changelog_entry PACKAGE: the body of its "## VERSION" CHANGELOG section.
  awk -v heading="## $VERSION" '
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "packages/$1/CHANGELOG.md" | sed '/./,$!d'
}

commit_message() {
  # Subject plus each released package's CHANGELOG entry.
  local package
  printf 'Release flutter_react_embed %s (%s)\n' "$VERSION" "${RELEASE[*]}"
  for package in "${RELEASE[@]}"; do
    printf '\n%s %s:\n%s\n' "$package" "$VERSION" "$(changelog_entry "$package")"
  done
}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
note() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  # confirm PROMPT: continue only on an explicit "yes".
  local answer
  if ((DRY_RUN)); then
    note "dry run: would ask \"$1\""
    return 1
  fi
  if ((ASSUME_YES)); then
    note "$1 yes (--yes)"
    return 0
  fi
  read -r -p "$(printf '\033[1;35m  ?\033[0m %s [type yes] ' "$1")" answer
  [[ "$answer" == "yes" ]]
}

pubspec_version() {
  sed -n 's/^version: *//p' "packages/$1/pubspec.yaml"
}

on_pub_dev() {
  # on_pub_dev PACKAGE [VERSION]: true if pub.dev serves PACKAGE at VERSION
  # (default: the package's pubspec version).
  local version="${2:-$(pubspec_version "$1")}"
  curl -fsS --max-time 20 "https://pub.dev/api/packages/$1" 2>/dev/null \
    | grep -q "\"version\":\"$version\""
}

wait_for_pub_dev() {
  # wait_for_pub_dev PACKAGE: poll until pub.dev serves its pubspec version.
  local waited=0 version
  version="$(pubspec_version "$1")"
  until on_pub_dev "$1" "$version"; do
    ((waited < PROPAGATION_TIMEOUT_S)) || die "$1 $version is not visible on pub.dev after ${PROPAGATION_TIMEOUT_S} s; re-run this script later"
    sleep 15
    waited=$((waited + 15))
    printf '    waiting for pub.dev to list %s %s (%ss)\n' "$1" "$version" "$waited"
  done
}

cd "$ROOT"

# -----------------------------------------------------------------------------
step "1. Preconditions"
# -----------------------------------------------------------------------------
command -v flutter >/dev/null || die "flutter is not on PATH"
command -v curl >/dev/null || die "curl is not on PATH"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "not on $BRANCH (on $(git rev-parse --abbrev-ref HEAD))"
git fetch --quiet "$REMOTE" "$BRANCH" || die "cannot fetch $REMOTE/$BRANCH (network or SSH key?)"
behind="$(git rev-list --count "HEAD..$REMOTE/$BRANCH")"
[[ "$behind" -eq 0 ]] || die "$BRANCH is $behind commit(s) behind $REMOTE/$BRANCH; pull and re-validate first"
ok "on $BRANCH, not behind $REMOTE/$BRANCH"

[[ -f "$PUB_CREDENTIALS" ]] || die "no pub.dev credentials; run: dart pub login"
ok "pub.dev credentials present"

RELEASE=()
for package in "${PUBLISH_ORDER[@]}"; do
  version="$(pubspec_version "$package")"
  if [[ "$version" == "$VERSION" ]]; then
    grep -q "^## $VERSION\$" "packages/$package/CHANGELOG.md" || die "packages/$package/CHANGELOG.md has no '## $VERSION'"
    RELEASE+=("$package")
  elif on_pub_dev "$package" "$version"; then
    ok "$package stays at $version (already on pub.dev)"
  else
    die "$package is at $version, which is neither $VERSION nor published on pub.dev"
  fi
done
((${#RELEASE[@]} > 0)) || die "no package's pubspec is at $VERSION"
ok "releasing $VERSION: ${RELEASE[*]}"

grep -q "s.version *= *'$(pubspec_version flutter_react_embed_ios)'" packages/flutter_react_embed_ios/ios/flutter_react_embed_ios.podspec \
  || die "podspec version does not match flutter_react_embed_ios $(pubspec_version flutter_react_embed_ios)"
for dependency in flutter_react_embed_platform_interface flutter_react_embed_android flutter_react_embed_ios; do
  constraint="^$(pubspec_version "$dependency")"
  grep -q "^  $dependency: \\$constraint\$" packages/flutter_react_embed/pubspec.yaml \
    || die "flutter_react_embed must depend on $dependency $constraint"
done
ok "podspec and flutter_react_embed's constraints match the sibling pubspecs"

for package in "${RELEASE[@]}"; do
  if on_pub_dev "$package"; then
    note "$package $VERSION is already on pub.dev (will be skipped)"
  else
    ok "$package $VERSION not yet on pub.dev"
  fi
done

# -----------------------------------------------------------------------------
step "2. Commit"
# -----------------------------------------------------------------------------
if [[ -z "$(git status --porcelain)" ]]; then
  ok "working tree clean; nothing to commit"
else
  forbidden="$(git status --porcelain --untracked-files=all | cut -c4- | grep -E "$FORBIDDEN_IN_COMMIT" || true)"
  [[ -z "$forbidden" ]] || die "refusing to commit generated or secret files:
$forbidden
(add them to .gitignore)"
  git status --short --untracked-files=all
  echo
  COMMIT_MESSAGE="$(commit_message)"
  printf '%s\n' "$COMMIT_MESSAGE" | sed 's/^/    /'
  if confirm "Commit these $(git status --porcelain --untracked-files=all | wc -l | tr -d ' ') paths with the message above?"; then
    git add -A
    git commit --quiet -m "$COMMIT_MESSAGE"
    ok "committed $(git rev-parse --short HEAD)"
  elif ((DRY_RUN)); then
    note "dry run: not committing; steps 3-6 check the current tree"
  else
    die "aborted before committing"
  fi
fi

# -----------------------------------------------------------------------------
step "3. Preflight gate on the committed tree"
# -----------------------------------------------------------------------------
preflight_output="$(tool/release_preflight.sh --check 2>&1)" || true
summary="$(printf '%s\n' "$preflight_output" | sed -n 's/^Logs: //p; s/.*Summary: //p' | tail -1)"
[[ -n "$summary" ]] || { printf '%s\n' "$preflight_output"; die "preflight did not report a log location"; }
[[ -d "$summary" ]] && summary="$summary/summary.txt"
counts="$(grep -E '^failures=[0-9]+ warnings=[0-9]+$' "$summary" || true)"
if [[ "$counts" == "failures=0 warnings=0" ]]; then
  ok "preflight: 0 failures, 0 warnings ($summary)"
elif ((DRY_RUN)) && [[ "$counts" =~ ^failures=0 ]]; then
  note "preflight: $counts (warnings expected in a dry run on an uncommitted tree)"
else
  grep -E '^(FAIL|WARN)' "$summary" | sed 's/^/    /'
  die "preflight must pass with no failures and no warnings ($counts)"
fi

# -----------------------------------------------------------------------------
step "4. Push $BRANCH"
# -----------------------------------------------------------------------------
ahead="$(git rev-list --count "$REMOTE/$BRANCH..HEAD")"
if [[ "$ahead" -eq 0 ]]; then
  ok "$REMOTE/$BRANCH is up to date"
elif confirm "Push $ahead commit(s) to $REMOTE/$BRANCH?"; then
  git push "$REMOTE" "$BRANCH"
  ok "pushed $(git rev-parse --short HEAD) to $REMOTE/$BRANCH"
elif ((DRY_RUN)); then
  note "dry run: would push $ahead commit(s)"
else
  die "aborted before pushing"
fi

# -----------------------------------------------------------------------------
step "5. Publish to pub.dev (order: ${RELEASE[*]})"
# -----------------------------------------------------------------------------
published=()
for package in "${RELEASE[@]}"; do
  if on_pub_dev "$package"; then
    ok "$package $VERSION already on pub.dev; skipping"
    published+=("$package")
    continue
  fi
  if [[ "$package" == "flutter_react_embed" ]]; then
    # Its constraints only resolve once the leaves are served.
    for dependency in flutter_react_embed_platform_interface flutter_react_embed_android flutter_react_embed_ios; do
      if ((DRY_RUN)); then
        on_pub_dev "$dependency" || note "dry run: would wait for $dependency $(pubspec_version "$dependency") on pub.dev"
      else
        wait_for_pub_dev "$dependency"
      fi
    done
  fi
  if ! confirm "Publish $package $VERSION to pub.dev? This cannot be undone."; then
    ((DRY_RUN)) && { note "dry run: would run flutter pub publish in packages/$package"; continue; }
    die "aborted before publishing $package (earlier packages stay published; re-run to continue)"
  fi
  # Interactive: pub prints the archive and validation, then asks y/N itself.
  publish_args=()
  ((ASSUME_YES)) && publish_args+=(--force)
  (cd "packages/$package" && flutter pub publish ${publish_args[@]+"${publish_args[@]}"}) \
    || die "flutter pub publish failed for $package; fix and re-run"
  wait_for_pub_dev "$package"
  ok "$package $VERSION is live: https://pub.dev/packages/$package/versions/$VERSION"
  published+=("$package")
done

# -----------------------------------------------------------------------------
step "6. Tags"
# -----------------------------------------------------------------------------
if ((DRY_RUN)); then
  for package in "${RELEASE[@]}"; do note "dry run: would tag $package-v$VERSION"; done
else
  for package in "${published[@]}"; do
    tag="$package-v$VERSION"
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
      ok "tag $tag exists"
    else
      git tag -a "$tag" -m "$package $VERSION"
      ok "tagged $tag"
    fi
  done
  if confirm "Push the $VERSION tags to $REMOTE?"; then
    git push "$REMOTE" $(printf 'refs/tags/%s-v'"$VERSION"' ' "${published[@]}")
    ok "tags pushed"
  else
    note "tags created locally only; push later with: git push $REMOTE --tags"
  fi
fi

step "Done"
if ((DRY_RUN)); then
  ok "dry run finished; nothing was committed, pushed, published or tagged"
else
  for package in "${RELEASE[@]}"; do
    printf '    https://pub.dev/packages/%s/versions/%s\n' "$package" "$VERSION"
  done
fi
