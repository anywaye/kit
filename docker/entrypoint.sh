#!/bin/sh
set -eu

log() { printf 'kit-entrypoint: %s\n' "$*" >&2; }
die() {
  printf 'kit-entrypoint: %s\n' "$*" >&2
  exit 1
}

[ "$#" -gt 0 ] || die "no command given — ENTRYPOINT must end with the service command, e.g. [\"/app/kit-entrypoint\", \"/app/service\"]"

mode="${KIT_MIGRATE:-auto}"
case "$mode" in
  auto | required | off) ;;
  *) die "KIT_MIGRATE='$mode' is not one of auto, required, off" ;;
esac


resolve_migrate() {
  if [ -n "${KIT_MIGRATE_CMD:-}" ]; then
    printf '%s' "$KIT_MIGRATE_CMD"
    return 0
  fi
  if [ -x ./bin/migrate ]; then
    printf '%s' "./bin/migrate"
    return 0
  fi
  if [ -x ./bin/rails ] && [ -f ./config/application.rb ]; then
    printf '%s' "./bin/rails db:prepare"
    return 0
  fi
  return 1
}

lock_acquire() {
  key="$1"
  command -v psql >/dev/null 2>&1 || die \
    "KIT_MIGRATE_ADVISORY_LOCK=$key was requested but there is no psql in this image, so the lock cannot be taken. Either install psql, or unset the variable and accept that every replica migrates concurrently."

  tmpdir="${TMPDIR:-/tmp}"
  fifo="$(mktemp -u "$tmpdir/kit-entrypoint-lock.XXXXXX")"
  mkfifo "$fifo" || die "could not create the lock FIFO at $fifo"
  locklog="$(mktemp "$tmpdir/kit-entrypoint-lock-log.XXXXXX")"

  psql "$DATABASE_URL" -q -A -t -v ON_ERROR_STOP=1 \
    -f "$fifo" >"$locklog" 2>&1 &
  lock_pid=$!
  exec 3>"$fifo"
  {
    printf "SELECT pg_advisory_lock(%s);\n" "$key"
    printf "SELECT 'kit-entrypoint:lock-held';\n"
  } >&3

  held=0
  i=0
  while [ "$i" -lt 150 ]; do
    if grep -q 'kit-entrypoint:lock-held' "$locklog" 2>/dev/null; then
      held=1
      break
    fi
    kill -0 "$lock_pid" 2>/dev/null || break
    sleep 0.2
  done

  if [ "$held" -ne 1 ]; then
    exec 3>&- 2>/dev/null || true
    printf 'kit-entrypoint: could not take advisory lock %s:\n' "$key" >&2
    sed 's/^/kit-entrypoint:   /' "$locklog" >&2 2>/dev/null || true
    die "refusing to start: the migration lock this image is configured for was not granted."
  fi
  KIT_ENTRYPOINT_LOCK_FIFO="$fifo"
  log "holding postgres advisory lock $key (session-scoped; released when this replica exits or dies)"
}

lock_release() {
  [ -n "${KIT_ENTRYPOINT_LOCK_FIFO:-}" ] || return 0
  exec 3>&- 2>/dev/null || true
  wait "${KIT_ENTRYPOINT_LOCK_PID:-0}" 2>/dev/null || true
  rm -f "$KIT_ENTRYPOINT_LOCK_FIFO"
}


migrate() {
  if ! command=$(resolve_migrate); then
    case "$mode" in
      off) log "KIT_MIGRATE=off — not migrating; the schema is whatever is already there."; return 0 ;;
      required) die \
        "KIT_MIGRATE=required and no migration command was found (looked for KIT_MIGRATE_CMD, ./bin/migrate, ./bin/rails db:prepare). Set one of them, or set KIT_MIGRATE=auto if this service genuinely owns no schema." ;;
      *) log "no migration command found (looked for KIT_MIGRATE_CMD, ./bin/migrate, ./bin/rails) — serving. Set KIT_MIGRATE=required for a service that owns a schema."; return 0 ;;
    esac
  fi

  [ -n "${DATABASE_URL:-}" ] || die \
    "DATABASE_URL is not set, so there is nothing to migrate against. The service would boot against whatever the pool defaults to, which is the failure this script exists to remove."

  if [ -n "${KIT_MIGRATE_ADVISORY_LOCK:-}" ]; then
    lock_acquire "$KIT_MIGRATE_ADVISORY_LOCK"
    KIT_ENTRYPOINT_LOCK_PID="$lock_pid"
  else
    log "no KIT_MIGRATE_ADVISORY_LOCK set — every replica runs this migration at boot. Safety is the migrate command's own idempotency. Set KIT_MIGRATE_ADVISORY_LOCK if that is not enough."
  fi

  log "migrating: $command"
  if [ -n "${KIT_ENTRYPOINT_LOCK_FIFO:-}" ]; then
    if ! sh -c "$command"; then
      lock_release
      die "migration failed: $command — the container will not start. This is deliberate; see the header of this file."
    fi
  else
    sh -c "$command" || die \
      "migration failed: $command — the container will not start. This is deliberate; see the header of this file."
  fi
  lock_release
  log "migrations applied"
}

if [ "$mode" = "off" ]; then
  log "KIT_MIGRATE=off — starting $1 without touching the schema."
else
  migrate
fi

if [ -r /app/kit-provenance.json ]; then
  kit_provenance="$(sed -n 's/.*"revision": "\([^"]*\)".*/\1/p' /app/kit-provenance.json 2>/dev/null || true)"
  log "built from ${kit_provenance:-an unstamped revision} — full stamp in /app/kit-provenance.json"
fi

exec "$@"
