#!/usr/bin/env bash
# Build the Android Studio Layout/Compose engine libraries for Linux ARM64.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${LAYOUTLIB_WORKSPACE:-$HOME/layoutlib}"
OUTPUT_DIR="${LAYOUTLIB_OUTPUT_DIR:-${SCRIPT_DIR}/lib}"
SUPPORT_ARCHIVE="${SCRIPT_DIR}/layoutlib-build-support.tar.gz"
MANIFEST_URL="https://android.googlesource.com/platform/manifest"
MANIFEST_BRANCH="android17-release"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-arm64"
CLANG_COMMIT="198cef08637a6133e98b4a80e36f0ca35775fa9a"
GO_URL="https://android.googlesource.com/platform/prebuilts/go/linux-arm64"
GO_COMMIT="85088d1ab9a678cc8531f9cc05de9fa802f91c58"
RUST_VERSION="1.88.0"
DEBIAN_PACKAGES_URL="https://deb.debian.org/debian/dists/trixie/main/binary-arm64/Packages.xz"
JOBS=1
BUILD_ONLY=0
SETUP_ONLY=0
SKIP_SETUP=0

usage() {
  cat <<'EOF'
Usage: build-layoutlib-arm64.sh [options]

Build Android 17 layoutlib for glibc-based Linux ARM64. The generated
layoutlib_jni.so and libandroid_runtime.so are used by both the XML Layout
Editor and Compose Preview.

Options:
  --workspace DIR  Android 17 layoutlib workspace. Missing inputs are fetched.
                   Default: $LAYOUTLIB_WORKSPACE or
                   $HOME/layoutlib
  --output DIR     Artifact directory. Default: ./lib beside this script.
  --build-only     Reuse the existing audited Soong/Ninja graph.
  --setup-only     Install and validate native build prerequisites, then exit.
  --skip-setup     Do not install host packages.
  --help           Show this help text.

On a new workspace the script fetches the coherent android17-release source
snapshot and pinned ARM64 Clang, Go, and Rust prebuilts. Allow at least 120 GiB
of free disk space. Downloads and partial Git clones are reused on later runs.
Build parallelism is selected automatically from the available CPU count.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

as_root() {
  if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

install_host_prerequisites() {
  local -a packages missing=()
  local package
  if command -v apt-get >/dev/null 2>&1; then
    packages=(bc binutils bison build-essential ca-certificates ccache curl file flex gawk git libc++-dev libc++abi-dev libelf-dev libssl-dev libxml2-utils libzstd-dev lz4 m4 musl-dev musl-tools ninja-build openjdk-21-jdk-headless openssh-client patch perl pkg-config python3 repo rsync tar unzip xz-utils zip zlib1g-dev zstd)
    for package in "${packages[@]}"; do
      dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || missing+=("$package")
    done
    if ((${#missing[@]})); then
      as_root apt-get update
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    packages=(bc binutils bison ccache curl file findutils flex gawk gcc gcc-c++ git glibc-devel java-devel libstdc++-devel libxml2 lz4 make ninja-build openssl-devel openssh-clients patch perl pkgconf-pkg-config python3 rsync tar unzip xz zip zlib-devel zstd)
    for package in "${packages[@]}"; do
      rpm -q "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    ((${#missing[@]} == 0)) || as_root dnf install -y "${missing[@]}"
  else
    die "Only native Debian and Fedora hosts are supported"
  fi
}

ensure_repo_tool() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v repo >/dev/null 2>&1 && return
  mkdir -p "$HOME/.local/bin"
  curl -fL --retry 5 https://storage.googleapis.com/git-repo-downloads/repo \
    -o "$HOME/.local/bin/repo"
  chmod +x "$HOME/.local/bin/repo"
}

available_gib() {
  df -Pk "$1" | awk 'NR == 2 {printf "%d\n", $4 / 1024 / 1024}'
}

clone_commit() {
  local url="$1" commit="$2" destination="$3" probe="$4"
  [[ -x "$destination/$probe" ]] && return
  rm -rf "$destination"
  mkdir -p "$destination"
  git -C "$destination" init -q
  git -C "$destination" remote add origin "$url"
  git -C "$destination" fetch --depth=1 origin "$commit"
  git -C "$destination" checkout -q --detach FETCH_HEAD
  [[ -x "$destination/$probe" ]] || die "Incomplete prebuilt checkout: $destination"
}

prepare_rust() {
  local destination="$WORKSPACE/arm64-prebuilts/prebuilts/rust/linux-arm64/$RUST_VERSION"
  local component="rust-${RUST_VERSION}-aarch64-unknown-linux-gnu"
  local archive="$WORKSPACE/cache/${component}.tar.xz"
  [[ -x "$destination/bin/rustc" ]] && return
  mkdir -p "${archive%/*}" "${destination%/*}"
  if [[ ! -s "$archive" ]]; then
    curl -fL --retry 8 --retry-delay 5 \
      "https://static.rust-lang.org/dist/${component}.tar.xz" -o "${archive}.part"
    mv "${archive}.part" "$archive"
  fi
  rm -rf "$destination" "$WORKSPACE/cache/$component"
  tar -C "$WORKSPACE/cache" -xf "$archive"
  "$WORKSPACE/cache/$component/install.sh" --prefix="$destination" --disable-ldconfig
  mv "$destination/bin/rustc" "$destination/bin/rustc.real"
  mv "$destination/bin/clippy-driver" "$destination/bin/clippy-driver.real"
  install -m 0755 "$WORKSPACE/rustc-gnu-bootstrap" "$destination/bin/rustc"
  install -m 0755 "$WORKSPACE/clippy-gnu-bootstrap" "$destination/bin/clippy-driver"
  rm -rf "$WORKSPACE/cache/$component"
}

prepare_glibc_sysroot() {
  local packages="$WORKSPACE/cache/debian13-Packages.xz"
  local sysroot="$WORKSPACE/debian13-arm64-sysroot"
  local filename checksum archive data manifest tmp
  [[ -f "$sysroot/.ready" && -L "$sysroot/lib" && -e "$sysroot/lib/aarch64-linux-gnu/libgcc_s.so.1" ]] && return
  mkdir -p "$WORKSPACE/cache" "$sysroot"
  curl -fL --retry 8 "$DEBIAN_PACKAGES_URL" -o "${packages}.part"
  mv "${packages}.part" "$packages"
  manifest="$(mktemp)"
  python3 - "$packages" > "$manifest" <<'PY'
import lzma
import sys

wanted = {"libc6", "libc6-dev", "libgcc-s1", "linux-libc-dev"}
selected = {}
with lzma.open(sys.argv[1], "rt", encoding="utf-8") as stream:
    for stanza in stream.read().split("\n\n"):
        fields = {}
        for line in stanza.splitlines():
            if ": " in line:
                key, value = line.split(": ", 1)
                fields[key] = value
        package = fields.get("Package")
        if package in wanted:
            selected[package] = (fields["Filename"], fields["SHA256"])
if selected.keys() != wanted:
    raise SystemExit(f"missing Debian packages: {sorted(wanted - selected.keys())}")
for package in sorted(selected):
    print("|".join(selected[package]))
PY
  while IFS='|' read -r filename checksum; do
    archive="$WORKSPACE/cache/${filename##*/}"
    if [[ ! -s "$archive" ]]; then
      curl -fL --retry 8 "https://deb.debian.org/debian/$filename" -o "${archive}.part"
      mv "${archive}.part" "$archive"
    fi
    echo "$checksum  $archive" | sha256sum -c -
    tmp="$(mktemp -d)"
    (cd "$tmp" && ar x "$archive")
    data="$(find "$tmp" -maxdepth 1 -name 'data.tar.*' -print -quit)"
    [[ -n "$data" ]] || die "No data archive in $archive"
    tar -C "$sysroot" -xf "$data"
    rm -rf "$tmp"
  done < "$manifest"
  rm -f "$manifest"
  ln -sfn usr/lib "$sysroot/lib"
  touch "$sysroot/.ready"
}

prepare_graph_inputs() {
  python3 - "$SOONG_OUT/soong/soong.aosp_arm64.variables" \
    "$SOONG_OUT/soong/soong.environment.available" "$SRC" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    variables = json.load(stream)
variables["Unbundled_build"] = True
variables["Allow_missing_dependencies"] = True
variables["HostMusl"] = False
variables["PartitionVarsForSoongMigrationOnlyDoNotUse"][
    "EnforceArtifactPathRequirements"
] = "false"
rendered = json.dumps(variables, indent=4) + "\n"
with open(path, encoding="utf-8") as stream:
    current = stream.read()
if current != rendered:
    with open(path, "w", encoding="utf-8") as stream:
        stream.write(rendered)

path = sys.argv[2]
with open(path, encoding="utf-8") as stream:
    environment = json.load(stream)
environment = [item for item in environment if item["Key"] != "RUST_PREBUILTS_VERSION"]
for item in environment:
    parts = item["Value"].split(":")
    item["Value"] = ":".join(
        sys.argv[3] + part[4:] if part == "/src" or part.startswith("/src/") else part
        for part in parts
    )
environment.append({"Key": "RUST_PREBUILTS_VERSION", "Value": "1.88.0"})
rendered = json.dumps(sorted(environment, key=lambda item: item["Key"]), indent=4) + "\n"
with open(path, encoding="utf-8") as stream:
    current = stream.read()
if current != rendered:
    with open(path, "w", encoding="utf-8") as stream:
        stream.write(rendered)
PY

  python3 "$WORKSPACE/disable_test_modules.py" \
    "$SRC/prebuilts/rust-toolchain/linux-x86/Android.bp" \
    "$WORKSPACE/rust-toolchain.Android.bp.native"

  local rust="$WORKSPACE/arm64-prebuilts/prebuilts/rust/linux-arm64"
  cmp -s "$WORKSPACE/rust-toolchain.Android.bp.native" "$rust/Android.bp" || \
    install -m 0644 "$WORKSPACE/rust-toolchain.Android.bp.native" "$rust/Android.bp"
  if [[ "$(readlink "$SRC/prebuilts/rust-toolchain/linux-arm64" 2>/dev/null || true)" != "$rust" ]]; then
    rm -rf "$SRC/prebuilts/rust-toolchain/linux-arm64"
    ln -s "$rust" "$SRC/prebuilts/rust-toolchain/linux-arm64"
  fi

  # Materialize the proven overlay manifest into this dedicated source tree.
  python3 - "$WORKSPACE" "$SRC" "$RUNNER" <<'PY'
from pathlib import Path
import re
import shutil
import sys

root, source, manifest = map(Path, sys.argv[1:])
text = manifest.read_text(encoding="utf-8")
for overlay, destination in re.findall(
    r'-v "\$root/([^:"]+):/src/([^:"]+):ro"', text
):
    if overlay.startswith(("arm64-prebuilts/", "rust-toolchain.")):
        continue
    target = source / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / overlay, target)

for family in ("aidl-overlays", "hidl-overlays", "test-overlays"):
    with (root / f"{family}.list").open(encoding="utf-8") as stream:
        for line in stream:
            _, destination = line.rstrip().split("|", 1)
            target = source / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / family / destination, target)

compat = source / "frameworks/base/core/jni/platform/linux/GlibcCompat.cpp"
compatibility_source = """#include <arpa/inet.h>
#include <cerrno>
#include <cstddef>
#include <sys/socket.h>

extern "C" const char* __inet_ntop_chk(int af, const void* src, char* dst,
                                        socklen_t size, size_t dst_size) {
    if (size > dst_size) {
        errno = ENOSPC;
        return nullptr;
    }
    return inet_ntop(af, src, dst, size);
}
"""
if not compat.exists() or compat.read_text(encoding="utf-8") != compatibility_source:
    compat.write_text(compatibility_source, encoding="utf-8")
blueprint = source / "frameworks/base/core/jni/Android.bp"
text = blueprint.read_text(encoding="utf-8")
source_line = '            srcs: ["platform/linux/GlibcCompat.cpp"],\n'
needle = '        host_linux: {\n            version_script:'
if source_line not in text:
    if needle not in text:
        raise SystemExit(f"cannot locate libandroid_runtime host_linux in {blueprint}")
    text = text.replace(
        needle, '        host_linux: {\n' + source_line + '            version_script:', 1
    )
    blueprint.write_text(text, encoding="utf-8")

PY
}

run_build_mode() {
  local mode="$1"
  case "$mode" in
    audit)
      (cd "$SRC" && "$NINJA" -n -k0 -f layoutlib-build.ninja "$TARGET")
      ;;
    build)
      (cd "$SRC" && "$NINJA" -j"$JOBS" -f layoutlib-build.ninja "$TARGET")
      ;;
    analysis)
      (
        cd "$SRC"
        TOP="$SRC" "$SOONG_OUT/host/linux-arm64/bin/soong_build" \
          --top "$SRC" \
          --soong_out out-android17-partial/soong \
          --out out-android17-partial \
          --soong_variables out-android17-partial/soong/soong.aosp_arm64.variables \
          -o out-android17-partial/soong/build.aosp_arm64.ninja \
          --partial-analysis-targets=layoutlib_jni \
          --kati_suffix -aosp_arm64 \
          -l out-android17-partial/.module_paths/Android.bp.layoutlib.list \
          --available_env out-android17-partial/soong/soong.environment.available \
          --used_env out-android17-partial/soong/soong.environment.used.aosp_arm64.filtered \
          Android.bp
      )
      ;;
    *) die "Unknown build mode: $mode" ;;
  esac
}

prepare_workspace() {
  local support_hash marker override_hash override_marker tmp
  mkdir -p "$WORKSPACE"
  if [[ ! -d "$SRC/.repo" ]]; then
    (( $(available_gib "$WORKSPACE") >= 120 )) || \
      die "A new workspace requires at least 120 GiB free at $WORKSPACE"
    mkdir -p "$SRC"
    (
      cd "$SRC"
      repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1 \
        --partial-clone --clone-filter=blob:none --no-clone-bundle
      repo sync -c -j"$JOBS" --fail-fast --no-clone-bundle --no-tags
    )
  fi

  [[ -f "$SUPPORT_ARCHIVE" ]] || die "Build support archive not found: $SUPPORT_ARCHIVE"
  support_hash="$(sha256sum "$SUPPORT_ARCHIVE" | awk '{print $1}')"
  marker="$WORKSPACE/.layoutlib-build-support"
  if [[ "$(cat "$marker" 2>/dev/null || true)" != "$support_hash" ]]; then
    tar -C "$WORKSPACE" -xzf "$SUPPORT_ARCHIVE"
    printf '%s\n' "$support_hash" > "$marker"
  fi

  clone_commit "$CLANG_URL" "$CLANG_COMMIT" \
    "$SRC/prebuilts/clang/host/linux-arm64" "clang-r584948b/bin/clang"
  ln -sfn clang-r584948b "$SRC/prebuilts/clang/host/linux-arm64/clang-r584948"
  clone_commit "$GO_URL" "$GO_COMMIT" "$SRC/prebuilts/go/linux-arm64" "bin/go"
  prepare_rust
  prepare_glibc_sysroot

  override_hash="$(sha256sum "$WORKSPACE/android17-overrides-final.tar.gz" | awk '{print $1}')"
  override_marker="$WORKSPACE/.layoutlib-source-overrides"
  if [[ "$(cat "$override_marker" 2>/dev/null || true)" != "$override_hash" ]]; then
    tmp="$(mktemp -d)"
    tar -C "$tmp" -xzf "$WORKSPACE/android17-overrides-final.tar.gz"
    cp -a "$tmp/android17-overrides/." "$SRC/"
    rm -rf "$tmp"
    printf '%s\n' "$override_hash" > "$override_marker"
  fi

  mkdir -p "$SOONG_OUT/soong" "$SOONG_OUT/.module_paths"
  [[ -f "$SOONG_OUT/soong/bootstrap.ninja" ]] || \
    cp "$WORKSPACE/templates/bootstrap.ninja" "$SOONG_OUT/soong/bootstrap.ninja"
  [[ -f "$SOONG_OUT/soong/soong.aosp_arm64.variables" ]] || \
    cp "$WORKSPACE/templates/soong.aosp_arm64.variables" "$SOONG_OUT/soong/soong.aosp_arm64.variables"
  [[ -f "$SOONG_OUT/soong/soong.environment.available" ]] || \
    cp "$WORKSPACE/templates/soong.environment.available" "$SOONG_OUT/soong/soong.environment.available"
  [[ -f "$SOONG_OUT/.module_paths/Android.bp.layoutlib.list" ]] || \
    cp "$WORKSPACE/templates/Android.bp.layoutlib.list" "$SOONG_OUT/.module_paths/Android.bp.layoutlib.list"
}

while (($#)); do
  case "$1" in
    --workspace) [[ $# -ge 2 ]] || die "--workspace requires a directory"; WORKSPACE="$2"; shift ;;
    --output) [[ $# -ge 2 ]] || die "--output requires a directory"; OUTPUT_DIR="$2"; shift ;;
    --build-only) BUILD_ONLY=1 ;;
    --setup-only) SETUP_ONLY=1 ;;
    --skip-setup) SKIP_SETUP=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die "This build must run on Linux"
case "$(uname -m)" in aarch64|arm64) ;; *) die "This build requires an ARM64 host" ;; esac
getconf GNU_LIBC_VERSION >/dev/null 2>&1 || die "A glibc-based Linux host is required"
if (( ! SKIP_SETUP )); then install_host_prerequisites; fi
export PATH="$HOME/.local/bin:$PATH"
for cmd in ar cmp curl dirname file find gcc getconf git install ldd ln mktemp nproc python3 readelf readlink realpath sha256sum stat strip tar; do need "$cmd"; done
JOBS="$(nproc)"
ensure_repo_tool
if (( SETUP_ONLY )); then
  echo "Prerequisite setup completed successfully."
  exit 0
fi

mkdir -p "$WORKSPACE"
WORKSPACE="$(realpath "$WORKSPACE")"
SRC="${WORKSPACE}/src"
RUNNER="${WORKSPACE}/run_layoutlib_analysis.sh"
SOONG_OUT="${SRC}/out-android17-partial"
GLIBC_SYSROOT="${WORKSPACE}/debian13-arm64-sysroot"
GCC_LIB_DIR="$(dirname "$(gcc -print-file-name=crtbeginS.o)")"
GCC_RUNTIME_DIR="$(dirname "$(gcc -print-file-name=libgcc_s.so.1)")"
TARGET="layoutlib_jni-linux_glibc_arm64_shared-install"
NINJA="${SRC}/prebuilts/build-tools/linux-arm64/bin/ninja"
LAYOUTLIB_SO="${SOONG_OUT}/host/linux-arm64/lib64/layoutlib_jni.so"
RUNTIME_SO="${SOONG_OUT}/host/linux-arm64/lib64/libandroid_runtime.so"

prepare_workspace
[[ -d "$SRC" ]] || die "Android source tree not found: $SRC"
[[ -x "$RUNNER" ]] || die "Prepared build runner not found: $RUNNER"
[[ -x "$NINJA" ]] || die "ARM64 Ninja not found: $NINJA"
[[ -x "${WORKSPACE}/arm64-prebuilts/prebuilts/rust/linux-arm64/${RUST_VERSION}/bin/rustc" ]] || \
  die "ARM64 Rust prebuilt was not prepared"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# AOSP otherwise forces ARM64 Linux hosts onto musl even when HostMusl is false.
if (( ! BUILD_ONLY )); then
python3 - "$SRC" "$GLIBC_SYSROOT" "$GCC_LIB_DIR" "$GCC_RUNTIME_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
arch = root / "build/soong/android/arch.go"
text = arch.read_text(encoding="utf-8")
forced = 'if Bool(config.productVariables.HostMusl) || runtime.GOARCH == "arm64" {'
glibc = 'if Bool(config.productVariables.HostMusl) {'
if forced in text:
    arch.write_text(text.replace(forced, glibc, 1), encoding="utf-8")
elif glibc not in text:
    raise SystemExit(f"cannot locate host OS selection in {arch}")

host = root / "build/soong/cc/config/x86_linux_host.go"
text = host.read_text(encoding="utf-8")
marker = 'if runtime.GOOS == "linux" && runtime.GOARCH == "arm64" {'
before, found, arm64 = text.partition(marker)
flag = '"-Wno-error=#warnings",'
if not found:
    raise SystemExit(f"cannot locate ARM64 host flags in {host}")
if flag not in arm64:
    needle = '"-D_FORTIFY_SOURCE=3",'
    if needle not in arm64:
        raise SystemExit(f"cannot locate ARM64 fortify flags in {host}")
    arm64 = arm64.replace(needle, needle + '\n\t\t\t' + flag, 1)
sysroot_flag = f'"--sysroot={sys.argv[2]}",'
link_flags = [
    sysroot_flag,
    f'"-L{sys.argv[2]}/usr/lib/aarch64-linux-gnu",',
    f'"-L{sys.argv[2]}/lib/aarch64-linux-gnu",',
    f'"-B{sys.argv[3]}",',
    f'"-L{sys.argv[3]}",',
]
arm64 = arm64.replace(f'\n\t\t\t"-L{sys.argv[4]}",', "")
missing_flags = [flag for flag in link_flags if flag not in arm64]
if missing_flags:
    needle = 'linuxLdflags = []string{'
    if needle not in arm64:
        raise SystemExit(f"cannot locate ARM64 linker flags in {host}")
    arm64 = arm64.replace(
        needle, needle + "\n\t\t\t" + "\n\t\t\t".join(missing_flags), 1
    )
updated = before + marker + arm64
if updated != text:
    host.write_text(updated, encoding="utf-8")

launcher = root / "build/soong/python/scripts/main.py"
text = launcher.read_text(encoding="utf-8")
start = "  # when people try to use it.\n"
end = "\n\n  # Extract the shared libraries"
before, found, remainder = text.partition(start)
_, found_end, after = remainder.partition(end)
if not found or not found_end:
    raise SystemExit(f"cannot locate Python launcher compatibility block in {launcher}")
compatibility = "  if sys.version_info < (3, 14):\n    sys.executable = None"
updated = before + start + compatibility + end + after
if updated != text:
    launcher.write_text(updated, encoding="utf-8")

utils = root / "system/libhwbinder/Utils.h"
text = utils.read_text(encoding="utf-8")
old = "inline void zeroMemory(uint8_t* data, size_t size) {\n    memset_explicit(data, 0, size);\n}"
new = """inline void zeroMemory(uint8_t* data, size_t size) {
#if defined(__GLIBC__)
    explicit_bzero(data, size);
#else
    memset_explicit(data, 0, size);
#endif
}"""
if old in text:
    utils.write_text(text.replace(old, new, 1), encoding="utf-8")
elif new not in text:
    raise SystemExit(f"cannot locate zeroMemory implementation in {utils}")
PY
fi

prepare_graph_inputs

if (( ! BUILD_ONLY )); then
  echo "==> Rebuilding the ARM64 Soong bootstrap"
  (
    cd "$SRC"
    "$NINJA" -j"$JOBS" -f out-android17-partial/soong/bootstrap.ninja \
      out-android17-partial/host/linux-arm64/bin/soong_build
  )

  echo "==> Generating the partial layoutlib graph"
  run_build_mode analysis
  printf 'dist = nodist\nsubninja out-android17-partial/soong/build.aosp_arm64.ninja\n' \
    > "${SRC}/layoutlib-build.ninja"

  echo "==> Auditing the complete ${TARGET} dependency graph"
  run_build_mode audit
fi

echo "==> Building ${TARGET} with ${JOBS} jobs"
run_build_mode build

validate_elf() {
  local library="$1" max_glibc
  [[ -s "$library" ]] || die "Build output not found: $library"
  file "$library" | grep -q 'ELF 64-bit.*ARM aarch64' || die "Not an ARM64 ELF: $library"
  readelf -d "$library" | grep -q 'Shared library: \[libc.so.6\]' || die "Not linked to glibc: $library"
  ! readelf -d "$library" | grep -q 'libc_musl' || die "Unexpected musl dependency: $library"
  max_glibc="$(readelf --version-info "$library" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  [[ "$(printf '%s\n' GLIBC_2.41 "$max_glibc" | sort -V | tail -1)" == GLIBC_2.41 ]] || \
    die "$library requires $max_glibc and will not run on Debian 13"
}

echo "==> Publishing verified libraries to ${OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"
install -m 0755 "$LAYOUTLIB_SO" "$TMP/layoutlib_jni.so"
install -m 0755 "$RUNTIME_SO" "$TMP/libandroid_runtime.so"
strip --strip-debug "$TMP/layoutlib_jni.so" "$TMP/libandroid_runtime.so"
validate_elf "$TMP/layoutlib_jni.so"
validate_elf "$TMP/libandroid_runtime.so"
for library in "$TMP/layoutlib_jni.so" "$TMP/libandroid_runtime.so"; do
  (( $(stat -c %s "$library") <= 100 * 1024 * 1024 )) || \
    die "$library exceeds GitHub's 100 MiB regular-file limit"
done
LD_LIBRARY_PATH="$TMP" ldd "$TMP/layoutlib_jni.so" | grep -q 'not found' && die "Unresolved layoutlib dependency"
LD_LIBRARY_PATH="$TMP" ldd "$TMP/libandroid_runtime.so" | grep -q 'not found' && die "Unresolved runtime dependency"
mv -f "$TMP/layoutlib_jni.so" "$OUTPUT_DIR/layoutlib_jni.so"
mv -f "$TMP/libandroid_runtime.so" "$OUTPUT_DIR/libandroid_runtime.so"

sha256sum "$OUTPUT_DIR/layoutlib_jni.so" "$OUTPUT_DIR/libandroid_runtime.so"
echo "Build complete. These two libraries support both XML Layout Editor and Compose Preview."
