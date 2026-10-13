#!/usr/bin/env bash
#
# chart_publish_check.sh — the chart publish proof, standalone.
#
#   bash tests/chart_publish_check.sh <workflow> <applications-dir>
#
# WHAT IT PROVES. The publish/consume seam, both ends in kit: the workflow's
# default registry is the PREFIX every SERVICE Application's source.repoURL is
# built from — `repoURL == registry + "/" + chart` — `push` defaults to false,
# the chart name/version are not inputs, and the pull_request refusal is
# present. Plus its RED CONTROLS under the same assertions: a fixture whose
# repoURL is the registry root (the shape that never synced — measured:
# `HEAD https://ghcr.io/v2/cafaye/charts/manifests/0.1.0` → 403, because Argo
# resolves an OCI revision against repoURL itself and the registry root is not
# an artifact), a fixture whose repoURL path disagrees with `chart:`, a
# fixture whose registry prefix drifted, and a fixture with `push`'s default
# flipped to true — each must go red, or the proof fails itself.
#
# SINGLE SOURCE OF TRUTH. The assertions below are the gate's chart-publish
# assertions, not a second implementation: tests/validate.sh's
# check_chart_publish() calls this file, and tests/focused_publish.sh calls
# it directly. One copy of the proof; two callers. A second implementation
# here would be one assertion that can drift.
#
# WHAT IT NEVER DOES. It never invokes tests/validate.sh — neither the full
# gate nor `--only`. The re-entrancy this packet removes lived INSIDE the
# gate itself: `have()` resolves its probe runner through `_timeout_bin()`,
# so `_timeout_bin()` calling `have()` back nested one forked gate child
# per `$( )` level (a 624-deep validate.sh tree from one focused run).
# This file proves the seam without entering that tree at all.
#
# Exit 0: the real tree passes and both controls go red.
# Exit 1: an assertion fails, or a control stays green (a failure of the
# proof itself, not a pass over a blind check).
# Exit 2: usage error, or no YAML-capable python — the seam cannot be
# measured without a parser, and that is reported, never passed silently.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: bash tests/chart_publish_check.sh <workflow> <applications-dir>" >&2
  exit 2
fi
workflow="$1"
apps_dir="$2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The gate's venv python when present, else a system python3 with PyYAML.
# No parser is an explicit exit 2, never a silent pass.
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

# The assertions live in ONE python program, written to a temp file so the
# real run and both controls run the SAME code: two copies of an assertion
# is one assertion that can drift, and a control that re-measures with a
# second implementation is a control that can disagree with the check.
checker="$TMP/chart-publish-check.py"
cat >"$checker" <<'PY'
import glob
import re
import sys

import yaml

workflow_path, apps_dir = sys.argv[1], sys.argv[2]
problems = []

# 1. Exists, parses, and is a workflow_call. PyYAML parses the bare `on:`
# key as boolean True (YAML 1.1), so both spellings are read.
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

# 2. `push` defaults to false.
push = inputs.get("push")
if not isinstance(push, dict):
    problems.append("no `push` input")
elif push.get("default") is not False:
    problems.append(f"`push` default is {push.get('default')!r}, not false")

# 3. The default registry is the PREFIX of every SERVICE Application's
# source.repoURL: repoURL == registry + "/" + chart. Argo resolves an OCI
# source's revision against repoURL ITSELF — the artifact it HEADs is
# <repoURL>:<targetRevision> — so a repoURL that is the registry root asks for
# an artifact named after nothing. Measured on the fleet's first end-to-end
# install: `HEAD https://ghcr.io/v2/cafaye/charts/manifests/0.1.0` → 403 and
# every Application stuck un-synced, because the published packages are
# `cafaye/charts/<name>` and the root is not an artifact. The push appends the
# chart name (`helm push "$PACKAGE" "$REGISTRY"`), so the pull must name it too.
# Observability Applications (alloy, grafana, loki, prometheus) point at
# upstream chart repositories by design and are skipped here — asserting them
# here as well would pin them to a registry nothing publishes them to, which
# is the defect w102 exists to remove. They are asserted in full by the
# obs-chart-sources checker, which names the same four by filename.
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

# 4. The name and version are not inputs.
for banned in ("chart-name", "chart-version"):
    if banned in inputs:
        problems.append(
            f"`{banned}` is an input — the chart's name and version must be "
            f"read from Chart.yaml, never copied into a service repo"
        )

# 5. The pull_request refusal is present. Comments are stripped BEFORE the
# grep: a check that a comment can satisfy is not a check, and this
# workflow's own header explains the refusal in prose.
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

# The `|| ec=$?` shape is load-bearing rather than defensive: a bare
# `out="$(cmd)"` that fails takes the shell down under `set -e` before the
# status is ever read, so a check that correctly REJECTS a broken tree
# would take this script with it. The guard makes the assignment part of a
# list, which `set -e` does not apply to.
out=""
ec=0
out="$("$PY" "$checker" "$workflow" "$apps_dir" 2>&1)" || ec=$?
if [ "$ec" -ne 0 ]; then
  printf '%s\n' "$out"
  exit 1
fi

# THE CONTROLS. Each builds a fixture that violates exactly one property
# and requires the same assertions to answer RED. A control that stays
# green means the check is not measuring what it claims, and that is
# reported as a failure of the proof itself rather than passed over.

# A temp file and `mv`, not `sed -i`: BSD sed (macOS) requires a backup
# argument after `-i` and GNU sed does not, so the in-place spelling is
# one platform's bug and the other's no-op.
mutate_gateway() {
  # Rewrite one line of the gateway Application in a fresh fixture dir,
  # everything else byte-identical: one fixture, one mutation.
  local dir="$1" expr="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$apps_dir"/*.yaml "$dir"/
  sed "$expr" "$dir/gateway.yaml" >"$dir/gateway.yaml.mutated"
  mv "$dir/gateway.yaml.mutated" "$dir/gateway.yaml"
}

# (a) THE ROOT CONTROL: one service Application's repoURL set back to the
# registry ROOT — today's shape, and the one that never synced. Argo resolves
# the revision against repoURL itself, the root is not an artifact, and every
# sync 403s: this is precisely the defect the check exists to catch.
root_fixture="$TMP/chart-publish-root"
mutate_gateway "$root_fixture" \
  's|^\( *\)repoURL: oci://ghcr.io/cafaye/charts/gateway$|\1repoURL: oci://ghcr.io/cafaye/charts|'
if "$PY" "$checker" "$workflow" "$root_fixture" >/dev/null 2>&1; then
  printf 'chart publish: control (a) the registry-root control did not go red — a repoURL that is the registry root is not being caught\n'
  exit 1
fi

# (b) THE PATH/NAME CONTROL: the chart name in the repoURL path disagrees
# with the manifest's own `chart:`. The two are one fact; the fixture changes
# one and leaves the other, so exactly one property is violated.
disagree_fixture="$TMP/chart-publish-disagree"
mutate_gateway "$disagree_fixture" \
  's|^\( *\)repoURL: oci://ghcr.io/cafaye/charts/gateway$|\1repoURL: oci://ghcr.io/cafaye/charts/gateway-drifted|'
if "$PY" "$checker" "$workflow" "$disagree_fixture" >/dev/null 2>&1; then
  printf 'chart publish: control (b) the path/name control did not go red — a repoURL path that disagrees with `chart:` is not being caught\n'
  exit 1
fi

# (c) THE DRIFTED-REGISTRY CONTROL: the old seam fixture, the workflow's
# prefix moved out from under every repoURL. It is kept BESIDE (a) rather than
# folded into it: (a) removes the chart segment and (c) moves the registry, and
# a check that can catch one but not the other is a check with a blind side.
drift_fixture="$TMP/chart-publish-drift"
mutate_gateway "$drift_fixture" \
  's|oci://ghcr.io/cafaye/charts/gateway|oci://ghcr.io/cafaye/charts-drifted/gateway|'
if "$PY" "$checker" "$workflow" "$drift_fixture" >/dev/null 2>&1; then
  printf 'chart publish: control (c) the drifted-registry control did not go red — the registry comparison is not measuring what it claims\n'
  exit 1
fi

# (d) THE DEFAULT CONTROL: `push` flipped to default-true. A reusable
# workflow that publishes by default is one every caller publishes from
# by accident, so the fixture is the one-line flip.
push_fixture="$TMP/chart-publish-push-default.yml"
sed 's/default: false/default: true/' "$workflow" >"$push_fixture"
if "$PY" "$checker" "$push_fixture" "$apps_dir" >/dev/null 2>&1; then
  printf 'chart publish: control (d) the push-default control did not go red — the default comparison is not measuring what it claims\n'
  exit 1
fi

# The proof, on the way out: the seam the check measured, so a green run
# prints the number of Applications the registry+chart string was compared
# against rather than asserting it in a comment.
printf '%s\n' "$out"
printf 'chart publish: four red controls went red (repoURL at the registry root; repoURL path disagreeing with `chart:`; drifted registry prefix; push default true)\n'
exit 0
