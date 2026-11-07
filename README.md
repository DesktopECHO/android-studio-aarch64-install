# Android Studio for Linux ARM64

Unofficial Android Studio packaging for glibc-based Linux ARM64 systems. The
installer combines the Android Studio distribution with the full ARM64 JetBrains
Runtime SDK (including `jlink`), ARM64 IntelliJ platform native components, ARM64
FFmpeg/JavaCPP natives for device mirroring, an ARM64 Android SDK and NDK from [@HomuHomu833](https://github.com/HomuHomu833), and native rendering
libraries for the XML Layout Editor and Compose Preview. It also installs the
JetBrains-patched ARM64 clangd bundle from the matching CLion release for NDK
code insight.

The installer does not include an emulator. Developers using Apple Silicon users can run the [Ika Android Emulator](https://github.com/DesktopECHO/ika), or a physical Android device can also be used to run and debug applications.

The installer targets Debian 13, Ubuntu 26.04, Fedora 44, and Arch Linux ARM on ARM64 (`aarch64`), and has
been successfully tested on [Asahi Linux](https://asahilinux.org/) and in
Android chroot environments like [Trixie.apk](https://github.com/DesktopECHO/trixie.apk).

## Why This Project Exists

Google does not support Android Studio on Linux ARM64.
Existing community ports could launch the IDE by replacing the JetBrains Runtime,
but no ARM64 replacements were available for the native rendering libraries. As
a result, the XML Layout Editor and Compose Preview remained completely broken.
This project integrates the ARM64 runtime and the SDK and NDK tools. It also
supplies the rebuilt layoutlib libraries and ARM64 clangd tooling required for
a complete developer workflow.

**This is an unofficial port and is not supported by Google or JetBrains.**

## Install Android Studio

Install Git (and, optionally, the distro-provided `adb`; otherwise the ARM64
`adb` from the bundled SDK is used):

```bash
# Debian/Ubuntu
sudo apt install adb git

# Fedora/Red Hat
sudo dnf install android-tools git

# Arch Linux ARM
sudo pacman -S --needed android-tools git file
```

Clone the repository and run the installer as the desktop user, not as root:

```bash
git clone https://github.com/DesktopECHO/android-studio-aarch64-install.git
cd android-studio-aarch64-install
./android-studio-aarch64-install.sh
```

Available options:

```text
--dry-run    Verify download URLs without installing
--no-launch  Complete the install without starting Android Studio
--yes        Skip the confirmation prompt
--help       Show command help
```

The default locations can be changed with environment variables:

```text
INSTALL_DIR       Android Studio parent directory
AS_ROOT_DIR       Android Studio installation directory
ANDROID_SDK_ROOT  Android SDK directory
NDK_DIR           Android NDK parent directory
CACHE_DIR         Download cache
```

The installer preserves an existing Android Studio directory as a timestamped
backup, creates a desktop entry, and installs a `bin/studio` launcher that, while
Android Studio runs, replaces any x86_64 `platform-tools/adb`, `aapt2` or
`zipalign` installed by the SDK Manager with ARM64 copies kept in
`bin/arm64-sdk-tools/`. It installs the
bundled ARM64 Layout Editor and Compose Preview libraries, and configures a
per-user ARM64 `aapt2` override in `~/.gradle/gradle.properties` while
suppressing its AGP experimental-option warning. It downloads the matching
CLion ARM64 archive and copies only its clang tooling into Android Studio's
`cidr-clangd` plugin.

## Pinned Components

| Component | Version | Source |
| --- | --- | --- |
| Android Studio | 2026.2.2.9 (Rabbit 2 Patch 1, platform 262.10968.63) | Google |
| IntelliJ IDEA (native donor) | 2026.2.3 (262.10968.63) | JetBrains |
| JetBrains Runtime SDK | 25.0.4 b508.27 (same build Android Studio bundles) | JetBrains |
| CLion (clangd donor) | 2026.2.3 | JetBrains |
| bytedeco FFmpeg / JavaCPP | 7.1.1-1.5.12 / 1.5.12 `linux-arm64` | Maven Central |
| Android SDK | 37.0.0 (build-tools 37.0.0, platform-tools 37.0.1) | HomuHomu833 (mirrored) |
| Android NDK | r30 (30.0.16248370) | HomuHomu833 |

Why the extra components:

- **JBR SDK**: IntelliJ IDEA bundles a trimmed runtime without `jdk.jlink`,
  `jdk.jartool` and `jdk.jdeps`. AGP runs `jlink` (JdkImageTransform) with the
  Gradle JDK, which defaults to Android Studio's embedded `jbr`, so the full JBR
  SDK is installed instead.
- **FFmpeg/JavaCPP**: device mirroring decodes the video stream with bytedeco
  FFmpeg (`libjniavutil.so`, `libjniavcodec.so`, ...). Android Studio only ships
  the `linux-x86_64` jars; the installer swaps in the `linux-arm64` jars and
  updates `product-info.json`. Studio's optional native `libvideo_decoder.so` is
  x86_64-only, so it logs a fallback to FFmpeg, which is expected.

## Known Limitations

These bundled host tools are Google-built x86_64 binaries without ARM64 Linux
equivalents and remain non-functional:

- Native (LLDB) debugging: `plugins/android-ndk/resources/lldb`
- CPU/system trace analysis in the Profiler: `trace_processor_daemon`,
  `trace-processor`, `traceconv`, host `simpleperf`
- Gemini local models (`llama.cpp`), the `android` CLI, and the WebP image
  plugin's `libwebp_jni.so`
- The Android Emulator

## Layout/Compose Engine

`build-layoutlib-arm64.sh` builds the Linux ARM64 native libraries used by both
Android Studio rendering paths:

- `layoutlib_jni.so`
- `libandroid_runtime.so`

Prebuilt copies are stored directly in `lib/`. The installer copies these
libraries and never runs `build-layoutlib-arm64.sh`. _Run this build script only
if you need to regenerate them_.

### Build requirements

- Native Debian or Fedora ARM64 host using glibc
- At least 120 GiB of free storage for a new Android source workspace
- A network connection for AOSP and toolchain downloads
- An interactive terminal with `sudo` access for prerequisite installation

The script installs the required distro packages and fetches the Android `repo`
tool, the `android17-release` source snapshot, pinned ARM64 Clang, Go, and Rust
toolchains, and a verified Debian 13 ARM64 glibc link-time sysroot. The sysroot keeps
Fedora-built artifacts compatible with Debian 13. Downloads and Git checkouts
are reused between builds.

Validate a new build host without downloading Android source:

```bash
chmod +x build-layoutlib-arm64.sh
./build-layoutlib-arm64.sh --setup-only
```

Start a complete build in the default `$HOME/layoutlib` workspace:

```bash
./build-layoutlib-arm64.sh
```

Use `--workspace DIR` or `LAYOUTLIB_WORKSPACE` to select another workspace.

Reuse an existing audited Soong/Ninja graph for a faster rebuild:

```bash
./build-layoutlib-arm64.sh --build-only
```

Verified artifacts are written to `lib/` by default. Use `--output DIR` or
`LAYOUTLIB_OUTPUT_DIR` to publish them elsewhere.

## Build Notes

The Layout/Compose build uses a coherent Android 17 source snapshot plus the
checked-in `layoutlib-build-support.tar.gz` archive. The source checkout is
dedicated to this build because the script applies ARM64 host fixes and a reduced
Soong module graph directly to the tree.

Before publication, both outputs are validated as AArch64 ELF files, checked for
glibc linkage and a maximum required symbol version of `GLIBC_2.41`, and tested
for unresolved dynamic dependencies. Debug sections are removed so each library
remains below GitHub's 100 MiB regular-file limit. The default parallelism is
selected automatically from the host's available CPU count.

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/9f6dde6c-2001-42f2-9823-0597f11db412" />
