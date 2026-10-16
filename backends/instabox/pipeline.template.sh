#!/usr/bin/env bash
# ci/pipeline.sh — a cafaye service's pipeline, on the instabox backend or any
# other. COPY THIS FILE to `ci/pipeline.sh`, edit the MARKED places, delete
# this paragraph, and write `instabox` into `ci/backend`.
#
# WHY A SERVICE NEEDS ONE. The backend's job is only to provide an
# environment and call this script; the gate, the build and the ship are the
# project's. `bin/prime` already exists in almost every repository and
# `bin/publish` already ships an image and a chart — this file is the wiring
# between them that Actions used to hold, moved into the repository where it
# can be run by hand, by a sandbox, or by a runner.
#
# WHERE THE FACTS COME FROM: `.github/workflows/*.yml` IN THIS REPOSITORY.
# Every fact this template uses about how a repository is built — whether it
# pins a toolchain with mise, what its gate entrypoint is called, and which
# PATH entries its CI adds — is visible in its workflow files, and THAT FILE
# IS THE SOURCE OF TRUTH. When a workflow changes, change this file with it.
# The three facts, and the exact place to read each:
#
#   1. DOES IT PIN A TOOLCHAIN?  `ls mise.toml`. Every service repository in
#      the fleet has one, and its CI either runs `mise install` or names the
#      same version through a setup-* action reading it. The block below runs
#      `mise install` and then the gate under `mise exec`, so the gate runs on
#      the pinned toolchain rather than whatever the sandbox ships.
#
#   2. WHAT IS THE GATE CALLED?  `grep -A2 'name: ' .github/workflows/ci.yml`.
#      It is `bin/prime` in almost every repository, and NOT in these, which
#      is why this is a MARKED place rather than a default:
#        box        `bin/ci`      (.github/workflows/ci.yml, "gate (bin/ci)")
#        keyholder  `bin/gate`    (.github/workflows/ci.yml, "bin/gate")
#        kit        `bash tests/validate.sh` — kit has no bin/prime, and its
#                   `language: none` job runs its own gate; see its ci.yml
#      A gate a workflow names and a pipeline does not is a pipeline that is
#      green while testing nothing — read the file, do not assume.
#
#   3. DOES ITS CI ADD PATH ENTRIES?  `grep 'GITHUB_PATH' .github/workflows/*.yml`.
#      gateway's `prime` job installs golangci-lint into `$HOME/.local/bin`
#      and then appends it to PATH, because `bin/prime` exits 127 without the
#      binary. Any such line in a workflow belongs in the PATHS list below, in
#      the same order, or the gate fails on this machine for a reason that has
#      nothing to do with the tree.
#
# AND ONE FACT THIS TEMPLATE DOES NOT READ FOR YOU: whether the repository
# ships a chart (`chart/Chart.yaml`) or an image. It checks for the chart at
# run time; the publish tool itself reads `Chart.yaml`, `Dockerfile` and
# `chart/values.yaml` and refuses a malformed digest, so there is nothing to
# copy from a workflow here. `bin/publish` is `templates/bin/publish.sh` from
# kit — copy that file to `bin/publish` if this repository does not have it,
# and DO NOT reimplement a push.
#
# WHAT THE BACKEND PROVIDES (backends/README.md is the contract): WORKSPACE,
# GH_TOKEN, CI. Anything else this repository's pipeline needs — a deploy host,
# a key, a bucket — it declares, and the backend materializes it from
# `~/ci-env.d/<project>.env`. A pipeline that reads DEPLOY_HOST works on the
# instabox backend and on GitHub Actions without knowing which one ran it.
set -euo pipefail

# ---------------------------------------------------------------------------
# identity
# ---------------------------------------------------------------------------
# `run from anywhere`: the repository root is derived from this file, not from
# the caller's cwd. The agent resets the checkout to the fetched commit before
# calling us, and the pipeline does the same itself so that a hand-run is
# identical to a polled one.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
REPO_NAME="$(basename "$REPO_DIR")"

WORKSPACE="${WORKSPACE:-$(cd "$REPO_DIR/../.." && pwd)}"
BRANCH="${CI_BRANCH:-master}"
export CI="${CI:-1}"
export WORKSPACE

log() { printf '\n== %s\n' "$1"; }

log "pipeline: $REPO_NAME at $REPO_DIR"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git fetch --quiet origin "$BRANCH" 2>/dev/null || true
  git reset --hard FETCH_HEAD --quiet 2>/dev/null || true
fi

# ===========================================================================
# MARKED 1 — THE GATE. Replace `./bin/prime` with the entrypoint THIS
# repository's `.github/workflows/ci.yml` names. See the header.
# ===========================================================================
GATE=(./bin/prime)

# ===========================================================================
# MARKED 2 — PATHS THIS REPOSITORY'S CI ADDS. Copy every `echo … >> $GITHUB_PATH`
# line out of `.github/workflows/*.yml`. Example, from gateway's ci.yml:
#   PATHS=("$HOME/.local/bin")     # golangci-lint, installed by the gate job
# ===========================================================================
PATHS=()

if [ "${#PATHS[@]}" -gt 0 ]; then
  for d in "${PATHS[@]}"; do
    # One entry per directory, in the order the workflow appends them: PATH is
    # searched front to back and a later entry must not shadow an earlier one.
    export PATH="$d:$PATH"
  done
fi

log "the toolchain the repository pins"
# `mise install` materializes the versions in mise.toml; `mise exec` runs the
# gate under them, so a developer, a runner and this sandbox all use the same
# compiler. When there is no mise.toml, or no mise, the gate runs on whatever
# this machine ships — which is what the workflow does on a runner without
# the setup step, and is reported rather than hidden.
if [ -f mise.toml ] && command -v mise >/dev/null 2>&1; then
  mise install
  GATE=(mise exec -- "${GATE[@]}")
elif [ -f mise.toml ]; then
  echo "pipeline: mise.toml is present and mise is NOT on PATH — the gate runs on the machine's own toolchain"
fi

log "the gate"
# The command is a list, so a multi-word gate (`bash tests/validate.sh`) works
# without eval and nothing a project writes here is re-parsed.
"${GATE[@]}"

# ===========================================================================
# MARKED 3 — SHIP. The default is the image+chart publish this repository
# already carries. A service that deploys something else (docs rsyncs a static
# site) replaces this block; a service with no chart deletes it. Never rebuild
# what the gate just tested: publish the tree as it stands.
# ===========================================================================
if [ "${CI_DRY_RUN:-0}" = "1" ]; then
  log "gate passed; CI_DRY_RUN=1, not shipping"
  exit 0
fi

SHIPPED=""
if [ -f chart/Chart.yaml ]; then
  log "publish image + chart"
  # `--service-dir .` because we are already at the root; the tool derives the
  # image name, reads the chart's name and version from Chart.yaml, stamps the
  # chart with the PUSHED image's digest, and pushes to oci://ghcr.io/cafaye/charts.
  # It needs a registry login already in place — the operator does that once
  # with `bin/publish --sandbox` (token via stdin); see backends/README.md.
  ./bin/publish --service-dir .
  chart_name="$(sed -n 's/^name: *//p' chart/Chart.yaml | head -1)"
  chart_version="$(sed -n 's/^version: *//p' chart/Chart.yaml | head -1)"
  SHIPPED="image+chart ${chart_name}:${chart_version}"
else
  echo "pipeline: no chart/Chart.yaml — nothing to publish; the gate is the whole run"
fi

# ---------------------------------------------------------------------------
# the last line a log tail reads
# ---------------------------------------------------------------------------
# Naming WHAT shipped and the COMMIT it was built from is the whole point of
# this line: `agent[<project>]: shipped <sha>` says the pipeline returned 0,
# and this says what that meant. A run that shipped nothing says so.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$SHIPPED" ]; then
  log "pipeline: shipped $REPO_NAME $SHIPPED at $COMMIT"
else
  log "pipeline: passed $REPO_NAME at $COMMIT (nothing published)"
fi
