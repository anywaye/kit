#!/usr/bin/env bash
#
# cross_tenant_harness.sh — the proof that a service's query layer cannot read
# another account's rows, by RUNNING it against a real database.
#
#   bash tests/tenant_isolation/cross_tenant_harness.sh up
#   bash tests/tenant_isolation/cross_tenant_harness.sh run '<test name>'
#   bash tests/tenant_isolation/cross_tenant_harness.sh down
#
# WHAT THIS IS, AND WHY IT IS NOT A LINTER
#
#   DEBT.md D18 says nothing proves one account cannot read another's data. The
#   cheap thing to build for that is a grep: find every query and check that
#   `account_id` appears near it. That is a lint, and it is blind in three ways
#   this file exists to close:
#
#     * a bind parameter passed as the PREVIOUS one — the predicate is spelled
#       correctly on the line above and the value under it is someone else's;
#     * a query that scopes correctly in production and unscoped on the error
#       path, because the error path is the branch nobody reads;
#     * an entry point that is not a query at all — `update/2` takes a struct, so
#       the predicate that scoped it lives four frames away at the load site, and
#       a per-query lint sees a clean `Repo.update`.
#
#   So this harness does not read the service's code. It builds the service,
#   brings up a real Postgres, seeds TWO accounts through the service's own
#   write path, then calls the service's own functions as account A and asserts
#   on what came back. That is also why it lives in kit rather than in the
#   service: kit has the docker fixtures and the fleet-wide shape, and a check
#   every service adopts is the only kind that stays adopted.
#
# WHY IT IS PLUGGABLE, AND WHAT "PLUGGABLE" DOES NOT MEAN
#
#   Exactly one language is implemented: `adapters/elixir.sh`, against courier.
#   The five other fleet languages are an adapter away — see
#   `tests/tenant_isolation/adapters/README.md` for the contract, which is five
#   function names and nothing else. This file contains no Elixir, no Ecto and
#   no knowledge of what courier's tables are called.
#
#   The honest claim after this harness is therefore:
#
#     "cross-tenant isolation is proven for Elixir, on a service that scopes
#      correctly. Five languages remain unproven."
#
#   Not "the fleet is isolated". A harness run once per language would let this
#   file say that, and the whole of D18 is that a reader cannot tell a proven
#   claim from an unexercised one.
#
# EVERY NAME IS DERIVED FROM THE SESSION, AND THE SESSION IS THE PID
#
#   The container name and the published host port both come from `SESSION`,
#   which defaults to this shell's pid. `tests/isolation_test.sh` records why
#   that must be so: a compose project name is the namespace for that stack's
#   containers, networks and volumes, so two concurrent runs of a hardcoded name
#   are one stack with two owners, and the second run's teardown pulls the
#   database out from under the first. Three other workers share this box, so
#   the same argument applies with nothing added. A fixed HOST PORT is the worse
#   half of it: it collides with a developer's own running stack, not merely
#   with another test run.
#
#   `SESSION` is exported by a caller that makes three invocations (`up`, then
#   `run` per case, then `down`), so that one database and one compilation serve
#   all seven cases.
#
# A RUN THAT COULD NOT HAPPEN EXITS 2, NEVER 0
#
#   No service checkout, no `timeout` binary, no docker, no language toolchain —
#   each is an unknown, and an unknown reported as a pass is the defect this
#   whole packet exists to remove.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tests/tenant_isolation"

# `timeout` is RESOLVED, not assumed: GNU coreutils calls it `timeout`, macOS has
# no /usr/bin/timeout and Homebrew's installs `gtimeout`. A suite that hardcodes
# one of them is a gate that fails on arrival on the other.
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

SESSION="${KIT_TENANT_SESSION:-$$}"
# The session id IS the port seed, so it has to be a number. A caller that passes
# a word gets a named failure here rather than an arithmetic error eleven lines
# later, which reads as a defect in the harness rather than in the invocation.
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

# --------------------------------------------------------------------------
# Locating the service under test.
#
# `KIT_SERVICE_REPO` is REQUIRED and there is no search. It used to default to
# `$ROOT/../courier` then `$ROOT/../../courier`, and that guess was a cross-repo
# reader in the same shape as the fleet checks that went with MD36: kit deciding,
# without being told, which repository it was grading. The failure it invited is
# the one kit's gate already learned the hard way -- a sweep that reaches
# further than it owns finds a checkout in a shared temp directory and reports
# on a copy, which is a finding about nobody.
#
# Naming the service is also the honest reading of what this harness is. It is
# not part of `tests/validate.sh` and no CI job runs it, because the thing it
# proves -- one service's query layer cannot see another tenant -- is only
# true of a service somebody chose. So the choice is stated rather than inferred.
# --------------------------------------------------------------------------
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
  # shellcheck source=/dev/null
  . "$adapter"
}

# --------------------------------------------------------------------------
# tenant_harness_up — the database, the service copy, the migrations, the probe.
# --------------------------------------------------------------------------
tenant_harness_up() {
  [ -n "$TIMEOUT_BIN" ] || die "no \`timeout\` on PATH (GNU coreutils, or Homebrew's gtimeout). Every command this harness runs is bounded with it; a run that cannot bound itself is not a run."
  command -v docker >/dev/null 2>&1 || die "docker is not on PATH. This harness runs the service's real query layer against a real database; there is no substitution for one, so the run exits 2 rather than reporting a green."
  load_adapter
  command -v "$(adapter_language_tool)" >/dev/null 2>&1 || die "'$(adapter_language_tool)' is not on PATH, and it is the only way this harness can execute the service's query layer."

  local service
  service="$(find_service)"

  local project="kit-tenant-iso-$SESSION"

  # A free port out of kit's claimed 15000-15999 block, derived from the session
  # and walked if the first slice is taken. /dev/tcp is the same dependency-free
  # probe stack_live_test.sh uses, for the same reason: nothing here may assume a
  # tool is installed. A busy box is not a red gate and not a green one.
  local base=$(( 15500 + (SESSION % 400) )) port="" p=0
  while [ "$p" -lt 40 ]; do
    port=$(( base + p ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then break; fi
    exec 3<&- 2>/dev/null || true
    port=""
    p=$(( p + 1 ))
  done
  [ -n "$port" ] || die "no free port in $base..$(( base + 39 ))."

  # The work directory is DERIVED, not mktemp'd, because `up`, `run` and `down`
  # are three processes and the other two have to find it. The derivation is the
  # session id, which is the pid — so two runs cannot land on one directory.
  WORK="${TMPDIR:-/tmp}/kit-tenant-iso.$SESSION"
  rm -rf "$WORK"
  mkdir -p "$WORK" || die "could not create $WORK."
  KIT_TENANT_PROJECT="$project"
  KIT_TENANT_PGPORT="$port"
  KIT_TENANT_SERVICE="$service"
  export KIT_TENANT_WORK="$WORK" KIT_TENANT_PROJECT KIT_TENANT_PGPORT KIT_TENANT_SERVICE
  export KIT_TENANT_ADAPTER_DIR="$HERE/adapters"

  # postgres:17, not a built image. This harness measures a service's QUERIES,
  # and a query's answer does not depend on which pgvector layer sits underneath
  # it; building an image to learn that would cost two minutes this box does not
  # have spare, with three other workers on it.
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

  # The state a LATER PROCESS needs — `run` and `down` are separate invocations
  # with no memory of this one — written HERE rather than in the CLI's `up` arm,
  # because a recipe that sources this file and calls tenant_harness_up directly
  # must get the same session file as one that shells out. Writing it in one place
  # is the only way those two callers cannot disagree.
  {
    printf 'KIT_TENANT_WORK=%s\n' "$KIT_TENANT_WORK"
    printf 'KIT_TENANT_PROJECT=%s\n' "$KIT_TENANT_PROJECT"
    printf 'KIT_TENANT_PGPORT=%s\n' "$KIT_TENANT_PGPORT"
    printf 'KIT_TENANT_SERVICE=%s\n' "$KIT_TENANT_SERVICE"
    printf 'KIT_TENANT_ADAPTER_DIR=%s\n' "$KIT_TENANT_ADAPTER_DIR"
  } >"$WORK/session.env"
}

# --------------------------------------------------------------------------
# tenant_harness_run <test name> — run the probe filtered to one test.
#
# The needle is an ExUnit test NAME, not a file and not a line number: kit's own
# rule is that a self-test needle must be a thing the runner EMITS, and this one
# emits test names. `--only <line>` would be the other answer and it is worse —
# a line number moves when anybody edits the file above it, and a recipe pinned
# to one dies silently and reports green.
# --------------------------------------------------------------------------
tenant_harness_run() {
  local needle="$1"
  [ -n "$needle" ] || die "run needs a test name to filter on."
  [ -n "${KIT_TENANT_WORK:-}" ] || die "run without up: nothing is running. Exiting 2."
  load_adapter
  adapter_run "$needle"
}

# --------------------------------------------------------------------------
# tenant_harness_down — everything this harness started, removed.
#
# The container was created with `--rm`, so stopping it removes it; `docker rm -f`
# is belt and braces for one that outlived its teardown. The IMAGE is
# deliberately not removed: it is shared with every other worker on this box, and
# pulling it again would cost each of them the same two minutes.
# --------------------------------------------------------------------------
tenant_harness_down() {
  if [ -n "${KIT_TENANT_PROJECT:-}" ]; then
    "$TIMEOUT_BIN" 60 docker rm -f "$KIT_TENANT_PROJECT" >/dev/null 2>&1 || true
  fi
  if [ -n "${KIT_TENANT_WORK:-}" ]; then
    rm -rf "$KIT_TENANT_WORK"
  fi
  say "harness: down."
}

# --------------------------------------------------------------------------
# CLI. Three invocations share one session when KIT_TENANT_SESSION is exported;
# each one on its own is a complete session if it is the only one.
#
# It dispatches ONLY when this file is EXECUTED. A harness a recipe has to `.`
# cannot dispatch on its own argv, or sourcing it prints a usage message and
# exits 2 — which is what this one did, and the recipe reported a missing
# toolchain rather than the two lines that would have found it.
# --------------------------------------------------------------------------
harness_cli() {
  case "${1:-}" in
  up)
    tenant_harness_up
    say "harness: work dir $KIT_TENANT_WORK"
    ;;
  run | down)
    # The session directory is derived from the session id, never guessed: a
    # `ls -dt` over the temp dir would pick up another worker's directory on a
    # box that has three other workers on it.
    env_file="${TMPDIR:-/tmp}/kit-tenant-iso.$SESSION/session.env"
    if [ ! -r "$env_file" ]; then
      die "no session $SESSION at $env_file. Run \`up\` first, exporting KIT_TENANT_SESSION=$SESSION so \`run\` and \`down\` find the same database. Exiting 2."
    fi
    # shellcheck disable=SC1090
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

# `[ -f "${BASH_SOURCE[0]:-}" ]` is true when executed AND when sourced, so the test
# that matters is equality with `$0`, which only holds on execution. That is what lets
# a recipe `.` this file: sourcing it does not dispatch on the caller argv.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  harness_cli "$@"
fi
