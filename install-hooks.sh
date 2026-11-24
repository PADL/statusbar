#! /bin/sh
# Copyright 2026 Jeff Koftinoff <jeff.koftinoff@statusbar.com>
# SPDX-License-Identifier: MIT

# Install the pre-commit hook into the umbrella repo and every initialized
# submodule. The hook runs `sh reformat.sh --check` at the repo root and
# refuses the commit if anything would be reformatted; repos without a
# reformat.sh (rtkernel, linuxptp4avb) get the same hook, which no-ops.
#
# It then runs core's check-block-statements.sh on the staged C++ -- the
# house rule that bounds the statements in one block, enforced only on the
# lines a commit touches. The script lives in core and checks whichever repo
# the hook runs in; its absolute path is written into each hook here, so no
# hook guesses at a relative one. It exits 0 without checking when the
# clang-tidy plugin or a configured build directory is missing, so the hook
# stays quiet on a machine that has not built them.
#
# With --functional the hook also runs the repo's functional tests, with
# core's run-functional-tests.sh: the tests on real sockets and a real kernel.
# A build already runs them (local-build.sh, and so CI), so this step is off
# unless asked for. It runs when the staged change touches C++ or CMake and a
# configured build directory is there to run them from; without one the script
# says so and lets the commit through. STATUSBAR_SKIP_FUNCTIONAL_TESTS=1 skips
# it for one commit. Running install-hooks.sh again without the option takes
# the step back out.
#
# Re-run after cloning or after `git submodule update --init`.

set -e

functional=0
case "${1:-}" in
    --functional) functional=1 ;;
    "") ;;
    *)
        echo "usage: $0 [--functional]" >&2
        exit 2
        ;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
GATE="$ROOT/core/check-block-statements.sh"
FUNCTIONAL="$ROOT/core/run-functional-tests.sh"

# The optional third step: the functional tests of the repo the hook runs in.
write_functional_step() {
    echo "# The functional tests of the repo this hook runs in (install-hooks.sh --functional)."
    printf "FUNCTIONAL='%s'\n" "$FUNCTIONAL"
    cat <<'EOF'
if [ -f "$FUNCTIONAL" ] && ! sh "$FUNCTIONAL"; then
    echo "" >&2
    echo "pre-commit: functional tests failed." >&2
    echo "Fix them, or commit once without them: STATUSBAR_SKIP_FUNCTIONAL_TESTS=1 git commit ..." >&2
    exit 1
fi
EOF
}

write_hook() {
    hooks_dir=$1
    mkdir -p "$hooks_dir"
    {
        cat <<'EOF'
#! /bin/sh
# Installed by install-hooks.sh — edit there, not here.
# Refuse the commit if reformat.sh --check reports formatting drift.
[ -f reformat.sh ] || exit 0
# The pinned formatters install via pipx into ~/.local/bin (see
# requirements-format.txt); prefer that over any newer system/brew copy.
PATH="$HOME/.local/bin:$PATH"
if ! sh reformat.sh --check; then
    echo "" >&2
    echo "pre-commit: formatting check failed." >&2
    echo "Fix with 'sh reformat.sh', restage, and commit again." >&2
    exit 1
fi
# The block-statements house rule, on the staged C++ only. The gate lives in
# core and checks the repo this hook runs in.
EOF
        printf "GATE='%s'\n" "$GATE"
        cat <<'EOF'
if [ -f "$GATE" ] && ! sh "$GATE"; then
    echo "" >&2
    echo "pre-commit: block-statements check failed." >&2
    echo "Split the block, or mark its brace with a reason, and restage." >&2
    exit 1
fi
EOF
        if [ "$functional" = 1 ]; then
            write_functional_step
        fi
    } > "$hooks_dir/pre-commit"
    chmod +x "$hooks_dir/pre-commit"
}

# The umbrella repo itself.
hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks)
write_hook "$hooks_dir"
echo "installed pre-commit hook: . -> $hooks_dir"

# Every initialized submodule. --git-path resolves the .git-file indirection
# into .git/modules/<name>/hooks.
git config --file .gitmodules --get-regexp '^submodule\..*\.path$' \
    | while read -r _ sm; do
    if [ ! -e "$sm/.git" ]; then
        echo "skipping $sm: submodule not initialized"
        continue
    fi
    hooks_dir=$(git -C "$sm" rev-parse --path-format=absolute --git-path hooks)
    write_hook "$hooks_dir"
    echo "installed pre-commit hook: $sm -> $hooks_dir"
done
