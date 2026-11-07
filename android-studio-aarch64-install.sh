#!/usr/bin/env bash
#
# Changes 2026-11-06
#
# - Updated to Android Studio `2026.2.2.9` (Rabbit 2 Patch 1, platform 262.10968.63), IntelliJ donor `2026.2.3`
#   (exact platform build match), CLion `2026.2.3`, and Android NDK `r30` final (`30.0.16248370`).
# - Replaced the trimmed IntelliJ runtime with the full ARM64 JetBrains Runtime SDK of the same build Android Studio
#   bundles (`25.0.4+b508.27`). The IDEA runtime lacks `jdk.jlink`, `jdk.jartool` and `jdk.jdeps`, which broke AGP's
#   JdkImageTransform (`jlink`) when the embedded JDK is used as the Gradle JDK.
# - Replaced the x86_64-only bytedeco FFmpeg/JavaCPP jars (`libjniavutil.so` etc.) with their `linux-arm64` builds so
#   device mirroring (screen sharing) can decode the video stream.
# - Moved the ARM64 `adb`/`aapt2`/`zipalign` watchdog into the `studio` launcher so it survives reboots and only runs
#   while Android Studio is open. Distro `adb` is now optional; the ARM64 `adb` from the SDK is used otherwise.
#
# Changes 2026-09-16
#
# - Added the JetBrains-patched ARM64 clangd bundle from CLion for NDK code insight.
# - Suppressed the AGP warning for the user-wide ARM64 aapt2 override.
# - Corrected the Android NDK r30-beta3 package revision.
#
# Changes 2026-08-14
#
# - Updated package pins to Android Studio `2026.1.3.8`, IntelliJ donor `2026.1.4`, Android SDK `37.0.0`, and Android NDK `r30` (`30.0.15729638`).
# - Switched the ARM64 merge flow to use IntelliJ donor runtime/native files and donor JBR.
# - Replaced manual desktop-entry creation with automatic desktop-entry installation.
# - Replaced manual per-project `aapt2` override guidance with a user-wide Gradle `aapt2` override plus SDK-level replacement of x86 `aapt2` and `zipalign` binaries using ARM64 copies from the installed SDK release.
# - Changed launch behavior to support automatic GUI launch detection and `--no-launch`.
#
# Added
#
# - `--dry-run` and `--help` options.
# - Download caching and SHA-256 verification for Android Studio, IntelliJ donor, SDK, and NDK downloads.
# - Backup of an existing Android Studio install before replacement.
# - Requirement for distro-supplied `adb`, with distro-specific install guidance when `adb` is not on `PATH`.
# - Installation of ARM64 Layout Editor and Compose Preview native libraries.
# - Print environment variables for `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `android.ndkVersion`.
#
# Removed
#
# - The separate JBR tarball install path.
# - Manual “Create Desktop Entry” instructions from the welcome screen.
# - Per-project `android.aapt2FromMavenOverride` instructions, replaced by a user-wide Gradle override.
#

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0 LAUNCH_MODE=auto ASSUME_YES=0
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-launch) LAUNCH_MODE=no ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h) cat <<'EOF'
Usage: android-studio-aarch64-install.sh [options]
  --dry-run   Resolve sources and verify download URLs without installing.
  --no-launch Do not launch Android Studio after install.
  --yes       Do not wait for confirmation before installing.
  --help      Show this help text.
EOF
      exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share}" AS_ROOT_DIR="${AS_ROOT_DIR:-${INSTALL_DIR}/android-studio}"
SDK_ROOT_DIR="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}" NDK_DIR="${NDK_DIR:-${SDK_ROOT_DIR}/ndk}" CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/androidstudio-installer}"
LAYOUTLIB_SOURCE_DIR="${LAYOUTLIB_SOURCE_DIR:-${SCRIPT_DIR}/lib}"
AS_VERSION="2026.2.2.9" AS_ARCHIVE="android-studio-rabbit2-patch1-linux.tar.gz" AS_URL="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/${AS_VERSION}/${AS_ARCHIVE}" AS_SHA256="11ecbf0e6dc0f04a1353f797e45bf239a3ff1a82221539b1b8cdd7eab0d8d8ea"
IDEA_VERSION="2026.2.3" IDEA_ARCHIVE="idea-${IDEA_VERSION}-aarch64.tar.gz" IDEA_URL="https://download.jetbrains.com/idea/${IDEA_ARCHIVE}" IDEA_SHA256="873286dd6406971a2311827edd66c56060c345582a4a6b1774e3925183b02ec5"
CLION_VERSION="2026.2.3" CLION_ARCHIVE="CLion-${CLION_VERSION}-aarch64.tar.gz" CLION_URL="https://download.jetbrains.com/cpp/${CLION_ARCHIVE}" CLION_SHA256="97db7e50101b63c64f81f8dcf80b14c4ace42cba697a6b091d9bb2237e22ceb0"
# Full JBR SDK (includes jlink/jmod/jar/jdeps and jmods) matching the runtime build Android Studio bundles for x86_64.
JBR_VERSION="25.0.4" JBR_BUILD="b508.27" JBR_ARCHIVE="jbrsdk-${JBR_VERSION}-linux-aarch64-${JBR_BUILD}.tar.gz" JBR_URL="https://cache-redirector.jetbrains.com/intellij-jbr/${JBR_ARCHIVE}" JBR_SHA256="d994dc9931dc1d1ee057d7361b0097a0ce7927c58eba768c50b281522da307d9"
# bytedeco natives used by device mirroring (VideoDecoder); Android Studio only ships the linux-x86_64 classifier.
MAVEN_URL="https://repo1.maven.org/maven2/org/bytedeco"
FFMPEG_VERSION="7.1.1-1.5.12" FFMPEG_SHA256="efb714be7f7013d69ca1d12f93a7fe1db32705fdb0e031c97007325ba23ebb62"
JAVACPP_VERSION="1.5.12" JAVACPP_SHA256="da709b0817b799980ae974132a5a16ec451f458e9bafdc450693afd790062b66"
FFMPEG_ARCHIVE="ffmpeg-${FFMPEG_VERSION}-linux-arm64.jar" FFMPEG_URL="${MAVEN_URL}/ffmpeg/${FFMPEG_VERSION}/${FFMPEG_ARCHIVE}"
JAVACPP_ARCHIVE="javacpp-${JAVACPP_VERSION}-linux-arm64.jar" JAVACPP_URL="${MAVEN_URL}/javacpp/${JAVACPP_VERSION}/${JAVACPP_ARCHIVE}"
SDK_RELEASE_VERSION="37.0.0" SDK_MIRROR_TAG="mirror-20260919" SDK_ARCHIVE="android-sdk-aarch64-linux-musl-20260919.tar.xz" SDK_URL="https://github.com/DesktopECHO/android-studio-aarch64-install/releases/download/${SDK_MIRROR_TAG}/${SDK_ARCHIVE}" SDK_SHA256="1d9c475b70f66ec21dc225b25388214aaa41521000ee35a3fe89d8bb7ed467a6"
NDK_VERSION="r30" NDK_DISPLAY_VERSION="r30" NDK_BUILD_NUMBER="30.0.16248370" NDK_ARCHIVE="android-ndk-${NDK_VERSION}-aarch64-linux-musl.tar.xz" NDK_URL="https://github.com/HomuHomu833/android-ndk-custom/releases/download/${NDK_VERSION}/${NDK_ARCHIVE}" NDK_SHA256="c2a82ec7860c7047203daa7cc40a332526f07dcf648b911b276f60087b0ed287"
ARM64_TOOLS_DIR="${AS_ROOT_DIR}/bin/arm64-sdk-tools"

die(){ echo "ERROR: $*" >&2; exit 1; }
warn(){ echo "WARNING: $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fetch(){ local u="$1" o="$2" s="$3" t="${2}.part"; [[ -s "$o" ]] || { curl -L --fail --retry 8 --retry-delay 5 --retry-connrefused --connect-timeout 15 -C - -o "$t" "$u"; mv -f "$t" "$o"; }; echo "$s  $o" | sha256sum -c - || { rm -f "$o"; die "Checksum mismatch for ${o##*/} (removed from cache; upstream asset may have changed)"; }; }
check_url(){ curl -L --fail --silent --show-error --range 0-0 -o /dev/null "$1"; }
copy_if(){ [[ -e "$1" ]] || return 0; mkdir -p "$(dirname "$2")"; rm -rf "$2"; cp -a "$1" "$2"; }
is_arm64(){ file -L "$1" 2>/dev/null | grep -q 'ELF 64-bit.*ARM aarch64'; }
should_launch(){ [[ "$LAUNCH_MODE" == no ]] && return 1; [[ "$LAUNCH_MODE" == auto && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && return 1; return 0; }

validate_layoutlib() {
  local library
  for library in layoutlib_jni.so libandroid_runtime.so; do
    is_arm64 "${LAYOUTLIB_SOURCE_DIR}/${library}" || die "ARM64 layoutlib artifact not found: ${LAYOUTLIB_SOURCE_DIR}/${library}"
  done
}

install_layoutlib() {
  local library dst="${AS_ROOT_DIR}/plugins/design-tools/resources/layoutlib/data/linux/lib64"
  [[ -d "$dst" ]] || die "Android Studio layoutlib directory not found: $dst"
  for library in layoutlib_jni.so libandroid_runtime.so; do
    install -m 755 "${LAYOUTLIB_SOURCE_DIR}/${library}" "$dst/$library"
  done
}

# Swap the linux-x86_64 bytedeco jars (FFmpeg + JavaCPP natives) for linux-arm64 builds and fix the plugin classpath.
install_bytedeco_arm64() {
  local lib="${AS_ROOT_DIR}/plugins/android/lib" pinfo="${AS_ROOT_DIR}/product-info.json" name
  for name in "ffmpeg-${FFMPEG_VERSION}" "javacpp-${JAVACPP_VERSION}"; do
    [[ -f "${lib}/${name}-linux-x86_64.jar" ]] || die "Expected ${lib}/${name}-linux-x86_64.jar; update the bytedeco pins for this Android Studio release"
    rm -f "${lib}/${name}-linux-x86_64.jar"
    sed -i "s|plugins/android/lib/${name}-linux-x86_64\.jar|plugins/android/lib/${name}-linux-arm64.jar|g" "$pinfo"
  done
  install -m 644 "$FFMPEG_JAR" "${lib}/${FFMPEG_ARCHIVE}"
  install -m 644 "$JAVACPP_JAR" "${lib}/${JAVACPP_ARCHIVE}"
}

# The JBR SDK version should match the runtime Android Studio ships; warn when a future AS update changes it.
check_jbr_match() {
  local want
  want="$(tar -xzOf "$AS_TGZ" android-studio/jbr/release 2>/dev/null | sed -n 's/^JAVA_RUNTIME_VERSION="\(.*\)"/\1/p')"
  [[ -z "$want" || "$want" == "${JBR_VERSION}"*"-${JBR_BUILD}" ]] || warn "Android Studio bundles JBR ${want}, installing ${JBR_VERSION}-${JBR_BUILD}"
}

desktop_entry() {
  local f="${XDG_DATA_HOME:-$HOME/.local/share}/applications/android-studio.desktop"
  mkdir -p "${f%/*}"
  cat >"$f" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Android Studio
Exec=${AS_ROOT_DIR}/bin/studio %f
Icon=${AS_ROOT_DIR}/bin/studio.png
Terminal=false
Categories=Development;IDE;
StartupWMClass=jetbrains-studio
EOF
}

# Keep ARM64 copies of the SDK host tools that the SDK Manager would otherwise replace with x86_64 builds.
stage_arm64_sdk_tools() {
  local tool src distro_adb
  mkdir -p "$ARM64_TOOLS_DIR"
  for tool in aapt2 zipalign; do
    src="${SDK_ROOT_DIR}/build-tools/${SDK_RELEASE_VERSION}/${tool}"
    is_arm64 "$src" || die "Expected ARM64 ${tool} at ${src}"
    install -m 755 "$src" "${ARM64_TOOLS_DIR}/${tool}"
  done
  distro_adb="$(command -v adb 2>/dev/null || true)"
  if [[ -n "$distro_adb" ]] && is_arm64 "$distro_adb"; then
    install -m 755 "$(readlink -f "$distro_adb")" "${ARM64_TOOLS_DIR}/adb"
  else
    is_arm64 "${SDK_ROOT_DIR}/platform-tools/adb" || die "No ARM64 adb found in the SDK or on PATH"
    install -m 755 "${SDK_ROOT_DIR}/platform-tools/adb" "${ARM64_TOOLS_DIR}/adb"
  fi
}

write_launcher() {
  [[ -e "${AS_ROOT_DIR}/bin/studio" && ! -e "${AS_ROOT_DIR}/bin/studio.x86_64" ]] && mv "${AS_ROOT_DIR}/bin/studio" "${AS_ROOT_DIR}/bin/studio.x86_64"
  mkdir -p "$ARM64_TOOLS_DIR"
  cat >"${ARM64_TOOLS_DIR}/fix-sdk-tools" <<'EOF'
#!/usr/bin/env bash
# Replace x86_64 adb/aapt2/zipalign (e.g. installed by the SDK Manager) with the ARM64 copies next to this script.
TOOLS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" SDK="${1:?usage: fix-sdk-tools SDK_ROOT}"
for dst in "$SDK/platform-tools/adb" "$SDK"/build-tools/*/aapt2 "$SDK"/build-tools/*/zipalign; do
  [[ -f "$dst" && -x "${TOOLS}/${dst##*/}" ]] || continue
  if file -b "$dst" 2>/dev/null | grep -q 'x86-64'; then
    install -m 755 "${TOOLS}/${dst##*/}" "$dst" && echo "Replaced x86_64 ${dst} with ARM64 copy"
  fi
done
exit 0
EOF
  cat >"${AS_ROOT_DIR}/bin/studio" <<EOF
#!/usr/bin/env bash
# ARM64 launcher: keeps SDK host tools ARM64 while Android Studio runs, then starts studio.sh.
SCRIPT_DIR="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
FIX="\${SCRIPT_DIR}/arm64-sdk-tools/fix-sdk-tools" SDK="\${ANDROID_SDK_ROOT:-\${ANDROID_HOME:-${SDK_ROOT_DIR}}}"
"\$FIX" "\$SDK"
( while kill -0 \$\$ 2>/dev/null; do sleep 10; "\$FIX" "\$SDK"; done ) </dev/null >/dev/null 2>&1 &
exec "\${SCRIPT_DIR}/studio.sh" "\$@"
EOF
  chmod +x "${AS_ROOT_DIR}/bin/studio" "${ARM64_TOOLS_DIR}/fix-sdk-tools"
}

for cmd in curl tar xz sha256sum find awk sed mktemp cp mv rm grep dirname file install readlink; do need "$cmd"; done
case "$(uname -m)" in aarch64|arm64) ;; *) die "This installer is for aarch64/arm64 hosts; detected: $(uname -m)" ;; esac
validate_layoutlib
if (( DRY_RUN )); then for url in "$AS_URL" "$IDEA_URL" "$CLION_URL" "$JBR_URL" "$FFMPEG_URL" "$JAVACPP_URL" "$SDK_URL" "$NDK_URL"; do check_url "$url"; echo "OK  $url"; done; echo "Dry run completed successfully."; exit 0; fi

cat <<EOF

Unofficial Android Studio install for aarch64 Linux.
Pinned versions: AS ${AS_VERSION}, JBR ${JBR_VERSION}-${JBR_BUILD}, SDK ${SDK_RELEASE_VERSION}, NDK ${NDK_DISPLAY_VERSION} (${NDK_BUILD_NUMBER}).

EOF
(( ASSUME_YES )) || read -r -p "Hit [Enter] to continue, [CTRL-C] to quit. "
echo

mkdir -p "$INSTALL_DIR" "$SDK_ROOT_DIR" "$NDK_DIR" "$CACHE_DIR"
AS_TGZ="${CACHE_DIR}/${AS_ARCHIVE}" IDEA_TGZ="${CACHE_DIR}/${IDEA_ARCHIVE}" CLION_TGZ="${CACHE_DIR}/${CLION_ARCHIVE}" JBR_TGZ="${CACHE_DIR}/${JBR_ARCHIVE}"
FFMPEG_JAR="${CACHE_DIR}/${FFMPEG_ARCHIVE}" JAVACPP_JAR="${CACHE_DIR}/${JAVACPP_ARCHIVE}" SDK_TXZ="${CACHE_DIR}/${SDK_ARCHIVE}" NDK_TXZ="${CACHE_DIR}/${NDK_ARCHIVE}"

echo "==> Installing Android Studio ${AS_VERSION}"
fetch "$AS_URL" "$AS_TGZ" "$AS_SHA256"
BACKUP_PATH=""; [[ -d "$AS_ROOT_DIR" ]] && BACKUP_PATH="${AS_ROOT_DIR}.bak.$(date +%Y%m%d-%H%M%S)" && mv "$AS_ROOT_DIR" "$BACKUP_PATH"
tar --no-same-owner -C "$INSTALL_DIR" -xzf "$AS_TGZ" --exclude 'android-studio/jbr/*' --exclude 'android-studio/lib/jna/*' --exclude 'android-studio/lib/native/*' --exclude 'android-studio/lib/pty4j/*' --exclude 'android-studio/lib/skiko-awt-runtime-all/*'

echo "==> Merging ARM64 JetBrains platform files from IntelliJ IDEA ${IDEA_VERSION}"
fetch "$IDEA_URL" "$IDEA_TGZ" "$IDEA_SHA256"
TMP="$(mktemp -d)"; tar --no-same-owner -C "$TMP" -xzf "$IDEA_TGZ" --exclude '*/jbr/*' --exclude '*/plugins/*'; IDEA_ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$IDEA_ROOT" ]] || die "Could not locate IntelliJ IDEA archive root"
for rel in bin/fsnotifier bin/restarter lib/jna lib/native lib/pty4j lib/skiko-awt-runtime-all; do copy_if "${IDEA_ROOT}/${rel}" "${AS_ROOT_DIR}/${rel}"; done
rm -rf "$TMP"

echo "==> Installing ARM64 JetBrains Runtime SDK ${JBR_VERSION}-${JBR_BUILD}"
check_jbr_match
fetch "$JBR_URL" "$JBR_TGZ" "$JBR_SHA256"
TMP="$(mktemp -d)"; tar --no-same-owner -C "$TMP" -xzf "$JBR_TGZ"; JBR_ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$JBR_ROOT" ]] || die "Could not locate JBR archive root"
rm -rf "${AS_ROOT_DIR}/jbr"; mv "$JBR_ROOT" "${AS_ROOT_DIR}/jbr"; rm -rf "$TMP"
for tool in java javac jlink jmod jar; do is_arm64 "${AS_ROOT_DIR}/jbr/bin/${tool}" || die "ARM64 JBR is missing ${tool}"; done

echo "==> Replacing x86_64 FFmpeg/JavaCPP natives used by device mirroring"
fetch "$FFMPEG_URL" "$FFMPEG_JAR" "$FFMPEG_SHA256"
fetch "$JAVACPP_URL" "$JAVACPP_JAR" "$JAVACPP_SHA256"
install_bytedeco_arm64

echo "==> Merging ARM64 clang tools from CLion ${CLION_VERSION}"
fetch "$CLION_URL" "$CLION_TGZ" "$CLION_SHA256"
TMP="$(mktemp -d)"; tar --no-same-owner -C "$TMP" -xzf "$CLION_TGZ" "clion-${CLION_VERSION}/bin/clang/linux/aarch64"
copy_if "${TMP}/clion-${CLION_VERSION}/bin/clang/linux/aarch64" "${AS_ROOT_DIR}/plugins/cidr-clangd/bin/clang/linux/aarch64"
rm -rf "$TMP"
is_arm64 "${AS_ROOT_DIR}/plugins/cidr-clangd/bin/clang/linux/aarch64/bin/clangd" || die "ARM64 clangd was not installed correctly"

echo "==> Patching Android Studio launch metadata"
write_launcher
find "${AS_ROOT_DIR}/bin" -maxdepth 1 -type f -name '*.sh' -exec sed -i 's/amd64/aarch64/g' {} +
sed -i 's/amd64/aarch64/g' "${AS_ROOT_DIR}/product-info.json"

echo "==> Installing ARM64 Layout Editor and Compose Preview libraries"
install_layoutlib

echo "==> Installing Android SDK ${SDK_RELEASE_VERSION}"
fetch "$SDK_URL" "$SDK_TXZ" "$SDK_SHA256"
TMP="$(mktemp -d)"; xz -T0 -dc "$SDK_TXZ" | tar --no-same-owner -C "$TMP" -xf - --strip-components=1
while IFS= read -r -d '' p; do b=${p##*/}; rm -rf "${SDK_ROOT_DIR:?}/$b"; mv "$p" "${SDK_ROOT_DIR}/$b"; done < <(find "$TMP" -mindepth 1 -maxdepth 1 -print0)
rm -rf "$TMP"
mkdir -p "$HOME/.gradle"
{ grep -v -e '^android\.aapt2FromMavenOverride=' -e '^android\.sync\.suppressAgpWarnings=' "$HOME/.gradle/gradle.properties" 2>/dev/null || true; echo "android.aapt2FromMavenOverride=${SDK_ROOT_DIR}/build-tools/${SDK_RELEASE_VERSION}/aapt2"; echo 'android.sync.suppressAgpWarnings=UNSUPPORTED_PROJECT_OPTION_USE'; } > "$HOME/.gradle/gradle.properties.new" && mv "$HOME/.gradle/gradle.properties.new" "$HOME/.gradle/gradle.properties"

echo "==> Staging ARM64 adb/aapt2/zipalign and replacing any x86_64 copies in the SDK"
stage_arm64_sdk_tools
"${ARM64_TOOLS_DIR}/fix-sdk-tools" "$SDK_ROOT_DIR"

echo "==> Installing Android NDK ${NDK_DISPLAY_VERSION} (${NDK_BUILD_NUMBER})"
fetch "$NDK_URL" "$NDK_TXZ" "$NDK_SHA256"
TMP="$(mktemp -d)"; xz -T0 -dc "$NDK_TXZ" | tar --no-same-owner -C "$TMP" -xf -
[[ -d "${TMP}/android-ndk-${NDK_VERSION}" ]] || die "Unexpected NDK archive layout"
grep -q "^Pkg.Revision = ${NDK_BUILD_NUMBER}\$" "${TMP}/android-ndk-${NDK_VERSION}/source.properties" || die "NDK revision does not match ${NDK_BUILD_NUMBER}"
rm -rf "${NDK_DIR}/${NDK_BUILD_NUMBER}"; mv "${TMP}/android-ndk-${NDK_VERSION}" "${NDK_DIR}/${NDK_BUILD_NUMBER}"; rm -rf "$TMP"
[[ -x "${NDK_DIR}/${NDK_BUILD_NUMBER}/ndk-build" ]] || die "NDK installation validation failed"
desktop_entry

cat <<EOF

Installation complete.

Android Studio : ${AS_ROOT_DIR}
Android SDK    : ${SDK_ROOT_DIR}
Android NDK    : ${NDK_DIR}/${NDK_BUILD_NUMBER}

Recommended environment:
  export ANDROID_HOME="${SDK_ROOT_DIR}"
  export ANDROID_SDK_ROOT="${SDK_ROOT_DIR}"

Next steps:
  1. Run the Android Studio setup wizard.
  2. Choose Install type: Custom.
  3. Uncheck the AVD emulator.  Ignore warnings about missing Emulator components.
  4. Complete the setup wizard.  Let Android Studio download any remaining components.

For native projects using this NDK:
  android.ndkVersion=${NDK_BUILD_NUMBER}
EOF

if should_launch; then
  echo; echo "Starting Android Studio..."
  nohup "${AS_ROOT_DIR}/bin/studio" >"${TMPDIR:-/tmp}/studio.log" 2>&1 &
  echo "Log: ${TMPDIR:-/tmp}/studio.log"
else
  echo; echo "Launch skipped. Start Android Studio with:"; echo "  ${AS_ROOT_DIR}/bin/studio"
fi
[[ -n "$BACKUP_PATH" ]] && { echo; echo "Previous Android Studio backup:"; echo "  ${BACKUP_PATH}"; }
exit 0
