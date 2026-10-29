#!/usr/bin/env bash
set -euo pipefail

CI_ENV="${CI_ENV:-$HOME/.ci-env}"
if [ -f "$CI_ENV" ]; then
  set -a
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

LOCK_ROOT="${CI_LOCK_DIR:-$WORKSPACE/.ci-locks}"
LOCK_DIR="$LOCK_ROOT/$AGENT_NAME.lock"
mkdir -p "$LOCK_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "agent[$AGENT_NAME]: another agent (pid $holder) holds $LOCK_DIR — exiting"
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "agent[$AGENT_NAME]: lost the race for $LOCK_DIR — exiting"
    exit 0
  fi
fi
echo "$$" >"$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

mkdir -p "$WORKSPACE/anywaye"
PROJECT_DIR="$WORKSPACE/anywaye/$PROJECT_NAME"

GATE_LOCK_ROOT="${CI_GATE_LOCK_DIR:-$WORKSPACE/.ci-gate-locks}"
GATE_LOCK_DIR="$GATE_LOCK_ROOT/serial.lock"

acquire_gate_lock() {
  mkdir -p "$GATE_LOCK_ROOT"
  while ! mkdir "$GATE_LOCK_DIR" 2>/dev/null; do
    local holder
    holder="$(cat "$GATE_LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      echo "agent[$AGENT_NAME]: waiting for the serial gate lock (held by pid $holder)"
      sleep 2
    else
      rm -rf "$GATE_LOCK_DIR"
    fi
  done
  echo "$$" >"$GATE_LOCK_DIR/pid"
}

release_gate_lock() { rm -rf "$GATE_LOCK_DIR"; }

run_pipeline() {
  if [ "${CI_GATE_SERIAL:-0}" = "1" ]; then
    local rc=0
    acquire_gate_lock
    bash "$PROJECT_DIR/ci/pipeline.sh" >"$RUN_LOG" 2>&1 || rc=$?
    release_gate_lock
    return "$rc"
  fi
  bash "$PROJECT_DIR/ci/pipeline.sh" >"$RUN_LOG" 2>&1
}

cd "$WORKSPACE/anywaye"
if [ -d "$PROJECT_DIR/.git" ]; then
  echo "agent[$AGENT_NAME]: found $PROJECT_DIR"
else
  echo "agent[$AGENT_NAME]: cloning $PROJECT_REPO_URL"
  git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/anywaye/${PROJECT_NAME}.git" "$PROJECT_DIR" 2>/dev/null \
    || git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/anywaye/${PROJECT_NAME}.git" "$PROJECT_DIR"
fi

last=""
while true; do
  if git -C "$PROJECT_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    remote="$(git -C "$PROJECT_DIR" rev-parse FETCH_HEAD)"
    if [ "$remote" != "$last" ]; then
      last="$remote"
      echo "agent[$AGENT_NAME]: $PROJECT_NAME $BRANCH is $remote — running its pipeline"
      git -C "$PROJECT_DIR" reset --hard FETCH_HEAD --quiet
      if run_pipeline; then
        echo "agent[$AGENT_NAME]: $PROJECT_NAME shipped $remote"
      else
        echo "agent[$AGENT_NAME]: $PROJECT_NAME failed on $remote — see $RUN_LOG"
      fi
    fi
  fi
  sleep "$INTERVAL"
done
