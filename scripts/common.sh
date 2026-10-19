# shellcheck shell=bash
# Shared helpers for the build scripts. Source it, do not execute it.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_DIR

# shellcheck source=../config.env
. "$REPO_DIR/config.env"

WORK_DIR="${WORK_DIR:-$REPO_DIR/work}"
OUT_DIR="${OUT_DIR:-$REPO_DIR/out}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$WORK_DIR/downloads}"
SRC_DIR="${SRC_DIR:-$WORK_DIR/src/jdk21u-$JDK_TAG}"
DEPS_DIR="${DEPS_DIR:-$WORK_DIR/deps}"
export WORK_DIR OUT_DIR DOWNLOAD_DIR SRC_DIR DEPS_DIR

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

host_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) die "unsupported host OS: $(uname -s)" ;;
  esac
}

# sha256 of a file (GNU coreutils or macOS shasum).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha1_of() {
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum "$1" | awk '{print $1}'
  else
    shasum -a 1 "$1" | awk '{print $1}'
  fi
}

# Number of CPUs of the build host.
host_cpus() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    sysctl -n hw.ncpu
  fi
}

# download URL DEST [SHA256]: download with retries, verify checksum when given.
download() {
  local url="$1" dest="$2" sha="${3:-}"
  if [ -f "$dest" ] && [ -n "$sha" ] && [ "$(sha256_of "$dest")" = "$sha" ]; then
    log "cached: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "downloading $url"
  curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
  if [ -n "$sha" ]; then
    local got
    got="$(sha256_of "$dest")"
    if [ "$got" != "$sha" ]; then
      rm -f "$dest"
      die "sha256 mismatch for $url: expected $sha, got $got"
    fi
  fi
}

# Normalised target name and the matching triples.
#   TARGET=aarch64 (default) | arm
resolve_target() {
  TARGET="${TARGET:-aarch64}"
  case "$TARGET" in
    aarch64|arm64)
      TARGET=aarch64
      OPENJDK_TARGET=aarch64-linux-android
      CLANG_TRIPLE=aarch64-linux-android
      ANDROID_ABI=arm64-v8a
      ARTIFACT_ARCH=arm64
      ;;
    arm|armv7|armv7a)
      TARGET=arm
      OPENJDK_TARGET=arm-linux-androideabi
      CLANG_TRIPLE=armv7a-linux-androideabi
      ANDROID_ABI=armeabi-v7a
      ARTIFACT_ARCH=arm
      ;;
    *) die "unknown TARGET '$TARGET' (expected aarch64 or arm)" ;;
  esac
  CONF_NAME="android-$TARGET"
  BUILD_OUT="$SRC_DIR/build/$CONF_NAME"
  ARTIFACT_NAME="jre${JDK_FEATURE}-android-${ARTIFACT_ARCH}"
  export TARGET OPENJDK_TARGET CLANG_TRIPLE ANDROID_ABI ARTIFACT_ARCH CONF_NAME BUILD_OUT ARTIFACT_NAME
}

# Locate the NDK (r28c) and export NDK_HOME / NDK_TOOLCHAIN.
resolve_ndk() {
  local cand=""
  for cand in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}"; do
    [ -n "$cand" ] && [ -d "$cand" ] && break
    cand=""
  done
  [ -n "$cand" ] || die "Android NDK not found: set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) to an NDK $NDK_VERSION ($NDK_REVISION)"
  NDK_HOME="$(cd "$cand" && pwd)"
  local rev=""
  if [ -f "$NDK_HOME/source.properties" ]; then
    rev="$(sed -n 's/^Pkg\.Revision *= *//p' "$NDK_HOME/source.properties" | tr -d '\r')"
  fi
  if [ "$rev" != "$NDK_REVISION" ]; then
    if [ "${ALLOW_OTHER_NDK:-0}" = 1 ]; then
      log "warning: NDK revision '$rev' != pinned $NDK_REVISION (ALLOW_OTHER_NDK=1)"
    else
      die "NDK at $NDK_HOME has revision '$rev', expected $NDK_REVISION ($NDK_VERSION). Set ALLOW_OTHER_NDK=1 to override."
    fi
  fi
  NDK_REVISION_FOUND="$rev"
  local tag
  case "$(host_os)" in
    linux) tag=linux-x86_64 ;;
    darwin) tag=darwin-x86_64 ;;  # universal binaries, the directory keeps this name
  esac
  NDK_TOOLCHAIN="$NDK_HOME/toolchains/llvm/prebuilt/$tag"
  [ -x "$NDK_TOOLCHAIN/bin/clang" ] || die "no clang in $NDK_TOOLCHAIN"
  export NDK_HOME NDK_TOOLCHAIN NDK_REVISION_FOUND
}

# Hash over the patch series (order + content), used in NLAUNCHER-BUILD.txt.
patches_hash() {
  local series="$REPO_DIR/patches/series"
  {
    cat "$series"
    grep -v '^[[:space:]]*\(#\|$\)' "$series" | while read -r p; do
      cat "$REPO_DIR/patches/$p"
    done
    cat "$REPO_DIR/scripts/patch-launcher-home.py"
  } | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

# Release tag for the current pins, e.g. jre21-21.0.12.8-nl1
release_tag() {
  echo "jre${JDK_FEATURE}-${JDK_VERSION}.${JDK_BUILD}-nl${NL_REVISION}"
}
