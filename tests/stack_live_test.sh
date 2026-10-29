#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-stack.XXXXXX")"
PROJECT="kit-stack-$$"
STACK_NAME="$PROJECT"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
note() { printf 'NOTE  %s\n' "$1"; }

CANARY="CANARY-4e8b2a91-DO-NOT-SHIP"

cleanup() {
  [ "${KIT_KEEP_WORKDIR:-0}" = "1" ] ||
    (cd "$SERVICE" 2>/dev/null && bash ./bin/dev nuke >/dev/null 2>&1) || true
  if [ "${KIT_KEEP_WORKDIR:-0}" = "1" ]; then
    printf 'NOTE  keeping %s and the compose project %s\n' "$WORK" "$PROJECT" >&2
    return 0
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

wait_for() {
  local label="$1" deadline="$2"
  shift 2
  local start now out
  start=$(date +%s)
  while :; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$deadline" ]; then
      printf 'timed out after %ss waiting for: %s\n' "$deadline" "$label"
      printf '%s\n' "$out" | tail -20 | sed 's/^/        /' || true
      return 1
    fi
    sleep 1
  done
}

if ! docker info >/dev/null 2>&1; then
  echo "SKIP  stack live proof (docker daemon not reachable)"
  exit 0
fi

REMOTE="$WORK/kit-remote.git"
SEED="$WORK/seed"
mkdir -p "$SEED"
(cd "$ROOT" && tar -cf - --exclude=./.git --exclude=./.venv --exclude=./__pycache__ .) |
  (cd "$SEED" && tar -xf -)
git -C "$SEED" init -q
git -C "$SEED" add -A
git -C "$SEED" -c user.email=t@example.invalid -c user.name=kit13 commit -q -m "seed"
git clone --bare --quiet "$SEED" "$REMOTE"
rm -rf "$SEED"
PIN="$(git -C "$REMOTE" rev-parse HEAD)"

SERVICE="$WORK/service"
mkdir -p "$SERVICE/bin"
cp "$ROOT/templates/bin/dev.sh" "$SERVICE/bin/dev"
chmod +x "$SERVICE/bin/dev"

pick_port_base() {
  local base port p
  for base in $(seq 15000 10 15980); do
    local free=1
    for p in 0 500 600 700 800 900 901 902; do
      port=$((base + p))
      if ! port_is_free "$port"; then
        free=0
        break
      fi
    done
    [ "$free" -eq 1 ] && {
      printf '%s' "$base"
      return 0
    }
  done
  echo "SKIP  stack live proof (no free slice of the 15000-15999 block)" >&2
  return 1
}

port_is_free() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && {
    exec 3<&- 2>/dev/null || true
    return 1
  }
  return 0
}

PORT_BASE="$(pick_port_base)" || exit 0
note "using host ports $PORT_BASE-$((PORT_BASE + 902)) (a free slice of kit's 15000-15999 block)"

cat >"$SERVICE/docker-compose.yml" <<'YAML'
services:
  probe:
    image: curlimages/curl:8.10.1
    entrypoint: ["sleep", "infinity"]
    networks: [platform]
    volumes:
      - ./payload:/payload:ro
YAML
printf '%s\n' "$PIN" >"$SERVICE/kit.ref"
cat >"$SERVICE/.env" <<ENV
KIT_STACK_URL=file://$REMOTE
KIT_STACK_HOME=$WORK/cache
KIT_STACK_NAME=$STACK_NAME
KIT_GRAFANA_PORT=$PORT_BASE
KIT_POSTGRES_PORT=$((PORT_BASE + 500))
KIT_POSTGRES_DATABASES=kit_probe
KIT_NATS_CLIENT_PORT=$((PORT_BASE + 600))
KIT_NATS_MONITOR_PORT=$((PORT_BASE + 700))
KIT_REDIS_PORT=$((PORT_BASE + 800))
KIT_TEMPO_PORT=$((PORT_BASE + 900))
KIT_LOKI_PORT=$((PORT_BASE + 901))
KIT_OTEL_DEBUG_VERBOSITY=detailed
ENV

cd "$SERVICE"

printf -- '-- live: the FETCHED stack comes up, and a trace reaches Tempo\n'

step_up() {
  KIT_DEV_TIMEOUT=420 KIT_DEV_PROFILES=observability bash ./bin/dev up >"$WORK/up.log" 2>&1 || true
}

if ! wait_for "bin/dev up to finish its stack phase" 300 step_up; then
  if ! docker info >/dev/null 2>&1; then
    echo "SKIP  stack live proof (the docker daemon went away during the run)" >&2
    exit 0
  fi
  fail "bin/dev up did not finish its stack phase"
  tail -40 "$WORK/up.log" | sed 's/^/        /'
  exit 1
fi

if grep -q 'no migration command found' "$WORK/up.log" &&
  grep -q 'starting the stack from kit@' "$WORK/up.log"; then
  pass "the fetched stack came up healthy, and only then did bin/dev look for migrations"
else
  if ! docker info >/dev/null 2>&1; then
    echo "SKIP  stack live proof (the docker daemon went away during the run)" >&2
    exit 0
  fi
  fail "bin/dev up did not get the stack up before it looked for a migration command"
  tail -30 "$WORK/up.log" | sed 's/^/        /'
  exit 1
fi

unhealthy="$(docker compose -p "$PROJECT" ps --format '{{.Service}}|{{.Health}}' 2>/dev/null |
  awk -F'|' '$2 != "" && $2 != "healthy" {print $1" ("$2")"}' || true)"
if [ -z "$unhealthy" ]; then
  checked="$(docker compose -p "$PROJECT" ps --format '{{.Health}}' 2>/dev/null |
    grep -c 'healthy' || true)"
  pass "every service that declares a healthcheck reports healthy ($checked of them)"
else
  fail "these services are not healthy: $unhealthy"
fi

db_query() {
  docker compose -p "$PROJECT" exec -T postgres \
    psql --no-psqlrc --quiet --username "${KIT_POSTGRES_USER:-anywaye}" \
    --dbname "${KIT_POSTGRES_DB:-anywaye_platform}" --tuples-only --no-align \
    --set=ON_ERROR_STOP=1 --command="$1" 2>/dev/null | tr -d '[:space:]'
}

tenant_db="$(db_query "select count(*) from pg_database where datname = 'kit_probe'")"
tenant_owner="$(db_query "select coalesce(pg_get_userbyid(datdba), '') from pg_database where datname = 'kit_probe'")"
tenant_role="$(db_query "select count(*) from pg_roles where rolname = 'kit_probe'")"
tenant_super="$(db_query "select coalesce(max(rolsuper::int), -1) from pg_roles where rolname = 'kit_probe'")"

if [ "$tenant_db" = "1" ] && [ "$tenant_owner" = "kit_probe" ]; then
  pass "the initdb mount reached the running server: database kit_probe exists, owned by role kit_probe"
else
  fail "database kit_probe is missing or not owned by kit_probe (found=$tenant_db owner=${tenant_owner:-none}). \
An empty /docker-entrypoint-initdb.d produces exactly this: a healthy cluster with none of the fleet's databases."
fi

if [ "$tenant_role" = "1" ] && [ "$tenant_super" = "0" ]; then
  pass "role kit_probe exists and is not a superuser (NOSUPERUSER, so a service cannot admin the cluster)"
else
  fail "role kit_probe is missing (count=$tenant_role) or is a superuser (rolsuper=$tenant_super)"
fi

tenant_acl="$(db_query "select coalesce(array_to_string(datacl, ','), '') from pg_database where datname = 'kit_probe'")"
if [ -z "$tenant_acl" ]; then
  fail "database kit_probe carries no ACL at all (datacl is null), so it still has Postgres's defaults and PUBLIC may CONNECT"
elif printf '%s' "$tenant_acl" | grep -qE '(^|,)=[A-Za-z]*/'; then
  fail "PUBLIC still holds a privilege on database kit_probe: $tenant_acl"
else
  pass "PUBLIC holds no privilege on database kit_probe (datacl=$tenant_acl)"
fi

FETCHED="$WORK/cache/$PIN"
if [ -f "$FETCHED/.kit-stack-ref" ] && [ "$(head -1 "$FETCHED/.kit-stack-ref")" = "$PIN" ]; then
  pass "the running stack came from the fetched tree at the pinned ref ($PIN)"
else
  fail "the stack did not come from the pinned fetch"
fi

MOUNT_SRC="$(docker inspect --format   '{{range .Mounts}}{{if eq .Destination "/etc/otel/otel-collector.yml"}}{{.Source}}{{end}}{{end}}' \
  "$PROJECT-otel-collector-1" 2>/dev/null || true)"
if [ -z "$MOUNT_SRC" ]; then
  fail "the collector container has no bind mount at /etc/otel/otel-collector.yml.
   Without it the collector is running a default config, and a default config is
   not the redaction allowlist."
elif diff -q "$MOUNT_SRC" "$FETCHED/templates/compose/otel-collector.yml" >/dev/null 2>&1; then
  pass "the collector's config is the FETCHED otel-collector.yml, byte for byte (per docker inspect)"
else
  fail "the collector is running $MOUNT_SRC, which is NOT the fetched config at $FETCHED"
fi

if [ "$(head -1 "$FETCHED/.kit-stack-ref" 2>/dev/null)" = "$PIN" ]; then
  pass "the tree the collector is reading declares the pinned ref ($PIN)"
else
  fail "the fetched tree records a different ref than the one pinned"
fi

cat >"$WORK/traces.json" <<JSON
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "kitstackprobe" } },
          { "key": "service.namespace", "value": { "stringValue": "anywaye" } },
          { "key": "tenant_id", "value": { "stringValue": "tnt_kit13live" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "kit-stack-live" },
          "spans": [
            {
              "traceId": "9c1f2b7a4d3e5f60718293a4b5c6d7e8",
              "spanId": "1a2b3c4d5e6f7081",
              "name": "kit.probe",
              "kind": 2,
              "startTimeUnixNano": "$(($(date +%s) * 1000000000 - 50000000))",
              "endTimeUnixNano": "$(($(date +%s) * 1000000000))",
              "status": { "code": 2, "message": "provider auth rejected" },
              "attributes": [
                { "key": "http.route", "value": { "stringValue": "/v1/probe" } },
                { "key": "error.type", "value": { "stringValue": "provider_auth" } },
                { "key": "otel.status_code", "value": { "stringValue": "ERROR" } },
                { "key": "llm.model", "value": { "stringValue": "gpt-4o-mini" } },
                { "key": "llm.prompt", "value": { "stringValue": "a prompt containing $CANARY" } },
                { "key": "error.message", "value": { "stringValue": "rejected: $CANARY" } }
              ]
            }
          ]
        }
      ]
    }
  ]
}
JSON

cat >"$WORK/metrics.json" <<JSON
{
  "resourceMetrics": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "kitstackprobe" } },
          { "key": "service.namespace", "value": { "stringValue": "anywaye" } }
        ]
      },
      "scopeMetrics": [
        {
          "scope": { "name": "kit-stack-live" },
          "metrics": [
            {
              "name": "kit.probe.calls",
              "unit": "1",
              "description": "a direct metric, so the OTLP metrics path is proven as well as the connector's",
              "counter": {
                "aggregationTemporality": 2,
                "dataPoints": [
                  {
                    "timeUnixNano": "$(($(date +%s) * 1000000000))",
                    "asInt": "3",
                    "attributes": [
                      { "key": "http.route", "value": { "stringValue": "/v1/probe" } }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
JSON

send() {
  local signal="$1"
  docker compose -p "$PROJECT" exec -T probe curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://otel-collector:4318/v1/$signal" \
    -H 'Content-Type: application/json' \
    --data-binary "@/payload/$signal.json" 2>/dev/null || echo 000
}
mkdir -p "$SERVICE/payload"
cp "$WORK/traces.json" "$WORK/metrics.json" "$SERVICE/payload/"

for signal in traces metrics; do
  code="$(send "$signal")"
  case "$code" in
    200) pass "OTLP/$signal accepted by the running collector" ;;
    *) fail "OTLP/$signal rejected with HTTP $code" ;;
  esac
done

tempo_port() { docker compose -p "$PROJECT" port tempo 3200 2>/dev/null | sed 's/.*://'; }

if ! TP="$(tempo_port)" || [ -z "$TP" ]; then
  fail "tempo is not running, so nothing in section 4 can be read off it"
  note "is KIT_DEV_PROFILES=tempo set in this file's .env above?"
  docker compose -p "$PROJECT" ps --services 2>/dev/null | sed 's/^/        running: /' || true
  exit 1
fi
note "tempo on $TP (read from compose, not assumed)"

if wait_for "the trace reaches Tempo" 60 sh -c \
  "curl -sf 'http://localhost:$TP/api/search?tags=service.name%3Dkitstackprobe' | grep -q kit.probe"; then
  pass "the trace is in Tempo, found by service.name"
else
  fail "the trace never reached Tempo within 60s"
  curl -s "http://localhost:$TP/api/search?tags=service.name%3Dkitstackprobe" 2>&1 |
    head -5 | sed 's/^/        /' || true
fi

if wait_for "Tempo serves the trace by id" 40 sh -c \
  "curl -sf 'http://localhost:$TP/api/traces/9c1f2b7a4d3e5f60718293a4b5c6d7e8' | grep -q provider_auth"; then
  pass "Tempo returns the trace, and error.type survived the boundary"
else
  fail "Tempo did not return the trace, or error.type was stripped"
fi

if curl -sf "http://localhost:$TP/api/traces/9c1f2b7a4d3e5f60718293a4b5c6d7e8" 2>/dev/null |
  grep -q "$CANARY"; then
  fail "the canary reached TEMPO — the redaction boundary does not hold on the live stack"
else
  pass "the canary reached no exporter on the live stack (Tempo checked by trace id)"
fi

# ---------------------------------------------------------------------------
# 5. the DERIVED METRIC REACHES THE COLLECTOR'S OWN STDOUT
# ---------------------------------------------------------------------------
# WHERE THIS LOOKED BEFORE, AND WHY IT CANNOT LOOK THERE ANY MORE. This section
# used to query a metrics store over its published PromQL port for two things:
# the metric the probe sent directly, and the one the `spanmetrics` connector
# minted from the trace. That store cost 130s of readiness budget per cold start
# (retries 12 x interval 10s) against a 180s deadline for the whole stack, and
# was removed rather than left half-wired — no service, no volume, no port, no
# exporter dialling a host with nothing on it.
#
# So the assertions move to the collector's `debug` exporter, which is where the
# metrics pipeline goes now, and which is a BETTER place to read them from: the
# store answered a question about what survived to disk, and the exporter
# answers the question the change is actually about, which is whether the
# derived series still pass the ingest deny set on the way OUT. Nothing in this
# tree stores metrics, so the collector's stdout is the last place a dropped
# dimension can still be observed — and it is observable, because the export
# prints the attribute map (see `KIT_OTEL_DEBUG_VERBOSITY=detailed` in the .env
# this test writes above).
#
# `collector_logs` reads the container rather than a file, because a file
# exporter standing in for the fan-out is exactly what `canary_test.sh` already
# substitutes and what this test exists not to do.
#
# And it is a FUNCTION, which is a trap the first version of this assertion fell
# into. `wait_for` takes a COMMAND and runs it through `sh -c`, and `sh -c` is a
# new shell: it does not inherit this file's functions. The probe therefore ran
# `collector_logs`, got `sh: collector_logs: command not found`, and exited
# nonzero on the FIRST attempt and on all ninety after it — so the assertion
# reported that the spanmetrics connector had minted nothing while the very log
# lines it printed on failure showed `Name: anywaye.calls_total` sitting right
# there. A probe that cannot run and a system that is broken look identical from
# the outside, which is why this is a function AND why the command form is
# spelled out where `sh` can see it.
collector_logs() { docker compose -p "$PROJECT" logs --no-color otel-collector 2>/dev/null; }

if wait_for "the spanmetrics connector mints a metric" 90 sh -c \
  "docker compose -p '$PROJECT' logs --no-color otel-collector 2>/dev/null | grep -qE 'anywaye[_.]duration'"; then
  pass "the spanmetrics connector exported anywaye_duration — the fleet dashboard's source"
else
  fail "the spanmetrics connector minted nothing: the error view would be empty"
  collector_logs | grep -iE 'anywaye[_.]' | head -5 | sed 's/^/        /' || true
fi

if collector_logs | grep -qE 'tenant_id|account_id|request_id'; then
  fail "a high-cardinality dimension reached an exporter as a metric label — the ingest deny set did not run"
  collector_logs | grep -nE 'tenant_id|account_id|request_id' | head -5 | sed 's/^/        /' || true
else
  pass "no high-cardinality dimension appears on an exported metric label"
fi

if collector_logs | grep -q "$CANARY"; then
  fail "the canary reached the collector's exporter"
else
  pass "the canary reached no exporter on the live stack (exported attributes checked)"
fi

if docker compose -p "$PROJECT" ps --services 2>/dev/null | grep -qx probe; then
  pass "the service's own service joined the fetched stack rather than replacing it"
else
  fail "the service's own service is not in the running project"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: stack live — $failures assertion(s) failed. Logs in $WORK/up.log"
  exit 1
fi
echo "PASS: stack live — the fetched stack ran, and a trace reached Tempo and a derived metric reached the collector's exporter."
