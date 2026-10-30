#! /bin/bash

set -e
set -x

# STATUSBAR_TOOLCHAIN picks the compiler: clang (default) or gcc. Same knob as
# container-build.sh, so one name drives local and container builds alike.
#   ./local-build.sh                          # clang + libc++, C++23
#   STATUSBAR_TOOLCHAIN=gcc ./local-build.sh  # gcc + libstdc++, C++26
STATUSBAR_TOOLCHAIN="${STATUSBAR_TOOLCHAIN:-clang}"
case "$STATUSBAR_TOOLCHAIN" in
  clang | gcc) ;;
  *)
    set +x
    echo "error: STATUSBAR_TOOLCHAIN must be 'clang' or 'gcc'" >&2
    exit 1
    ;;
esac

# libc++ (clang) and libstdc++ (gcc) objects cannot be mixed, so each toolchain
# needs its own build tree. clang keeps the historical `build` default so
# existing habits and IDE setups are unaffected; gcc gets `build-gcc`, matching
# the `gcc` CMake preset. BUILD_DIR still overrides either.
case "$STATUSBAR_TOOLCHAIN" in
  clang) BUILD_DIR="${BUILD_DIR:-build}" ;;
  *)     BUILD_DIR="${BUILD_DIR:-build-$STATUSBAR_TOOLCHAIN}" ;;
esac

# STATUSBAR_TARGET_ARCH=arm64 cross-compiles with
# core/cmake/toolchain-<toolchain>-aarch64.cmake against STATUSBAR_SYSROOT (the
# same knobs as local-build-packages.sh), into build-arm64 unless BUILD_DIR says
# otherwise; the tests are built but not run (run them under qemu-aarch64 with
# QEMU_LD_PREFIX=$STATUSBAR_SYSROOT).
TARGET_ARCH="${STATUSBAR_TARGET_ARCH:-}"
case "$TARGET_ARCH" in
  "") ;;
  arm64)
    BUILD_DIR="${BUILD_DIR:-build-arm64}"
    [ "$BUILD_DIR" = build ] && BUILD_DIR=build-arm64
    export STATUSBAR_SYSROOT
    ;;
  *)
    set +x
    echo "error: STATUSBAR_TARGET_ARCH must be empty (native) or 'arm64'" >&2
    exit 1
    ;;
esac

cmake -G Ninja -B "$BUILD_DIR" -S . \
  --toolchain "cmake/toolchain-$STATUSBAR_TOOLCHAIN${TARGET_ARCH:+-aarch64}.cmake" "$@"
cmake --build "$BUILD_DIR"
if [ -z "$TARGET_ARCH" ]; then
  ctest --test-dir "$BUILD_DIR"
fi
