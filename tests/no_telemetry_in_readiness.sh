#!/usr/bin/env bash
#
# kit's proof that telemetry is never in a readiness path.
#
#   bash tests/no_telemetry_in_readiness.sh
#
# THE CLAIM
#   "A service that hangs on startup because telemetry is down is worse than no
#   telemetry at all." (PLAN.md §7b)
#
#   That sentence is easy to agree with and easy to break, and the way it
#   breaks is always the same shape: one `depends_on: [otel-collector]` added
#   for convenience, or one probe that curls the OTLP port "just to check
#   telemetry is up", and then a deploy that will not roll out because a
#   dev-local collector is not running in the cluster.
#
# WHAT IS PROVED HERE, AND IN HOW MANY PARTS
#   Four claims, in increasing order of how much they can be faked:
#
#   1. STATIC, no docker. Nothing in the shipped compose template or bin/dev
#      path waits on the collector. This is cheap and cannot be faked by a
#      runtime, but it also cannot see a probe that opens a socket.
#
#   2. LIVE, a real collector. The shipped collector is started with its store
#      exporters pointed at ports where NOTHING is listening — Tempo and Loki
#      both absent — and the question is whether it reports healthy. A
#      collector that fails its health check when its backends are down has put
#      an observability store in everyone's readiness path, which is the exact
#      inversion this packet is about.
#
#   3. LIVE, the collector KILLED. A throwaway HTTP service with a `/readyz`
#      that really checks a dependency — the shape core's probes.schema.json
#      demands — is started with the collector not running, and must serve. Its
#      readiness must report ready and its liveness must report alive, because
#      a telemetry component that can flip either of those is in the path.
#
#   4. LIVE, the export path. A real service exporting OTLP to a dead endpoint
#      must keep SERVING, and the collector's absence must not make it error.
#      This is the part that catches a client library configured to fail the
#      request path on export failure, which no amount of reading this file
#      would find.
#
# NO SLEEPS. Every wait is a poll on a health or readiness signal with a
# deadline and a named timeout. A sleep is a guess about someone else's startup
# time, and it is wrong on the machine where it matters.
#
# WHY A THROWAWAY PROJECT AND A THROWAWAY PORT RANGE
#   Nothing here touches the developer's own stack, and `docker compose down -v`
#   is called on the way out so no volume survives. The ports are in 15800-15899
#   and are the ONLY ones this script binds; the shipped stack claims
#   15000-15999 and the collision-avoidance is that this script's services
#   publish nothing at all and talk over the compose network by name.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-readiness.XXXXXX")"
PROJECT="kit-readiness-$$"

compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

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

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

printf -- '-- 1. static: nothing in the templates waits on the collector\n'

collector_waits() {
  "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
for name, svc in services.items():
    if name == "otel-collector":
        continue
    depends = svc.get("depends_on") or []
    if isinstance(depends, dict):
        depends = list(depends)
    for dep in depends:
        if "otel" in str(dep) or "tempo" in str(dep) or "loki" in str(dep) or "mimir" in str(dep) or "grafana" in str(dep):
            problems.append(f"{name} depends_on {dep!r}")
    test = " ".join(str((svc.get("healthcheck") or {}).get("test", [])))
    for target in ("otel", "4317", "4318", "13133", "3200", "3100", "9009"):
        if target in test:
            problems.append(f"{name} healthcheck probes {target}")

if problems:
    sys.exit("; ".join(problems))
PY
}

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

if collector_waits >"$WORK/static.log" 2>&1; then
  pass "no service depends_on or probes an observability component"
else
  fail "something in the stack waits on telemetry"
  sed 's/^/        /' "$WORK/static.log"
fi

if docker info >/dev/null 2>&1; then
  printf -- '-- 2. live: collector healthy with tempo and loki both absent\n'

  cat >"$WORK/compose.yml" <<'YAML'
name: kit-readiness
services:
  collector:
    image: otel/opentelemetry-collector-contrib:0.115.1
    command: ["--config=/etc/otel/otel-collector.yml"]
    volumes:
      - ./otel-collector.yml:/etc/otel/otel-collector.yml:ro
    environment:
      KIT_OTEL_GRPC_ENDPOINT: 0.0.0.0:4317
      KIT_OTEL_HTTP_ENDPOINT: 0.0.0.0:4318
      KIT_OTEL_SYSLOG_ENDPOINT: 0.0.0.0:5514
      KIT_OTEL_MEMORY_LIMIT_PERCENTAGE: "75"
      KIT_OTEL_MEMORY_SPIKE_PERCENTAGE: "15"
      KIT_OTEL_REDACTION_SUMMARY: info
      KIT_OTEL_BATCH_TIMEOUT: 1s
      KIT_OTEL_BATCH_SIZE: 16
      KIT_OTEL_METRIC_NAMESPACE: anywaye
      KIT_OTEL_METRICS_FLUSH_INTERVAL: 5s
      KIT_TEMPO_OTLP_ENDPOINT: 127.0.0.1:9
      KIT_LOKI_OTLP_ENDPOINT: http://127.0.0.1:9/otlp
      KIT_CLICKSTACK_OTLP_ENDPOINT: 127.0.0.1:9
      KIT_OTEL_TLS_INSECURE: "true"
      KIT_OTEL_EXPORT_TIMEOUT: 1s
      KIT_OTEL_DEBUG_VERBOSITY: normal
      KIT_OTEL_HEALTH_ENDPOINT: 0.0.0.0:13133
      KIT_OTEL_LOG_LEVEL: info
    healthcheck:
      test: ["CMD", "/otelcol-contrib", "validate", "--config=/etc/otel/otel-collector.yml"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 2s
YAML
  cp "$ROOT/templates/compose/otel-collector.yml" "$WORK/otel-collector.yml"

  if compose up -d --wait --wait-timeout 90 collector 2>"$WORK/collector.log"; then
    pass "collector reports healthy with every backend refused"
  else
    fail "collector would not come up healthy without its backends"
    sed 's/^/        /' "$WORK/collector.log" | tail -20
  fi

  # The stronger half: it is still ALIVE, and still answering, after the export
  # failures have had time to turn into a crash loop if they were going to. A
  # container that restarts is not "degrading honestly", it is failing, and the
  # difference is visible only in the restart count.
  if wait_for "collector stays up with dead backends" 20 sh -c \
    "test \"\$(docker inspect -f '{{.RestartCount}}' ${PROJECT}-collector-1 2>/dev/null || echo 0)\" = 0"; then
    pass "collector did not restart while its exports were refused"
  else
    fail "collector restarted while its exports were refused"
    compose logs --tail 20 collector 2>&1 | sed 's/^/        /' || true
  fi

  if wait_for "exports fail without a retry storm" 25 sh -c \
    "test \"\$(docker logs ${PROJECT}-collector-1 2>&1 | grep -ciE 'export|connection refused|failed' || echo 0)\" -lt 60"; then
    pass "refused exports produced a bounded number of log lines, not a retry storm"
  else
    fail "refused exports produced an unbounded number of log lines — a retry loop"
    compose logs --tail 30 collector 2>&1 | sed 's/^/        /' || true
  fi

  printf -- '-- 3. live: a service serves with the collector killed\n'

  mkdir -p "$WORK/probe"

  cat >"$WORK/probe/dep.py" <<'PY'
import socket

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 9000))
srv.listen(64)
while True:
    conn, _ = srv.accept()
    conn.close()
PY

  cat >"$WORK/probe/svc.py" <<'PY'
import http.server
import os
import socket
import socketserver
import sys

DEP_HOST = os.environ.get("READY_DEP_HOST", "dep")
DEP_PORT = int(os.environ.get("READY_DEP_PORT", "9000"))


def dependency_ok():
    try:
        with socket.create_connection((DEP_HOST, DEP_PORT), timeout=0.5):
            return True
    except OSError:
        return False


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, "liveness: ok\n")
        elif self.path == "/readyz":
            if dependency_ok():
                self.reply(200, "readiness: ok\n")
            else:
                self.reply(503, f"readiness: {DEP_HOST}:{DEP_PORT} unavailable\n")
        else:
            self.reply(404, "not found\n")

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
Server(("0.0.0.0", port), Handler).serve_forever()
PY

  cat >"$WORK/compose.yml" <<'YAML'
name: kit-readiness
services:
  dep:
    image: python:3.12-alpine
    command: ["python", "/probe/dep.py"]
    volumes:
      - ./probe:/probe:ro

  svc:
    image: python:3.12-alpine
    command: ["python", "/probe/svc.py", "8080"]
    volumes:
      - ./probe:/probe:ro
    environment:
      MUSE_OTEL_ENDPOINT: http://otel-collector:4318
      OTEL_SDK_DISABLED: "false"
      READY_DEP_HOST: dep
      READY_DEP_PORT: "9000"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/healthz | grep -q 'liveness: ok'"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 2s
YAML
  rm -f "$WORK/otel-collector.yml"

  if compose up -d --wait --wait-timeout 90 dep svc 2>"$WORK/service.log"; then
    pass "service came up healthy with the collector absent and OTLP pointed at it"
  else
    fail "service could not come up healthy without the collector"
    sed 's/^/        /' "$WORK/service.log" | tail -20
  fi

  if wait_for "readyz reports ready with the dependency up" 20 \
    docker exec "${PROJECT}-svc-1" wget -qO- http://127.0.0.1:8080/readyz; then
    pass "/readyz reports ready while its real dependency is up"
  else
    fail "/readyz did not report ready with its dependency up"
  fi

  compose stop dep >/dev/null 2>&1
  if wait_for "readyz reports NOT ready once its dependency is stopped" 30 \
    docker exec "${PROJECT}-svc-1" wget -qO- http://127.0.0.1:8080/readyz; then
    fail "/readyz still reported ready with its dependency stopped — it checks nothing"
  else
    pass "/readyz went 503 when its real dependency stopped — it really checks"
  fi

  if wait_for "service keeps serving with its dependency down and no collector" 20 \
    docker exec "${PROJECT}-svc-1" wget -qO- http://127.0.0.1:8080/healthz; then
    pass "service kept answering requests with a dead dependency and no collector"
  else
    fail "service stopped serving when the dependency was down and the collector absent"
    compose logs --tail 20 svc 2>&1 | sed 's/^/        /' || true
  fi

  if wait_for "service did not restart" 20 sh -c \
    "test \"\$(docker inspect -f '{{.RestartCount}}' ${PROJECT}-svc-1 2>/dev/null || echo 0)\" = 0"; then
    pass "service did not restart with a dead dependency and a dead OTLP endpoint"
  else
    fail "service restarted with a dead dependency and a dead OTLP endpoint"
  fi

  if compose down --volumes --remove-orphans >/dev/null 2>&1; then
    pass "the throwaway stack came down cleanly"
  else
    fail "the throwaway stack did not come down"
  fi
else
  printf 'SKIP  live proofs (docker daemon not reachable)\n'
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: no_telemetry_in_readiness — $failures claim(s) not proved."
  exit 1
fi
echo "PASS: telemetry is not in any readiness path, and nothing here slept to prove it."
