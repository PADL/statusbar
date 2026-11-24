# statusbar

Open-source C++23 building blocks for **time-synchronised, real-time audio
networking** — and the embedded platform tooling to run it.

This is an umbrella index for my public repositories on Codeberg. Everything
below lives under [**codeberg.org/statusbar**](https://codeberg.org/statusbar).

— Jeff Koftinoff · California · <https://avb.statusbar.com/>

---

## Quick start

Start here. This umbrella is the entry point — it pulls in every library and
tool as a submodule and builds them as one project. Clang with libc++ is the
required toolchain; `local-build.sh` applies it automatically (see
[Prerequisites](#prerequisites) to install it).

```sh
# Clone everything (libraries + platform tooling are git submodules)
git clone --recursive https://codeberg.org/statusbar/statusbar.git
cd statusbar

# Build every library + run the full test suite (into ./build)
./local-build.sh

# Sanitizers — mutually exclusive, each in its own build dir
BUILD_DIR=build-asan  ./local-build.sh -DENABLE_ASAN=ON     # AddressSanitizer
BUILD_DIR=build-ubsan ./local-build.sh -DENABLE_UBSAN=ON    # UndefinedBehaviorSanitizer
BUILD_DIR=build-tsan  ./local-build.sh -DENABLE_TSAN=ON     # ThreadSanitizer

# Fuzzing (Linux; libFuzzer is on by default with Clang)
BUILD_DIR=build-fuzz ./local-build.sh -DENABLE_FUZZING=ON
cmake --build build-fuzz --target fuzz-smoke   # run each *_fuzzer once
cmake --build build-fuzz --target fuzz-all     # ~30s-per-fuzzer campaign

# Code coverage (HTML report under build-cov/)
BUILD_DIR=build-cov ./local-build.sh -DENABLE_COVERAGE=ON
cmake --build build-cov --target coverage-html

# Format the whole tree (use --check in CI)
./reformat.sh
```

Everything above is expanded — prerequisites, IDE setup, Debian packaging — in
[**Building**](#building) below. Each submodule also has its own README for
working on that library standalone.

---

## The stack

The libraries layer cleanly: `core` is the foundation, `crypto` and `audio`
build on it, and `avb` ties everything together into a full AVB/TSN
implementation.

| Repository | Language | What it is |
| --- | --- | --- |
| [**avb**](https://codeberg.org/statusbar/avb) | C++23 | AVB/TSN protocol family — the flagship project (see below). |
| [**audio**](https://codeberg.org/statusbar/audio) | C++23 | Audio toolkit: DSP primitives, real-time data-flow engine, low-latency cross-platform audio I/O, SMPTE timecode, MIDI, and Open Sound Control. |
| [**crypto**](https://codeberg.org/statusbar/crypto) | C++23 | Cryptography toolkit: AES (block, CBC, GCM-SIV, SIV, CMAC), SHA-2, POLYVAL, HKDF/KDF2, Curve25519 (X25519/Ed25519), NIST P-256 (ECDH/ECDSA), ECIES, and PKCS#8 — hardware-accelerated (ARMv8 Crypto Extensions; AES-NI/PCLMUL/SHA-NI on x86-64) with portable software fallbacks. |
| [**core**](https://codeberg.org/statusbar/core) | C++23 | Foundational utilities: error handling, zero-copy buffers, IEEE and networking primitives, state machines, inter-thread communication, real-time scheduling, and terminal UI. |

## Platform & tooling

The hardware and OS layer for running this stack on Raspberry Pi 5 and
microcontrollers.

| Repository | Language | What it is |
| --- | --- | --- |
| [**rtkernel**](https://codeberg.org/statusbar/rtkernel) | Shell | Scripts to configure and build a Linux kernel for Debian trixie on the Raspberry Pi 5, tuned for real-time operation and isolated CPU cores. |
| [**linuxptp4avb**](https://codeberg.org/statusbar/linuxptp4avb) | Shell | LinuxPTP (`ptp4l`) configuration for the Raspberry Pi 5 to support gPTP (IEEE 802.1AS) with an external grandmaster synced to GPS TAI time. |
| [**zephyr**](https://codeberg.org/statusbar/zephyr) | Shell | Zephyr RTOS test applications for the statusbar libraries. |

---

## About avb

[`statusbar/avb`](https://codeberg.org/statusbar/avb) is a C++23 implementation
of the AVB/TSN (Audio Video Bridging / Time-Sensitive Networking) protocol
family:

- **IEEE 1722** — AVTP audio transport
- **IEEE 1722.1** — ATDECC device discovery, control, and connection management
- **IEEE 802.1AS** — gPTP time synchronisation
- **IEEE 802.1Q** — MSRP/MVRP stream reservation

It ships protocol modules (`avtp`, `atdecc`, `gptp`, `srp`, and the integrated
`nanoavb` entity stack) plus a broad set of command-line tools: ATDECC
controllers and monitors, a Linux gPTP slave and NTP-SHM bridge, AVTP
capture/replay/decode utilities, and turn-key AVB audio entities. It also
includes AVB/TSN-adjacent networking and measurement tooling — `udptun`
(gPTP-timestamped UDP framework), `owlm` (one-way latency measurement), a
`stun` client/server (RFC 8489), and `netdump` (AVB/AVTP-aware packet capture).

---

## Cloning everything

Every project is included here as a git submodule, so a recursive clone of this
umbrella pulls them all:

```sh
git clone --recursive https://codeberg.org/statusbar/statusbar.git
```

Already cloned without `--recursive`? Pull the submodules with:

```sh
git submodule update --init --recursive
```

---

## Building

The four C++ libraries (`core`, `crypto`, `audio`, `avb`) build together as a
single aggregate CMake project, so you can open the umbrella as one project in
your IDE. The build uses Clang with libc++; the bundled toolchain file picks the
compiler up automatically.

> **The toolchain file is required.** `cmake/toolchain-clang.cmake` defines the
> shared build helpers (fuzzing, coverage, clang-tidy, sanitizers). A plain
> `cmake -S .` without it will fail with `Unknown CMake command
> "statusbar_register_fuzz_targets"`.

### Prerequisites

- **macOS:** Homebrew LLVM (`brew install llvm`) for Clang + libc++, plus
  `brew install cmake ninja`. Linux-only components (AF_XDP, BPF) are compiled
  out automatically.
- **Debian/Ubuntu (incl. Raspberry Pi 5):** the stock LLVM toolchain and dev
  libraries:
  ```sh
  sudo apt install clang clang-tools clangd lld llvm libc++-dev libc++abi-dev \
      cmake ninja-build ccache pkg-config \
      libasound2-dev libbpf-dev libxdp-dev libelf-dev zlib1g-dev
  ```

### Quick build

```sh
./local-build.sh            # configure + build + both test runs, into ./build
BUILD_DIR=build-rel ./local-build.sh -DCMAKE_BUILD_TYPE=Release
```

`local-build.sh` is a thin wrapper around:

```sh
cmake -G Ninja -B build -S . --toolchain cmake/toolchain-clang.cmake
cmake --build build
ctest --test-dir build -LE functional   # the unit tests
ctest --test-dir build -L functional    # the functional tests
```

Two kinds of test are kept apart. Unit tests test logic: they open no socket
and wait for nothing, so they pass or fail the same on any host. Functional
tests exercise real sockets and a real kernel, and build into
`statusbar_functional_test`. A build runs both, the unit tests first, and a
failure in either fails it; that is what `local-build.sh` does, and so CI.
The functional run has its own switch, for a host that cannot run them:

```sh
STATUSBAR_SKIP_FUNCTIONAL_TESTS=1 ./local-build.sh   # unit tests only
```

`./install-hooks.sh` installs a pre-commit hook for formatting and the block
rule. `./install-hooks.sh --functional` adds the functional tests to it, for
the repository being committed to, when the staged change touches C++ or
CMake and that repository has a configured build directory. That step is off
unless asked for.

Each package's development package also installs them, as
`statusbar-<pkg>-functional-test`, to be run on a target.

### Sanitizers and coverage

The Clang sanitizers are off by default and **mutually exclusive** — each
changes the ABI/runtime, so give each its own build directory and re-run the
tests there (configuring two at once is a hard error):

```sh
# AddressSanitizer
cmake -G Ninja -B build-asan -S . --toolchain cmake/toolchain-clang.cmake -DENABLE_ASAN=ON
cmake --build build-asan && ctest --test-dir build-asan

# UndefinedBehaviorSanitizer (built with -fno-sanitize-recover, so it aborts)
cmake -G Ninja -B build-ubsan -S . --toolchain cmake/toolchain-clang.cmake -DENABLE_UBSAN=ON
cmake --build build-ubsan && ctest --test-dir build-ubsan

# ThreadSanitizer
cmake -G Ninja -B build-tsan -S . --toolchain cmake/toolchain-clang.cmake -DENABLE_TSAN=ON
cmake --build build-tsan && ctest --test-dir build-tsan
```

Code coverage (LLVM source-based; needs `llvm-profdata` / `llvm-cov`):

```sh
cmake -G Ninja -B build-cov -S . --toolchain cmake/toolchain-clang.cmake -DENABLE_COVERAGE=ON
cmake --build build-cov && ctest --test-dir build-cov
cmake --build build-cov --target coverage-html   # also: coverage-collect, coverage-report
```

### Fuzzing (Linux)

Fuzzing uses Clang's built-in libFuzzer (`-fsanitize=fuzzer`). It defaults **ON
with Clang on Linux** and **OFF on macOS** (the macOS path builds the fuzzer
sources as plain executables). With it enabled, two aggregate targets
auto-discover every `*_fuzzer` binary in the build tree:

```sh
cmake -G Ninja -B build -S . --toolchain cmake/toolchain-clang.cmake -DENABLE_FUZZING=ON
cmake --build build
cmake --build build --target fuzz-smoke   # run each fuzzer once with a seed (quick check)
cmake --build build --target fuzz-all     # campaign: ~30s per fuzzer, corpus under build/fuzz/
```

For reproducible, containerized campaigns (Debian + libc++, the packages that
define fuzzers are `crypto` and `avb`), use the wrapper instead — see
[Debian packages](#debian-packages) below:

```sh
./container-fuzz.sh            # all fuzzers; FUZZ_DURATION=60 ./container-fuzz.sh avb to tune
```

### IDE setup

The repo ships a `CMakePresets.json`, so most IDEs configure with no manual
setup — just select a preset:

- **`default`** — aggregate build with the pinned clang/libc++ toolchain
  (`RelWithDebInfo`, `compile_commands.json` on). Use this for day-to-day work.
- **`dev`** — same, plus `-Werror` (the strict CI build).
- **`asan`** — AddressSanitizer build in `build-asan/`.

IDEs that read `CMakePresets.json` natively: **CLion** (2021.1+),
**Visual Studio** (2019 16.10+ / 2022), **VS Code** with the CMake Tools
extension, and **Qt Creator** (recent). From the command line:

```sh
cmake --preset default
cmake --build --preset default
ctest --preset default              # the unit tests
ctest --preset default-functional   # the functional tests
```

Without presets, point your IDE's CMake options at the toolchain file directly:
`--toolchain cmake/toolchain-clang.cmake`.

### Debian packages

Reproducible `.deb` builds for each library run in a Debian container (needs
`podman` or `docker`):

```sh
./container-build.sh             # build every package's .deb into deb-output/
./container-build.sh avb         # build avb and its dependencies only
./container-build-cross.sh       # cross-compile arm64 .debs (no qemu, no tests)
./container-fuzz.sh              # run the libFuzzer campaigns (crypto, avb)
```

On a Debian- or Fedora/RHEL-based machine the same packages can be built
natively, for that machine, with no container at all. `local-build-debs.sh`
and `local-build-rpms.sh` (one script, `local-build-packages.sh`, with the
format fixed) walk the packages in dependency order, stage each one's install
under `build-debs/stage/` (or `build-rpms/stage/`) so the next package's
`find_package()` finds it, and write the packages to `deb-output-local/` or
`rpm-output-local/` (kept apart from the container builds, whose file names
are identical). They need no root to build; `--install-prereqs` runs the one
`apt-get install` / `dnf install` for the toolchain and development
libraries. A package that opts out of RPMs (`NO_RPM`, e.g. a private
DEB-only extension) is skipped by the rpm build.

```sh
./local-build-debs.sh --install-prereqs   # Debian: first time, install the prerequisites
./local-build-debs.sh                     # Debian: build every package's .deb natively
./local-build-rpms.sh                     # Fedora/RHEL: build every package's .rpm natively
./local-build-debs.sh avb                 # avb and its dependencies only
STATUSBAR_TOOLCHAIN=gcc ./local-build-debs.sh   # gcc/libstdc++ instead of clang/libc++
```

### Formatting

```sh
./reformat.sh                    # format all packages in place
./reformat.sh --check           # CI mode: non-zero exit if anything would change
```
