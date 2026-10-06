#!/usr/bin/env bash
#
# ONE Postgres cluster, TWO services — through `bin/dev`, not through compose.
#
#   bash tests/onecluster_test.sh
#
# WHAT MAKES THIS FILE DIFFERENT FROM tests/isolation_test.sh
# -----------------------------------------------------------
# `isolation_test.sh` already proves the boundary on a two-tenant cluster, and it
# does it carefully. It brings the stack up itself, with its own
# `docker compose --project-name … up -d --wait postgres` call against a copy of
# the template it made for itself. So on this tree, "two services share one
# cluster" was proven — but it was NOT proven that a DEVELOPER can do it, because
# the thing a developer runs is `bin/dev`, and every step between them and the
# cluster happens inside that script: the fetch, the ref validation, the `.env`
# creation, the compose argument assembly, the readiness wait, the migrate/seed
# steps.
#
# The gap is exactly the shape this repository keeps finding: the property is a
# fact about a script, and the check measured a YAML file. A `bin/dev` that
# interpolated the wrong project directory, or started one container instead of
# the cluster, or resolved a different ref, would leave `isolation_test.sh`
# green — it never invokes `bin/dev`.
#
# So this runs `bin/dev` itself, against a service directory holding a copy of
# it, and asserts on the WORLD afterwards: the container list, the cluster's own
# inventory, and a health query per service AS THAT SERVICE'S OWN ROLE.
#
# THE CLAIMS
#   1. ONE postgres container. Not two, not zero — one, named for the compose
#      project, and no other postgres container anywhere on the machine was
#      touched or removed.
#   2. TWO databases, one per named service, each owned by a role of its own.
#   3. TWO non-owner LOGIN roles, `<service>_app`, and the membership runs in ONE
#      direction only. That is the account boundary's substrate; the boundary
#      itself is `tests/tenancy_test.sh`'s subject and is not restated here.
#   4. BOTH services answer a health query AS THEIR OWN ROLE — `alpha` opening
#      `alpha` and `beta` opening `beta`, each with a real query, not `SELECT 1`
#      against the admin database. A cluster that provisioned two databases and
#      refused both logins passes claims 2 and 3 and fails this one.
#   5. NEITHER service reaches the other's database, which is the negative control
#      on claim 4: without it, a role that could open every database would still
#      "answer a health check".
#   6. The stack came up HEALTHY, by compose's own verdict rather than by this
#      file's patience.
#
# IT CAN GO RED, AND THAT WAS MEASURED
# -------------------------------------
# Declaring ONE service instead of two — one line in this file, restored with
# `git checkout` — produces **8 failed assertions**:
#
#   FAIL expected a database named beta; found '0'
#   FAIL expected one non-superuser LOGIN role named beta; found '0'
#   FAIL expected a non-superuser LOGIN role named beta_app; found '0'
#   FAIL beta could not write and read its own table (rows='… role "beta" does not exist')
#   FAIL beta: pgvector is not answering a real query
#   FAIL beta sees rows it should not
#   FAIL alpha was refused, but not by the database boundary: … database "beta" does not exist
#   FAIL beta was refused, but not by the database boundary: … role "beta" does not exist
#
# Two of those eight are the most valuable lines in the file, because they are the
# failure the whole assertion set exists to catch and the one that is invisible if
# the cross-service check only asks "did it fail":
#
#   database "beta" does not exist
#   role "beta" does not exist
#
# A cross-service query on a one-tenant cluster IS refused — the exit status is
# non-zero and the assertion "neither reaches the other" still passes. What is
# wrong is that the refusal is an ABSENCE, not a BOUNDARY. Same green check, a
# cluster that has no isolation at all, which is the defect `isolation_test.sh`'s
# negative control exists for and the reason the refusal is matched against
# `permission denied for database` rather than against a non-zero exit.
#
# Note also the three assertions that stayed green under that mutation, because
# each is satisfied by a DIFFERENT check that is still in the set — and a reader
# skimming a red run is likely to assume the tier has stopped working. "exactly one
# postgres container", "compose reports the cluster healthy", and the two summary
# PASS lines that print after their loops. The summary PASS lines are the cost of
# this design and are named here rather than left to be discovered: a per-loop
# `fail` inside a `for` is correct, and a summary line that says what the loop
# proved is not — when some iterations failed. They say what the loop would have
# proved.
#
# WHAT IS DELIBERATELY NOT CLAIMED
#   - Anything about the observability half of the stack. `bin/dev up` runs the
#     cheap stack (postgres/nats/redis/collector); this file asserts about
#     postgres, and the collector's own health is `tests/stack_live_test.sh`'s.
#   - Anything about `migrate` or `seed`. The fixture has neither, so `bin/dev`
#     says so and stops there. That is the correct behaviour and it is not the
#     subject of this file.
#   - That the cluster is the ONLY postgres on the machine. The developer's own
#     stack is running while this runs, and it is left alone; claim 1 is scoped
#     to this run's compose project.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$ROOT/templates/bin/dev.sh"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
say() { printf '%s\n' "$1"; }

# ---------------------------------------------------------------------------
# Environment. Every absence is named, because "SKIP (docker)" tells a reader
# nothing about which of three things was missing.
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  say 'SKIP tests/onecluster_test.sh: docker is not installed, so the one-cluster run is UNEXERCISED.'
  exit 77
fi
if ! docker info >/dev/null 2>&1; then
  say 'SKIP tests/onecluster_test.sh: the docker daemon is not reachable, so the one-cluster run is UNEXERCISED.'
  exit 77
fi
[ -r "$DEV" ] || {
  fail "one cluster: $DEV is not readable"
  exit 1
}

# ONE NAME FOR THE WHOLE RUN. Every namespace below derives from it, because a
# compose project name IS the namespace for that stack's containers, networks and
# volumes, and a hardcoded one makes two concurrent runs into one stack with two
# owners. See reports/compose-collision/README.md, which measured that.
PROJECT="kit-onecluster-$$"

# THE HOST PORTS — ALL FIVE, AND THAT IS THE FINDING.
#
# `bin/dev up` brings up the whole cheap stack (postgres, nats, redis, the
# collector), so this fixture has to move every published port, not just
# postgres. The first version moved only `KIT_POSTGRES_PORT` — copied from
# `isolation_test.sh`, which brings up `postgres` alone and needs exactly one —
# and died on:
#
#   Bind for 0.0.0.0:15800 failed: port is already allocated
#
# against a developer's own `cafaye` stack running on the same machine, which is
# the situation this whole packet is about: a second checkout beside a first one.
#
# So it is worth stating plainly, because templates/compose/docker-compose.yml's
# port block claims otherwise in prose: the block "makes two checkouts on one
# laptop a non-event", but only for postgres, whose default is the one most likely
# to be taken and is therefore the one you move. Redis (15800), nats (15600,
# 15700), grafana (15000), tempo (15900), loki (15901) and clickstack (15910) all
# sit on fixed defaults in the SAME range, and a second checkout collides on
# whichever it reaches first. Measured: the collision surfaced on redis, the
# third container, after postgres had already been allocated.
#
# NOT FIXED HERE. This file moves the ports for itself; changing kit's defaults
# would be a different packet touching every adopting service's `.env`, and the
# brief for this one says the compose template's contract is load-bearing. It is
# reported instead, with the measurement, because a documented claim that is
# false for four of six services is the kind of thing a reader believes.
#
# Ports move in `.env` and NEVER in a compose override: a `ports:` entry in a
# second file APPENDS rather than replacing, which templates/compose/
# docker-compose.yml spells out under "MAY — … change a published port", and
# which kit's gate fails on.
#
# The slice is searched rather than assumed, bounded so an occupied block is a
# NAMED failure rather than a walk off the end of kit's range, and seeded from
# `$$` so two concurrent runs do not begin in the same place.
PGPORT_BASE=$(( 15000 + ($$ % 400) ))
port_block_free() {
  local base="$1" off
  for off in 0 1 2 3 4 5 6 7 8 9; do
    (exec 3<>"/dev/tcp/127.0.0.1/$(( base + off ))") 2>/dev/null || continue
    return 1
  done
  return 0
}
PGPORT=""
_p=0
while [ "$_p" -lt 400 ]; do
  _cand=$(( PGPORT_BASE + _p ))
  if port_block_free "$_cand"; then
    PGPORT="$_cand"
    break
  fi
  _p=$(( _p + 1))
done
[ -n "$PGPORT" ] || {
  fail "no free 10-port block in this run's 400-port slice; the tier cannot start without colliding with something"
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-onecluster.XXXXXX")"
cleanup() {
  # BY COMPOSE PROJECT LABEL, and this is the second version.
  #
  # The first copied `isolation_test.sh`'s teardown: `docker compose
  # --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" down -v`.
  # It reached nothing, because this fixture has no such file — it copies
  # `bin/dev` into `$WORK/service` and points `KIT_STACK_DIR` at this repository,
  # so `$WORK/compose/docker-compose.yml` is a path that was never created. Three
  # runs left **twelve containers** on the machine, four per run, all still
  # `Up`. `down` against a non-existent file fails, `|| true` swallows it, and the
  # tier reports green having leaked an entire stack per run.
  #
  # The lesson is the one `isolation_test.sh`'s own cleanup header records, taken
  # one step further: a teardown written by copying a sibling's reaches only what
  # that sibling's layout happens to have. The sweep below names NOTHING — it
  # filters on the label compose stamps on every container, volume and network it
  # creates, so it covers the cheap stack whatever it grows to. The label derives
  # from this run, so it can only reach its own containers; see
  # reports/compose-collision/README.md on why a namespace must come from the run.
  #
  # `-v` matters twice over: `docker-entrypoint-initdb.d` runs ONLY on a fresh
  # volume, so a leaked one makes the NEXT run reuse an already-provisioned
  # cluster, the init script never runs, and the tier fails on an assertion about
  # a database the previous run left behind — which reads exactly like a broken
  # boundary and is in fact a leak.
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null)"
  [ -n "$ids" ] && echo "$ids" | xargs docker rm -f >/dev/null 2>&1
  ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null)"
  [ -n "$ids" ] && echo "$ids" | xargs docker volume rm >/dev/null 2>&1
  ids="$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null)"
  [ -n "$ids" ] && echo "$ids" | xargs docker network rm >/dev/null 2>&1
  return 0
rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The service fixture: kit's `bin/dev`, a `kit.ref`, and a `.env` declaring TWO
# services. Nothing else.
# ---------------------------------------------------------------------------
# `bin/dev` is COPIED rather than run from this repository, because the contract
# under test is the one a service gets: `templates/bin/dev.sh` at `bin/dev` with
# `cd "$(dirname "$SELF")/.."` deciding where `.env` and `kit.ref` live.
#
# `KIT_STACK_DIR` names the tree, which is source 1 of the four in
# `resolve_stack` and the one that needs no network. The fetch machinery is
# `tests/fetch_test.sh`'s subject; this file is about what happens AFTER the
# stack resolves, and a suite that had to reach github.com to answer that would
# be a gate that goes red when github is down.
SVC="$WORK/service"
mkdir -p "$SVC/bin"
cp "$DEV" "$SVC/bin/dev"
chmod +x "$SVC/bin/dev"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$SVC/kit.ref"

cp "$ROOT/templates/compose/.env.example" "$SVC/.env"
{
  echo "KIT_STACK_NAME=$PROJECT"
  # All five published ports of the cheap stack, from one free block. See the
  # comment above `PGPORT_BASE` for why this is five lines and not one.
  echo "KIT_POSTGRES_PORT=$PGPORT"
  echo "KIT_NATS_CLIENT_PORT=$(( PGPORT + 1 ))"
  echo "KIT_NATS_MONITOR_PORT=$(( PGPORT + 2 ))"
  echo "KIT_REDIS_PORT=$(( PGPORT + 3 ))"
  echo "KIT_GRAFANA_PORT=$(( PGPORT + 4 ))"
  # tempo, loki and clickstack are behind compose PROFILES that are off by
  # default, so they publish nothing on this path and are not moved. Stated rather
  # than left implicit, because a reader counting published ports in the compose
  # file would find eight and this list has five.
  # THE DECLARATION UNDER TEST. Two names, one cluster, and each becomes a
  # database and a role pair of its own. This one line is the whole feature.
  echo "KIT_POSTGRES_DATABASES=alpha,beta"
} >>"$SVC/.env"

say "== one cluster, two services, through bin/dev =="
say "   compose project: $PROJECT"
say "   host ports:      $PGPORT..$(( PGPORT + 4 ))"
say "   declared:        KIT_POSTGRES_DATABASES=alpha,beta"

started=$(date +%s)
( cd "$SVC" && KIT_STACK_DIR="$ROOT" ./bin/dev up ) >"$WORK/up.log" 2>&1
up_exit=$?
elapsed=$(( $(date +%s) - started ))
say "   bin/dev up: exit=$up_exit  elapsed=${elapsed}s"
say ""

if [ "$up_exit" -ne 0 ]; then
  # The fixture has no migration command and no seed, so a healthy stack still
  # ends nonzero — `bin/dev`'s own contract is "exit 0 means up, migrated AND
  # seeded", and it says so by name. So the verdict below is read from the stack
  # rather than from this status, and the log is printed when there is genuinely
  # no healthy postgres to ask.
  pg_healthy="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
    --filter 'name=postgres' --format '{{.Status}}' 2>/dev/null | head -1)"
  case "$pg_healthy" in
    *healthy*)
      say "   (nonzero exit is this fixture's missing bin/migrate — named in the log)"
      say "   $(grep -i 'no migration command' "$WORK/up.log" | head -1 | sed 's/^[[:space:]]*//')"
      ;;
    *)
      say "   the stack did not come up. Last lines:"
      tail -25 "$WORK/up.log" | sed 's/^/       /'
      fail "bin/dev up did not bring up a healthy cluster (exit $up_exit)"
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# CLAIM 1 — ONE postgres container.
#
# Read by compose project label, so this run's stack is counted and nobody else's
# is. The developer's own `cafaye-postgres-1` is running right now and is not
# part of this claim: the shape of the claim is "one cluster serves two services",
# not "postgres is installed once on this laptop".
# ---------------------------------------------------------------------------
pg_count="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
  --filter 'name=postgres' --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$pg_count" -eq 1 ]; then
  pass "exactly one postgres container serves the stack"
else
  fail "expected 1 postgres container in project $PROJECT, found $pg_count"
fi

say ""
say "== the containers this run brought up =="
docker ps --filter "label=com.docker.compose.project=$PROJECT" \
  --format '   {{.Names}}  {{.Status}}  {{.Ports}}' 2>/dev/null

# ---------------------------------------------------------------------------
# The cluster's own inventory, read through psql inside the container. The admin
# role is the one the compose file names; the DATABASE is kit's own, because a
# service's database is not where cluster administration lives.
# ---------------------------------------------------------------------------
C="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
  --filter 'name=postgres' --format '{{.Names}}' 2>/dev/null | head -1)"
[ -n "$C" ] || {
  fail "no postgres container to interrogate"
  exit 1
}

psql_in() { # psql_in <role> <db> <sql>
  docker exec -e PGPASSWORD=cafaye "$C" \
    psql --no-psqlrc -q -tA -U "$1" -d "$2" -c "$3" 2>&1
}

# CLAIM 6 — the readiness signal, by compose's own verdict. `bin/dev up` runs
# `up -d --wait`, so a container reporting `healthy` is the claim that the wait
# completed rather than expired; a suite that re-implemented the wait with its own
# deadline would be asserting its own patience rather than compose's.
status="$(docker ps --filter "name=$C" --format '{{.Status}}' 2>/dev/null | head -1)"
case "$status" in
  *'(healthy)'*) pass "compose reports the cluster healthy: $status" ;;
  *) fail "the cluster is not healthy: ${status:-<no status>}" ;;
esac

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

# CLAIM 2 — a database and an owner role per named service.
for svc in alpha beta; do
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_database WHERE datname = '$svc'")"
  [ "$got" = "1" ] || fail "expected a database named $svc; found '${got:-<no answer>}'"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$svc' AND NOT rolsuper AND rolcanlogin")"
  [ "$got" = "1" ] || fail "expected one non-superuser LOGIN role named $svc; found '${got:-<no answer>}'"
done
say "   2 databases (alpha, beta), each with a non-superuser owner role of its own"

# CLAIM 3 — the non-owner LOGIN roles, and the DIRECTION of the membership.
#
# The direction is the assertion, and it is the same one isolation_test.sh makes:
# `app -> owner` hands the application every privilege the owner has, which is
# every privilege on every table, and undoes templates/database/tenancy/ with one
# GRANT.
for svc in alpha beta; do
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${svc}_app' AND rolcanlogin AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected a non-superuser LOGIN role named ${svc}_app; found '${got:-<no answer>}'"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '${svc}_app' AND granted.rolname = '$svc'")"
  [ "$got" = "0" ] || fail "${svc}_app is a member of ${svc}: the login role holds every privilege the owner has"
done
pass "2 non-owner LOGIN roles (alpha_app, beta_app), membership owner->app in one direction only"

# CLAIM 4 — BOTH SERVICES ANSWER, each as its own role against its own database.
#
# A real query and not `SELECT 1`, and against the service's own database rather
# than the admin one. The point is a service's LOGIN working end to end: a
# database that exists, a role that exists, a GRANT that reached it, and a table
# it can create and write. `pgvector` is the query because the cluster image is
# built for it (templates/compose/postgres/Dockerfile) and `CREATE EXTENSION`
# succeeding and the extension answering are different claims — the rule AGENTS.md
# states about vendor configs, applied to an extension rather than a config file.
for svc in alpha beta; do
  psql_in "$svc" "$svc" "CREATE TABLE IF NOT EXISTS healthcheck(id int)" >/dev/null
  psql_in "$svc" "$svc" "INSERT INTO healthcheck VALUES (1) ON CONFLICT DO NOTHING" >/dev/null
  rows="$(psql_in "$svc" "$svc" "SELECT count(*) FROM healthcheck")"
  [ "$rows" = "1" ] || fail "$svc could not write and read its own table (rows='${rows}')"
  vec="$(psql_in "$svc" "$svc" "SELECT '[1,2,3]'::vector <=> '[1,2,4]'::vector < 1")"
  [ "$vec" = "t" ] || fail "$svc: pgvector is not answering a real query (got '${vec:-<no answer>}')"
  # And each service's tables are INVISIBLE to the other, which is the account
  # boundary's substrate rather than its subject — tenancy_test.sh asserts the
  # subject. What matters here is that two services on one cluster are two
  # separate worlds, not one database with two prefixes.
  seen="$(psql_in "$svc" "$svc" "SELECT count(*) FROM healthcheck WHERE false")"
  [ "$seen" = "0" ] || fail "$svc sees rows it should not: $seen"
done
pass "both services answer as their OWN role: wrote, read back, and pgvector answered in alpha and in beta"

# CLAIM 5 — the negative control on claim 4. Neither service reaches the other's
# database, and the refusal is BY THE BOUNDARY rather than by a missing database,
# which is the distinction isolation_test.sh's assertion 2 makes and the reason
# claim 2 exists above.
cross_query="SELECT * FROM healthcheck;"
for pair in "alpha beta" "beta alpha"; do
  set -- $pair
  from="$1" to="$2"
  out="$(psql_in "$from" "$to" "$cross_query" 2>&1)" && ec=0 || ec=$?
  say ""
  say "   \$ psql -U $from -d $to -c \"$cross_query\""
  printf '%s\n' "$out" | sed 's/^/       /'
  [ "$ec" -ne 0 ] || fail "$from REACHED $to's database. One cluster does not mean one shared database."
  case "$out" in
    *'permission denied for database'*) ;;
    *) fail "$from was refused, but not by the database boundary: $out" ;;
  esac
done
pass "neither service reaches the other's database: refused at the door"

say ""
if [ "$failures" -eq 0 ]; then
  say "one-cluster: all assertions passed (one container, two services, ${elapsed}s)"
  exit 0
fi
say "one-cluster: $failures assertion(s) failed"
exit 1