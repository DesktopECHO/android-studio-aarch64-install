#!/usr/bin/env bash
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
DRY_RUN=0 LAUNCH_MODE=auto
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-launch) LAUNCH_MODE=no ;;
    --help|-h) cat <<'EOF'
Usage: android-studio-aarch64-install.sh [options]
  --dry-run   Resolve sources and verify download URLs without installing.
  --no-launch Do not launch Android Studio after install.
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
AS_VERSION="2026.1.3.8" AS_ARCHIVE="android-studio-quail3-patch1-linux.tar.gz" AS_URL="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/${AS_VERSION}/${AS_ARCHIVE}" AS_SHA256="5bd5ee5d6e747b13f82fba3241380bd358cc2f4a847815c8e860757df13dc35f"
IDEA_VERSION="2026.1.4" IDEA_ARCHIVE="idea-2026.1.4-aarch64.tar.gz" IDEA_URL="https://download.jetbrains.com/idea/${IDEA_ARCHIVE}" IDEA_SHA256="303645b8bad4c5c0887346618b842180a3de53b3e0b3da09fc5c501f59f78013"
SDK_RELEASE_VERSION="37.0.0" SDK_ARCHIVE="android-sdk-aarch64-linux-musl.tar.xz" SDK_URL="https://github.com/HomuHomu833/android-sdk-custom/releases/download/${SDK_RELEASE_VERSION}/${SDK_ARCHIVE}" SDK_SHA256="b8424efb05ed7a25eb0ded8cea7f630ce59c9edab7ea06223aba9aa16bf40175"
NDK_VERSION="r30-beta2" NDK_DISPLAY_VERSION="r30" NDK_RELEASE_TAG="r30" NDK_BUILD_NUMBER="30.0.15729638" NDK_ARCHIVE="android-ndk-${NDK_VERSION}-aarch64-linux-musl.tar.xz" NDK_URL="https://github.com/HomuHomu833/android-ndk-custom/releases/download/${NDK_RELEASE_TAG}/${NDK_ARCHIVE}" NDK_SHA256="82cfdb69f08b27e9ed9c2e912cb2d638081522221fd2cdf75fbf3d0afb6e75b2"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fetch(){ local u="$1" o="$2" s="$3" t="${2}.part"; [[ -s "$o" ]] || { curl -L --fail --retry 8 --retry-delay 5 --retry-connrefused --connect-timeout 15 -C - -o "$t" "$u"; mv -f "$t" "$o"; }; echo "$s  $o" | sha256sum -c -; }
check_url(){ curl -L --fail --silent --show-error --range 0-0 -o /dev/null "$1"; }
copy_if(){ [[ -e "$1" ]] || return 0; mkdir -p "$(dirname "$2")"; rm -rf "$2"; cp -a "$1" "$2"; }
should_launch(){ [[ "$LAUNCH_MODE" == no ]] && return 1; [[ "$LAUNCH_MODE" == auto && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && return 1; return 0; }
guard_native_adb(){ nohup bash -c 'while :; do file "$2" 2>/dev/null | grep -q "ARM aarch64" || install -m 775 "$1" "$2"; sleep 10; done' _ "$(readlink -f "$(command -v adb)")" "${SDK_ROOT_DIR}/platform-tools/adb" >/dev/null 2>&1 & }

validate_layoutlib() {
  local library src
  for library in layoutlib_jni.so libandroid_runtime.so; do
    src="${LAYOUTLIB_SOURCE_DIR}/${library}"
    file "$src" 2>/dev/null | grep -q 'ELF 64-bit.*ARM aarch64' || \
      die "ARM64 layoutlib artifact not found: $src"
  done
}

install_layoutlib() {
  local library dst="${AS_ROOT_DIR}/plugins/design-tools/resources/layoutlib/data/linux/lib64"
  [[ -d "$dst" ]] || die "Android Studio layoutlib directory not found: $dst"
  for library in layoutlib_jni.so libandroid_runtime.so; do
    install -m 755 "${LAYOUTLIB_SOURCE_DIR}/${library}" "$dst/$library"
  done
}

desktop_entry() {
  local f="${XDG_DATA_HOME:-$HOME/.local/share}/applications/android-studio.desktop"
  mkdir -p "${f%/*}"
  cat >"$f" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Android Studio
Exec=${AS_ROOT_DIR}/bin/studio
Icon=${AS_ROOT_DIR}/bin/studio.png
Terminal=false
Categories=Development;IDE;
StartupWMClass=jetbrains-studio
EOF
}

overwrite_arm64_build_tools() {
  local tool src dst
  for tool in aapt2 zipalign; do
    src="${SDK_ROOT_DIR}/build-tools/${SDK_RELEASE_VERSION}/${tool}"
    file "$src" 2>/dev/null | grep -q 'ARM aarch64' || die "Expected ARM64 ${tool} at ${src}"
    while IFS= read -r -d '' dst; do
      [[ "$dst" == "$src" ]] && continue
      file "$dst" 2>/dev/null | grep -q 'x86-64' || continue
      install -m 775 "$src" "$dst"
    done < <(find "${SDK_ROOT_DIR}/build-tools" -mindepth 2 -maxdepth 2 -name "$tool" -print0 2>/dev/null)
  done
}

for cmd in curl tar xz sha256sum find awk sed mktemp cp mv rm nohup grep dirname file install readlink; do need "$cmd"; done
case "$(uname -m)" in aarch64|arm64) ;; *) die "This installer is for aarch64/arm64 hosts; detected: $(uname -m)" ;; esac
command -v adb >/dev/null 2>&1 || die 'adb not found, "sudo apt install adb" on Debian/Ubuntu or "sudo dnf install android-tools" on Fedora/RedHat'
validate_layoutlib
if (( DRY_RUN )); then for url in "$AS_URL" "$IDEA_URL" "$SDK_URL" "$NDK_URL"; do check_url "$url"; done; echo "Dry run completed successfully."; exit 0; fi

cat <<EOF

Unofficial Android Studio install for aarch64 Linux.
Pinned versions: AS ${AS_VERSION}, SDK ${SDK_RELEASE_VERSION}, NDK ${NDK_DISPLAY_VERSION}.

EOF
read -r -p "Hit [Enter] to continue, [CTRL-C] to quit. "
echo

mkdir -p "$INSTALL_DIR" "$SDK_ROOT_DIR" "$NDK_DIR" "$CACHE_DIR"
AS_TGZ="${CACHE_DIR}/${AS_ARCHIVE}" IDEA_TGZ="${CACHE_DIR}/${IDEA_ARCHIVE}" SDK_TXZ="${CACHE_DIR}/${SDK_ARCHIVE}" NDK_TXZ="${CACHE_DIR}/${NDK_ARCHIVE}"

echo "==> Installing Android Studio ${AS_VERSION}"
fetch "$AS_URL" "$AS_TGZ" "$AS_SHA256"
BACKUP_PATH=""; [[ -d "$AS_ROOT_DIR" ]] && BACKUP_PATH="${AS_ROOT_DIR}.bak.$(date +%Y%m%d-%H%M%S)" && mv "$AS_ROOT_DIR" "$BACKUP_PATH"
tar --no-same-owner -C "$INSTALL_DIR" -xzf "$AS_TGZ" --exclude 'android-studio/jbr/*' --exclude 'android-studio/lib/jna/*' --exclude 'android-studio/lib/native/*' --exclude 'android-studio/lib/pty4j/*' --exclude 'android-studio/lib/skiko-awt-runtime-all/*'

echo "==> Merging ARM64 JetBrains platform files from IntelliJ IDEA ${IDEA_VERSION}"
fetch "$IDEA_URL" "$IDEA_TGZ" "$IDEA_SHA256"
TMP="$(mktemp -d)"; tar --no-same-owner -C "$TMP" -xzf "$IDEA_TGZ"; IDEA_ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$IDEA_ROOT" ]] || die "Could not locate IntelliJ IDEA archive root"
for rel in bin/fsnotifier bin/restarter lib/jna lib/native lib/pty4j lib/skiko-awt-runtime-all jbr; do copy_if "${IDEA_ROOT}/${rel}" "${AS_ROOT_DIR}/${rel}"; done
rm -rf "$TMP"; [[ -x "${AS_ROOT_DIR}/jbr/bin/java" ]] || die "ARM64 JBR was not installed correctly"

echo "==> Patching Android Studio launch metadata"
[[ -e "${AS_ROOT_DIR}/bin/studio" && ! -e "${AS_ROOT_DIR}/bin/studio.x86_64" ]] && mv "${AS_ROOT_DIR}/bin/studio" "${AS_ROOT_DIR}/bin/studio.x86_64"
cat >"${AS_ROOT_DIR}/bin/studio" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/studio.sh" "$@"
EOF
chmod +x "${AS_ROOT_DIR}/bin/studio"
find "${AS_ROOT_DIR}/bin" -maxdepth 1 -type f -name '*.sh' -exec sed -i 's/amd64/aarch64/g' {} +
sed -i 's/amd64/aarch64/g' "${AS_ROOT_DIR}/product-info.json"

echo "==> Installing ARM64 Layout Editor and Compose Preview libraries"
install_layoutlib

echo "==> Installing Android SDK ${SDK_RELEASE_VERSION}"
fetch "$SDK_URL" "$SDK_TXZ" "$SDK_SHA256"
TMP="$(mktemp -d)"; xz -T0 -dc "$SDK_TXZ" | tar --no-same-owner -C "$TMP" -xf - --strip-components=1
while IFS= read -r -d '' p; do b=${p##*/}; rm -rf "${SDK_ROOT_DIR:?}/$b"; mv "$p" "${SDK_ROOT_DIR}/$b"; done < <(find "$TMP" -mindepth 1 -maxdepth 1 -print0)
rm -rf "$TMP"
guard_native_adb
mkdir -p "$HOME/.gradle"
{ grep -v '^android\.aapt2FromMavenOverride=' "$HOME/.gradle/gradle.properties" 2>/dev/null || true; echo "android.aapt2FromMavenOverride=${SDK_ROOT_DIR}/build-tools/${SDK_RELEASE_VERSION}/aapt2"; } > "$HOME/.gradle/gradle.properties.new" && mv "$HOME/.gradle/gradle.properties.new" "$HOME/.gradle/gradle.properties"

echo "==> Overwriting x86_64 build-tools binaries with ARM64 copies"
overwrite_arm64_build_tools

echo "==> Installing Android NDK ${NDK_DISPLAY_VERSION} (${NDK_BUILD_NUMBER})"
fetch "$NDK_URL" "$NDK_TXZ" "$NDK_SHA256"
TMP="$(mktemp -d)"; xz -T0 -dc "$NDK_TXZ" | tar --no-same-owner -C "$TMP" -xf -
[[ -d "${TMP}/android-ndk-${NDK_VERSION}" ]] || die "Unexpected NDK archive layout"
rm -rf "${NDK_DIR}/${NDK_BUILD_NUMBER}"; mv "${TMP}/android-ndk-${NDK_VERSION}" "${NDK_DIR}/${NDK_BUILD_NUMBER}"; rm -rf "$TMP"
[[ -x "${NDK_DIR}/${NDK_BUILD_NUMBER}/ndk-build" ]] || die "NDK installation validation failed"
JAVA_ARCH="$("${AS_ROOT_DIR}/jbr/bin/java" -XshowSettings:properties -version 2>&1 | awk -F'= ' '/os.arch =/ {print $2; exit}')"
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
