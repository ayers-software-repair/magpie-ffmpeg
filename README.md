# Magpie FFmpeg

Ayers Electronics' build of FFmpeg for Magpie. This repository is a fork of
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds). The build recipe keeps BtbN's MIT
licence (`LICENSE`). The FFmpeg binaries it produces are licensed under the GNU GPL version 3,
which every archive carries as `LICENSE.txt`.

## What differs from upstream

- **No disc reading.** libdvdcss, libdvdread, libdvdnav and libbluray are removed from the recipe,
  with libudfread, which only libbluray used. Every build is configured with
  `--disable-libdvdread --disable-libdvdnav --disable-libbluray`. All four go because libdvdread
  loads libdvdcss at run time when it is not linked in, and libbluray loads libaacs and libbdplus
  the same way. Magpie reads no discs.
- **No rav1e.** Its build fetches Rust crates from the network, so its full source could not be
  published with a release. Magpie never encodes AV1; dav1d, which decodes it, stays. rav1e's
  script goes, with `55-rustdedup.sh`, which only existed to pair it with librsvg, and every build
  is configured with `--disable-librav1e`.
- **One pinned FFmpeg.** `magpie-ffmpeg.json` holds the FFmpeg tag, its commit, the release
  tarball's sha256 and a revision number. `build.sh` builds exactly that tag and stops if the
  checkout is any other commit.
- **A fixed version.** The banner reads `ffmpeg version n8.1.3-magpie.1` (the tag, then `magpie.`
  and the revision) instead of a build date. Each archive carries the same token in `VERSION.txt`.
- **Six targets.** win64, winarm64, linux64 and linuxarm64 come from BtbN's `gpl 8.1` recipe.
  macOS Intel (`macos64`) and Apple silicon (`macosarm64`) are built natively by
  `magpie/macos-build.sh`, using markus-perl/ffmpeg-build-script (MIT) at a pinned commit with
  `magpie/markus-perl.patch`.
- **Releases only from a tag.** No schedule, no floating `latest` release, no pruning, and a
  release is never overwritten.
- **Every archive is proven before release** by `magpie/verify-build.sh`, run on the archive's own
  platform. Run it on a downloaded archive the same way: `magpie/verify-build.sh <archive>`. Add
  `--static` on a machine that cannot run that archive; it then checks everything that does not
  execute the binaries.

## Cutting a release

1. Set `magpie-ffmpeg.json`. A new FFmpeg tag takes its commit, its tarball sha256 and revision 1.
   A rebuild of the same tag raises the revision.
2. Push a tag named `<version>-<revision>`, for example `8.1.3-1`. The workflow refuses a tag that
   does not match `magpie-ffmpeg.json`, and a tag that already has a release.
3. The workflow builds the six archives, verifies each one, and publishes one release under the tag.

A manual run (Actions, Build FFmpeg, Run workflow) builds and verifies the chosen targets and keeps
the archives as workflow artifacts. It publishes nothing. The `macos-intel` and `macos` choices
build only the Mac archives.

## Corresponding source

Each release carries the source of its binaries:

- the FFmpeg release tarball;
- `magpie-ffmpeg-<tag>-deps-src.tar.part*`: the dependency sources the Windows and Linux builds
  mounted, exactly as the recipe downloaded them before building;
- `magpie-ffmpeg-<tag>-macos-deps-src.tar.part*`: every source archive the macOS builds
  downloaded, with their build script at its pinned commit and Magpie's patch to it.

Join the parts with `cat`, then untar. The recipe itself is this repository at the release tag.
Each archive inside the parts is also attached to the release on its own; those copies are the
download mirror below.

## Download mirror

Every build fetches each dependency archive from an earlier release of this repository first and
from its upstream second. `magpie/mirror.json` names that release (`url`) and the sha256 of each
archive it serves (`archives`). A mirror copy is used only when it matches its sha256. An upstream
download is checked by the recipe's own pin: a pinned commit for the Windows and Linux builds,
whose archives are fresh tarballs of a clone and never byte-identical, and the package checksum
for the macOS builds, or the listed sha256 where the package has none. With the mirror
unreachable, a build downloads everything from upstream as it did before the mirror existed.

The build log names every archive the mirror did not serve, in lines starting `mirror:`. An
archive is missing from the list when its recipe changed since the mirror release: a new BtbN pin,
a changed stage script or a new markus-perl commit.

To refresh the mirror after such a change:

1. Cut the release as usual. Its build downloads the changed archives from upstream, and the
   release attaches every archive the build used.
2. Run `magpie/mirror-list.sh <that release's tag>`. It rewrites `magpie/mirror.json` from the
   release's asset list, using the sha256 digest GitHub reports for each asset, and downloads
   nothing.
3. Commit `magpie/mirror.json`. The next build reads every archive from that release.

The list is read when a build downloads, not cached. Changing it does not invalidate the macOS
dependency cache or the download cache.

## Upstream recipe notes

The notes below are BtbN's, kept for the recipe's own use.

Windows builds are targetting Windows 7 and newer, provided UCRT is installed.
The minimum supported version is Windows 10 22H2, no guarantees on anything older.

Linux builds are targetting RHEL/CentOS 8 (glibc-2.28 + linux-4.18) and anything more recent.

### Package List

For a list of included dependencies check the scripts.d directory.
Every file corresponds to its respective package.

### How to make a build

#### Prerequisites

* bash
* docker

#### Build Image

* `./makeimage.sh target variant [addin [addin] [addin] ...]`

#### Build FFmpeg

* `./build.sh target variant [addin [addin] [addin] ...]`

In this fork `build.sh` always builds the tag pinned in `magpie-ffmpeg.json`, so the addin for its series (`8.1`) is required.

On success, the resulting zip file will be in the `artifacts` subdir.

#### Targets, Variants and Addins

Available targets:
* `win64` (x86_64 Windows)
* `win32` (x86 Windows)
* `linux64` (x86_64 Linux, glibc>=2.28, linux>=4.18)
* `linuxarm64` (arm64 (aarch64) Linux, glibc>=2.28, linux>=4.18)

The linuxarm64 target will not build some dependencies due to lack of arm64 (aarch64) architecture support or cross-compiling restrictions.

* `davs2` and `xavs2`: aarch64 support is broken.
* `libmfx` and `libva`: Library for Intel QSV, so there is no aarch64 support.

Available variants:
* `gpl` Includes all dependencies, even those that require full GPL instead of just LGPL.
* `lgpl` Lacking libraries that are GPL-only. Most prominently libx264 and libx265.
* `nonfree` Includes fdk-aac in addition to all the dependencies of the gpl variant.
* `gpl-shared` Same as gpl, but comes with the libav* family of shared libs instead of pure static executables.
* `lgpl-shared` Same again, but with the lgpl set of dependencies.
* `nonfree-shared` Same again, but with the nonfree set of dependencies.

All of those can be optionally combined with any combination of addins:
* `4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` to build from the respective release branch instead of master.
* `debug` to not strip debug symbols from the binaries. This increases the output size by about 250MB.
* `lto` build all dependencies and ffmpeg with -flto=auto (HIGHLY EXPERIMENTAL, broken for Windows, sometimes works for Linux)
