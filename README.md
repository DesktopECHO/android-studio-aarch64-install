# Android Studio for Linux ARM64

Unofficial Android Studio packaging for glibc-based Linux ARM64 systems. The
installer combines the Android Studio distribution with the ARM64 JetBrains
Runtime and native components, an ARM64 Android SDK and NDK from [@HomuHomu833](https://github.com/HomuHomu833), and native rendering
libraries for the XML Layout Editor and Compose Preview. 

The installer does not include an emulator. Developers using Apple Silicon users can run the [Ika Android Emulator](https://github.com/DesktopECHO/ika), or a physical Android device can also be used to run and debug applications.

The installer targets Debian 13, Ubuntu 26.04, and Fedora 44 on ARM64 (`aarch64`), and has
been successfully tested on [Asahi Linux](https://asahilinux.org/) and in
Android chroot environments like [Trixie.apk](https://github.com/DesktopECHO/trixie.apk).

## Why This Project Exists

Google does not support Android Studio on Linux ARM64.
Existing community ports could launch the IDE by replacing the JetBrains Runtime,
but no ARM64 replacements were available for the native rendering libraries. As
a result, the XML Layout Editor and Compose Preview remained completely broken.
This project integrates the ARM64 runtime and the SDK and NDK tools. It also
supplies the rebuilt layoutlib libraries required for a complete developer
workflow.

**This is an unofficial port and is not supported by Google or JetBrains.**

## Install Android Studio

Install Git and the distro-provided `adb`:

```bash
# Debian/Ubuntu
sudo apt install adb git

# Fedora/Red Hat
sudo dnf install android-tools git
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
backup, creates a desktop entry, monitors the SDK's `platform-tools/adb` and
replaces it with the distro-provided version if it is not ARM64, installs the
bundled ARM64 Layout Editor and Compose Preview libraries, and configures a
per-user ARM64 `aapt2` override in `~/.gradle/gradle.properties`.

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
