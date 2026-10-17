#!/usr/bin/env bash
# Build the statusbar packages as .tar.gz archives (CPack TGZ) natively on this
# machine, for this machine, without a container or any package tooling; works
# on macOS as well as Linux. See local-build-packages.sh for the options and
# knobs; this fixes the package format to tgz.
set -euo pipefail
PKG_FORMAT=tgz exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-build-packages.sh" "$@"
