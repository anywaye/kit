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
# ONE AGENT PER PROJECT, AND THIS FILE IS THE AGENT. A sandbox hosts several
# projects (the plan caps sandboxes at five and the fleet is larger), so the
# supervisor starts one of these per project, each bound to its own
# environment file and its own log by ~/ci/agents/<project>.sh — see
# backends/instabox/supervisor.sh and backends/instabox/provision.sh. The
# binding is three variables, so this file does not know how many projects
# exist:
#
#   CI_ENV        the KEY=value environment for THIS project
#                 (default: $HOME/.ci-env, the single-project legacy path)
#   AGENT_NAME    the project name, used in messages and the lock name
#                 (default: PROJECT_NAME)
#   AGENT_RUN_LOG where this agent's last pipeline run is logged
#                 (default: $HOME/ci-last-run.log)
#
# Environment comes from $CI_ENV, one KEY=value per line, written by
# provision. The pipeline sees those plus WORKSPACE, GH_TOKEN and CI — see
# backends/README.md for the contract.
#
# ONE LOCK PER AGENT, because a poller that is started twice is a project that
# is built twice concurrently. The supervisor can race itself across a
# restart, and an operator can start one by hand; flock is what makes the
# second copy exit rather than run beside the first. flock is Linux-only and
# the sandbox is Linux, but a machine without it degrades to no lock rather
# than refusing to poll.
set -euo pipefail

CI_ENV="${CI_ENV:-$HOME/.ci-env}"
if [ -f "$CI_ENV" ]; then
  set -a
  # shellcheck disable=SC1090  # $CI_ENV is a path chosen by the caller, not a literal
  . "$CI_ENV"
  set +a
fi

PROJECT_REPO_URL="${PROJECT_REPO_URL:?set PROJECT_REPO_URL in $CI_ENV}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_REPO_URL" .git)}"
AGENT_NAME="${AGENT_NAME:-$PROJECT_NAME}"
BRANCH="${CI_BRANCH:-master}"
WORKSPACE="${WORKSPACE:-$HOME/workspace}"
INTERVAL="${CI_POLL_SECONDS:-120}"
RUN_LOG="${AGENT_RUN_LOG:-$HOME/ci-last-run.log}"

export WORKSPACE CI=1

# The lock is taken before the first fetch and held for the process's whole
# life, so a second agent for the same project exits instead of polling beside
# this one. A per-sandbox workspace means a per-sandbox lock directory.
#
# `mkdir` is the lock, and it is chosen over `flock` because it is the same
# mechanism on every machine this runs on: the sandbox is Linux, where the
# fleet also develops on macOS, and `flock` is a util-linux binary macOS does
# not ship. `mkdir` is atomic everywhere. The pid inside it is what makes a
# SIGKILLed agent's lock recoverable rather than permanent.
LOCK_ROOT="${CI_LOCK_DIR:-$WORKSPACE/.ci-locks}"
LOCK_DIR="$LOCK_ROOT/$AGENT_NAME.lock"
mkdir -p "$LOCK_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "agent[$AGENT_NAME]: another agent (pid $holder) holds $LOCK_DIR — exiting"
    exit 0
  fi
  # The holder is gone; its lock outlived it. Take it over.
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "agent[$AGENT_NAME]: lost the race for $LOCK_DIR — exiting"
    exit 0
  fi
fi
echo "$$" >"$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

mkdir -p "$WORKSPACE/cafaye"
PROJECT_DIR="$WORKSPACE/cafaye/$PROJECT_NAME"

cd "$WORKSPACE/cafaye"
if [ -d "$PROJECT_DIR/.git" ]; then
  echo "agent[$AGENT_NAME]: found $PROJECT_DIR"
else
  echo "agent[$AGENT_NAME]: cloning $PROJECT_REPO_URL"
  git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/cafaye/${PROJECT_NAME}.git" "$PROJECT_DIR" 2>/dev/null \
    || git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/cafaye/${PROJECT_NAME}.git" "$PROJECT_DIR"
fi

last=""
while true; do
  if git -C "$PROJECT_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    remote="$(git -C "$PROJECT_DIR" rev-parse FETCH_HEAD)"
    if [ "$remote" != "$last" ]; then
      last="$remote"
      echo "agent[$AGENT_NAME]: $PROJECT_NAME $BRANCH is $remote — running its pipeline"
      git -C "$PROJECT_DIR" reset --hard FETCH_HEAD --quiet
      if bash "$PROJECT_DIR/ci/pipeline.sh" >"$RUN_LOG" 2>&1; then
        echo "agent[$AGENT_NAME]: $PROJECT_NAME shipped $remote"
      else
        echo "agent[$AGENT_NAME]: $PROJECT_NAME failed on $remote — see $RUN_LOG"
      fi
    fi
  fi
  sleep "$INTERVAL"
done
