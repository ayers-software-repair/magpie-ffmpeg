#!/bin/bash
# Writes magpie/mirror.json from the archives attached to release <tag>: the mirror every build
# tries before an archive's upstream. Each sha256 is the digest GitHub reports for the asset, so
# the list names only files that release really serves. Leaves out the built FFmpeg archives,
# the .tar.part bundles and checksums.sha256. See README.md, Download mirror.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?Usage: magpie/mirror-list.sh <release tag>}"
REPO="ayers-software-repair/magpie-ffmpeg"
LIST="magpie/mirror.json"

ID="$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id)"
gh api --paginate --slurp "repos/$REPO/releases/$ID/assets?per_page=100" |
    jq -S --arg url "https://github.com/$REPO/releases/download/$TAG" '
        [.[][] | select(.name | test("^checksums\\.sha256$|\\.tar\\.part[0-9]+$|^ffmpeg-n[0-9.]+-[a-z0-9]+-gpl-") | not)]
        | if length == 0 then error("release attaches no archives") else . end
        | map(if (.digest // "" | test("^sha256:[0-9a-f]{64}$")) then {key: .name, value: .digest[7:]}
              else error("no sha256 digest for \(.name)") end)
        | {url: $url, archives: from_entries}' >"$LIST.tmp"
mv "$LIST.tmp" "$LIST"
echo "$LIST: $(jq '.archives | length' "$LIST") archives from $TAG"
