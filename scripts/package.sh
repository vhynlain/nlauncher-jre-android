#!/usr/bin/env bash
# Package the jlink'ed runtime image produced by scripts/build.sh:
#   out/jre21-android-<arch>.tar.xz  (single root directory jre-21/)
#   out/jre21-android-<arch>.tar.xz.sha256
#
# Env: TARGET (aarch64 | arm), ANDROID_NDK_HOME (for llvm-strip),
#      STRIP_BINARIES=0 to keep symbols, SOURCE_DATE_EPOCH for file times.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

resolve_target
resolve_ndk

image="$OUT_DIR/stage/$TARGET/jre-$JDK_FEATURE"
[ -d "$image" ] || die "no runtime image at $image (run scripts/build.sh)"

# --- required layout (the contract in README.md) ---
for f in bin/java lib/server/libjvm.so lib/modules lib/jvm.cfg conf legal release \
         lib/libjava.so lib/libjli.so lib/libnet.so lib/libnio.so lib/libzip.so lib/libjimage.so; do
  [ -e "$image/$f" ] || die "image is missing $f"
done
if [ -e "$image/lib/libc++_shared.so" ]; then
  die "image unexpectedly contains libc++_shared.so (libc++ must be linked statically)"
fi

# --- developer tools (this fork ships a JDK: javac, jlink, jar must exist) ---
for f in bin/javac bin/jlink bin/jar lib/jrt-fs.jar; do
  [ -e "$image/$f" ] || die "image is missing $f (is jlink-modules.txt missing jdk.compiler / jdk.jlink / jdk.jartool?)"
done
# JDK 21 jlink needs a jmods directory next to the image to link anything on the device.
# Set INCLUDE_JMODS=1 to ship it (adds roughly 100+ MB uncompressed).
if [ "${INCLUDE_JMODS:-0}" = 1 ]; then
  [ -d "$BUILD_OUT/images/jmods" ] || die "no jmods at $BUILD_OUT/images/jmods"
  rm -rf "$image/jmods"
  cp -R "$BUILD_OUT/images/jmods" "$image/jmods"
fi

# --- drop files that are useless on a device ---
find "$image" \( -name '*.debuginfo' -o -name '*.diz' -o -name 'src.zip' \) -exec rm -f {} +

# --- strip native code ---
if [ "${STRIP_BINARIES:-1}" = 1 ]; then
  log "stripping ELF files"
  while IFS= read -r -d '' f; do
    if [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then
      chmod u+w "$f"
      "$NDK_TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$f"
    fi
  done < <(find "$image/bin" "$image/lib" -type f -print0)
fi

# --- ELF sanity checks: 16 KB alignment, dependencies, RUNPATH ---
python3 "$REPO_DIR/scripts/elfcheck.py" "$image" --arch "$TARGET" --page-size 16384

# --- build info ---
src_commit="${GITHUB_SHA:-$(git -C "$REPO_DIR" rev-parse --verify -q HEAD 2>/dev/null || echo unknown)}"
modules="$(grep -v '^[[:space:]]*\(#\|$\)' "$REPO_DIR/jlink-modules.txt" | awk '{print $1}' | paste -sd, -)"
npatches="$(grep -vc '^[[:space:]]*\(#\|$\)' "$REPO_DIR/patches/series")"
cat > "$image/NLAUNCHER-BUILD.txt" <<EOF
# Build information of this runtime image (key=value).
name=$ARTIFACT_NAME
release_tag=$(release_tag)
java_version=$JDK_VERSION+$JDK_BUILD-nl$NL_REVISION
upstream_repo=https://github.com/openjdk/jdk${JDK_FEATURE}u
upstream_tag=$JDK_TAG
upstream_commit=$JDK_COMMIT
upstream_tarball=$JDK_SRC_FILE
upstream_tarball_url=$JDK_SRC_URL
upstream_tarball_sha256=$JDK_SRC_SHA256
patches_count=$npatches
patches_sha256=$(patches_hash)
termux_packages_commit=$TERMUX_PACKAGES_COMMIT
ndk_version=$NDK_VERSION
ndk_revision=$NDK_REVISION_FOUND
android_api=$ANDROID_API
openjdk_target=$OPENJDK_TARGET
android_abi=$ANDROID_ABI
jvm_variant=server
libcxx=static
modules=$modules
source_repo=https://github.com/Unxkki/nlauncher-jre-android
source_commit=$src_commit
build_host=$(uname -s)-$(uname -m)
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# --- archive ---
mkdir -p "$OUT_DIR"
archive="$OUT_DIR/$ARTIFACT_NAME.tar.xz"
rm -f "$archive" "$archive.sha256"
epoch="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_DIR" log -1 --format=%ct 2>/dev/null || date +%s)}"
tar_flags=()
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar_flags=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" --format=gnu)
elif command -v gtar >/dev/null 2>&1; then
  tar() { gtar "$@"; }
  tar_flags=(--sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" --format=gnu)
else
  tar_flags=(--uid 0 --gid 0)   # bsdtar: not byte-for-byte reproducible, still valid
fi
log "writing $archive"
tar -C "$(dirname "$image")" "${tar_flags[@]}" -cf - "jre-$JDK_FEATURE" \
  | xz -T0 -9 > "$archive"
(cd "$OUT_DIR" && printf '%s  %s\n' "$(sha256_of "$(basename "$archive")")" "$(basename "$archive")" > "$(basename "$archive").sha256")
log "$(cat "$archive.sha256")"
du -h "$archive" | awk '{print "size: " $1}' >&2
