#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ALPHA=alpha
BETA=beta

PROJECT="kit-isolation-$$"

CONTROL_C="$PROJECT-control"
CONTROL_V="$PROJECT-control-vol"


WORK="${TMPDIR:-/tmp}/kit-isolation.$$"
IMAGE_TAG="17"
PGVECTOR_TAG="17-0.8.6"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker rm -f "$CONTROL_C" >/dev/null 2>&1 || true
  docker volume rm "$CONTROL_V" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

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

if ! command -v docker >/dev/null 2>&1; then
  say "SKIP tests/isolation_test.sh: docker is not installed, so the shared-cluster boundary is unexercised."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/isolation_test.sh: the docker daemon is not reachable, so the shared-cluster boundary is unexercised."
  exit 3
fi

mkdir -p "$WORK"

C="$PROJECT-postgres-1"

psql_in() {
  docker exec -e PGPASSWORD=anywaye "$C" psql -U "$1" -d "$2" -tAX -c "$3"
}

  local container="$1" role="$2" db="$3" out
  for _ in $(seq 1 90); do
    out="$(docker exec -e PGPASSWORD=anywaye "$container" \
      psql -U "$role" -d anywaye_platform -tAX -c \
      "SELECT count(*) FROM pg_database WHERE datname = '$db'" 2>/dev/null || true)"
    if [ "$out" = "1" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cp -R "$ROOT/templates/compose" "$WORK/compose"

if ! docker build \
  --build-arg "POSTGRES_TAG=$IMAGE_TAG" \
  --build-arg "PGVECTOR_TAG=$PGVECTOR_TAG" \
  -f "$WORK/compose/postgres/Dockerfile" \
  -t "kit-isolation-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/isolation_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

cp "$ROOT/templates/compose/.env.example" "$WORK/compose/.env"
{
  echo "KIT_POSTGRES_PORT=$PGPORT"
  echo "KIT_POSTGRES_DATABASES=$ALPHA,$BETA"
  echo "KIT_POSTGRES_EXTENSIONS=vector"
} >>"$WORK/compose/.env"

if ! docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
  up -d --wait postgres >"$WORK/up.log" 2>&1; then
  say "FAIL: the shared cluster did not come up. Last lines:"
  tail -20 "$WORK/up.log" | sed 's/^/       /'
  fail "cluster bring-up"
fi

if ! wait_for_provisioning "$C" anywaye "$BETA"; then
  say "FAIL: the cluster came up but initdb/10-cluster.sh never created a database named $BETA."
  say "      Container log:"
  docker logs "$C" 2>&1 | tail -25 | sed 's/^/       /'
  fail "init script did not complete"
fi

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

for svc in "$ALPHA" "$BETA"; do
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_database WHERE datname = '$svc'")"
  [ "$got" = "1" ] || fail "expected a database named $svc; found $got"
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$svc' AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected one non-superuser role named $svc; found $got"
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$svc' AND rolconnlimit > 0")"
  [ "$got" = "1" ] || fail "$svc has no per-role CONNECTION LIMIT; blast radius is unbounded"
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${svc}_app' AND rolcanlogin AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected one non-superuser LOGIN role named ${svc}_app; found $got"
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '${svc}_app' AND granted.rolname = '$svc'")"
  [ "$got" = "0" ] || fail "${svc}_app is a member of $svc. The account boundary is an owner that cannot be impersonated by the role that logs in; that membership hands it every privilege the owner has."
done
say "   topology: 2 databases, 2 owner roles with a per-role connection limit,"
say "             2 non-owner LOGIN roles, membership in one direction only"

for svc in "$ALPHA" "$BETA"; do
  got="$(psql_in anywaye "$svc" \
    "SELECT '[1,2,3]'::vector <=> '[1,2,4]'::vector < 1")"
  [ "$got" = "t" ] || fail "$svc: pgvector is not answering a real query (got '$got')"
done
say "   pgvector: a real similarity query answers in both databases"

say ""
say "== assertion 1: $ALPHA reaches its OWN database =="
psql_in "$ALPHA" "$ALPHA" \
  "CREATE TABLE IF NOT EXISTS deliveries(id int)" >/dev/null
psql_in "$ALPHA" "$ALPHA" \
  "INSERT INTO deliveries VALUES (1) ON CONFLICT DO NOTHING" >/dev/null
own="$(psql_in "$ALPHA" "$ALPHA" "SELECT count(*) FROM deliveries")"
[ "$own" = "1" ] || fail "$ALPHA wrote $own rows into its own database, expected 1"
say "   $ALPHA wrote 1 row into its own database"

say ""
say "== assertion 2: $ALPHA must NOT read $BETA's database =="
readonly CROSS_QUERY="SELECT * FROM deliveries;"
say "   \$ psql -U $ALPHA -d $BETA -c \"$CROSS_QUERY\""
cross_out="$(psql_in "$ALPHA" "$BETA" "$CROSS_QUERY" 2>&1)" && cross_ec=0 || cross_ec=$?
printf '%s\n' "$cross_out" | sed 's/^/   /'
say "   psql exit: $cross_ec"

[ "$cross_ec" -ne 0 ] || fail "$ALPHA READ $BETA's database. Isolation is not in place."
case "$cross_out" in
  *'permission denied for database'*) ;;
  *) fail "$ALPHA was refused, but not by the database boundary: $cross_out" ;;
esac
say "   REFUSED at the door: permission denied for database \"$BETA\""

say ""
say "== assertion 3: $BETA must NOT read $ALPHA's database either =="
back_out="$(psql_in "$BETA" "$ALPHA" "$CROSS_QUERY" 2>&1)" && back_ec=0 || back_ec=$?
printf '%s\n' "$back_out" | sed 's/^/   /'
[ "$back_ec" -ne 0 ] || fail "$BETA READ $ALPHA's database. Isolation is one-directional."
case "$back_out" in
  *'permission denied for database'*) ;;
  *) fail "refused, but not by the database boundary: $back_out" ;;
esac
say "   REFUSED at the door: permission denied for database \"$ALPHA\""

leaks="$(psql_in anywaye anywaye_platform \
  "SELECT string_agg(datname, ',') FROM pg_database
    WHERE NOT datistemplate AND has_database_privilege('public', datname, 'CONNECT')")"
[ -z "$leaks" ] || fail "PUBLIC still holds CONNECT on: $leaks. The boundary is not exhaustive."
say ""
say "   PUBLIC holds CONNECT on no database in the cluster (including 'postgres')"

say ""
say "== assertion 4: the CONTROL — same shape, REVOKE removed =="
mkdir -p "$WORK/norevoke"
cat >"$WORK/norevoke/10-norevoke.sh" <<'CONTROL'
set -e
for db in "$KIT_ALPHA" "$KIT_BETA"; do
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE $db LOGIN PASSWORD '$POSTGRES_PASSWORD'" >/dev/null
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $db OWNER $db" >/dev/null
done
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE IF NOT EXISTS deliveries(id int)" >/dev/null
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO deliveries VALUES (1)" >/dev/null
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "GRANT ALL ON SCHEMA public TO $KIT_BETA" >/dev/null
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO $KIT_BETA" >/dev/null
CONTROL

docker rm -f "$CONTROL_C" >/dev/null 2>&1 || true
docker volume rm "$CONTROL_V" >/dev/null 2>&1 || true
docker run -d --name "$CONTROL_C" \
  -e POSTGRES_PASSWORD=anywaye -e POSTGRES_USER=anywaye -e POSTGRES_DB=anywaye_platform \
  -e KIT_ALPHA="$ALPHA" -e KIT_BETA="$BETA" \
  -v "$WORK/norevoke/10-norevoke.sh:/docker-entrypoint-initdb.d/10-norevoke.sh:ro" \
  -v "$CONTROL_V":/var/lib/postgresql/data \
  "kit-isolation-postgres:$IMAGE_TAG" >/dev/null

if ! wait_for_provisioning "$CONTROL_C" anywaye "$BETA"; then
  say "FAIL: the control cluster never provisioned a database named $BETA."
  docker logs "$CONTROL_C" 2>&1 | tail -20 | sed 's/^/       /'
  fail "control cluster did not come up"
fi

ctl_connect=""; ctl_ec=1
say "   \$ psql -U $ALPHA -d $BETA -c 'SELECT current_database()'   (no REVOKE applied)"
for _ in $(seq 1 30); do
  ctl_connect="$(docker exec -e PGPASSWORD=anywaye "$CONTROL_C" \
    psql -U "$ALPHA" -d "$BETA" -tAX -c 'SELECT current_database()' 2>&1)" \
    && ctl_ec=0 || ctl_ec=$?
  [ "$ctl_ec" -eq 0 ] && break
  case "$ctl_connect" in
    *'permission denied for database'*) break ;;
  esac
  sleep 1
done
printf '%s\n' "$ctl_connect" | sed 's/^/   /'
say "   psql exit: $ctl_ec"

if [ "$ctl_ec" -ne 0 ]; then
  fail "the control cluster REFUSED the connection too. The two clusters are supposed to differ, and a control that agrees with the thing it controls proves nothing. Check that the control really omits the REVOKE."
fi
[ "$ctl_connect" = "$BETA" ] || fail "control connected somewhere unexpected: $ctl_connect"
say "   the control cluster let $ALPHA INTO $BETA's database — so assertion 2 is load-bearing,"
say "   and the difference between the two clusters is the REVOKE, not the table grants."

docker rm -f "$CONTROL_C" >/dev/null 2>&1 || true
docker volume rm "$CONTROL_V" >/dev/null 2>&1 || true

say ""
say "PASS: one cluster, one database and one role per service, and the database is the boundary."
say "      $ALPHA -> $BETA refused: permission denied for database \"$BETA\" (exit 2)"
say "      $BETA -> $ALPHA refused: permission denied for database \"$ALPHA\""
say "      control without the REVOKE: allowed in, which is what makes the refusals above mean something."