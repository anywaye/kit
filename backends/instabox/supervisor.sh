#!/usr/bin/env bash
# kit/backends/instabox/supervisor.sh — one supervisor, one agent per project.
#
# Runs on the sandbox, like agent.sh. Its whole job is: for every project an
# operator provisioned, keep that project's poller alive.
#
# WHY IT EXISTS. The plan caps sandboxes at five and the fleet is larger, so
# one sandbox hosts several projects — each a separate poller process. Some-
# thing has to start them all and restart the one that dies: a poller that
# exits on a transient git error is a project that silently stops building,
# and nothing on the sandbox would say so. That silent stop is the failure
# this file prevents.
#
# ONE AGENT PER PROJECT, EACH ITS OWN FILE. provision.sh writes
# ~/ci/agents/<project>.sh — a binding of the shared agent.sh to one project's
# environment (CI_ENV), one name (AGENT_NAME) and one log (AGENT_RUN_LOG). The
# supervisor's world model is that directory: a file in it is a project, and
# adding a project is provisioning it. It never reads a project list, so a
# project cannot be "configured but not supervised" — the two are the same
# act.
#
# RESTART POLICY. `--once` reconciles and returns; provision.sh runs it after
# writing the agents so a failure is visible in that command's output.
# `--loop` reconciles, then reconciles again every SUPERVISOR_INTERVAL seconds
# (default 60). The loop is the restart policy, and it is deliberately not a
# `cron @reboot` line: a poller restarting on the supervisor's cadence is the
# same guarantee on a sandbox that never reboots, and one moving part instead
# of two.
#
# ONE SUPERVISOR, and that is a lock rather than a convention. Two supervisors
# racing the same agents would each see a dead pid and each start a copy. The
# lock is taken for the process's whole life with flock, so the second
# `--loop` exits instead of doubling every poller. flock is Linux-only and the
# sandbox is Linux; without it this degrades to the racy behaviour rather than
# refusing to supervise.
#
# EVERY LONG-RUNNING THING IS BOUNDED: the loop sleeps a fixed interval, and
# an agent is started detached so the loop never waits on a gate.
set -euo pipefail

AGENTS_DIR="${AGENTS_DIR:-$HOME/ci/agents}"
LOG_DIR="${LOG_DIR:-$HOME/ci-logs}"
RUN_DIR="${RUN_DIR:-$HOME/ci/run}"
INTERVAL="${SUPERVISOR_INTERVAL:-60}"
LOCK_DIR="${SUPERVISOR_LOCK:-$RUN_DIR/supervisor.lock}"

MODE="${1:---once}"
case "$MODE" in
  --once) LOOP=0 ;;
  --loop) LOOP=1 ;;
  *) echo "supervisor: usage: supervisor.sh [--once|--loop]" >&2; exit 2 ;;
esac

mkdir -p "$AGENTS_DIR" "$LOG_DIR" "$RUN_DIR"

log() { printf '%s supervisor: %s\n' "$(date -u +%FT%TZ)" "$*"; }

# One supervisor, held for the process's life. `mkdir` is the lock — the same
# atomic mechanism on the Linux sandbox and on a developer's macOS machine,
# where `flock` does not exist — and the pid inside it means a killed
# supervisor's lock is recoverable rather than permanent. A second copy is not
# an error to report: it is the same intent arriving twice, so it exits 0.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    log "another supervisor (pid $holder) holds $LOCK_DIR — exiting"
    exit 0
  fi
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "lost the race for $LOCK_DIR — exiting"
    exit 0
  fi
fi
echo "$$" >"$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# running <project> — is the pid recorded for it a live process?
running() {
  local pidfile="$RUN_DIR/$1.pid" pid
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# start <project> — launch the project's agent, detached, with its own log.
# `setsid` is what makes it outlive the ssh session that started provision;
# where it is absent, `nohup` is the fallback the single-project provisioner
# always used.
start() {
  local p="$1" agent logf
  agent="$AGENTS_DIR/$p.sh"
  logf="$LOG_DIR/$p.log"
  if [ ! -f "$agent" ]; then
    log "no agent at $agent — skipping $p"
    return 1
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$agent" >>"$logf" 2>&1 &
  else
    nohup bash "$agent" >>"$logf" 2>&1 &
  fi
  echo "$!" >"$RUN_DIR/$p.pid"
  log "started $p (pid $!) -> $logf"
}

reconcile() {
  local agent p alive=0 started=0
  shopt -s nullglob
  for agent in "$AGENTS_DIR"/*.sh; do
    p="$(basename "$agent" .sh)"
    if running "$p"; then
      alive=$((alive + 1))
      continue
    fi
    if start "$p"; then
      started=$((started + 1))
    fi
  done
  shopt -u nullglob
  log "reconcile: $alive running, $started (re)started"
}

reconcile
if [ "$LOOP" -eq 1 ]; then
  while sleep "$INTERVAL"; do
    reconcile
  done
fi
