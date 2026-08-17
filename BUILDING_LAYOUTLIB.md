# How the ARM64 Layout Libraries Were Built

Getting Android Studio to launch on Linux ARM64 was a good start. The IDE opened,
Gradle worked, and projects could build, but the XML Layout Editor and Compose
Preview were still broken. Both features were trying to load native x86_64
libraries from the Android Studio installation.

The missing files were `layoutlib_jni.so` and `libandroid_runtime.so`. They had to
be rebuilt for ARM64 from the same Android source snapshot. Replacing only one
does not work because `layoutlib_jni.so` depends on `libandroid_runtime.so`, and
the two libraries need to agree on the Android framework ABI.

`layoutlib_jni.so` is the native bridge used by Android Studio's layoutlib
renderer. It allows Studio to load Android resources and render an interface on
the host without running the application on a phone. `libandroid_runtime.so`
provides the native Android framework code needed by that bridge. Compose Preview
uses the same rendering stack, so fixing these files fixes both preview systems.

## Using One Source Snapshot

The build uses the AOSP `android17-release` branch. The `repo` tool creates a shallow partial
clone under `$HOME/layoutlib/src`. Even with a partial clone, AOSP and its build
output need a lot of disk space: 120 GiB for a new workspace.

The build runs natively on ARM64 Linux. It is not an x86_64 cross-build and it
does not use a container. Every host tool launched by Soong also has to run on
ARM64. The script installs the required Debian or Fedora packages and uses the
CPU count reported by `nproc` for parallel builds.

## Replacing the x86_64 Host Tools

AOSP assumes that Linux host tools live in x86_64 prebuilt directories. That
assumption had to be replaced carefully rather than changing every path in the
tree.

The build uses these pinned ARM64 tools:

- Android Clang commit `198cef08637a6133e98b4a80e36f0ca35775fa9a`
- Android Go commit `85088d1ab9a678cc8531f9cc05de9fa802f91c58`
- Rust 1.88.0 for `aarch64-unknown-linux-gnu`
- Native ARM64 Ninja

Rust needed wrappers because Soong expects the layout and arguments used by the
AOSP Rust prebuilt. The wrappers put the GNU ARM64 compiler and Clippy driver
where Soong expects to find them. The matching `Android.bp` file disables Rust
targets that are unrelated to the host layout renderer.

The `layoutlib-build-support.tar.gz` file contains the rest of the known-good
build setup. It includes the Soong bootstrap files, the reduced module list,
native blueprint replacements, and AIDL, HIDL, and test overlays. Most of those
overlays remove device products, tests, fuzzers, and unrelated tools from the
graph. The archive does not contain the compiler or the finished `.so` files.

## Reducing the Soong Graph

Building a complete `aosp_arm64` product would take forever. Layoutlib is a
host library, but a normal AOSP product graph pulls in thousands of device-only
modules that have nothing to do with Android Studio. 

The successful build isolates `layoutlib_jni` from the full product graph. Soong
runs partial analysis with `layoutlib_jni` as the target and writes a dedicated
Ninja file. Before compiling anything, Ninja audits the complete reachable graph
in dry-run mode with `-k0`. If an input is missing, the script stops there instead
of finding out halfway through a long compile.

The final Ninja target is:

```text
layoutlib_jni-linux_glibc_arm64_shared-install
```

This target builds the native framework dependencies, links
`libandroid_runtime.so`, and then links `layoutlib_jni.so` against it.

## Fixing the ARM64 Host Assumptions

This Android source branch forces Linux ARM64 hosts into the musl configuration,
even when `HostMusl` is false. Android Studio on Debian and Fedora needs glibc, so
the build changes that selection and uses the normal `HostMusl` setting. For this
build, `HostMusl` is explicitly disabled.

There were several smaller host problems after that:

- Fedora's fortify settings produced warnings that AOSP treated as fatal errors
  in host AIDL and HIDL tools.
- AOSP's Python launcher cleared `sys.executable`, which breaks under Python
  3.14. The old behavior is now limited to earlier Python versions.
- Android code used `memset_explicit`, while glibc provides `explicit_bzero` for
  this job.
- New Fedora headers emitted a call to `__inet_ntop_chk`, but that symbol was not
  available in the Debian runtime used as the compatibility baseline.

The `GlibcCompat.cpp` source handles the last case without disabling fortify for
the whole build. These changes apply only to the Linux host build. Android device
code is not modified.

## Keeping the Result Portable

The first libraries that linked successfully on Fedora still did not work on
Debian 13. They picked up symbols from Fedora's newer glibc and required glibc
2.42 or 2.43. That was a valid Fedora build, but it was not a useful distributable
build.

The build now links against a Debian 13 ARM64 sysroot. The script downloads the
Debian Trixie package index and selects these packages:

- `libc6`
- `libc6-dev`
- `libgcc-s1`
- `linux-libc-dev`

Each package is checked against the SHA-256 value published in the Debian index
before it is extracted. Soong receives the sysroot paths plus the host compiler's
specific GCC runtime directory. It does not receive Fedora's general system
library directory, because that could silently bring the newer glibc dependency
back.

The compiler still runs natively on the build host. The Debian files are only
the link-time ABI baseline. The finished libraries currently require no symbol
newer than `GLIBC_2.38`. The script rejects a future build if it requires anything
newer than `GLIBC_2.41`, which is the Debian 13 limit used by this project.

## Checking the Finished Files

Before the files are published, the script checks that both are 64-bit AArch64 ELF shared objects, both link to glibc instead of musl, neither exceeds the glibc version limit, and `ldd` reports no missing dependencies.

The raw build includes a large amount of DWARF debug data. The script removes
only the debug sections with `strip --strip-debug`. The exported dynamic symbols
do not change. This reduced `libandroid_runtime.so` from about 106 MiB to about
32 MiB, allowing both libraries to be stored directly in Git instead of Git LFS.
The script also rejects either file if it exceeds GitHub's 100 MiB file limit.

The files currently included with the installer are:

| Library | Size | SHA-256 |
| --- | ---: | --- |
| `layoutlib_jni.so` | 1,186,384 bytes | `8dab77938b9692a199d5dc4452446cbd154cb20e12fef3fe84feccb20ddc5bb5` |
| `libandroid_runtime.so` | 33,463,832 bytes | `12db3051512c8d11c0bbc6b312b292054fd5725c2279607753ab473a645cb11d` |

The stripped files were tested on Debian 13 and Asahi Fedora 44. They kept the same dynamic symbols
as the unstripped build, required no symbol newer than `GLIBC_2.38`, and loaded
without a missing dependency.

## Installing Them in Android Studio

The build script writes the files to `lib/`. The Android Studio installer does
not run the build script. It validates the prebuilt ARM64 files and copies them
over the x86_64 versions in:

```text
plugins/design-tools/resources/layoutlib/data/linux/lib64
```

Android Studio already looks in that directory for the Linux rendering runtime,
so no project-level setting is needed. Once both ARM64 files are in place, the
XML Layout Editor and Compose Preview can load the native rendering stack.

The point of the build script is repeatability. Most users should never need to
download AOSP or build these libraries. If Android Studio moves to a new
layoutlib source version, the script can recreate the toolchain, apply the same
host fixes, rebuild the reduced graph, check portability, and produce a new pair
of files without repeating the original trial-and-error process.
