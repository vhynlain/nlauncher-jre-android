#!/usr/bin/env bash
# Apply patches/series (in order, with `git apply`, no fuzz) to the pristine
# source tree in $SRC_DIR.
#
# Usage:
#   scripts/apply-patches.sh           apply (fails if the tree was already patched)
#   scripts/apply-patches.sh --check   dry-run every patch in order on a scratch copy
#                                      of the files they touch; the tree is not modified
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

SERIES="$REPO_DIR/patches/series"
[ -d "$SRC_DIR" ] || die "no source tree at $SRC_DIR (run scripts/fetch-source.sh first)"

series_list() {
  grep -v '^[[:space:]]*\(#\|$\)' "$SERIES"
}

# Files touched by a patch ("+++ b/<path>" lines).
touched_files() {
  sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "$1"
}

MODE="${1:-apply}"
case "$MODE" in
  apply|--check) ;;
  *) die "unknown argument: $MODE" ;;
esac

target="$SRC_DIR"
if [ "$MODE" = --check ]; then
  target="$(mktemp -d)"
  trap 'rm -rf "$target"' EXIT
  series_list | while read -r p; do
    touched_files "$REPO_DIR/patches/$p"
  done | sort -u | while read -r f; do
    if [ -f "$SRC_DIR/$f" ]; then
      mkdir -p "$target/$(dirname "$f")"
      cp "$SRC_DIR/$f" "$target/$f"
    fi
  done
elif [ -f "$SRC_DIR/.nlauncher-patched" ]; then
  die "$SRC_DIR is already patched; run scripts/fetch-source.sh to get a pristine tree"
fi

n=0
while read -r p; do
  file="$REPO_DIR/patches/$p"
  [ -f "$file" ] || die "patch listed in series not found: $p"
  # git apply: strict context (no fuzz), identical on Linux and macOS.
  # GIT_CEILING_DIRECTORIES stops git from discovering an enclosing repository
  # (work/ lives inside this repo), so paths stay relative to $target.
  if ! out="$(cd "$target" && GIT_CEILING_DIRECTORIES="$(dirname "$target")" \
              git apply -p1 --whitespace=nowarn "$file" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "patch failed: $p"
  fi
  n=$((n + 1))
  log "applied $p"
done < <(series_list)

# nl-0007: launcher honours NLAUNCHER_JAVA_HOME (a script, not a .patch: it anchors on the function signature, so it needs no exact context)
if [ "$MODE" = apply ]; then
  python3 "$REPO_DIR/scripts/patch-launcher-home.py" "$SRC_DIR" || die "launcher patch failed (scripts/patch-launcher-home.py)"
else
  log "launcher patch (scripts/patch-launcher-home.py) is not part of --check; it runs when applying"
fi

if [ "$MODE" = apply ]; then
  patches_hash > "$SRC_DIR/.nlauncher-patched"
  log "$n patches applied to $SRC_DIR"
else
  log "$n patches apply cleanly"
fi
