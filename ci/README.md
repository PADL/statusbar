# CI — submodule-PR integration builds (SSH-only git server)

Self-hosted, dependency-free CI for the statusbar bare-git server. There is no
forge (no Gitea/Forgejo, no Actions) — just a `post-receive` git hook that, on a
push to a `pr/*` branch, builds the **whole umbrella** with the pushed submodule
swapped in.

Push `pr/foo` to `statusbar-core` → CI checks out the umbrella, leaves every
other submodule at its normal commit, swaps `core` to your PR commit, and runs
the aggregate CMake build + tests, `local-build.sh`, and `container-build.sh`.
No gitlink is ever bumped — the swap is transient, in a persistent clone.

## Files

| file | role |
| --- | --- |
| `post-receive` | shared git hook; filters `pr/*`, launches the build detached |
| `integration-build.sh` | does the swap + the three builds, in the persistent clone |

## One-time server setup (as the git user)

```sh
# 1. A persistent working clone of the umbrella (warm ccache + incremental builds).
#    Relative submodule URLs resolve to the local bare repos, so this is all local disk.
git clone /srv/git/statusbar.git /srv/ci/statusbar
cd /srv/ci/statusbar && git submodule update --init --recursive

# 2. Put the scripts where the config defaults expect them (or edit the paths).
cp /srv/ci/statusbar/ci/integration-build.sh /srv/ci/integration-build.sh
chmod +x /srv/ci/integration-build.sh

# 3. A shared hooks dir for every repo, pointing at this one hook.
mkdir -p /srv/ci/hooks /srv/ci/logs
cp /srv/ci/statusbar/ci/post-receive /srv/ci/hooks/post-receive
chmod +x /srv/ci/hooks/post-receive
git config --global core.hooksPath /srv/ci/hooks
```

`core.hooksPath` is global for the git user, so the one hook serves every repo;
it ignores any repo that is not the umbrella or a `statusbar-*` package.

> If the server fronts repos with **gitolite**, do not use `core.hooksPath`;
> install `post-receive` through gitolite's hook framework instead.

## Usage

```sh
# work on a package, then push a pr/* branch (no PR/forge needed):
git -C statusbar-core push origin HEAD:refs/heads/pr/my-change
# the push prints the log path; follow it:
ssh git@git.statusbar.com tail -f /srv/ci/logs/<stamp>.log
```

A push to a `pr/*` branch of the **umbrella** repo itself is built at that exact
commit (with its own submodule pins), instead of swapping a single submodule.

## Configuration

Both scripts read env vars with sensible defaults — edit the `--- config ---`
block or export overrides:

| var | default | meaning |
| --- | --- | --- |
| `CI_ROOT` | `/srv/ci/statusbar` | the persistent umbrella clone |
| `CI_BIN` | `/srv/ci/integration-build.sh` | build script the hook launches |
| `LOG_DIR` | `/srv/ci/logs` | per-push build logs |
| `UMBRELLA_REPO` | `statusbar` | bare repo name of the umbrella |
| `UMBRELLA_BRANCH` | `main` | integration base branch |
| `INTEGRATE_MODE` | `pinned` | `pinned` = other submodules at the umbrella's recorded commits; `mains` = at each submodule's `origin/main` |
| `RUN_AGGREGATE` / `RUN_LOCAL` / `RUN_CONTAINER` | `1` | toggle each build step |
| `STATUSBAR_SKIP_FUNCTIONAL_TESTS` | `0` | `1` leaves the functional test run out of the aggregate and local builds |
| `CI_PATH` | `/usr/local/bin:/usr/bin:/bin` | PATH for the build (clang/cmake/ninja/ccache/podman) |
| `NOTIFY` | _(unset)_ | command run on failure; a summary is piped to its stdin (e.g. `mail -s 'CI fail' you@…`) |

## Design notes & caveats

- **Integration base.** `pinned` (default) tests your PR against the umbrella's
  last known-good submodule set — reproducible. `mains` tests against the latest
  tip of every submodule. They answer different questions; pick deliberately.
- **Three builds.** The aggregate (`cmake --preset default`) and `local-build.sh`
  are nearly the same top-level build — kept in separate dirs (`build/` vs
  `build-local/`) so both stay incrementally warm. The genuinely distinct third
  build is `container-build.sh`'s `.deb`s. Set `RUN_LOCAL=0` if the overlap isn't
  worth the extra minutes.
- **Concurrency.** Builds serialize via `flock` on one warm clone — simplest and
  correct for solo use. For parallel PR builds you'd switch to `git worktree`,
  but each worktree's build dirs start cold (you lose the incremental speedup).
- **Reset hygiene.** Each run does `checkout -f` + `reset --hard` +
  `submodule update --force`, so it starts from a clean integrated state
  regardless of what the previous build left. The gitignored `build*/` and
  `deb-output/` survive — that is the speedup. Between runs `git status` in the
  clone will show a dirty submodule gitlink; that's expected and the next run
  fixes it.
- **The PR commit must be fetched.** A submodule's `pr/*` commit isn't reachable
  from the umbrella, so the script does `git -C <submod> fetch origin <branch>`
  (local disk, cheap).
- **Cleanup.** Prune merged `pr/*` refs and old `LOG_DIR` files periodically
  (a small cron job), and delete merged `pr/*` branches from the bare repos.
- **Containers.** `container-build.sh` needs `podman` (or `docker`) on the
  server and rebuilds `.deb`s by source mtime, which `checkout -f` updates
  correctly; its ccache lives in a persistent named volume.
