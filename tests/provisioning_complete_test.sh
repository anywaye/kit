#!/usr/bin/env bash
#
# PROVISIONING IS COMPLETE, IN BOTH HALVES. For every database declared in
# KIT_POSTGRES_DATABASES, assert that its `<database>_app` role exists, can log
# in, is neither SUPERUSER nor BYPASSRLS, and that the membership between the
# two roles runs in the ONE permitted direction.
#
#   bash tests/provisioning_complete_test.sh
#   bash tests/provisioning_complete_test.sh --cluster anywaye-postgres-1 [--databases a,b]
#
# WHY THIS EXISTS, AND THE MEASUREMENT THAT PROMPTED IT.
#
#   `10-cluster.sh` creates TWO roles per service — `<svc>` owns the database and
#   runs the migrations, `<svc>_app` owns nothing and is what the application's
#   pool logs in as — and it does that ONLY ON A FRESH VOLUME, because that is
#   where `docker-entrypoint-initdb.d` runs. The init script's own closing note
#   and `bin/dev db grant` both say so. What nothing did was REPORT the missing
#   half afterwards, and the two tiers that come closest are structurally blind
#   to it: `tests/isolation_test.sh` and `tests/grant_surface_test.sh` each
#   provision their OWN fresh cluster, so neither can ever see an existing
#   cluster on which a service was added later.
#
#   Measured on the fleet's live cluster, which is why this file exists: the
#   `muse` role was present and `muse_app` did not exist at all —
#   `select rolname from pg_roles where rolname like 'muse%'` returned ONE row —
#   and muse's application pool had been logging in as the OWNER, which on that
#   database is a role that can `ALTER TABLE … DISABLE ROW LEVEL SECURITY` and
#   `DROP TABLE vault_secrets`, the platform's vendor credentials. Nothing in
#   this repository said a word about it.
#
# WHAT IT ASSERTS, per declared database, and every item fails BY NAME:
#
#   <db>        the OWNER role exists — half of a pair is not provisioning, and
#               this check is about the pair
#   <db>_app    exists, `rolcanlogin`, NOT `rolsuper`, NOT `rolbypassrls`
#   membership  <db> IS a member of <db>_app. That is the direction
#               `10-cluster.sh` grants (`GRANT :"app" TO :"svc"`), and it is what
#               lets an operator — and `tests/isolation_test.sh` — impersonate
#               the weaker role to prove the boundary from the outside
#   membership  <db>_app is NOT a member of <db>. The reverse grant hands the
#               application every privilege the owner has, which is the whole of
#               what the two-role split exists to withhold
#
# FAILING BY NAME IS THE POINT. A summary count ("2 of 3 services complete")
# sends a reader off to look; a name is a fix one paste away. Every failure line
# below names the database, the role and the fact, and the controls assert on
# those names rather than on the exit status alone.
#
# THE CONTROLS, ON EVERY RUN. A check that cannot be shown to fail proves
# nothing, so this suite mutates the cluster it provisioned, four times, and
# requires a red result NAMING the fact each time, then restores and requires
# green:
#
#   1. the app role is DROPPED      -> red, naming `<svc>_app` as absent
#   2. the membership is REVERSED   -> red, naming the reversed direction
#   3. the app role gains BYPASSRLS -> red, naming the attribute
#   4. the app role loses LOGIN     -> red, naming the attribute
#
# Each restore runs the init script's OWN statements (see `provision_app_role`),
# so the green after a control is a statement about the cluster being complete
# again rather than merely about the mutation having been undone.
#
# `--cluster <container>` GRADES A CLUSTER THAT ALREADY EXISTS, which is the
# situation this file is about: the init script has already run, and the question
# is whether what it produced is complete. The declared list is read from the
# container's own `KIT_POSTGRES_DATABASES` unless `--databases` names one. There
# are NO controls in this mode, deliberately: mutating a cluster somebody else is
# using in order to prove a point would make this tool unusable on the exact
# cluster it is for.
#
# SKIPS LOUDLY, NEVER SILENTLY. No docker, no daemon, no network to GHCR for the
# image build: a SKIP (exit 3) naming what was missing, counted by validate.sh —
# except in `--cluster` mode, where docker is not an optional dependency and the
# absence is a failure of the request rather than of the environment.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The declared list, in the shape the init script reads it: comma-separated, and
# the SAME three names `tests/grant_surface_test.sh` pins its golden to — the
# launch's database-bearing services, so a fourth name is a deliberate addition
# to both files in the same review rather than a name that silently starts being
# graded here.
SERVICES="identity,courier,billing"
LAST_SERVICE="billing"

# The cluster's dev defaults, from templates/compose/.env.example, hardcoded for
# the same reason grant_surface_test.sh hardcodes them: the boundary holds while
# every password in the cluster is public, and a test that read a git-ignored
# `.env` would refuse to run on a fresh clone.
PGADMIN=anywaye
PGADMIN_DB=anywaye_platform

# The two role settings 10-cluster.sh applies, from its own defaults. The check
# does not grade them (grant_surface_test.sh's golden does), but the RESTORE after
# control 1 has to re-create the role the init script would have created, and a
# restore that left the app role with no statement_timeout would be a cluster
# this suite had made subtly different from the one it grades.
STMT_MS=15000
IDLE_MS=30000

IMAGE_TAG="17"
# The pgvector layer pin, matching templates/compose/postgres/Dockerfile and
# tests/grant_surface_test.sh, for the reason repeated there: parsing ARGs out of
# a Dockerfile in bash is a second place for the pin to drift.
PGVECTOR_TAG="17-0.8.6"

# --cluster <container> and --databases <list>, for grading a cluster that is
# already running. Both empty means "provision a fresh one".
CLUSTER=""
DATABASES=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster)
      [ "$#" -ge 2 ] || { printf 'usage: %s [--cluster <container>] [--databases a,b]\n' "$0" >&2; exit 2; }
      CLUSTER="$2"
      shift
      ;;
    --databases)
      [ "$#" -ge 2 ] || { printf 'usage: %s [--cluster <container>] [--databases a,b]\n' "$0" >&2; exit 2; }
      DATABASES="$2"
      shift
      ;;
    *)
      printf 'usage: %s [--cluster <container>] [--databases a,b]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Environment. Everything missing is named, because "SKIP (docker)" tells a
# reader nothing about which of three things was absent. In --cluster mode a
# missing docker is a FAIL: the operator asked for a specific container, and
# `docker exec` is how this grades it.
if ! command -v docker >/dev/null 2>&1; then
  if [ -n "$CLUSTER" ]; then
    fail "--cluster $CLUSTER needs docker to reach that container, and docker is not installed."
  fi
  say "SKIP tests/provisioning_complete_test.sh: docker is not installed, so no cluster's provisioning is graded."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  if [ -n "$CLUSTER" ]; then
    fail "--cluster $CLUSTER needs the docker daemon, and it is not reachable."
  fi
  say "SKIP tests/provisioning_complete_test.sh: the docker daemon is not reachable, so no cluster's provisioning is graded."
  exit 3
fi

# The C locale, for this script only, and for the reason 10-cluster.sh sets it:
# shell bracket ranges are collation-dependent, the identifier check below is
# built out of them, and `LC_ALL=C` is what makes the check mean the same thing on
# every laptop. Measured in the init script's own header: under `en_US.UTF-8`,
# `[!a-z_]` does NOT match `B`.
export LC_ALL=C

# The declared names, resolved before anything is graded. In fresh mode they are
# the list this script writes into `.env`; in --cluster mode `--databases` or the
# container's own KIT_POSTGRES_DATABASES decides. Nothing is graded until the
# list is non-empty, so a typo cannot grade nothing and pass.
DATABASE_LIST=""

# The same validator 10-cluster.sh uses, for its reason: every name below is
# pasted unquoted into identifiers and string literals in the SQL that follows,
# and it arrives from an operator's command line or from a container's
# environment rather than from a literal in this file. Silently mangling one is
# how a completeness check ends up grading some other role and reporting green.
require_identifier() { # require_identifier <database>
  case "$1" in
    "" | [!a-z_]* | *[!a-z0-9_]*)
      fail "'$1' is not a bare identifier. It must match [a-z_][a-z0-9_]*, the same rule KIT_POSTGRES_DATABASES entries are held to, because it is pasted into SQL below."
      ;;
  esac
}

# psql_admin <args...> — the admin role against the admin database, for the
# cluster-wide statements. `--no-psqlrc` so a developer's ~/.psqlrc cannot change
# a verdict; `ON_ERROR_STOP` so no statement can fail silently.
psql_admin() {
  docker exec -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$PGADMIN_DB" -tAX \
    --set=ON_ERROR_STOP=1 "$@"
}

# ---------------------------------------------------------------------------
# THE CHECK. One row per database, then a verdict per fact; the exit status is
# the whole answer (0 = every declared database complete) and the OUTPUT names
# every failure, because the caller's next move is a paste and a paste needs a
# name.
#
# One query per database rather than one per assertion: `pg_roles` and
# `pg_auth_members` are read cluster-wide from any database, so all seven facts
# come back in one round trip and a failure is a row rather than a diagnosis by
# elimination.
#
# The booleans are compared as `true`/`false` in `run_check`, NOT as psql's
# `t`/`f`, and that is measured rather than stylistic: the `::text` casts that
# let these values be concatenated make Postgres render a boolean as
# `true`/`false`, while a bare boolean COLUMN is what psql prints as `t`/`f`. The
# first version of this script compared against `t`/`f`, ran against a cluster
# that was perfectly provisioned, and reported three failures per database about
# roles that were fine.
read_facts() { # read_facts <database> — prints "app|canlogin|super|bypassrls|owner|fwd|rev"
  local svc="$1"
  psql_admin -c "
select coalesce((select rolname from pg_roles where rolname = '${svc}_app'), 'MISSING') || '|' ||
       coalesce((select rolcanlogin::text from pg_roles where rolname = '${svc}_app'), '-') || '|' ||
       coalesce((select rolsuper::text from pg_roles where rolname = '${svc}_app'), '-') || '|' ||
       coalesce((select rolbypassrls::text from pg_roles where rolname = '${svc}_app'), '-') || '|' ||
       coalesce((select rolname from pg_roles where rolname = '${svc}'), 'MISSING') || '|' ||
       (select count(*) from pg_auth_members m
          join pg_roles r on r.oid = m.member
          join pg_roles g on g.oid = m.roleid
         where r.rolname = '${svc}' and g.rolname = '${svc}_app') || '|' ||
       (select count(*) from pg_auth_members m
          join pg_roles r on r.oid = m.member
          join pg_roles g on g.oid = m.roleid
         where r.rolname = '${svc}_app' and g.rolname = '${svc}')"
}

# run_check — grades every declared database, prints one PASS line per complete
# database and one FAIL line per violated fact, and returns 1 if any failed.
# It never exits the script: the caller wants every database reported, not the
# first bad one, because an operator fixing this wants one list.
run_check() {
  local violations=0 svc facts app canlogin super bypassrls owner fwd rev
  for svc in $DATABASE_LIST; do
    require_identifier "$svc"
    # `bad` is THIS database's tally and `violations` is the run's. They are two
    # variables because the PASS line belongs to a database that had no
    # violations, and a counter carried across the loop would suppress the third
    # database's PASS line because the first one failed — a report that reads as
    # a broader failure than the one that exists.
    local bad=0
    if ! facts="$(read_facts "$svc")"; then
      printf 'FAIL provisioning_complete_test: could not read the roles of %s from the cluster\n' "$svc"
      violations=$((violations + 1))
      continue
    fi
    IFS='|' read -r app canlogin super bypassrls owner fwd rev <<<"$facts"
    if [ "$owner" = "MISSING" ] && [ "$app" = "MISSING" ]; then
      printf 'FAIL provisioning_complete_test: %s is declared in KIT_POSTGRES_DATABASES and NEITHER role exists (%s and %s_app). The init script has not run against this cluster with this name in its list.\n' \
        "$svc" "$svc" "$svc"
      violations=$((violations + 1))
      continue
    fi
    if [ "$owner" = "MISSING" ]; then
      printf 'FAIL provisioning_complete_test: %s_app exists and its OWNER %s does not — half a pair, and the half that cannot own the database\n' \
        "$svc" "$svc"
      violations=$((violations + 1))
      continue
    fi
    if [ "$app" = "MISSING" ]; then
      printf 'FAIL provisioning_complete_test: %s_app does not exist, and %s is declared in KIT_POSTGRES_DATABASES. Provisioning is half done: the owner role is here because it is the one a migration needs, and the login role the APPLICATION needs is the one nobody notices missing — on a cluster whose init script predates the name, only the owner is ever created (bin/dev db grant prints both halves).\n' \
        "$svc" "$svc"
      violations=$((violations + 1))
      continue
    fi
    if [ "$canlogin" != "true" ]; then
      printf 'FAIL provisioning_complete_test: %s_app cannot log in (rolcanlogin = %s): the application pool would be refused at connect\n' \
        "$svc" "$canlogin"
      bad=$((bad + 1))
    fi
    if [ "$super" != "false" ]; then
      printf 'FAIL provisioning_complete_test: %s_app is a SUPERUSER (rolsuper = %s): a login role that owns nothing is not a boundary if it can become anything\n' \
        "$svc" "$super"
      bad=$((bad + 1))
    fi
    if [ "$bypassrls" != "false" ]; then
      printf 'FAIL provisioning_complete_test: %s_app has BYPASSRLS (rolbypassrls = %s): it walks past every row-level-security policy, including FORCE\n' \
        "$svc" "$bypassrls"
      bad=$((bad + 1))
    fi
    if [ "$fwd" -lt 1 ]; then
      printf 'FAIL provisioning_complete_test: %s is NOT a member of %s_app. 10-cluster.sh grants the app role TO the owner (GRANT :"app" TO :"svc"): that is how an operator impersonates the weaker role to prove the boundary, and its absence means the membership was never granted\n' \
        "$svc" "$svc"
      bad=$((bad + 1))
    fi
    if [ "$rev" -ne 0 ]; then
      printf 'FAIL provisioning_complete_test: %s_app IS a member of %s. The membership direction is reversed, and this is the one grant the split exists to forbid: it hands the login role every privilege the owner has, including ALTER TABLE … DISABLE ROW LEVEL SECURITY and DROP TABLE\n' \
        "$svc" "$svc"
      bad=$((bad + 1))
    fi
    if [ "$bad" -eq 0 ]; then
      printf 'PASS provisioning_complete_test: %s — %s_app exists, LOGIN, NOSUPERUSER, NOBYPASSRLS; %s is a member of %s_app; %s_app is not a member of %s\n' \
        "$svc" "$svc" "$svc" "$svc" "$svc" "$svc"
    fi
    violations=$((violations + bad))
  done
  [ "$violations" -eq 0 ] || return 1
  return 0
}

# check_capture — runs the check with its output and status kept for a caller
# that has to assert on BOTH. `local` is not used for these two: they are the
# interface, and a caller reading them after the subshell is the point.
#
# BOTH ARE RESET INSIDE THE FUNCTION, before the run, and that is not tidiness —
# it was a measured defect in the first version of this file. Reset at the top
# level only, the SECOND call to `check_capture` leaves `CHECK_EC` holding the
# PREVIOUS run's status whenever the new run is green, and a restore that
# genuinely repaired the cluster was then reported as "did not restore a green
# check". `bounded_check` in `tests/validate.sh` publishes its two variables
# unconditionally for exactly this reason; the rule is the same here: a verdict
# variable assigned on only one branch is a variable that can be read from the
# wrong run.
CHECK_OUT=""
CHECK_EC=0
check_capture() {
  CHECK_OUT=""
  CHECK_EC=0
  CHECK_OUT="$(run_check)" || CHECK_EC=$?
}

# provision_app_role <database> — the INIT SCRIPT'S OWN statements for the login
# role, and the reason the restore after each control is a statement about
# completeness rather than about cleanup. They are copied from
# templates/compose/postgres/initdb/10-cluster.sh's second `admin` call, in its
# order, with its two settings defaults.
#
# The password is read from the container's own $POSTGRES_PASSWORD rather than
# written here, for the reason the init script reads it from its environment: the
# value belongs to the cluster, and a test that hardcoded one would pass on a
# cluster whose roles hold a different one. It is read INSIDE the container by
# psql's own `\set … \`…\`` and never appears in an argument list or in output.
provision_app_role() {
  local svc="$1"
  docker exec -i -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$PGADMIN_DB" \
      --set=ON_ERROR_STOP=1 --set=svc="$svc" --set=app="${svc}_app" \
      --set=stmt_ms="$STMT_MS" --set=idle_ms="$IDLE_MS" -f - >/dev/null <<'SQL'
\set pw `printf %s "$POSTGRES_PASSWORD"`
create role :"app" login nosuperuser nocreatedb nocreaterole noreplication password :'pw';
grant :"app" to :"svc";
grant connect, temporary on database :"svc" to :"app";
alter role :"app" set statement_timeout = :'stmt_ms';
alter role :"app" set idle_in_transaction_session_timeout = :'idle_ms';
SQL
}

# ---------------------------------------------------------------------------
# --cluster: grade a cluster that is already running, and stop.
if [ -n "$CLUSTER" ]; then
  C="$CLUSTER"
  LIST_SOURCE="--databases"
  if [ -z "$DATABASES" ]; then
    # The DECLARED list, read from the cluster's own environment rather than
    # guessed: the init script provisions what THIS variable names, so a
    # completeness check that used a list from anywhere else would grade a
    # cluster nobody provisioned.
    DATABASES="$(docker exec "$C" sh -c 'printf %s "${KIT_POSTGRES_DATABASES:-}"')" \
      || fail "could not read KIT_POSTGRES_DATABASES from container $C"
    [ -n "$DATABASES" ] || fail "container $C has no KIT_POSTGRES_DATABASES in its environment, so no list is declared to grade. Pass --databases a,b."
    LIST_SOURCE="the cluster's own KIT_POSTGRES_DATABASES"
  fi
  DATABASE_LIST="$(printf '%s' "$DATABASES" | tr ',' ' ')"
  say "== grading $C: $DATABASES ($LIST_SOURCE) =="
  check_capture
  printf '%s\n' "$CHECK_OUT"
  if [ "$CHECK_EC" -ne 0 ]; then
    fail "provisioning is INCOMPLETE on $C — the failures above name each role."
  fi
  say "PASS tests/provisioning_complete_test.sh: $C is complete for every declared database ($DATABASES)."
  say "      Each: the owner role and a <db>_app login role, LOGIN, NOSUPERUSER,"
  say "      NOBYPASSRLS, membership granted app -> owner and never back."
  exit 0
fi

# ---------------------------------------------------------------------------
# Fresh mode: provision a cluster from the stack kit SHIPS, grade it, then prove
# the check can go red by breaking what it grades.
PROJECT="kit-provisioning-complete-$$"

# A named project and a named volume, not `--rm`: the controls need the cluster
# to survive between checks.
WORK="${TMPDIR:-/tmp}/kit-provisioning-complete.$$"

cleanup() {
  # `down -v`, not `docker rm -f` plus a guessed volume name: the init script
  # runs ONLY on a fresh volume, and a leaked volume makes the next run grade a
  # cluster provisioned by the previous one — which reads as drift and is in
  # fact a reused volume. Every name is `$PROJECT`-derived so this can only ever
  # remove its own.
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The host port, searched rather than fixed: a fixed port collides with a
# developer's own running stack, not merely with another test run. Same
# dependency-free /dev/tcp walk as tests/grant_surface_test.sh (no nc, no
# python), started at a $$-derived offset so two concurrent runs do not begin in
# the same place.
PGPORT_BASE=$(( 15800 + ($$ % 200) ))
PGPORT=""
_p=0
while [ "$_p" -lt 200 ]; do
  _cand=$(( PGPORT_BASE + _p ))
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$_cand") 2>/dev/null; then
    PGPORT="$_cand"
    break
  fi
  _p=$(( _p + 1 ))
done
[ -n "$PGPORT" ] || fail "no free host port in this run's 200-port slice; the tier cannot start without colliding with something"

mkdir -p "$WORK"

# The container name compose derives: <project>-<service>-<index>.
C="$PROJECT-postgres-1"

# Wait for the INIT SCRIPT to finish, not for the server to answer. During
# `docker-entrypoint-initdb.d` the image runs a TEMPORARY server, so both
# `pg_isready` and `docker compose up --wait` are satisfied before the first
# init statement runs — and a check that started grading there would grade a
# cluster whose roles are still being created. The evidence waited for is the
# init script's own closing line, and then an answer from the real server the
# entrypoint starts after it.
#
# The match is a here-string and NOT `docker logs … | grep -q`, and that is the
# SIGPIPE race this repository already paid for once (kit-14, commit 90f606a):
# `grep -q` exits at the first match and closes the pipe, `docker logs` then
# dies 141 still writing the lines AFTER the match, and under `pipefail` a
# MATCH reads as a MISS.
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
# that one file, and grading anything else would be grading a copy.
cp -R "$ROOT/templates/compose" "$WORK/compose"

if ! docker build \
  --build-arg "POSTGRES_TAG=$IMAGE_TAG" \
  --build-arg "PGVECTOR_TAG=$PGVECTOR_TAG" \
  -f "$WORK/compose/postgres/Dockerfile" \
  -t "kit-provisioning-complete-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/provisioning_complete_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

# Start the stack the way `bin/dev` does: the shipped compose file, the init
# script mounted from the tree, and the database list in .env. The port and the
# list are overridden so this suite cannot collide with a developer's stack.
cp "$ROOT/templates/compose/.env.example" "$WORK/compose/.env"
{
  echo "KIT_POSTGRES_PORT=$PGPORT"
  echo "KIT_POSTGRES_DATABASES=$SERVICES"
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

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

DATABASE_LIST="$(printf '%s' "$SERVICES" | tr ',' ' ')"

say ""
say "== the check: every declared database, both roles =="
check_capture
printf '%s\n' "$CHECK_OUT" | sed 's/^/   /'
[ "$CHECK_EC" -eq 0 ] || fail "the fresh cluster is INCOMPLETE for a declared database. That is either a defect in 10-cluster.sh or a defect in this check; the lines above name which."

# ---------------------------------------------------------------------------
# THE CONTROLS. Each one breaks exactly one graded fact, requires the check to
# go red NAMING it, restores, and requires green. A check that cannot be shown
# to fail is a decoration, and a control asserted only on the exit status would
# pass for a check that failed on something else entirely — hence the grep for
# the name.
run_control() { # run_control <label> <expected-name-in-output>
  local label="$1" expect="$2"
  say ""
  say "== control: $label =="
  check_capture
  if [ "$CHECK_EC" -eq 0 ]; then
    fail "the check stayed GREEN after: $label. It is not load-bearing."
  fi
  printf '%s\n' "$CHECK_OUT" | sed 's/^/   /'
  if ! grep -qF "$expect" <<<"$CHECK_OUT"; then
    fail "the check went red after '$label' but did not say '$expect'. A red that does not name the fact sends the reader looking instead of fixing."
  fi
}
expect_green() { # expect_green <label>
  check_capture
  if [ "$CHECK_EC" -ne 0 ]; then
    printf '%s\n' "$CHECK_OUT" | sed 's/^/   /'
    fail "$1 did not restore a green check — the restore is incomplete, and every later control is then suspect."
  fi
  say "   went red by name, the restore went green"
}

say ""
say "== control 1: DROP ROLE ${LAST_SERVICE}_app (the half nobody notices missing) =="
# The database-level grants are dependencies of the role, so they come off first:
# `DROP ROLE` refuses while the role holds a privilege in any database, and a
# control that skipped this would fail for a reason unrelated to the check.
psql_admin -c "REVOKE ALL ON DATABASE \"$LAST_SERVICE\" FROM \"${LAST_SERVICE}_app\"" >/dev/null
psql_admin -c "DROP ROLE \"${LAST_SERVICE}_app\"" >/dev/null
run_control "DROP ROLE ${LAST_SERVICE}_app" "${LAST_SERVICE}_app does not exist"
provision_app_role "$LAST_SERVICE"
expect_green "re-provisioning ${LAST_SERVICE}_app (init's own statements)"

say ""
say "== control 2: the membership direction, REVERSED =="
# TWO statements, because Postgres refuses to hold both directions at once.
# Measured on the first run of this control:
#
#   $ GRANT billing TO billing_app        # with the granted direction in place
#   ERROR:  role "billing" is a member of role "billing_app"
#
# `10-cluster.sh`'s `GRANT :"app" TO :"svc"` makes the OWNER a member of the app
# role, so the reverse grant is refused while it stands. The granted direction
# therefore comes OFF first and the forbidden one goes on, which is also the
# state a wrong paste leaves behind — an operator who read `GRANT a TO b` the
# wrong way round would have had to remove the first grant to get here — so the
# control models the real defect rather than a state the server will not build.
psql_admin -c "REVOKE \"${LAST_SERVICE}_app\" FROM \"$LAST_SERVICE\"" >/dev/null
psql_admin -c "GRANT \"$LAST_SERVICE\" TO \"${LAST_SERVICE}_app\"" >/dev/null
run_control "the membership direction reversed (GRANT $LAST_SERVICE TO ${LAST_SERVICE}_app)" "${LAST_SERVICE}_app IS a member of $LAST_SERVICE"
psql_admin -c "REVOKE \"$LAST_SERVICE\" FROM \"${LAST_SERVICE}_app\"" >/dev/null
psql_admin -c "GRANT \"${LAST_SERVICE}_app\" TO \"$LAST_SERVICE\"" >/dev/null
expect_green "restoring the membership direction"

say ""
say "== control 3: ALTER ROLE ${LAST_SERVICE}_app BYPASSRLS =="
psql_admin -c "ALTER ROLE \"${LAST_SERVICE}_app\" BYPASSRLS" >/dev/null
run_control "ALTER ROLE ${LAST_SERVICE}_app BYPASSRLS" "${LAST_SERVICE}_app has BYPASSRLS"
psql_admin -c "ALTER ROLE \"${LAST_SERVICE}_app\" NOBYPASSRLS" >/dev/null
expect_green "NOBYPASSRLS"

say ""
say "== control 4: ALTER ROLE ${LAST_SERVICE}_app NOLOGIN =="
psql_admin -c "ALTER ROLE \"${LAST_SERVICE}_app\" NOLOGIN" >/dev/null
run_control "ALTER ROLE ${LAST_SERVICE}_app NOLOGIN" "${LAST_SERVICE}_app cannot log in"
psql_admin -c "ALTER ROLE \"${LAST_SERVICE}_app\" LOGIN" >/dev/null
expect_green "LOGIN"

say ""
say "PASS: provisioning is complete, in both halves, for every declared database."
say "      graded: $DATABASE_LIST — each with the owner role, a <db>_app login role"
say "      (LOGIN, NOSUPERUSER, NOBYPASSRLS), membership granted app -> owner and"
say "      never back. controls: a DROPPED app role, a REVERSED membership,"
say "      BYPASSRLS and NOLOGIN each moved the result to a red that NAMED the"
say "      role and the fact; each restore re-provisioned with the init script's own"
say "      statements and the check went green again."
say ""
say "      To grade a cluster that already exists (the case this file is about):"
say "          bash tests/provisioning_complete_test.sh --cluster <postgres-container>"
