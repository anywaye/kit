#!/usr/bin/env bash
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

running() {
  local pidfile="$RUN_DIR/$1.pid" pid
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

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
