#!/usr/bin/env bash
# Dependency-aware Debian package builder for the exported statusbar trees.
#
# Usage: ./container-build.sh [<pkg> ...]
#   (no arguments)   build every package
#   <pkg> ...        build the named packages and their dependencies;
#                    names may be given as 'core' or 'statusbar-core'
#
# A package's .deb is rebuilt when a file of its source tree (followed when
# the tree is a symlink) is newer than the .deb, or when one of its
# dependencies was rebuilt during this run. File times miss an older commit
# checked out; local-build-packages.sh compares git source states instead. Output is
# collected in deb-output/. Override the base image with DEBIAN_VERSION,
# the container engine with CONTAINER_ENGINE, and the target architecture
# with TARGET_PLATFORM (default linux/arm64; cross-arch needs qemu-user-static
# registered with the host kernel's binfmt_misc).
#
# STATUSBAR_TOOLCHAIN=clang|gcc selects the compiler (default clang). The gcc
# toolchain builds C++26 with g++-16 on a forky base and, by default, statically
# links the C++ runtime so the packages still install on an older target; its
# .deb files land in deb-output-gcc/ so the two toolchains never overwrite each
# other. Set STATUSBAR_STATIC_CXX=ON|OFF to override the static-runtime choice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Compiler selection, passed down to each package's container-build.sh.
STATUSBAR_TOOLCHAIN="${STATUSBAR_TOOLCHAIN:-clang}"
case "$STATUSBAR_TOOLCHAIN" in
  clang | gcc) ;;
  *)
    echo "error: STATUSBAR_TOOLCHAIN must be 'clang' or 'gcc'" >&2
    exit 1
    ;;
esac
export STATUSBAR_TOOLCHAIN

# Each toolchain gets its own output directory. The .deb filenames are
# identical across toolchains, so a shared directory would have them overwrite
# each other and make the source-newer-than-.deb staleness check compare a
# tree against a package built by the other compiler.
case "$STATUSBAR_TOOLCHAIN" in
  gcc) _default_out="$ROOT/deb-output-gcc" ;;
  *)   _default_out="$ROOT/deb-output" ;;
esac
DEB_OUTPUT="${DEB_OUTPUT:-$_default_out}"
export DEB_OUTPUT
ENGINE="${CONTAINER_ENGINE:-podman}"

# On macOS the container engine runs inside a VM; when that VM is stopped
# every engine command fails with a cryptic "connection refused". If the
# engine is unreachable but a podman machine is configured, start it.
if ! "$ENGINE" info >/dev/null 2>&1; then
  if "$ENGINE" machine inspect >/dev/null 2>&1; then
    echo "=== $ENGINE VM is not running; starting it ==="
    "$ENGINE" machine start
  else
    echo "error: cannot connect to $ENGINE." >&2
    echo "       Start the container engine (macOS: '$ENGINE machine init' then" >&2
    echo "       '$ENGINE machine start'; Linux: check the $ENGINE service)." >&2
    exit 1
  fi
fi

# Packages in dependency-first order.
TOPO="core crypto audio avb"

# Membership test in a space-separated set (needed by the discovery below).
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac ; }

# Nested extension packages: a private tree dropped into the umbrella (NOT a
# submodule) joins the build when it carries its own scripts/container-build.sh.
# They depend only on exported packages (their script's DEPS line), so they
# sort after the exported set in any order.
EXTRA=""
for _cb in "$ROOT"/*/scripts/container-build.sh; do
  [ -e "$_cb" ] || continue
  _p="$(basename "$(dirname "$(dirname "$_cb")")")"
  has "$TOPO" "$_p" || EXTRA="$EXTRA $_p"
done
TOPO="$TOPO$EXTRA"

# Transitive dependencies of each package. Extension packages declare theirs
# in their own container-build.sh (the DEPS= line).
tdeps() {
  case "$1" in
    core) echo "" ;;
    crypto) echo "core" ;;
    audio) echo "core" ;;
    avb) echo "core crypto audio" ;;
    *) sed -n 's/^DEPS="\(.*\)"$/\1/p' "$ROOT/$1/scripts/container-build.sh" 2>/dev/null ;;
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

# Stale if the .deb is missing, or any source file is newer than it.
# Extension packages may name their deb without the statusbar- prefix, and
# PADL's name theirs padl-<pkg>; a library package may ship its -dev package
# alone (aes67, aes70).
src_newer() {
  local pkg="$1" tree="$ROOT/$1" deb
  deb="$(ls -1 "$DEB_OUTPUT"/statusbar-"$pkg"_*.deb "$DEB_OUTPUT"/statusbar-"$pkg"-dev_*.deb \
            "$DEB_OUTPUT"/"$pkg"_*.deb "$DEB_OUTPUT"/padl-"$pkg"_*.deb \
            "$DEB_OUTPUT"/padl-"$pkg"-dev_*.deb 2>/dev/null | head -n1 || true)"
  [ -z "$deb" ] && return 0
  [ -n "$(find -H "$tree" -type f -newer "$deb" \
            -not -path '*/build/*' -not -path '*/build-*/*' \
            -not -path '*/.git/*' -print -quit)" ]
}

# One shared Debian package revision for this whole run: every package rebuilt
# now gets the same strictly-increasing version (1.1.0-<rev>), so a redeploy
# always upgrades (plain `apt-get install` skips a same-version reinstall, which
# silently left a node on the old binary). Bumped only here / per run.
export STATUSBAR_DEB_REVISION="${STATUSBAR_DEB_REVISION:-$(date -u +%Y%m%d%H%M%S)}"
echo "=== toolchain: $STATUSBAR_TOOLCHAIN  output: $DEB_OUTPUT ==="
echo "=== deb revision for this run: $STATUSBAR_DEB_REVISION ==="

REBUILT=""
count=0
for pkg in $TOPO; do
  has "$WANT" "$pkg" || continue
  stale=0
  for d in $(tdeps "$pkg"); do
    if has "$REBUILT" "$d"; then stale=1; fi
  done
  if [ "$stale" -eq 0 ] && ! src_newer "$pkg"; then
    echo "$pkg: up to date"
    continue
  fi
  echo "=== statusbar-$pkg: building (.deb out of date) ==="
  "$ROOT/$pkg/scripts/container-build.sh"
  REBUILT="$REBUILT $pkg"
  count=$((count + 1))
done
echo "=== done: $count package(s) (re)built; .deb files in $DEB_OUTPUT ==="
