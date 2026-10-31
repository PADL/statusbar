# statusbar: house conventions

The umbrella builds Jeff Koftinoff's statusbar packages (`core`, `crypto`, `audio`,
`avb`; upstream codeberg.org/statusbar) and PADL's (`aes67`, `aes70`, open, MIT;
`mediabridge`, private) as one CMake project. Derive anything not written here from
Jeff's code in `core/statusbar/{status,buffer,net}` and `avb/statusbar/{atdecc,avtp}`.

## Upstreaming boundary

- `core` and `avb` are PADL forks (`origin` = github.com/PADL, `upstream` = Codeberg);
  branch `padl` carries PADL work that is meant to go to Jeff. Everything added there
  must be generic, MIT, and keep the file's existing header
  (`// Copyright 2026 Jeff Koftinoff <jeff.koftinoff@statusbar.com>` / `SPDX MIT`).
- Generic code goes to the open package it belongs to (AES67 I/O to `aes67`, OCP.1
  encoding to `aes70`, socket helpers to `core`); `mediabridge` holds only what is the
  bridge's own. New files in `aes67`/`aes70`: `// Copyright 2026 PADL Software Pty Ltd`
  + `SPDX-License-Identifier: MIT`; in `mediabridge`: `... All rights reserved.` +
  `LicenseRef-PADL-Proprietary`.
- Nothing in `core`/`avb`/`aes67`/`aes70` may refer to PADL-internal planning
  (`MILAN_PLAN`, "stage N") in code, comments or commit messages. Cite the standard
  instead: `IEEE 1722.1-2021 Clause 7.4.40`, `Milan v1.2 Section 5.4.2.7`, `RFC 3550`.
- Never commit swap files, captures or audio (`*.swp`, `*.pcap`; see each `.gitignore`).

## Layout and naming

- One module per directory `statusbar/<module>/`; files `<module>_<topic>.hpp/.cpp`,
  tests `<module>_<topic>_test.cpp` beside the code, tools `<module>_<name>_tool.cpp`,
  fuzzers `*_fuzzer.cpp`, examples `*_example.cpp`. `<module>.hpp` is the umbrella
  header consumers include. Includes are `"statusbar/<module>/<file>.hpp"`.
- Namespace `statusbar::<module>`. Types `CamelCase`, functions/variables/members
  `snake_case` (members `trailing_`), wire constants `UPPER_CASE`, `enum class`
  enumerators `snake_case`, concepts `CamelCase`. Tools install as `statusbar-<name>`
  (`statusbar_prefix_tool_names`; `STATUSBAR_UNPREFIXED` for operator-facing daemons).
- Every module's `CMakeLists.txt` is one `statusbar_add_module(NAME SOURCES DEPS TESTS)`
  call plus its tools; register tools on `STATUSBAR_INSTALL_TARGETS`.

## C++

- C++23, Clang + libc++ (`cmake/toolchain-clang.cmake` is mandatory; GCC 16 / C++26 is a
  secondary build). No C++20 modules, no RTTI tricks, no heap on hot paths: fixed
  capacities, `std::array`, `std::span`, `sg14::inplace_function` / `inplace_vector`,
  `std::pmr` where a caller may supply memory.
- Errors are values: `Status` / `StatusValue<T>` (`std::expected<_, std::error_code>`),
  `success()`, `failure(enum)`, `forward_failure(r)`; each module has `<module>_error.hpp`
  with an `enum class XError`, a category named `statusbar.<module>`, and
  `is_error_code_enum`. Library code never throws; `throw_or_abort` is the one boundary
  (the tree builds with `ENABLE_NO_EXCEPTIONS`). Builders are sticky-error and chained.
- Signatures: trailing return types (`auto f() const noexcept -> T`), `[[nodiscard]]` on
  every query and every `Status` return, `noexcept` wherever true, east const
  (`T const&`), `explicit` single-argument constructors, `= default` destructors.
- Wire formats are packed structs of `ieee::octet_t/doublet_t/quadlet_t/octlet_t` with
  `static_assert` on size and offsets; parsing goes through `buffer` (never hand-shifted
  bytes or bare `memcpy`: use `span_utils`).
- Blocks are short (Jeff's rule): about 4 statements directly inside a `{}` (each `if`/`for`/
  `return` counts, a nested block once); the gate fails changed blocks over 6. Split multi-step
  procedures into named phases; leave tables, codecs, `switch` bodies and many-field resets whole
  with `// NOLINT(statusbar-block-statements): <reason>`. Early return, no `else` after `return`.
  Never scatter logic into tiny functions or pack lines to hit the number; 7-8 beats that.
  Enforced by core's `statusbar-block-statements` clang-tidy plugin and the pre-commit gate
  (`core/cmake/check-block-statements.sh`; tests and fuzzers exempt).
- Real-time threads never allocate, block, lock or log; cross-thread state goes through
  `itc` (`SeqlockValue`, `LatestPipe`, `MessagePipe`). Designs are event-driven: one
  initial fetch, then events; do not add polling or "snapshots".
- Dedicated-device rule: do not add machinery for misbehaviour that cannot happen on a
  single-purpose box (rate limits on local clients, wedged-socket rebinds). Fix real
  bugs; otherwise choose the simplest thing and say so in the commit message.

## Comments and documentation

- `#pragma once`, blank line, copyright + SPDX, blank line, a `///` paragraph saying what
  the file is, then includes (`"statusbar/..."` first, then system `<x.h>`, then `<std>`;
  clang-format regroups them). `///` on every public declaration, one to three lines,
  stating the contract (units, ownership, when it may be called, what it returns on
  failure). Section banners are `//\n// Title - Clause N\n//`.
- Keep comments to three lines or fewer. The reasoning, the spec exegesis and the
  bench observations go to the module doc, `docs/*.md` or the commit body, not the code.
  Cite the clause (`IEEE 1722.1-2021 Clause 6.2.1.5`) rather than paraphrasing it.
- Each module has `docs/<MODULE>_MODULE.md` with exactly these sections: Overview, Key
  types, Quick example, Headers, Dependencies, Notes & caveats, Further reading, linked
  from `docs/README.md`'s table. Longer topics get their own `docs/<TOPIC>.md`. Package
  READMEs list modules in a table and keep a `Status:` line. Prose is present tense,
  imperative for instructions, no marketing.

## Tests

- The `test` module only: `TEST(group, name) { EXPECT_TRUE/FALSE/EQ/NE }` and a closing
  `TEST_MAIN(<module>_<topic>, <file stem>)`; the file name must match. Groups are
  `<module>_<thing>` or the type under test; names are snake_case statements of the
  behaviour (`a_refused_rate_change_is_undone`, `late_frames_are_dropped`), never
  `test1`. Tests are self-contained (no ordering, no network, no root); feed state
  machines crafted frames and fake clocks. Fuzzers for every parser. A test that
  needs root (veth + BPF) skips cleanly when unprivileged and is run as root on
  the bench box before its change is pushed.
- One `statusbar_test` binary; ctest names are `statusbar/<module>/<file>_test`.
  Hardware-dependent behaviour (AF_XDP zero-copy, cbs shaping, PTP lock, Dante/Milan
  interop) is verified on the bench box and recorded in `mediabridge/docs/TESTBED.md`
  / `PROVISIONING.md`, not faked in unit tests.

## Build, lint, format

- `PATH=/snap/bin:$PATH LLVM_PATH=/usr/lib/llvm-20 ./local-build.sh` (cmake >= 3.31,
  clang >= 19 with matching libc++; apt cmake and the swiftly clang do not work). One
  build dir per variant: `BUILD_DIR=build-asan ./local-build.sh -DENABLE_ASAN=ON`.
  `ctest --test-dir build -R <module>` for one module. `-Werror` is on.
- `sh reformat.sh` (clang-format 19.1.7 pinned, cmake-format, ruff) in the package you
  touched; `install-hooks.sh` installs the pre-commit check. Never hand-wrap what
  clang-format owns (132 columns, 4 spaces, Allman braces on types and functions).
- clang-tidy (`.clang-tidy`, `WarningsAsErrors: '*'`) must pass:
  `cmake --build build --target clang-tidy` or `-DENABLE_CLANG_TIDY=ON`. Fix the code,
  not the config; a `NOLINT` needs a reason on the same line.

## Commits

- Subject `<module>[, <module>]: <what changed>`, lower case, no period, a statement
  not an imperative (`nanoavb: TIMING served with its ptp_instances list`); `build:`,
  `docs:`, `cmake:`, `wireshark:` for the rest. Under about 72 characters.
- Body: why and what behaviour changed, in prose, spec clauses cited; what was verified
  (build variants, bench). One subsystem per commit; run `/code-review` on a new
  subsystem before its substantial commit. End with the attribution lines the session
  gives. Bump umbrella and submodule pointers together; never force-push `main`.
