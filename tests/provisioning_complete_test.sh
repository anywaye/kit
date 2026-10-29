#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SERVICES="identity,courier,billing"
LAST_SERVICE="billing"

PGADMIN=anywaye
PGADMIN_DB=anywaye_platform

STMT_MS=15000
IDLE_MS=30000

IMAGE_TAG="17"
PGVECTOR_TAG="17-0.8.6"

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

export LC_ALL=C

DATABASE_LIST=""

  case "$1" in
    "" | [!a-z_]* | *[!a-z0-9_]*)
      fail "'$1' is not a bare identifier. It must match [a-z_][a-z0-9_]*, the same rule KIT_POSTGRES_DATABASES entries are held to, because it is pasted into SQL below."
      ;;
  esac
}

psql_admin() {
  docker exec -e PGPASSWORD="$PGADMIN" "$C" \
    psql --no-psqlrc --quiet --username "$PGADMIN" --dbname "$PGADMIN_DB" -tAX \
    --set=ON_ERROR_STOP=1 "$@"
}

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

run_check() {
  local violations=0 svc facts app canlogin super bypassrls owner fwd rev
  for svc in $DATABASE_LIST; do
    require_identifier "$svc"
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

CHECK_OUT=""
CHECK_EC=0
check_capture() {
  CHECK_OUT=""
  CHECK_EC=0
  CHECK_OUT="$(run_check)" || CHECK_EC=$?
}

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

if [ -n "$CLUSTER" ]; then
  C="$CLUSTER"
  LIST_SOURCE="--databases"
  if [ -z "$DATABASES" ]; then
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

PROJECT="kit-provisioning-complete-$$"

WORK="${TMPDIR:-/tmp}/kit-provisioning-complete.$$"

cleanup() {
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

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

C="$PROJECT-postgres-1"

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
  -t "kit-provisioning-complete-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/provisioning_complete_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

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
  check_capture
  if [ "$CHECK_EC" -ne 0 ]; then
    printf '%s\n' "$CHECK_OUT" | sed 's/^/   /'
    fail "$1 did not restore a green check — the restore is incomplete, and every later control is then suspect."
  fi
  say "   went red by name, the restore went green"
}

say ""
say "== control 1: DROP ROLE ${LAST_SERVICE}_app (the half nobody notices missing) =="
psql_admin -c "REVOKE ALL ON DATABASE \"$LAST_SERVICE\" FROM \"${LAST_SERVICE}_app\"" >/dev/null
psql_admin -c "DROP ROLE \"${LAST_SERVICE}_app\"" >/dev/null
run_control "DROP ROLE ${LAST_SERVICE}_app" "${LAST_SERVICE}_app does not exist"
provision_app_role "$LAST_SERVICE"
expect_green "re-provisioning ${LAST_SERVICE}_app (init's own statements)"

say ""
say "== control 2: the membership direction, REVERSED =="
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
