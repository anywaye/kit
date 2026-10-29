#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tests/tenant_isolation"

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

SESSION="${KIT_TENANT_SESSION:-$$}"
case "$SESSION" in
  '' | *[!0-9]*)
    say "cross_tenant_harness: KIT_TENANT_SESSION=$SESSION is not a number."
    say "  It is the pid, and it seeds the published host port, so it has to be one."
    exit 2
    ;;
esac
export KIT_TENANT_SESSION="$SESSION"

say() { printf '%s\n' "$*"; }
die() {
  printf 'cross_tenant_harness: %s\n' "$*" >&2
  exit 2
}

find_service() {
  if [ -z "${KIT_SERVICE_REPO:-}" ]; then
    die "KIT_SERVICE_REPO is not set. This harness grades a service you name, and there is no default: point it at the checkout, e.g. KIT_SERVICE_REPO=../courier $0 up. Exiting 2: nothing was proven, which is not the same as having passed."
  fi
  [ -d "$KIT_SERVICE_REPO" ] || die "KIT_SERVICE_REPO=$KIT_SERVICE_REPO is not a directory."
  ( cd "$KIT_SERVICE_REPO" && pwd )
}

load_adapter() {
  local adapter="${KIT_TENANT_ADAPTER:-$HERE/adapters/elixir.sh}"
  [ -r "$adapter" ] || die "no adapter at $adapter. The contract is in $HERE/adapters/README.md."
  . "$adapter"
}

tenant_harness_up() {
  [ -n "$TIMEOUT_BIN" ] || die "no \`timeout\` on PATH (GNU coreutils, or Homebrew's gtimeout). Every command this harness runs is bounded with it; a run that cannot bound itself is not a run."
  command -v docker >/dev/null 2>&1 || die "docker is not on PATH. This harness runs the service's real query layer against a real database; there is no substitution for one, so the run exits 2 rather than reporting a green."
  load_adapter
  command -v "$(adapter_language_tool)" >/dev/null 2>&1 || die "'$(adapter_language_tool)' is not on PATH, and it is the only way this harness can execute the service's query layer."

  local service
  service="$(find_service)"

  local project="kit-tenant-iso-$SESSION"

  local base=$(( 15500 + (SESSION % 400) )) port="" p=0
  while [ "$p" -lt 40 ]; do
    port=$(( base + p ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then break; fi
    exec 3<&- 2>/dev/null || true
    port=""
    p=$(( p + 1 ))
  done
  [ -n "$port" ] || die "no free port in $base..$(( base + 39 ))."

  WORK="${TMPDIR:-/tmp}/kit-tenant-iso.$SESSION"
  rm -rf "$WORK"
  mkdir -p "$WORK" || die "could not create $WORK."
  KIT_TENANT_PROJECT="$project"
  KIT_TENANT_PGPORT="$port"
  KIT_TENANT_SERVICE="$service"
  export KIT_TENANT_WORK="$WORK" KIT_TENANT_PROJECT KIT_TENANT_PGPORT KIT_TENANT_SERVICE
  export KIT_TENANT_ADAPTER_DIR="$HERE/adapters"

  say "harness: up — $project on host port $port (postgres:17), session $SESSION"
  if ! "$TIMEOUT_BIN" 180 docker run -d --rm \
    --name "$project" \
    -p "$port:5432" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=postgres \
    postgres:17 >"$WORK/pg.cid" 2>"$WORK/pg.err"; then
    sed 's/^/  /' "$WORK/pg.err" >&2
    die "the database did not start. Exiting 2."
  fi

  local i
  for i in $(seq 1 60); do
    if "$TIMEOUT_BIN" 10 docker exec "$project" pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  [ "$i" -lt 60 ] || die "Postgres did not accept a connection within 60s. Exiting 2."

  say "harness: preparing a throwaway copy of $(basename "$service")"
  adapter_prepare || die "the adapter could not prepare the service copy. Exiting 2."
  adapter_migrate || die "the service's own migrations did not apply to a real database. Exiting 2 — a harness that seeds into a schema nobody migrated proves nothing."
  adapter_install_probe || die "the negative suite did not install into the service copy. Exiting 2."

  {
    printf 'KIT_TENANT_WORK=%s\n' "$KIT_TENANT_WORK"
    printf 'KIT_TENANT_PROJECT=%s\n' "$KIT_TENANT_PROJECT"
    printf 'KIT_TENANT_PGPORT=%s\n' "$KIT_TENANT_PGPORT"
    printf 'KIT_TENANT_SERVICE=%s\n' "$KIT_TENANT_SERVICE"
    printf 'KIT_TENANT_ADAPTER_DIR=%s\n' "$KIT_TENANT_ADAPTER_DIR"
  } >"$WORK/session.env"
}

tenant_harness_run() {
  local needle="$1"
  [ -n "$needle" ] || die "run needs a test name to filter on."
  [ -n "${KIT_TENANT_WORK:-}" ] || die "run without up: nothing is running. Exiting 2."
  load_adapter
  adapter_run "$needle"
}

tenant_harness_down() {
  if [ -n "${KIT_TENANT_PROJECT:-}" ]; then
    "$TIMEOUT_BIN" 60 docker rm -f "$KIT_TENANT_PROJECT" >/dev/null 2>&1 || true
  fi
  if [ -n "${KIT_TENANT_WORK:-}" ]; then
    rm -rf "$KIT_TENANT_WORK"
  fi
  say "harness: down."
}

harness_cli() {
  case "${1:-}" in
  up)
    tenant_harness_up
    say "harness: work dir $KIT_TENANT_WORK"
    ;;
  run | down)
    env_file="${TMPDIR:-/tmp}/kit-tenant-iso.$SESSION/session.env"
    if [ ! -r "$env_file" ]; then
      die "no session $SESSION at $env_file. Run \`up\` first, exporting KIT_TENANT_SESSION=$SESSION so \`run\` and \`down\` find the same database. Exiting 2."
    fi
    . "$env_file"
    export KIT_TENANT_WORK KIT_TENANT_PROJECT KIT_TENANT_PGPORT KIT_TENANT_SERVICE KIT_TENANT_ADAPTER_DIR
    if [ "${1:-}" = run ]; then
      tenant_harness_run "${2:-}"
    else
      tenant_harness_down
    fi
    ;;
  *)
    cat >&2 <<'USAGE'
cross_tenant_harness.sh — run a service's real query layer against a real
database with two accounts seeded, and assert on what came back.

  up                       bring up Postgres, build the service copy, migrate,
                           install the negative suite
  run '<test name>'        run the suite filtered to one test
  down                     remove the container and the work dir

Environment:
  KIT_TENANT_SESSION       one session for up/run/down. Default: this shell's pid.
                           A caller making three invocations must export it.
  KIT_SERVICE_REPO         the service checkout. REQUIRED -- there is no
                           default, and no search for one.
  KIT_TENANT_ADAPTER       the adapter. Default: adapters/elixir.sh.
USAGE
    exit 2
    ;;
esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  harness_cli "$@"
fi
