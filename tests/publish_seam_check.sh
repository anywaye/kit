#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: bash tests/publish_seam_check.sh <workflows-dir> <applications-dir> <fleet-root> <caller-template.yml>" >&2
  exit 2
fi
workflows="$1"
apps_dir="$2"
fleet="$3"
caller_template="$4"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PY=""
if [ -x "$ROOT/.venv/bin/python" ] && "$ROOT/.venv/bin/python" -c "import yaml" 2>/dev/null; then
  PY="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  PY="python3"
fi
if [ -z "$PY" ]; then
  echo "publish seam: cannot measure — no YAML-capable python (gate .venv and system PyYAML both absent)" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-publish-seam.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checker="$TMP/publish-seam-check.py"
cat >"$checker" <<'PY'
import glob
import os
import re
import sys

import yaml

workflows, apps_dir, fleet, caller_template = sys.argv[1:5]

SERVICE_APPS = ("identity", "gateway", "courier", "parlor")

problems = []
notes = []


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def on_block(doc):
    on = doc.get("on") or doc.get(True)
    return on if isinstance(on, dict) else {}


def code_of(path):
    with open(path, encoding="utf-8") as fh:
        return "\n".join(
            line for line in fh.read().splitlines() if not line.lstrip().startswith("#")
        )


def callee_inputs(path):
    if not os.path.isfile(path):
        return None
    try:
        doc = load(path)
    except Exception as exc:
        problems.append(f"{path} does not parse: {exc}")
        return {}
    return ((on_block(doc).get("workflow_call") or {}).get("inputs")) or {}


composer_path = os.path.join(workflows, "publish.reusable.yml")
image_path = os.path.join(workflows, "image.reusable.yml")
chart_path = os.path.join(workflows, "chart.reusable.yml")

for path in (composer_path, image_path, chart_path):
    if not os.path.isfile(path):
        problems.append(f"{path} is missing — the publish path has no callee")
if problems:
    for problem in problems:
        print(f"publish seam: {problem}")
    sys.exit(1)

try:
    composer_doc = load(composer_path)
    image_doc = load(image_path)
except Exception as exc:
    print(f"publish seam: publish.reusable.yml or image.reusable.yml does not parse: {exc}")
    sys.exit(1)

composer_inputs = ((on_block(composer_doc).get("workflow_call") or {}).get("inputs")) or {}
image_inputs = ((on_block(image_doc).get("workflow_call") or {}).get("inputs")) or {}
jobs = composer_doc.get("jobs") or {}

LOCAL_PREFIX = "./ci/"
for job_id in sorted(jobs):
    job = jobs[job_id] if isinstance(jobs[job_id], dict) else {}
    uses = job.get("uses")
    if not isinstance(uses, str):
        continue
    if not (uses.startswith("./") or uses.startswith("$/")):
        continue
    if not uses.startswith(LOCAL_PREFIX):
        problems.append(
            f"publish.reusable.yml job {job_id!r} uses {uses!r} — GitHub "
            f"resolves a local reusable workflow from the repository ROOT "
            f"as ./ci/<file>, so this reference cannot be "
            f"resolved and the run is rejected at workflow-resolution time: "
            f"no jobs, no check-runs, no log line"
        )
        continue
    callee_path = os.path.join(workflows, os.path.basename(uses))
    if not os.path.isfile(callee_path):
        problems.append(
            f"publish.reusable.yml job {job_id!r} uses {uses!r} but no such "
            f"file exists beside it"
        )
        continue
    declared = callee_inputs(callee_path)
    if declared is None:
        problems.append(f"{callee_path} is missing — {job_id!r} calls a file that is not there")
        continue
    passed = job.get("with") or {}
    for key in passed:
        if key not in declared:
            problems.append(
                f"publish.reusable.yml job {job_id!r} passes {key!r} to "
                f"{os.path.basename(callee_path)}, which does not declare "
                f"that input — a refusal at run time"
            )
    for key, spec in declared.items():
        if isinstance(spec, dict) and spec.get("required") and key not in passed:
            problems.append(
                f"publish.reusable.yml job {job_id!r} does not pass {key!r}, "
                f"which {os.path.basename(callee_path)} declares REQUIRED"
            )

image_job = None
image_job_id = None
for job_id in sorted(jobs):
    job = jobs[job_id] if isinstance(jobs[job_id], dict) else {}
    uses = job.get("uses")
    if isinstance(uses, str) and "image.reusable.yml" in uses:
        image_job = job
        image_job_id = job_id
if image_job is None:
    problems.append("publish.reusable.yml has no job calling image.reusable.yml — the image half does not publish")
else:
    value = (image_job.get("with") or {}).get("app-version")
    if not isinstance(value, str) or not re.fullmatch(
        r"\$\{\{\s*needs\.\w+\.outputs\.app-version\s*\}\}", value
    ):
        problems.append(
            f"publish.reusable.yml image job passes app-version={value!r} — "
            f"it must be the derived output of a job that READ Chart.yaml "
            f"(needs.<job>.outputs.app-version), never a literal a human "
            f"would have to remember in two places"
        )

if "app-version" not in image_inputs:
    problems.append(
        "image.reusable.yml declares no `app-version` input — the tag every "
        "chart's values.yaml pins is not one this workflow can publish"
    )
else:
    default = (image_inputs["app-version"] or {}).get("default", "")
    if default not in ("", None):
        problems.append(
            f"image.reusable.yml `app-version` defaults to {default!r}, not "
            f"empty — a service with an image and no chart would publish a "
            f"tag nobody chose"
        )

composer_code = code_of(composer_path)
image_code = code_of(image_path)
if not re.search(r"appVersion", composer_code):
    problems.append(
        "publish.reusable.yml never reads `appVersion` — the image tag is "
        "not derived from the chart's own single source of truth"
    )
if not re.search(r"Chart\.yaml", composer_code):
    problems.append("publish.reusable.yml never reads Chart.yaml")
if "inputs.app-version" not in image_code:
    problems.append(
        "image.reusable.yml never uses `inputs.app-version` in a step — the "
        "declared input would publish nothing"
    )
if "type=sha,format=long" not in image_code:
    problems.append(
        "image.reusable.yml no longer publishes `type=sha,format=long` — the "
        "immutable sha-<40> tag was the immutable tag; the appVersion tag "
        "was added beside it, never instead of it"
    )

image_outputs = (on_block(image_doc).get("workflow_call") or {}).get("outputs") or {}
if not isinstance(image_outputs, dict) or "digest" not in image_outputs:
    problems.append(
        "image.reusable.yml declares no `digest` workflow_call output — the "
        "chart's image.digest has no derived source, so a human would have "
        "to re-resolve it on every push, which is the defect"
    )

chart_inputs = callee_inputs(chart_path) or {}
if "image-digest" not in chart_inputs:
    problems.append(
        "chart.reusable.yml declares no `image-digest` input — nothing can "
        "hand the built image's digest to the chart that names it"
    )

chart_job = None
for job_id in sorted(jobs):
    job = jobs[job_id] if isinstance(jobs[job_id], dict) else {}
    uses = job.get("uses")
    if isinstance(uses, str) and "chart.reusable.yml" in uses:
        chart_job = job
if chart_job is None:
    problems.append(
        "publish.reusable.yml has no job calling chart.reusable.yml — the "
        "chart half does not publish"
    )
else:
    value = (chart_job.get("with") or {}).get("image-digest")
    if not isinstance(value, str) or not re.fullmatch(
        r"\$\{\{\s*needs\.\w+\.outputs\.digest\s*\}\}", value
    ):
        problems.append(
            f"publish.reusable.yml chart job passes image-digest={value!r} — "
            f"it must be the derived output of the image job that built it "
            f"(needs.<job>.outputs.digest), never a literal a human would "
            f"have to re-resolve on every push"
        )
    needs = chart_job.get("needs")
    needs_list = [needs] if isinstance(needs, str) else list(needs or [])
    if image_job_id and image_job_id not in needs_list:
        problems.append(
            f"publish.reusable.yml chart job does not `needs:` the image job "
            f"({image_job_id!r}), so it may run before the digest it is handed "
            f"exists and the chart names nothing, or a stale digest"
        )

try:
    chart_doc = load(chart_path)
except Exception as exc:
    problems.append(f"chart.reusable.yml does not parse: {exc}")
    chart_doc = {}
pin_run = ""
pin_if = None
pin_index = package_index = None
for job_id, job in (chart_doc.get("jobs") or {}).items():
    if not isinstance(job, dict):
        continue
    steps = job.get("steps")
    if not isinstance(steps, list):
        continue
    if not any(
        isinstance(s, dict) and "helm package" in (s.get("run") or "") for s in steps
    ):
        continue
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        run = step.get("run") or ""
        if "values" in run and "digest" in run:
            pin_index, pin_run, pin_if = i, run, step.get("if")
        if "helm package" in run:
            package_index = i
if pin_index is None:
    problems.append(
        "chart.reusable.yml has no step that writes the image digest into "
        "values.yaml — the chart that lands in the registry names the image "
        "by the mutable tag alone, which is the measured defect"
    )
elif package_index is not None and pin_index > package_index:
    problems.append(
        "chart.reusable.yml writes the image digest AFTER `helm package` — a "
        "package is a tarball of the directory, so a digest written afterwards "
        "pins nothing and the pushed chart names the previous build"
    )
if pin_index is not None:
    if not re.search(r"sha256:\[0-9a-f\]\{64\}", pin_run):
        problems.append(
            "chart.reusable.yml's digest step does not refuse a malformed "
            "digest (no `sha256:[0-9a-f]{64}` grammar check) — a value that "
            "is not a manifest digest renders `repository@nonsense`, which "
            "looks like a pin and fails at image-pull with nothing naming "
            "this step"
        )
    if not re.search(r"image-digest\s*!=\s*''", str(pin_if)):
        problems.append(
            f"chart.reusable.yml's digest step runs unconditionally (if: "
            f"{pin_if!r}) — it must skip on an empty `image-digest` (a "
            f"`push: false` run or a direct caller), where the chart packages "
            f"the digest values.yaml commits rather than a blank one"
        )

try:
    template_doc = load(caller_template)
except Exception as exc:
    problems.append(f"{caller_template} does not parse: {exc}")
    template_doc = {}
called = False
for job_id, job in (template_doc.get("jobs") or {}).items():
    uses = job.get("uses") if isinstance(job, dict) else None
    if not isinstance(uses, str) or "publish.reusable.yml" not in uses:
        continue
    called = True
    if not uses.startswith("anywaye/kit/ci/publish.reusable.yml@"):
        problems.append(
            f"{caller_template} job {job_id!r} uses {uses!r} — the caller "
            f"names the kit ref it adopts, pinned"
        )
    for key in job.get("with") or {}:
        if key not in composer_inputs:
            problems.append(
                f"{caller_template} job {job_id!r} passes {key!r}, which "
                f"publish.reusable.yml does not declare — a refusal at run "
                f"time, and every service copies this file"
            )
if not called:
    problems.append(f"{caller_template} does not call publish.reusable.yml")


def find_charts(by_name):
    """Every sibling dir holding Chart.yaml for the chart called `by_name`.

    Found by the chart's OWN NAME, not by a directory spelling: the fleet
    keeps `chart/` (identity, courier) and `charts/<name>/` (gateway), and a
    worktree's directory name is not a fact this check may rely on. One
    level of siblings only — the AGENTS.md rule — which is what makes this
    assertable offline and unattended in CI.

    ALL matches are returned and ALL are asserted, rather than the first:
    two worktrees of one repository can carry the same chart name (measured
    here — the website repo, mid-rename, in two worktrees at once), and
    picking one silently is a verdict the check cannot defend. Every file
    that claims the name is graded, and the note below names them all.
    """
    candidates = sorted(
        glob.glob(os.path.join(fleet, "*", "chart", "Chart.yaml"))
    ) + sorted(glob.glob(os.path.join(fleet, "*", "charts", "*", "Chart.yaml")))
    found = []
    for candidate in candidates:
        try:
            doc = load(candidate)
        except Exception:
            continue
        if isinstance(doc, dict) and doc.get("name") == by_name:
            found.append(os.path.dirname(candidate))
    return found


def repo_root_of(chart_dir):
    if os.path.basename(os.path.dirname(chart_dir)) == "charts":
        return os.path.dirname(os.path.dirname(chart_dir))
    return os.path.dirname(chart_dir)


apps = sorted(glob.glob(os.path.join(apps_dir, "*.yaml"))) + sorted(
    glob.glob(os.path.join(apps_dir, "*.yml"))
)
if not apps:
    problems.append(f"no Application manifests found in {apps_dir}")

matched = 0
chart_dir_default = (composer_inputs.get("chart-dir") or {}).get("default", "chart/")
for app in apps:
    try:
        adoc = load(app)
    except Exception as exc:
        problems.append(f"{app} does not parse: {exc}")
        continue
    name = ((adoc.get("metadata") or {}).get("name"))
    if name not in SERVICE_APPS:
        continue
    source = (adoc.get("spec") or {}).get("source") or {}
    chart_name = source.get("chart")
    revision = str(source.get("targetRevision"))
    chart_dirs = find_charts(chart_name)
    if not chart_dirs:
        notes.append(
            f"{name}: no sibling checkout beside {fleet} carries a chart "
            f"named {chart_name!r} — chart version/Application "
            f"targetRevision agreement, the values.yaml tag and this "
            f"service's own publish.yml are NOT ASSERTED for {name} here"
        )
        continue
    matched += 1
    if len(chart_dirs) > 1:
        notes.append(
            f"{name}: {len(chart_dirs)} sibling checkouts beside {fleet} "
            f"carry a chart named {chart_name!r} — EVERY one is asserted, "
            f"and the files are: {', '.join(chart_dirs)}"
        )
    for chart_dir in chart_dirs:
        cdoc = load(os.path.join(chart_dir, "Chart.yaml"))
        version = str(cdoc.get("version"))
        app_version = str(cdoc.get("appVersion"))
        if version != revision:
            problems.append(
                f"{name}: {chart_dir}/Chart.yaml version is {version} but the "
                f"Application pins targetRevision {revision} — the OCI tag of a "
                f"Helm chart IS its version, so Argo never finds the pushed "
                f"chart and reports nothing"
            )

        values_path = os.path.join(chart_dir, "values.yaml")
        try:
            vdoc = load(values_path)
            tag = str((vdoc or {}).get("image", {}).get("tag"))
        except Exception as exc:
            problems.append(f"{name}: {values_path} does not parse: {exc}")
            tag = None
        if tag is not None:
            if tag == "latest":
                problems.append(
                    f"{name}: {values_path} pins image.tag `latest` — a floating "
                    f"tag is a deploy that changes when somebody else pushes"
                )
            if tag != app_version:
                problems.append(
                    f"{name}: {values_path} pins image.tag {tag!r} but "
                    f"Chart.yaml appVersion is {app_version!r} — the publish "
                    f"produces {app_version!r}, never {tag!r}, and the box sits "
                    f"in ImagePullBackOff with nothing naming the publish path"
                )

        repo = repo_root_of(chart_dir)
        caller_path = os.path.join(repo, "ci", "publish.yml")
        if os.path.isfile(caller_path):
            try:
                cdoc2 = load(caller_path)
            except Exception as exc:
                problems.append(f"{caller_path} does not parse: {exc}")
                continue
            for job_id, job in (cdoc2.get("jobs") or {}).items():
                uses = job.get("uses") if isinstance(job, dict) else None
                if not isinstance(uses, str) or "publish.reusable.yml" not in uses:
                    continue
                for key in job.get("with") or {}:
                    if key not in composer_inputs:
                        problems.append(
                            f"{caller_path} job {job_id!r} passes {key!r}, which "
                            f"publish.reusable.yml does not declare — a refusal "
                            f"at run time"
                        )
                chart_dir_arg = (job.get("with") or {}).get("chart-dir", chart_dir_default)
                if not os.path.isfile(os.path.join(repo, chart_dir_arg, "Chart.yaml")):
                    problems.append(
                        f"{caller_path} job {job_id!r} sets chart-dir "
                        f"{chart_dir_arg!r} but {repo}/{chart_dir_arg}/Chart.yaml "
                        f"does not exist — the chart job refuses, or publishes a "
                        f"chart that is not the one the values.yaml beside it pins"
                    )
        else:
            notes.append(
                f"{name}: {caller_path} absent — the publish.yml beside the "
                f"chart at {chart_dir} is not asserted here"
            )

if problems:
    for problem in problems:
        print(f"publish seam: {problem}")
    sys.exit(1)

for note in notes:
    print(f"publish seam: note: {note}")
print(
    f"seam: {matched} of {len(SERVICE_APPS)} service Application(s) matched a "
    f"sibling chart beside {fleet}; local uses root-relative and resolving; "
    f"caller/callee inputs agree both ways; appVersion derived into the image "
    f"tag; sha-<40> kept; image digest derived from the image job, written "
    f"before helm package, refused when malformed"
)
PY

run_checker() {
  local ec=0
  local out=""
  out="$("$PY" "$checker" "$@" 2>&1)" || ec=$?
  CHECK_EC="$ec"
  CHECK_OUT="$out"
}
CHECK_EC=0
CHECK_OUT=""

run_checker "$workflows" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -ne 0 ]; then
  printf '%s\n' "$CHECK_OUT"
  exit 1
fi


ctl_a="$TMP/ctl-a-workflows"
mkdir -p "$ctl_a"
cp "$workflows"/*.yml "$ctl_a"/
sed 's|^\( *\)uses: \./ci/image\.reusable\.yml$|\1uses: ./image.reusable.yml|' \
  "$ctl_a/publish.reusable.yml" >"$ctl_a/publish.reusable.yml.new"
mv "$ctl_a/publish.reusable.yml.new" "$ctl_a/publish.reusable.yml"
run_checker "$ctl_a" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (a) the path control did not go red — the root-relative assertion is not measuring what it claims\n'
  exit 1
fi

ctl_b="$TMP/ctl-b-workflows"
mkdir -p "$ctl_b"
cp "$workflows"/*.yml "$ctl_b"/
sed 's|app-version: .*|app-version: "0.1.0"|' \
  "$ctl_b/publish.reusable.yml" >"$ctl_b/publish.reusable.yml.new"
mv "$ctl_b/publish.reusable.yml.new" "$ctl_b/publish.reusable.yml"
run_checker "$ctl_b" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (b) the derived-tag control did not go red — the needs-hand-off assertion is not measuring what it claims\n'
  exit 1
fi

ctl_c="$TMP/ctl-c-fleet"
identity_chart="$(python3 - "$fleet" <<'FIND'
import glob
import os
import sys

fleet = sys.argv[1]
for candidate in sorted(glob.glob(os.path.join(fleet, "*", "chart", "Chart.yaml"))):
    with open(candidate, encoding="utf-8") as fh:
        if "name: identity" in fh.read():
            print(os.path.dirname(candidate))
            break
FIND
)"
if [ -z "$identity_chart" ]; then
  identity_chart="$ctl_c/identity/chart"
  mkdir -p "$identity_chart"
  {
    echo 'apiVersion: v2'
    echo 'name: identity'
    echo 'version: 0.1.0'
    echo 'appVersion: "0.1.0"'
  } >"$identity_chart/Chart.yaml"
  {
    echo 'image:'
    echo '  repository: ghcr.io/anywaye/identity'
    echo '  tag: "0.1.0"'
  } >"$identity_chart/values.yaml"
else
  mkdir -p "$ctl_c/identity"
  cp -R "$identity_chart" "$ctl_c/identity/chart"
fi
sed 's|tag: "0.1.0"|tag: "9.9.9"|' "$ctl_c/identity/chart/values.yaml" \
  >"$ctl_c/identity/chart/values.yaml.new"
mv "$ctl_c/identity/chart/values.yaml.new" "$ctl_c/identity/chart/values.yaml"
run_checker "$workflows" "$apps_dir" "$ctl_c" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (c) the chart control did not go red — the values-tag/appVersion assertion is not measuring what it claims\n'
  exit 1
fi

ctl_d="$TMP/ctl-d-workflows"
mkdir -p "$ctl_d"
cp "$workflows"/*.yml "$ctl_d"/
sed 's|type=sha,format=long|type=raw,value=not-the-commit|' \
  "$ctl_d/image.reusable.yml" >"$ctl_d/image.reusable.yml.new"
mv "$ctl_d/image.reusable.yml.new" "$ctl_d/image.reusable.yml"
run_checker "$ctl_d" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (d) the sha control did not go red — the sha-<40> assertion is not measuring what it claims\n'
  exit 1
fi

ctl_e="$TMP/ctl-e-workflows"
mkdir -p "$ctl_e"
cp "$workflows"/*.yml "$ctl_e"/
sed '/image-digest: .*needs\.image\.outputs\.digest/d' \
  "$ctl_e/publish.reusable.yml" >"$ctl_e/publish.reusable.yml.new"
mv "$ctl_e/publish.reusable.yml.new" "$ctl_e/publish.reusable.yml"
run_checker "$ctl_e" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (e) the digest hand-off control did not go red — the needs.image.outputs.digest assertion is not measuring what it claims\n'
  exit 1
fi

pin_mutate() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import sys

import yaml

src, dst, op = sys.argv[1:4]
with open(src, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)


def is_pin(step):
    if not isinstance(step, dict):
        return False
    run = step.get("run") or ""
    return "values" in run and "digest" in run


for job in (doc.get("jobs") or {}).values():
    if not isinstance(job, dict):
        continue
    steps = job.get("steps")
    if not isinstance(steps, list):
        continue
    pins = [s for s in steps if is_pin(s)]
    if not pins:
        continue
    rest = [s for s in steps if not is_pin(s)]
    steps[:] = rest if op == "delete" else rest + pins
    break
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False)
PY
}

ctl_f="$TMP/ctl-f-workflows"
mkdir -p "$ctl_f"
cp "$workflows"/*.yml "$ctl_f"/
pin_mutate "$ctl_f/chart.reusable.yml" "$ctl_f/chart.reusable.yml.new" delete
mv "$ctl_f/chart.reusable.yml.new" "$ctl_f/chart.reusable.yml"
run_checker "$ctl_f" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (f) the pin-step control did not go red — the image.digest write is not being found at all\n'
  exit 1
fi

ctl_g="$TMP/ctl-g-workflows"
mkdir -p "$ctl_g"
cp "$workflows"/*.yml "$ctl_g"/
pin_mutate "$ctl_g/chart.reusable.yml" "$ctl_g/chart.reusable.yml.new" reorder
mv "$ctl_g/chart.reusable.yml.new" "$ctl_g/chart.reusable.yml"
run_checker "$ctl_g" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (g) the ordering control did not go red — a digest written after `helm package` is not being caught\n'
  exit 1
fi

ctl_h="$TMP/ctl-h-workflows"
mkdir -p "$ctl_h"
cp "$workflows"/*.yml "$ctl_h"/
sed 's/\^sha256:\[0-9a-f\]{64}\$/^sha256:/' \
  "$ctl_h/chart.reusable.yml" >"$ctl_h/chart.reusable.yml.new"
mv "$ctl_h/chart.reusable.yml.new" "$ctl_h/chart.reusable.yml"
run_checker "$ctl_h" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (h) the grammar control did not go red — the sha256:<64 hex> refusal is not being asserted\n'
  exit 1
fi

ctl_i="$TMP/ctl-i-workflows"
mkdir -p "$ctl_i"
cp "$workflows"/*.yml "$ctl_i"/
sed '/^      digest:$/d' \
  "$ctl_i/image.reusable.yml" >"$ctl_i/image.reusable.yml.new"
mv "$ctl_i/image.reusable.yml.new" "$ctl_i/image.reusable.yml"
run_checker "$ctl_i" "$apps_dir" "$fleet" "$caller_template"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish seam: control (i) the digest-output control did not go red — the workflow_call output assertion is not measuring what it claims\n'
  exit 1
fi

run_checker "$workflows" "$apps_dir" "$fleet" "$caller_template"
printf '%s\n' "$CHECK_OUT"
printf 'publish seam: all nine red controls went red (unresolved path; literal tag; values pinning an unpublished tag; sha tag deleted; digest hand-off removed; pin step deleted; pin step reordered after pack; digest grammar weakened; digest output deleted)\n'
exit 0
