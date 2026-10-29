#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C

: "${KIT_POSTGRES_DATABASES:?KIT_POSTGRES_DATABASES is unset. Name the services, comma-separated. A service with no entry has no database, and its migrations fail against a database that was never created.}"

statement_timeout_ms="${KIT_POSTGRES_STATEMENT_TIMEOUT_MS:-15000}"
idle_in_transaction_ms="${KIT_POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT_MS:-30000}"
role_connection_limit="${KIT_POSTGRES_ROLE_CONNECTIONS:-10}"
extensions="${KIT_POSTGRES_EXTENSIONS:-}"

note() { printf '  [cluster] %s\n' "$1"; }

require_identifier() {
  case "$2" in
    "" | [!a-z_]* | *[!a-z0-9_]*)
      note "REFUSING '$2' as $1: must match [a-z_][a-z0-9_]*. Silently mangling an identifier here is how one service ends up owning another's database."
      exit 1
      ;;
  esac
}

admin() {
  psql --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set=ON_ERROR_STOP=1 "$@"
}

IFS=',' read -r -a entries <<<"$KIT_POSTGRES_DATABASES"
provisioned=0

for entry in "${entries[@]}"; do
  trimmed="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$trimmed" ] || continue

  case "$trimmed" in
    *[[:space:]]*)
      note "REFUSING '$trimmed' as a service name: it holds whitespace, which reads as two names with no comma between them."
      note "  KIT_POSTGRES_DATABASES is COMMA-separated: 'billing,courier', not 'billing courier'."
      note "  A space after a comma is fine; a space instead of one fuses the names into the single database '$trimmed', and this stack reported itself healthy while doing it."
      exit 1
      ;;
  esac

  service="$trimmed"
  require_identifier service "$service"
  app_role="${service}_app"
  require_identifier login-role "$app_role"
  note "provisioning $service"

  admin --set=svc="$service" --set=pw="$POSTGRES_PASSWORD" <<'SQL' >/dev/null
CREATE ROLE :"svc" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'pw';
SQL

  admin --set=app="$app_role" --set=svc="$service" --set=pw="$POSTGRES_PASSWORD" <<'SQL' >/dev/null
CREATE ROLE :"app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'pw';
GRANT :"app" TO :"svc";
SQL

  admin --set=svc="$service" <<'SQL' >/dev/null
CREATE DATABASE :"svc" OWNER :"svc";
SQL

  admin --set=svc="$service" --set=app="$app_role" --set=conn_limit="$role_connection_limit" \
    --set=stmt_ms="$statement_timeout_ms" --set=idle_ms="$idle_in_transaction_ms" <<'SQL' >/dev/null
REVOKE ALL ON DATABASE :"svc" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"svc" TO :"svc";
GRANT CONNECT, TEMPORARY ON DATABASE :"svc" TO :"app";
ALTER ROLE :"svc" CONNECTION LIMIT :conn_limit;
ALTER ROLE :"svc" SET statement_timeout = :'stmt_ms';
ALTER ROLE :"svc" SET idle_in_transaction_session_timeout = :'idle_ms';
ALTER ROLE :"app" SET statement_timeout = :'stmt_ms';
ALTER ROLE :"app" SET idle_in_transaction_session_timeout = :'idle_ms';
SQL

  psql --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$service" \
    --set=ON_ERROR_STOP=1 <<'SQL' >/dev/null
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

  if [ -n "$extensions" ]; then
    IFS=',' read -r -a ext_list <<<"$extensions"
    for raw_ext in "${ext_list[@]}"; do
      ext="$(printf '%s' "$raw_ext" | tr -d '[:space:]')"
      [ -n "$ext" ] || continue
      require_identifier extension "$ext"
      note "$service: CREATE EXTENSION IF NOT EXISTS $ext"
      psql --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$service" \
        --set=ON_ERROR_STOP=1 --set=ext="$ext" <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS :"ext";
SQL
    done
  fi

  provisioned=$((provisioned + 1))
done

if [ "$provisioned" -eq 0 ]; then
  note "REFUSING to finish with zero databases. An empty KIT_POSTGRES_DATABASES brings up a cluster that satisfies every statement in this script and isolates nothing."
  exit 1
fi

admin <<'SQL'
DO $caf$
DECLARE
  d record;
BEGIN
  FOR d IN SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname
  LOOP
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', d.datname);
    EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', d.datname, current_user);
    RAISE NOTICE 'boundary applied: % reachable only by its own role and %', d.datname, current_user;
  END LOOP;
END
$caf$;
SQL

note "done: $provisioned service database(s), an owner and a non-owner login role each, PUBLIC holds CONNECT on none of them"