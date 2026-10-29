#!/usr/bin/env bash
set -euo pipefail

SERVICE_ROOT="${SERVICE_ROOT:-$(pwd)}"
CONFIG_FILE="${KIT_DEPLOY_CONFIG:-config/deploy.yml}"

kamal_cmd() {
  if [ -x "$SERVICE_ROOT/bin/kamal" ]; then
    printf 'bin/kamal'
  elif [ -f "$SERVICE_ROOT/Gemfile" ]; then
    printf 'bundle exec kamal'
  else
    printf 'kamal'
  fi
}

note() { printf 'drill: %s\n' "$*" >&2; }
die() {
  printf 'drill: %s\n' "$*" >&2
  exit "${2:-1}"
}

usage() {
  cat >&2 <<'USAGE'
usage: drill.sh --table NAME [--table NAME ...] [options]

  --table NAME        a table that MUST have rows after the restore. Repeatable,
                      and required: a drill with no table asserts nothing.
  --scratch NAME      scratch database name (default: <service>_drill)
  --snapshot ID       restore a specific snapshot instead of the latest
  --database URL      the postgres accessory's host:port (default: <service>-postgres:5432)
  --print-check       print the generated check command and exit, running nothing
  -h, --help          this text
USAGE
  exit 64
}

TABLES=""
SCRATCH=""
SNAPSHOT=""
PGHOST_OVERRIDE=""
PRINT_CHECK=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --table)
      [ "$#" -ge 2 ] || usage
      TABLES="$TABLES $2"
      shift 2
      ;;
    --table=*)
      TABLES="$TABLES ${1#*=}"
      shift
      ;;
    --scratch)
      [ "$#" -ge 2 ] || usage
      SCRATCH="$2"
      shift 2
      ;;
    --scratch=*)
      SCRATCH="${1#*=}"
      shift
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || usage
      SNAPSHOT="$2"
      shift 2
      ;;
    --snapshot=*)
      SNAPSHOT="${1#*=}"
      shift
      ;;
    --database)
      [ "$#" -ge 2 ] || usage
      PGHOST_OVERRIDE="$2"
      shift 2
      ;;
    --print-check)
      PRINT_CHECK=1
      shift
      ;;
    -h | --help) usage ;;
    *) printf 'drill: unknown argument %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "${TABLES// /}" ] || usage

[ -f "$SERVICE_ROOT/$CONFIG_FILE" ] ||
  die "no Kamal config at $SERVICE_ROOT/$CONFIG_FILE. Run this from the service repository."

SERVICE="$(awk '/^service:/ { print $2; exit }' "$SERVICE_ROOT/$CONFIG_FILE")"
[ -n "$SERVICE" ] ||
  die "$CONFIG_FILE has no top-level 'service:' line, so there is no name to derive a scratch database from."

case "$SERVICE" in
  *'<'* | *'%'*)
    die "$CONFIG_FILE still contains ERB. This is kit's template, not a rendered Kamal config — copy it to $CONFIG_FILE and let Kamal render it (or render it yourself) before drilling." 64
    ;;
esac

[ -n "$SCRATCH" ] || SCRATCH="${SERVICE}_drill"

case "$SCRATCH" in
  *prod* | *PROD* | *live* | *LIVE*)
    die "refusing to drill into '$SCRATCH': the name looks like production. A drill restores into a scratch database and then DROPS it, so a production-looking name is a database that gets dropped." 65
    ;;
esac

[ "$SCRATCH" != "$SERVICE" ] ||
  die "refusing to drill into '$SCRATCH': that is the live database." 65

case "$SCRATCH" in
  [A-Za-z_]* ) ;;
  * ) die "scratch database name '$SCRATCH' must start with a letter or underscore" 64 ;;
esac

SQL_MARK='CAF_DRILL_SQL'

build_check() {
  local scratch="$1" body="" table
  for table in $TABLES; do
    [ -n "$body" ] && body="${body}
    "
    body="${body}    IF (SELECT count(*) FROM \"${table}\") = 0 THEN
      RAISE EXCEPTION 'drill: table ${table} is empty in ${scratch}';
    END IF;"
  done

  printf '%s\n' \
    "psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname=${scratch} <<'${SQL_MARK}'" \
    'DO $$' \
    'DECLARE' \
    'BEGIN' \
    "${body}" \
    'END' \
    '$$;' \
    "${SQL_MARK}"
}

CHECK_COMMAND="$(build_check "$SCRATCH")"

if [ "$PRINT_CHECK" -eq 1 ]; then
  printf '%s\n' "$CHECK_COMMAND"
  exit 0
fi

DATABASE_URL="${DATABASE_URL:-}"
[ -n "$DATABASE_URL" ] ||
  die "DATABASE_URL is not set. It is a Kamal secret on the backup accessory, so this normally runs through 'kamal accessory exec'; running it directly means exporting the secret yourself." 78

url_scheme="${DATABASE_URL%%://*}"
url_rest="${DATABASE_URL#*://}"
url_userinfo="${url_rest%%@*}"
url_hostport="${url_rest##*@}"
url_host="${url_hostport%%:*}"
url_port="${url_hostport##*:}"
[ "$url_port" = "$url_hostport" ] && url_port=5432
url_user="${url_userinfo%%:*}"
url_pass=""
case "$url_userinfo" in
  *:*) url_pass="${url_userinfo#*:}" ;;
esac

case "$url_scheme" in
  postgres | postgresql) ;;
  *) die "DATABASE_URL must be a postgres:// URL, not $url_scheme://" 64 ;;
esac

: "${PGHOST:=$url_host}"
: "${PGPORT:=$url_port}"
: "${PGUSER:=$url_user}"
: "${PGPASSWORD:=$url_pass}"
if [ -n "$PGHOST_OVERRIDE" ]; then
  PGHOST="${PGHOST_OVERRIDE%%:*}"
  PGPORT="${PGHOST_OVERRIDE##*:}"
  [ "$PGPORT" = "$PGHOST_OVERRIDE" ] && PGPORT=5432
fi
export PGHOST PGPORT PGUSER PGPASSWORD

admin() { psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname=postgres "$@"; }

cleanup() {
  admin -c "DROP DATABASE IF EXISTS \"${SCRATCH}\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

note "scratch database '${SCRATCH}' will be dropped on every exit path, including a failure or a Ctrl-C"

cleanup
admin -c "CREATE DATABASE \"${SCRATCH}\"" >/dev/null ||
  die "could not create the scratch database '${SCRATCH}'. If it exists, something else owns it — pick another name with --scratch."

KAMAL="$(kamal_cmd)"
set -- drill production ${SNAPSHOT:-latest} \
  --database "$SCRATCH" \
  --check "$CHECK_COMMAND" \
  --yes

status=0
"$KAMAL" accessory exec -c "$CONFIG_FILE" --interactive --reuse backup \
  kamal-backup "$@" || status=$?

cleanup

if [ "$status" -ne 0 ]; then
  die "the drill FAILED (kamal-backup exit ${status}). The scratch database has been dropped; nothing about the live database was touched."
fi

note "drill passed: '${SCRATCH}' held rows in $(echo $TABLES | wc -w | tr -d ' ') table(s), and has been dropped."
