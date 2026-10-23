#!/usr/bin/env bash
#
# THE PRIVILEGE SURFACE, PINNED. Provision a cluster, dump everything the
# isolation contract depends on, and FAIL if it differs from the golden file.
#
#   bash tests/grant_surface_test.sh                 # check
#   bash tests/grant_surface_test.sh --regenerate    # deliberately rewrite the golden
#
# WHY THIS EXISTS, AND WHAT IT WOULD HAVE CAUGHT.
#
#   `templates/compose/postgres/initdb/10-cluster.sh` is the whole privilege
#   model of the shared cluster — two roles per service, CONNECT revoked from
#   PUBLIC, per-role timeouts and connection limits — and until this test
#   nothing compared a RUNNING cluster against it. Static checks read the
#   script; they cannot see the cluster it produced, and three of the defects
#   this fleet has actually hit live only in the produced cluster:
#
#     * two services' pools connected as the OWNER role instead of
#       `<service>_app` — found by hand, twice. The account boundary those
#       services had adopted (templates/database/tenancy/) was one privilege
#       away from meaningless, and nothing said so.
#     * Postgres exempts a table's OWNER from its own row-level-security
#       policies, so a role that logs in as the owner reads every account's
#       rows even with FORCE ROW LEVEL SECURITY in place. That is the failure
#       the two-role split exists to prevent, and it is invisible from source:
#       the policies are all present and correct.
#     * three services' compose files re-added POSTGRES_USER/POSTGRES_DB/
#       POSTGRES_PASSWORD on the shared cluster; kit's own history records the
#       cluster that broke. The role attributes here are where that arrives.
#
#   None of the three changes a file review would catch. All three are in
#   `pg_roles`, `pg_auth_members` and `pg_database.datacl`, which is what
#   `tests/grant_surface.sql` reads.
#
# WHAT THE GOLDEN FILE HOLDS. The output of `tests/grant_surface.sql` for a
# freshly provisioned cluster with KIT_POSTGRES_DATABASES naming the services
# below: every provisioned role with its attributes (including `rolbypassrls`),
# the role-level statement_timeout / idle_in_transaction_session_timeout
# settings, the memberships in both directions, the CONNECT surface of every
# database, and the `public` schema ACL of every database. The exclusions and
# the ordering rules are documented in `tests/grant_surface.sql`; the property
# this file adds is that the output is BYTE-IDENTICAL between two runs against
# the same cluster, asserted below rather than assumed.
#
# THE SERVICES. `identity,courier,billing` — the three services the launch
# overlay declares a database for (`launch/docker-compose.launch.yml:210`;
# gateway's state is Redis and parlor holds no database of its own). A fourth
# name here is a new service to provision; the golden file is regenerated in
# the same review as that change, deliberately, with the command below.
#
# HOW TO REGENERATE, AND WHY THAT IS A ONE-LINER. When a change REALLY moves
# the privilege surface — a pinned image bump, a deliberate init-script change,
# a service added to the launch — the golden is rewritten by:
#
#     bash tests/grant_surface_test.sh --regenerate
#
#   which provisions a fresh cluster, writes the golden from it, and runs the
#   mutation control anyway so the file it just wrote is known to be
#   comparable. A golden file nobody can regenerate is a file that gets
#   deleted when it fails, so the command lives in this header and is printed
#   by the failure path below.
#
# THE CONTROL, ON EVERY RUN. A diff that cannot be shown to fail proves
# nothing, so after the comparison this test mutates the live cluster twice —
# `ALTER ROLE billing_app BYPASSRLS` and `GRANT CONNECT ON DATABASE billing TO
# PUBLIC`, the two defects named above — and REQUIRES the diff to go red,
# naming the row that moved. Each mutation is then reverted and the surface
# must come back byte-for-byte; a revert that does not restore the bytes would
# make every later assertion suspect, so it is checked rather than assumed.
#
# SKIPS LOUDLY, NEVER SILENTLY. No docker, no daemon, no network to GHCR for
# the image build: a SKIP (exit 3) naming what was missing, counted by
# validate.sh. A skip reported as a pass is the thing this repository forbids.

set -euo pipefail

REGENERATE=0
case "${1:-}" in
  --regenerate) REGENERATE=1 ;;
  "") ;;
  *)
    printf 'usage: %s [--regenerate]\n' "$0" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOLDEN="$ROOT/tests/grant_surface.out"
SURFACE_SQL="$ROOT/tests/grant_surface.sql"

# The services, and the one whose database proves the sweep ran. Defined here
# rather than beside their first use because `set -u` treats a variable read
# before it is assigned as fatal, and the .env write below is a use.
SERVICES="identity,courier,billing"
LAST_SERVICE="billing"

# The cluster's dev defaults, from templates/compose/.env.example. Hardcoded
# here for the same reason tests/isolation_test.sh hardcodes them: the whole
# point of the boundary is that it holds while every password in the cluster is
# public, and a test that read the values from a git-ignored .env would refuse
# to run on a fresh clone.
PGADMIN=anywaye
PGADMIN_DB=anywaye_platform

# One name for the whole run; every namespace this suite touches is derived
# from it, for the reason tests/isolation_test.sh documents: a compose project
# name is the namespace for containers, networks and volumes, so two concurrent
# runs sharing a name are one stack with two owners.
PROJECT="kit-grant-surface-$$"

# Where the state goes. A named project and a named volume, not `--rm`,
# because the control mutations need the cluster to survive between dumps.
WORK="${TMPDIR:-/tmp}/kit-grant-surface.$$"
IMAGE_TAG="17"
# The pgvector layer pin, matching templates/compose/postgres/Dockerfile, for
# the reason tests/isolation_test.sh repeats it: parsing ARGs out of a
# Dockerfile in bash is a second place for the pin to drift. validate.sh
# asserts the copies agree.
PGVECTOR_TAG="17-0.8.6"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # `down -v`, not `docker rm -f` plus a guessed volume name: the init script
  # runs ONLY on a fresh volume, and a leaked volume makes the next run query a
  # cluster provisioned by the previous one — which reads as surface drift and
  # is in fact a reused volume. Every name is `$PROJECT`-derived so this can
  # only ever remove its own.
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The host port, searched rather than fixed: a fixed port collides with a
# developer's own running stack, not merely with another test run. Same
# dependency-free /dev/tcp walk as tests/isolation_test.sh and
# tests/tenancy_test.sh (no nc, no python), started at a $$-derived offset so
# two concurrent runs do not begin in the same place.
PGPORT_BASE=$(( 15500 + ($$ % 400) ))
PGPORT=""
_p=0
while [ "$_p" -lt 400 ]; do
  _cand=$(( PGPORT_BASE + _p ))
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$_cand") 2>/dev/null; then
    PGPORT="$_cand"
    break
  fi
  _p=$(( _p + 1 ))
done
[ -n "$PGPORT" ] || fail "no free host port in this run's 400-port slice; the tier cannot start without colliding with something"

# ---------------------------------------------------------------------------
# Environment. Everything missing is named, because "SKIP (docker)" tells a
# reader nothing about which of three things was absent.
if ! command -v docker >/dev/null 2>&1; then
  say "SKIP tests/grant_surface_test.sh: docker is not installed, so the cluster's privilege surface is unexercised."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/grant_surface_test.sh: the docker daemon is not reachable, so the cluster's privilege surface is unexercised."
  exit 3
fi

mkdir -p "$WORK"

# The container name compose derives: <project>-<service>-<index>.
C="$PROJECT-postgres-1"

# psql_admin <args...> — the admin role against the admin database, for the
# cluster-wide statements. `--no-psqlrc` so a developer's ~/.psqlrc cannot
# change a dump; `ON_ERROR_STOP` so no statement can fail silently.
psql_admin() {
  docker exec -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$PGADMIN_DB" -tAX \
    --set=ON_ERROR_STOP=1 "$@"
}

# psql_surface <schema 0|1> <database> — one mode of tests/grant_surface.sql,
# run on a connection to that database. The SQL file is copied into the
# container once, below, so the file the diff is computed from is byte-for-byte
# the committed one.
psql_surface() {
  docker exec -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$2" -tAX \
    --set=ON_ERROR_STOP=1 --variable=schema="$1" --variable=db="$2" \
    --file /tmp/grant_surface.sql
}

# Wait for the INIT SCRIPT to finish, not for the server to answer. During
# `docker-entrypoint-initdb.d` the image runs a TEMPORARY server, so both
# `pg_isready` and `docker compose up --wait` are satisfied before the first
# init statement runs — and the last statement this script makes is the sweep
# that revokes PUBLIC's CONNECT on every database, so a dump that starts too
# early would pin a HALF-provisioned surface as the golden. The evidence waited
# for is the init script's own closing line, and then an answer from the real
# server the entrypoint starts after it.
#
# The match is a here-string and NOT `docker logs … | grep -q`, and that is the
# SIGPIPE race this repository already paid for once (kit-14, commit 90f606a):
# `grep -q` exits at the first match and closes the pipe, `docker logs` then
# dies 141 still writing the lines AFTER the match, and under `pipefail` a
# MATCH reads as a MISS. The log here grows a shutdown/restart tail after the
# closing line, which is precisely the size-dependent case that race is
# invisible in until it fires.
wait_for_provisioning() {
  local _i logs=""
  for _i in $(seq 1 90); do
    logs="$(docker logs "$C" 2>&1)" || true
    if grep -q '\[cluster\] done:' <<<"$logs"; then
      break
    fi
    sleep 1
  done
  grep -q '\[cluster\] done:' <<<"$logs" || return 1
  for _i in $(seq 1 60); do
    if psql_admin -c 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# The WHOLE of templates/compose, not just the postgres directory: compose
# validates the document even when only `postgres` is started, so the vendor
# config trees have to be present too. This is the stack kit SHIPS — the init
# script's bind mount, the build args and the environment block all come from
# that one file, and a dump taken through anything else would be testing a copy.
cp -R "$ROOT/templates/compose" "$WORK/compose"

# Build the cluster image exactly as the compose file builds it. A build that
# cannot happen — no network to ghcr.io, a moved pin — is a SKIP naming the
# build failure, never a pass.
if ! docker build \
  --build-arg "POSTGRES_TAG=$IMAGE_TAG" \
  --build-arg "PGVECTOR_TAG=$PGVECTOR_TAG" \
  -f "$WORK/compose/postgres/Dockerfile" \
  -t "kit-grant-surface-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/grant_surface_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

# Start the stack the way `bin/dev` does: the shipped compose file, the init
# script mounted from the tree, and the database list in .env. The port and the
# list are overridden so this suite cannot collide with a developer's stack;
# moving the port in .env (not an override) is what AGENTS.md prescribes,
# because compose APPENDS a second file's `ports:` list rather than replacing it.
cp "$ROOT/templates/compose/.env.example" "$WORK/compose/.env"
{
  echo "KIT_POSTGRES_PORT=$PGPORT"
  echo "KIT_POSTGRES_DATABASES=$SERVICES"
  echo "KIT_POSTGRES_EXTENSIONS=vector"
} >>"$WORK/compose/.env"

if ! docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
  up -d --wait postgres >"$WORK/up.log" 2>&1; then
  say "FAIL: the shared cluster did not come up. Last lines:"
  tail -20 "$WORK/up.log" | sed 's/^/       /'
  fail "cluster bring-up"
fi

if ! wait_for_provisioning; then
  say "FAIL: the cluster never reached the init script's closing line, so it is not fully provisioned."
  docker logs "$C" 2>&1 | tail -25 | sed 's/^/       /'
  fail "init script did not complete"
fi

# The SQL file has to be in the container before the first dump; the copy above
# ran before the container existed (a failed `docker cp` is tolerated there
# because of it), so it is done again here where failure means failure.
docker cp "$SURFACE_SQL" "$C:/tmp/grant_surface.sql"

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

# dump_surface <outfile> — the whole surface: cluster-wide sections once,
# schema sections once per database. The database list comes from the cluster
# rather than from this file, so a database nobody declared is dumped too; the
# schema half cannot be read cluster-wide because `pg_namespace` is a
# database-local catalog and Postgres has no view across databases.
dump_surface() {
  local out="$1" dbs db
  dbs="$(psql_admin -c "select datname from pg_database where not datistemplate order by datname")" \
    || fail "could not read the database list from the cluster"
  {
    psql_surface 0 "$PGADMIN_DB"
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      psql_surface 1 "$db"
    done <<<"$dbs"
  } >"$out"
}

say ""
say "== the dump =="
dump_surface "$WORK/surface-1"
dump_surface "$WORK/surface-2"

# DETERMINISM, ASSERTED. The golden diff is only a gate if two runs against the
# same cluster produce the same bytes; everything below inherits this property
# and would be flaky without it.
if ! cmp -s "$WORK/surface-1" "$WORK/surface-2"; then
  say "FAIL: two consecutive dumps of the SAME cluster differ, so a golden diff would be flaky. Difference:"
  diff -u "$WORK/surface-1" "$WORK/surface-2" | head -40 | sed 's/^/       /' || true
  fail "the privilege-surface dump is not deterministic"
fi
say "   two consecutive dumps are byte-identical ($(wc -l <"$WORK/surface-1" | tr -d ' ') lines)"

if [ "$REGENERATE" -eq 1 ]; then
  cp "$WORK/surface-1" "$GOLDEN"
  say "   REGENERATED: $GOLDEN"
  say "   Review it like a diff — a golden rewritten without reading it is a"
  say "   golden that has stopped meaning anything."
else
  if ! cmp -s "$GOLDEN" "$WORK/surface-1"; then
    say ""
    say "FAIL: the cluster's privilege surface differs from $GOLDEN."
    say "      golden -> cluster:"
    diff -u "$GOLDEN" "$WORK/surface-1" | sed 's/^/       /' || true
    say ""
    say "      If this is DRIFT, fix the cause — the diff above names it."
    say "      If this is a DELIBERATE move of the surface (a pinned image bump, an"
    say "      intentional init-script change, a service added to the launch),"
    say "      regenerate the golden and put it in the same review:"
    say ""
    say "          bash tests/grant_surface_test.sh --regenerate"
    fail "grant surface drifted"
  fi
  say "   matches $GOLDEN byte for byte"
fi

# ---------------------------------------------------------------------------
# THE CONTROL, ON EVERY RUN. Both mutations are the two real defects named in
# the header; each must move the surface BY NAME, and each revert must restore
# the exact bytes. A diff that cannot be shown to fail is a decoration.
REF="$WORK/surface-1"

say ""
say "== control 1: ALTER ROLE ${LAST_SERVICE}_app BYPASSRLS =="
psql_admin -c "ALTER ROLE ${LAST_SERVICE}_app BYPASSRLS" >/dev/null
dump_surface "$WORK/mutated-1"
if cmp -s "$REF" "$WORK/mutated-1"; then
  fail "the surface did NOT change after ALTER ROLE ${LAST_SERVICE}_app BYPASSRLS. The golden diff is not load-bearing."
fi
diff -u "$REF" "$WORK/mutated-1" >"$WORK/control-1.diff" || true
sed 's/^/   /' "$WORK/control-1.diff"
grep -q "^+${LAST_SERVICE}_app|" "$WORK/control-1.diff" \
  || fail "the diff noticed a change but did not name the ${LAST_SERVICE}_app role row: that role gaining BYPASSRLS must appear as its own line."
psql_admin -c "ALTER ROLE ${LAST_SERVICE}_app NOBYPASSRLS" >/dev/null
dump_surface "$WORK/restored-1"
cmp -s "$REF" "$WORK/restored-1" \
  || fail "reverting the BYPASSRLS mutation did not restore the surface byte for byte, so every later comparison is suspect."
say "   went red by name, and the revert restored the bytes"

say ""
say "== control 2: GRANT CONNECT ON DATABASE $LAST_SERVICE TO PUBLIC =="
psql_admin -c "GRANT CONNECT ON DATABASE $LAST_SERVICE TO PUBLIC" >/dev/null
dump_surface "$WORK/mutated-2"
if cmp -s "$REF" "$WORK/mutated-2"; then
  fail "the surface did NOT change after granting CONNECT to PUBLIC on $LAST_SERVICE. The isolation boundary's own defect is invisible to this diff."
fi
diff -u "$REF" "$WORK/mutated-2" >"$WORK/control-2.diff" || true
sed 's/^/   /' "$WORK/control-2.diff"
grep -q "^+${LAST_SERVICE}|PUBLIC|CONNECT" "$WORK/control-2.diff" \
  || fail "the diff noticed a change but did not name PUBLIC's CONNECT row on $LAST_SERVICE: the boundary failing open must appear as its own line."
psql_admin -c "REVOKE CONNECT ON DATABASE $LAST_SERVICE FROM PUBLIC" >/dev/null
dump_surface "$WORK/restored-2"
cmp -s "$REF" "$WORK/restored-2" \
  || fail "reverting the CONNECT grant did not restore the surface byte for byte, so every later comparison is suspect."
say "   went red by name, and the revert restored the bytes"

say ""
say "PASS: the privilege surface matches tests/grant_surface.out byte for byte."
say "      roles, role settings, memberships, per-database CONNECT and the public"
say "      schema ACL of every database, for: $SERVICES (+ $PGADMIN_DB, postgres)."
say "      control: BYPASSRLS on ${LAST_SERVICE}_app and CONNECT to PUBLIC on"
say "      $LAST_SERVICE both moved the diff by name; both reverts restored the bytes."
