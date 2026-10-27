#! /bin/sh
# Copyright 2026 Jeff Koftinoff <jeff.koftinoff@statusbar.com>
# SPDX-License-Identifier: MIT

# Install the formatting and block size pre-commit hook into the umbrella repo and every
# initialized submodule. The hook runs `sh reformat.sh --check` at the repo
# root and refuses the commit if anything would be reformatted; repos without
# a reformat.sh (rtkernel, linuxptp4avb) get the same hook, which no-ops.
#
# Re-run after cloning or after `git submodule update --init`.

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

write_hook() {
    hooks_dir=$1
    mkdir -p "$hooks_dir"
    cat > "$hooks_dir/pre-commit" <<'EOF'
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
# Block size of the staged C++ (core/cmake/check-block-statements.sh), when the umbrella build has
# the clang-tidy plugin; STATUSBAR_BUILD_DIR picks another build.
umbrella=$(git rev-parse --show-superproject-working-tree 2>/dev/null)
umbrella=${umbrella:-$(git rev-parse --show-toplevel)}
check="$umbrella/core/cmake/check-block-statements.sh"
build=${STATUSBAR_BUILD_DIR:-$umbrella/build}
if [ -f "$check" ] && [ -d "$build" ] && ! sh "$check" "$build" --staged; then
    echo "pre-commit: block size check failed." >&2
    exit 1
fi
EOF
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
