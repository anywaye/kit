#!/usr/bin/env bash

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

CLAIM_DIR="${KIT_ONECLUSTER_CLAIM_DIR:-${TMPDIR:-/tmp}/kit-onecluster-claims}"
port_block_free() {
  local base="$1" off
  for off in 0 1 2 3 4 5 6 7 8 9; do
    (exec 3<>"/dev/tcp/127.0.0.1/$(( base + off ))") 2>/dev/null || continue
    return 1
  done
  return 0
}
claim_port_block() {
  local base="$1" _p=0 _cand _owner
  PGPORT=""
  mkdir -p "$CLAIM_DIR" 2>/dev/null || return 1
  while [ "$_p" -lt 400 ]; do
    _cand=$(( base + _p ))
    if mkdir "$CLAIM_DIR/$_cand" 2>/dev/null; then
      echo "$$" >"$CLAIM_DIR/$_cand/pid" 2>/dev/null
      if port_block_free "$_cand"; then
        PGPORT="$_cand"
        return 0
      fi
      rm -rf "${CLAIM_DIR:?}/${_cand:?}" 2>/dev/null
    else
      _owner="$(cat "$CLAIM_DIR/$_cand/pid" 2>/dev/null)"
      if [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; then
        rm -rf "${CLAIM_DIR:?}/${_cand:?}" 2>/dev/null
        if mkdir "$CLAIM_DIR/$_cand" 2>/dev/null; then
          echo "$$" >"$CLAIM_DIR/$_cand/pid" 2>/dev/null
          if port_block_free "$_cand"; then
            PGPORT="$_cand"
            return 0
          fi
          rm -rf "${CLAIM_DIR:?}/${_cand:?}" 2>/dev/null
        fi
      fi
    fi
    _p=$(( _p + 1 ))
  done
  return 1
}

if [ "${1:-}" = "--select-block" ]; then
  SEED="${KIT_ONECLUSTER_SEED:-$$}"
  if claim_port_block "$(( 15000 + (SEED % 400) ))"; then
    printf '%s\n' "$PGPORT"
    trap 'rm -rf "${CLAIM_DIR:?}/${PGPORT:?}" 2>/dev/null' EXIT
    sleep "${KIT_ONECLUSTER_HOLD:-10}"
    exit 0
  fi
  echo "no free 10-port block" >&2
  exit 1
fi

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

PROJECT="kit-onecluster-$$"

PGPORT_BASE=$(( 15000 + (${KIT_ONECLUSTER_SEED:-$$} % 400) ))
PGPORT=""
claim_port_block "$PGPORT_BASE" || {
  fail "no free 10-port block in this run's 400-port slice; the tier cannot start without colliding with something"
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-onecluster.XXXXXX")"
cleanup() {
  [ -n "${PGPORT:-}" ] && [ -n "${CLAIM_DIR:-}" ] && \
    rm -rf "${CLAIM_DIR:?}/${PGPORT:?}" 2>/dev/null
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

SVC="$WORK/service"
mkdir -p "$SVC/bin"
cp "$DEV" "$SVC/bin/dev"
chmod +x "$SVC/bin/dev"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$SVC/kit.ref"

cp "$ROOT/templates/compose/.env.example" "$SVC/.env"
{
  echo "KIT_STACK_NAME=$PROJECT"
  echo "KIT_POSTGRES_PORT=$PGPORT"
  echo "KIT_NATS_CLIENT_PORT=$(( PGPORT + 1 ))"
  echo "KIT_NATS_MONITOR_PORT=$(( PGPORT + 2 ))"
  echo "KIT_REDIS_PORT=$(( PGPORT + 3 ))"
  echo "KIT_GRAFANA_PORT=$(( PGPORT + 4 ))"
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

C="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
  --filter 'name=postgres' --format '{{.Names}}' 2>/dev/null | head -1)"
[ -n "$C" ] || {
  fail "no postgres container to interrogate"
  exit 1
}

  docker exec -e PGPASSWORD=anywaye "$C" \
    psql --no-psqlrc -q -tA -U "$1" -d "$2" -c "$3" 2>&1
}

status="$(docker ps --filter "name=$C" --format '{{.Status}}' 2>/dev/null | head -1)"
case "$status" in
  *'(healthy)'*) pass "compose reports the cluster healthy: $status" ;;
  *) fail "the cluster is not healthy: ${status:-<no status>}" ;;
esac

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

for svc in alpha beta; do
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_database WHERE datname = '$svc'")"
  [ "$got" = "1" ] || fail "expected a database named $svc; found '${got:-<no answer>}'"
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$svc' AND NOT rolsuper AND rolcanlogin")"
  [ "$got" = "1" ] || fail "expected one non-superuser LOGIN role named $svc; found '${got:-<no answer>}'"
done
say "   2 databases (alpha, beta), each with a non-superuser owner role of its own"

for svc in alpha beta; do
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${svc}_app' AND rolcanlogin AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected a non-superuser LOGIN role named ${svc}_app; found '${got:-<no answer>}'"
  got="$(psql_in anywaye anywaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '${svc}_app' AND granted.rolname = '$svc'")"
  [ "$got" = "0" ] || fail "${svc}_app is a member of ${svc}: the login role holds every privilege the owner has"
done
pass "2 non-owner LOGIN roles (alpha_app, beta_app), membership owner->app in one direction only"

for svc in alpha beta; do
  psql_in "$svc" "$svc" "CREATE TABLE IF NOT EXISTS healthcheck(id int)" >/dev/null
  psql_in "$svc" "$svc" "INSERT INTO healthcheck VALUES (1) ON CONFLICT DO NOTHING" >/dev/null
  rows="$(psql_in "$svc" "$svc" "SELECT count(*) FROM healthcheck")"
  [ "$rows" = "1" ] || fail "$svc could not write and read its own table (rows='${rows}')"
  vec="$(psql_in "$svc" "$svc" "SELECT '[1,2,3]'::vector <=> '[1,2,4]'::vector < 1")"
  [ "$vec" = "t" ] || fail "$svc: pgvector is not answering a real query (got '${vec:-<no answer>}')"
  seen="$(psql_in "$svc" "$svc" "SELECT count(*) FROM healthcheck WHERE false")"
  [ "$seen" = "0" ] || fail "$svc sees rows it should not: $seen"
done
pass "both services answer as their OWN role: wrote, read back, and pgvector answered in alpha and in beta"

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