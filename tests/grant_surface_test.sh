#!/usr/bin/env bash

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

SERVICES="identity,courier,billing"
LAST_SERVICE="billing"

PGADMIN=anywaye
PGADMIN_DB=anywaye_platform

PROJECT="kit-grant-surface-$$"

WORK="${TMPDIR:-/tmp}/kit-grant-surface.$$"
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
  say "SKIP tests/grant_surface_test.sh: docker is not installed, so the cluster's privilege surface is unexercised."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/grant_surface_test.sh: the docker daemon is not reachable, so the cluster's privilege surface is unexercised."
  exit 3
fi

mkdir -p "$WORK"

C="$PROJECT-postgres-1"

psql_admin() {
  docker exec -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$PGADMIN_DB" -tAX \
    --set=ON_ERROR_STOP=1 "$@"
}

psql_surface() {
  docker exec -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$2" -tAX \
    --set=ON_ERROR_STOP=1 --variable=schema="$1" --variable=db="$2" \
    --file /tmp/grant_surface.sql
}

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

cp -R "$ROOT/templates/compose" "$WORK/compose"

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

docker cp "$SURFACE_SQL" "$C:/tmp/grant_surface.sql"

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

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
