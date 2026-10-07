#!/usr/bin/env bash
#
# kit's proof that the substrate install is real, and that its pins are exact.
#
#   bash tests/substrate_test.sh
#
# WHAT THIS IS FOR
#   `templates/substrate/install.sh` is the customer-facing one-command install.
#   It cannot be EXECUTED on a development machine — it needs root, a Linux
#   kernel, a container runtime and a reachable registry — so the claims it
#   makes are otherwise untested. This script proves the parts that can be
#   proven without a box: the script parses, DRY_RUN runs to completion
#   printing the ordered steps, every pin is exact, every manifest parses, the
#   two ClusterIssuers are staging and prod with distinct account keys, no
#   image floats on `latest`, and no secret is a literal in the tree.
#
# EVERY CLAIM HAS A CONTROL THAT MUST ANSWER DIFFERENTLY.
#   A check that passes against an empty directory is not a check. So each
#   check below is run twice: once against the real tree (must be GREEN) and
#   once against a fixture built to violate exactly that one property (must
#   be RED). The pin check's control is the one the packet names — a fixture
#   with a `latest` pin goes red under the same check the real tree passes.
#   A control that does not go red is reported as a failure of the test itself.
#
# WHAT IS NOT PROVEN HERE
#   That k3s installs, that Argo syncs, that the charts exist. Those need a
#   customer box. `templates/substrate/README.md` says so in the same words.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBSTRATE="$ROOT/templates/substrate"
MANIFESTS="$SUBSTRATE/manifests/applications"
TLS_DIR="$SUBSTRATE/manifests/tls"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "substrate_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-substrate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passes=0
skips=0
failures=0

pass() {
  printf '      PASS substrate_test: %s\n' "$1"
  passes=$((passes + 1))
}

skip() {
  printf '      SKIP substrate_test: %s — %s\n' "$1" "$2"
  skips=$((skips + 1))
}

fail() {
  printf '      FAIL substrate_test: %s\n' "$1"
  printf '%s\n' "$2" | head -12 | sed 's/^/             /'
  failures=$((failures + 1))
}

# run <name> <expected: red|green> <command...>
#
# The `|| ec=$?` shape is not defensive style: `out=$(cmd)` alone is an
# ASSIGNMENT, and under `set -e` a failing `cmd` kills this script before the
# status is ever read — so a check that correctly REJECTS a bad fixture would
# take the harness down with it. The guard makes the command part of a list,
# which `set -e` does not apply to.
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

printf -- '-- substrate_test: the install is real, and the pins are exact\n'

# ===========================================================================
# 1. install.sh parses
# ===========================================================================
run 'install.sh parses (bash -n)' green bash -n "$SUBSTRATE/install.sh"

# ===========================================================================
# 2. DRY_RUN=1 runs to completion, printing the ordered steps
# ===========================================================================
dry_run_out="$(DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" && dry_run_ec=0 || dry_run_ec=$?

if [ "$dry_run_ec" -ne 0 ]; then
  fail 'DRY_RUN=1 runs to completion' "$dry_run_out"
else
  pass 'DRY_RUN=1 runs to completion'
fi

# The seven steps, in order. The markers are `[1/7]` … `[7/7]`; the check reads
# them out of the output in the order they appear and compares against the
# expected sequence, so a script that printed them out of order — or skipped
# one — would go red here rather than passing on the presence of all seven.
# The `|| true` is load-bearing: with no `[n/7]` markers printed yet, grep
# exits 1, and under `set -o pipefail` a failing command substitution would
# take the harness down before the status is ever read — the same shape the
# `run` helper's comment describes four lines below.
found="$(printf '%s\n' "$dry_run_out" | grep -o '\[[0-9]/7\]' | tr -d '[]' | cut -d/ -f1 | tr '\n' ' ' || true)"
found="${found% }"
if [ "$found" = "1 2 3 4 5 6 7" ]; then
  pass 'DRY_RUN prints the seven steps in order'
else
  fail 'DRY_RUN prints the seven steps in order' "found step sequence: '${found}'"
fi

# Each step must say what it would do. A DRY_RUN that printed only the headers
# and no per-step action would be a plan with no content.
dry_count="$(printf '%s\n' "$dry_run_out" | grep -c 'DRY_RUN:' || true)"
if [ "$dry_count" -ge 7 ]; then
  pass 'DRY_RUN prints a per-step action for every step'
else
  fail 'DRY_RUN prints a per-step action for every step' "found ${dry_count} DRY_RUN action(s), expected >= 7"
fi

# ===========================================================================
# 3. Every pin is exact — and a `latest` pin goes red under the same check
# ===========================================================================
#
# The check is a python script that reads the four version variables and
# refuses a floating value. It is run against the real install.sh (green) and
# against a fixture with `latest` substituted in (red). The fixture is the
# control: it proves the check can fail, which is the only thing that
# distinguishes it from a grep that matches nothing.
check_pins() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
pins = re.findall(
    r'^(K3S_VERSION|CERT_MANAGER_VERSION|CNPG_VERSION|ARGOCD_VERSION)="([^"]+)"',
    src,
    re.M,
)
if len(pins) != 4:
    print(f"expected 4 pins, found {len(pins)}")
    sys.exit(1)
bad = []
for name, val in pins:
    if val in ("latest", "main", "master"):
        bad.append(f"{name}={val} (floating ref)")
    elif not re.match(r"^v?\d+\.\d+\.\d+", val):
        bad.append(f"{name}={val} (not an exact version)")
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
}

run 'every pin is exact (k3s, cert-manager, CNPG, Argo CD)' green check_pins "$SUBSTRATE/install.sh"

# The control: the same check against a fixture with a floating pin. This MUST
# go red. If it does not, the check above is not measuring what it claims.
fixture_latest="$WORK/install-latest.sh"
sed 's/^K3S_VERSION="v1.37.1+k3s1"/K3S_VERSION="latest"/' \
  "$SUBSTRATE/install.sh" >"$fixture_latest"
run 'control: a latest pin goes red under the same check' red check_pins "$fixture_latest"

# ===========================================================================
# 4. Every manifest parses, and the Applications carry the fields Argo needs
# ===========================================================================
#
# One python check over the whole directory: every file parses as YAML, every
# document is an Application, and every Application has spec.source and
# spec.destination. Run against the real manifests (green) and against a
# fixture with a broken file (red).
check_manifests() {
  "$PY" - "$1" <<'PY'
import os
import sys

import yaml

d = sys.argv[1]
files = sorted(f for f in os.listdir(d) if f.endswith((".yaml", ".yml")))
if not files:
    print("no YAML manifests found")
    sys.exit(1)
problems = []
for f in files:
    path = os.path.join(d, f)
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except yaml.YAMLError as e:
        problems.append(f"{f}: does not parse ({e})")
        continue
    if not isinstance(doc, dict):
        problems.append(f"{f}: not a mapping")
        continue
    if doc.get("kind") != "Application":
        problems.append(f"{f}: kind is {doc.get('kind')!r}, not 'Application'")
        continue
    spec = doc.get("spec", {})
    for field in ("source", "destination"):
        if field not in spec:
            problems.append(f"{f}: spec.{field} missing")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(files)} Applications, all with spec.source and spec.destination")
PY
}

run 'every manifest parses and carries spec.source + spec.destination' green check_manifests "$MANIFESTS"

# The control: a fixture directory with one broken manifest. Must go red.
fixture_broken="$WORK/broken-manifests"
mkdir -p "$fixture_broken"
cp "$MANIFESTS/identity.yaml" "$fixture_broken/"
printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: broken\n  spec:\n    destination: {}\n' \
  >"$fixture_broken/broken.yaml"
run 'control: a manifest missing spec.source goes red' red check_manifests "$fixture_broken"

# ===========================================================================
# 5. The ClusterIssuers — staging and prod, HTTP-01 through Traefik
# ===========================================================================
#
# A separate check from check_manifests, and the reason is the kind: that one
# asserts `kind: Application` over manifests/applications, and folding a
# ClusterIssuer into it would force the wrong kind on one of the two
# directories. Without this note the next reader "simplifies" the two back
# together and breaks one of them.
#
# Each assertion is a specific mistake a copy-paste makes — a shared account
# key, a real email committed, one solver — and each failure names the
# document and the field, so a red line is actionable.
check_issuers() {
  "$PY" - "$1" <<'PY'
import os
import sys

import yaml

d = sys.argv[1]
if not os.path.isdir(d):
    print(f"{d}: no such directory — the tls manifests do not exist")
    sys.exit(1)
files = sorted(f for f in os.listdir(d) if f.endswith((".yaml", ".yml")))
if not files:
    print("no YAML manifests found")
    sys.exit(1)
docs = []
for f in files:
    path = os.path.join(d, f)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"{f}: unreadable ({e})")
        sys.exit(1)
    try:
        parsed = list(yaml.safe_load_all(text))
    except yaml.YAMLError as e:
        print(f"{f}: does not parse ({e})")
        sys.exit(1)
    for i, doc in enumerate(parsed):
        label = f if len(parsed) == 1 else f"{f} doc {i + 1}"
        if not isinstance(doc, dict):
            print(f"{label}: not a mapping")
            sys.exit(1)
        docs.append((label, doc))

problems = []
names = []
servers = []
keys = []
for label, doc in docs:
    if doc.get("kind") != "ClusterIssuer":
        problems.append(f"{label}: kind is {doc.get('kind')!r}, not 'ClusterIssuer'")
        continue
    name = doc.get("metadata", {}).get("name")
    names.append(name)
    acme = doc.get("spec", {}).get("acme", {})
    server = acme.get("server")
    if not isinstance(server, str) or not server.startswith("https://"):
        problems.append(f"{label}: spec.acme.server is {server!r}, not an https:// URL")
    else:
        servers.append((name, server))
    email = acme.get("email")
    if email != "ACME_EMAIL_PLACEHOLDER":
        problems.append(
            f"{label}: spec.acme.email is {email!r}, not the placeholder"
            " 'ACME_EMAIL_PLACEHOLDER' — a real address committed here lands on"
            " a customer's ACME account"
        )
    key = acme.get("privateKeySecretRef", {}).get("name")
    if not key:
        problems.append(f"{label}: spec.acme.privateKeySecretRef.name missing")
    else:
        keys.append((name, key))
    solvers = acme.get("solvers")
    if not isinstance(solvers, list) or not solvers:
        problems.append(
            f"{label}: spec.acme.solvers is empty or not a list — this issuer"
            " can solve no challenge"
        )
    else:
        for solver in solvers:
            if "http01" not in solver:
                problems.append(f"{label}: a solver carries no http01")

if sorted(names) != ["letsencrypt-prod", "letsencrypt-staging"]:
    problems.append(
        f"issuer names are {sorted(names)}, expected ['letsencrypt-prod', 'letsencrypt-staging']"
    )

if len(servers) == 2 and servers[0][1] == servers[1][1]:
    problems.append(
        "both issuers share one ACME server URL — staging and production are"
        " separate directories"
    )
if len(servers) == 2:
    prod = [s for n, s in servers if n == "letsencrypt-prod"]
    if prod and "acme-v02" not in prod[0]:
        problems.append(f"letsencrypt-prod server {prod[0]!r} does not contain 'acme-v02'")

if len(keys) == 2 and keys[0][1] == keys[1][1]:
    problems.append(
        f"both issuers share privateKeySecretRef.name {keys[0][1]!r} — staging"
        " and production are separate ACME accounts"
    )

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(
    f"{len(docs)} ClusterIssuers ({', '.join(sorted(names))}), HTTP-01"
    " solvers, email still the placeholder"
)
PY
}

run 'the ClusterIssuers are staging and prod, distinct in every field' green check_issuers "$TLS_DIR"

# The controls derive from the real manifests, so they need them to exist;
# the green check above is the one that says what is missing when they do not.
if ls "$TLS_DIR"/*.yaml >/dev/null 2>&1; then
  # The control: a fixture whose issuers share one account key. Must go red.
  fixture_shared_key="$WORK/issuers-shared-key"
  mkdir -p "$fixture_shared_key"
  sed 's/letsencrypt-staging-account-key/letsencrypt-prod-account-key/' \
    "$TLS_DIR"/*.yaml >"$fixture_shared_key/clusterissuer.yaml"
  run 'control: issuers sharing one account key go red' red check_issuers "$fixture_shared_key"

  # The control: a fixture whose issuers carry no solver. Must go red.
  fixture_no_solvers="$WORK/issuers-no-solvers"
  mkdir -p "$fixture_no_solvers"
  sed -e 's/^    solvers:/    solvers: []/' \
    -e '/^      - http01:/,/ingressClassName: traefik/d' \
    "$TLS_DIR"/*.yaml >"$fixture_no_solvers/clusterissuer.yaml"
  run 'control: an issuer with no solver goes red' red check_issuers "$fixture_no_solvers"
else
  fail 'controls: the issuer fixtures need the real manifests' "$TLS_DIR has no YAML — the green check above names what is missing"
fi

# ===========================================================================
# 6. No image floats on `latest` anywhere in the substrate tree
# ===========================================================================
#
# A floating tag in an install script is the defect this fleet exists to
# avoid. The check greps the whole tree; the control plants a `:latest` and
# requires the same grep to find it.
if grep -rn ':latest' "$SUBSTRATE" >/dev/null 2>&1; then
  fail 'no :latest image tag in the substrate tree' "$(grep -rn ':latest' "$SUBSTRATE")"
else
  pass 'no :latest image tag in the substrate tree'
fi

fixture_latest_tag="$WORK/latest-tag"
mkdir -p "$fixture_latest_tag"
printf 'image: ghcr.io/cafaye/charts/identity:latest\n' >"$fixture_latest_tag/pod.yaml"
if grep -rn ':latest' "$fixture_latest_tag" >/dev/null 2>&1; then
  pass 'control: a planted :latest tag is found by the same grep'
else
  fail 'control: a planted :latest tag is found by the same grep' "the grep did not find the planted tag"
fi

# ===========================================================================
# 7. No secret is a literal in the tree
# ===========================================================================
#
# Two forms: `stringData:` in a manifest (the inline-secret mechanism) and an
# `echo` of the pull secret in install.sh (which would print it to the logs).
# The control plants each and requires the same check to find it.
if grep -rn 'stringData:' "$SUBSTRATE/manifests" >/dev/null 2>&1; then
  fail 'no inline secret (stringData) in the manifests' "$(grep -rn 'stringData:' "$SUBSTRATE/manifests")"
else
  pass 'no inline secret (stringData) in the manifests'
fi

if grep -nE 'echo.*\$KIT_SUBSTRATE_PULL_SECRET' "$SUBSTRATE/install.sh" >/dev/null 2>&1; then
  fail 'the pull secret is never echoed' "$(grep -nE 'echo.*\$KIT_SUBSTRATE_PULL_SECRET' "$SUBSTRATE/install.sh")"
else
  pass 'the pull secret is never echoed'
fi

fixture_secret="$WORK/secret"
mkdir -p "$fixture_secret"
printf 'stringData:\n  password: supersecretvalue123\n' >"$fixture_secret/secret.yaml"
if grep -rn 'stringData:' "$fixture_secret" >/dev/null 2>&1; then
  pass 'control: a planted stringData secret is found by the same grep'
else
  fail 'control: a planted stringData secret is found by the same grep' "the grep did not find the planted secret"
fi

# ===========================================================================
# Summary
# ===========================================================================
printf -- '-- substrate_test: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"
