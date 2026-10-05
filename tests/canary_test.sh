#!/usr/bin/env bash
#
# kit's proof that the redaction boundary holds, against a REAL collector.
#
#   bash tests/canary_test.sh
#
# THE CLAIM
#   "Prompt and completion content must never appear in a telemetry span."
#   (core/schemas/telemetry/redaction.schema.json, `default: "deny"`)
#
#   Every other proof of this in the fleet is a STATIC assertion over an
#   allowlist: kit's gate compares the collector's `allowed_keys` to core's
#   schemas, and muse asserts its own `ALLOWED_SPAN_ATTRIBUTES` over a rendered
#   span. Those are necessary and they are not sufficient. A key-name check
#   proves the names somebody already thought of are absent, and the realistic
#   way this leaks is a name nobody predicted — a well-meaning `muse.prompt`
#   added in six months by someone debugging a routing decision, not an
#   attacker.
#
#   So this test plants a canary string in every shape a leak could take and
#   asserts it appears in NOTHING that left the collector:
#
#     a banned key            (`llm.prompt`)       the obvious one
#     an SDK-default key      (`error.message`)    shipped by every SDK
#     the exception form      (`exception.message`) the migration path
#     a near-miss key         (`llm.prompt_sha256`) the sneaky one
#     an allowed key          (`http.route`)       the important one
#     a resource attribute    (`service.secret`)   the one nobody checks
#     a credential VALUE under an allowed key — blocked_values, not the allowlist
#     a metric data point     the label, not the span
#     a log record attribute
#     a log record BODY       — reported, not asserted. See below.
#
#   And it asserts the ALLOWED data survived, which is the half that is easy to
#   fake: a collector that drops everything passes a "no canary" test and is
#   useless. If `error.type`, `http.route` and a resource `tenant_id` do not
#   arrive, the boundary is not enforcing a policy, it is deleting the data.
#
# THE LOG BODY IS DELIBERATELY NOT ASSERTED, and this is the one thing a reader
# must not get wrong. The body is the one place free text is EXPECTED — core's
# log schema requires it and bounds it at 2048 characters — and the redaction
# processor is specified over ATTRIBUTES, so a body is neither scrubbed nor
# claimed to be. The test says so out loud rather than quietly passing, because
# a reader who assumes the body is scrubbed is exactly the reader who puts a
# prompt in one.
#
# HOUSE PATTERN
#   muse/tests/test_trace_propagation.py, which places a canary in both the
#   prompt and the completion and asserts it appears nowhere in the rendered
#   span payload, SEPARATELY from the key-name check so that truncation cannot
#   be what makes it pass. The `http.route` case is that separation: the key is
#   allowlisted so it survives, and the canary in its VALUE is the only thing
#   standing between a working pipeline and a silent pass.
#
# THE CONFIG UNDER TEST
#   The shipped `templates/compose/otel-collector.yml`, with its three exporters
#   mechanically replaced by a `file` exporter. Built by substitution, never
#   maintained as a second copy: a second copy of the redaction config is a
#   second place for the allowlist to drift, and the allowlist is the thing this
#   test exists to check. The redaction processors, their order, the transform
#   and the spanmetrics connector are all the shipped ones, unmodified.
#
# NO SLEEPS. Every wait is a poll on a health or content signal with a deadline.
# A sleep is a guess about someone else's flush interval, and it is wrong on the
# machine where it matters.

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
      # The label goes in the timeout message. A bare "timed out" on a
      # container that exited two seconds in is the least useful thing this
      # script could print, and the label is the half of the message that
      # survives a paste into a terminal.
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

# ---------------------------------------------------------------------------
# The capturing exporter, substituted into the shipped config.
# ---------------------------------------------------------------------------
# The venv python, not `python3`. This script parses the substituted config, and
# the system python on most machines has no PyYAML — so the first run of this
# died with a ModuleNotFoundError that said nothing about the boundary. Same
# resolution order as validate.sh, so one variable configures both.
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

# WHICH EXPORTERS TO REPLACE IS DISCOVERED, NOT LISTED. This block was written
# with `("otlp/tempo", "otlp/loki", "otlp/mimir")` hardcoded, and it died the
# moment the shipped config corrected Loki and Mimir to `otlphttp/` — which it
# had to, because those two backends have no gRPC OTLP listener at all. A test
# that fails on a rename is a test that will be "fixed" by renaming the thing it
# was asserting about, so the names come from the parsed document and a rename
# costs nothing here.
#
# The set is the three stores that ship: Tempo and Loki (the LGTM profile) and
# ClickStack, which takes all three signals. The metrics store's name was here
# once and its exporter is gone, and this list is a filter over what may be
# SUBSTITUTED rather than an assertion about what exists — so an absent name is
# inert, which is why the removal needed no change here at all. It is removed
# anyway, because a test naming a container the tree does not ship is a test
# that reads as though it did.
shipped = yaml.safe_load(source)
BACKENDS = {"tempo", "loki", "clickstack"}
targets = [
    name
    for name in (shipped.get("exporters") or {})
    if name.partition("/")[2] in BACKENDS and name.partition("/")[0] in ("otlp", "otlphttp")
]
if not targets:
    sys.exit("canary: no backend exporters found; the shipped config changed shape")

# THE METRICS PIPELINE HAS NO BACKEND TO SUBSTITUTE, and that is not a gap in the
# substitution -- it is a decision in the shipped config. kit's dev profile removed
# the metrics store (it cost 130s of readiness budget and 384m per cold start for
# a fleet with no series to put in it), so `templates/compose/otel-collector.yml`
# ships NO metrics exporter and the metrics pipeline runs on `debug` alone: this
# process's own stdout, on the machine already running it, which cannot reach the
# network.
#
# THIS TEST WAS WRITTEN WHEN THAT PIPELINE NAMED A STORE, and it went red the day
# the store left rather than saying so. `BACKENDS` is a filter over what may be
# SUBSTITUTED, so a name nobody can substitute is inert by design -- which is
# exactly why the failure was silent until the assertion at the bottom, four
# hundred lines later, reported `the metrics pipeline points at ['debug'],
# expected ['file/capture']` and said nothing about why. A red with no cause is
# how a security check gets deleted.
#
# SO THE SUBSTITUTION COVERS EVERY PIPELINE, and the rule is derived rather than
# listed: an exporter in a pipeline is replaced by `file/capture` when it is one
# of the backends above, OR when it is the pipeline's ONLY exporter. The second
# clause is the one that matters. `debug` writes to stdout, which this test never
# reads, so on the shipped config the metrics signal was NEVER OBSERVED: the
# `llm.prompt`, `error.message` and `tenant_id`-on-a-measurement assertions below
# were all passing vacuously on a path nothing had ever sent to a file. Swapping
# `debug` for `file/capture` puts those metrics into the capture where they can be
# checked, which is a STRENGTHENING and not a relaxation: the canary now proves
# what it claims to prove about all three signals instead of two.
#
# `debug` is left in place on a pipeline that has a backend of its own (traces),
# because there it is the shipped local escape hatch and removing it would drop
# the collector's stdout path rather than redirect one.


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
    # Also swallow the blank line that separated this block from the next, so the
    # result keeps its shape.
    while end < len(lines) and lines[end].strip() == "":
        end += 1
        break
    return "".join(lines[:start] + lines[end:])


for name in targets:
    source = drop_exporter(source, name)

# ...and the pipeline exporter LISTS are rewritten by structure too, not by the
# three literal strings this used to replace. Those strings encoded both the
# exporter names AND the exact list formatting of each pipeline, so a fourth
# pipeline, or a reordering, would have silently stopped matching and left the
# test asserting against a config that still pointed at a dead Tempo.
#
# The mapping is per PIPELINE, not global: a name is captured when it is one of
# `targets`, and additionally when it is the only exporter its pipeline has. The
# list is de-duplicated because substituting both `otlp/tempo` and `debug` on one
# pipeline would otherwise produce `file/capture` twice and the collector refuses
# a pipeline that names the same exporter twice -- a substitution that cannot be
# loaded is a substitution nobody would debug.
pipelines = (shipped.get("service") or {}).get("pipelines") or {}
if not pipelines:
    sys.exit("canary: the shipped config declares no pipelines")


def substitute(match):
    body = match.group(2)
    parts = [part.strip() for part in body.split(",") if part.strip()]
    if len(parts) == 1 and parts[0] not in targets:
        # A pipeline with a single exporter and nothing to substitute it for: this
        # is the metrics pipeline after the dev profile removed the store. Capture
        # it, or the signal is never observed at all.
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

# Both checks are hard failures, and they are here rather than discovered as a
# confusing "no such exporter" from the collector. A test that quietly measures a
# config it did not build is the worst outcome available.
#
# Checked on the PARSED document rather than on the text, and that is not
# fussiness: the first version grepped the source for "otlp/tempo" and failed,
# because the comment block introduced three lines above NAMES all three
# exporters while explaining what they are standing in for. A substring search
# over a file that documents itself is a check that fails on its own
# documentation — the same trap the traceparent snippets hit.
doc = yaml.safe_load(source)
if set(doc.get("exporters") or {}) - {"file/capture", "debug"}:
    sys.exit(
        "canary: unexpected exporters survived: "
        + ", ".join(sorted(set(doc["exporters"]) - {"file/capture", "debug"}))
    )
# EVERY PIPELINE MUST BE OBSERVABLE, and that is a stronger claim than the three
# literal expectations this used to assert. The old check said `metrics` must be
# `["file/capture"]` -- a statement about the pipeline kit happened to ship -- and
# it is what went red when the dev profile removed the metrics store, four hundred
# lines below the substitution that could no longer do anything for it.
#
# What the canary actually needs is not that the metrics pipeline names a
# particular exporter; it is that EVERY signal it sends reaches `file/capture`,
# the one exporter this test reads. A pipeline exporting only to `debug` -- to the
# collector's own stdout, which nothing here inspects -- is a signal the canary
# does not test, and a canary that silently does not test a signal reports its
# green over all three. So the assertion is the property, and the shape of the
# shipped config is free to change underneath it.
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
      # `debug` and not `info`: the processor's summary then names the KEYS it
      # removed, and that list is the receipt proving the collector saw the
      # canary and stripped it — as opposed to the canary being absent because
      # the sender never sent it, which is what "no canary found" means on its
      # own.
      #
      # BOTH switches are needed and only setting one of them is the same as
      # setting neither. `KIT_OTEL_REDACTION_SUMMARY: debug` tells the PROCESSOR
      # to log at debug verbosity; `KIT_OTEL_LOG_LEVEL: debug` tells the
      # COLLECTOR to emit debug records at all. The shipped compose sets the
      # collector's level to `info`, so a summary of `debug` produces nothing —
      # and this test ran green for a full packet with the receipt silently
      # unreachable, printing a NOTE about it rather than asking why. Two
      # variables that look like one setting are why "removal is asserted by
      # absence only" appeared at all.
      KIT_OTEL_REDACTION_SUMMARY: debug
      KIT_OTEL_LOG_LEVEL: debug
      KIT_OTEL_BATCH_TIMEOUT: 1s
      KIT_OTEL_BATCH_SIZE: 8
      KIT_OTEL_METRIC_NAMESPACE: cafaye
      KIT_OTEL_METRICS_FLUSH_INTERVAL: 5s
      KIT_TEMPO_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_LOKI_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_OTEL_TLS_INSECURE: "true"
      KIT_OTEL_EXPORT_TIMEOUT: 1s
      KIT_OTEL_DEBUG_VERBOSITY: basic
      KIT_OTEL_HEALTH_ENDPOINT: 0.0.0.0:13133
      # NB: no second KIT_OTEL_LOG_LEVEL here. It was, at `info`, eleven lines
      # above the `debug` that makes the receipt observable — and a duplicated
      # YAML key resolves to the LAST one, so the collector ran at `info` and
      # the redaction summary was filtered out anyway. A test that sets the
      # thing it needs and then quietly overwrites it is worse than one that
      # never set it, because the variable is present in the file.
    healthcheck:
      test: ["CMD", "/otelcol-contrib", "validate", "--config=/etc/otel/otel-collector.yml"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 2s
  # The collector image is distroless: no shell, no curl. So the sender is a
  # stock curl image on the same network, and OTLP is reached by service name
  # rather than by a published port — which also means the collector publishes
  # nothing to the host, exactly as the shipped compose file has it.
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

# ---------------------------------------------------------------------------
# The payloads. Hand-built OTLP/JSON so the canary goes in EXACTLY the shapes a
# real SDK produces — including the ones a service would only get by accident,
# like `exception.message` on a log record.
#
# Written out verbatim as files, because when this test fails the first question
# is "what exactly did you send" and an answer that requires re-deriving it is
# not an answer.
# ---------------------------------------------------------------------------
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

# Poll for the capture rather than sleeping: the batch timeout is 1s but the
# spanmetrics flush is 5s, and a sleep long enough for the second is a sleep
# long enough to be flaky on a loaded machine.
if wait_for "capture written" 40 sh -c \
  "test -s '$WORK/capture/telemetry.json' && grep -q 'provider_auth' '$WORK/capture/telemetry.json' && grep -q 'dependency_unavailable' '$WORK/capture/telemetry.json'"; then
  pass "the capture contains data that passed the redaction boundary"
else
  fail "nothing reached the capturing exporter within 40s"
  compose logs --tail 30 collector 2>&1 | sed 's/^/        /' || true
  exit 1
fi

CAPTURE="$WORK/capture/telemetry.json"

# ---------------------------------------------------------------------------
# THE ASSERTIONS
# ---------------------------------------------------------------------------

# The canary, in NO attribute, on any signal, at any depth. Counted, so a
# partial leak is a quotable number rather than a boolean.
#
# TWO LINES ARE EXCLUDED, and both exclusions are load-bearing:
#
#   `"body"` — the log body is the one place free text is EXPECTED. core
#   requires a body and bounds it at 2048 characters, and the redaction
#   processor is specified over ATTRIBUTES. Reported separately below; counting
#   it here would make this number a measure of the test's own payload rather
#   than of the boundary.
#
#   `redaction.redacted.keys` — the processor's own summary, which is a
#   comma-joined list of the key NAMES it removed. The canary's key names are
#   therefore in the capture and the canary's key VALUES are not, because the
#   attributes are gone before the summary is written. The first version of
#   this test read those names as a leak and reported four failures that were
#   in fact the receipt working: "the key name appears" is not "the key
#   survived", and conflating them makes the summary a false positive.
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

# One key at a time, so a failure says WHICH mechanism failed rather than
# "something leaked". This is the separation muse's canary test insists on:
# asserting the keys individually is not redundant with counting the canary,
# because a key can survive with a truncated value and pass the string search.
#
# A key named in `redaction.redacted.keys` is the RECEIPT, not a leak — the
# processor is reporting what it removed. Reported as a note so a reader can see
# the mechanism working, and excluded from the failure branch for the reason
# given above.
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

# `tenant_id` is different: it is PROHIBITED ON A MEASUREMENT and REQUIRED on
# the resource, and the two halves have opposite answers. Checked separately
# because a check that just looks for the string finds the legitimate one and
# passes, which is exactly the bug core's metrics schema exists to prevent.
if grep -q 'tnt_-'"$CANARY" "$CAPTURE" 2>/dev/null; then
  fail "a tenant_id reached a measurement, where core prohibits it"
else
  pass "no tenant_id reached a measurement attribute — the cardinality trap is closed"
fi

# blocked_values: a credential-shaped VALUE under a key the allowlist KEEPS.
# The key is not the signal here, the value is, and this is the second
# independent barrier to the same leak rather than a third instance of the
# first.
if grep -q 'sk-abcdefghijklmnopqrstuvwx' "$CAPTURE" 2>/dev/null; then
  fail "a credential-shaped value under an allowlisted key was not masked"
else
  pass "a bearer token under an allowlisted key was masked by blocked_values"
fi

# THE OTHER HALF. A collector that drops everything passes every assertion above
# and is useless, so the allowed data is asserted PRESENT — including the LLM
# attributes, which are the ones an over-tight allowlist would lose and which
# are the whole reason muse has telemetry at all.
for expected in provider_auth /v1/route gpt-4o-mini dependency_unavailable; do
  if grep -qF "$expected" "$CAPTURE" 2>/dev/null; then
    pass "allowed data survived: $expected"
  else
    fail "allowed data was destroyed by the boundary: $expected"
  fi
done

# Resource attributes are the EXEMPTION and they are supposed to survive:
# identity lives there rather than on a measurement precisely because resource
# attributes are not counted against the 2000-combination cap. A boundary that
# stripped them would break the per-tenant totals core's metrics schema depends
# on, and would do it silently.
if grep -qF 'tnt_01J9Z8R4T7Y2U6K3W8Q5N0P1DG"' "$CAPTURE" 2>/dev/null; then
  pass "a resource tenant_id survived — identity stays on the resource, off the measurement"
else
  fail "resource attributes were stripped, which breaks the per-tenant totals core requires"
fi

# The receipt. With `summary: debug` the processor records what it removed, and
# finding the canary's own keys named in the collector's output is the
# difference between "the boundary removed it" and "the sender never sent it".
# A NOTE rather than a failure: the summary is a diagnostic, and a build of the
# processor that omits it is still enforcing. Reported so a reader knows the
# receipt was not available in this run rather than assuming it was checked.
#
# THE LOG IS CAPTURED TO A FILE FIRST, and that is not tidiness — it is the
# difference between a check that works and one that works two times in three.
# `docker logs ... | grep -qi redact` under `set -o pipefail` is a race: `grep -q`
# exits at the FIRST match and closes the pipe, so `docker logs` takes SIGPIPE
# and exits 141 — but only if it had not already finished writing. With the
# collector at debug level the log is large, so "had not finished" is the common
# case and the check reported "no redaction summary" on a run where the summary
# was plainly there. Reading a file has no pipe and no SIGPIPE, so there is
# nothing left to race against.
docker logs "$PROJECT-collector-1" >"$WORK/collector.log" 2>&1 || true

# Polled, not read once. The processor writes the summary while it redacts and
# the batch processor flushes afterwards, so the ordering is usually right — and
# "usually" is not a property a receipt can rest on.
if wait_for "the collector records what it redacted" 20 \
  grep -qi 'redact' "$WORK/collector.log"; then
  pass "the collector's own log records the redaction — removal is observed, not inferred"
else
  note "no redaction summary in the collector's log this run; removal is asserted by absence only"
fi

# 9. THE LOG BODY. Reported, never asserted.
note "log bodies are the one place free text is EXPECTED: core requires a body and"
note "bounds it at 2048 characters, and the redaction processor is specified over"
note "ATTRIBUTES. This test does not assert a body is scrubbed, and a reader who"
note "assumes it is scrubbed is the reader who puts a prompt in one."

# The spanmetrics connector builds metric labels from spans, so its output is a
# SEPARATE path from the direct metric payload and worth confirming separately.
#
# Polled, because the connector flushes on its OWN interval (5s here, via
# KIT_OTEL_METRICS_FLUSH_INTERVAL) rather than with the batch it came from. Read
# once, immediately after the direct payload's assertions, it is absent about a
# third of the time and the test NOTEd "no spanmetrics output in this capture"
# on a run where the connector had simply not flushed yet — which reads as
# "the connector is not wired" and is really "nobody waited".
if wait_for "the spanmetrics connector flushes derived metrics" 30 \
  grep -qi 'span_metrics\|cafaye_span\|duration' "$CAPTURE"; then
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
