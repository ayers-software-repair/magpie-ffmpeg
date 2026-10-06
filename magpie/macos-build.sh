#!/bin/bash
# Builds Magpie's FFmpeg on the Mac it runs on: arm64 gives macosarm64, x86_64 gives macos64.
#
# FFmpeg is the pinned release tarball from magpie-ffmpeg.json, checksum verified. The
# dependencies are built by markus-perl/ffmpeg-build-script (MIT) at the commit pinned
# below, patched by magpie/markus-perl.patch to build x264 and x265 under the GPL without
# its non-free mode, take the pinned tarball, stamp the Magpie version and add the GPL
# configure flags of variants/defaults-gpl.sh, which disable the disc libraries.
# Blu-ray is also never built (--disable=bluray); the script has no DVD libraries.
#
# Writes into artifacts/:
#   ffmpeg-<tag>-<target>-gpl-<series>.tar.xz  bin/ffmpeg, bin/ffprobe, LICENSE.txt, VERSION.txt
#   <target>-deps-src/                         every source archive the build downloaded,
#                                              and the build script at its pinned commit
# Bash 3.2 compatible: the macOS runners ship it.
set -eo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
# shellcheck source=SCRIPTDIR/vars.sh
. magpie/vars.sh
# FF_CONFIGURE and LICENSE_FILE, shared with the Windows and Linux builds.
# shellcheck source=SCRIPTDIR/../variants/defaults-gpl.sh
. variants/defaults-gpl.sh

MARKUS_REPO="https://github.com/markus-perl/ffmpeg-build-script.git"
MARKUS_COMMIT="db249ab80862368e910cfb281a38bef855110289"

case "$(uname -s)-$(uname -m)" in
Darwin-arm64) TARGET=macosarm64 ;;
Darwin-x86_64) TARGET=macos64 ;;
*)
    echo "This builds on macOS only, not $(uname -s) $(uname -m)." >&2
    exit 1
    ;;
esac
BUILD_NAME="ffmpeg-${MAGPIE_FFMPEG_TAG}-${TARGET}-gpl-${MAGPIE_FFMPEG_SERIES}"
TARBALL="${MAGPIE_TARBALL_URL##*/}"

# Outside the checkout: build-ffmpeg moves the .git of the folder it runs in aside.
WORK="$(mktemp -d)"
git clone --quiet --filter=blob:none "$MARKUS_REPO" "$WORK/ffmpeg-build-script"
git -C "$WORK/ffmpeg-build-script" checkout --quiet --detach "$MARKUS_COMMIT"
git -C "$WORK/ffmpeg-build-script" apply "$REPO_ROOT/magpie/markus-perl.patch"

export MAGPIE_TARBALL_URL MAGPIE_TARBALL_SHA256 MAGPIE_FFMPEG_TAG MAGPIE_EXTRA_VERSION
export MAGPIE_CONFIGURE_FLAGS="$FF_CONFIGURE"

# rav1e is left out because cargo fetches its crates during the build, so they would be
# missing from the published corresponding source. Magpie never encodes with it.
mkdir -p "$WORK/build"
(
    cd "$WORK/build"
    "$WORK/ffmpeg-build-script/build-ffmpeg" --build --skip-install \
        --ffmpeg-version="${MAGPIE_FFMPEG_TAG#n}" --disable=bluray,rav1e
)

PKG="$WORK/pkgroot/$BUILD_NAME"
mkdir -p "$PKG/bin" "$REPO_ROOT/artifacts"
cp "$WORK/build/workspace/bin/ffmpeg" "$WORK/build/workspace/bin/ffprobe" "$PKG/bin/"
cp "$WORK/build/packages/${TARBALL%.tar.*}/$LICENSE_FILE" "$PKG/LICENSE.txt"
echo "$MAGPIE_VERSION" >"$PKG/VERSION.txt"
# COPYFILE_DISABLE keeps macOS from adding ._ AppleDouble entries beside the folder.
COPYFILE_DISABLE=1 tar -C "$WORK/pkgroot" -cJf "$REPO_ROOT/artifacts/$BUILD_NAME.tar.xz" "$BUILD_NAME"

DEPS="$REPO_ROOT/artifacts/$TARGET-deps-src"
mkdir -p "$DEPS"
find "$WORK/build/packages" -maxdepth 1 -type f ! -name '*.done' ! -name "$TARBALL" -exec cp {} "$DEPS/" \;
git -C "$WORK/ffmpeg-build-script" archive --format=tar.gz --prefix=ffmpeg-build-script/ \
    -o "$DEPS/ffmpeg-build-script-$MARKUS_COMMIT.tar.gz" "$MARKUS_COMMIT"
cp "$REPO_ROOT/magpie/markus-perl.patch" "$DEPS/"

rm -rf "$WORK"
