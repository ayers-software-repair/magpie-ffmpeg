#!/bin/bash
# shellcheck disable=SC2034 # every variable here is read by the scripts that source this file
# Sourced. Reads the FFmpeg pin, magpie-ffmpeg.json at the repository root, into
# MAGPIE_* variables. Bash 3.2 compatible: the macOS runners still ship it.

MAGPIE_PIN_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/magpie-ffmpeg.json"

magpie_pin() {
    jq -r "$1 // empty" "$MAGPIE_PIN_FILE" | tr -d '\r'
}

MAGPIE_FFMPEG_TAG="$(magpie_pin .tag)"
MAGPIE_FFMPEG_COMMIT="$(magpie_pin .commit)"
MAGPIE_TARBALL_URL="$(magpie_pin .tarball_url)"
MAGPIE_TARBALL_SHA256="$(magpie_pin .tarball_sha256)"
MAGPIE_REVISION="$(magpie_pin .revision)"

if ! [[ $MAGPIE_FFMPEG_TAG =~ ^n[0-9]+\.[0-9]+(\.[0-9]+)?$ &&
    $MAGPIE_FFMPEG_COMMIT =~ ^[0-9a-f]{40}$ &&
    $MAGPIE_TARBALL_URL == https://* &&
    $MAGPIE_TARBALL_SHA256 =~ ^[0-9a-f]{64}$ &&
    $MAGPIE_REVISION =~ ^[1-9][0-9]*$ ]]; then
    echo "magpie-ffmpeg.json is incomplete or malformed: $MAGPIE_PIN_FILE" >&2
    return 1
fi

# n8.1.3 -> 8.1, the addin this tag belongs to.
MAGPIE_FFMPEG_SERIES="${MAGPIE_FFMPEG_TAG#n}"
MAGPIE_FFMPEG_SERIES="$(cut -d. -f1-2 <<<"$MAGPIE_FFMPEG_SERIES")"
MAGPIE_EXTRA_VERSION="magpie.${MAGPIE_REVISION}"
# The version banner and VERSION.txt token, e.g. n8.1.3-magpie.1.
MAGPIE_VERSION="${MAGPIE_FFMPEG_TAG}-${MAGPIE_EXTRA_VERSION}"
# The release tag that publishes this pin, e.g. 8.1.3-1.
MAGPIE_RELEASE_TAG="${MAGPIE_FFMPEG_TAG#n}-${MAGPIE_REVISION}"
