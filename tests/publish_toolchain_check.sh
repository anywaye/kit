#!/usr/bin/env bash
#
# publish_toolchain_check.sh — the two publish steps that had never once
# succeeded in the fleet: the helm pin's verification, and the provenance
# stamper's home. Standalone.
#
#   bash tests/publish_toolchain_check.sh <workflows-dir>
#
# WHY THIS EXISTS. The publish path resolved for the first time (the previous
# packet fixed the root-relative `uses:` and the image-tag seam), and two more
# defects surfaced, each in a step that had therefore NEVER run to completion
# anywhere:
#
#   1. `chart.reusable.yml`'s `install helm (pinned)` step ran
#      `helm version --client` after pinning Helm v4. Helm 4 removed
#      `--client`, so the step died with `Error: unknown flag: --client`,
#      exit 1, before the chart was packaged. Helm 3 still has `--client`,
#      so a developer's local helm could not see the bug.
#   2. `image.reusable.yml`'s `stamp provenance` step ran
#      `sh docker/provenance.sh --validate` in the CALLER's checkout. The
#      script lives in kit; identity, gateway, courier and parlor carry no
#      `docker/` directory, so the step died with
#      `sh: 0: cannot open docker/provenance.sh: No such file` and no image
#      in the fleet has ever been published.
#
# WHAT IT PROVES, on the PARSED workflow with comments stripped (a check a
# comment can satisfy is not a check):
#
#   helm:
#     H1. No `helm version` invocation anywhere carries a flag the pinned
#         major does not have. The allowed set is Helm 4.3.0's own
#         `helm version` options — `--template`, `--short`, `--help`/`-h` —
#         read from its documentation; `--client` is the regression and the
#         assertion is not narrowed to it alone.
#     H2. The install step actually VERIFIES the pin: the installed version is
#         compared against the pin in a test that can exit non-zero. A version
#         printed for the log is a log line, not a check.
#     H3. The pin is ONE value: it lives in the step's `env.HELM_PIN`, and the
#         run body contains no `vN.N.N` literal, so install and verify cannot
#         disagree by an edit to one of two numbers.
#
#   provenance:
#     P1. No run body invokes the stamper through the caller's relative path
#         (`docker/provenance.sh`, `./docker/provenance.sh`). The stamp step
#         runs it through `$KIT_PROVENANCE_SCRIPT`.
#     P2. Kit is fetched at the reusable workflow's OWN commit — an `env`
#         value of `${{ job.workflow_sha }}` — not `master` and not a ref the
#         caller supplies, and into `$RUNNER_TEMP` rather than the build
#         context.
#     P3. The fetch refuses by name when the script is absent: a `[ ! -f … ]`
#         guard on docker/provenance.sh that exits non-zero. A stamp that
#         silently skips when the script is missing ships an unstamped image
#         and says nothing.
#
# THE FIVE RED CONTROLS. Each fixture copies the REAL workflows and violates
# exactly ONE property; the SAME checker must answer RED:
#   (a) `helm version --template` reverted to `helm version --client`;
#   (b) the helm comparison disabled (`!=` rewritten to `==`);
#   (c) the stamp step reverted to `sh docker/provenance.sh --validate`;
#   (d) the fetch ref rewritten to the literal `master`;
#   (e) the existence guard inverted (`[ ! -f ]` → `[ -f ]`, i.e. no guard).
# A control that stays green is a failure of the proof itself, reported as
# such rather than passed over.
#
# SINGLE SOURCE OF TRUTH. One checker program below; the real tree and all
# five controls run the SAME code against fixture directories. A PASS in
# tests/focused_publish.sh or in tests/validate.sh means exactly what this
# standalone proof means — the rule chart_publish_check.sh states at length.
#
# Exit 0: the real tree passes and all five controls go red.
# Exit 1: an assertion fails, or a control stays green.
# Exit 2: usage error, or no YAML-capable python — the workflows cannot be
#         read without a parser, and that is reported, never passed silently.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: bash tests/publish_toolchain_check.sh <workflows-dir>" >&2
  exit 2
fi
workflows="$1"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$workflows" ]; then
  echo "publish toolchain: $workflows is not a directory" >&2
  exit 2
fi

# The gate's venv python when present, else a system python3 with PyYAML. No
# parser is an explicit exit 2, never a silent pass — the same resolution and
# the same discipline as publish_seam_check.sh and workflow_timeouts_check.sh.
PY=""
if [ -x "$ROOT/.venv/bin/python" ] && "$ROOT/.venv/bin/python" -c "import yaml" 2>/dev/null; then
  PY="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  PY="python3"
fi
if [ -z "$PY" ]; then
  echo "publish toolchain: cannot measure — no YAML-capable python (gate .venv and system PyYAML both absent)" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-publish-toolchain.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checker="$TMP/publish-toolchain-check.py"
cat >"$checker" <<'PY'
import glob
import os
import re
import sys

import yaml

workflows = sys.argv[1]

problems = []
helm_version_invocations = 0
helm_install_steps = 0


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def code_of(text):
    # Comments stripped BEFORE reading: a check a comment can satisfy is not a
    # check, and these workflows explain themselves in prose.
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def steps_of(path):
    """Every (job_id, step_index, step) in a workflow file."""
    try:
        doc = load(path)
    except Exception as exc:  # noqa: BLE001 - a parse failure is the finding
        problems.append(f"{os.path.basename(path)} does not parse: {exc}")
        return []
    if not isinstance(doc, dict):
        problems.append(f"{os.path.basename(path)} is not a mapping")
        return []
    out = []
    for jid, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for i, step in enumerate(job.get("steps") or []):
            if isinstance(step, dict):
                out.append((jid, i, step))
    return out


def run_body(step):
    body = step.get("run")
    return code_of(body) if isinstance(body, str) else ""


def env_of(step):
    env = step.get("env")
    return env if isinstance(env, dict) else {}


files = sorted(glob.glob(os.path.join(workflows, "*.yml"))) + sorted(
    glob.glob(os.path.join(workflows, "*.yaml"))
)
if not files:
    problems.append(f"no *.yml or *.yaml in {workflows}")

# ---------------------------------------------------------------------
# Helm: the pinned major's flags, the pin's verification, one pin.
#
# Helm 4.3.0's `helm version` options, from its own documentation, are
# `--short` and `--template` (plus `-h`/`--help`). `--client` was a Helm 3
# option and was removed with the client/server split. Anything else on a
# `helm version` line is a flag the pinned major may not have.
# ---------------------------------------------------------------------
HELM_VERSION_FLAGS = {"--template", "--short", "--help", "-h"}

for path in files:
    for jid, i, step in steps_of(path):
        body = run_body(step)
        if not body:
            continue
        for line in body.splitlines():
            if re.search(r"\bhelm\s+version\b", line):
                helm_version_invocations += 1
                # Every long/short flag on the invocation line, quotes removed.
                for token in line.split():
                    token = token.strip("'\"")
                    if token.startswith("-") and re.fullmatch(
                        r"-{1,2}[A-Za-z][A-Za-z0-9-]*", token
                    ):
                        if token not in HELM_VERSION_FLAGS:
                            problems.append(
                                f"{os.path.basename(path)} job {jid!r} step "
                                f"{i} runs `helm version {token}` — the pinned "
                                f"major (v4) does not have {token}; its "
                                f"`helm version` options are "
                                f"{', '.join(sorted(HELM_VERSION_FLAGS))}, and "
                                f"`--client` in particular was removed with the "
                                f"Helm 3 client/server split"
                            )

# The chart workflow must verify the pin, and the pin must be one value.
chart_path = os.path.join(workflows, "chart.reusable.yml")
if not os.path.isfile(chart_path):
    problems.append("chart.reusable.yml is missing — the helm install has no home")
else:
    for jid, i, step in steps_of(chart_path):
        body = run_body(step)
        if "get-helm-3" not in body:
            continue
        helm_install_steps += 1
        env = env_of(step)
        pin = env.get("HELM_PIN")
        # H3: the pin is the one literal, and the body holds no second copy.
        if not (isinstance(pin, str) and re.fullmatch(r"v\d+\.\d+\.\d+", pin)):
            problems.append(
                f"chart.reusable.yml job {jid!r} step {i} does not carry the "
                f"helm pin in env.HELM_PIN as a vN.N.N string (got {pin!r}) — "
                f"there is no single value to install AND verify against"
            )
        if re.search(r"v\d+\.\d+\.\d+", body):
            problems.append(
                f"chart.reusable.yml job {jid!r} step {i} spells a vN.N.N "
                f"literal inside its run body as well as in env.HELM_PIN — the "
                f"install and the verification can drift by an edit to one of "
                f"two numbers"
            )
        # H2: a comparison against the pin that can exit non-zero.
        if not (
            re.search(r"\[.*!=.*\]", body)
            and re.search(r"\bexit\s+1\b", body)
            and "HELM_PIN" in body
        ):
            problems.append(
                f"chart.reusable.yml job {jid!r} step {i} does not VERIFY the "
                f"helm pin — it must compare the installed version against "
                f"env.HELM_PIN in a test that exits non-zero, or the check is a "
                f"log line that cannot fail"
            )

if helm_version_invocations == 0:
    problems.append(
        "no `helm version` invocation was found in any workflow — the pin is "
        "not verified anywhere, so the verification assertion proved nothing"
    )
if helm_install_steps == 0:
    problems.append(
        "no helm install step (get-helm-3) was found in chart.reusable.yml — "
        "the pin's verification has no site to live at"
    )

# ---------------------------------------------------------------------
# Provenance: the stamper comes from kit's own commit, not the caller's tree.
# ---------------------------------------------------------------------
image_path = os.path.join(workflows, "image.reusable.yml")

# P1: no INVOCATION of the stamper through the caller-relative path, in ANY
# workflow — provenance.sh is a file in kit, so a run body that reaches it as
# `docker/provenance.sh` reads the caller's checkout and has never worked.
# Read the COMMAND, not every line: the fetch computes
# `script="…/docker/provenance.sh"` and the guard echoes that path, and
# neither is an invocation.
for path in files:
    for jid, i, step in steps_of(path):
        body = run_body(step)
        if not body:
            continue
        for line in body.splitlines():
            tokens = line.split()
            # Drop leading VAR=value env assignments to find the command word.
            j = 0
            while j < len(tokens) and re.fullmatch(
                r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[j]
            ):
                j += 1
            cmd = [t.strip("'\"") for t in tokens[j:]]
            relative = r"(?:\./)?docker/provenance\.sh"
            invoked = bool(cmd) and (
                re.fullmatch(relative, cmd[0])
                or (
                    cmd[0] in ("sh", "bash", "source", ".")
                    and len(cmd) > 1
                    and re.fullmatch(relative, cmd[1])
                )
            )
            if invoked:
                problems.append(
                    f"{os.path.basename(path)} job {jid!r} step {i} invokes "
                    f"`{line.strip()}` — docker/provenance.sh is a file in kit, "
                    f"not in the caller's checkout (identity, gateway, courier "
                    f"and parlor have no docker/ directory), so this reads a "
                    f"path that has never existed and the stamp never ran"
                )

if not os.path.isfile(image_path):
    problems.append("image.reusable.yml is missing — the stamp has no home")
else:
    stamp_seen = 0
    fetch_seen = 0
    guard_seen = 0
    for jid, i, step in steps_of(image_path):
        body = run_body(step)
        if not body:
            continue
        if "--validate" in body:
            stamp_seen += 1
            if "$KIT_PROVENANCE_SCRIPT" not in body and "${KIT_PROVENANCE_SCRIPT}" not in body:
                problems.append(
                    f"image.reusable.yml job {jid!r} step {i} stamps through "
                    f"something other than $KIT_PROVENANCE_SCRIPT — the path "
                    f"exported by the fetch step is the only one known to hold "
                    f"kit's script rather than the caller's"
                )
        # P3: the fetch refuses by name when the script is absent.
        if re.search(r"\[\s*!\s*-f\b", body) and "provenance.sh" in body and re.search(
            r"\bexit\s+1\b", body
        ):
            guard_seen += 1
        # P2: the fetch itself — kit, into $RUNNER_TEMP, at the ref from env.
        if (
            "fetch" in body
            and "cafaye/kit" in body
            and "docker/provenance.sh" in body
            and "RUNNER_TEMP" in body
        ):
            fetch_seen += 1
            env = env_of(step)
            refs = [str(v).strip() for v in env.values()]
            if "${{ job.workflow_sha }}" not in refs:
                problems.append(
                    f"image.reusable.yml job {jid!r} step {i} fetches kit but "
                    f"does not pin the ref to ${{{{ job.workflow_sha }}}} (the "
                    f"reusable workflow file's OWN commit) — env refs were "
                    f"{refs!r}; `master` drifts and an input is a second pin a "
                    f"service must raise"
                )
            if any(re.search(r"(^|/)master$", r) for r in refs):
                problems.append(
                    f"image.reusable.yml job {jid!r} step {i} fetches kit at a "
                    f"`master` literal — the ref must be the workflow's own "
                    f"commit, never a moving branch"
                )
            if not re.search(r'origin\s+"?\$\{?KIT_REF\}?"?', body):
                problems.append(
                    f"image.reusable.yml job {jid!r} step {i} fetches kit but "
                    f"the fetched ref is not the env value (no `origin "
                    f"\"$KIT_REF\"`) — a literal ref would not be the pin read "
                    f"above"
                )

    if stamp_seen == 0:
        problems.append(
            "image.reusable.yml has no step running `provenance.sh --validate` "
            "— the stamp is gone, and the assertions above proved nothing"
        )
    if fetch_seen == 0:
        problems.append(
            "image.reusable.yml never fetches kit's docker/ tree — the stamper "
            "has no source"
        )
    if guard_seen == 0:
        problems.append(
            "image.reusable.yml has no `[ ! -f … ]` guard on the stamper — a "
            "missing script would fail as a bare shell error rather than a "
            "refusal that names the missing piece"
        )

if problems:
    for problem in problems:
        print(f"publish toolchain: {problem}")
    sys.exit(1)

print(
    f"publish toolchain: {helm_version_invocations} `helm version` "
    f"invocation(s) carry no flag outside the pinned major's set; the helm pin "
    f"is verified against one value; the provenance stamper is fetched from "
    f"cafaye/kit@job.workflow_sha into $RUNNER_TEMP, guarded by name"
)
PY

run_checker() {
  # The `|| ec=$?` shape is load-bearing, the reason is stated in
  # chart_publish_check.sh: a bare `out="$(cmd)"` that fails takes the shell
  # down under set -e before the status is read.
  local ec=0
  CHECK_OUT=""
  CHECK_OUT="$("$PY" "$checker" "$@" 2>&1)" || ec=$?
  CHECK_EC="$ec"
}
CHECK_EC=0
CHECK_OUT=""

run_checker "$workflows"
if [ "$CHECK_EC" -ne 0 ]; then
  printf '%s\n' "$CHECK_OUT"
  exit 1
fi

# ---------------------------------------------------------------------
# THE FIVE CONTROLS. A one-token edit inside a copy of the REAL files; the
# same checker must answer RED for each.
# ---------------------------------------------------------------------
copy_workflows() {
  mkdir -p "$1"
  cp "$workflows"/*.yml "$1"/
}

# (a) The helm flag the pinned major removed, put back.
ctl_a="$TMP/ctl-a-client"
copy_workflows "$ctl_a"
sed 's|helm version --template|helm version --client|' \
  "$ctl_a/chart.reusable.yml" >"$ctl_a/chart.reusable.yml.new"
mv "$ctl_a/chart.reusable.yml.new" "$ctl_a/chart.reusable.yml"
run_checker "$ctl_a"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish toolchain: control (a) `helm version --client` did not go red — the helm-flag assertion is not measuring what it claims\n'
  exit 1
fi

# (b) The comparison disabled: a version check that cannot fail.
ctl_b="$TMP/ctl-b-nofail"
copy_workflows "$ctl_b"
sed 's|if \[ "$helm_version" != "$HELM_PIN" \]; then|if [ "$helm_version" == "$HELM_PIN" ]; then|' \
  "$ctl_b/chart.reusable.yml" >"$ctl_b/chart.reusable.yml.new"
mv "$ctl_b/chart.reusable.yml.new" "$ctl_b/chart.reusable.yml"
run_checker "$ctl_b"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish toolchain: control (b) a helm check that cannot fail did not go red — the pin-verification assertion is not measuring what it claims\n'
  exit 1
fi

# (c) The stamper read from the caller's checkout again.
ctl_c="$TMP/ctl-c-relative"
copy_workflows "$ctl_c"
sed 's|sh "$KIT_PROVENANCE_SCRIPT" --validate|sh docker/provenance.sh --validate|' \
  "$ctl_c/image.reusable.yml" >"$ctl_c/image.reusable.yml.new"
mv "$ctl_c/image.reusable.yml.new" "$ctl_c/image.reusable.yml"
run_checker "$ctl_c"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish toolchain: control (c) the caller-relative provenance path did not go red — the stamper-home assertion is not measuring what it claims\n'
  exit 1
fi

# (d) The kit ref rewritten to a moving branch.
ctl_d="$TMP/ctl-d-master"
copy_workflows "$ctl_d"
sed 's|KIT_REF: ${{ job.workflow_sha }}|KIT_REF: master|' \
  "$ctl_d/image.reusable.yml" >"$ctl_d/image.reusable.yml.new"
mv "$ctl_d/image.reusable.yml.new" "$ctl_d/image.reusable.yml"
run_checker "$ctl_d"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish toolchain: control (d) a `master` kit ref did not go red — the workflow-commit pin assertion is not measuring what it claims\n'
  exit 1
fi

# (e) The existence guard removed.
ctl_e="$TMP/ctl-e-guard"
copy_workflows "$ctl_e"
sed 's|if \[ ! -f "$script" \]; then|if [ -f "$script" ]; then|' \
  "$ctl_e/image.reusable.yml" >"$ctl_e/image.reusable.yml.new"
mv "$ctl_e/image.reusable.yml.new" "$ctl_e/image.reusable.yml"
run_checker "$ctl_e"
if [ "$CHECK_EC" -eq 0 ]; then
  printf 'publish toolchain: control (e) the missing-stamper guard removed did not go red — the refusal-by-name assertion is not measuring what it claims\n'
  exit 1
fi

# The proof, on the way out: the real tree's own summary line.
run_checker "$workflows"
printf '%s\n' "$CHECK_OUT"
printf 'publish toolchain: all five red controls went red (--client; check that cannot fail; caller-relative stamper; master ref; guard removed)\n'
exit 0
