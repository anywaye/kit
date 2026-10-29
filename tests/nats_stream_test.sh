#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/templates/compose/docker-compose.yml"
EXAMPLE="$ROOT/templates/compose/.env.example"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "nats_stream_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-nats-stream-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passes=0
failures=0

pass() {
  printf '      PASS nats_stream_test: %s\n' "$1"
  passes=$((passes + 1))
}

fail() {
  printf '      FAIL nats_stream_test: %s\n' "$1"
  printf '%s\n' "$2" | head -12 | sed 's/^/             /'
  failures=$((failures + 1))
}

run() {
  local name="$1" want="$2" out ec=0
  shift 2
  out=$("$@" 2>&1) || ec=$?
  case "$want:$ec" in
    red:0)
      fail "$name" "$out"
      ;;
    red:*)
      pass "$name"
      ;;
    green:0)
      pass "$name"
      ;;
    green:*)
      fail "$name" "$out"
      ;;
  esac
}

printf -- '-- nats_stream_test: the stream the fleet publishes to\n'

check_stream() {
  "$PY" - "$1" "$2" <<'PY'
import re
import sys

import yaml

compose_path, example_path = sys.argv[1], sys.argv[2]

REQUIRED_PREFIXES = ("identity.>", "billing.>", "courier.>", "muse.>", "darkroom.>")

problems = []

try:
    with open(compose_path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except yaml.YAMLError as e:
    print(f"docker-compose.yml does not parse as YAML: {e}")
    sys.exit(1)

services = (doc or {}).get("services") or {}
svc = services.get("nats-stream-init")
if svc is None:
    print("no nats-stream-init service — the bus has no stream, and every publish "
          "to a subject no stream claims goes silent")
    sys.exit(1)

image = str(svc.get("image") or "")
if "natsio/nats-box" not in image:
    problems.append(f"image is {image!r}, not natsio/nats-box — the stream init runs "
                    f"the NATS CLI, and a different image is a different CLI")
tag = image.rsplit(":", 1)[-1] if ":" in image.rsplit("/", 1)[-1] else ""
if tag in ("", "latest"):
    problems.append(f"image is unpinned ({image})")

depends = svc.get("depends_on") or {}
if isinstance(depends, list):
    depends = {str(d): {} for d in depends}
if "nats" not in depends:
    problems.append("does not depend on nats — the init would race the broker on a "
                    "cold start and fail before JetStream is up")
elif str((depends.get("nats") or {}).get("condition")) != "service_healthy":
    problems.append("depends_on nats without condition: service_healthy")

command = svc.get("command")
text = " ".join(str(part) for part in command) if isinstance(command, list) else str(command or "")

m = re.search(r'--subjects\s+"([^"]*)"', text)
subjects = m.group(1) if m else None
if subjects is None:
    problems.append("command sets no --subjects — the stream claims nothing and every "
                    "publish goes silent")
else:
    if subjects.strip() == ">":
        problems.append('subjects is a bare ">" — it would claim $JS.> and $SYS.> '
                        "system traffic, and the coverage would not be auditable in "
                        "one line")
    for prefix in REQUIRED_PREFIXES:
        if prefix not in subjects:
            problems.append(f"command does not cover {prefix} — that service's events "
                            f"would never leave its outbox table")

if "stream info" not in text or "||" not in text:
    problems.append("not idempotent by construction — a plain `nats stream add` exits 1 "
                    "on the second run ('stream name already in use with a different "
                    "configuration (10058)'), so every second `bin/dev up` would be red")
if "--defaults" not in text:
    problems.append("no --defaults — the CLI asks for confirmation and, with no "
                    "terminal in a container, exits 1")

m_storage = re.search(r"--storage\s+(\S+)", text)
if not m_storage or m_storage.group(1) != "file":
    problems.append("storage is not file — memory storage loses every event on a "
                    "restart, which is the regression the -js flag exists to prevent")
m_retention = re.search(r"--retention\s+(\S+)", text)
if not m_retention or m_retention.group(1) != "limits":
    problems.append("retention is not limits — interest retention grows without "
                    "bound and no dev stack needs it")

example = open(example_path, encoding="utf-8").read()
m2 = re.search(r"^KIT_NATS_BOX_TAG=(.*)$", example, re.M)
example_tag = m2.group(1).strip() if m2 else None
compose_tag = None
m3 = re.search(r"\$\{KIT_NATS_BOX_TAG:-([^}]*)\}", image)
if m3:
    compose_tag = m3.group(1)
if not example_tag:
    problems.append(".env.example does not set KIT_NATS_BOX_TAG — bin/dev copies it "
                    "to .env, where an unset tag means the compose default silently wins")
elif compose_tag and example_tag != compose_tag:
    problems.append(f"the nats-box tag disagrees: docker-compose.yml defaults to "
                    f"{compose_tag!r} and .env.example sets {example_tag!r}")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("nats-stream-init: pinned, waits for a healthy nats, covers "
      "identity/billing/courier/muse/darkroom, check-then-create idempotent, "
      "file storage with limits retention, tags agree")
PY
}

run 'nats-stream-init exists, is pinned, waits for a healthy nats, covers the fleet, is idempotent' \
  green check_stream "$COMPOSE" "$EXAMPLE"


fixture_latest="$WORK/latest.yml"
sed 's/\${KIT_NATS_BOX_TAG:-0\.20\.0}/latest/' "$COMPOSE" >"$fixture_latest"
run 'control: a latest pin goes red' red check_stream "$fixture_latest" "$EXAMPLE"

fixture_nodep="$WORK/nodep.yml"
sed '/^    depends_on:$/,+2d' "$COMPOSE" >"$fixture_nodep"
run 'control: a missing depends_on goes red' red check_stream "$fixture_nodep" "$EXAMPLE"

fixture_noidentity="$WORK/noidentity.yml"
sed 's/identity\.>,//' "$COMPOSE" >"$fixture_noidentity"
run 'control: a dropped identity.> goes red' red check_stream "$fixture_noidentity" "$EXAMPLE"

fixture_bare="$WORK/bare.yml"
sed 's/identity\.>,billing\.>,courier\.>,muse\.>,darkroom\.>/ >/' "$COMPOSE" >"$fixture_bare"
run 'control: a bare > subject goes red' red check_stream "$fixture_bare" "$EXAMPLE"

fixture_plainadd="$WORK/plainadd.yml"
sed 's#nats stream info anywaye >/dev/null 2>&1 || nats stream add#nats stream add#' \
  "$COMPOSE" >"$fixture_plainadd"
run 'control: a plain stream add (no check-then-create) goes red' \
  red check_stream "$fixture_plainadd" "$EXAMPLE"

fixture_memory="$WORK/memory.yml"
sed 's/--storage file/--storage memory/' "$COMPOSE" >"$fixture_memory"
run 'control: memory storage goes red' red check_stream "$fixture_memory" "$EXAMPLE"

fixture_tagdisagree="$WORK/tagdisagree.env"
sed 's/^KIT_NATS_BOX_TAG=0\.20\.0$/KIT_NATS_BOX_TAG=0.19.7/' "$EXAMPLE" >"$fixture_tagdisagree"
run 'control: a tag disagreement goes red' red check_stream "$COMPOSE" "$fixture_tagdisagree"

printf -- '-- nats_stream_test: %d passed, %d failed\n' "$passes" "$failures"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: %d passed, %d failed\n' "$passes" "$failures"
