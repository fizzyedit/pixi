#!/usr/bin/env bash
# Point this plugin's `.fizzy` dependency at either a local fizzy checkout or the newest
# published SDK release.
#
#   scripts/fizzy-sdk.sh local     .path = ../../fizzy/sdk   (test unreleased SDK changes)
#   scripts/fizzy-sdk.sh latest    .url + .hash              (what CI and publishing need)
#
# Override the checkout location with FIZZY_SDK_PATH, and the source repo with FIZZY_SDK_REPO.
#
# `latest` deliberately pins the release *asset*, never the tag's source archive: the archive
# is the whole fizzy monorepo, whose root build.zig.zon carries app-only dependencies
# (Velopack and friends) that a plugin must never pull in. See docs/PLUGINS.md section 2.3.
#
# ASCII only, on purpose. A non-ASCII character sitting directly against a `$VAR` in a double
# quoted string gets scanned into the variable name by some bash/locale combinations, which is
# what "REPO...: unbound variable" was.
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  local|latest) ;;
  *) echo "usage: $(basename "$0") local|latest" >&2; exit 2 ;;
esac

[[ -f build.zig.zon ]] || { echo "error: no build.zig.zon here - run from the plugin repo root." >&2; exit 1; }

REPO="${FIZZY_SDK_REPO:-fizzyedit/fizzy}"
SDK_PATH="${FIZZY_SDK_PATH:-../../fizzy/sdk}"

STRIP_PY='
import re, sys
src = open("build.zig.zon").read()
# Only strips a comment block directly above the entry when it is the banner `local` mode wrote,
# so a hand-written comment about the dependency survives.
pattern = r"(?:[ \t]*//[^\n]*LOCAL SDK[^\n]*\n(?:[ \t]*//[^\n]*\n)*)?[ \t]*\.fizzy = \.\{.*?\n[ \t]*\},\n"
out, n = re.subn(pattern, sys.argv[1], src, count=1, flags=re.S)
if n != 1:
    sys.exit("error: could not find a .fizzy dependency entry in build.zig.zon")
open("build.zig.zon", "w").write(out)
'

if [[ "$MODE" == "local" ]]; then
  if [[ ! -f "${SDK_PATH}/build.zig.zon" ]]; then
    echo "error: no fizzy SDK at ${SDK_PATH} (looked for ${SDK_PATH}/build.zig.zon)." >&2
    echo "       Set FIZZY_SDK_PATH if your checkout lives elsewhere." >&2
    exit 1
  fi

  REPLACEMENT="        // LOCAL SDK: testing against an unreleased fizzy checkout.
        // Run the \"fizzy sdk: use latest release\" task before publishing - CI builds from
        // a clean checkout of the tag and cannot resolve a local path.
        .fizzy = .{
            .path = \"${SDK_PATH}\",
        },
"
  python3 -c "${STRIP_PY}" "${REPLACEMENT}"

  echo "build.zig.zon now points at the local SDK: ${SDK_PATH}"
  echo "Build to confirm:  zig build"
  exit 0
fi

echo "Looking up the latest SDK release of ${REPO} ..."

RESULT="$(
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "https://api.github.com/repos/${REPO}/releases?per_page=100" \
  | python3 -c '
import json, sys
# sdk-v* releases are interleaved with the app own v* releases, so /releases/latest would
# usually hand back an app release. Filter instead.
for r in json.load(sys.stdin):
    tag = r.get("tag_name", "")
    if not tag.startswith("sdk-v") or r.get("draft"):
        continue
    for a in r.get("assets", []):
        name = a.get("name", "")
        if name.startswith("fizzy-sdk-v") and name.endswith(".tar.gz"):
            print(tag, a["browser_download_url"])
            sys.exit(0)
sys.exit("no sdk-v* release with a fizzy-sdk-v*.tar.gz asset found")
'
)" || { echo "error: could not resolve a published SDK release." >&2; exit 1; }

TAG="${RESULT%% *}"
ASSET_URL="${RESULT#* }"

echo "Latest SDK: ${TAG}"
echo "Fetching  : ${ASSET_URL}"
echo "(downloads the tarball to compute its hash - give it a moment)"

# Drop the existing .fizzy entry before fetching. `zig fetch --save` overwrites the *value* of
# an entry that already exists but keeps its field name, so running this over a local pin
# produced `.path = "https://.../fizzy-sdk-v0.1.51.tar.gz"` - a path pointing at a URL, with no
# hash at all. Removing the entry first makes --save write a clean `.url` + `.hash` pair.
BACKUP="$(mktemp)"
cp build.zig.zon "${BACKUP}"
trap 'cp "${BACKUP}" build.zig.zon; rm -f "${BACKUP}"' EXIT

python3 -c "${STRIP_PY}" ""

zig fetch --save=fizzy "${ASSET_URL}"

ENTRY="$(sed -n '/\.fizzy = \.{/,/},/p' build.zig.zon)"
case "$ENTRY" in
  *.hash*) ;;
  *) echo "error: the .fizzy entry has no .hash after fetching - not safe to publish." >&2; exit 1 ;;
esac

# Fetch succeeded and the entry looks right - keep it.
trap - EXIT
rm -f "${BACKUP}"

echo
echo "build.zig.zon now pins ${TAG}. Build to confirm the ABI fingerprint still matches:"
echo "    zig build"
