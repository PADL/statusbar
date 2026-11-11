#!/usr/bin/env bash
# Dependency-aware cross-compile builder for the statusbar Debian packages.
# Native amd64 toolchain that cross-targets aarch64 via clang multi-target +
# Debian multiarch :arm64 dev libs — no qemu emulation. Produces arm64
# .debs much faster than the emulated path (./container-build.sh) but
# cannot run tests (binaries don't execute on the build host).
#
# Usage: ./container-build-cross.sh [<pkg> ...]
#   (no arguments)   build every package
#   <pkg> ...        build the named packages and their dependencies;
#                    names may be given as 'core' or 'statusbar-core'
#
# A package's .deb is rebuilt when its source tree is newer than the .deb,
# or when one of its dependencies was rebuilt during this run. Output is
# collected in deb-output/. Override the target arch with TARGET_ARCH and
# the container engine with CONTAINER_ENGINE.
#
# STATUSBAR_TOOLCHAIN=clang|gcc selects the compiler (default clang). clang
# cross-targets with its multi-target driver; gcc uses Debian's
# aarch64-linux-gnu cross compiler, which needs a forky-or-later base. As in
# the native path, gcc output goes to deb-output-gcc/ and statically links the
# C++ runtime by default (override with STATUSBAR_STATIC_CXX=ON|OFF).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Compiler selection, passed down to each package's container-build-cross.sh.
STATUSBAR_TOOLCHAIN="${STATUSBAR_TOOLCHAIN:-clang}"
case "$STATUSBAR_TOOLCHAIN" in
  clang | gcc) ;;
  *)
    echo "error: STATUSBAR_TOOLCHAIN must be 'clang' or 'gcc'" >&2
    exit 1
    ;;
esac

# Each toolchain gets its own output directory: the .deb filenames are
# identical across compilers, so a shared directory would have them overwrite
# each other and make the source-newer-than-.deb staleness check compare a
# tree against a package built by the other compiler.
case "$STATUSBAR_TOOLCHAIN" in
  gcc) _default_out="$ROOT/deb-output-gcc" ;;
  *)   _default_out="$ROOT/deb-output" ;;
esac
DEB_OUTPUT="${DEB_OUTPUT:-$_default_out}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
export DEB_OUTPUT TARGET_ARCH STATUSBAR_TOOLCHAIN

# One shared Debian revision for the whole run, so a multi-package build
# produces a consistent set (each package script defaults its own if unset).
STATUSBAR_DEB_REVISION="${STATUSBAR_DEB_REVISION:-$(date -u +%Y%m%d%H%M%S)}"
export STATUSBAR_DEB_REVISION

# Packages in dependency-first order.
TOPO="core crypto audio avb"

# Membership test in a space-separated set (needed by the discovery below).
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac ; }

# Extension packages (aes67, aes70, mediabridge) join the build when they carry
# their own scripts/container-build-cross.sh, as in ./container-build.sh. They
# follow the exported set in directory order, so one may depend only on those
# that sort before it (mediabridge on aes67 and aes70).
EXTRA=""
for _cb in "$ROOT"/*/scripts/container-build-cross.sh; do
  [ -e "$_cb" ] || continue
  _p="$(basename "$(dirname "$(dirname "$_cb")")")"
  has "$TOPO" "$_p" || EXTRA="$EXTRA $_p"
done
TOPO="$TOPO$EXTRA"

# Transitive dependencies of each package. Extension packages declare theirs
# in their own container-build-cross.sh (the DEPS= line).
tdeps() {
  case "$1" in
    core) echo "" ;;
    crypto) echo "core" ;;
    audio) echo "core" ;;
    avb) echo "core crypto audio" ;;
    *) sed -n 's/^DEPS="\(.*\)"$/\1/p' "$ROOT/$1/scripts/container-build-cross.sh" 2>/dev/null ;;
  esac
}

mkdir -p "$DEB_OUTPUT"

WANT=""
if [ "$#" -eq 0 ]; then
  WANT=" $TOPO "
else
  for arg in "$@"; do
    p="${arg#statusbar-}"
    if ! has "$TOPO" "$p"; then
      echo "error: unknown package '$arg'" >&2
      exit 1
    fi
    WANT="$WANT $p $(tdeps "$p")"
  done
fi

# Stale if the .deb (for this target arch) is missing, or any source file
# is newer than it. PADL's packages name their debs padl-<pkg> (aes67, aes70,
# mediabridge); a library package may ship its -dev package alone (aes67,
# aes70).
src_newer() {
  local pkg="$1" tree="$ROOT/$1" deb
  deb="$(ls -1 "$DEB_OUTPUT"/statusbar-"$pkg"_*_"$TARGET_ARCH".deb \
            "$DEB_OUTPUT"/statusbar-"$pkg"-dev_*_"$TARGET_ARCH".deb \
            "$DEB_OUTPUT"/padl-"$pkg"_*_"$TARGET_ARCH".deb \
            "$DEB_OUTPUT"/padl-"$pkg"-dev_*_"$TARGET_ARCH".deb 2>/dev/null \
         | head -n1 || true)"
  [ -z "$deb" ] && return 0
  [ -n "$(find "$tree" -type f -newer "$deb" \
            -not -path '*/build/*' -not -path '*/build-*/*' \
            -not -path '*/.git/*' -print -quit)" ]
}

REBUILT=""
count=0
for pkg in $TOPO; do
  has "$WANT" "$pkg" || continue
  stale=0
  for d in $(tdeps "$pkg"); do
    if has "$REBUILT" "$d"; then stale=1; fi
  done
  if [ "$stale" -eq 0 ] && ! src_newer "$pkg"; then
    echo "$pkg: up to date ($TARGET_ARCH)"
    continue
  fi
  echo "=== statusbar-$pkg ($TARGET_ARCH): cross-building (.deb out of date) ==="
  "$ROOT/$pkg/scripts/container-build-cross.sh"
  REBUILT="$REBUILT $pkg"
  count=$((count + 1))
done
echo "=== done: $count package(s) (re)built; .deb files in $DEB_OUTPUT ==="
