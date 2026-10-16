#!/usr/bin/env bash
# kit/backends/instabox/agent.sh — the poller. Runs on the sandbox.
#
# The sandbox has no public IP, so a push-triggered build is a poll: fetch
# the project's master, and on a new commit run the project's own
# ci/pipeline.sh. The interval is the whole backend's latency, which is why
# it is an environment variable and not a constant (CI_POLL_SECONDS, default
# 120) — a fleet that pushes frequently lowers it; a nightly project raises
# it.
#
# Environment comes from $HOME/.ci-env, one KEY=value per line, written by
# provision. The pipeline sees those plus WORKSPACE, GH_TOKEN and CI — see
# backends/README.md for the contract.
set -euo pipefail

CI_ENV="${CI_ENV:-$HOME/.ci-env}"
if [ -f "$CI_ENV" ]; then
  set -a; . "$CI_ENV"; set +a
fi

PROJECT_REPO_URL="${PROJECT_REPO_URL:?set PROJECT_REPO_URL in $CI_ENV}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_REPO_URL" .git)}"
BRANCH="${CI_BRANCH:-master}"
WORKSPACE="${WORKSPACE:-$HOME/workspace}"
INTERVAL="${CI_POLL_SECONDS:-120}"

export WORKSPACE CI=1

mkdir -p "$WORKSPACE/cafaye"
PROJECT_DIR="$WORKSPACE/cafaye/$PROJECT_NAME"

cd "$WORKSPACE/cafaye"
if [ -d "$PROJECT_DIR/.git" ]; then
  echo "agent: found $PROJECT_DIR"
else
  echo "agent: cloning $PROJECT_REPO_URL"
  git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/cafaye/${PROJECT_NAME}.git" "$PROJECT_DIR" 2>/dev/null \
    || git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/cafaye/${PROJECT_NAME}.git" "$PROJECT_DIR"
fi

last=""
while true; do
  if git -C "$PROJECT_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    remote="$(git -C "$PROJECT_DIR" rev-parse FETCH_HEAD)"
    if [ "$remote" != "$last" ]; then
      last="$remote"
      echo "agent: $PROJECT_NAME $BRANCH is $remote — running its pipeline"
      git -C "$PROJECT_DIR" reset --hard FETCH_HEAD --quiet
      if bash "$PROJECT_DIR/ci/pipeline.sh" >"$HOME/ci-last-run.log" 2>&1; then
        echo "agent: $PROJECT_NAME shipped $remote"
      else
        echo "agent: $PROJECT_NAME failed on $remote — see ~/ci-last-run.log"
      fi
    fi
  fi
  sleep "$INTERVAL"
done
