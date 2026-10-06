#!/bin/bash
# Proves a Magpie FFmpeg archive before it is published or pinned.
#
# Every archive, on any host:
#   - its name, single top folder, LICENSE.txt and VERSION.txt match magpie-ffmpeg.json;
#   - ffmpeg and ffprobe hold no DVD or Blu-ray decryption loader string
#     (dvdcss, libaacs, libbdplus), searched over the raw bytes, UTF-16 included;
#   - the configure line built into them disables libdvdread, libdvdnav, libbluray and
#     librav1e and enables none of them, nor nonfree.
# Unless --static, it also runs the binaries, so run it on the archive's own platform:
#   - the version banners of ffmpeg and ffprobe;
#   - -buildconf: the switches above and the libraries Magpie's playback needs;
#   - no dvdvideo demuxer, no bluray protocol;
#   - every encoder, filter, muxer, demuxer, protocol and hwaccel Magpie asks FFmpeg for;
#   - Magpie's live path end to end: a Matroska clip read with -readrate and a file,pipe
#     protocol whitelist, scaled and padded, encoded to H.264 and AAC, written as HLS
#     with MPEG-TS segments;
#   - on macOS: VideoToolbox encode and decode tried on the runner (reported, since a
#     runner may have no encoder hardware), libplacebo and vulkan reported, only system
#     libraries linked, native code for the target, and macOS 15 or lower required.
#
# Usage: magpie/verify-build.sh [--static] ARCHIVE...
# Exits non-zero when any check fails. Bash 3.2 compatible: the macOS runners ship it.

set -o pipefail

# shellcheck source=SCRIPTDIR/vars.sh
. "$(dirname "$0")/vars.sh" || exit 2

STATIC=0
if [[ $1 == --static ]]; then
    STATIC=1
    shift
fi
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [--static] ARCHIVE..." >&2
    exit 2
fi

# What Magpie asks FFmpeg for, on every platform.
ENCODERS="libx264 libx265 aac ac3 eac3 pcm_s16le srt webvtt mjpeg png"
FILTERS="loudnorm subtitles overlay gblur crop bwdif zscale tonemap colorspace
scale pad fps format hwupload tile setpts asetpts pan volume afade split eq setsar aformat
blackdetect testsrc2 anullsrc color"
MUXERS="hls mpegts mp4 adts image2 wav s16le webvtt null matroska"
DEMUXERS="matroska mov mpegts"
PROTOCOLS="file pipe http tcp"
# Libraries whose decoders, filters or encoders Magpie's playback relies on.
PLAYBACK_LIBS="libdav1d libvpx libopus libvorbis libmp3lame libwebp libopenjpeg libass
libfreetype libharfbuzz libzimg libsoxr libxml2 libx264 libx265"
DISC_LOADERS='dvdcss|libaacs|libbdplus'
# rav1e is out because cargo fetches its crates during its build, outside the published source.
REQUIRED_DISABLES="--disable-libdvdread --disable-libdvdnav --disable-libbluray --disable-librav1e"
FORBIDDEN_ENABLES="--enable-libdvdread --enable-libdvdnav --enable-libbluray --enable-librav1e --enable-nonfree"

FAILURES=0
fail() {
    echo "FAIL $*"
    FAILURES=$((FAILURES + 1))
}
pass() {
    echo "ok   $*"
}
note() {
    echo "note $*"
}

# Matching lines in a binary, NUL bytes dropped first so UTF-16LE text matches too.
count_pattern() {
    LC_ALL=C tr -d '\000' <"$2" | LC_ALL=C grep -a -c -i -E -e "$1"
}
count_fixed() {
    LC_ALL=C grep -a -c -F -e "$1" "$2"
}
# One name per line from a listing column; muxer and demuxer columns can be comma-separated.
names() {
    tr -d '\r' | awk -v col="$1" 'NF >= col { print $col }' | tr ',' '\n'
}
has() {
    grep -qx -F -e "$2" <<<"$1"
}
# need LABEL LIST NAME... : every NAME is in LIST.
need() {
    local label="$1" list="$2" missing="" name
    shift 2
    for name in "$@"; do
        has "$list" "$name" || missing="$missing $name"
    done
    if [[ -z $missing ]]; then
        pass "$label: $*"
    else
        fail "$label missing:$missing"
    fi
}
first_line() {
    head -n 1 <<<"$1" | tr -d '\r'
}

check_static() { # check_static BINARY_PATH LABEL
    local bin="$1" label="$2" n flag before
    n="$(count_pattern "$DISC_LOADERS" "$bin")"
    if [[ $n == 0 ]]; then
        pass "$label: no $DISC_LOADERS"
    else
        fail "$label: $n matches of $DISC_LOADERS"
    fi
    if [[ $(count_fixed "$MAGPIE_VERSION" "$bin") != 0 ]]; then
        pass "$label: carries $MAGPIE_VERSION"
    else
        fail "$label: does not carry $MAGPIE_VERSION"
    fi
    before=$FAILURES
    for flag in $REQUIRED_DISABLES; do
        [[ $(count_fixed "$flag" "$bin") != 0 ]] || fail "$label: configure line lacks $flag"
    done
    for flag in $FORBIDDEN_ENABLES; do
        [[ $(count_fixed "$flag" "$bin") == 0 ]] || fail "$label: configure line has $flag"
    done
    [[ $FAILURES == "$before" ]] && pass "$label: configure line has $REQUIRED_DISABLES, none of $FORBIDDEN_ENABLES"
}

check_banner() { # check_banner BINARY_PATH TOOL
    local out first
    if ! out="$("$1" -version 2>&1)"; then
        fail "$2 does not run on this host: $(first_line "$out")"
        return 1
    fi
    first="$(first_line "$out")"
    if [[ $first == "$2 version $MAGPIE_VERSION "* ]]; then
        pass "banner: $first"
    else
        fail "banner: $first"
    fi
}

# Magpie's live stream command shape, end to end, with the software H.264 encoder every
# target carries.
check_live_path() { # check_live_path FFMPEG DIR
    local ff="$1" d="$2" err
    if ! err="$("$ff" -hide_banner -loglevel error -f lavfi -i testsrc2=duration=2:size=1280x720:rate=30 \
        -f lavfi -i sine=duration=2 -c:v libx264 -c:a aac -f matroska "$d/clip.mkv" 2>&1)"; then
        fail "live path: making the Matroska test clip: $(first_line "$err")"
        return 1
    fi
    if err="$("$ff" -hide_banner -loglevel error -readrate 1 -readrate_initial_burst 1 \
        -protocol_whitelist file,pipe -i "$d/clip.mkv" -vf scale=640:360,pad=640:480:0:60 \
        -c:v libx264 -c:a aac -f hls -hls_segment_type mpegts -hls_time 1 "$d/live.m3u8" 2>&1)" &&
        grep -q '\.ts' "$d/live.m3u8"; then
        pass "live path: Matroska in with -readrate and a file,pipe whitelist, scale and pad, libx264 and aac, HLS with MPEG-TS segments"
    else
        fail "live path: $(first_line "$err")"
    fi
}

# VideoToolbox needs encoder hardware a hosted runner may lack, so these report, never fail;
# -encoders and -hwaccels above are the gate.
report_videotoolbox() { # report_videotoolbox FFMPEG CLIP
    local ff="$1" clip="$2" enc err
    for enc in h264_videotoolbox hevc_videotoolbox; do
        if err="$("$ff" -hide_banner -loglevel error -i "$clip" -an -c:v "$enc" -f null - 2>&1)"; then
            pass "$enc encodes on this runner's hardware"
        elif "$ff" -hide_banner -loglevel error -i "$clip" -an -c:v "$enc" -allow_sw 1 -f null - >/dev/null 2>&1; then
            note "$enc: no encoder hardware on this runner ($(first_line "$err")); it encoded through Apple's software encoder"
        else
            note "$enc cannot encode on this runner: $(first_line "$err"); prove it on a real Mac"
        fi
    done
    if err="$("$ff" -hide_banner -loglevel warning -hwaccel videotoolbox -i "$clip" -f null - 2>&1)" && [[ -z $err ]]; then
        pass "-hwaccel videotoolbox decodes on this runner"
    else
        note "-hwaccel videotoolbox on this runner: $(first_line "$err")"
    fi
}

check_run() { # check_run ROOT TARGET EXE_SUFFIX
    local ff="$1/bin/ffmpeg$3" target="$2" conf enc fil mux dem prot hw libs bad flag before
    local arch want_arch minos missing lib d
    local enc_extra="" fil_extra="libplacebo" hw_extra="vulkan" playback="$PLAYBACK_LIBS"
    case $target in
    linux64)
        enc_extra="h264_qsv hevc_qsv h264_nvenc hevc_nvenc h264_vaapi hevc_vaapi"
        hw_extra="$hw_extra cuda qsv vaapi"
        ;;
    linuxarm64)
        enc_extra="h264_nvenc hevc_nvenc h264_vaapi hevc_vaapi"
        hw_extra="$hw_extra cuda vaapi"
        ;;
    win64)
        enc_extra="h264_qsv hevc_qsv h264_nvenc hevc_nvenc"
        hw_extra="$hw_extra cuda qsv"
        ;;
    winarm64)
        # BtbN's recipe builds no libvpx for winarm64; FFmpeg's own vp8 and vp9 decoders play it.
        playback="$(tr ' ' '\n' <<<"$playback" | grep -vx libvpx)"
        ;;
    macos64 | macosarm64)
        # libplacebo and vulkan need MoltenVK at run time on a Mac: reported below, not required.
        enc_extra="h264_videotoolbox hevc_videotoolbox"
        fil_extra=""
        hw_extra="videotoolbox"
        ;;
    esac

    check_banner "$ff" ffmpeg || return
    check_banner "$1/bin/ffprobe$3" ffprobe

    conf="$("$ff" -hide_banner -buildconf 2>&1 | names 1)"
    before=$FAILURES
    for flag in $REQUIRED_DISABLES; do
        has "$conf" "$flag" || fail "-buildconf lacks $flag"
    done
    for flag in $FORBIDDEN_ENABLES; do
        has "$conf" "$flag" && fail "-buildconf has $flag"
    done
    [[ $FAILURES == "$before" ]] && pass "-buildconf has $REQUIRED_DISABLES, none of $FORBIDDEN_ENABLES"

    missing=""
    for lib in $playback; do
        has "$conf" "--enable-$lib" || missing="$missing $lib"
    done
    has "$conf" --enable-libfontconfig || has "$conf" --enable-fontconfig || missing="$missing libfontconfig"
    if [[ -z $missing ]]; then
        pass "-buildconf enables $(tr '\n' ' ' <<<"$playback")libfontconfig"
    else
        fail "-buildconf lacks playback libraries:$missing"
    fi

    dem="$("$ff" -hide_banner -demuxers 2>&1 | names 2)"
    prot="$("$ff" -hide_banner -protocols 2>&1 | names 1)"
    enc="$("$ff" -hide_banner -encoders 2>&1 | names 2)"
    fil="$("$ff" -hide_banner -filters 2>&1 | names 2)"
    mux="$("$ff" -hide_banner -muxers 2>&1 | names 2)"
    hw="$("$ff" -hide_banner -hwaccels 2>&1 | names 1)"

    if has "$dem" dvdvideo; then fail "demuxer dvdvideo is present"; else pass "no dvdvideo demuxer"; fi
    if has "$prot" bluray; then fail "protocol bluray is present"; else pass "no bluray protocol"; fi

    # shellcheck disable=SC2086 # the lists are space-separated names, split on purpose
    {
        need encoders "$enc" $ENCODERS $enc_extra
        need filters "$fil" $FILTERS $fil_extra
        need muxers "$mux" $MUXERS
        need demuxers "$dem" $DEMUXERS
        need protocols "$prot" $PROTOCOLS
        need hwaccels "$hw" $hw_extra
    }

    d="$WORK/run-$target"
    mkdir -p "$d"
    check_live_path "$ff" "$d"

    if [[ $target == macos* ]]; then
        [[ -f $d/clip.mkv ]] && report_videotoolbox "$ff" "$d/clip.mkv"
        if has "$fil" libplacebo && has "$hw" vulkan; then
            note "libplacebo filter and vulkan hwaccel are built in; they run only where MoltenVK is installed"
        else
            note "libplacebo or vulkan is not built in; the HDR tone-mapping route through libplacebo is unavailable, zscale and tonemap remain"
        fi
        if ! libs="$(otool -L "$ff" | tail -n +2 | awk '{ print $1 }')"; then
            fail "otool -L failed"
        else
            bad="$(grep -v -E '^(/usr/lib/|/System/Library/)' <<<"$libs")"
            if [[ -z $bad ]]; then pass "links only system libraries"; else fail "links outside the system: $bad"; fi
        fi
        # Native code for the target, never an arm64 binary under Rosetta or the reverse.
        arch="$(lipo -archs "$ff")"
        want_arch=x86_64
        [[ $target == macosarm64 ]] && want_arch=arm64
        if [[ $arch == "$want_arch" ]]; then pass "architecture $arch"; else fail "architecture '$arch', expected $want_arch"; fi
        # The owner's Mac runs macOS 15, so the minimum macOS must be 15 or lower.
        minos="$(otool -l "$ff" | awk '/LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { print $2; exit }')"
        if [[ -n $minos && ${minos%%.*} -le 15 ]]; then pass "minimum macOS $minos"; else fail "minimum macOS '$minos', must be 15 or lower"; fi
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for archive in "$@"; do
    name="$(basename "$archive")"
    base="${name%.zip}"
    base="${base%.tar.xz}"
    case $base in
    *-winarm64-*) target=winarm64 ;;
    *-win64-*) target=win64 ;;
    *-linuxarm64-*) target=linuxarm64 ;;
    *-linux64-*) target=linux64 ;;
    *-macosarm64-*) target=macosarm64 ;;
    *-macos64-*) target=macos64 ;;
    *)
        fail "$name: no known target in the name"
        continue
        ;;
    esac
    echo "== $name ($target)"

    exe=""
    ext="tar.xz"
    if [[ $target == win* ]]; then
        exe=".exe"
        ext="zip"
    fi
    want="ffmpeg-${MAGPIE_FFMPEG_TAG}-${target}-gpl-${MAGPIE_FFMPEG_SERIES}.${ext}"
    if [[ $name == "$want" ]]; then pass "name"; else fail "name $name, expected $want"; fi

    dir="$WORK/$target"
    mkdir -p "$dir"
    case $name in
    *.zip)
        if command -v unzip >/dev/null; then
            unzip -q "$archive" -d "$dir"
        else
            7z x -y -o"$dir" "$archive" >/dev/null
        fi
        ;;
    *.tar.xz) tar -xJf "$archive" -C "$dir" ;;
    *) false ;;
    esac || {
        fail "$name: cannot be extracted"
        continue
    }

    entries="$(ls -A "$dir")"
    if [[ $entries != "$base" ]]; then
        fail "archive must hold exactly the folder $base, holds: $(tr '\n' ' ' <<<"$entries")"
        continue
    fi
    root="$dir/$base"

    missing=""
    for f in "bin/ffmpeg$exe" "bin/ffprobe$exe" LICENSE.txt VERSION.txt; do
        [[ -f $root/$f ]] || missing="$missing $f"
    done
    if [[ -n $missing ]]; then
        fail "layout missing:$missing"
        [[ -f $root/bin/ffmpeg$exe && -f $root/bin/ffprobe$exe ]] || continue
    else
        pass "layout bin/ffmpeg$exe bin/ffprobe$exe LICENSE.txt VERSION.txt"
    fi

    if [[ -f $root/VERSION.txt ]]; then
        version="$(tr -d '\r' <"$root/VERSION.txt")"
        if [[ $version == "$MAGPIE_VERSION" ]]; then pass "VERSION.txt $version"; else fail "VERSION.txt is '$version', expected $MAGPIE_VERSION"; fi
    fi
    if [[ -f $root/LICENSE.txt ]] && grep -q 'GNU GENERAL PUBLIC LICENSE' "$root/LICENSE.txt" && grep -q 'Version 3' "$root/LICENSE.txt"; then
        pass "LICENSE.txt is GPL v3"
    else
        fail "LICENSE.txt is not the GPL v3 text"
    fi

    check_static "$root/bin/ffmpeg$exe" ffmpeg
    check_static "$root/bin/ffprobe$exe" ffprobe

    if [[ $STATIC == 1 ]]; then
        echo "--   --static: nothing executed; banner, -buildconf, listings, live path not checked"
    else
        check_run "$root" "$target" "$exe"
    fi
    rm -rf "$dir"
done

if [[ $FAILURES -gt 0 ]]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "all checks passed"
