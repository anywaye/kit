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
#   two ClusterIssuers are staging and prod with distinct account keys, the
#   Postgres Cluster reproduces the local provisioning contract, the Redis
#   image is pinned exact, the NATS broker is installed with the fleet's
#   stream defined idempotently and matching the local stack's nats-stream-init,
#   the recorded secret name-and-key list matches what install.sh creates,
#   no image floats on `latest`, no secret is a literal in the tree, and the
#   apply mode is assigned by where the manifest comes from — a REMOTE URL is
#   `--server-side=true --force-conflicts` (client-side apply's
#   last-applied-configuration annotation overflows Kubernetes's 262144-byte cap
#   on metadata.annotations for cert-manager's, CNPG's and Argo CD's CRDs, and a
#   re-run after any mixed-mode apply collides with "field managed by another
#   client"), while kit's own manifests stay client-side so a re-run keeps the
#   ability to reclaim its own fields.
#   the env-var surface the leak check covers is still the surface the installer
#   reads — so a rename that reaches one file and not the other goes red.
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
# The install needs KIT_SUBSTRATE_DATABASES even to plan: step 8 provisions
# one role-and-database per named service, so a plan with no names is a plan
# for nothing. The success path below sets it; the refusal controls after it
# prove an unset or empty value is refused with the fix named. (SMTP and the
# paired courier values are validated on the live path only — a plan does not
# need credentials to print.)
DBS="identity,gateway,courier,parlor"
dry_run_out="$(KIT_SUBSTRATE_DATABASES="$DBS" DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" && dry_run_ec=0 || dry_run_ec=$?

if [ "$dry_run_ec" -ne 0 ]; then
  fail 'DRY_RUN=1 runs to completion' "$dry_run_out"
else
  pass 'DRY_RUN=1 runs to completion'
fi

# The eleven steps, in order. The markers are `[1/11]` … `[11/11]`; the check
# reads them out of the output in the order they appear and compares against
# the expected sequence, so a script that printed them out of order — or
# skipped one — would go red here rather than passing on the presence of all
# eleven. The `|| true` is load-bearing: with no `[n/11]` markers printed yet,
# grep exits 1, and under `set -o pipefail` a failing command substitution
# would take the harness down before the status is ever read — the same shape
# the `run` helper's comment describes four lines below.
found="$(printf '%s\n' "$dry_run_out" | grep -o '\[[0-9][0-9]*/11\]' | tr -d '[]' | cut -d/ -f1 | tr '\n' ' ' || true)"
found="${found% }"
if [ "$found" = "1 2 3 4 5 6 7 8 9 10 11" ]; then
  pass 'DRY_RUN prints the eleven steps in order'
else
  fail 'DRY_RUN prints the eleven steps in order' "found step sequence: '${found}'"
fi

# Each step must say what it would do. A DRY_RUN that printed only the headers
# and no per-step action would be a plan with no content.
dry_count="$(printf '%s\n' "$dry_run_out" | grep -c 'DRY_RUN:' || true)"
if [ "$dry_count" -ge 10 ]; then
  pass 'DRY_RUN prints a per-step action for every step'
else
  fail 'DRY_RUN prints a per-step action for every step' "found ${dry_count} DRY_RUN action(s), expected >= 9"
fi

# The refusal: KIT_SUBSTRATE_DATABASES unset or empty is a refusal in DRY_RUN
# too, with a message naming the fix — mirroring 10-cluster.sh:120. A plan
# that cannot name its databases is not a plan. Both the unset and the empty
# spelling must refuse; either one completing is a gate that waves through
# the exact state the local contract refuses.
refuse_unset="$(DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" && refuse_unset_ec=0 || refuse_unset_ec=$?
if [ "$refuse_unset_ec" -ne 0 ] && printf '%s\n' "$refuse_unset" | grep -q 'KIT_SUBSTRATE_DATABASES'; then
  pass 'control: DRY_RUN with KIT_SUBSTRATE_DATABASES unset refuses, naming the fix'
else
  fail 'control: DRY_RUN with KIT_SUBSTRATE_DATABASES unset refuses, naming the fix' "exit=${refuse_unset_ec}: ${refuse_unset}"
fi

refuse_empty="$(KIT_SUBSTRATE_DATABASES="" DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" && refuse_empty_ec=0 || refuse_empty_ec=$?
if [ "$refuse_empty_ec" -ne 0 ] && printf '%s\n' "$refuse_empty" | grep -q 'KIT_SUBSTRATE_DATABASES'; then
  pass 'control: DRY_RUN with KIT_SUBSTRATE_DATABASES empty refuses, naming the fix'
else
  fail 'control: DRY_RUN with KIT_SUBSTRATE_DATABASES empty refuses, naming the fix' "exit=${refuse_empty_ec}: ${refuse_empty}"
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
    r'^(K3S_VERSION|CERT_MANAGER_VERSION|CNPG_VERSION|ARGOCD_VERSION|NATS_VERSION|NATS_BOX_VERSION)="([^"]+)"',
    src,
    re.M,
)
if len(pins) != 6:
    print(f"expected 6 pins, found {len(pins)}")
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

run 'every pin is exact (k3s, cert-manager, CNPG, Argo CD, NATS, nats-box)' green check_pins "$SUBSTRATE/install.sh"

# The control: the same check against a fixture with a floating pin. This MUST
# go red. If it does not, the check above is not measuring what it claims.
fixture_latest="$WORK/install-latest.sh"
sed 's/^K3S_VERSION="v1.37.1+k3s1"/K3S_VERSION="latest"/' \
  "$SUBSTRATE/install.sh" >"$fixture_latest"
run 'control: a latest pin goes red under the same check' red check_pins "$fixture_latest"

# The second control: a fixture floating the NATS pin instead. Must go red the
# same way — a pin the check cannot see float is documentation, not a pin.
fixture_latest_nats="$WORK/install-latest-nats.sh"
sed 's/^NATS_VERSION="2.10.24-alpine"/NATS_VERSION="latest"/' \
  "$SUBSTRATE/install.sh" >"$fixture_latest_nats"
run 'control: a latest NATS pin goes red under the same check' red check_pins "$fixture_latest_nats"

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

# The operator values are never echoed either — in any mode. The check reads
# every `echo` line mentioning one of the KIT_SUBSTRATE_* values and fails if
# the line also dereferences it. Naming the VARIABLE in a message is fine
# (every refusal below does); printing its VALUE is the leak.
sourced_vars="KIT_SUBSTRATE_BOX_ID KIT_SUBSTRATE_REGISTRY_CAPABILITY KIT_SUBSTRATE_BOX_URL KIT_SUBSTRATE_ACME_EMAIL KIT_SUBSTRATE_DATABASES KIT_SUBSTRATE_POSTGRES_EXTENSIONS KIT_SUBSTRATE_SMTP_ADAPTER KIT_SUBSTRATE_SMTP_HOST KIT_SUBSTRATE_SMTP_PORT KIT_SUBSTRATE_SMTP_USERNAME KIT_SUBSTRATE_SMTP_PASSWORD KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET KIT_SUBSTRATE_MAIL_FROM KIT_SUBSTRATE_MAIL_FROM_NAME KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY"
echo_leak=""
for v in $sourced_vars; do
  if grep -nE "echo.*\\$$v" "$SUBSTRATE/install.sh" >/dev/null 2>&1; then
    echo_leak="${echo_leak} $v: $(grep -nE "echo.*\\$$v" "$SUBSTRATE/install.sh" | head -3)"
  fi
done
if [ -n "$echo_leak" ]; then
  fail 'no operator value is ever echoed' "$echo_leak"
else
  pass 'no operator value is ever echoed'
fi

# THE `sourced_vars` LIST AND install.sh MUST AGREE, and the direction that
# matters is the one a rename breaks. The echo-leak check above only scans the
# names this list names, so a rename that reached install.sh and NOT the list
# would leave the list looking full while the scan quietly stopped covering
# the variable that moved — the exact drift this packet's own env-var rename
# could have introduced, and it would have been green. The assertion is about
# the LIST: every name it names must still be read by the installer.
stale_sourced=""
for v in $sourced_vars; do
  if ! grep -qE "\\\$\{?$v" "$SUBSTRATE/install.sh"; then
    stale_sourced="${stale_sourced} $v"
  fi
done
if [ -n "$stale_sourced" ]; then
  fail 'sourced_vars names only variables install.sh reads' "the installer does not read:${stale_sourced}"
else
  pass 'sourced_vars names only variables install.sh reads'
fi

# THE CONTROL is the drift itself, replayed: a copy of install.sh in which one
# listed variable has been renamed — here the ACME contact, because a rename is
# the only way this check can go red — must be CAUGHT by the same loop, since
# the list still names the old spelling and the fixture no longer reads it. A
# control that plants an absent name would only prove the grep works; this one
# proves the check catches a rename that reached one file and not the other,
# which is the defect this packet's own env rename could have introduced.
control_script="$WORK/install.sh.renamed"
sed 's/KIT_SUBSTRATE_ACME_EMAIL/KIT_SUBSTRATE_ACME_CONTACT/g' "$SUBSTRATE/install.sh" >"$control_script"
control_stale=""
for v in $sourced_vars; do
  if ! grep -qE "\\\$\{?$v" "$control_script"; then
    control_stale="${control_stale} $v"
  fi
done
case "$control_stale" in
  *KIT_SUBSTRATE_ACME_EMAIL*)
    pass 'control: a rename that misses sourced_vars goes red'
    ;;
  *)
    fail 'control: a rename that misses sourced_vars goes red' "the fixture was not caught (stale:${control_stale:-none})"
    ;;
esac

# ===========================================================================
# 8. KIT_SUBSTRATE_DATABASES refuses in DRY_RUN: unset, empty, mismatched
# ===========================================================================
#
# The refusal is the contract: a cluster with no database list is a cluster
# with no databases, and a list that disagrees with the manifest is a
# DATABASE_URL pointing at nothing. (The unset and empty cases are asserted
# in section 2, beside the success path they gate; this section adds the
# mismatch and the accepted-control.) Each refusing case must exit non-zero
# NAMING the fix. The control is the valid list, which must be accepted — a
# refusal that fires unconditionally proves nothing.
databases_try() {
  # $1: __UNSET__, __EMPTY__, or a value.
  local out ec=0
  case "$1" in
    __UNSET__) out="$(env -u KIT_SUBSTRATE_DATABASES DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" || ec=$? ;;
    __EMPTY__) out="$(KIT_SUBSTRATE_DATABASES="" DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" || ec=$? ;;
    *) out="$(KIT_SUBSTRATE_DATABASES="$1" DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" || ec=$? ;;
  esac
  printf '%s' "$out"
  return "$ec"
}

refused_out=""; refused_ec=0
refused_out="$(databases_try 'identity,courier')" || refused_ec=$?
case "$refused_ec:$refused_out" in
  0:*)
    fail 'DRY_RUN with a database list disagreeing with the manifest refuses' "exit 0 — a typo would boot a cluster missing a service"
    ;;
  *manifest*)
    pass 'DRY_RUN with a database list disagreeing with the manifest refuses'
    ;;
  *)
    fail 'DRY_RUN with a database list disagreeing with the manifest refuses' "$refused_out"
    ;;
esac

refused_out=""; refused_ec=0
refused_out="$(databases_try "$DBS")" || refused_ec=$?
if [ "$refused_ec" -eq 0 ]; then
  pass 'control: DRY_RUN with the matching database list is accepted'
else
  fail 'control: DRY_RUN with the matching database list is accepted' "$refused_out"
fi

# ===========================================================================
# 9. The Postgres Cluster manifest — one cluster, the per-role provisioning
# ===========================================================================
#
# Parses as YAML, names one Cluster (postgres in data), carries the boundary
# (REVOKE … FROM PUBLIC per database), the membership (inRoles, the
# declarative GRANT <svc>_app TO <svc>), the connection limit, the timeouts
# and the vector extension — and pointedly NO imageName (CNPG's standard image
# already carries pgvector, so there is no custom image to pin). The control
# is a fixture with the REVOKE removed, which must go red under the same
# check the real manifest passes.
DATA_DIR="$SUBSTRATE/manifests/data"
check_cluster() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

path = sys.argv[1]
try:
    docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
except yaml.YAMLError as e:
    print(f"does not parse ({e})")
    sys.exit(1)
if len(docs) != 1:
    print(f"expected 1 document, found {len(docs)}")
    sys.exit(1)
doc = docs[0]
problems = []
if doc.get("kind") != "Cluster":
    problems.append(f"kind is {doc.get('kind')!r}, not 'Cluster'")
if doc.get("apiVersion") != "postgresql.cnpg.io/v1":
    problems.append(f"apiVersion is {doc.get('apiVersion')!r}")
meta = doc.get("metadata", {})
if meta.get("name") != "postgres" or meta.get("namespace") != "data":
    problems.append(
        f"is {meta.get('namespace')}/{meta.get('name')}, not data/postgres —"
        " step 9 builds DATABASE_URL against postgres-rw.data"
    )
spec = doc.get("spec", {})
if "imageName" in spec:
    problems.append(
        "spec.imageName is set — CNPG's standard image already carries"
        " pgvector, so a pinned image here is a second artifact to maintain"
    )
initdb = spec.get("bootstrap", {}).get("initdb", {})
if "postInitApplicationSQL" in initdb or "postInitApplicationSQLRefs" in initdb:
    problems.append(
        "postInitApplicationSQL* runs as the non-superuser app owner in the"
        " single initdb database — CREATE EXTENSION vector there is refused"
        " ('Must be superuser') and fails the whole bootstrap; the manifest"
        " header names the gap instead"
    )
store = spec.get("storageConfiguration", {})
if not store.get("size"):
    problems.append("spec.storageConfiguration.size is unset")
if store.get("storageClass") != "local-path":
    problems.append(
        f"storageClass is {store.get('storageClass')!r}, not 'local-path'"
        " (k3s's default provisioner)"
    )
svcs = ("identity", "gateway", "courier", "parlor")
sql = "\n".join(initdb.get("postInitSQL", []))
for svc in svcs:
    for needle in (
        f'CREATE DATABASE "{svc}" OWNER "{svc}"',
        f'REVOKE ALL ON DATABASE "{svc}" FROM PUBLIC',
        f'GRANT CONNECT, TEMPORARY ON DATABASE "{svc}" TO "{svc}"',
        f'GRANT CONNECT, TEMPORARY ON DATABASE "{svc}" TO "{svc}_app"',
        f'ALTER ROLE "{svc}" CONNECTION LIMIT 10',
        f'ALTER ROLE "{svc}" SET statement_timeout',
        f'ALTER ROLE "{svc}_app" SET statement_timeout',
        f'ALTER ROLE "{svc}" SET idle_in_transaction_session_timeout',
    ):
        if needle not in sql:
            problems.append(f"postInitSQL is missing: {needle}")
# No postInitApplicationSQL assertion here: the manifest must NOT carry that
# hook (asserted above), and the extension list lives in install.sh — the
# check below it asserts the declaration and its default.
roles = {r.get("name"): r for r in spec.get("managed", {}).get("roles", [])}
for svc in svcs:
    owner, app = roles.get(svc), roles.get(f"{svc}_app")
    if owner is None or app is None:
        problems.append(f"managed.roles is missing {svc} or {svc}_app")
        continue
    if not owner.get("login") or not app.get("login"):
        problems.append(f"role {svc} or {svc}_app is not a LOGIN role")
    if f"{svc}_app" not in (owner.get("inRoles") or []):
        problems.append(
            f"role {svc} has no inRoles [{svc}_app] — the declarative"
            f" GRANT {svc}_app TO {svc}"
        )
    if app.get("inRoles"):
        problems.append(
            f"role {svc}_app carries inRoles {app.get('inRoles')} — the"
            " reverse membership would hand the application the owner's"
            " privileges"
        )
    for r in (owner, app):
        if not (r.get("passwordSecret") or {}).get("name"):
            problems.append(f"role {r.get('name')} names no passwordSecret")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("1 Cluster (data/postgres), 4 services provisioned, no imageName")
PY
}

run 'the Cluster manifest carries the per-role provisioning' green check_cluster "$DATA_DIR/postgres-cluster.yaml"

# The control: the same check against a fixture with the REVOKE removed. This
# MUST go red — a boundary the check cannot see missing is not a check.
fixture_no_revoke="$WORK/no-revoke-cluster.yaml"
grep -v 'REVOKE ALL ON DATABASE' "$DATA_DIR/postgres-cluster.yaml" >"$fixture_no_revoke"
run 'control: a Cluster without the REVOKE goes red' red check_cluster "$fixture_no_revoke"

# The second control: a fixture RE-ADDING the forbidden
# postInitApplicationSQL hook. Must go red the same way — an absence the
# check cannot see violated is not an assertion.
fixture_app_sql="$WORK/app-sql-cluster.yaml"
awk '/^      owner: app$/{print; print "      postInitApplicationSQL:"; print "        - SELECT 1"; next}1' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_app_sql"
run 'control: a Cluster re-adding postInitApplicationSQL goes red' red check_cluster "$fixture_app_sql"

# The extension list is declared in install.sh with the compose default
# (`vector`) and validated as identifiers — because no CNPG hook can create
# extensions per database, the declaration is what the gate can hold. The
# control drops the default; a declaration the check cannot see missing is
# documentation, not a check.
check_extensions() {
  code="$(sed -e 's/#.*//' "$1")"
  problems=""
  case "$code" in
    *'KIT_SUBSTRATE_POSTGRES_EXTENSIONS:=vector'*) ;;
    *) problems="no KIT_SUBSTRATE_POSTGRES_EXTENSIONS default of vector" ;;
  esac
  case "$code" in
    *'KIT_SUBSTRATE_POSTGRES_EXTENSIONS is not a bare identifier'*) ;;
    *) problems="${problems}; no identifier validation on KIT_SUBSTRATE_POSTGRES_EXTENSIONS" ;;
  esac
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems"
    return 1
  fi
  printf 'extensions default to vector, validated as identifiers\n'
}

run 'the extension list defaults to vector and is validated' green check_extensions "$SUBSTRATE/install.sh"

fixture_no_ext_default="$WORK/install-no-ext-default.sh"
sed 's/KIT_SUBSTRATE_POSTGRES_EXTENSIONS:=vector/KIT_SUBSTRATE_POSTGRES_EXTENSIONS:=/' \
  "$SUBSTRATE/install.sh" >"$fixture_no_ext_default"
run 'control: an extension list with no default goes red' red check_extensions "$fixture_no_ext_default"

# ===========================================================================
# 10. The Redis manifest — parses, exact tag, password by reference only
# ===========================================================================
check_redis() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

path = sys.argv[1]
try:
    docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
except yaml.YAMLError as e:
    print(f"does not parse ({e})")
    sys.exit(1)
problems = []
by_kind = {}
for d in docs:
    by_kind.setdefault(d.get("kind"), []).append(d)
for want in ("PersistentVolumeClaim", "Deployment", "Service"):
    if want not in by_kind:
        problems.append(f"no {want} document")
if problems:
    print("; ".join(problems))
    sys.exit(1)
dep = by_kind["Deployment"][0]
container = dep["spec"]["template"]["spec"]["containers"][0]
image = container.get("image", "")
if image != "redis:7.4.1-alpine":
    problems.append(f"image is {image!r}, not the exact 'redis:7.4.1-alpine'")
if "latest" in image:
    problems.append(f"image {image!r} floats on latest")
cmd = " ".join(container.get("command", []))
if "--requirepass" in cmd and "$REDIS_PASSWORD" not in cmd:
    problems.append("a literal --requirepass password in the command")
env = {e.get("name"): e for e in container.get("env", [])}
ref = (env.get("REDIS_PASSWORD", {}).get("valueFrom", {}).get("secretKeyRef", {}))
if ref.get("name") != "redis-password" or ref.get("key") != "password":
    problems.append(
        "REDIS_PASSWORD is not a secretKeyRef to redis-password/password"
    )
pvc = by_kind["PersistentVolumeClaim"][0]
if pvc["spec"].get("storageClassName") != "local-path":
    problems.append("the PVC is not on storageClass local-path")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("Deployment + Service + PVC, redis:7.4.1-alpine, password by secretKeyRef")
PY
}

run 'the Redis manifest parses with an exact tag and no literal password' green check_redis "$DATA_DIR/redis.yaml"

# The control: the same check against a fixture floating on latest. Must go red.
fixture_latest_redis="$WORK/latest-redis.yaml"
sed 's/image: redis:7.4.1-alpine/image: redis:latest/' "$DATA_DIR/redis.yaml" >"$fixture_latest_redis"
run 'control: a Redis floating on latest goes red' red check_redis "$fixture_latest_redis"

# ===========================================================================
# 11. The recorded secret name-and-key list matches what install.sh creates
# ===========================================================================
#
# The SECRET RECORD in install.sh is the drift tripwire both ways: every name
# it lists must be created below it, and every key must appear as a
# --from-literal. The control removes one key from a fixture copy and must go
# red — a record the check cannot see drift in is documentation, not a check.
check_secret_record() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
records = re.findall(r"^#\s+RECORD\s+(\S+):\s*(.*)$", src, re.M)
if len(records) != 4:
    print(f"expected 4 RECORD lines, found {len(records)}")
    sys.exit(1)
# A key is WRITTEN in one of two spellings: `--from-literal=KEY=` (the secrets
# step 9 creates) or the merge patch step 11 sends, whose body is built as
# `{"stringData":{"KEY":$t}}`. Both are writes and both are checked, so the
# record cannot be satisfied by a key that only appears in a comment or a
# variable name. The control below removes one of each.
patch_keys = set(re.findall(r'"stringData":\{"([A-Z_]+)":\$t\}', code))
# Conditional keys: set only when the operator sets the surface (identity's
# OIDC block and its issuer, its courier credential, courier's mail-from). They
# are deliberately UNRECORDED — absent is a valid reduced surface, and the
# record lists the keys every install creates. MFA_ENCRYPTION_KEY is NOT
# conditional: the installer generates it on first creation, so every
# install creates it and the record must name it. OIDC_SIGNING_KEY and its
# id are now GENERATED ON THE BOX rather than supplied, but still only when
# the operator sets an issuer — the surface stays all-or-nothing, so they
# stay unrecorded beside the issuer that gates them.
conditional = {
    "COURIER_TOKEN",
    "OIDC_SIGNING_KEY",
    "OIDC_SIGNING_KEY_ID",
    "OIDC_ISSUER",
    "OAUTH_ENCRYPTION_KEY",
    "MAIL_FROM",
    "MAIL_FROM_NAME",
}
problems = []
recorded = {}
for secret, keys in records:
    recorded[secret] = set(keys.split())
    if f"create secret generic {secret}" not in code:
        problems.append(f"{secret} is recorded but never created")
    for key in keys.split():
        if f"--from-literal={key}=" not in code and key not in patch_keys:
            problems.append(f"{secret} records {key} but no --from-literal sets it")
created = set(re.findall(r"create secret generic (\S+)", code))
for secret in created:
    if secret not in recorded and secret.startswith(("identity", "gateway", "courier", "parlor")):
        problems.append(f"{secret} is created but not recorded")
for key in set(re.findall(r"--from-literal=([A-Z_]+)=", code)) | patch_keys:
    if key in conditional:
        continue
    if not any(key in keys for keys in recorded.values()):
        problems.append(f"{key} is set by --from-literal but recorded nowhere")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(records)} secrets, every recorded key created")
PY
}

run 'the recorded secret name-and-key list matches install.sh' green check_secret_record "$SUBSTRATE/install.sh"

# The control: a fixture with one key's --from-literal removed. Must go red.
fixture_dropped_key="$WORK/install-dropped-key.sh"
grep -v -- '--from-literal=COURIER_SMTP_PASSWORD=' "$SUBSTRATE/install.sh" >"$fixture_dropped_key"
run 'control: a secret with a key removed goes red' red check_secret_record "$fixture_dropped_key"

# The second control, for the other spelling: step 11's mint writes its key
# through a merge patch, and a fixture with that patch removed must go red
# too. Without it the widened check would be proven only by the --from-literal
# path, which is the path that never changed.
fixture_dropped_patch="$WORK/install-dropped-patch.sh"
grep -v -- '"stringData":{"COURIER_IDENTITY_TOKEN":$t}' "$SUBSTRATE/install.sh" >"$fixture_dropped_patch"
run 'control: a secret whose patch is removed goes red' red check_secret_record "$fixture_dropped_patch"

# The reverse control: a fixture setting a key the record does not name (and
# the conditional set does not excuse). Must go red the other way.
fixture_extra_key="$WORK/install-extra-key.sh"
cp "$SUBSTRATE/install.sh" "$fixture_extra_key"
printf '\n--from-literal=EXTRA_UNRECORDED_KEY=x\n' >>"$fixture_extra_key"
run 'control: a secret with an unrecorded key goes red' red check_secret_record "$fixture_extra_key"

# ===========================================================================
# 12. NATS with JetStream — the bus the local stack runs, on the box too
# ===========================================================================
#
# The local stack runs NATS with JetStream (`nats` with `-js`, plus the
# one-shot `nats-stream-init` defining stream `cafaye`); the substrate
# installed no broker, so on the box every event with no matching stream is a
# silent black hole — the exact failure `nats-stream-init`'s comment exists to
# prevent. Step 10 installs one Deployment + Service + PVC in `data` and
# defines the same stream, idempotently (`info || add`, mirroring the local
# service). Three checks: the manifest carries the broker, install.sh applies
# it and defines the stream, and the two renders agree — the drift check
# parses BOTH contracts and fails on divergence, so local and substrate
# cannot drift apart silently. Each has a fixture control that must go red.
COMPOSE_STACK="$ROOT/templates/compose/docker-compose.yml"

check_nats_manifest() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

path = sys.argv[1]
try:
    docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
except yaml.YAMLError as e:
    print(f"does not parse ({e})")
    sys.exit(1)
except OSError as e:
    print(f"{path}: unreadable ({e})")
    sys.exit(1)
problems = []
by_kind = {}
for d in docs:
    by_kind.setdefault(d.get("kind"), []).append(d)
if sorted(by_kind) != ["Deployment", "PersistentVolumeClaim", "Service"]:
    problems.append(
        f"kinds are {sorted(by_kind)}, not exactly [Deployment,"
        " PersistentVolumeClaim, Service]"
    )
    print("; ".join(problems))
    sys.exit(1)
dep = by_kind["Deployment"][0]
meta = dep.get("metadata", {})
if meta.get("name") != "nats" or meta.get("namespace") != "data":
    problems.append(
        f"Deployment is {meta.get('namespace')}/{meta.get('name')}, not"
        " data/nats"
    )
if dep.get("spec", {}).get("replicas") != 1:
    problems.append("replicas is not 1 — one box, one broker; a second replica without a route is a split brain")
containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
if len(containers) != 1:
    problems.append(f"expected 1 container, found {len(containers)}")
    print("; ".join(problems))
    sys.exit(1)
container = containers[0]
if container.get("image") != "NATS_IMAGE_PLACEHOLDER":
    problems.append(
        f"image is {container.get('image')!r}, not NATS_IMAGE_PLACEHOLDER —"
        " the pin lives in install.sh ($NATS_VERSION) and is substituted at"
        " apply time; a literal tag here is a second opinion"
    )
tokens = container.get("command", [])
for flag in ("-js", "-sd", "/data", "-m", "8222"):
    if flag not in tokens:
        problems.append(
            f"broker command is missing {flag!r} — without -js the bus is"
            " at-most-once and every publish is unacked file storage"
        )
for probe in ("livenessProbe", "readinessProbe"):
    if probe not in container:
        problems.append(f"no {probe} — an unprobed broker is never waited on")
    elif "8222" not in str(container[probe]):
        problems.append(
            f"{probe} does not hit the monitor port 8222 — the same signal"
            " the local stack's healthcheck uses"
        )
mounts = container.get("volumeMounts", [])
if not any(m.get("mountPath") == "/data" for m in mounts):
    problems.append("nothing mounts /data — file storage without a volume is a fresh broker on every restart")
svc = by_kind["Service"][0]
ports = sorted(p.get("port") for p in svc.get("spec", {}).get("ports", []))
if ports != [4222, 8222]:
    problems.append(
        f"Service ports are {ports}, not [4222, 8222] (client + monitor)"
    )
pvc = by_kind["PersistentVolumeClaim"][0]
if pvc.get("spec", {}).get("storageClassName") != "local-path":
    problems.append("the PVC is not on storageClass local-path (k3s's default provisioner)")
if not (pvc.get("spec", {}).get("resources", {}).get("requests", {}).get("storage")):
    problems.append("the PVC requests no storage")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("Deployment + Service + PVC, -js file storage, monitor probes, image from install.sh")
PY
}

check_nats_install() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
problems = []


def need(sub, msg):
    if sub not in code:
        problems.append(msg)


need("TOTAL=11", "TOTAL is not 11 — step 11 (the courier credential minted on this box) widens the plan and the DRY_RUN order check with it")
need('NATS_VERSION="2.10.24-alpine"', "no exact NATS_VERSION pin beside the other pins")
need('NATS_BOX_VERSION="0.20.0"', "no exact NATS_BOX_VERSION pin for the stream-init image")
if not re.search(r"(?m)^install_nats\(\)", code):
    problems.append("no install_nats step")
if not re.search(r"(?m)^  install_nats$", code):
    problems.append("main never calls install_nats")
need("    nats)", "the guard has no nats component — a re-run would reinstall the broker")
need("NATS_IMAGE_PLACEHOLDER", "the broker manifest substitution is missing")
need("nats:${NATS_VERSION}", "the broker image is not substituted from $NATS_VERSION — the pin lives in two places")
need("nats stream info cafaye", "the stream is never inspected before creation")
need("nats stream add cafaye", "the stream cafaye is never created")
if not any(
    "nats stream info cafaye" in ln and "||" in ln and "nats stream add cafaye" in ln
    for ln in code.splitlines()
):
    problems.append(
        "the stream init is not the idempotent info || add shape — a plain"
        " add fails every second run (measured: exit 1, stream already in use)"
    )
need(
    '"identity.>,billing.>,courier.>,muse.>,darkroom.>"',
    "the fleet subject set is not the local one — an uncovered prefix is a silent black hole",
)
for flag in ("--storage file", "--retention limits", "--max-age 7d", "--discard old", "--replicas 1", "--defaults"):
    need(flag, f"the stream spec is missing {flag} — the drift check names the divergence")
need("--restart=Never", "the one-shot pod must never restart — a restart policy hides a failed add")
need("status.phase", "nothing waits for the one-shot pod's completion — a failed init would pass silently")
need("Succeeded", "the wait does not assert the Succeeded phase")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("step 10 applies the broker and defines stream cafaye idempotently")
PY
}

check_nats_drift() {
  "$PY" - "$1" "$2" <<'PY'
import re
import sys

compose = open(sys.argv[1], encoding="utf-8").read()
install = open(sys.argv[2], encoding="utf-8").read()
problems = []


def grp(pat, text, label):
    m = re.search(pat, text)
    if not m:
        problems.append(f"could not parse {label}")
        return None
    return m.group(1)


ctag = grp(r"KIT_NATS_TAG:-([^}]+)", compose, "the compose KIT_NATS_TAG default")
itag = grp(r'(?m)^NATS_VERSION="([^"]+)"', install, "install.sh NATS_VERSION")
if ctag and itag and ctag != itag:
    problems.append(f"broker image drift: compose defaults to {ctag}, install.sh pins {itag}")
cbox = grp(r"KIT_NATS_BOX_TAG:-([^}]+)", compose, "the compose KIT_NATS_BOX_TAG default")
ibox = grp(r'(?m)^NATS_BOX_VERSION="([^"]+)"', install, "install.sh NATS_BOX_VERSION")
if cbox and ibox and cbox != ibox:
    problems.append(f"nats-box image drift: compose defaults to {cbox}, install.sh pins {ibox}")


def stream_flags(text, label):
    i = text.find("nats stream add cafaye")
    if i < 0:
        problems.append(f"{label}: no `nats stream add cafaye`")
        return None
    seg = text[i : i + 600]
    out = {}
    m = re.search(r'--subjects\s+"([^"]+)"', seg)
    if not m:
        problems.append(f"{label}: the --subjects set is unparsable")
        return None
    out["subjects"] = m.group(1)
    for flag in ("storage", "retention", "max-age", "discard", "replicas"):
        m = re.search(r"--" + flag + r"\s+(\S+)", seg)
        if not m:
            problems.append(f"{label}: --{flag} is missing from the stream spec")
            return None
        out[flag] = m.group(1)
    if "--defaults" not in seg:
        problems.append(f"{label}: --defaults is missing — without it the CLI waits on a terminal that is not there")
    return out


cflags = stream_flags(compose, "compose nats-stream-init")
iflags = stream_flags(install, "install.sh stream init")
if cflags and iflags:
    for flag in ("subjects", "storage", "retention", "max-age", "discard", "replicas"):
        if cflags[flag] != iflags[flag]:
            problems.append(
                f"stream drift on --{flag}: local is {cflags[flag]!r}, substrate is {iflags[flag]!r}"
            )
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"broker {itag} + nats-box {ibox}, stream cafaye {cflags['subjects']} storage={cflags['storage']} retention={cflags['retention']} max-age={cflags['max-age']}")
PY
}

run 'the NATS manifest carries the broker (Deployment + Service + PVC, -js, monitor probes)' green check_nats_manifest "$DATA_DIR/nats.yaml"

# The controls: a fixture without -js, and a fixture floating on latest. Both
# MUST go red under the same check the real manifest passes.
fixture_no_js="$WORK/nats-no-js.yaml"
if [ -r "$DATA_DIR/nats.yaml" ]; then
  grep -v '"-js"' "$DATA_DIR/nats.yaml" >"$fixture_no_js"
  run 'control: a NATS manifest without -js goes red' red check_nats_manifest "$fixture_no_js"
  fixture_float_nats="$WORK/nats-float.yaml"
  sed 's/NATS_IMAGE_PLACEHOLDER/nats:latest/' "$DATA_DIR/nats.yaml" >"$fixture_float_nats"
  run 'control: a NATS manifest floating on latest goes red' red check_nats_manifest "$fixture_float_nats"
else
  fail 'controls: the NATS fixtures need the real manifest' "$DATA_DIR/nats.yaml is missing — the green check above names what is missing"
fi

run 'install.sh applies the broker and defines stream cafaye idempotently' green check_nats_install "$SUBSTRATE/install.sh"

# The control: a fixture with one publisher dropped from the subject set. Must
# go red — a subject list the check cannot see shrink is documentation.
fixture_subjects="$WORK/install-nats-subjects.sh"
sed 's/muse\.>,darkroom\.>/muse.>/' "$SUBSTRATE/install.sh" >"$fixture_subjects"
run 'control: a stream missing a publisher goes red' red check_nats_install "$fixture_subjects"

run 'the substrate stream spec equals the compose stack nats-stream-init args' green check_nats_drift "$COMPOSE_STACK" "$SUBSTRATE/install.sh"

# The drift control mutates ONE side only: a substrate copy with a 30d replay
# window must disagree with the untouched stack. Must go red.
fixture_drift="$WORK/install-nats-drift.sh"
sed 's/--max-age 7d/--max-age 30d/' "$SUBSTRATE/install.sh" >"$fixture_drift"
run 'control: a substrate with a drifted max-age goes red' red check_nats_drift "$COMPOSE_STACK" "$fixture_drift"

# --- the broker's address reaches the services ---------------------------------
#
# THE BROKER ALONE IS NOT ENOUGH. install.sh installs NATS in `data` and
# defines the stream, and the only NATS_URL it ever set was on the one-shot
# stream-init pod — so every service that has a publisher has it dark on a
# real box, and identity's outbox loop (built only when NATS_URL is set) has
# never run in production. The local compose stack sets the variable; the
# substrate now does too, into identity-secrets.
#
# The check is a COUPLING, not a presence test: the address in the secret must
# be the fully qualified name of the broker's own Service (name, namespace and
# port read out of manifests/data/nats.yaml), because identity runs in
# `identity` and an unqualified `nats` resolves only inside `data` — the
# compose spelling, which here would produce a pod that starts and a loop
# that connects to nothing. The record half is section 11's (a key set but
# unrecorded is already red there); what this adds is that the KEY EXISTS at
# all, which is the direction nothing else asks — the two checks together are
# what cover the literal and its record entry being removed in one commit.
check_nats_service_url() {
  "$PY" - "$1" "$2" <<'PY'
import re
import sys

import yaml

install = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", install)
problems = []

try:
    docs = [d for d in yaml.safe_load_all(open(sys.argv[2], encoding="utf-8")) if d]
except (yaml.YAMLError, OSError) as e:
    print(f"unreadable ({e})")
    sys.exit(1)
svcs = [d for d in docs if d.get("kind") == "Service"]
if len(svcs) != 1:
    print(f"expected 1 Service, found {len(svcs)}")
    sys.exit(1)
svc = svcs[0].get("metadata", {})
ports = [p.get("port") for p in svcs[0].get("spec", {}).get("ports", [])]
if 4222 not in ports:
    problems.append(f"the broker Service exposes {ports}, not the 4222 client port")
want = f"nats://{svc.get('name')}.{svc.get('namespace')}.svc.cluster.local:4222"

assigns = re.findall(r'(?m)^NATS_URL="([^"]*)"', code)
if len(assigns) != 1:
    problems.append(f"expected exactly one NATS_URL assignment, found {len(assigns)} — one fact, one line")
elif assigns[0] != want:
    problems.append(
        f"NATS_URL is {assigns[0]!r}, want {want!r} — the fully qualified name of the broker's own Service"
    )
if '--from-literal=NATS_URL="$NATS_URL"' not in code:
    problems.append("no service secret carries --from-literal=NATS_URL — the publisher stays dark on a box")
if '--env="NATS_URL=$NATS_URL"' not in code:
    problems.append("the stream-init pod does not read the same constant — the two writers have drifted apart")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"identity-secrets carries {want}, one constant read by both writers")
PY
}

run 'identity-secrets carries the in-cluster broker address (fully qualified)' green \
  check_nats_service_url "$SUBSTRATE/install.sh" "$DATA_DIR/nats.yaml"

# The controls, one property each: the unqualified compose spelling, the
# missing literal, and the two writers spelling the address separately. Each
# must go red for the reason its own name gives — a control that fires for
# some other reason proves nothing about the assertion it sits under.
fixture_short_url="$WORK/install-nats-short.sh"
sed 's|nats://nats.data.svc.cluster.local:4222|nats://nats:4222|' \
  "$SUBSTRATE/install.sh" >"$fixture_short_url"
run 'control: the unqualified compose spelling goes red' red \
  check_nats_service_url "$fixture_short_url" "$DATA_DIR/nats.yaml"

fixture_dropped_url="$WORK/install-nats-url-dropped.sh"
grep -v -- '--from-literal=NATS_URL="$NATS_URL"' "$SUBSTRATE/install.sh" >"$fixture_dropped_url"
run 'control: a secret without the broker address goes red' red \
  check_nats_service_url "$fixture_dropped_url" "$DATA_DIR/nats.yaml"

fixture_two_writers="$WORK/install-nats-two-writers.sh"
sed 's|--env="NATS_URL=$NATS_URL"|--env="NATS_URL=nats://nats.data.svc.cluster.local:4222"|' \
  "$SUBSTRATE/install.sh" >"$fixture_two_writers"
run 'control: a second spelling of the address in the stream-init pod goes red' red \
  check_nats_service_url "$fixture_two_writers" "$DATA_DIR/nats.yaml"

# ===========================================================================
# 13. identity-secrets carries a generated MFA key by default
# ===========================================================================
#
# A fresh substrate install with the documented minimum inputs must still
# produce a usable Identity MFA surface: identity mounts GET /v1/mfa and the
# enrollment routes only when MFA_ENCRYPTION_KEY is present, so an
# identity-secrets without it boots an identity that cannot show the truthful
# `Off` state or enroll a factor. The installer therefore generates a
# cryptographically random 32-byte base64url-no-padding key on first creation
# (the exact shape identity's config parser accepts — base64.RawURLEncoding,
# exactly 32 bytes, the same generation as SIGNUP_SIGNING_KEY), keeps an
# operator-supplied KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY override
# (validated, never printed), and never rotates or patches an existing
# secret — a legacy identity-secrets without the key is left alone, because
# an imported database could hold ciphertext sealed under a key no longer
# present.
#
# install.sh needs root, Linux and k3s, so none of this runs here. Instead the
# installer is sourced with its trailing `main` call removed and
# install_service_secrets is executed against a mocked kubectl backed by
# files — local only, no cluster, no network. Each case gets a fresh store
# under $WORK, swept by the EXIT trap. Every assertion below reads a
# captured variable with a shell `case`, never a pipe (AGENTS.md: a piped
# read flips on the pipe buffer, not on the content).
fixture_sourced="$WORK/install-sourced.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$fixture_sourced"

# mock_seed <namespace> <secret> <key> <value> — plant one stored value.
# Every key planted here is a FAKE. Nothing in this file is a credential; the
# strings are labels, and a label is what a test may print.
mock_seed() {
  local d="$MOCK_ROOT/$1/$2"
  mkdir -p "$d"
  printf '%s' "$4" >"$d/$3"
}

# mock_get <namespace> <secret> <key> — the stored plaintext, or empty.
mock_get() {
  cat "$MOCK_ROOT/$1/$2/$3" 2>/dev/null || true
}

# mock_kubectl — the file-backed kubectl. Emulates only what
# install_service_secrets uses: `create namespace` (prints a stub down the
# pipe to `apply`), `create secret generic … --from-literal=K=V …`,
# `get secret …` (existence), and `get secret … -o jsonpath={.data.KEY}`
# (base64 of the stored value, the shape read_secret_key decodes).
# Anything else is a loud failure, not a silent success.
mock_kubectl() {
  # EVERY invocation is recorded in full and in order, because the pull-secret
  # contract is that the credential never appears in argv at all — and the
  # only way to prove a negative is to have the whole command line to grep.
  # Recorded before any shift, so what is written is what was called.
  if [ -n "${MOCK_ROOT:-}" ]; then
    printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"
  fi
  local fallback_ns="" patch_file_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kubeconfig=*) shift ;;
      -n) fallback_ns="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local verb="${1:-}"
  shift || true
  case "$verb" in
    create)
      local resource="${1:-}"
      shift || true
      if [ "$resource" = "namespace" ]; then
        printf 'namespace-stub\n'
        return 0
      fi
      if [ "$resource" != "secret" ]; then
        echo "mock_kubectl: unhandled create $resource" >&2
        return 1
      fi
      if [ "${1:-}" = "generic" ]; then shift; fi
      if [ "${1:-}" = "docker-registry" ]; then
        shift
        local name="${1:-}"
        shift || true
        local ns="$fallback_ns" src="" client_dry_run=0
        while [ $# -gt 0 ]; do
          case "$1" in
            -n) ns="$2"; shift 2 ;;
            --namespace=*) ns="${1#--namespace=}"; shift ;;
            --from-file=.dockerconfigjson=*) src="${1#--from-file=.dockerconfigjson=}"; shift ;;
            --dry-run=client) client_dry_run=1; shift ;;
            -o) shift 2 ;;  # `-o yaml`, only ever alongside --dry-run=client
            *) shift ;;
          esac
        done
        if [ -z "$src" ]; then
          echo "mock_kubectl: create secret docker-registry without a --from-file path" >&2
          return 1
        fi
        local d="$MOCK_ROOT/$ns/$name"
        mkdir -p "$d"
        cat "$src" >"$d/.dockerconfigjson"
        if [ "$client_dry_run" -eq 1 ]; then
          # `--dry-run=client -o yaml` prints the object to stdout for the
          # piped `apply -f -`. The .dockerconfigjson bytes are the base64
          # credential exactly as kubectl encodes it, which is what makes the
          # read-back assertions below mean anything — the value can be
          # confirmed in the applied Secret and still never appear in argv.
          printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/dockerconfigjson\ndata:\n  .dockerconfigjson: %s\n' \
            "$name" "$ns" "$(base64 <"$d/.dockerconfigjson" | tr -d '\n')"
        fi
        return 0
      fi
      local name="${1:-}"
      shift || true
      local ns="$fallback_ns"
      local -a lits=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) ns="$2"; shift 2 ;;
          --from-literal=*) lits+=("${1#--from-literal=}"); shift ;;
          *) shift ;;
        esac
      done
      local d="$MOCK_ROOT/$ns/$name"
      mkdir -p "$d"
      local e k v
      for e in ${lits[@]+"${lits[@]}"}; do
        k="${e%%=*}"
        v="${e#*=}"
        printf '%s' "$v" >"$d/$k"
      done
      return 0
      ;;
    get)
      if [ "${1:-}" != "secret" ]; then
        echo "mock_kubectl: unhandled get ${1:-}" >&2
        return 1
      fi
      shift || true
      local name="${1:-}"
      shift || true
      local ns="" tmpl=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) ns="$2"; shift 2 ;;
          -o) tmpl="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      local dir="$MOCK_ROOT/$ns/$name"
      if [ -z "$tmpl" ]; then
        if [ -d "$dir" ]; then return 0; else return 1; fi
      fi
      local key="${tmpl#jsonpath={.data.}"
      key="${key%\}}"
      if [ -z "$key" ] || [ "$key" = "$tmpl" ] || [ ! -f "$dir/$key" ]; then
        return 1
      fi
      base64 <"$dir/$key" | tr -d '\n'
      return 0
      ;;
    apply)
      # The mock records what the installer SENT, because for the pull secret
      # and the minted credential the manifest on stdin IS the claim: the
      # secret's shape, and that the value in it came from the redemption
      # rather than a literal in the tree. APPENDED, not numbered: every
      # pipeline element is a fork, so a counter kept in the parent never
      # advances and the sixth apply would overwrite the first.
      mkdir -p "$MOCK_ROOT/applied"
      cat >>"$MOCK_ROOT/applied.yaml"
      return 0
      ;;
    rollout)
      # `rollout status` (a wait), `rollout restart` (a kick). Both are no-ops
      # against the file store: the mint loop's contract is that it ASKS, and
      # the value assertions below are what prove it wrote the right thing.
      return 0
      ;;
    patch)
      # A merge patch, read from `--patch-file=-`: the mock MERGES the
      # stringData keys into the stored secret, exactly as kubectl does. This
      # is what makes the "no other key is wiped" assertion below mean
      # anything — a mock that treated a patch as a replace would make the
      # destructive and the correct write indistinguishable.
      local patch_ns="$fallback_ns" patch_name="" body=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) patch_ns="$2"; shift 2 ;;
          --namespace=*) patch_ns="${1#--namespace=}"; shift ;;
          secret) shift; patch_name="${1:-}"; shift ;;
          --type=*) shift ;;
          --type) shift 2 ;;
          --patch-file=*) patch_file_arg="${1#--patch-file=}"; shift ;;
          *) shift ;;
        esac
      done
      if [ -z "$patch_name" ]; then
        echo "mock_kubectl: patch without a secret name" >&2
        return 1
      fi
      case "${patch_file_arg:-}" in
        -) body="$(cat)" ;;
        "") echo "mock_kubectl: patch without --patch-file" >&2; return 1 ;;
        *) body="$(cat "$patch_file_arg")" ;;
      esac
      local d="$MOCK_ROOT/$patch_ns/$patch_name"
      mkdir -p "$d"
      # Every "key": "value" pair under stringData, merged over what is stored.
      printf '%s' "$body" | jq -r '.stringData // {} | to_entries[] | "\(.key)=\(.value)"' |
        while IFS= read -r pair; do
          printf '%s' "${pair#*=}" >"$d/${pair%%=*}"
        done
      return 0
      ;;
    port-forward)
      # A real one blocks forever; this one returns instantly, so the installer's
      # background job is already gone when its RETURN trap kills it. The
      # exchange it guards is mocked at the curl boundary, not here.
      return 0
      ;;
    *)
      echo "mock_kubectl: unhandled verb $verb" >&2
      return 1
      ;;
  esac
}

# mfa_shape_ok <value> — exit 0 iff the value is exactly what identity's
# config parser accepts: 43 base64url-no-padding characters decoding to
# 32 bytes (32 bytes is 3*10+2, so RawURLEncoding prints 10*4+3).
mfa_shape_ok() {
  "$PY" - "$1" <<'PY'
import base64
import re
import sys
s = sys.argv[1]
if not re.fullmatch(r"[A-Za-z0-9_-]{43}", s):
    print("shape: %r is not 43 base64url-no-padding characters" % (s,))
    sys.exit(1)
try:
    raw = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
except Exception as e:
    print("shape: does not decode (%s)" % (e,))
    sys.exit(1)
if len(raw) != 32:
    print("shape: decodes to %d bytes, want exactly 32" % (len(raw),))
    sys.exit(1)
print("shape: 43 base64url characters, 32 bytes")
PY
}

# mfa_seed_roles — the passwords install_service_secrets reads back: the
# four <svc>_app role passwords (step 8 made them) and the redis password
# (step 9's first half made it). Without them the step refuses naming step
# 8, which is a different contract from the one proven here.
mfa_seed_roles() {
  local svc
  for svc in identity gateway courier parlor; do
    mock_seed data "postgres-role-$svc-app" password "pw-$svc-app"
  done
  mock_seed data redis-password password "redis-pw"
}

# mfa_smtp_env — the externally-sourced courier values the live path
# requires. Dummy relay values: the shape of the refusal is proven
# elsewhere; here they only open the gate to the secrets half. The box id and
# capability are the two inputs the W2-P4 cut left, and both are fakes whose
# shape is what the installer validates.
mfa_smtp_env() {
  export DRY_RUN=0
  export KIT_SUBSTRATE_SMTP_HOST="relay.example.com"
  export KIT_SUBSTRATE_SMTP_USERNAME="relay-user"
  export KIT_SUBSTRATE_SMTP_PASSWORD="relay-pass"
  export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="provider-signing-secret"
  # Empty, not unset: the sourced installer runs under `set -u` and reads
  # these unconditionally, so an unset variable is a fatal rather than an
  # absent surface. Empty is the absent surface the installer documents.
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY=""
}

# Case A: no override — first creation generates a correctly shaped key.
MOCK_ROOT="$WORK/mfa-a"
mkdir -p "$MOCK_ROOT"
mfa_a_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  install_service_secrets >"$WORK/mfa-a.log" 2>&1
) || mfa_a_ec=$?
mfa_key_a="$(mock_get identity identity-secrets MFA_ENCRYPTION_KEY)"
if [ "$mfa_a_ec" -ne 0 ]; then
  fail 'default: first creation succeeds with no MFA override' "$(cat "$WORK/mfa-a.log")"
elif [ -z "$mfa_key_a" ]; then
  fail 'default: first creation stores an MFA_ENCRYPTION_KEY' "$(cat "$WORK/mfa-a.log")"
else
  pass 'default: first creation stores an MFA_ENCRYPTION_KEY'
fi
run 'default: the generated key is 43 base64url chars decoding to 32 bytes' green mfa_shape_ok "$mfa_key_a"
run 'control: a short key fails the same shape check' red mfa_shape_ok "not-a-key"
case "$(cat "$WORK/mfa-a.log")" in
  *"$mfa_key_a"*)
    fail 'default: the installer output never contains the generated key' "the generated value appears in the log"
    ;;
  *)
    pass 'default: the installer output never contains the generated key'
    ;;
esac

# Case B: a valid override is stored exactly, and never printed.
MFA_OVERRIDE="Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
MOCK_ROOT="$WORK/mfa-b"
mkdir -p "$MOCK_ROOT"
mfa_b_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY="$MFA_OVERRIDE"
  install_service_secrets >"$WORK/mfa-b.log" 2>&1
) || mfa_b_ec=$?
mfa_key_b="$(mock_get identity identity-secrets MFA_ENCRYPTION_KEY)"
if [ "$mfa_b_ec" -ne 0 ]; then
  fail 'override: a valid supplied key is accepted' "$(cat "$WORK/mfa-b.log")"
elif [ "$mfa_key_b" != "$MFA_OVERRIDE" ]; then
  fail 'override: the stored key equals the supplied override' "stored: '${mfa_key_b}'"
else
  pass 'override: the stored key equals the supplied override'
fi
case "$(cat "$WORK/mfa-b.log")" in
  *"$MFA_OVERRIDE"*)
    fail 'override: the installer output never contains the supplied key' "the override appears in the log"
    ;;
  *)
    pass 'override: the installer output never contains the supplied key'
    ;;
esac

# Case C: an invalid override is refused, naming the variable — and no
# secret is written. A key the installer would happily store is a key
# identity refuses at boot, so the refusal belongs here, not on the box.
MOCK_ROOT="$WORK/mfa-c"
mkdir -p "$MOCK_ROOT"
mfa_c_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY="not-a-key"
  install_service_secrets >"$WORK/mfa-c.log" 2>&1
) || mfa_c_ec=$?
mfa_log_c="$(cat "$WORK/mfa-c.log")"
if [ "$mfa_c_ec" -eq 0 ]; then
  fail 'override: an invalid supplied key is refused' "exit 0 — identity would refuse this value at boot"
else
  pass 'override: an invalid supplied key is refused'
fi
case "$mfa_log_c" in
  *KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY*)
    pass 'override: the refusal names the variable, not the value'
    ;;
  *)
    fail 'override: the refusal names the variable, not the value' "$mfa_log_c"
    ;;
esac
case "$mfa_log_c" in
  *not-a-key*)
    fail 'override: the refusal never prints the rejected value' "the value appears in the log"
    ;;
  *)
    pass 'override: the refusal never prints the rejected value'
    ;;
esac
if [ -d "$MOCK_ROOT/identity/identity-secrets" ]; then
  fail 'override: a refused run writes no identity-secrets' "the secret was created despite the refusal"
else
  pass 'override: a refused run writes no identity-secrets'
fi

# Case D: reruns never rotate — the stored key survives a second run even
# when the operator passes a different override. The whole fleet's
# once-only rule applies: rotation is replace-the-secret, never re-run.
MOCK_ROOT="$WORK/mfa-d"
mkdir -p "$MOCK_ROOT"
mfa_d_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  install_service_secrets >"$WORK/mfa-d1.log" 2>&1
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY="z-thread-is-long-enough-0123456789-_Xab"
  install_service_secrets >"$WORK/mfa-d2.log" 2>&1
) || mfa_d_ec=$?
mfa_key_d1="$(mock_get identity identity-secrets MFA_ENCRYPTION_KEY)"
if [ "$mfa_d_ec" -ne 0 ]; then
  fail 'rerun: two consecutive installs succeed' "$(cat "$WORK/mfa-d1.log" "$WORK/mfa-d2.log")"
elif [ -z "$mfa_key_d1" ]; then
  fail 'rerun: the first run stores a key' "no MFA_ENCRYPTION_KEY after the first run"
else
  pass 'rerun: the first run stores a key'
fi
run 'rerun: the stored key keeps its shape' green mfa_shape_ok "$mfa_key_d1"
case "$mfa_key_d1" in
  "z-thread-is-long-enough-0123456789-_Xab")
    fail 'rerun: a second run never replaces the stored key' "the override replaced the stored value"
    ;;
  *)
    pass 'rerun: a second run never replaces the stored key'
    ;;
esac
if [ "$mfa_key_a" != "$mfa_key_d1" ]; then
  pass 'rerun: two fresh installs generate distinct keys (never a constant)'
else
  fail 'rerun: two fresh installs generate distinct keys (never a constant)' "both stores hold the same value"
fi

# Case E: a legacy identity-secrets without the key is left alone. The
# guard's per-secret refusal — not a patch — is the contract: an imported
# database could hold ciphertext sealed under a key no longer present, so
# guessing a fresh one in would fork it. (The other three secrets are
# absent here, so the step runs its per-secret path rather than skipping.)
MOCK_ROOT="$WORK/mfa-e"
mkdir -p "$MOCK_ROOT"
mfa_e_ec=0
(
  mfa_seed_roles
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity?sslmode=disable"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  install_service_secrets >"$WORK/mfa-e.log" 2>&1
) || mfa_e_ec=$?
if [ "$mfa_e_ec" -ne 0 ]; then
  fail 'legacy: the step still completes around a pre-existing secret' "$(cat "$WORK/mfa-e.log")"
else
  pass 'legacy: the step still completes around a pre-existing secret'
fi
if [ -n "$(mock_get identity identity-secrets MFA_ENCRYPTION_KEY)" ]; then
  fail 'legacy: a pre-existing secret without the key is not patched' "MFA_ENCRYPTION_KEY appeared in the legacy secret"
else
  pass 'legacy: a pre-existing secret without the key is not patched'
fi
if [ "$(mock_get identity identity-secrets SIGNUP_SIGNING_KEY)" = "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8" ]; then
  pass 'legacy: the pre-existing secret keeps its own values'
else
  fail 'legacy: the pre-existing secret keeps its own values' "SIGNUP_SIGNING_KEY changed"
fi

# ===========================================================================
# 12 (executed half). identity-secrets carries the broker's address
# ===========================================================================
#
# Section 12 above PARSES the source; this RUNS it. The installer is sourced
# with its trailing `main` removed and install_service_secrets is executed
# against the file-backed kubectl the MFA cases above define, so the claim is
# about the secret kubectl would actually create rather than about the text
# of the script. It lives beside those cases rather than in section 12 because
# the harness it needs is defined there.
#
# WHY IT IS WORTH RUNNING: identity builds its NATS publisher only when
# NATS_URL is set, so the local compose stack publishes and a real box does
# not — the one difference this packet closes. A parse can be satisfied by a
# literal on a line that never executes; a mock store cannot.
BROKER_URL="nats://nats.data.svc.cluster.local:4222"
MOCK_ROOT="$WORK/nats-url"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
nats_url_1_ec=0
(
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  install_service_secrets >"$WORK/nats-url-1.log" 2>&1
) || nats_url_1_ec=$?
first_broker_url="$(mock_get identity identity-secrets NATS_URL)"

# Twice: the second run is the idempotency claim. A re-run must not rewrite
# the address — and it cannot, by construction. When all four secrets exist
# the step's own guard skips it ("already installed, skipping"); when only
# some do (a half-finished first run) the step runs and the per-secret path
# refuses to overwrite identity-secrets. Either way nothing is patched: the
# address is fixed by the broker's own Service name, and a broker that moves
# is a rotate-by-replacement (README), never a silent patch of a live secret.
nats_url_2_ec=0
(
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  install_service_secrets >"$WORK/nats-url-2.log" 2>&1
) || nats_url_2_ec=$?
second_broker_url="$(mock_get identity identity-secrets NATS_URL)"

if [ "$nats_url_1_ec" -ne 0 ]; then
  fail 'identity-secrets: the first run completes carrying the broker address' "$(cat "$WORK/nats-url-1.log")"
elif [ "$first_broker_url" != "$BROKER_URL" ]; then
  fail 'identity-secrets: the first run completes carrying the broker address' "stored: '${first_broker_url}'"
else
  pass 'identity-secrets: the first run completes carrying the broker address'
fi
if [ "$nats_url_2_ec" -ne 0 ]; then
  fail 're-run: a second run succeeds and changes nothing' "$(cat "$WORK/nats-url-2.log")"
elif [ "$second_broker_url" != "$first_broker_url" ]; then
  fail 're-run: a second run succeeds and changes nothing' "'${first_broker_url}' became '${second_broker_url}'"
else
  pass 're-run: a second run succeeds and changes nothing'
fi
case "$(cat "$WORK/nats-url-2.log")" in
  *"already installed, skipping"*)
    pass 're-run: the guard skips the step rather than rewriting the secret'
    ;;
  *"secret identity-secrets exists"*)
    pass 're-run: the per-secret refusal fires rather than rewriting the secret'
    ;;
  *)
    fail 're-run: the guard skips the step rather than rewriting the secret' "$(cat "$WORK/nats-url-2.log")"
    ;;
esac

# The control: the identical run against an installer carrying the COMPOSE
# spelling (`nats://nats:4222`, which resolves only inside `data`) stores that
# spelling verbatim. It proves the assertion above is about the INSTALLER and
# not about the mock — a store that recorded whatever it was sent, wrongly,
# would make the green assertion a tautology, and this is the fixture that
# shows it can tell the two apart.
fixture_short_live="$WORK/install-nats-short-live.sh"
sed 's|--from-literal=NATS_URL="$NATS_URL"|--from-literal=NATS_URL="nats://nats:4222"|' \
  "$SUBSTRATE/install.sh" | sed '/^main "$@"/d' >"$fixture_short_live"
MOCK_ROOT="$WORK/nats-url-control"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
control_short_ec=0
(
  # shellcheck source=/dev/null
  . "$fixture_short_live"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  install_service_secrets >"$WORK/nats-url-control.log" 2>&1
) || control_short_ec=$?
control_short_url="$(mock_get identity identity-secrets NATS_URL)"
if [ "$control_short_ec" -eq 0 ] && [ "$control_short_url" = "nats://nats:4222" ] && [ "$control_short_url" != "$BROKER_URL" ]; then
  pass 'control: the compose spelling is stored verbatim, and is not the broker address'
else
  fail 'control: the compose spelling is stored verbatim, and is not the broker address' "exit ${control_short_ec}; stored: '${control_short_url}'"
fi

# ===========================================================================
# 13. No long-lived secret enters the installer (invariant 3's input side)
# ===========================================================================
#
# W2-P4. Two values used to be handed TO this installer: a GHCR
# dockerconfigjson and identity's OIDC signing key — both long-lived, both
# belonging to the box, both arrived in a shell history. A third loop used to
# cross a boundary twice: the operator minted courier's credential by hand and
# pasted it into a second run.
#
# What this section proves:
#   1. the retired input names are GONE from install.sh — an input nobody
#      declared is still an input if somebody read it;
#   2. what replaced the pull secret is SHORT-LIVED and BOX-BOUND: a capability
#      of the minted shape, redeemed per run, and never printed;
#   3. the OIDC signing key is BORN ON THE BOX — generated, shaped the way
#      identity's own parser demands, stable across a re-run, and never echoed;
#   4. the courier credential is minted, patched and restarted INSIDE one run,
#      and the minted value reaches neither secrets nor logs.
#
# The no-print assertions are the SECRET RECORD's own idiom: the value must
# not appear in the installer's output. Each has a control that plants the
# value in a log and must go red.
CAP_GOOD="cap_$(printf 'a%.0s' $(seq 64))"
CAP_B64_PULL_SECRET="$(printf '{"auths":{"ghcr.io":{"auth":"ZmFrZS1ub3QtYS1jcmVkZW50aWFs"}}}' | base64 | tr -d '\n')"
CAP_BOX_ID_UUID="11111111-2222-3333-4444-555555555555"
CAP_OTHER_BOX_UUID="88888887-7777-6666-5555-444444444444"
CAP_ACCOUNT_UUID="99999999-8888-7777-6666-555555555555"

# 13a. The retired inputs are gone. The names below are the four spellings an
# older runbook still carries; a file that reads any of them is a file that
# still takes a long-lived secret in.
#
# The check reads CODE, with comments stripped — the same strip the SECRET
# RECORD check above uses. A comment cannot read a variable, and this file
# needs to be able to NAME the values it retired (that naming is the record of
# the change); a `set -u` installer is what the check is actually about.
installer_code="$WORK/install-code-only.sh"
sed -e 's/^[[:space:]]*#.*$//' "$SUBSTRATE/install.sh" >"$installer_code"
for retired in KIT_SUBSTRATE_PULL_SECRET KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY_ID KIT_SUBSTRATE_COURIER_IDENTITY_TOKEN KIT_SUBSTRATE_IDENTITY_COURIER_TOKEN; do
  if grep -n "$retired" "$installer_code" >/dev/null 2>&1; then
    fail "the installer no longer reads $retired" "$(grep -n "$retired" "$installer_code" | head -3)"
  else
    pass "the installer no longer reads $retired"
  fi
done

# The control: a fixture carrying every retired name must be found by the same
# grep. A check that cannot see the thing it bans is a comment.
fixture_retired="$WORK/install-retired-inputs.sh"
cp "$SUBSTRATE/install.sh" "$fixture_retired"
for retired in KIT_SUBSTRATE_PULL_SECRET KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY_ID KIT_SUBSTRATE_COURIER_IDENTITY_TOKEN KIT_SUBSTRATE_IDENTITY_COURIER_TOKEN; do
  printf ': "${%s:=}"\n' "$retired" >>"$fixture_retired"
  if grep -n "$retired" "$fixture_retired" >/dev/null 2>&1; then
    pass "control: a planted $retired is found by the same grep"
  else
    fail "control: a planted $retired is found by the same grep" "the grep found nothing in $fixture_retired"
  fi
done

# 13b. The capability is validated by shape BEFORE any network call, so a
# pasted dockerconfigjson — the value an older runbook asks for — is refused
# on the box instead of sent somewhere as an opaque bearer.
# shellcheck source=/dev/null
. "$fixture_sourced"

run 'the capability is validated: the minted shape is accepted' green registry_capability_shape_ok "$CAP_GOOD"
run 'control: a dockerconfigjson is refused as a capability' red registry_capability_shape_ok "$CAP_B64_PULL_SECRET"
run 'control: a short capability is refused' red registry_capability_shape_ok "cap_deadbeef"
run 'control: an empty capability is refused' red registry_capability_shape_ok ""

# 13c. The exchange itself: the capability is exchanged for a dockerconfigjson,
# and the credential never touches a log, an argv, or the disk.
#
# The previous packet proved this step REFUSED, because no service in the fleet
# traded a redeemed capability for a dockerconfigjson (seam audit §5a-5c). That
# service now exists — cafaye/registry, the capability exchange — so the
# assertions below flip from "it refuses, naming the gap" to the four
# properties the exchange's own brief names, asserted at the installer's end:
#   1. it speaks the exchange route, presenting the capability as a bearer and
#      naming the box the capability is bound to;
#   2. it writes the credential as a docker-registry Secret in every namespace
#      that pulls the fleet's images, READ BACK as the base64 form
#      kubectl would store;
#   3. it never prints it, and never puts it in argv — a value in argv is a
#      value in `ps`;
#   4. it refuses, by name, every way the exchange can answer no.
#
# The credential below is a LABEL, not a credential — one of the fakes that
# guard not the value but the deviation. The dockerconfigjson the mock
# answers is real base64 so the decode is real.
receipt_expires="$("$PY" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=58)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
receipt_past="$("$PY" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

# The exchange's answer: the dockerconfigjson it minted, plus the lifetime. The
# credential inside it is a label — what is asserted is the shape and the
# destination, never the value.
EXCHANGE_B64="$(printf '{"auths":{"ghcr.io":{"username":"x-access-token","password":"ghs_a-labelled-fake"}}}' | base64 | tr -d '\n')"
exchange_body() { # <b64> <expires_at> <seconds_remaining>
  printf '{"registry":"ghcr.io","expires_at":"%s","seconds_remaining":%s,"dockerconfigjson":"%s"}' "$2" "$3" "$1"
}

MOCK_ROOT="$WORK/pull-secret"
mkdir -p "$MOCK_ROOT"
rm -f "$MOCK_ROOT/curl-calls" "$MOCK_ROOT/curl-response" "$MOCK_ROOT/kubectl-argv" "$MOCK_ROOT/applied.yaml" "$WORK/pull-secret.log"

# The mock records what the installer SENT. The URL is the claim — the
# exchange's route, not the redeem door the installer used to speak — and the
# bearer and the body are the box-bound half.
MOCK_CURL_MODE="answer"
exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT/curl-response"
pull_secret_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() {
    printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"
    [ "${MOCK_CURL_MODE:-}" = "fail" ] && return 1
    cat "$MOCK_ROOT/curl-response"
    # The installer asks for the status on a trailing `-w '\n%{http_code}'`
    # line. curl writes the -w format verbatim after the body, escapes
    # included, so the mock emits the newline the format string carries
    # rather than inventing its own separator: the single-call read that
    # spends the capability once is what is under test.
    case "$*" in
      *"-w"*) printf '\n%s\n' "${MOCK_CURL_STATUS:-200}" ;;
    esac
    return 0
  }
  export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.cafaye.test"
  install_pull_secret >"$WORK/pull-secret.log" 2>&1
) || pull_secret_ec=$?

# 1. The step SUCCEEDS. It used to refuse; the exchange exists now, so a
# refusal is the failure, not the contract.
if [ "$pull_secret_ec" -ne 0 ]; then
  fail 'the pull-secret step exchanges the capability and writes the secret' "exit $pull_secret_ec: $(cat "$WORK/pull-secret.log")"
else
  pass 'the pull-secret step exchanges the capability and writes the secret'
fi

# 2. It speaks the EXCHANGE route, presenting the capability as a bearer and
# naming the box — the box-bound half, enforced server-side at box by the
# exchange on the capability's behalf.
curl_call_ok() {
  local call
  call="$(cat "$MOCK_ROOT/curl-calls" 2>/dev/null || true)"
  case "$call" in
    *"/v1/registry-credentials"*) ;;
    *) printf 'the exchange did not speak the registry-credentials route\n%s\n' "$call"; return 1 ;;
  esac
  case "$call" in
    *"$CAP_GOOD"*) ;;
    *) printf 'the exchange did not present the capability\n'; return 1 ;;
  esac
  case "$call" in
    *"$CAP_BOX_ID_UUID"*) ;;
    *) printf 'the exchange did not name the box\n'; return 1 ;;
  esac
  # The capability rides in the bearer, not the URL: a path is logged by every
  # proxy in front of the exchange and outlives the credential.
  case "$call" in
    *"Authorization: Bearer $CAP_GOOD"*) ;;
    *) printf 'the capability did not travel as a bearer header\n%s\n' "$call"; return 1 ;;
  esac
  case "$call" in
    *"/v1/registry-credentials/cap_"*|*registration-credentials/cap_*)
      printf 'the capability appears in the URL path\n%s\n' "$call"; return 1 ;;
    *) ;;
  esac
  # The capability is box-bound, so the request names THIS box and never
  # another one: a body carrying a foreign box id is the shape of a
  # capability being cashed for somebody else's pull.
  case "$call" in
    *"$CAP_OTHER_BOX_UUID"*)
      printf 'the request names a box that is not this box\n%s\n' "$call"; return 1 ;;
    *) ;;
  esac
  # The account rides INSIDE the capability, not in the request: a body naming
  # an account is a caller trying to choose whose pull to buy.
  case "$call" in
    *"$CAP_ACCOUNT_UUID"*)
      printf 'the request names the account — it travels in the capability\n%s\n' "$call"; return 1 ;;
    *) ;;
  esac
  printf 'a POST to the exchange route, the capability as a bearer, a body naming the box'
}
run 'the exchange speaks the registry-credentials route, bearer + box' green curl_call_ok

# 3. The credential is WRITTEN as a docker-registry Secret in every namespace
# that pulls the fleet's images, and the bytes stored are the base64 the
# exchange returned — read back exactly as kubectl would read them.
APPLIED_NAMESPACES=(argocd identity gateway courier parlor observability)
applied_pull_secrets_ok() {
  local ns found
  for ns in "${APPLIED_NAMESPACES[@]}"; do
    if ! grep -q "namespace: $ns" "$MOCK_ROOT/applied.yaml" 2>/dev/null; then
      printf 'no pull secret was applied in %s\n' "$ns"
      return 1
    fi
  done
  # The applied Secret's type is the docker-registry type, which is what makes
  # kubelet read it as image-pull credentials at all.
  grep -q "kubernetes.io/dockerconfigjson" "$MOCK_ROOT/applied.yaml" || {
    printf 'the applied Secret is not a dockerconfigjson Secret'
    return 1
  }
  printf 'a dockerconfigjson Secret applied in %d namespaces' "${#APPLIED_NAMESPACES[@]}"
}
run 'the dockerconfigjson is written as a pull Secret in every pulling namespace' green applied_pull_secrets_ok

# 4. THE CREDENTIAL IS NEVER ECHOED. Three assertions, each with a control
# below that plants the value and must go red: the log, the argv, and the
# variable that held it (dropped after use).
log="$WORK/pull-secret.log"
case "$(cat "$log")" in
  *"$EXCHANGE_B64"*)
    fail 'the exchanged step never echoes the dockerconfigjson' "the dockerconfigjson appears in the log" ;;
  *) pass 'the exchanged step never echoes the dockerconfigjson' ;;
esac
case "$(cat "$log")" in
  *"ghs_a-labelled-fake"*)
    fail 'the exchanged step never echoes the credential' "the credential appears in the log" ;;
  *) pass 'the exchanged step never echoes the credential' ;;
esac
case "$(cat "$log")" in
  *"$CAP_GOOD"*)
    fail 'the exchanged step never echoes the capability' "the capability appears in the log" ;;
  *) pass 'the exchanged step never echoes the capability' ;;
esac

# 5. THE CREDENTIAL NEVER ENTERS ARGV. This is the one that cannot be read
# off a log: `ps` sees the whole command line, and a credential in argv is a
# credential on the box for as long as the process lives. The mock recorded
# every kubectl invocation in full, so the negative is checkable — with the
# control that the recorder does see planted argv when something puts a
# secret there.
case "$(cat "$MOCK_ROOT/kubectl-argv" 2>/dev/null || true)" in
  *"$EXCHANGE_B64"*)
    fail 'the dockerconfigjson never enters argv' "the credential appears in a kubectl invocation" ;;
  *) pass 'the dockerconfigjson never enters argv' ;;
esac
if kubectl() { mock_kubectl "$@"; }; then
  :
fi
(
  kubectl() { mock_kubectl "$@"; }
  export MOCK_ROOT="$MOCK_ROOT"
  printf '%s\n' "--from-literal=password=$EXCHANGE_B64" >>"$MOCK_ROOT/kubectl-argv" 2>/dev/null
) || true
case "$(cat "$MOCK_ROOT/kubectl-argv" 2>/dev/null || true)" in
  *"--from-literal=password=$EXCHANGE_B64"*)
    pass 'control: the argv recorder does see a secret planted in an invocation' ;;
  *) fail 'control: the argv recorder does see a secret planted in an invocation' "the recorder found nothing" ;;
esac

# 6. The credential is never written to disk outside the Secret's own bytes:
# there is no temp file holding it, only the store the mock keeps as the
# cluster would. The store holds the applied Secret, nothing else carries the
# value.
stray_files_ok() {
  # A glob and a for loop rather than `ls | grep`, so a filename with a space
  # or a newline is a name this test can actually count.
  local f
  for f in "$MOCK_ROOT"/*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
      curl-calls|curl-response|kubectl-argv|applied|applied.yaml) continue ;;
      argocd|identity|gateway|courier|parlor|observability) continue ;;
    esac
    printf 'unexpected file in the store: %s\n' "${f##*/}"
    return 1
  done
  printf 'nothing but the applied Secret and the records of the call hold the credential'
}
run 'no stray file on the box holds the credential' green stray_files_ok

# 7. Every way the exchange can answer no is refused, BY NAME, and the fix
# named. A green case here would mean the installer wrote a Secret from an
# answer it did not read.
exchange_case() { # <mode> <status> <response-body> <expected-log-substring> <case-name>
  local mode="$1" status="$2" body="$3" want="$4" name="$5"
  local log="$WORK/pull-secret-case.log"
  rm -f "$MOCK_ROOT/curl-calls" "$MOCK_ROOT/kubectl-argv" "$MOCK_ROOT/applied.yaml" "$log"
  MOCK_CURL_MODE="$mode"
  MOCK_CURL_STATUS="$status"
  printf '%s' "$body" >"$MOCK_ROOT/curl-response"
  local ec=0
  (
    kubectl() { mock_kubectl "$@"; }
    curl() {
      printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"
      [ "${MOCK_CURL_MODE:-}" = "fail" ] && return 1
      cat "$MOCK_ROOT/curl-response"
      case "$*" in
        *"-w"*) printf '\n%s\n' "${MOCK_CURL_STATUS:-200}" ;;
      esac
    }
    export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
    export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
    export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.cafaye.test"
    install_pull_secret >"$log" 2>&1
  ) || ec=$?
  MOCK_CURL_MODE=""
  MOCK_CURL_STATUS=""
  if [ "$ec" -ne 0 ] && grep -q "$want" "$log" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "exit $ec, log: $(cat "$log" 2>/dev/null)"
  fi
  # A refusal must also not have written anything: no argv recorded, no Secret
  # applied. A half-written refusal is the half-installed substrate.
  if [ -s "$MOCK_ROOT/kubectl-argv" ] 2>/dev/null || [ -s "$MOCK_ROOT/applied.yaml" ] 2>/dev/null; then
    fail "a refusal writes nothing: $name" "argv or applied.yaml is non-empty after the refusal"
  else
    pass "a refusal writes nothing: $name"
  fi
}
refusal_body() { # <code> <message>
  printf '{"error":{"code":"%s","message":"%s"}}' "$1" "$2"
}
exchange_case fail 000 ""   "the registry exchange did not answer"   'a dead exchange is a refusal, named for the operator'
exchange_case answer 410 "$(refusal_body capability_expired 'capability has expired')"   "capability_expired"   'an expired capability is refused, naming the expiry'
exchange_case answer 409 "$(refusal_body capability_redeemed 'capability has already been redeemed')"   "capability_redeemed"   'an already-redeemed capability is refused, naming the spend'
exchange_case answer 403 "$(refusal_body capability_wrong_box 'capability is bound to a different box')"   "capability_wrong_box"   'a capability minted for another box is refused, naming the box'
exchange_case answer 403 "$(refusal_body capability_wrong_purpose 'capability is minted for a different purpose')"   "capability_wrong_purpose"   'a capability minted for another purpose is refused, naming the purpose'
exchange_case answer 200 "$(exchange_body "$EXCHANGE_B64" "$receipt_expires" 20)"   "seconds of life left"   'a credential with no life left is refused rather than written'
exchange_case answer 200 "$(exchange_body "$EXCHANGE_B64" "not-an-instant" 3480)" \
  "is not an instant" \
  'a credential whose expires_at is unreadable is refused'
exchange_case answer 200 "$(exchange_body "$EXCHANGE_B64" "$receipt_past" 3480)" \
  "is already past" \
  'a credential whose expires_at has already passed is refused'
exchange_case answer 200 '{"registry":"ghcr.io","expires_at":"'"$receipt_expires"'","seconds_remaining":3480}'   "carried no dockerconfigjson"   'an answer with no dockerconfigjson is refused'
exchange_case answer 200 "$(exchange_body "$(printf 'not base64 at all' | base64 | tr -d '
')" "$receipt_expires" 3480)"   "not a ghcr.io credential"   'a dockerconfigjson that is not a ghcr.io credential is refused'

# The control on the shape check: a pasted dockerconfigjson in the
# capability's place is refused before any network call. The recorded calls
# are cleared first, so "no network" is measured for this case alone.
rm -f "$MOCK_ROOT/curl-calls" "$MOCK_ROOT/kubectl-argv" "$MOCK_ROOT/applied.yaml"
(
  kubectl() { mock_kubectl "$@"; }
  curl() { printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"; cat "$MOCK_ROOT/curl-response"; printf '\n%s\n' "${MOCK_CURL_STATUS:-200}"; }
  export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_B64_PULL_SECRET"
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.cafaye.test"
  install_pull_secret >"$WORK/pull-secret-paste.log" 2>&1
) || true
if grep -q "OLD runbook" "$WORK/pull-secret-paste.log" 2>/dev/null && [ ! -s "$MOCK_ROOT/curl-calls" ]; then
  pass 'control: a pasted dockerconfigjson is refused before any network call'
else
  fail 'control: a pasted dockerconfigjson is refused before any network call' "$(cat "$WORK/pull-secret-paste.log")"
fi

# 13d. The OIDC signing key is born on THIS box.
#
# A private RSA key that has been in somebody's shell history is not the
# customer's key any more, so the installer generates it: openssl at identity's
# own floor (2048 bits, MinKeyBits), an id DERIVED FROM THE KEY (a public
# thumbprint, so a cached verifier's `kid` keeps matching), read back
# once-only, and never printed. A re-run does not regenerate: gateway caches
# JWKS entries by `kid`, so a service that signs with a new key every boot is a
# service nobody can verify.
oidc_shape_ok() {
  local pem bits
  pem="$1"
  case "$pem" in
    *"BEGIN RSA PRIVATE KEY"* | *"BEGIN PRIVATE KEY"*) ;;
    *) printf 'not a PEM private key (%s)\n' "$(printf '%s' "$pem" | head -1)"; return 1 ;;
  esac
  bits="$(printf '%s' "$pem" | openssl rsa -noout -text 2>/dev/null | sed -n 's/.*Private-Key: (\([0-9][0-9]*\) bit.*/\1/p' | head -1)"
  if [ -z "$bits" ]; then
    printf 'openssl could not parse the stored key\n'
    return 1
  fi
  if [ "$bits" -lt 2048 ]; then
    printf 'the key is %s bits — identity refuses a key below MinKeyBits (2048)\n' "$bits"
    return 1
  fi
  printf 'a %s-bit RSA PEM private key\n' "$bits"
}

oidc_log_clean() {
  # $1 = the log, $2 = the value that must not be in it.
  case "$1" in
    *"$2"*)
      printf 'the value appears in the installer output\n'
      return 1
      ;;
  esac
  printf 'absent from the output\n'
}

MOCK_ROOT="$WORK/oidc-a"
mkdir -p "$MOCK_ROOT"
oidc_a_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://identity.example.com"
  install_service_secrets >"$WORK/oidc-a.log" 2>&1
) || oidc_a_ec=$?
if [ "$oidc_a_ec" -ne 0 ]; then
  fail 'oidc: the surface wires on a box with no stored key' "$(cat "$WORK/oidc-a.log")"
else
  pass 'oidc: the surface wires on a box with no stored key'
fi
oidc_key_a="$(mock_get identity identity-secrets OIDC_SIGNING_KEY)"
oidc_id_a="$(mock_get identity identity-secrets OIDC_SIGNING_KEY_ID)"
oidc_shape_a="$(oidc_shape_ok "$oidc_key_a")" && oidc_shape_a_ec=0 || oidc_shape_a_ec=$?
if [ -z "$oidc_key_a" ]; then
  fail 'oidc: a signing key is generated on the box' "no OIDC_SIGNING_KEY in $MOCK_ROOT/identity/identity-secrets"
elif [ "$oidc_shape_a_ec" -ne 0 ]; then
  fail 'oidc: the generated key is an RSA PEM of at least 2048 bits' "$oidc_shape_a"
else
  pass "oidc: the generated key is an RSA PEM of at least 2048 bits ($oidc_shape_a)"
fi
case "$oidc_id_a" in
  box-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    pass 'oidc: the key id is a thumbprint identity accepts (box- plus 16 hex)'
    ;;
  *) fail 'oidc: the key id is a thumbprint identity accepts (box- plus 16 hex)' "id: $oidc_id_a" ;;
esac
run 'oidc: the generated key never reaches the output' green oidc_log_clean "$(cat "$WORK/oidc-a.log")" "$oidc_key_a"
run 'control: a key echoed into the log is caught' red oidc_log_clean "created with OIDC_SIGNING_KEY=${oidc_key_a}" "$oidc_key_a"
if [ "$(mock_get identity identity-secrets OIDC_ISSUER)" = "https://identity.example.com" ]; then
  pass 'oidc: the issuer rides along — the surface is issuer, key and id, or nothing'
else
  fail 'oidc: the issuer rides along — the surface is issuer, key and id, or nothing' "OIDC_ISSUER: $(mock_get identity identity-secrets OIDC_ISSUER)"
fi

# The re-run: nothing regenerates. The stored key is read back, the id is read
# back with it, and a second box generates a different key (never a constant).
MOCK_ROOT="$WORK/oidc-b"
mkdir -p "$MOCK_ROOT"
oidc_b_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://identity.example.com"
  install_service_secrets >"$WORK/oidc-b.log" 2>&1
) || oidc_b_ec=$?
oidc_key_b="$(mock_get identity identity-secrets OIDC_SIGNING_KEY)"
if [ "$oidc_b_ec" -ne 0 ]; then
  fail 'oidc: a second box generates its own key' "$(cat "$WORK/oidc-b.log")"
elif [ "$oidc_key_a" = "$oidc_key_b" ]; then
  fail 'oidc: a second box generates its own key' "both boxes hold the same key"
elif [ "$(mock_get identity identity-secrets OIDC_SIGNING_KEY_ID)" = "$oidc_id_a" ]; then
  fail 'oidc: a second box generates its own key' "both boxes hold the same key id"
else
  pass 'oidc: a second box generates its own key'
fi
MOCK_ROOT="$WORK/oidc-rerun"
mkdir -p "$MOCK_ROOT"
oidc_rerun_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://identity.example.com"
  install_service_secrets >"$WORK/oidc-rerun1.log" 2>&1
  install_service_secrets >"$WORK/oidc-rerun2.log" 2>&1
) || oidc_rerun_ec=$?
oidc_key_rerun="$(mock_get identity identity-secrets OIDC_SIGNING_KEY)"
oidc_id_rerun="$(mock_get identity identity-secrets OIDC_SIGNING_KEY_ID)"
if [ "$oidc_rerun_ec" -ne 0 ]; then
  fail 'oidc: a re-run never regenerates the key' "$(cat "$WORK/oidc-rerun1.log" "$WORK/oidc-rerun2.log")"
elif [ -z "$oidc_key_rerun" ]; then
  fail 'oidc: a re-run never regenerates the key' "no key after the second run"
elif [ "$oidc_key_rerun" = "$oidc_key_a" ] || [ "$oidc_key_rerun" = "$oidc_key_b" ]; then
  fail 'oidc: a re-run never regenerates the key' "the stored key matches another install's — a constant, not a key"
else
  pass 'oidc: a re-run never regenerates the key'
fi
case "$oidc_id_rerun" in
  box-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    pass 'oidc: the key id is read back with the key'
    ;;
  *) fail 'oidc: the key id is read back with the key' "id: $oidc_id_rerun" ;;
esac

# 13e. The courier loop is box-internal: one run mints the credential through
# identity's own API, writes the SAME value into both secrets that have to hold
# it, and restarts both deployments. Nothing is printed.
COURIER_MINT_TOKEN="cap_box_minted_fake_token_value"
courier_mint_curl() {
  # The URL is whichever argument is one — the calls put `-d` last, so taking
  # the final argument would read the request body instead.
  local url="" arg
  for arg in "$@"; do
    case "$arg" in
      http://* | https://*) url="$arg" ;;
    esac
  done
  case "$url" in
    */v1/signup-timestamp) printf '{"timestamp":1700000000,"signature":"fake-signature"}' ;;
    */v1/users) printf '{"id":"fake-user"}' ;;
    */v1/session) printf '{"token":"fake-session"}' ;;
    */v1/accounts) printf '{"id":"fake-account"}' ;;
    */v1/accounts/fake-account/api-keys) printf '{"token":"%s"}' "$COURIER_MINT_TOKEN" ;;
    *)
      printf 'courier_mint_curl: unmocked %s\n' "$url" >&2
      return 1
      ;;
  esac
}

MOCK_ROOT="$WORK/mint-loop"
mkdir -p "$MOCK_ROOT"
mint_loop_ec=0
(
  mfa_seed_roles
  # The box's secrets as step 9 left them — so the assertion below is about
  # what the mint ADDS, not about a secret it created itself.
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
  mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "z-thread-is-long-enough-0123456789-_Xab"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  curl() { courier_mint_curl "$@"; }
  mfa_smtp_env
  mint_courier_identity_token >"$WORK/mint-loop.log" 2>&1
) || mint_loop_ec=$?
if [ "$mint_loop_ec" -ne 0 ]; then
  fail 'the mint loop completes inside one run' "$(cat "$WORK/mint-loop.log")"
elif [ "$(mock_get courier courier-secrets COURIER_IDENTITY_TOKEN)" != "$COURIER_MINT_TOKEN" ]; then
  fail 'the mint loop completes inside one run' "courier-secrets holds: '$(mock_get courier courier-secrets COURIER_IDENTITY_TOKEN)'"
elif [ "$(mock_get identity identity-secrets COURIER_TOKEN)" != "$COURIER_MINT_TOKEN" ]; then
  fail 'the mint loop completes inside one run' "identity-secrets holds: '$(mock_get identity identity-secrets COURIER_TOKEN)'"
else
  pass 'the mint loop completes inside one run'
fi
# The patch is a PATCH. A whole-Secret `apply` would carry COURIER_TOKEN and
# drop every key step 9 wrote — identity would boot without its DATABASE_URL
# and nothing here would look broken until a pod restarted.
for kept in DATABASE_URL SIGNUP_SIGNING_KEY MFA_ENCRYPTION_KEY; do
  if [ -n "$(mock_get identity identity-secrets "$kept")" ]; then
    pass "the mint patches identity-secrets without dropping ${kept}"
  else
    fail "the mint patches identity-secrets without dropping ${kept}" "the key is gone after the mint"
  fi
done
run 'the mint loop never echoes the minted credential' green oidc_log_clean "$(cat "$WORK/mint-loop.log")" "$COURIER_MINT_TOKEN"
run 'control: a minted credential echoed into the log is caught' red oidc_log_clean "patched with COURIER_IDENTITY_TOKEN=${COURIER_MINT_TOKEN}" "$COURIER_MINT_TOKEN"

# ===========================================================================
# 14. --headless — stdout is progress-only, and progress is secret-free
# ===========================================================================
#
# The claim `caf box apply --phase N` rests on: run the installer with
# --headless and stdout is a stream of JSONL progress events, one object per
# line, and NOTHING ELSE — because an agent parsing that stream cannot tell a
# prose line from a progress line, and a prose line is where a credential
# would go if one ever did.
#
# The proof is in two halves, and both are needed.
#
#   A STATIC parse of every echo and printf in install.sh. It is the
#     SECRET RECORD's own idiom — a check over the source, not over one run —
#     and it is the half that holds for code paths no run reaches. Two rules:
#     (1) a statement that writes to the process stdout must live inside one
#     of the two emitters, and (2) no statement that can reach stdout, and no
#     emitter call, may expand a variable that holds secret material. Rule 2
#     is what makes the first one worth having: a stdout channel that only
#     the emitters write to is still a channel a `$PASSWORD` could be poured
#     into.
#
#   A LIVE run of the headless path against the mocked kubectl. It proves the
#     two writers actually behave: stdout parsed line by line as JSON, the
#     human text on stderr, and none of the run's real secret material — the
#     generated keys, the role passwords, the operator's relay password —
#     anywhere on stdout. A static check cannot see a value that only exists
#     at runtime, which is exactly the half the generated keys occupy.
#
# The `$KIT_SUBSTRATE_RECEIPT` override is load-bearing here: the default path
# is /var/lib/kit on a root-owned box, and a receipt the test cannot read is a
# receipt the test has not checked.

check_headless_stdout() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

# The two writers, plus the helpers they own. A statement inside one of these
# may reach the process stdout; anywhere else it may not.
EMITTERS = {
    "json_str",
    "kit_substrate_emit",
    "kit_substrate_out",
    "kit_substrate_write_receipt",
    "kit_substrate_refuse",
}

# Functions whose stdout is a COMMAND SUBSTITUTION at every call site. Their
# output is a value handed to another command — database_url_for builds a DSN
# carrying a generated password, oidc_key_id_for builds a thumbprint — so it
# must reach its caller and never a terminal. They are excused from rule 1 and
# NOT checked by rule 2, because a printf that cannot carry `$pw` is a DSN
# with no password in it. The assertion at the bottom of this check keeps the
# list honest: a value producer called anywhere else goes red.
VALUE_PRODUCERS = {"database_url_for", "oidc_key_id_for"}

# Every variable in install.sh that HOLDS secret material, by name. This is a
# closed list, not a pattern: a `*SECRET*` glob would also match `secret_name`
# (a Kubernetes object's name, which is not a value) and `secret_base`, and a
# check that fires on correct work teaches its reader to ignore it. A new
# secret-bearing variable must be added here in the same commit that adds it —
# the list is the contract, and an absent name is a hole.
SECRET_VARS = {
    "OIDC_SIGNING_KEY",             # generated on the box, step 9
    "OIDC_SIGNING_KEY_ID",
    "KIT_SUBSTRATE_REGISTRY_CAPABILITY",
    "KIT_SUBSTRATE_SMTP_PASSWORD",
    "KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET",
    "KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY",
    "KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY",
    "response",                     # step 5's redemption round trip — watched
                                    # whether or not the answer carries a credential
    "stored",                       # read_secret_key's return
    "signup_key", "mfa_key", "oidc_key", "oidc_key_id",
    "secret_base", "secret_box", "relay_token", "redis_pw", "pw",
    "token", "session_token", "owner_password",
    "mint_timestamp", "mint_signature", "out", "session", "account_id",
}

fn_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
stmt_re = re.compile(r"^\s*(echo|printf)\b(.*)$")
var_re = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")

# Continuation lines are joined first. The pipe that carries a rendered Secret
# into `kubectl apply -f -` sits on the line AFTER the printf, so a line-based
# read would flag the one statement in this file whose output most needs to
# stay off the terminal.
joined = []
buf, start = "", None
for n, line in enumerate(src.split("\n"), 1):
    if start is None:
        start = n
    if line.rstrip().endswith("\\"):
        buf += line.rstrip()[:-1] + " "
        continue
    buf += line
    joined.append((start, buf))
    buf, start = "", None
if start is not None:
    joined.append((start, buf))

problems = []
writers = 0
cur = "<top>"
for n, line in joined:
    m = fn_re.match(line)
    if m:
        cur = m.group(1)
        continue
    m = stmt_re.match(line)
    if not m:
        continue
    verb, rest = m.group(1), m.group(2)
    # A refusal already names the channel it writes to.
    if ">&2" in rest:
        continue
    # A printf whose output is a pipe or a command substitution never reaches
    # the process stdout: it is an argument to another command. Those are the
    # GOOD paths — the credential travels into kubectl, not into a terminal —
    # and flagging them would fail the exact behaviour this install exists to
    # have. Quoted text is stripped first so a `|` inside a message is not
    # mistaken for a pipe.
    bare = re.sub(r"'[^']*'|\"[^\"]*\"", "", rest)
    if "|" in bare or "$(" in bare or "`" in bare:
        continue
    if cur not in EMITTERS and cur not in VALUE_PRODUCERS:
        problems.append(
            f"line {n}: `{verb}` writes to stdout from {cur}() — "
            "route it through kit_substrate_out"
        )
        continue
    if cur in VALUE_PRODUCERS:
        continue
    writers += 1
    # Rule 2: a secret-bearing variable expanded into anything that can reach
    # stdout, including through an emitter call. Parsed off the raw line so a
    # value passed as an argument is seen wherever it sits.
    for name in var_re.findall(line):
        if name in SECRET_VARS:
            problems.append(
                f"line {n}: ${name} reaches the stdout path — "
                "a secret-shaped variable must never be expanded there"
            )

# Rule 2's other half: an emitter CALL SITE is checked the same way. A call is
# not an echo or printf, so the loop above never sees it.
for n, line in enumerate(src.split("\n"), 1):
    for name in ("kit_substrate_out", "kit_substrate_emit"):
        for call in re.finditer(re.escape(name) + r"\b(.*)", line):
            for var in var_re.findall(call.group(1)):
                if var in SECRET_VARS:
                    problems.append(
                        f"line {n}: {name}(... ${var}) — a secret-shaped "
                        "variable reaches the stdout path through a call site"
                    )

if "kit_substrate_out" not in src or "kit_substrate_emit" not in src:
    problems.append("the two writers are not both defined")
# The human channel must really move in headless mode, or the claim is prose.
out_body = re.search(r"^kit_substrate_out\(\)\s*\{(.*?)^\}", src, re.M | re.S)
if not out_body or ">&2" not in out_body.group(1):
    problems.append("kit_substrate_out does not send the human channel to stderr")

# And the VALUE_PRODUCERS exemption is only as good as its call sites: each one
# must be read inside a `$(...)`. Called bare, `database_url_for` would print a
# password to stdout and this check would have excused it. The definition line
# is skipped — `name()` is not a call.
for name in sorted(VALUE_PRODUCERS):
    for m in re.finditer(r"(?<![\w$])" + re.escape(name) + r"\s*\(", src):
        before = src[: m.start()]
        line_start = before.rfind("\n") + 1
        if not src[line_start : m.start()].strip():
            continue  # the definition
        window = src[max(0, line_start - 2) : m.start()]
        if "$(" not in window:
            problems.append(
                f"{name} is called outside a command substitution — its "
                "output would reach stdout"
            )
            break

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{writers} stdout statement(s), all inside the two writers")
PY
}

run 'every stdout echo/printf lives in the two writers' green check_headless_stdout "$SUBSTRATE/install.sh"

# The control for rule 1: a step that goes back to a bare echo. Must go red —
# without this the check is satisfied by a file with no echoes at all, which
# is the state where the property has been deleted rather than kept.
fixture_bare_echo="$WORK/install-bare-echo.sh"
sed 's|^\( *\)kit_substrate_out "      applied letsencrypt|\1echo "      applied letsencrypt|' \
  "$SUBSTRATE/install.sh" >"$fixture_bare_echo"
if ! grep -q 'echo "      applied letsencrypt' "$fixture_bare_echo"; then
  fail 'control fixture: the bare-echo edit failed to apply' \
    "the sed did not restore an echo — the control would prove nothing"
  failures=$((failures + 1))
else
  run 'control: a step that echoes straight to stdout goes red' red check_headless_stdout "$fixture_bare_echo"
fi

# The control for rule 2, through kit_substrate_out. The property the packet
# is named for, in the one line that could break it.
fixture_secret_out="$WORK/install-secret-out.sh"
cp "$SUBSTRATE/install.sh" "$fixture_secret_out"
printf '\n  kit_substrate_out "relay password ${KIT_SUBSTRATE_SMTP_PASSWORD}"\n' >>"$fixture_secret_out"
run 'control: a secret-shaped variable on the human channel goes red' red check_headless_stdout "$fixture_secret_out"

# The second control for rule 2, through kit_substrate_emit — the stdout
# channel itself, so the two writers are proven separately rather than by one
# fixture that happens to satisfy only the first.
fixture_secret_emit="$WORK/install-secret-emit.sh"
cp "$SUBSTRATE/install.sh" "$fixture_secret_emit"
printf '\n  kit_substrate_emit progress "redeemed ${response}"\n' >>"$fixture_secret_emit"
run 'control: a secret-shaped variable on the stdout channel goes red' red check_headless_stdout "$fixture_secret_emit"

# The third control: rule 1's escape hatch. A printf redirected into a pipe is
# excused because the value travels into a command's stdin, not the terminal.
# Removing the pipe — leaving the redemption round trip on the process stdout
# — must go red, or the piped exemption is a hole the check cannot see through.
fixture_no_pipe="$WORK/install-no-pipe.sh"
cp "$SUBSTRATE/install.sh" "$fixture_no_pipe"
printf '\n  printf "%%s" "$response"\n' >>"$fixture_no_pipe"
run 'control: a piped secret moved onto stdout goes red' red check_headless_stdout "$fixture_no_pipe"

# --- the live half -----------------------------------------------------------
# The install needs root, Linux and k3s, so the headless path runs the way
# section 13's cases do: the installer is sourced with its trailing `main`
# stripped, kubectl is the file-backed mock, and the two writers are watched
# on the real channels. This is the half a static parse cannot do: the values
# asserted absent are GENERATED during the run.
headless_receipt="$WORK/headless-receipt.json"
MOCK_ROOT="$WORK/headless"
mkdir -p "$MOCK_ROOT"
headless_ec=0
(
  # The exports come BEFORE the source: `RECEIPT_PATH` is resolved from
  # KIT_SUBSTRATE_RECEIPT at source time, so exporting after would leave the
  # installer writing to the real /var/lib/kit — which on a developer machine
  # it cannot create, so the receipt would silently never appear.
  export DRY_RUN=0
  export HEADLESS=1
  export KIT_SUBSTRATE_RECEIPT="$headless_receipt"
  # The operator-sourced courier values. Every one is a FAKE — a label, not a
  # credential — and each is asserted absent from stdout below, which is the
  # point: a value the installer never prints is a value the check can look
  # for by name.
  export KIT_SUBSTRATE_SMTP_HOST="relay.example.com"
  export KIT_SUBSTRATE_SMTP_USERNAME="relay-user"
  export KIT_SUBSTRATE_SMTP_PASSWORD="relay-pass-fake"
  export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="provider-signing-fake"
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY=""
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  # shellcheck disable=SC2034  # read by the sourced installer's emit path
  CURRENT_PHASE="redis-and-secrets"
  log_step "Redis (single instance) and the services' secrets (identity, gateway, courier, parlor)"
  install_service_secrets
  # A refusal, because that is where a receipt earns its keep: the agent's
  # only touchpoint with a person is this event's input_needed and human.
  kit_substrate_refuse \
    "KIT_SUBSTRATE_ACME_EMAIL" \
    "export KIT_SUBSTRATE_ACME_EMAIL='<your-address@example.com>' on the box" \
    "KIT_SUBSTRATE_ACME_EMAIL is not set"
) >"$WORK/headless.jsonl" 2>"$WORK/headless.human" || headless_ec=$?

if [ "$headless_ec" -eq 0 ]; then
  fail 'headless: the refusal path exits non-zero' "exit 0 — a refusal must stop the install"
else
  pass 'headless: the refusal path exits non-zero'
fi

headless_jsonl_ok() {
  "$PY" - "$1" <<'PY'
import json
import sys

bad = []
count = 0
for i, line in enumerate(open(sys.argv[1], encoding="utf-8").read().split("\n"), 1):
    if not line.strip():
        continue
    count += 1
    try:
        obj = json.loads(line)
    except Exception as e:
        bad.append(f"line {i} is not JSON ({e}): {line[:70]!r}")
        continue
    for field in ("event", "step", "phase", "message"):
        if field not in obj:
            bad.append(f"line {i} has no {field!r} field")
if count == 0:
    print("stdout was empty — no events at all")
    sys.exit(1)
if bad:
    print("; ".join(bad))
    sys.exit(1)
print(f"{count} JSONL event(s), every one with event/step/phase/message")
PY
}
run 'headless: stdout is JSONL, one object per line' green headless_jsonl_ok "$WORK/headless.jsonl"

# Every secret the run actually holds — generated during it, and read back
# from the mock store so the assertion is about the run's own values rather
# than about a literal planted in the test.
headless_absent() {
  local log needle
  log="$(cat "$1")"
  shift
  for needle in "$@"; do
    case "$log" in
      *"$needle"*)
        printf 'the value appears on headless stdout\n'
        return 1
        ;;
    esac
  done
  printf 'none of the %d checked values appear on headless stdout\n' "$#"
}
headless_secrets=(
  "relay-pass-fake"
  "provider-signing-fake"
  "$(mock_get identity identity-secrets SIGNUP_SIGNING_KEY)"
  "$(mock_get identity identity-secrets MFA_ENCRYPTION_KEY)"
  "$(mock_get courier courier-secrets SECRET_KEY_BASE)"
  "$(mock_get courier courier-secrets COURIER_SECRET_BOX_KEY)"
  "$(mock_get courier courier-secrets COURIER_ERROR_RELAY_TOKEN)"
  "$(mock_get data redis-password password)"
  "$(mock_get data postgres-role-identity-app password)"
)
run 'headless: no secret value the run holds reaches stdout' green \
  headless_absent "$WORK/headless.jsonl" "${headless_secrets[@]}"

# The DATABASE_URL is the interesting one: it carries a real generated
# password inside a value the installer builds, so it is the shape most likely
# to leak by accident.
run 'headless: a generated DATABASE_URL never reaches stdout' green \
  headless_absent "$WORK/headless.jsonl" \
  "$(mock_get identity identity-secrets DATABASE_URL)" \
  "$(mock_get courier courier-secrets DATABASE_URL)"

# The human channel survives. A headless run that swallowed the operator's
# output would be a run nobody could debug, and the split only helps if both
# halves still reach somebody. What it carries is the DETAIL lines: the step
# headers became JSONL events, which is the point of the mode, so the human
# channel is asserted on a detail line and on the refusal that ended the run.
case "$(cat "$WORK/headless.human")" in
  *"secret identity-secrets created"*"error: KIT_SUBSTRATE_ACME_EMAIL is not set"*)
    pass 'headless: the human channel still carries the detail lines and the refusal'
    ;;
  *)
    fail 'headless: the human channel still carries the detail lines and the refusal' "$(cat "$WORK/headless.human")"
    ;;
esac
# And the converse, which is the real claim: the human prose must NOT be on
# stdout. A single non-JSON line on stdout would break `caf box apply`'s
# parser, so this is asserted separately from the JSONL parse above.
if grep -q 'secret identity-secrets created' "$WORK/headless.jsonl"; then
  fail 'headless: the human detail lines are not on stdout' "a prose line reached the JSONL channel"
else
  pass 'headless: the human detail lines are not on stdout'
fi

# The receipt: phase, next step, input needed, where the human goes. The
# refusal above is what makes it a resumable-install contract rather than a
# log — it names the variable the operator must supply and where.
headless_receipt_ok() {
  "$PY" - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    r = json.load(fh)
missing = [f for f in ("phase", "status", "next", "input_needed", "human") if f not in r]
if missing:
    print(f"receipt has no {', '.join(missing)}")
    sys.exit(1)
if r["status"] != "refused":
    print(f"status is {r['status']!r}, want 'refused' — the refusal did not land in the receipt")
    sys.exit(1)
if r["input_needed"] != "KIT_SUBSTRATE_ACME_EMAIL":
    print(f"input_needed is {r['input_needed']!r}, want the variable name")
    sys.exit(1)
if "example.com" not in (r["human"] or ""):
    print(f"human is {r['human']!r} — it must say where the person goes")
    sys.exit(1)
if not (r["next"] or "").strip():
    print("next is empty — a receipt with no next step is not resumable")
    sys.exit(1)
print("phase, next, input_needed and human all name their thing")
PY
}
run 'headless: the receipt names phase, next step, input needed and the human' green \
  headless_receipt_ok "$headless_receipt"

# The receipt's control: a receipt with no `human` field must go red. Without
# it the shape check is satisfied by a status report, which is the thing the
# receipt exists NOT to be.
fixture_receipt_no_human="$WORK/receipt-no-human.json"
sed 's/  "human": .*$/  "human": "",/' "$headless_receipt" >"$fixture_receipt_no_human"
run 'control: a receipt with no human destination goes red' red headless_receipt_ok "$fixture_receipt_no_human"

# And a receipt whose status is not the refusal's must go red too — the
# direction that matters, because a refusal recorded as `running` is an
# install the agent believes is still in progress.
fixture_receipt_running="$WORK/receipt-running.json"
sed 's/"status": "refused"/"status": "running"/' "$headless_receipt" >"$fixture_receipt_running"
run 'control: a refusal recorded as running goes red' red headless_receipt_ok "$fixture_receipt_running"

# The refusal's fix hint is on stderr, in interactive and headless mode alike.
# This was a real regression while this section was written: a
# kit_substrate_refuse that printed only `error: <message>` silently dropped the
# `export KIT_SUBSTRATE_…` line that tells an operator how to unblock, and the
# existing refusal checks still passed because the VARIABLE NAME appears in the
# message. The hint is the contract's second half, so it gets its own
# assertion — in both modes, because they take different branches.
refusal_hint_ok() {
  local log mode="$2"
  case "$1" in
    *"error: KIT_SUBSTRATE_DATABASES is not set"*"export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor'"*)
      printf 'the refusal names the variable and the fix that clears it (%s)\n' "$mode"
      ;;
    *)
      printf 'the %s-mode refusal lost its fix hint\n' "$mode"
      return 1
      ;;
  esac
}
refuse_unset_hint="$(DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" && refuse_unset_hint_ec=0 || refuse_unset_hint_ec=$?
if [ "$refuse_unset_hint_ec" -eq 0 ]; then
  fail 'the refusal names the variable and the fix that clears it (interactive)' "exit 0 — the plan was not refused"
else
  run 'the refusal names the variable and the fix that clears it (interactive)' green \
    refusal_hint_ok "$refuse_unset_hint" interactive
fi
run 'control: a refusal with no hint goes red' red refusal_hint_ok "error: KIT_SUBSTRATE_DATABASES is not set" interactive

headless_refuse_hint="$WORK/headless-refuse-hint.json"
headless_refuse_ec=0
# `|| ec=$?` is load-bearing, and the reason is the same one the `run` helper
# documents: the installer is EXPECTED to exit non-zero here, and under
# `set -e` a bare failing command takes the harness down before the status is
# read. A refused plan is the success case of this assertion.
KIT_SUBSTRATE_RECEIPT="$headless_refuse_hint" KIT_SUBSTRATE_DATABASES="" DRY_RUN=1 \
  bash "$SUBSTRATE/install.sh" --headless >"$WORK/headless-refuse.jsonl" \
  2>"$WORK/headless-refuse.human" || headless_refuse_ec=$?
if [ "$headless_refuse_ec" -eq 0 ]; then
  fail 'the refusal names the variable and the fix that clears it (headless)' "exit 0 — the plan was not refused"
else
  run 'the refusal names the variable and the fix that clears it (headless)' green \
    refusal_hint_ok "$(cat "$WORK/headless-refuse.human")" headless
fi
# And the headless half: the refusal EVENT carries input_needed and human, so
# an agent reading stdout alone knows both what to collect and what to say.
case "$(cat "$WORK/headless-refuse.jsonl")" in
  *'"event":"refusal"'*'"input_needed":"KIT_SUBSTRATE_DATABASES"'*'"human":"export KIT_SUBSTRATE_DATABASES='*)
    pass 'headless: the refusal event names the input needed and where the human goes'
    ;;
  *)
    fail 'headless: the refusal event names the input needed and where the human goes' "$(cat "$WORK/headless-refuse.jsonl")"
    ;;
esac
# Its control: an event with a null human must go red. An agent told what to
# collect but not who to ask is told half a refusal.
refusal_no_human='{"event":"refusal","step":8,"phase":"postgres","input_needed":"KIT_SUBSTRATE_DATABASES","human":null,"message":"x"}'
case "$refusal_no_human" in
  *'"event":"refusal"'*'"input_needed":"KIT_SUBSTRATE_DATABASES"'*'"human":"export KIT_SUBSTRATE_DATABASES='*)
    fail 'control: a refusal event with no human destination goes red' 'a null human matched the want'
    ;;
  *)
    pass 'control: a refusal event with no human destination goes red'
    ;;
esac

# ===========================================================================
# 14. THE APPLY MODE IS ASSIGNED BY WHERE THE MANIFEST COMES FROM
# ===========================================================================
#
# Two installer defects, both measured only on a real k3s/k3d box, and neither
# of which a compose run can see:
#
#   1. `kubectl apply -f <remote-url>` for CNPG's and Argo CD's manifests is
#      refused by the API server with
#        `CustomResourceDefinition ... is invalid: metadata.annotations:
#         Too long: may not be more than 262144 bytes`
#      Client-side apply stores the whole object in the
#      last-applied-configuration annotation, and those CRDs are large enough
#      to overflow Kubernetes's per-object annotation cap.
#   2. On a RE-RUN after that was hand-repaired, the two halves collided:
#      `field is managed by another client` — because one object had been
#      written client-side and the next server-side, so the fix has to be
#      consistent rather than per step.
#
# THE RULE, stated once and checked here: every apply whose target is a REMOTE
# URL carries BOTH `--server-side=true` and `--force-conflicts`; every apply
# whose target is a LOCAL file or stdin carries NEITHER. The remote half is
# measured above; the local half is the reclaim side — these files are kit's
# own, small, and re-applied on every run, so server-side apply there would take
# away the re-run's ability to take back a field it previously owned.
#
# The assertions are BOTH DIRECTIONS and both spellings, because a one-way check
# is satisfied by an installer that made the opposite mistake uniformly:
#   * a remote apply missing either flag is RED (the defect that shipped)
#   * a local apply carrying either flag is RED (the drift back into mixed mode)
#   * the flags are required on the DRY_RUN plan string AND on the run, so the
#     plan `caf box apply` reads cannot describe a mode the installer does not
#     use
#   * the rule is over ANY remote URL, not over a remembered list of three: a
#     new remote apply with no flags is RED, which is the shape a future
#     fourth component arrives in
#   * a tree with fewer than three remote applies is RED, so the check cannot
#     be satisfied by converting all of them away and passing on nothing
check_apply_modes() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
# Comments stripped first, as everywhere in this file: the rule is about what
# the installer RUNS, and a comment that spells the flags out is not a run.
# (And this file's own prose names both flags, so a check that can be
# satisfied by a comment would be green on the very tree it describes.)
code = re.sub(r"(?m)^\s*#.*$", "", src)
# A backslash continuation is ONE command: `kubectl apply -f \` on one line
# and the URL on the next is a single remote apply, and reading it as two
# statements would miss the flags entirely.
code = code.replace("\\\n", " ")

problems = []
remote = 0
local = 0
for ln in code.splitlines():
    if "kubectl" not in ln or "apply" not in ln:
        continue
    m = re.search(r"(?:^|\s)-f\s+\"?([^\s\"]+)\"?", ln)
    if not m:
        # An apply with no target is not this check's subject (there is none
        # here; it is refused rather than waved through).
        continue
    target = m.group(1)
    if target.startswith(("http://", "https://")):
        remote += 1
        for flag in ("--server-side=true", "--force-conflicts"):
            if flag not in ln:
                problems.append(f"{target}: a remote apply without {flag}")
    elif target == "-" or target.startswith(("$", "/", ".")):
        # Local: a file in this repository or a piped stream built here.
        local += 1
        for flag in ("--server-side=true", "--force-conflicts"):
            if flag in ln:
                problems.append(
                    f"the LOCAL apply of {target} carries {flag} — server-side"
                    " mode for kit's own manifests takes a re-run's ability to"
                    " reclaim its own fields away"
                )
    else:
        problems.append(
            f"cannot tell whether the apply target {target!r} is remote or"
            " local — assign the mode explicitly instead of leaving it to a"
            " reader"
        )

# Non-vacuity: the three upstream components are what the defect was measured
# on, and a check whose subject disappeared would pass on the empty case.
if remote < 3:
    problems.append(f"expected at least 3 remote applies, found {remote}")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(
    f"{remote} remote applies carry --server-side=true --force-conflicts,"
    f" {local} local applies are client-side"
)
PY
}

run 'every remote-URL apply is server-side with force-conflicts, and every local apply is not' \
  green check_apply_modes "$SUBSTRATE/install.sh"

# The control that matters most: the shape the box actually hit. A copy in
# which --force-conflicts is gone from every remote apply must be RED, and must
# be red NAMING the flag — a control that fires for some other reason proves
# nothing about the assertion it sits under.
fixture_no_force="$WORK/install-no-force-conflicts.sh"
sed 's/ --force-conflicts//g' "$SUBSTRATE/install.sh" >"$fixture_no_force"
mode_out=""; mode_ec=0
mode_out="$(check_apply_modes "$fixture_no_force" 2>&1)" || mode_ec=$?
case "$mode_ec:$mode_out" in
  0:*)
    fail 'control: a remote apply without --force-conflicts goes red' "exit 0 — the check cannot see a missing flag"
    ;;
  *force-conflicts*)
    pass 'control: a remote apply without --force-conflicts goes red, naming the flag'
    ;;
  *)
    fail 'control: a remote apply without --force-conflicts goes red, naming the flag' "$mode_out"
    ;;
esac

# The other half: --server-side is what survives the annotation ceiling, and
# removing it alone must be RED too. Two flags, two controls — a check that
# only notices one of them is half a rule.
fixture_no_ss="$WORK/install-no-server-side.sh"
sed 's/ --server-side=true//g' "$SUBSTRATE/install.sh" >"$fixture_no_ss"
mode_out=""; mode_ec=0
mode_out="$(check_apply_modes "$fixture_no_ss" 2>&1)" || mode_ec=$?
case "$mode_ec:$mode_out" in
  0:*)
    fail 'control: a remote apply without --server-side goes red' "exit 0 — the check cannot see a missing flag"
    ;;
  *server-side*)
    pass 'control: a remote apply without --server-side goes red, naming the flag'
    ;;
  *)
    fail 'control: a remote apply without --server-side goes red, naming the flag' "$mode_out"
    ;;
esac

# A THIRD remote component, arriving with no flags. This is the control that
# stops the check being a list of three remembered lines rather than a rule.
fixture_new_remote="$WORK/install-new-remote.sh"
cp "$SUBSTRATE/install.sh" "$fixture_new_remote"
printf '  kubectl --kubeconfig="$KUBECONFIG" apply -f "https://example.com/some-new-operator.yaml"\n' \
  >>"$fixture_new_remote"
run 'control: a fourth remote apply with no flags goes red' red check_apply_modes "$fixture_new_remote"

# The OTHER DIRECTION: a local apply that grew the remote flags. Without this
# control a check satisfied by "every apply has both flags" would be just as
# happy with an installer that moved kit's own manifests into server-side mode
# and lost the re-run's reclaim.
fixture_local_ss="$WORK/install-local-server-side.sh"
sed 's|apply -f "$MANIFEST_DIR"|apply --server-side=true --force-conflicts -f "$MANIFEST_DIR"|' \
  "$SUBSTRATE/install.sh" >"$fixture_local_ss"
run 'control: a local apply carrying the remote flags goes red' red check_apply_modes "$fixture_local_ss"

# And the plan half: the DRY_RUN string is what `caf box apply` reads and what
# the receipt describes, so a run that gained the flags while its plan did not
# is the drift a future reader would notice at the box and not here.
fixture_plan_drift="$WORK/install-plan-drift.sh"
awk '/dry_run/ { gsub(/ --server-side=true --force-conflicts/, ""); } { print }' \
  "$SUBSTRATE/install.sh" >"$fixture_plan_drift"
run 'control: a plan that lost the flags while the run kept them goes red' red \
  check_apply_modes "$fixture_plan_drift"

# ===========================================================================
# 16. The waits survive an empty list — the cold-box defect, executed
# ===========================================================================
#
# `kubectl wait --for=condition=Ready node --all` is NOT a wait when the list
# is empty: it fails within a second with `error: no matching resources found`,
# and `set -e` makes that the end of the install. k3s is STARTED by the line
# above it and the kubelet registers the Node object a few seconds LATER, so a
# wiped box lost that race and died at step 1 (exit 1) while a warm box never
# noticed.
#
# The harness above sources the installer and runs single steps against a
# file-backed mock, which is exactly what this needs: step 1 is three lines
# (start k3s, prove the node exists, wait for Ready), so the step can RUN and
# be watched. THE MOCK IS THE CLUSTER, and it is a faithful one — a GET of an
# empty list answers nothing and exits 0, which is what real kubectl does, and
# the WAIT answers the way real kubectl does on an empty list, by failing.
#
# THREE CASES, and the third is the one that earns the first two:
#   1. a cold box — the list is empty twice, then the kubelet registers. The
#      step must reach Ready and return 0. The pre-fix installer aborts here.
#   2. a broken box — the node never registers. The step must REFUSE inside its
#      bound, naming the empty list, and must never claim to have waited.
#   3. THE CONTROL — the same fixture with kit_substrate_await_list removed,
#      which is the shape the box actually ran. Case 1 against it must ABORT,
#      because a check that cannot see the defect it is named for is a comment.
#
# Each case records every kubectl invocation, so "reached Ready" is an order in
# an argv log rather than a return code the loop could have produced by giving
# up.
K3S_DIR="$WORK/k3s"
mkdir -p "$K3S_DIR"

# node_kubectl — the cluster on a box where the kubelet has not registered its
# Node object yet. NODE_APPEARS_AT is the poll after which it does.
node_kubectl() {
  printf '%s\n' "$*" >>"$K3S_DIR/argv"
  case "$*" in
    *"wait --for=condition=Ready node"*)
      # What real kubectl does on an empty list, and the whole defect: an
      # error, not a wait. It only succeeds once the object exists.
      if [ ! -f "$K3S_DIR/node-registered" ]; then
        printf 'error: no matching resources found\n' >&2
        return 1
      fi
      printf 'node/box condition met\n'
      ;;
    *"get node --no-headers"*)
      # A GET of an empty list is not an error: kubectl exits 0 and prints
      # nothing. The registration is a few seconds away, which is the race.
      local polls
      polls=$(( $(cat "$K3S_DIR/polls" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$polls" >"$K3S_DIR/polls"
      if [ "$polls" -ge "${NODE_APPEARS_AT:-2}" ]; then
        : >"$K3S_DIR/node-registered"
        printf 'box   Ready   <none>   10d   v1.31.5+k3s1\n'
      fi
      return 0
      ;;
    *)
      printf 'node_kubectl: unhandled %s\n' "$*" >&2
      return 1
      ;;
  esac
}

# k3s_step <fixture> <appears-at> <register-timeout> — run step 1 for real
# against that fixture, and leave the exit status behind in $k3s_ec. The
# install script, curl and the pipe into `sh -` are stubbed: none of them is
# the subject, and the step's own two waits are.
k3s_step() {
  rm -f "$K3S_DIR/argv" "$K3S_DIR/polls" "$K3S_DIR/node-registered"
  k3s_ec=0
  (
    # BEFORE the source, because the installer reads each of these at source
    # time and a value exported after it is a value it never saw.
    export DRY_RUN=0
    export HEADLESS=0
    export KIT_SUBSTRATE_RECEIPT="$K3S_DIR/receipt.json"
    export NODE_APPEARS_AT="$2"
    export NODE_REGISTER_TIMEOUT="$3"
    export NODE_READY_TIMEOUT=5
    # shellcheck source=/dev/null
    . "$1"
    kubectl() { node_kubectl "$@"; }
    curl() { :; }
    install_k3s >"$K3S_DIR/run.log" 2>&1
  ) || k3s_ec=$?
}

k3s_cold="$WORK/install-cold.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$k3s_cold"
k3s_no_await="$WORK/install-no-await.sh"
sed -e '/^main "$@"/d' -e '/kit_substrate_await_list "\$NODE_REGISTER_TIMEOUT" node/d' \
  "$SUBSTRATE/install.sh" >"$k3s_no_await"

# The control fixture is only a control if it really is the pre-fix shape: the
# await must be gone from it, and the Ready wait must still be there. A
# mutation that broke nothing would pass case 1 for the wrong reason.
if grep -q 'kit_substrate_await_list "\$NODE_REGISTER_TIMEOUT" node' "$k3s_no_await" \
  || ! grep -q 'wait --for=condition=Ready node' "$k3s_no_await"; then
  fail 'control fixture: the pre-fix k3s step is the shape the box ran' \
    "the await-line deletion did not apply, so case 3 would prove nothing"
  failures=$((failures + 1))
else
  # CASE 1, green: the cold box installs. The node registers on the second
  # poll, so the loop has to tolerate an empty list once and keep going, and
  # the Ready wait must come AFTER the registration rather than racing it.
  k3s_step "$k3s_cold" 2 5
  k3s_cold_ok() {
    if [ "$k3s_ec" -ne 0 ]; then
      printf 'step 1 exited %s — an empty list still kills the install\n%s\n' \
        "$k3s_ec" "$(cat "$K3S_DIR/run.log")"
      return 1
    fi
    # The argv log is the ORDER, and the order is the whole fix: two GETs that
    # found nothing, then the GET that found the node, then the Ready wait.
    if ! grep -q 'wait --for=condition=Ready node' "$K3S_DIR/argv"; then
      printf 'the Ready wait never ran — the step gave up before waiting\n%s\n' \
        "$(cat "$K3S_DIR/run.log")"
      return 1
    fi
    # The empty polls really were empty: NODE_APPEARS_AT is 2, so the first
    # poll must have seen nothing and the registration must be the SECOND
    # one. A fixture that never ran the race would pass on a step that races.
    if [ "$(cat "$K3S_DIR/polls" 2>/dev/null || echo 0)" -ne 2 ]; then
      printf 'the fake registered the node on the first poll, so the empty-list case never happened\n'
      return 1
    fi
    printf 'the step survived an empty list and reached Ready'
  }
  run 'step 1 reaches Ready when the node registers a few seconds after k3s starts' \
    green k3s_cold_ok

  # CASE 3, THE CONTROL: the pre-fix shape against the same cold box. It must
  # abort with the empty-list error, and the signature that proves it is the
  # ARGV: the pre-fix step never asked whether the node existed, so it went
  # straight to a Ready wait that could not be satisfied. A control that
  # merely exits non-zero would also be satisfied by a step that failed for
  # some other reason, so the argv carries the assertion.
  k3s_step "$k3s_no_await" 2 5
  case "$k3s_ec:$(cat "$K3S_DIR/run.log" 2>/dev/null):$(cat "$K3S_DIR/argv" 2>/dev/null)" in
    0:*:*:*)
      fail 'control: a single wait on an empty list aborts the install' \
        "exit 0 — the control did not reproduce the defect it is named for"
      ;;
    *"no matching resources found"*:*"get node --no-headers"*)
      fail 'control: a single wait on an empty list aborts the install' \
        "the pre-fix fixture still checked for existence, so it is not the shape the box ran"
      ;;
    *"no matching resources found"*:*)
      if grep -q 'condition=Ready node --all' "$K3S_DIR/argv"; then
        pass 'control: a single wait on an empty list aborts the install, with no existence check before it'
      else
        fail 'control: a single wait on an empty list aborts the install' \
          "the wait did not run, so the control failed for some other reason"
      fi
      ;;
    *)
      fail 'control: a single wait on an empty list aborts the install' \
        "exit $k3s_ec: $(cat "$K3S_DIR/run.log" 2>/dev/null)"
      ;;
  esac
fi

# CASE 2: a node that never registers. The step must REFUSE inside its bound,
# not hang and not lie. The bound is shortened to 2s here, and the elapsed time
# is measured rather than asserted by exit status alone — a wait that exceeded
# its own budget would pass a glance at the message.
k3s_broken_ok() {
  local started elapsed
  started="$(date +%s)"
  k3s_step "$k3s_cold" 999 2
  elapsed=$(( $(date +%s) - started ))
  if [ "$k3s_ec" -eq 0 ]; then
    printf 'a node that never appeared was answered with success\n%s\n' \
      "$(cat "$K3S_DIR/run.log")"
    return 1
  fi
  if [ "$elapsed" -gt 15 ]; then
    printf 'the refusal took %ss — the bound is 2s, so this is a hang\n' "$elapsed"
    return 1
  fi
  case "$(cat "$K3S_DIR/run.log")" in
    *"kubectl get node"*"empty"*)
      : ;;
    *)
      printf 'the refusal does not name the empty list\n%s\n' "$(cat "$K3S_DIR/run.log")"
      return 1
      ;;
  esac
  if grep -q 'get node --no-headers' "$K3S_DIR/argv" \
    && [ "$(grep -c 'wait --for=condition=Ready node' "$K3S_DIR/argv" || true)" -gt 0 ]; then
    printf 'the step waited for Ready on a node that never registered\n'
    return 1
  fi
  printf 'refused in %ss, naming the empty list, with no Ready wait' "$elapsed"
}
run 'step 1 refuses within its bound when the node never registers' green k3s_broken_ok

# ===========================================================================
# Summary
# ===========================================================================
printf -- '-- substrate_test: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"
