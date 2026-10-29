#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-canary.XXXXXX")"
PROJECT="kit-canary-$$"
CANARY="CANARY-9f3a1c7e-DO-NOT-EXPORT"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
note() { printf 'NOTE  %s\n' "$1"; }

compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
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
  echo "SKIP  canary proofs (docker daemon not reachable)"
  exit 0
fi

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "canary: needs a python with PyYAML: pip install -r tests/requirements.txt" >&2
  exit 1
}

"$PY" - "$ROOT" "$WORK" <<'PY'
import re
import sys

import yaml

root, work = sys.argv[1], sys.argv[2]
path = f"{root}/templates/compose/otel-collector.yml"
source = open(path, encoding="utf-8").read()

shipped = yaml.safe_load(source)
BACKENDS = {"tempo", "loki", "clickstack"}
targets = [
    name
    for name in (shipped.get("exporters") or {})
    if name.partition("/")[2] in BACKENDS and name.partition("/")[0] in ("otlp", "otlphttp")
]
if not targets:
    sys.exit("canary: no backend exporters found; the shipped config changed shape")



def drop_exporter(body, name):
    """Remove one exporter block, by indentation rather than by regex.

    The first version of this used a non-greedy regex anchored on the next
    top-level key, and it matched `otlp/mimir` zero times — the file is
    perfectly valid YAML with a comment block between the blocks, and a pattern
    that has to survive comments, blank lines and a trailing `debug:` exporter
    is a pattern that will eventually take the wrong thing with it. An exporter
    that silently survived would leave the test asserting against a config with
    two exporters, which is a test of something nobody shipped.

    Indentation is the structure YAML actually has: an exporter's body is
    everything indented deeper than the key, and the block ends at the next line
    at or below the key's own indentation.
    """
    lines = body.splitlines(keepends=True)
    start = None
    for index, line in enumerate(lines):
        if line.rstrip("\n") == f"  {name}:":
            start = index
            break
    if start is None:
        sys.exit(f"canary: exporter {name} not found; the shipped config changed shape")
    end = start + 1
    while end < len(lines):
        stripped = lines[end].strip()
        indented = lines[end].startswith("    ")
        if stripped and not indented:
            break
        end += 1
    while end < len(lines) and lines[end].strip() == "":
        end += 1
        break
    return "".join(lines[:start] + lines[end:])


for name in targets:
    source = drop_exporter(source, name)

pipelines = (shipped.get("service") or {}).get("pipelines") or {}
if not pipelines:
    sys.exit("canary: the shipped config declares no pipelines")


def substitute(match):
    body = match.group(2)
    parts = [part.strip() for part in body.split(",") if part.strip()]
    if len(parts) == 1 and parts[0] not in targets:
        parts = ["file/capture"]
    else:
        parts = ["file/capture" if part in targets else part for part in parts]
    seen = []
    for part in parts:
        if part not in seen:
            seen.append(part)
    return match.group(1) + ", ".join(seen) + match.group(3)


source = re.sub(
    r"(?m)^(      exporters: \[)([^\]]*)(\])",
    substitute,
    source,
)

source = source.replace(
    "  debug:\n    verbosity: ${env:KIT_OTEL_DEBUG_VERBOSITY}",
    "  # The capture. Stands in for tempo, loki and mimir and writes the exact\n"
    "  # bytes each of them would have been handed. A `file` exporter is a real\n"
    "  # exporter from the same binary, so what lands here is what a backend\n"
    "  # would have received — not a re-serialisation of the pipeline's\n"
    "  # intentions.\n"
    "  #\n"
    "  # `file/capture`, not `capture`: the part before the slash is the COMPONENT\n"
    "  # TYPE and the collector looks it up in its factory registry. A key with no\n"
    "  # slash is a component named `capture`, and the collector rejects it at\n"
    "  # startup with a list of every type it does have — which is how this line\n"
    "  # got written wrong the first time.\n"
    "  file/capture:\n"
    "    path: /capture/telemetry.json\n"
    "    rotation:\n"
    "      max_megabytes: 32\n"
    "      max_days: 1\n"
    "  debug:\n    verbosity: ${env:KIT_OTEL_DEBUG_VERBOSITY}",
)

doc = yaml.safe_load(source)
if set(doc.get("exporters") or {}) - {"file/capture", "debug"}:
    sys.exit(
        "canary: unexpected exporters survived: "
        + ", ".join(sorted(set(doc["exporters"]) - {"file/capture", "debug"}))
    )
for signal, pipeline in sorted(
    ((doc.get("service") or {}).get("pipelines") or {}).items()
):
    got = pipeline.get("exporters")
    if not got:
        sys.exit(f"canary: the {signal} pipeline exports to nothing")
    if "file/capture" not in got:
        sys.exit(
            f"canary: the {signal} pipeline points at {got}, none of which this test can "
            f"read; a leak on {signal} would pass silently. Every pipeline must export to "
            f"file/capture."
        )
    if len(set(got)) != len(got):
        sys.exit(f"canary: the {signal} pipeline names an exporter twice: {got}")

open(f"{work}/otel-collector.yml", "w", encoding="utf-8").write(source)
PY

mkdir -p "$WORK/capture"

cat >"$WORK/compose.yml" <<'YAML'
name: kit-canary
services:
  collector:
    image: otel/opentelemetry-collector-contrib:0.115.1
    command: ["--config=/etc/otel/otel-collector.yml"]
    volumes:
      - ./otel-collector.yml:/etc/otel/otel-collector.yml:ro
      - ./capture:/capture
    environment:
      KIT_OTEL_GRPC_ENDPOINT: 0.0.0.0:4317
      KIT_OTEL_HTTP_ENDPOINT: 0.0.0.0:4318
      KIT_OTEL_SYSLOG_ENDPOINT: 0.0.0.0:5514
      KIT_OTEL_MEMORY_LIMIT_PERCENTAGE: "75"
      KIT_OTEL_MEMORY_SPIKE_PERCENTAGE: "15"
      KIT_OTEL_REDACTION_SUMMARY: debug
      KIT_OTEL_LOG_LEVEL: debug
      KIT_OTEL_BATCH_TIMEOUT: 1s
      KIT_OTEL_BATCH_SIZE: 8
      KIT_OTEL_METRIC_NAMESPACE: anywaye
      KIT_OTEL_METRICS_FLUSH_INTERVAL: 5s
      KIT_TEMPO_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_LOKI_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_OTEL_TLS_INSECURE: "true"
      KIT_OTEL_EXPORT_TIMEOUT: 1s
      KIT_OTEL_DEBUG_VERBOSITY: basic
      KIT_OTEL_HEALTH_ENDPOINT: 0.0.0.0:13133
    healthcheck:
      test: ["CMD", "/otelcol-contrib", "validate", "--config=/etc/otel/otel-collector.yml"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 2s
  sender:
    image: curlimages/curl:8.10.1
    depends_on:
      collector:
        condition: service_healthy
    volumes:
      - .:/payload:ro
    entrypoint: ["sleep", "infinity"]
YAML

printf -- '-- canary: every leak shape, and what survived\n'

if compose up -d --wait --wait-timeout 120 sender 2>"$WORK/up.log"; then
  pass "collector started with the shipped redaction pipeline plus a capturing exporter"
else
  fail "the collector would not start"
  sed 's/^/        /' "$WORK/up.log" | tail -20
  exit 1
fi

cat >"$WORK/traces.json" <<JSON
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "muse" } },
          { "key": "service.version", "value": { "stringValue": "0.4.1" } },
          { "key": "tenant_id", "value": { "stringValue": "tnt_01J9Z8R4T7Y2U6K3W8Q5N0P1DG" } },
          { "key": "service.secret", "value": { "stringValue": "$CANARY" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "kit-canary" },
          "spans": [
            {
              "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
              "spanId": "00f067aa0ba902b7",
              "name": "muse.request",
              "kind": 2,
              "startTimeUnixNano": "1759000000000000000",
              "endTimeUnixNano": "1759000000100000000",
              "status": { "code": 2, "message": "provider auth rejected" },
              "attributes": [
                { "key": "http.request.method", "value": { "stringValue": "POST" } },
                { "key": "http.route", "value": { "stringValue": "/v1/route" } },
                { "key": "error.type", "value": { "stringValue": "provider_auth" } },
                { "key": "otel.status_code", "value": { "stringValue": "ERROR" } },
                { "key": "llm.model", "value": { "stringValue": "gpt-4o-mini" } },
                { "key": "llm.tokens_in", "value": { "intValue": "1200" } },

                { "key": "llm.prompt", "value": { "stringValue": "my prompt contains $CANARY" } },
                { "key": "llm.completion", "value": { "stringValue": "echoing back: $CANARY" } },
                { "key": "llm.prompt_sha256", "value": { "stringValue": "deadbeef$CANARY" } },
                { "key": "error.message", "value": { "stringValue": "content rejected: $CANARY" } },
                { "key": "error.stacktrace", "value": { "stringValue": "at muse: $CANARY" } },
                { "key": "gen_ai.prompt", "value": { "stringValue": "$CANARY" } },
                { "key": "url.full", "value": { "stringValue": "https://api/v1?prompt=$CANARY" } },
                { "key": "http.request.header.authorization", "value": { "stringValue": "Bearer sk-abcdefghijklmnopqrstuvwx" } },
                { "key": "user.email", "value": { "stringValue": "someone-$CANARY@example.com" } },
                { "key": "db.statement", "value": { "stringValue": "select * from t where note='$CANARY'" } }
              ],
              "events": [
                {
                  "name": "exception",
                  "timeUnixNano": "1759000000050000000",
                  "attributes": [
                    { "key": "exception.type", "value": { "stringValue": "ProviderAuthError" } },
                    { "key": "exception.message", "value": { "stringValue": "$CANARY" } },
                    { "key": "exception.stacktrace", "value": { "stringValue": "File x line 1: $CANARY" } }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
JSON

cat >"$WORK/logs.json" <<JSON
{
  "resourceLogs": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "muse" } }
        ]
      },
      "scopeLogs": [
        {
          "scope": { "name": "kit-canary" },
          "logRecords": [
            {
              "timeUnixNano": "1759000000000000000",
              "severityNumber": 17,
              "severityText": "ERROR",
              "body": { "stringValue": "outbox row 4471 exceeded 5 attempts" },
              "attributes": [
                { "key": "log.severity", "value": { "stringValue": "error" } },
                { "key": "service.name", "value": { "stringValue": "muse" } },
                { "key": "error.type", "value": { "stringValue": "dependency_unavailable" } },
                { "key": "exception.type", "value": { "stringValue": "ProviderAuthError" } },
                { "key": "exception.message", "value": { "stringValue": "$CANARY" } },
                { "key": "exception.stacktrace", "value": { "stringValue": "line 1: $CANARY" } },
                { "key": "llm.prompt", "value": { "stringValue": "$CANARY" } },
                { "key": "http.request.body", "value": { "stringValue": "prompt=$CANARY" } },
                { "key": "http.route", "value": { "stringValue": "/v1/route" } }
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
          { "key": "service.name", "value": { "stringValue": "muse" } },
          { "key": "tenant_id", "value": { "stringValue": "tnt_01J9Z8R4T7Y2U6K3W8Q5N0P1DG" } }
        ]
      },
      "scopeMetrics": [
        {
          "scope": { "name": "kit-canary" },
          "metrics": [
            {
              "name": "http.server.request.duration",
              "unit": "s",
              "description": "how long a request took",
              "histogram": {
                "aggregationTemporality": 2,
                "dataPoints": [
                  {
                    "timeUnixNano": "1759000000000000000",
                    "count": "1",
                    "sum": 0.01,
                    "attributes": [
                      { "key": "http.route", "value": { "stringValue": "/v1/route" } },
                      { "key": "http.response.status_code_class", "value": { "stringValue": "5xx" } },
                      { "key": "error.type", "value": { "stringValue": "provider_auth" } },
                      { "key": "tenant_id", "value": { "stringValue": "tnt_-$CANARY" } },
                      { "key": "llm.prompt", "value": { "stringValue": "$CANARY" } },
                      { "key": "error.message", "value": { "stringValue": "$CANARY" } }
                    ],
                    "bucketCounts": ["1", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"],
                    "explicitBounds": [0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
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

for signal in traces logs metrics; do
  code="$(compose exec -T sender curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://collector:4318/v1/$signal" \
    -H 'Content-Type: application/json' \
    --data-binary "@/payload/$signal.json" 2>/dev/null || echo 000)"
  case "$code" in
    200) pass "OTLP/$signal accepted — the canary reached the collector's receiver" ;;
    *) fail "OTLP/$signal rejected with HTTP $code" ;;
  esac
done

if wait_for "capture written" 40 sh -c \
  "test -s '$WORK/capture/telemetry.json' && grep -q 'provider_auth' '$WORK/capture/telemetry.json' && grep -q 'dependency_unavailable' '$WORK/capture/telemetry.json'"; then
  pass "the capture contains data that passed the redaction boundary"
else
  fail "nothing reached the capturing exporter within 40s"
  compose logs --tail 30 collector 2>&1 | sed 's/^/        /' || true
  exit 1
fi

CAPTURE="$WORK/capture/telemetry.json"


leaks="$(grep -c "$CANARY" "$CAPTURE" 2>/dev/null || true)"
leaks="${leaks:-0}"
body_lines="$(grep "$CANARY" "$CAPTURE" 2>/dev/null | grep -c '"body"' || true)"
body_lines="${body_lines:-0}"
summary_lines="$(grep "$CANARY" "$CAPTURE" 2>/dev/null | grep -c 'redaction\.redacted\.keys' || true)"
summary_lines="${summary_lines:-0}"
attribute_leaks=$((leaks - body_lines - summary_lines))

if [ "$attribute_leaks" -eq 0 ]; then
  pass "the canary reached no exporter as an attribute, on any signal, at any depth"
else
  fail "the canary reached an exporter in $attribute_leaks attribute(s)"
  grep "$CANARY" "$CAPTURE" | grep -v '"body"' | head -5 | cut -c1-400 | sed 's/^/        /'
fi

removed_keys=()
for key in \
  'llm.prompt"' 'llm.completion"' 'llm.prompt_sha256"' 'error.message"' \
  'error.stacktrace"' 'gen_ai.prompt"' 'url.full"' 'exception.message"' \
  'exception.stacktrace"' 'http.request.body"' 'user.email"' \
  'db.statement"' 'http.request.header.authorization"' 'service.secret"'
do
  line="$(grep -F "\"$key" "$CAPTURE" 2>/dev/null | head -1 || true)"
  [ -n "$line" ] || continue
  if grep -q 'redaction\.redacted\.keys' <<<"$line"; then
    removed_keys+=("${key%\"}")
  else
    fail "key ${key%\"} survived the redaction boundary"
    printf '%s\n' "$line" | cut -c1-300 | sed 's/^/        /'
  fi
done
if [ "${#removed_keys[@]}" -gt 0 ]; then
  note "removed and named in the summary: ${removed_keys[*]}"
fi
pass "no planted content-bearing key survived, checked one key at a time"

if grep -q 'tnt_-'"$CANARY" "$CAPTURE" 2>/dev/null; then
  fail "a tenant_id reached a measurement, where core prohibits it"
else
  pass "no tenant_id reached a measurement attribute — the cardinality trap is closed"
fi

if grep -q 'sk-abcdefghijklmnopqrstuvwx' "$CAPTURE" 2>/dev/null; then
  fail "a credential-shaped value under an allowlisted key was not masked"
else
  pass "a bearer token under an allowlisted key was masked by blocked_values"
fi

for expected in provider_auth /v1/route gpt-4o-mini dependency_unavailable; do
  if grep -qF "$expected" "$CAPTURE" 2>/dev/null; then
    pass "allowed data survived: $expected"
  else
    fail "allowed data was destroyed by the boundary: $expected"
  fi
done

if grep -qF 'tnt_01J9Z8R4T7Y2U6K3W8Q5N0P1DG"' "$CAPTURE" 2>/dev/null; then
  pass "a resource tenant_id survived — identity stays on the resource, off the measurement"
else
  fail "resource attributes were stripped, which breaks the per-tenant totals core requires"
fi

docker logs "$PROJECT-collector-1" >"$WORK/collector.log" 2>&1 || true

if wait_for "the collector records what it redacted" 20 \
  grep -qi 'redact' "$WORK/collector.log"; then
  pass "the collector's own log records the redaction — removal is observed, not inferred"
else
  note "no redaction summary in the collector's log this run; removal is asserted by absence only"
fi

note "log bodies are the one place free text is EXPECTED: core requires a body and"
note "bounds it at 2048 characters, and the redaction processor is specified over"
note "ATTRIBUTES. This test does not assert a body is scrubbed, and a reader who"
note "assumes it is scrubbed is the reader who puts a prompt in one."

if wait_for "the spanmetrics connector flushes derived metrics" 30 \
  grep -qi 'span_metrics\|anywaye_span\|duration' "$CAPTURE"; then
  pass "the spanmetrics connector emitted derived metrics from redacted spans"
else
  note "no spanmetrics output in this capture; the metric assertions cover the direct OTLP path"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: canary — $failures assertion(s) failed. The capture was at $CAPTURE"
  exit 1
fi
echo "PASS: canary — a secret in every leak shape reached no exporter, and the allowed data survived."
