#!/usr/bin/env bash
# Cut a release of this plugin: bump the version, commit, tag, push.
#
# Usage: scripts/release-plugin.sh minor|major
#
# Versions are `0.<major>.<minor>`:
#   minor   0.1.21 -> 0.1.22
#   major   0.1.21 -> 0.2.0
#
# The base version is the highest of the newest published `v*` release and the local
# `plugin.zig.zon` - so a version already bumped locally but never released is not
# silently released twice, and never goes backwards.
#
# `plugin.zig.zon` is the identity source of truth and the release CI requires the tag to
# equal its `.version`, so the bump is committed before the tag is created. Nothing is
# pushed until you confirm.
# ASCII only, on purpose: a non-ASCII character sitting directly against a `$VAR` inside a
# double quoted string gets scanned into the variable name by some bash/locale combinations.
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  minor|major) ;;
  *) echo "usage: $(basename "$0") minor|major" >&2; exit 2 ;;
esac

[[ -f plugin.zig.zon ]] || { echo "error: no plugin.zig.zon here." >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository." >&2; exit 1; }

# The release CI builds from a clean checkout of the tag, so a local-path SDK pin would
# fail there in a way that is confusing after the fact. Catch it before anything is pushed.
if grep -qE '^\s*\.path\s*=' <(sed -n '/\.fizzy = \.{/,/},/p' build.zig.zon); then
  echo "error: build.zig.zon pins the fizzy SDK by local .path." >&2
  echo "       CI builds from the tag and cannot resolve it. Run the \"update fizzy\" task" >&2
  echo "       (or scripts/update-fizzy-sdk.sh) to repin by URL+hash first." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty - commit or stash first." >&2
  git status --short >&2
  exit 1
fi

REPO_SLUG="$(git remote get-url origin | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

ZON_VERSION="$(sed -nE 's/^[[:space:]]*\.version = "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' plugin.zig.zon | head -1)"
[[ -n "$ZON_VERSION" ]] || { echo "error: could not read .version from plugin.zig.zon" >&2; exit 1; }

echo "Looking up the newest release of ${REPO_SLUG} ..."
LOOKUP_OK=1
RELEASE_VERSION="$(
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "https://api.github.com/repos/${REPO_SLUG}/releases?per_page=100" \
  | python3 -c '
import json, re, sys
best = (0, 0, 0)
for r in json.load(sys.stdin):
    if r.get("draft"):
        continue
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", r.get("tag_name", ""))
    if m:
        best = max(best, tuple(int(g) for g in m.groups()))
print("%d.%d.%d" % best)
' 2>/dev/null || { LOOKUP_OK=0; echo "0.0.0"; }
)"

# A network hiccup or a private repo must not silently look like "no releases yet" - that would
# quietly base the bump on plugin.zig.zon alone and could reuse a version already published.
if [[ "$LOOKUP_OK" == "0" ]]; then
  echo "warning: could not read releases for ${REPO_SLUG}; basing the bump on plugin.zig.zon alone." >&2
fi

NEW_VERSION="$(python3 - "$ZON_VERSION" "$RELEASE_VERSION" "$MODE" <<'PY'
import sys
zon, rel, mode = sys.argv[1], sys.argv[2], sys.argv[3]
base = max(tuple(int(p) for p in zon.split(".")), tuple(int(p) for p in rel.split(".")))
epoch, major, minor = base
if mode == "minor":
    minor += 1
else:
    major += 1
    minor = 0
print(f"{epoch}.{major}.{minor}")
PY
)"

TAG="v$NEW_VERSION"

echo
echo "  repo            $REPO_SLUG"
echo "  branch          $BRANCH"
echo "  latest release  ${RELEASE_VERSION:-none}"
echo "  plugin.zig.zon  $ZON_VERSION"
echo "  releasing       $NEW_VERSION  ($MODE)"
echo

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists locally." >&2
  exit 1
fi

echo "This will commit the version bump, tag $TAG, and push both to origin."
read -r -p "Continue? [y/N] " reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Aborted."; exit 1; }

# Rewrite only the first `.version` line - `min_sdk_version` must not be touched.
python3 - "$NEW_VERSION" <<'PY'
import re, sys
new = sys.argv[1]
src = open("plugin.zig.zon").read()
out, n = re.subn(r'(^\s*\.version = ")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{new}\g<2>', src, count=1, flags=re.M)
if n != 1:
    sys.exit("failed to rewrite .version in plugin.zig.zon")
open("plugin.zig.zon", "w").write(out)
PY

git add plugin.zig.zon
git commit -m "$TAG"
git tag -a "$TAG" -m "$TAG"

git push origin "$BRANCH"
git push origin "$TAG"

echo
if git remote get-url origin | grep -q 'github\.com'; then
  echo "Pushed ${TAG}. Release CI: https://github.com/${REPO_SLUG}/actions"
else
  echo "Pushed ${TAG}."
fi
