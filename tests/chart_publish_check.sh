#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: bash tests/chart_publish_check.sh <workflow> <applications-dir>" >&2
  exit 2
fi
workflow="$1"
apps_dir="$2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PY=""
if [ -x "$ROOT/.venv/bin/python" ] && "$ROOT/.venv/bin/python" -c "import yaml" 2>/dev/null; then
  PY="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  PY="python3"
fi
if [ -z "$PY" ]; then
  echo "chart publish: cannot measure — no YAML-capable python (gate .venv and system PyYAML both absent)" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-chart-publish.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checker="$TMP/chart-publish-check.py"
cat >"$checker" <<'PY'
import glob
import re
import sys

import yaml

workflow_path, apps_dir = sys.argv[1], sys.argv[2]
problems = []

try:
    with open(workflow_path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:
    sys.exit(f"{workflow_path} does not parse: {exc}")
if not isinstance(doc, dict):
    sys.exit(f"{workflow_path} is not a mapping")
on = doc.get("on") or doc.get(True)
inputs = {}
if isinstance(on, dict):
    inputs = ((on.get("workflow_call") or {}).get("inputs")) or {}
if not inputs and not (isinstance(on, dict) and "workflow_call" in on):
    problems.append("not a workflow_call reusable workflow")

push = inputs.get("push")
if not isinstance(push, dict):
    problems.append("no `push` input")
elif push.get("default") is not False:
    problems.append(f"`push` default is {push.get('default')!r}, not false")

SERVICE_APPS = {"identity", "gateway", "courier", "parlor"}
registry = inputs.get("registry")
default_registry = registry.get("default") if isinstance(registry, dict) else None
if not isinstance(default_registry, str) or not default_registry:
    problems.append(
        "chart.reusable.yml declares no default `registry` — the pull end "
        "has no prefix to be built from"
    )
apps = sorted(glob.glob(apps_dir + "/*.yaml")) + sorted(glob.glob(apps_dir + "/*.yml"))
if not apps:
    problems.append(f"no Application manifests found in {apps_dir}")
checked = 0
for app in apps:
    try:
        with open(app, encoding="utf-8") as fh:
            adoc = yaml.safe_load(fh)
    except Exception as exc:
        problems.append(f"{app} does not parse: {exc}")
        continue
    source = (adoc.get("spec") or {}).get("source") or {}
    repo = source.get("repoURL")
    chart = source.get("chart")
    name = ((adoc.get("metadata") or {}).get("name"))
    if name not in SERVICE_APPS:
        continue
    checked += 1
    want = f"{default_registry}/{chart}" if isinstance(chart, str) and chart else None
    if repo != want:
        problems.append(
            f"{app}: source.repoURL is {repo!r} but the workflow's default "
            f"registry {default_registry!r} plus this Application's chart name "
            f"{chart!r} is {want!r} — Argo resolves an OCI source's revision "
            f"against repoURL itself, so a repoURL that is not the chart's own "
            f"path in the registry finds no artifact and the Application never "
            f"syncs (the publish/consume seam)"
        )

for banned in ("chart-name", "chart-version"):
    if banned in inputs:
        problems.append(
            f"`{banned}` is an input — the chart's name and version must be "
            f"read from Chart.yaml, never copied into a service repo"
        )

with open(workflow_path, encoding="utf-8") as fh:
    code = "\n".join(
        line for line in fh.read().splitlines() if not line.lstrip().startswith("#")
    )
if not re.search(r"github\.event_name\s*==\s*'pull_request'", code):
    problems.append("no pull_request refusal (github.event_name == 'pull_request')")

if problems:
    for problem in problems:
        print(f"chart publish: {problem}")
    sys.exit(1)
print(f"seam: default registry + chart == source.repoURL in {checked} service Application(s)")
PY

out=""
ec=0
out="$("$PY" "$checker" "$workflow" "$apps_dir" 2>&1)" || ec=$?
if [ "$ec" -ne 0 ]; then
  printf '%s\n' "$out"
  exit 1
fi


mutate_gateway() {
  local dir="$1" expr="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$apps_dir"/*.yaml "$dir"/
  sed "$expr" "$dir/gateway.yaml" >"$dir/gateway.yaml.mutated"
  mv "$dir/gateway.yaml.mutated" "$dir/gateway.yaml"
}

root_fixture="$TMP/chart-publish-root"
mutate_gateway "$root_fixture" \
  's|^\( *\)repoURL: oci://ghcr.io/anywaye/charts/gateway$|\1repoURL: oci://ghcr.io/anywaye/charts|'
if "$PY" "$checker" "$workflow" "$root_fixture" >/dev/null 2>&1; then
  printf 'chart publish: control (a) the registry-root control did not go red — a repoURL that is the registry root is not being caught\n'
  exit 1
fi

disagree_fixture="$TMP/chart-publish-disagree"
mutate_gateway "$disagree_fixture" \
  's|^\( *\)repoURL: oci://ghcr.io/anywaye/charts/gateway$|\1repoURL: oci://ghcr.io/anywaye/charts/gateway-drifted|'
if "$PY" "$checker" "$workflow" "$disagree_fixture" >/dev/null 2>&1; then
  printf 'chart publish: control (b) the path/name control did not go red — a repoURL path that disagrees with `chart:` is not being caught\n'
  exit 1
fi

drift_fixture="$TMP/chart-publish-drift"
mutate_gateway "$drift_fixture" \
  's|oci://ghcr.io/anywaye/charts/gateway|oci://ghcr.io/anywaye/charts-drifted/gateway|'
if "$PY" "$checker" "$workflow" "$drift_fixture" >/dev/null 2>&1; then
  printf 'chart publish: control (c) the drifted-registry control did not go red — the registry comparison is not measuring what it claims\n'
  exit 1
fi

push_fixture="$TMP/chart-publish-push-default.yml"
sed 's/default: false/default: true/' "$workflow" >"$push_fixture"
if "$PY" "$checker" "$push_fixture" "$apps_dir" >/dev/null 2>&1; then
  printf 'chart publish: control (d) the push-default control did not go red — the default comparison is not measuring what it claims\n'
  exit 1
fi

printf '%s\n' "$out"
printf 'chart publish: four red controls went red (repoURL at the registry root; repoURL path disagreeing with `chart:`; drifted registry prefix; push default true)\n'
exit 0
