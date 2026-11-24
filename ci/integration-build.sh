#!/usr/bin/env bash
#
# Integration build for a statusbar PR push. Invoked detached by ci/post-receive
# with REPO_NAME / BRANCH / SHA in the environment.
#
# It builds the WHOLE umbrella with exactly one submodule swapped to the pushed
# PR commit, in a persistent clone (warm ccache + incremental build dirs):
#
#   1. reset the persistent umbrella clone to its integration base (main)
#   2. bring every submodule to the umbrella's pinned commit  (INTEGRATE_MODE=pinned)
#      or to each submodule's origin/main                     (INTEGRATE_MODE=mains)
#   3. swap the changed submodule to the PR commit (or, for a push to the
#      umbrella itself, check the umbrella out at the PR commit)
#   4. run: aggregate cmake build + ctest, local-build.sh, container-build.sh
#
# A push to `pr/foo` of statusbar-core therefore answers: "does the rest of the
# umbrella still build and pass with this core change?" — without bumping any
# gitlink.
set -uo pipefail   # NOT -e: we attempt every build step and report all results

: "${REPO_NAME:?set by the hook}" "${BRANCH:?}" "${SHA:?}"

# --- config (override via env in the hook or a wrapper) ----------------------
CI_ROOT="${CI_ROOT:-/srv/ci/statusbar}"       # persistent umbrella clone
UMBRELLA_REPO="${UMBRELLA_REPO:-statusbar}"   # bare repo name of the umbrella
UMBRELLA_BRANCH="${UMBRELLA_BRANCH:-main}"    # integration base branch
INTEGRATE_MODE="${INTEGRATE_MODE:-pinned}"    # pinned | mains  (see step 2 above)
LOCK="${LOCK:-/srv/ci/ci-statusbar.lock}"     # serializes builds on the clone
RUN_AGGREGATE="${RUN_AGGREGATE:-1}"           # cmake --preset default + ctest -> build/
RUN_LOCAL="${RUN_LOCAL:-1}"                   # ./local-build.sh           -> build-local/
RUN_CONTAINER="${RUN_CONTAINER:-1}"           # ./container-build.sh       -> deb-output/
NOTIFY="${NOTIFY:-}"                          # optional: command run on FAIL, summary on stdin
export PATH="${CI_PATH:-/usr/local/bin:/usr/bin:/bin}"   # toolchain visible to a bare hook env
# ----------------------------------------------------------------------------

# Hooks inherit git's quarantine/object env; clear it so our own git ops are clean.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_QUARANTINE_PATH GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

# Map the pushed repo to a submodule path: statusbar-core -> core; umbrella -> "umbrella".
if [ "$REPO_NAME" = "$UMBRELLA_REPO" ]; then
  submod=umbrella
else
  submod="${REPO_NAME#statusbar-}"
fi

started="$(date -u +%FT%TZ)"
echo "### statusbar integration build"
echo "### repo=$REPO_NAME submodule=$submod branch=$BRANCH sha=$SHA"
echo "### mode=$INTEGRATE_MODE base=$UMBRELLA_BRANCH start=$started"
echo

# Serialize builds on the shared persistent clone.
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK" || { echo "cannot open lock $LOCK"; exit 1; }
flock 9        || { echo "cannot acquire lock $LOCK"; exit 1; }

cd "$CI_ROOT" || { echo "persistent clone $CI_ROOT not found (see ci/README.md)"; exit 1; }

run() {  # run "<label>" cmd... ; logs banners, returns the command's exit code
  local label="$1"; shift
  echo "----- $label -----"
  if "$@"; then echo "----- $label: OK -----"; return 0; fi
  local rc=$?; echo "----- $label: FAILED (exit $rc) -----"; return "$rc"
}

prepare() {
  git fetch -q origin                                       || return 1
  git checkout -q -f "$UMBRELLA_BRANCH"                     || return 1
  git reset -q --hard "origin/$UMBRELLA_BRANCH"            || return 1
  git submodule sync -q --recursive
  git submodule update -q --init --recursive --force        || return 1

  if [ "$INTEGRATE_MODE" = mains ]; then
    git submodule foreach -q --recursive \
      'git fetch -q origin && git checkout -q -f origin/main 2>/dev/null || true'
  fi

  if [ "$submod" = umbrella ]; then
    git checkout -q -f "$SHA"                               || return 1
    git submodule update -q --init --recursive --force      || return 1
  else
    [ -d "$submod" ] || { echo "no submodule dir '$submod' in $CI_ROOT"; return 1; }
    git -C "$submod" fetch -q origin "$BRANCH"              || return 1
    git -C "$submod" checkout -q -f "$SHA"                  || return 1
    git -C "$submod" submodule update -q --init --recursive --force 2>/dev/null || true
  fi
}

status=0
run "prepare integration tree" prepare || status=$?

if [ "$status" -eq 0 ]; then
  if [ "$RUN_AGGREGATE" = 1 ]; then
    run "aggregate cmake build + tests" bash -c \
      'cmake --preset default && cmake --build --preset default && ctest --preset default &&
       { [ "${STATUSBAR_SKIP_FUNCTIONAL_TESTS:-0}" = 1 ] || ctest --preset default-functional; }' \
      || status=$?
  fi
  if [ "$RUN_LOCAL" = 1 ]; then
    run "local-build.sh" env BUILD_DIR=build-local ./local-build.sh || status=$?
  fi
  if [ "$RUN_CONTAINER" = 1 ]; then
    run "container-build.sh (.debs)" ./container-build.sh || status=$?
  fi
fi

finished="$(date -u +%FT%TZ)"
echo
echo "### result: $([ "$status" -eq 0 ] && echo PASS || echo FAIL) (exit $status)"
echo "### start=$started finish=$finished"

if [ "$status" -ne 0 ] && [ -n "$NOTIFY" ]; then
  printf 'statusbar CI FAIL\nrepo=%s submodule=%s\nbranch=%s sha=%s\nexit=%s\n' \
    "$REPO_NAME" "$submod" "$BRANCH" "$SHA" "$status" | $NOTIFY || true
fi

exit "$status"
