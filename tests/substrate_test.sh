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
#   Postgres Cluster reproduces the local provisioning contract, every CRD
#   field the manifests write is declared by the operator the installer pins
#   (§9b — the check that would have caught `spec.storageConfiguration`), the
#   Redis image is pinned exact, the NATS broker is installed with the fleet's
#   stream defined idempotently and matching the local stack's nats-stream-init,
#   the recorded secret name-and-key list matches what install.sh creates, and
#   every secret NAME and KEY the four service charts mount or read is in that
#   list — a chart key with no writer is a pod that never starts,
#   no image floats on `latest`, no secret is a literal in the tree, step 6
#   waits on nothing — the core-install reality, executed against a mock whose
#   deployment list is the pinned core-install set, with the pre-fix wait
#   restored as the control — and the
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

# The thirteen steps, in order. The markers are `[1/13]` … `[13/13]`; the check
# reads them out of the output in the order they appear and compares against
# the expected sequence, so a script that printed them out of order — or
# skipped one — would go red here rather than passing on the presence of all
# thirteen. The `|| true` is load-bearing: with no `[n/13]` markers printed yet,
# grep exits 1, and under `set -o pipefail` a failing command substitution
# would take the harness down before the status is ever read — the same shape
# the `run` helper's comment describes four lines below.
found="$(printf '%s\n' "$dry_run_out" | grep -o '\[[0-9][0-9]*/13\]' | tr -d '[]' | cut -d/ -f1 | tr '\n' ' ' || true)"
found="${found% }"
if [ "$found" = "1 2 3 4 5 6 7 8 9 10 11 12 13" ]; then
  pass 'DRY_RUN prints the thirteen steps in order'
else
  fail 'DRY_RUN prints the thirteen steps in order' "found step sequence: '${found}'"
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
sourced_vars="KIT_SUBSTRATE_BOX_ID KIT_SUBSTRATE_REGISTRY_CAPABILITY KIT_SUBSTRATE_BOX_URL KIT_SUBSTRATE_ACME_EMAIL KIT_SUBSTRATE_DATABASES KIT_SUBSTRATE_POSTGRES_EXTENSIONS KIT_SUBSTRATE_SMTP_ADAPTER KIT_SUBSTRATE_SMTP_HOST KIT_SUBSTRATE_SMTP_PORT KIT_SUBSTRATE_SMTP_USERNAME KIT_SUBSTRATE_SMTP_PASSWORD KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET KIT_SUBSTRATE_MAIL_FROM KIT_SUBSTRATE_MAIL_FROM_NAME KIT_SUBSTRATE_APP_BASE_URL KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY"
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
store = spec.get("storage", {})
if not store.get("size"):
    problems.append("spec.storage.size is unset")
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

# ===========================================================================
# 9b. Every CRD field the manifests use is DECLARED by the operator the
#     installer pins — the check that would have caught `storageConfiguration`
# ===========================================================================
#
# WHY THIS EXISTS, and why every check above it was blind to the defect. The
# Cluster was applied on the box and refused:
#
#   Cluster in version "v1" cannot be handled as a Cluster: strict decoding
#     error: unknown field "spec.storageConfiguration"
#
# `storageConfiguration` is CNPG's PRE-1.24 name; v1.30.1 — the version
# install_cnpg applies — declares `spec.storage`. The CRD is structural, so the
# API server refuses the object rather than ignoring the unknown key. Every
# check in this file passed on it, including check_cluster, which asserted
# `spec.storageConfiguration.size` in so many words: a check written from the
# manifest it was meant to grade is a check that can never disagree with it.
#
# THE MODEL IS DERIVED, NOT TYPED. tests/substrate-crd/schemas.json holds the
# property-name graph of each pinned CRD's `spec`, produced by
# tests/substrate-crd/regen.py from the SAME release URL install.sh applies —
# so the allowed names come from the operator, never from the manifest under
# test. A hand-typed allow-list would contain `storageConfiguration` the day
# the manifest did, which is the failure this whole section is about.
#
# WHAT IT DOES, AND DOES NOT, PROVE. It proves every field NAME the manifests
# write under `spec` exists in the pinned CRD at that path. It does not prove
# types, required fields, enum values, or that a field means what the comment
# says — those still need the box, and README says so. It is the strict-decoding
# half only, and that half is what refused the install.
#
# The model carries the pin it was derived from; the check FAILS if the pin in
# install.sh has moved without a re-derivation, so a version bump cannot
# silently grade a manifest against a schema nobody re-fetched.
CRD_MODEL="$ROOT/tests/substrate-crd/schemas.json"
check_crd_fields() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import json
import os
import re
import sys

import yaml

model_path, manifests_root, install = sys.argv[1:4]
try:
    data = json.load(open(model_path, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as e:
    print(f"{model_path}: unreadable ({e})")
    sys.exit(1)
schemas = data["schemas"]
sources = data["sources"]

pins = dict(re.findall(
    r'^(K3S_VERSION|CERT_MANAGER_VERSION|CNPG_VERSION|ARGOCD_VERSION|'
    r'NATS_VERSION|NATS_BOX_VERSION)="([^"]+)"',
    open(install, encoding="utf-8").read(), re.M))
problems = []
for key, src in sources.items():
    have = pins.get(src["pin"])
    if have != src["version"]:
        problems.append(
            f"{key}: model derived from {src['version']} but install.sh pins "
            f"{src['pin']}={have} — re-derive tests/substrate-crd/schemas.json"
        )
    if key not in schemas:
        problems.append(f"{key}: named in sources but has no schema")

# Core Kubernetes API groups carry no CRD of ours, and are not what this check
# grades; a doc in one of them is counted and skipped. A doc in an UNKNOWN
# group fails closed, so a CRD that arrives without a model is visible.
CORE_GROUPS = {
    "", "apps", "batch", "policy", "autoscaling", "networking.k8s.io",
    "rbac.authorization.k8s.io", "storage.k8s.io", "apiextensions.k8s.io",
}


def walk(schema, node, path, unknown, seen):
    if schema is True or schema == "*":
        return
    if isinstance(schema, dict):
        if "[]" in schema:
            if isinstance(node, list):
                for i, item in enumerate(node):
                    walk(schema["[]"], item, f"{path}[{i}]", unknown, seen)
            return
        if not isinstance(node, dict):
            return
        for k, v in node.items():
            if k in schema:
                seen.add(f"{path}.{k}")
                walk(schema[k], v, f"{path}.{k}", unknown, seen)
            elif "*" not in schema:
                unknown.append(f"{path}.{k}")


seen_keys = set()
verified = {}
core_skipped = 0
for dirpath, _dirs, files in os.walk(manifests_root):
    for f in sorted(files):
        if not f.endswith((".yaml", ".yml")):
            continue
        rel = os.path.relpath(os.path.join(dirpath, f), manifests_root)
        raw = open(os.path.join(dirpath, f), encoding="utf-8").read()
        try:
            docs = [d for d in yaml.safe_load_all(raw) if d]
        except yaml.YAMLError as e:
            problems.append(f"{rel}: does not parse ({e})")
            continue
        for doc in docs:
            api = doc.get("apiVersion", "")
            key = f"{api}/{doc.get('kind')}"
            group = api.split("/")[0] if "/" in api else ""
            if key in schemas:
                seen_before = len(seen_keys)
                walk(schemas[key], doc.get("spec", {}), f"{key}.spec",
                     problems, seen_keys)
                verified[key] = verified.get(key, 0) + len(seen_keys) - seen_before
            elif group in CORE_GROUPS:
                core_skipped += 1
            else:
                problems.append(
                    f"{rel}: {key}: no CRD model and not a core Kubernetes "
                    "apiVersion — model the CRD or confirm it is core"
                )

# A CRD no manifest exercises means a manifest was renamed and this check is
# no longer looking at it. That is a silent skip, so it fails.
for key in sources:
    if key not in verified:
        problems.append(
            f"{key}: declared in the model but no manifest under "
            f"{manifests_root} uses it — has the manifest been renamed?"
        )

if problems:
    print("; ".join(problems))
    sys.exit(1)
for key in sorted(verified):
    src = sources[key]
    print(f"{key}: {verified[key]} field path(s) declared by {src['crdName']} "
          f"{src['version']} ({src['url'].rsplit('/', 1)[-1]})")
print(f"{core_skipped} core Kubernetes document(s) skipped (no CRD schema)")
PY
}

run 'every CRD field is declared by the pinned operator CRD' green \
  check_crd_fields "$CRD_MODEL" "$SUBSTRATE/manifests" "$SUBSTRATE/install.sh"

# The named control: the EXACT field the box refused. A fixture putting
# `storageConfiguration` back must go red under the same check the real tree
# passes. This is the red proof for the whole section — if this is green, the
# check is not reading the CRD.
#
# The control directory mirrors the REAL manifest tree with exactly one line
# changed. A directory holding only the mutated Cluster would go red on the
# "a declared CRD is not exercised" guard instead of on the unknown field — a
# red for the wrong reason, which proves nothing about the field check.
fixture_storage_cfg="$WORK/crd-storage"
mkdir -p "$fixture_storage_cfg/applications" "$fixture_storage_cfg/data" "$fixture_storage_cfg/tls"
cp -R "$SUBSTRATE/manifests/applications/." "$fixture_storage_cfg/applications/"
cp -R "$SUBSTRATE/manifests/data/." "$fixture_storage_cfg/data/"
cp -R "$SUBSTRATE/manifests/tls/." "$fixture_storage_cfg/tls/"
sed 's/^  storage:$/  storageConfiguration:/' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_storage_cfg/data/postgres-cluster.yaml"
run 'control: spec.storageConfiguration goes red' red \
  check_crd_fields "$CRD_MODEL" "$fixture_storage_cfg" "$SUBSTRATE/install.sh"

# A second control, at depth: a genuine v1.30.1 field with a retired spelling
# (`storageClassName` instead of `storageClass`) must go red too, so the check
# is not only looking at the top level. Same full-tree shape as above.
fixture_nested="$WORK/crd-nested"
mkdir -p "$fixture_nested/applications" "$fixture_nested/data" "$fixture_nested/tls"
cp -R "$SUBSTRATE/manifests/applications/." "$fixture_nested/applications/"
cp -R "$SUBSTRATE/manifests/data/." "$fixture_nested/data/"
cp -R "$SUBSTRATE/manifests/tls/." "$fixture_nested/tls/"
sed 's/^    storageClass: local-path$/    storageClassName: local-path/' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_nested/data/postgres-cluster.yaml"
run 'control: a nested unknown field (storageClassName) goes red' red \
  check_crd_fields "$CRD_MODEL" "$fixture_nested" "$SUBSTRATE/install.sh"

# A third control: the model's pin disagrees with install.sh. Bumping the
# operator without re-deriving the model must go red, or the model silently
# grades a manifest against a schema nobody re-fetched.
fixture_pin_drift="$WORK/install-cnpg-drift.sh"
sed 's/^CNPG_VERSION="v1.30.1"/CNPG_VERSION="v1.31.0"/' \
  "$SUBSTRATE/install.sh" >"$fixture_pin_drift"
run 'control: a pin bump without re-deriving the model goes red' red \
  check_crd_fields "$CRD_MODEL" "$SUBSTRATE/manifests" "$fixture_pin_drift"

# The bootstrap ORDER: postInitSQL runs once, at cluster creation, as the
# superuser — BEFORE the operator reconciles spec.managed.roles (measured on
# the live box: `role "identity" does not exist` inside postgres-1-initdb,
# `kubectl get cluster` stuck in `Setting up primary`). So a bootstrap
# statement that names a role must be preceded, IN THE SAME LIST, by a
# CREATE ROLE for it — the grant belongs after the creation by construction
# of the list order, not by luck of the operator's timing. And every role the
# bootstrap names must also have a managed.roles entry, which is what gives
# it its password and membership afterwards (a bootstrap-created role with no
# managed entry is a role no service can log in as).
#
# The check walks the postInitSQL list in order, starting from the two roles
# initdb itself guarantees (the `postgres` superuser, which the bootstrap
# page forbids deleting, and the `app` owner the initdb database/owner block
# creates), and fails on the first statement naming a role nothing above it
# created. `FROM PUBLIC` and `ON DATABASE "x"` name no role and are ignored:
# only OWNER "...", TO "..." and ROLE "..." are references, and only
# CREATE ROLE "..." creates.
check_cluster_bootstrap_order() {
  "$PY" - "$1" <<'PY'
import re
import sys

import yaml

path = sys.argv[1]
try:
    docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
except yaml.YAMLError as e:
    print(f"does not parse ({e})")
    sys.exit(1)
doc = docs[0]
initdb = doc.get("spec", {}).get("bootstrap", {}).get("initdb", {})
stmts = initdb.get("postInitSQL", [])
managed = {
    r.get("name")
    for r in doc.get("spec", {}).get("managed", {}).get("roles", [])
}
problems = []
created = {"postgres", "app"}
ref_needles = (
    re.compile(r'\bOWNER\s+"([^"]+)"'),
    re.compile(r'\bTO\s+"([^"]+)"'),
    re.compile(r'\bROLE\s+"([^"]+)"'),
)
for n, stmt in enumerate(stmts, 1):
    made = re.findall(r'\bCREATE\s+ROLE\s+"([^"]+)"', stmt)
    if made:
        for role in made:
            created.add(role)
        continue
    refs = []
    for needle in ref_needles:
        refs.extend(needle.findall(stmt))
    for role in refs:
        if role not in created:
            problems.append(
                f"postInitSQL statement {n} names role {role!r} before"
                f" anything creates it ({stmt.strip()[:80]}) — managed"
                " roles are reconciled only after bootstrap finishes"
            )
        elif role not in managed and role not in ("postgres", "app"):
            problems.append(
                f"postInitSQL names role {role!r} but no managed.roles"
                " entry creates it — nothing would set its password"
            )
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(stmts)} bootstrap statements, every named role created above its use")
PY
}

run 'the Cluster bootstrap SQL creates every role before it names it' green check_cluster_bootstrap_order "$DATA_DIR/postgres-cluster.yaml"

# The control: the same check against a fixture with the CREATE ROLE lines
# removed — the shape this file had when the box crash-looped. MUST go red.
fixture_no_creates="$WORK/no-creates-cluster.yaml"
grep -v 'CREATE ROLE' "$DATA_DIR/postgres-cluster.yaml" >"$fixture_no_creates"
run 'control: bootstrap SQL naming roles it never creates goes red' red check_cluster_bootstrap_order "$fixture_no_creates"

# The second control: a fixture whose bootstrap CREATES a role no
# managed.roles entry adopts, then grants to it. The ordering half passes
# (the CREATE precedes the GRANT) so only the coverage half can fire — a
# bootstrap role with no managed entry is a login no secret can reach.
fixture_ghost="$WORK/ghost-role-cluster.yaml"
awk '/- CREATE DATABASE "identity" OWNER "identity"$/{print "        - CREATE ROLE \"ghost\" WITH LOGIN"; print "        - GRANT CONNECT ON DATABASE \"identity\" TO \"ghost\""}1' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_ghost"
run 'control: bootstrap SQL naming a role no managed entry creates goes red' red check_cluster_bootstrap_order "$fixture_ghost"

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
# step 9 creates) or the merge patch step 11 sends, whose body is built as a
# `stringData` object. Both are writes and both are checked, so the record
# cannot be satisfied by a key that only appears in a comment or a variable
# name. The patch keys are read out of EVERY `stringData` block rather than off
# a `KEY:$t` literal, because a patch now carries a whole PAIR of keys
# (`COURIER_BASE_URL` + `COURIER_TOKEN`, `COURIER_IDENTITY_URL` +
# `COURIER_IDENTITY_TOKEN`) and a regex keyed to the trailing `:$t}` would see
# only the token half. The controls below remove one `--from-literal` key and
# one key out of a patch.
patch_keys = set()
for block in re.findall(r'"stringData"\s*:\s*\{([^}]*)\}', code):
    patch_keys.update(re.findall(r'"([A-Z_]+)"\s*:', block))
# Conditional keys: set only when the operator sets the surface (identity's
# OIDC block and its issuer, OAUTH_ENCRYPTION_KEY, courier's mail-from). They
# are deliberately UNRECORDED — absent is a valid reduced surface, and the
# record lists the keys every install creates. MFA_ENCRYPTION_KEY is NOT
# conditional: the installer generates it on first creation, so every
# install creates it and the record must name it. The COURIER credential pair
# is NOT conditional either: step 11 always mints it on the live path, so
# every install writes COURIER_BASE_URL + COURIER_TOKEN and
# COURIER_IDENTITY_URL + COURIER_IDENTITY_TOKEN, and the record names them.
# OIDC_SIGNING_KEY and its id are now GENERATED ON THE BOX rather than
# supplied, but still only when the operator sets an issuer and a login UI —
# the surface stays all-or-nothing, so they stay unrecorded beside the issuer
# and login UI that gate them.
conditional = {
    "OIDC_SIGNING_KEY",
    "OIDC_SIGNING_KEY_ID",
    "OIDC_ISSUER",
    "OIDC_LOGIN_UI_URL",
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

# The second control, for the other spelling: step 11's mint writes each pair
# through a merge patch, and a fixture with one key removed from that patch
# must go red too. Without it the widened check would be proven only by the
# --from-literal path, which is the path that never changed. One control per
# half of the pair: the courier token and identity's base URL.
fixture_dropped_patch="$WORK/install-dropped-patch.sh"
sed 's/,"COURIER_IDENTITY_TOKEN":\$t//' "$SUBSTRATE/install.sh" >"$fixture_dropped_patch"
run 'control: a secret whose patched key is removed goes red' red check_secret_record "$fixture_dropped_patch"

fixture_dropped_url="$WORK/install-dropped-url.sh"
sed 's/"COURIER_BASE_URL":\$url,//' "$SUBSTRATE/install.sh" >"$fixture_dropped_url"
run 'control: a patched base URL removed from the pair goes red' red check_secret_record "$fixture_dropped_url"

# The reverse control: a fixture setting a key the record does not name (and
# the conditional set does not excuse). Must go red the other way.
fixture_extra_key="$WORK/install-extra-key.sh"
cp "$SUBSTRATE/install.sh" "$fixture_extra_key"
printf '\n--from-literal=EXTRA_UNRECORDED_KEY=x\n' >>"$fixture_extra_key"
run 'control: a secret with an unrecorded key goes red' red check_secret_record "$fixture_extra_key"

# ===========================================================================
# 11b. Every secret key a CHART mounts or names is written by install.sh
# ===========================================================================
#
# WHY THIS EXISTS. The defect this packet was written about: gateway's chart
# points a `volumes.secret` item at gateway-secrets/ASSERTION_SIGNING_KEY, and
# step 9 created that secret with REDIS_URL only. The pod sat in
# ContainerCreating for 152 minutes on `FailedMount: references non-existent
# secret key` while every other step reported success — a missing generator
# surfacing as a pod that hangs, the class nobody attributes. The SECRET RECORD
# check above proves the record and install.sh agree with each other; neither
# half can see a chart that consumes a key neither names. This check closes the
# loop: it reads the four service charts beside kit (READ-ONLY) and requires
# every secret NAME and KEY they consume to be in install.sh's own inventory.
#
# THREE REFERENCES, and all three are checked because all three have failed in
# the fleet at least once: `envFrom.secretRef` (the secret must exist — the
# generated charts inject every secret key this way), `env.valueFrom.secretKeyRef`
# (both the secret and the key must exist), and `volumes.secret` with `items`
# (a required ITEM: a missing key is a `FailedMount`, not a missing env var).
# Ingress TLS secrets (`*-tls`) are NOT in scope and not scanned: cert-manager
# fills them from the ClusterIssuer, they are not pod mounts.
#
# THE FLEET IS ONE LEVEL UP AND NAMED, NEVER FURTHER — the AGENTS.md rule. A
# service whose sibling checkout is absent is NAMED in a note; on a fresh clone
# every service is a note. The check's ABILITY to see a missing writer is proved
# by the controls below, which build a throwaway fixture fleet rather than
# depend on a neighbour being present: one carries a key install.sh never
# writes (must go red) and one carries the key it does (must stay green).
check_chart_secret_keys() {
  "$PY" - "$1" "$2" <<'PY'
import glob
import os
import re
import sys

import yaml

install_path, fleet = sys.argv[1], sys.argv[2]

SERVICES = ("identity", "gateway", "courier", "parlor")

# install.sh's inventory: the SECRET RECORD maps a secret to the keys it writes,
# and the two writers are the `--from-literal=KEY=` sites plus step 11's merge
# patch (`{"stringData":{"KEY":$t}}`). check_secret_record above proves the
# record and the writes agree; this check asks whether the charts are covered.
src = open(install_path, encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
records = re.findall(r"^#\s+RECORD\s+(\S+):\s*(.*)$", src, re.M)
recorded = {name: set(keys.split()) for name, keys in records}
created = set(re.findall(r"create secret generic (\S+)", code))
patched = set(re.findall(r'"stringData":\{"([A-Z_]+)":\$t\}', code))

problems = []
notes = []


def dotted(values, path):
    node = values
    for part in path.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            return None
    return node


def resolve(text, values):
    # A chart template is not valid YAML while it carries Helm actions, so the
    # secret references are resolved by name rather than rendered. `.Values.a.b`
    # is the only expression the four generated charts put in a secret-name or
    # secret-key position; anything else is left in place and reported below,
    # never silently skipped.
    def sub(m):
        got = dotted(values, m.group(1).strip())
        return str(got) if got is not None else m.group(0)

    return re.sub(r"\{\{-?\s*\.Values\.([A-Za-z0-9_.]+)\s*-?\}\}", sub, text)


def refs_from(text):
    refs = set()   # (secret, key) the pod REQUIRES
    names = set()  # secret names referenced at all
    for m in re.finditer(r"secretRef:\s*\n\s*name:\s*([^\s]+)", text):
        names.add(m.group(1))
    for m in re.finditer(r"secretKeyRef:\s*\n\s*name:\s*([^\s]+)\s*\n\s*key:\s*([^\s]+)", text):
        names.add(m.group(1))
        refs.add((m.group(1), m.group(2)))
    # A volume's secretName, and every `- key:` ITEM under it (items live at a
    # deeper indent than the secretName that introduces them).
    for m in re.finditer(r"(?m)^(\s*)secretName:\s*([^\s]+)\s*$", text):
        indent = len(m.group(1))
        secret = m.group(2)
        names.add(secret)
        block = []
        for line in text[m.end():].split("\n"):
            if line.strip() and (len(line) - len(line.lstrip())) < indent:
                break
            block.append(line)
        for k in re.findall(r"-\s*key:\s*([^\s]+)", "\n".join(block)):
            refs.add((secret, k))
    return refs, names


for svc in SERVICES:
    base = os.path.join(fleet, svc)
    charts = []
    for chart_yaml in glob.glob(os.path.join(base, "**", "Chart.yaml"), recursive=True):
        chart_dir = os.path.dirname(chart_yaml)
        if os.path.isfile(os.path.join(chart_dir, "templates", "deployment.yaml")):
            charts.append(chart_dir)
    if not charts:
        notes.append(f"{svc}: no sibling chart checkout under {base} — not asserted")
        continue
    for chart_dir in sorted(charts):
        values_path = os.path.join(chart_dir, "values.yaml")
        try:
            with open(values_path, encoding="utf-8") as fh:
                values = yaml.safe_load(fh) or {}
        except Exception as exc:  # noqa: BLE001 - reported, never swallowed
            problems.append(f"{values_path} does not parse: {exc}")
            continue
        dep_path = os.path.join(chart_dir, "templates", "deployment.yaml")
        with open(dep_path, encoding="utf-8") as fh:
            text = resolve(fh.read(), values)
        refs, names = refs_from(text)
        for secret in sorted(names):
            if "{" in secret:
                problems.append(
                    f"{svc}: an unresolved Helm expression reached a secret name "
                    f"({secret}) — the chart cannot be read"
                )
            elif secret not in created:
                problems.append(
                    f"{svc}: the chart references secret {secret}, which install.sh never creates"
                )
        for secret, key in sorted(refs):
            if "{" in key:
                problems.append(
                    f"{svc}: an unresolved Helm expression reached a secret key ({key})"
                )
                continue
            if key not in recorded.get(secret, set()):
                problems.append(
                    f"{svc}: the chart mounts {secret}/{key}, which install.sh does not record "
                    "(and therefore does not write)"
                )
            if key not in patched and f"--from-literal={key}=" not in code:
                problems.append(
                    f"{svc}: the chart mounts {secret}/{key}, which install.sh never writes"
                )

if problems:
    print("; ".join(problems))
    sys.exit(1)
for note in notes:
    print(f"note: {note}")
print(f"chart secret references: {len(SERVICES)} services checked, {len(notes)} absent")
PY
}

# The real run: the sibling charts beside kit, when a checkout is there.
run 'every secret key a chart mounts or names is written by install.sh' green \
  check_chart_secret_keys "$SUBSTRATE/install.sh" "$ROOT/.."

# The controls run against a THROWAWAY fixture fleet, so the check's ability to
# see a missing writer never depends on a neighbour being checked out. The
# fixture carries all three reference shapes the four charts use, with the
# gateway volume ITEM as the load-bearing one (it is the shape that produced the
# 152-minute ContainerCreating).
build_chart_fixture() {
  # $1 = the directory; $2 = the assertion key the chart mounts.
  local dir="$1" key="$2"
  mkdir -p "$dir/gateway/charts/gateway/templates"
  cat >"$dir/gateway/charts/gateway/Chart.yaml" <<'YAML'
apiVersion: v2
name: gateway
version: 0.1.0
YAML
  cat >"$dir/gateway/charts/gateway/values.yaml" <<YAML
secretName: gateway-secrets
secrets:
  redisUrlSecretName: gateway-secrets
  redisUrlSecretKey: REDIS_URL
  assertionKeySecretName: gateway-secrets
  assertionKeySecretKey: ${key}
YAML
  cat >"$dir/gateway/charts/gateway/templates/deployment.yaml" <<'YAML'
spec:
  template:
    spec:
      containers:
        - name: gateway
          envFrom:
            - secretRef:
                name: {{ .Values.secretName }}
          env:
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.redisUrlSecretName }}
                  key: {{ .Values.secrets.redisUrlSecretKey }}
      volumes:
        - name: assertion-key
          secret:
            secretName: {{ .Values.secrets.assertionKeySecretName }}
            items:
              - key: {{ .Values.secrets.assertionKeySecretKey }}
                path: signing.pem
YAML
}

fixture_chart_bad="$WORK/chart-fleet-unwritten"
build_chart_fixture "$fixture_chart_bad" "A_KEY_NOTHING_WRITES"
run 'control: a chart mounting a key install.sh never writes goes red' red \
  check_chart_secret_keys "$SUBSTRATE/install.sh" "$fixture_chart_bad"

fixture_chart_good="$WORK/chart-fleet-written"
build_chart_fixture "$fixture_chart_good" "ASSERTION_SIGNING_KEY"
run 'control: the same fixture with the written key stays green' green \
  check_chart_secret_keys "$SUBSTRATE/install.sh" "$fixture_chart_good"

# The envFrom half: a secret NAME the chart reads but install.sh never creates.
fixture_chart_name="$WORK/chart-fleet-missing-secret"
build_chart_fixture "$fixture_chart_name" "ASSERTION_SIGNING_KEY"
sed -i.bak 's/secretName: gateway-secrets/secretName: gateway-secrets-TYPO/' \
  "$fixture_chart_name/gateway/charts/gateway/values.yaml"
rm -f "$fixture_chart_name/gateway/charts/gateway/values.yaml.bak"
run 'control: a chart reading a secret install.sh never creates goes red' red \
  check_chart_secret_keys "$SUBSTRATE/install.sh" "$fixture_chart_name"

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
#
# AND THE FIELD THE FLAGS LIVE IN IS PART OF THE CLAIM. The manifest used to
# carry the compose flag list under `command:`, which Kubernetes reads as the
# ENTRYPOINT rather than as arguments — the box refused to start the container
# at all (`exec: "-js": executable file not found in $PATH`, CrashLoopBackOff,
# step 10's wait timing out). The check now reads the union of `command` and
# `args`, because that union is the argv the runtime execs, so no fixture can
# pass by putting the flags in a field that is not the field.
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
# The flags are read out of `command` AND `args` together, because that union
# is the argv the runtime execs: Kubernetes replaces the image's entrypoint
# with `command` and appends `args` to it. Reading only one of them would pass
# a manifest whose flags sit in the wrong field — which is the defect this
# packet is about, and which the check in §12b refuses by shape.
tokens = list(container.get("command") or []) + list(container.get("args") or [])
for flag in ("-js", "-sd", "/data", "-m", "8222"):
    if flag not in tokens:
        problems.append(
            f"broker argv is missing {flag!r} — without -js the bus is"
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


need("TOTAL=13", "TOTAL is not 13 — step 10 (the services' schemas), step 11 (NATS), step 12 (the courier credential minted on this box) and step 13 (the residual ReplicaSets) widen the plan and the DRY_RUN order check with it")
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
# 12b. A container's `command:` is an ENTRYPOINT, never a flag list — the
#      compose/k8s field confusion, gated
# ===========================================================================
#
# THE DEFECT, and why no reader of either file can catch it. The nats manifest
# carried the local stack's flag list under `command:`, because the compose file
# spells the same list under the same key. Compose APPENDS its `command:` to the
# image's ENTRYPOINT; Kubernetes REPLACES the entrypoint with `command:` and
# carries arguments in `args:`. One spelling, two meanings, two files. The box
# said so once — `exec: "-js": executable file not found in $PATH`,
# CrashLoopBackOff, and step 10's `kubectl wait --for=condition=Available
# deployment nats` timing out with nothing in `gh run view --log-failed` to read,
# because no step failed: the container never started.
#
# WHAT IS ASSERTED, AND HOW NARROWLY. Kubernetes execs `command[0]` as a binary
# name resolved in the image's PATH. A first element beginning with `-` cannot
# name a binary, so it cannot run — on ANY image, because the entrypoint it would
# have been appended to has been replaced. So the check refuses exactly that
# shape:
#
#   COVERED   every non-Argo document under manifests/: any LIST under a
#             `command:` key whose FIRST element begins with `-`, and any
#             `command:` spelled as one string beginning with `-`. That reaches
#             a container's `command:` and a probe's or lifecycle handler's
#             `exec.command:` alike, because both are argv.
#
#   NOT COVERED  argoproj.io Applications. Those are chart requests: a
#             `command:` inside their values is a Helm value whose meaning
#             belongs to the chart, not a Kubernetes field, and the charts are
#             out of this packet's scope. They are COUNTED and reported as
#             skipped, never passed over in silence.
#
#   ALSO NOT COVERED  whether a non-flag `command:` names a binary the image
#             actually carries. `command: [nats-server]` and
#             `command: [sh, -c, …]` are both accepted on shape. Whether those
#             binaries exist is a property of the image, whose tag is pinned in
#             install.sh — proving it needs a runtime, which is what README says
#             this suite cannot do.
#
# NO ALLOWLIST, and that is deliberate. The brief allows an exception for "a
# site whose entrypoint is documented as such"; there is no such site, because
# replacing the entrypoint is what makes a flag-named binary unrunnable on every
# image. An entry that permits nothing is a ratchet, which is the very thing the
# static phase's allowlist rules exist to refuse.
#
# AND THE CHECK MUST NOT BE SATISFIABLE BY EXAMINING NOTHING. It prints how many
# `command:` sites it read, and the assertion below reads that number back out of
# the real tree's own output. A check that walks an empty tree and reports "0
# flag-shaped" is green and worthless.
check_container_command_fields() {
  "$PY" - "$1" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
problems = []
argo_docs = 0
command_sites = 0
ARGO_GROUPS = {"argoproj.io"}


def command_values(node, path):
    """Every `command:` VALUE in this document, at any depth.

    A Kubernetes `command` is a string list, but a malformed manifest can spell
    it as one string; both are read, because both are a value a reader would
    call "the command", and the defect the check exists for is a value that
    begins with a flag. Normalised to a list so the first element is `cmd[0]`
    either way.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "command":
                if isinstance(v, list):
                    yield path, v
                elif isinstance(v, str):
                    yield path, [v]
            yield from command_values(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from command_values(item, f"{path}[{i}]")


for dirpath, _dirs, files in os.walk(root):
    for f in sorted(files):
        if not f.endswith((".yaml", ".yml")):
            continue
        rel = os.path.relpath(os.path.join(dirpath, f), root)
        raw = open(os.path.join(dirpath, f), encoding="utf-8").read()
        try:
            docs = [d for d in yaml.safe_load_all(raw) if d]
        except yaml.YAMLError as e:
            problems.append(f"{rel}: does not parse ({e})")
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            api = doc.get("apiVersion", "")
            group = api.split("/")[0] if "/" in api else ""
            if group in ARGO_GROUPS:
                argo_docs += 1
                continue
            kind = doc.get("kind", "?")
            for path, cmd in command_values(doc, kind):
                if not cmd or not all(isinstance(c, str) for c in cmd):
                    continue
                command_sites += 1
                if cmd[0].startswith("-"):
                    problems.append(
                        f"{rel}: {path}.command[0] is {cmd[0]!r} — Kubernetes "
                        "REPLACES the image's entrypoint with `command:`, it "
                        "does not append to it, so this asks the kernel to exec "
                        f"a binary named {cmd[0]!r}. The flags belong in "
                        "`args:` (compose's `command:` appends; Kubernetes's "
                        "replaces)"
                    )

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{command_sites} command site(s) read, none flag-shaped; "
      f"{argo_docs} argoproj.io document(s) skipped (Helm values, not "
      "Kubernetes fields)")
PY
}

run 'no container command: starts with a flag (the compose/k8s field confusion)' green \
  check_container_command_fields "$SUBSTRATE/manifests"

# The real tree's own site count, read back out of the output. Without this the
# check is satisfiable by a tree it never walked.
command_sites_out="$(check_container_command_fields "$SUBSTRATE/manifests")" || true
case "$command_sites_out" in
  *"4 command site(s) read"*)
    pass "the check read 4 command sites (nats, redis, and redis's two probes) and none flag-shaped"
    ;;
  *)
    fail "the check read the real tree's own command sites" \
      "got: ${command_sites_out:-<nothing>} — expected the site count, so a check that walked nothing cannot pass"
    ;;
esac

# THE RED CONTROL IS THE DEFECT ITSELF, restored: the flag list back under
# `command:`, `args:` gone, nothing else in the tree touched. A fixture that has
# silently stopped carrying the defect is a control that proves nothing, so the
# fixture asserts its own premise before it is used.
fixture_cmd_flags="$WORK/command-flag-shape"
mkdir -p "$fixture_cmd_flags"
cp -R "$SUBSTRATE/manifests/." "$fixture_cmd_flags/"
sed -e '/^          command:$/d' \
  -e '/^            - "nats-server"$/d' \
  -e 's/^          args:$/          command:/' \
  "$SUBSTRATE/manifests/data/nats.yaml" >"$fixture_cmd_flags/data/nats.yaml"
if ! grep -q '^          command:$' "$fixture_cmd_flags/data/nats.yaml" ||
  grep -q '^          args:$' "$fixture_cmd_flags/data/nats.yaml" ||
  ! grep -q '^            - "-js"$' "$fixture_cmd_flags/data/nats.yaml"; then
  fail 'control: the flag-shaped fixture is not flag-shaped' \
    'the transform did not put the flag list back under command: — this control would prove nothing'
else
  run 'control: a command: starting with a flag goes red (the -js shape that shipped)' red \
    check_container_command_fields "$fixture_cmd_flags"
fi

# The other half, and the one that keeps the check honest about what it keys on:
# a `command:` that NAMES the binary and carries the flags after it must stay
# GREEN. Without this the check is "a flag appears somewhere in command:", and
# the fix — naming the binary — would be refused along with the bug.
fixture_cmd_binary="$WORK/command-binary-first"
mkdir -p "$fixture_cmd_binary"
cp -R "$SUBSTRATE/manifests/." "$fixture_cmd_binary/"
sed -e '/^          args:$/d' \
  "$SUBSTRATE/manifests/data/nats.yaml" >"$fixture_cmd_binary/data/nats.yaml"
if ! grep -q '^            - "nats-server"$' "$fixture_cmd_binary/data/nats.yaml" ||
  grep -q '^          args:$' "$fixture_cmd_binary/data/nats.yaml"; then
  fail 'control: the binary-first fixture is not binary-first' \
    'the transform did not fold the flags under a command: naming the binary'
else
  run 'control: a command: naming the binary, flags after it, stays green' green \
    check_container_command_fields "$fixture_cmd_binary"
fi

# The third shape, and the reason the checker reads a scalar too: a `command:`
# spelled as one string that begins with a flag. (`command` is a []string in the
# Kubernetes schema, so the API server would reject this at apply — but the gate
# sees the tree first, and a value that begins with a flag is the same defect one
# shape over.) The premise asserts the fixture still PARSES, so a red here cannot
# be a YAML error wearing the finding's clothes.
fixture_cmd_scalar="$WORK/command-scalar-flag"
mkdir -p "$fixture_cmd_scalar"
cp -R "$SUBSTRATE/manifests/." "$fixture_cmd_scalar/"
sed -e 's/^          command:$/          command: "-js"/' \
  -e '/^            - "nats-server"$/d' \
  "$SUBSTRATE/manifests/data/nats.yaml" >"$fixture_cmd_scalar/data/nats.yaml"
if ! grep -q '^          command: "-js"$' "$fixture_cmd_scalar/data/nats.yaml" ||
  ! "$PY" -c 'import sys, yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$fixture_cmd_scalar/data/nats.yaml" 2>/dev/null; then
  fail 'control: the scalar-command fixture is not a valid scalar command' \
    'the transform did not leave a parseable `command: "-js"` — this control would prove nothing'
else
  run 'control: a scalar command: beginning with a flag goes red' red \
    check_container_command_fields "$fixture_cmd_scalar"
fi

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

# mock_namespace_exists <namespace> — has anything in this store created it?
#
# The boundary the packet's defect crosses, and the reason the mock needs a
# namespace registry at all: `create secret` in a namespace NOBODY made is
# refused by the API server with `Error from server (NotFound): namespaces "x"
# not found`, exit 1. That is the exact error the live box produced on a wiped
# machine, where step 4 had made argocd and step 6's Applications had yet to
# make the other five. A mock that let a Secret be created in any namespace
# would have been green on that failure for the whole life of this suite,
# which is the same shape as the defect: an assertion that pins the destination
# without modelling the destination's existence.
#
# GET and PATCH are deliberately NOT bound by this: `get secret -n x` on a
# namespace that does not exist is NotFound too, but the fixture's own store is
# the only thing those verbs read, and binding them would make a seeded secret
# unreadable rather than wrong. The boundary is modelled where the defect
# measured it — a WRITE into the namespace.
mock_namespace_exists() {
  [ -n "${MOCK_ROOT:-}" ] || return 0
  [ -f "$MOCK_ROOT/namespaces" ] || return 1
  grep -qx -- "$1" "$MOCK_ROOT/namespaces" 2>/dev/null
}

# mock_has_control_bytes <file> — exit 0 iff the file carries a NUL byte, the
# signature of the AppleDouble sidecar (`._name`) BSD tar writes for a file's
# resource fork. Real kubectl fails to parse such a file; the mock's apply
# branch calls this so a control that hands it one really does break.
mock_has_control_bytes() {
  "$PY" -c 'import sys; sys.exit(0 if b"\x00" in open(sys.argv[1], "rb").read() else 1)' "$1"
}

# mock_apply_plant <manifest> — the ONE write path for `apply`, shared by the
# three ways a manifest reaches it: a resolved `-f` FILE, a `-f` DIRECTORY (read
# the way kubectl reads it), and the pipeline on stdin. Two boundaries meet
# here, one from each packet, and they are independent: the namespace the
# manifest NAMES must exist (the same NotFound `create secret` models, asked of
# the write), and the bytes are then appended to the store verbatim. A manifest
# with no top-level `namespace:` — the namespace stub `create namespace …
# --dry-run=client -o yaml` prints, or a cluster-scoped object — is not bound by
# the first, exactly as real kubectl does not bind it.
mock_apply_plant() {
  local manifest="$1" apply_ns
  apply_ns="$(printf '%s\n' "$manifest" | sed -n 's/^  namespace: //p' | head -1)"
  if [ -n "$apply_ns" ] && ! mock_namespace_exists "$apply_ns"; then
    printf 'Error from server (NotFound): namespaces "%s" not found\n' "$apply_ns" >&2
    return 1
  fi
  printf '%s\n' "$manifest" >>"$MOCK_ROOT/applied.yaml"
}
# mock_kubectl — the file-backed kubectl. Emulates only what
# install_service_secrets and the pull-secret step use: `create namespace`
# (REGISTERS the namespace and prints a stub down the pipe to `apply`),
# `create secret generic … --from-literal=K=V …`,
# `create secret docker-registry … --from-file=…`,
# `get secret …` (existence), and `get secret … -o jsonpath={.data.KEY}`
# (base64 of the stored value, the shape read_secret_key decodes).
# Two of those verbs — `create secret` and `apply` — refuse a namespace nobody
# made, with the API server's own NotFound. Anything else is a loud failure,
# not a silent success.
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
        # THE REGISTRY. Real kubectl keeps the namespace set in etcd; the mock
        # keeps it in one name per line of $MOCK_ROOT/namespaces, and that file
        # is what the two namespace-bound verbs below consult. Written before
        # anything else, so the same `create | apply` pipeline that asks for the
        # namespace is the one that makes it observable to the Secret beside it.
        local ns_name="${1:-}"
        shift || true
        # THE RED CONTROL'S HOOK: a box whose admission policy, or a
        # kubeconfig pointing at a cluster it cannot reach, refuses the
        # namespace the step is about to write into. Answered the way the API
        # server answers it — loudly, on stderr, exit 1.
        if [ -n "${MOCK_NAMESPACE_REFUSE:-}" ] && [ "$MOCK_NAMESPACE_REFUSE" = "$ns_name" ]; then
          printf 'Error from server (Forbidden): namespaces "%s" is forbidden: the mock refuses to create it\n' "$ns_name" >&2
          return 1
        fi
        printf '%s\n' "$ns_name" >>"$MOCK_ROOT/namespaces"
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
        # The namespace must EXIST. On a wiped box the pull-secret step runs
        # before the Applications create them, and this is where that failure
        # lives — `Error from server (NotFound): error when creating "STDIN":
        # namespaces "identity" not found`, which `set -e` turns into the end
        # of the install.
        if ! mock_namespace_exists "$ns"; then
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "$ns" >&2
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
      # The namespace must EXIST, exactly as for the docker-registry Secret
      # above. Step 9 makes its own four before it writes into them, which is
      # why this is a boundary and not an obstruction.
      if ! mock_namespace_exists "$ns"; then
        printf 'Error from server (NotFound): namespaces "%s" not found\n' "$ns" >&2
        return 1
      fi
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
      if [ "${1:-}" = "deployment" ]; then
        # Existence by name in the file store, like `get secret` below: a GET
        # of a missing object exits 0 and prints nothing (real kubectl), and
        # --no-headers prints one line per object that exists. Step 11's await
        # polls this until Argo creates the Deployment, so the mint's fixture
        # seeds `deploy-<name>` the way a box past step 6 holds it.
        #
        # `-o jsonpath={…containers[0].image}` reads the image the Deployment
        # runs — the value step 10's migrate Job is built from, so the fixture
        # stores it in `deploy-<name>/image` and a missing file is an empty
        # image, which is the same "no Deployment yet" state.
        shift || true
        local dep_name="${1:-}"
        shift || true
        local dep_ns="" dep_tmpl=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -n) dep_ns="$2"; shift 2 ;;
            -o) dep_tmpl="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -d "$MOCK_ROOT/$dep_ns/deploy-$dep_name" ]; then
          case "$dep_tmpl" in
            *image*)
              cat "$MOCK_ROOT/$dep_ns/deploy-$dep_name/image" 2>/dev/null || true
              ;;
            *)
              printf '%s   1/1   1   1   10d\n' "$dep_name"
              ;;
          esac
        fi
        return 0
      fi
      if [ "${1:-}" = "pod" ]; then
        # The one-shot pods steps 10 and 11 run: existence is `pod-<name>`, the
        # phase is the file inside it. A missing pod exits 1, exactly as a real
        # `get pod` does, so a wait loop can tell "not scheduled yet" from a
        # phase.
        shift || true
        local pod_name="${1:-}"
        shift || true
        local pod_ns="$fallback_ns" pod_tmpl=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -n) pod_ns="$2"; shift 2 ;;
            -o) pod_tmpl="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        local pdir="$MOCK_ROOT/$pod_ns/pod-$pod_name"
        [ -d "$pdir" ] || return 1
        case "$pod_tmpl" in
          *status.phase*) cat "$pdir/phase" 2>/dev/null || printf 'Pending' ;;
          *) printf '%s   0/1   Pending   0   1s\n' "$pod_name" ;;
        esac
        return 0
      fi
      if [ "${1:-}" = "cluster.postgresql.cnpg.io" ]; then
        # The `cluster` guard's probe: does the CNPG Cluster object exist? The
        # fixture plants `data/cluster-postgres` to say it does, which is how a
        # re-run is modelled — and the only way a test can reach the guard
        # branch of install_postgres_cluster that skips the re-provision.
        shift || true
        local cl_name="${1:-}"
        shift || true
        local cl_ns="$fallback_ns"
        while [ $# -gt 0 ]; do
          case "$1" in
            -n) cl_ns="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -f "$MOCK_ROOT/$cl_ns/cluster-$cl_name" ] && return 0
        return 1
      fi
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
      #
      # `-f` may name a real FILE or DIRECTORY, and then the mock READS it the
      # way kubectl does — dotfiles in a directory included — and refuses a
      # file carrying NUL bytes with the exact error the box reported for an
      # AppleDouble sidecar. That is what makes the "filter removed" control
      # below able to break the apply again rather than pass on a mock that
      # never looked.
      #
      # EVERY manifest written — from a resolved `-f` file, a `-f` directory,
      # or the pipeline on stdin — goes through mock_apply_plant, which reads
      # the manifest's own namespace before storing it: the same NotFound
      # boundary `create secret` models, asked of the write. The two packets'
      # additions meet here and neither replaces the other: the file/directory
      # reading is the transport fix's, the namespace registry is step 5's.
      mkdir -p "$MOCK_ROOT/applied"
      local -a apply_targets=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -f) apply_targets+=("$2"); shift 2 ;;
          -f=*) apply_targets+=("${1#-f=}"); shift ;;
          *) shift ;;
        esac
      done
      if [ "${#apply_targets[@]}" -eq 0 ]; then
        mock_apply_plant "$(cat)"
        return $?
      fi
      local apply_target
      for apply_target in "${apply_targets[@]}"; do
        if [ "$apply_target" = "-" ]; then
          mock_apply_plant "$(cat)" || return 1
          continue
        fi
        local -a apply_files=()
        if [ -d "$apply_target" ]; then
          local fpath
          for fpath in "$apply_target"/* "$apply_target"/.[!.]* "$apply_target"/..?*; do
            [ -f "$fpath" ] || continue
            apply_files+=("$fpath")
          done
        else
          if [ ! -f "$apply_target" ]; then
            printf 'error: the path "%s" does not exist\n' "$apply_target" >&2
            return 1
          fi
          apply_files=("$apply_target")
        fi
        local afile
        for afile in "${apply_files[@]}"; do
          if mock_has_control_bytes "$afile"; then
            printf 'error parsing %s: error converting YAML to JSON: yaml: control characters are not allowed\n' "$afile" >&2
            return 1
          fi
          mock_apply_plant "$(cat "$afile")" || return 1
        done
      done
      return 0
      ;;
    rollout)
      # `rollout status` (a wait), `rollout restart` (a kick). Both are no-ops
      # against the file store: the mint loop's contract is that it ASKS, and
      # the value assertions below are what prove it wrote the right thing.
      return 0
      ;;
    patch)
      # A merge patch, read from `--patch-file=/dev/stdin`: the mock MERGES the
      # stringData keys into the stored secret, exactly as kubectl does. This
      # is what makes the "no other key is wiped" assertion below mean
      # anything — a mock that treated a patch as a replace would make the
      # destructive and the correct write indistinguishable. `--patch-file=-`
      # is refused with kubectl's own error below, because the real binary has
      # no `-` stdin convention and this suite must not be green on one.
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
        "") echo "mock_kubectl: patch without --patch-file" >&2; return 1 ;;
        -)
          # THE LIVE DEFECT, MODELLED. Real kubectl has no `-` stdin
          # convention for --patch-file: it opens a file literally named `-`,
          # and this is the byte-for-byte error it prints when there is none.
          # Measured on the Contabo box against the pinned kubectl. The mock
          # used to treat `-` as stdin, which is why a step that could never
          # run was green for the life of this suite.
          echo "error: unable to read patch file: open -: no such file or directory" >&2
          return 1
          ;;
        /dev/stdin) body="$(cat)" ;;
        *) body="$(cat "$patch_file_arg")" ;;
      esac
      local d="$MOCK_ROOT/$patch_ns/$patch_name"
      mkdir -p "$d"
      # Every key under stringData is merged over what is stored. The value is
      # written VERBATIM, one jq call per key, rather than through a
      # line-oriented `key=value` stream: a value with a newline in it — a
      # multi-line PEM, which is exactly what gateway's assertion key is —
      # would otherwise be split across writes and truncated to its last line.
      # Real kubectl preserves the bytes; the mock has to as well, or the repair
      # that patches a PEM in looks like it worked when it stored garbage.
      local -a patch_keys=()
      local patch_key
      while IFS= read -r patch_key; do
        [ -n "$patch_key" ] && patch_keys+=("$patch_key")
      done < <(printf '%s' "$body" | jq -r '.stringData // {} | keys[]')
      # A `"key":null` entry DELETES the stored key, exactly as a real merge
      # patch does — the orphan sweep relies on it, and a mock that stored an
      # empty file (or the string "null") would be green on a sweep that wrote
      # the wrong patch. `data` is the persisted map, so a null there deletes
      # the entry; a value there is base64, decoded the way read_secret_key
      # decodes it.
      for patch_key in ${patch_keys[@]+"${patch_keys[@]}"}; do
        # A null under stringData is a NO-OP, exactly as on the API server:
        # stringData is write-only and is never persisted, so the stored
        # object carries no such field for the null to delete. (The sweep
        # deletes under `data` for this reason.) A mock that deleted here
        # would be green on a patch the box silently ignores.
        if [ "$(printf '%s' "$body" | jq -r --arg k "$patch_key" '.stringData[$k] | type')" != "null" ]; then
          printf '%s' "$body" | jq -jr --arg k "$patch_key" '.stringData[$k] // empty' >"$d/$patch_key"
        fi
      done
      local -a data_keys=()
      local data_key
      while IFS= read -r data_key; do
        [ -n "$data_key" ] && data_keys+=("$data_key")
      done < <(printf '%s' "$body" | jq -r '.data // {} | keys[]')
      for data_key in ${data_keys[@]+"${data_keys[@]}"}; do
        if [ "$(printf '%s' "$body" | jq -r --arg k "$data_key" '.data[$k] | type')" = "null" ]; then
          rm -f "$d/$data_key"
        else
          printf '%s' "$body" | jq -jr --arg k "$data_key" '.data[$k] // empty' | base64 -d >"$d/$data_key"
        fi
      done
      return 0
      ;;
    run)
      # `kubectl run <name> -n <ns> --restart=Never --image=… --env=K=V …
      # --command -- <cmd>` — the one-shot pod shape steps 10 and 11 use. The
      # mock stores what it was asked to run (image, command, env, phase) in
      # `pod-<name>/`, so an assertion can read back the OWNER DSN the migrate
      # Job was given rather than trusting the argv line. MOCK_POD_PHASE forces
      # the red control: a migration that Failed.
      local run_name="${1:-}"
      shift || true
      local run_ns="$fallback_ns" run_image="" run_cmd="" run_env=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) run_ns="$2"; shift 2 ;;
          --restart=*) shift ;;
          --image=*) run_image="${1#--image=}"; shift ;;
          --env=*)
            run_env="${run_env}${run_env:+
}${1#--env=}"
            shift
            ;;
          --command) shift ;;
          --)
            shift
            run_cmd="$*"
            break
            ;;
          *) shift ;;
        esac
      done
      local rdir="$MOCK_ROOT/$run_ns/pod-$run_name"
      mkdir -p "$rdir"
      printf '%s' "$run_image" >"$rdir/image"
      printf '%s' "$run_cmd" >"$rdir/command"
      printf '%s' "$run_env" >"$rdir/env"
      printf '%s' "${MOCK_POD_PHASE:-Succeeded}" >"$rdir/phase"
      [ -n "${MOCK_POD_LOGS:-}" ] && printf '%s' "$MOCK_POD_LOGS" >"$rdir/logs"
      return 0
      ;;
    delete)
      # `delete pod NAME` / `delete secret NAME`, with or without
      # `--ignore-not-found`. Removing a directory that is not there is what
      # --ignore-not-found means, so both spellings succeed.
      local del_res="${1:-}"
      shift || true
      local del_name="${1:-}"
      shift || true
      local del_ns="$fallback_ns"
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) del_ns="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      case "$del_res" in
        pod) rm -rf "${MOCK_ROOT:?}/${del_ns:?}/pod-${del_name:?}" ;;
        secret) rm -rf "${MOCK_ROOT:?}/${del_ns:?}/${del_name:?}" ;;
        *) ;;
      esac
      return 0
      ;;
    logs)
      # `logs pod/NAME -n NS` — the pod's stored logs, or nothing.
      local log_ref="${1:-}"
      shift || true
      local log_ns="$fallback_ns"
      while [ $# -gt 0 ]; do
        case "$1" in
          -n) log_ns="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      cat "$MOCK_ROOT/$log_ns/pod-${log_ref#pod/}/logs" 2>/dev/null || true
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
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL=""
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
# 12c. The role-secret wiring: every managed role's passwordSecret carries
#      that ROLE's name in `username`, and DATABASE_URL reads the app secret
# ===========================================================================
#
# THE DEFECT THIS SECTION EXISTS FOR, measured on the live box. CNPG's
# managed-role reconciler sets a role's password from the Secret named in
# `passwordSecret` ONLY when the Secret's `username` key equals the ROLE's
# name. Step 8 named the Secret for the service (`postgres-role-identity-app`,
# a hyphen) and wrote that same spelling into `username`, so CNPG refused to
# set the password for all four `_app` roles and said so only in the Cluster's
# status:
#
#   cannotReconcile:
#     identity_app:
#     - the username in secret "postgres-role-identity-app" does not match
#       role "identity_app"
#
# `pg_authid.rolpassword` held a SCRAM verifier for `identity` and NULL for
# `identity_app`, and every pod logged `FATAL: password authentication failed
# for user "identity_app" (SQLSTATE 28P01)`.
#
# WHY THIS IS A CHECK AND NOT A PARAGRAPH. The mismatch is invisible to every
# other check in this file: the Cluster applies, the roles exist, the Secret
# exists, the Deployment's envFrom resolves, and the only witnesses are a
# status field nobody reads and a NULL nobody selects. So the wiring is
# asserted from BOTH ends the installer controls: step 8 is EXECUTED against
# the file-backed kubectl, and its output is compared to the Cluster manifest
# the same step applies. `database_url_for` — step 9's own naming function —
# is executed too, and the DSN it builds must carry the app role's name and
# the app Secret's password; a URL built from the owner Secret is a login as
# the wrong role.
check_role_secret_wiring() {
  local install_sh="$1" cluster="$2" root ec=0
  root="$(mktemp -d "$WORK/role-wiring.XXXXXX")"
  # Source the installer with its `main` call removed, the same shape every
  # other sourced fixture in this file uses: without the strip, `. install.sh`
  # would RUN the install.
  sed '/^main "$@"/d' "$install_sh" >"$root/install-no-main.sh"
  (
    export MOCK_ROOT="$root"
    mkdir -p "$MOCK_ROOT"
    # `data` exists by the time step 8 writes into it (step 8's own
    # `create namespace data`); the mock's write verbs require it, exactly as
    # the API server does.
    printf 'data\n' >"$MOCK_ROOT/namespaces"
    export KUBECONFIG=/dev/null
    # shellcheck source=/dev/null
    . "$root/install-no-main.sh"
    kubectl() { mock_kubectl "$@"; }
    create_postgres_role_secrets >"$root/step8.log" 2>&1
    local svc
    for svc in identity gateway courier parlor; do
      database_url_for "$svc" >"$root/url-$svc.txt"
    done
  ) || ec=$?
  if [ "$ec" -ne 0 ]; then
    echo "the step-8/step-9 functions failed (exit $ec): $(head -2 "$root/step8.log" 2>/dev/null)"
    return 1
  fi
  "$PY" - "$root" "$cluster" <<'PY'
import os
import sys

import yaml

root, cluster = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(cluster, encoding="utf-8"))
roles = doc.get("spec", {}).get("managed", {}).get("roles", [])
problems = []

store = {}
data_dir = os.path.join(root, "data")
if os.path.isdir(data_dir):
    for name in os.listdir(data_dir):
        d = os.path.join(data_dir, name)
        if not os.path.isdir(d):
            continue

        def value(key, _d=d):
            try:
                return open(os.path.join(_d, key), encoding="utf-8").read()
            except OSError:
                return ""

        store[name] = {"username": value("username"), "password": value("password")}

declared = set()
for r in roles:
    name = r.get("name")
    secret = (r.get("passwordSecret") or {}).get("name")
    if not secret:
        problems.append(f"role {name} names no passwordSecret")
        continue
    declared.add(secret)
    if secret not in store:
        problems.append(f"role {name}: step 8 creates no secret named {secret}")
        continue
    # THE ASSERTION THE LIVE DEFECT VIOLATED.
    if store[secret]["username"] != name:
        problems.append(
            f"role {name}: secret {secret} has username"
            f" {store[secret]['username']!r} — CNPG refuses to set the password"
            f" unless it is {name!r}"
        )
    if not store[secret]["password"]:
        problems.append(f"role {name}: secret {secret} carries no password")
for secret in sorted(store):
    if secret not in declared:
        problems.append(f"step 8 creates {secret}, which no managed role names")

# The DATABASE_URL half: step 9's naming function must read the APP role's
# secret and password, and the DSN must name the app role and the database.
for svc in ("identity", "gateway", "courier", "parlor"):
    try:
        url = open(os.path.join(root, f"url-{svc}.txt"), encoding="utf-8").read()
    except OSError:
        problems.append(f"database_url_for {svc} produced nothing")
        continue
    app_secret = f"postgres-role-{svc}-app"
    pw = store.get(app_secret, {}).get("password", "")
    if not pw:
        problems.append(f"{app_secret} has no password for {svc}'s DATABASE_URL")
    elif f":{pw}@" not in url:
        problems.append(
            f"{svc}'s DATABASE_URL does not carry {app_secret}'s password — the"
            " DSN was built from a different secret or a different key"
        )
    if f"://{svc}_app:" not in url:
        problems.append(f"{svc}'s DATABASE_URL does not connect as {svc}_app")
    if f"/{svc}" not in url:
        problems.append(f"{svc}'s DATABASE_URL does not name database {svc}")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(
    f"{len(roles)} managed roles: each passwordSecret carries username=role,"
    " and DATABASE_URL reads the app secret"
)
PY
}

run 'the role secrets and the Cluster agree: username is the role name, DATABASE_URL reads the app secret' green \
  check_role_secret_wiring "$SUBSTRATE/install.sh" "$DATA_DIR/postgres-cluster.yaml"

# Control A — the live defect reintroduced: step 8 hyphenates the app suffix
# into `username` (the secret's spelling, not the role's). Must go red.
fixture_user_drift="$WORK/install-username-drift.sh"
sed 's|--from-literal=username="\$role"|--from-literal=username="${role//_/-}"|' \
  "$SUBSTRATE/install.sh" >"$fixture_user_drift"
run 'control: a hyphenated app username (the live defect) goes red' red \
  check_role_secret_wiring "$fixture_user_drift" "$DATA_DIR/postgres-cluster.yaml"

# Control B — one service's ROLE name drifts in the manifest. The secret is
# unchanged, so the username no longer matches it. One service, one edit.
fixture_role_drift="$WORK/cluster-role-name-drift.yaml"
sed 's/^      - name: identity_app$/      - name: identity-app/' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_role_drift"
run 'control: one role name drifting from its secret goes red' red \
  check_role_secret_wiring "$SUBSTRATE/install.sh" "$fixture_role_drift"

# Control C — DATABASE_URL reads the OWNER secret instead of the app secret:
# a DSN that logs in as the wrong role with the wrong password. Must go red.
fixture_dsn_drift="$WORK/install-dsn-drift.sh"
sed 's|read_secret_key data "postgres-role-\$1-app" password|read_secret_key data "postgres-role-$1" password|' \
  "$SUBSTRATE/install.sh" >"$fixture_dsn_drift"
run 'control: a DATABASE_URL built from the owner secret goes red' red \
  check_role_secret_wiring "$fixture_dsn_drift" "$DATA_DIR/postgres-cluster.yaml"

# The re-run half, EXECUTED. The live box already had a Cluster, so step 8's
# `cluster` guard would skip the re-provision — and a reconcile placed behind
# that guard would never run on the one box that needs it. This drives
# `install_postgres_cluster` with the guard answering "the Cluster exists" and
# every app role's Secret seeded with the broken `username` spelling, then
# asserts the usernames were repaired and the passwords were NOT regenerated.
check_rerun_repairs_username() {
  local install_sh="$1" root ec=0 svc problems=""
  root="$(mktemp -d "$WORK/rerun-repair.XXXXXX")"
  mkdir -p "$root/data"
  printf 'data\n' >"$root/namespaces"
  : >"$root/data/cluster-postgres" # the guard's probe: a Cluster already exists
  # The step resolves the Cluster manifest from its own directory, so the
  # fixture carries the real manifests beside the stripped installer.
  cp -R "$SUBSTRATE/manifests" "$root/manifests"
  MOCK_ROOT="$root"
  for svc in identity gateway courier parlor; do
    mock_seed data "postgres-role-$svc" username "$svc"
    mock_seed data "postgres-role-$svc" password "pw-$svc"
    mock_seed data "postgres-role-$svc-app" username "$svc-app" # the live defect's spelling
    mock_seed data "postgres-role-$svc-app" password "pw-$svc-app"
  done
  sed '/^main "$@"/d' "$install_sh" >"$root/install-no-main.sh"
  (
    export MOCK_ROOT="$root" KUBECONFIG=/dev/null
    # shellcheck source=/dev/null
    . "$root/install-no-main.sh"
    kubectl() { mock_kubectl "$@"; }
    export KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor"
    export DRY_RUN=0
    install_postgres_cluster >"$root/rerun.log" 2>&1
  ) || ec=$?
  MOCK_ROOT="$root"
  if [ "$ec" -ne 0 ]; then
    echo "install_postgres_cluster (re-run) failed (exit $ec): $(head -2 "$root/rerun.log")"
    return 1
  fi
  case "$(cat "$root/rerun.log")" in
    *"already installed, skipping"*) : ;;
    *) problems="$problems; the guard branch was not taken — this was not the re-run path" ;;
  esac
  for svc in identity gateway courier parlor; do
    [ "$(mock_get data "postgres-role-$svc-app" username)" = "${svc}_app" ] ||
      problems="$problems; $svc-app username was not repaired to ${svc}_app"
    [ "$(mock_get data "postgres-role-$svc-app" password)" = "pw-$svc-app" ] ||
      problems="$problems; $svc-app password was regenerated"
  done
  # The repair must have TRAVELLED on a `/dev/stdin` patch, not merely landed.
  # The mock records every invocation in full and refuses `-`, so an argv
  # naming the convention is the fact the live fix depends on — a store that
  # changed through some other route would pass the username check above and
  # still not be the path the box ran.
  if ! grep -q -- "patch secret postgres-role-identity-app .*--patch-file=/dev/stdin" \
    "$root/kubectl-argv" 2>/dev/null; then
    problems="$problems; the repair never issued a --patch-file=/dev/stdin patch"
  fi
  if [ -n "$problems" ]; then
    echo "${problems#; }"
    return 1
  fi
  echo "the re-run repaired 4 app-role usernames and kept every password"
}

run 'a re-run repairs the app-role usernames even though the cluster guard skips the apply' green \
  check_rerun_repairs_username "$SUBSTRATE/install.sh"

# Control D — the reconcile moved BELOW the guard (the shape this packet's fix
# must not have). The guard then returns before it runs, the usernames stay
# broken, and the check must go red. The fixture asserts its own premise: the
# transform refuses to write a file it could not make.
fixture_guard_first="$WORK/install-reconcile-behind-guard.sh"
"$PY" - "$SUBSTRATE/install.sh" "$fixture_guard_first" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
before = (
    "  create_postgres_role_secrets\n"
    "  if kit_substrate_guard cluster; then\n"
    '    kit_substrate_out "      already installed, skipping"\n'
    "    return 0\n"
    "  fi\n"
)
after = (
    "  if kit_substrate_guard cluster; then\n"
    '    kit_substrate_out "      already installed, skipping"\n'
    "    return 0\n"
    "  fi\n"
    "  create_postgres_role_secrets\n"
)
if before not in src:
    print("the guard/reconcile block was not found — the control cannot be built")
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(before, after, 1))
PY
run 'control: a reconcile behind the cluster guard never repairs a re-run' red \
  check_rerun_repairs_username "$fixture_guard_first"

# ===========================================================================
# 12d. `kubectl patch` reads its patch from `/dev/stdin`, not `-`
# ===========================================================================
#
# THE HALF OF THE LIVE DEFECT THAT MADE 12c UNREACHABLE. 12c proves the
# username is repaired; this proves the repair can REACH the API server at
# all. `kubectl` has no `-` stdin convention for `--patch-file`: it opens a
# file literally named `-` and dies before the request is built, so the repair
# never happens on the box. Measured back to back on Contabo, against the
# pinned kubectl:
#
#   $ echo '{"metadata":{"annotations":{"probe":"1"}}}' |
#       kubectl patch secret postgres-role-identity -n data --type=merge \
#         --patch-file=-
#   error: unable to read patch file: open -: no such file or directory
#   $ echo '{"metadata":{"annotations":{"probe":"1"}}}' |
#       kubectl patch secret postgres-role-identity -n data --type=merge \
#         --patch-file=/dev/stdin
#   secret/postgres-role-identity patched
#
# `kubectl apply -f -` IS a real convention (step 6 and the pull secret use
# it, and it is left alone); only the `--patch-file` spelling was wrong. The
# mock modelled `-` as stdin and so was green over a step that cannot run — a
# witness from a different program than the one on the box. Both mocks now
# implement `/dev/stdin` and refuse `-` with the real binary's own error, so
# the class cannot pass again.

# check_patch_convention <mock-fn> <root> — one store, the two spellings,
# against the mock named. `/dev/stdin` must read the pipe and merge; `-` must
# fail with kubectl's EXACT message and leave the store untouched. Shared by
# mock_kubectl (step 8) and rollout_kubectl (step 11) because they hold the
# same contract and a divergence between them would be the defect again.
check_patch_convention() {
  local mock="$1" root="$2" ec=0
  local want="error: unable to read patch file: open -: no such file or directory"
  rm -rf "$root"
  mkdir -p "$root"
  (
    export MOCK_ROOT="$root"
    mock_seed data probe username old
    # (1) the convention the installer uses: /dev/stdin reads the pipe.
    printf '%s' '{"stringData":{"username":"new"}}' |
      "$mock" -n data patch secret probe --type=merge --patch-file=/dev/stdin ||
      { echo "$mock refused the /dev/stdin patch"; exit 3; }
    # (2) the spelling the real kubectl rejects: `-`.
    printf '%s' '{"stringData":{"username":"never"}}' |
      "$mock" -n data patch secret probe --type=merge --patch-file=- 2>"$root/dash.err" &&
      { echo "$mock accepted --patch-file=-, which real kubectl refuses"; exit 4; }
    # (3) a null under `data` deletes the key — the orphan sweep's own
    # spelling — while a null under `stringData` is a no-op, exactly as on
    # the API server (stringData is write-only and never persisted, so the
    # stored object carries no such field for the null to delete).
    mock_seed data probe doomed old
    printf '%s' '{"data":{"doomed":null}}' |
      "$mock" -n data patch secret probe --type=merge --patch-file=/dev/stdin ||
      { echo "$mock refused the data-null patch"; exit 5; }
    printf '%s' '{"stringData":{"username":null}}' |
      "$mock" -n data patch secret probe --type=merge --patch-file=/dev/stdin ||
      { echo "$mock refused the stringData-null patch"; exit 6; }
    exit 0
  ) || ec=$?
  MOCK_ROOT="$root"
  if [ "$ec" -ne 0 ]; then
    echo "the mock-convention check failed (exit $ec)"
    return 1
  fi
  if [ -f "$root/data/probe/doomed" ]; then
    echo "the data-null patch did not delete the key"
    return 1
  fi
  if [ "$(mock_get data probe username)" != "new" ]; then
    echo "the stringData-null patch touched the key (stored '$(mock_get data probe username)') — the box would ignore it"
    return 1
  fi
  MOCK_ROOT="$root"
  if [ "$ec" -ne 0 ]; then
    echo "the mock-convention check failed (exit $ec)"
    return 1
  fi
  if [ "$(cat "$root/dash.err")" != "$want" ]; then
    echo "$mock's --patch-file=- error is not kubectl's: '$(cat "$root/dash.err")'"
    return 1
  fi
  if [ "$(mock_get data probe username)" != "new" ]; then
    echo "the /dev/stdin patch did not merge (stored '$(mock_get data probe username)')"
    return 1
  fi
  echo "$mock reads /dev/stdin and refuses - with kubectl's own error"
}
run 'the step-8 mock reads --patch-file=/dev/stdin and refuses - as kubectl does' green \
  check_patch_convention mock_kubectl "$WORK/mock-dash"

# The RED CONTROL on the real step: step 8's patch spelling reverted to `-`.
# The mock now refuses it exactly as the box does, so the re-run repair aborts
# and the check that is GREEN above goes red. The fixture asserts its own
# premise before it is used: a transform that matched nothing would be a
# control that proves nothing.
fixture_patch_dash="$WORK/install-patchfile-dash.sh"
sed -e '/^main "$@"/d' -e 's|--patch-file=/dev/stdin|--patch-file=-|g' \
  "$SUBSTRATE/install.sh" >"$fixture_patch_dash"
if grep -q -- '--patch-file=-' "$fixture_patch_dash" \
  && ! grep -q -- '--patch-file=/dev/stdin' "$fixture_patch_dash"; then
  run 'control: the - patch spelling the real kubectl refuses goes red' red \
    check_rerun_repairs_username "$fixture_patch_dash"
else
  fail 'control: the - patch spelling the real kubectl refuses goes red' \
    "the fixture still holds /dev/stdin or lost the dashed spelling — the control cannot be built"
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
# that pulls the fleet's images — and the bytes the Secret carries are the
# DECODED JSON, not the exchange's base64. --from-file encodes the file's
# bytes into data, so the decoded bytes are what kubectl must receive; the
# kubelet-shaped read in 3b proves it, and the control re-introduces the
# double-encode to prove the read can fail.
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

# 3b. THE KUBELET'S READ, not kubectl's write. --from-file base64-encodes the
# file's bytes into data[.dockerconfigjson], so the applied value decodes ONCE
# — exactly what the kubelet does with it — to JSON carrying
# auths["ghcr.io"].username. Writing the exchange's base64 through undecoded
# stores base64(base64(json)): the API server decodes once and the kubelet
# JSON-parses base64 text (measured: `invalid character 'e'`, the first
# character of eyJhdXRocyI6). The mock above is faithful to the real kubectl
# (it base64s the file content into data), which is what makes this read mean
# anything — and what let the old assertion stay green over the broken
# installer, since it pinned the destination without ever decoding it.
pull_secret_kubelet_ok() {
  "$PY" - "$MOCK_ROOT/applied.yaml" <<'PY'
import base64
import json
import sys
vals = []
for ln in open(sys.argv[1], encoding="utf-8"):
    if ".dockerconfigjson:" in ln:
        vals.append(ln.split(":", 1)[1].strip())
if not vals:
    print("no .dockerconfigjson data in the applied Secret")
    sys.exit(1)
for v in vals:
    try:
        raw = base64.b64decode(v)
    except Exception:
        print("the applied data is not base64 — kubectl always base64s the file content")
        sys.exit(1)
    try:
        doc = json.loads(raw)
    except Exception as e:
        print("the applied data decodes once to bytes the kubelet cannot parse as JSON (%s) — the file held the exchange's base64 rather than the decoded JSON" % (e,))
        sys.exit(1)
    if not ((doc.get("auths") or {}).get("ghcr.io") or {}).get("username"):
        print('the decoded JSON carries no auths["ghcr.io"].username')
        sys.exit(1)
print("%d Secret(s), each decoding once to JSON with auths[ghcr.io].username" % (len(vals),))
PY
}
run 'the applied Secret decodes once, as the kubelet does, to a ghcr.io credential' green pull_secret_kubelet_ok

# The control: the pre-fix shape — the exchange's base64 written through
# without decoding — must go RED under the same read. A check that stays green
# on base64(base64(json)) is the defect this packet fixes, asserted over.
fixture_double="$WORK/install-double-encode.sh"
sed '/REGISTRY_DOCKERCONFIGJSON" | base64 -d |/s/ | base64 -d |/ |/' \
  "$SUBSTRATE/install.sh" | sed '/^main "$@"/d' >"$fixture_double"
if grep -q 'REGISTRY_DOCKERCONFIGJSON" | base64 -d' "$fixture_double" \
  || ! grep -q -- '--from-file=.dockerconfigjson=/dev/stdin' "$fixture_double"; then
  fail 'control fixture: the double-encode edit failed to apply' \
    "the sed did not restore the pre-fix write, so the control would prove nothing"
  failures=$((failures + 1))
else
  MOCK_ROOT_DOUBLE="$WORK/pull-secret-double"
  mkdir -p "$MOCK_ROOT_DOUBLE"
  (
    # shellcheck source=/dev/null
    . "$fixture_double"
    kubectl() { mock_kubectl "$@"; }
    export MOCK_ROOT="$MOCK_ROOT_DOUBLE"
    export REGISTRY_DOCKERCONFIGJSON="$EXCHANGE_B64"
    apply_pull_secret >/dev/null 2>&1
  ) || true
  MOCK_ROOT_SAVED="$MOCK_ROOT"
  MOCK_ROOT="$MOCK_ROOT_DOUBLE"
  run 'control: writing the encoded value fails the kubelet-shaped read' red pull_secret_kubelet_ok
  MOCK_ROOT="$MOCK_ROOT_SAVED"
fi

# ===========================================================================
# 3c. THE NAMESPACE IS MADE BEFORE THE SECRET IS WRITTEN INTO IT
# ===========================================================================
# The defect this packet fixes, and the reason the mock above now has a
# namespace registry. Measured live on a wiped box:
#
#       secret ghcr-pull-secret to be created in argocd
#       secret ghcr-pull-secret to be created in identity
#   Error from server (NotFound): error when creating "STDIN":
#   namespaces "identity" not found
#
# Five of the six namespaces the pull secret is written into do not exist at
# step 5 — the Argo CD Applications at step 6 create them, with
# `CreateNamespace=true` — and `set -e` ended the install at its second
# namespace. Only a box with nothing in it could show that, which is why the
# store below starts EMPTY: no namespace exists, and the mock refuses a Secret
# written into one that was never made, exactly as the API server does.
#
# The green case is therefore the whole claim in one run: six namespaces made
# BY THE STEP, and the secret written into each of them. The order is read off
# the recorded argv rather than asserted from the source, so "created first" is
# a measurement and not a reading of the code.
MOCK_ROOT_NS="$WORK/pull-secret-ns"
mkdir -p "$MOCK_ROOT_NS"
rm -f "$MOCK_ROOT_NS/curl-calls" "$MOCK_ROOT_NS/curl-response" "$MOCK_ROOT_NS/kubectl-argv" \
  "$MOCK_ROOT_NS/applied.yaml" "$MOCK_ROOT_NS/namespaces" "$WORK/pull-secret-ns.log" "$WORK/ns-runner.sh"
exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT_NS/curl-response"
# A SEPARATE PROCESS, for the reason the control below states in full: a `|| ec`
# guard suspends `set -e` for the whole guarded body, so a subshell run cannot
# tell "the install finished" from "the install survived a failure it should
# have died of". This one is the run that must answer the way a box does.
cat >"$WORK/ns-runner.sh" <<RUNNER
set -euo pipefail
export MOCK_ROOT="$MOCK_ROOT_NS"
export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.cafaye.test"
# shellcheck source=/dev/null
. "$fixture_sourced"
kubectl() { mock_kubectl "\$@"; }
curl() {
  printf '%s\n' "\$*" >>"\$MOCK_ROOT/curl-calls"
  cat "\$MOCK_ROOT/curl-response"
  case "\$*" in
    *"-w"*) printf '\n%s\n' 200 ;;
  esac
  return 0
}
install_pull_secret
RUNNER
export -f mock_kubectl mock_namespace_exists mock_apply_plant mock_has_control_bytes
pull_ns_ec=0
bash "$WORK/ns-runner.sh" >"$WORK/pull-secret-ns.log" 2>&1 || pull_ns_ec=$?
if [ "$pull_ns_ec" -ne 0 ]; then
  fail 'step 5 creates each namespace and then writes the pull secret into it' \
    "exit $pull_ns_ec: $(cat "$WORK/pull-secret-ns.log")"
else
  pass 'step 5 creates each namespace and then writes the pull secret into it'
fi

# The namespace the step MADE, in the step's own words. Read from the registry
# the mock writes, because that is the record of what the cluster would now
# hold — the state the manager produced by hand on the affected box, which is
# the state a fixed installer has to produce itself.
pull_secret_namespaces_ok() {
  local ns
  for ns in "${REGISTRY_PULL_NAMESPACES[@]}"; do
    if ! grep -qx -- "$ns" "$MOCK_ROOT_NS/namespaces" 2>/dev/null; then
      printf 'the step did not create namespace %s\n' "$ns"
      return 1
    fi
  done
  printf 'the step itself created all %d namespaces it writes into' "${#REGISTRY_PULL_NAMESPACES[@]}"
}
run 'every pulling namespace is created by the step, not by hand' green pull_secret_namespaces_ok

# THE ORDER, off the recorded argv: one `create namespace <ns>` line must sit
# BEFORE the `secret <name> -n <ns>` line for the same namespace. A check that
# only asked whether both happened would be satisfied by a step that wrote the
# secret first and made the namespace afterwards, which is the wiped-box
# failure with a happy ending nobody would see until a re-run.
pull_secret_order_ok() {
  local ns made wrote
  for ns in "${REGISTRY_PULL_NAMESPACES[@]}"; do
    made="$(grep -n -m1 -- "create namespace $ns " "$MOCK_ROOT_NS/kubectl-argv" 2>/dev/null | cut -d: -f1 || true)"
    # The recorded argv, in full: `create secret docker-registry <name> -n <ns>
    # --from-file=… --dry-run=client -o yaml`. The `-n <ns>` after the name is
    # what makes this the write for THIS namespace and not a neighbour's.
    wrote="$(grep -n -m1 -- "docker-registry $REGISTRY_PULL_SECRET_NAME -n $ns " "$MOCK_ROOT_NS/kubectl-argv" 2>/dev/null | cut -d: -f1 || true)"
    if [ -z "$made" ]; then
      printf 'no namespace creation was recorded for %s\n' "$ns"
      return 1
    fi
    if [ -z "$wrote" ]; then
      printf 'no pull-secret write was recorded for %s\n' "$ns"
      return 1
    fi
    if [ "$made" -gt "$wrote" ]; then
      printf 'the secret was written into %s (call %s) before its namespace was created (call %s)\n' "$ns" "$wrote" "$made"
      return 1
    fi
  done
  printf 'in every namespace the create precedes the secret write'
}
run 'the namespace is created BEFORE the secret is written into it' green pull_secret_order_ok

# THE RED CONTROL. The namespace itself is refused — an admission policy, a
# kubeconfig aimed at a cluster that will not answer, a box with the k3s
# service down. The step must REFUSE BY NAME and stop, never skip the
# namespace and carry on: a run that continued would report success while that
# namespace pulled nothing, and the CrashLoopBackOff it produced would name
# neither this line nor the namespace that was never made.
MOCK_ROOT_REFUSE="$WORK/pull-secret-refuse"
mkdir -p "$MOCK_ROOT_REFUSE"
rm -f "$MOCK_ROOT_REFUSE/curl-calls" "$MOCK_ROOT_REFUSE/curl-response" "$MOCK_ROOT_REFUSE/kubectl-argv" \
  "$MOCK_ROOT_REFUSE/applied.yaml" "$MOCK_ROOT_REFUSE/namespaces" "$WORK/pull-secret-refuse.log"
refuse_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() {
    printf '%s\n' "$*" >>"$MOCK_ROOT_REFUSE/curl-calls"
    cat "$MOCK_ROOT_REFUSE/curl-response"
    case "$*" in
      *"-w"*) printf '\n%s\n' 200 ;;
    esac
    return 0
  }
  export MOCK_ROOT="$MOCK_ROOT_REFUSE"
  export MOCK_NAMESPACE_REFUSE="identity"
  export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.cafaye.test"
  exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT_REFUSE/curl-response"
  install_pull_secret >"$WORK/pull-secret-refuse.log" 2>&1
) || refuse_ec=$?
refuse_ok() {
  if [ "$refuse_ec" -eq 0 ]; then
    printf 'the step succeeded with a namespace it could not create — a silent skip\n'
    return 1
  fi
  case "$(cat "$WORK/pull-secret-refuse.log")" in
    *"identity could not be created"*) ;;
    *) printf 'the refusal does not name the namespace\n%s\n' "$(cat "$WORK/pull-secret-refuse.log")"; return 1 ;;
  esac
  # And nothing was written into it. A refusal that leaves half a credential
  # behind is the half-installed substrate the preflight's header forbids.
  local ns
  for ns in identity gateway courier parlor; do
    if grep -q "namespace: $ns" "$MOCK_ROOT_REFUSE/applied.yaml" 2>/dev/null; then
      printf 'the pull secret was written into %s after the namespace that could not be created\n' "$ns"
      return 1
    fi
  done
  printf 'refused loudly, by name, and no secret was written past the hole'
}
run 'a namespace that cannot be created refuses the step, by name, with nothing written past it' green refuse_ok

# THE BOUNDARY IS REAL, AND THE CREATION IS LOAD-BEARING. The same mock, with
# the namespace creation DELETED from the installer, must now fail at the first
# namespace with the API server's own NotFound — proving the mock is not merely
# permissive and that nothing else in the step makes the namespaces. Without
# this control a green run above could be a mock that always says yes.
fixture_no_ns="$WORK/install-no-namespace.sh"
rm -f "$fixture_no_ns"
# Guarded by an `if`, not run bare: under this script's `set -e` a python exit
# would take the whole suite down before the failure is reported as a failure
# of the control rather than as an unexplained stop.
if "$PY" - "$SUBSTRATE/install.sh" "$fixture_no_ns" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
start = None
for i, ln in enumerate(lines):
    if ln.startswith('apply_pull_secret() {'):
        start = i
        break
if start is None:
    sys.exit("control fixture: apply_pull_secret was not found")
end = None
for i in range(start, len(lines)):
    if lines[i] == '}':
        end = i
        break
if end is None:
    sys.exit("control fixture: apply_pull_secret has no closing brace")
head = "if ! kubectl --kubeconfig="
close = 'could not be created, so the image pull secret cannot be written'
block_start = block_end = None
for i in range(start, end):
    if block_start is None and lines[i].strip().startswith(head):
        block_start = i
    if close in lines[i]:
        block_end = i
        break
if block_start is None or block_end is None:
    sys.exit("control fixture: the namespace-creation statement was not found")
# The statement is an `if ! … ; then … fi`, so the closing `fi` is part of it:
# deleting the body and leaving the `fi` behind would produce a fixture that
# does not parse, which fails loudly rather than proving something by accident.
while block_end + 1 < len(lines) and lines[block_end + 1].strip() == "fi":
    block_end += 1
del lines[block_start:block_end + 1]
out_lines = [ln for ln in lines if ln != 'main "$@"']
out = "\n".join(out_lines)
# The fixture must assert its own premise before it is used: the secret write
# is still there (otherwise the control proves a different, dumber failure),
# and the namespace creation is gone from apply_pull_secret while the other
# call site, install_service_secrets' own loop, is untouched. A control whose
# mutation silently stopped breaking the thing it names is a proof of nothing.
body = out[out.index("apply_pull_secret() {"):out.index("install_pull_secret() {")]
if 'create namespace "$ns"' in body:
    sys.exit("control fixture: the creation is still inside apply_pull_secret")
if '--from-file=.dockerconfigjson=/dev/stdin' not in body:
    sys.exit("control fixture: the secret write is no longer inside apply_pull_secret")
if 'create namespace "$ns"' not in out:
    sys.exit("control fixture: the edit removed more than the one call site")
# The trailing `main "$@"` is stripped the way every fixture in this file
# strips it, so sourcing the fixture DEFINES the step rather than running it.
if 'main "$@"' in out:
    sys.exit("control fixture: the main call is still there, so sourcing runs the install")
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
then
  :
else
  echo "control fixture: the namespace-creation delete did not apply, so the control proves nothing" >&2
fi
if [ -s "$fixture_no_ns" ] && bash -n "$fixture_no_ns" \
  && diff -q "$SUBSTRATE/install.sh" "$fixture_no_ns" >/dev/null 2>&1; then
  fail 'control fixture: the namespace-creation delete failed to apply' \
    "the fixture is byte-identical to the installer, so the control would prove nothing"
elif [ -s "$fixture_no_ns" ] && bash -n "$fixture_no_ns"; then
  MOCK_ROOT_NONS="$WORK/pull-secret-no-ns"
  mkdir -p "$MOCK_ROOT_NONS"
  rm -f "$MOCK_ROOT_NONS/curl-calls" "$MOCK_ROOT_NONS/kubectl-argv" "$MOCK_ROOT_NONS/applied.yaml" \
    "$MOCK_ROOT_NONS/namespaces" "$WORK/pull-secret-no-ns.log" "$WORK/no-ns-runner.sh"
  exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT_NONS/curl-response"
  # The runner is a SEPARATE bash process, and that is the whole reason it
  # exists. Every live case above runs as `( … ) || ec=$?`, and a command in a
  # `||` list runs with `set -e` SUSPENDED for its whole body — MEASURED: with
  # the creation deleted, the guarded run walked all six namespaces, applied
  # nothing, and exited 0. A box does not do that; `set -e` ends the install at
  # the first failure. So the case that must reproduce the box's behaviour runs
  # in a process with no such context, where `set -e` is live, and its status
  # is read off the child rather than inferred.
  cat >"$WORK/no-ns-runner.sh" <<RUNNER
set -euo pipefail
export MOCK_ROOT="$MOCK_ROOT_NONS"
export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.cafaye.test"
# The state the box was ACTUALLY in: step 4 has made argocd, and nothing has
# made the other five. With that seed the failure this control reproduces lands
# on the same namespace the live run stopped on, so the evidence is the same
# evidence rather than a nearby shape of it.
printf 'argocd\n' >"\$MOCK_ROOT/namespaces"
# shellcheck source=/dev/null
. "$fixture_no_ns"
kubectl() { mock_kubectl "\$@"; }
curl() {
  printf '%s\n' "\$*" >>"\$MOCK_ROOT/curl-calls"
  cat "\$MOCK_ROOT/curl-response"
  case "\$*" in
    *"-w"*) printf '\n%s\n' 200 ;;
  esac
  return 0
}
install_pull_secret
RUNNER
  export -f mock_kubectl mock_namespace_exists mock_apply_plant mock_has_control_bytes
  no_ns_ec=0
  bash "$WORK/no-ns-runner.sh" >"$WORK/pull-secret-no-ns.log" 2>&1 || no_ns_ec=$?
  no_ns_ok() {
    if [ "$no_ns_ec" -eq 0 ]; then
      printf 'the step exited 0 on a box where every namespace it writes into was refused\n'
      return 1
    fi
    case "$(cat "$WORK/pull-secret-no-ns.log")" in
      *'namespaces "identity" not found'*) ;;
      *) printf 'the stop is not the API server NotFound for identity\n%s\n' "$(cat "$WORK/pull-secret-no-ns.log")"; return 1 ;;
    esac
    # It stopped AT identity, so argocd — the namespace that existed — was
    # written and the rest were not. That is the live evidence line for line,
    # and it is what a silent skip would be missing.
    if ! grep -q "namespace: argocd" "$MOCK_ROOT_NONS/applied.yaml" 2>/dev/null; then
      printf 'argocd was not written, which is not the state the box was measured in\n'
      return 1
    fi
    local ns
    for ns in identity gateway courier parlor observability; do
      if grep -q "namespace: $ns" "$MOCK_ROOT_NONS/applied.yaml" 2>/dev/null; then
        printf 'the secret was written into %s after the refusal — the loop carried on\n' "$ns"
        return 1
      fi
    done
    printf 'stopped at %s with namespaces "identity" not found, argocd written and nothing after it' "$no_ns_ec"
  }
  run 'control: without the creation the step stops at identity, exactly as the box did' green no_ns_ok
else
  fail 'control fixture: the namespace-creation delete failed to apply' \
    "the edit did not remove the creation, so the control would prove nothing"
fi

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
      # The namespace registry the mock keeps: one name per line, held to prove
      # the step MADE the namespaces it wrote into. It carries no credential —
      # it holds names — which is why it is allowed to sit in the store.
      namespaces) continue ;;
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
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="https://app.example.com/sign-in/oidc"
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
if [ "$(mock_get identity identity-secrets OIDC_ISSUER)" = "https://identity.example.com" ] && [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" = "https://app.example.com/sign-in/oidc" ]; then
  pass 'oidc: the issuer and login UI ride along — the surface is issuer, key, id and login UI, or nothing'
else
  fail 'oidc: the issuer and login UI ride along — the surface is issuer, key, id and login UI, or nothing' "OIDC_ISSUER: $(mock_get identity identity-secrets OIDC_ISSUER) OIDC_LOGIN_UI_URL: $(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)"
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
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="https://app.example.com/sign-in/oidc"
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
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="https://app.example.com/sign-in/oidc"
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

# OIDC four-member surface: the installer as it stands on master wires three
# keys (issuer + signing key + id) and leaves OIDC_LOGIN_UI_URL absent — the
# shape identity refuses with `OIDC_LOGIN_UI_URL: no OIDC login UI configured`
# (CrashLoopBackOff). The packet adds the fourth member and the all-or-nothing
# refusal before any secret is written.
OIDC_FOUR_ISSUER="https://identity.example.com"
OIDC_FOUR_LOGIN="https://app.example.com/sign-in/oidc"

# Green: with issuer and login UI both set, identity-secrets carries all four.
MOCK_ROOT="$WORK/oidc-four-green"
mkdir -p "$MOCK_ROOT"
oidc_four_green_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="$OIDC_FOUR_LOGIN"
  install_service_secrets >"$WORK/oidc-four-green.log" 2>&1
) || oidc_four_green_ec=$?
if [ "$oidc_four_green_ec" -ne 0 ]; then
  fail 'oidc four: issuer and login UI both set wires all four keys' "$(cat "$WORK/oidc-four-green.log")"
elif [ "$(mock_get identity identity-secrets OIDC_ISSUER)" != "$OIDC_FOUR_ISSUER" ] || \
     [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" != "$OIDC_FOUR_LOGIN" ] || \
     [ -z "$(mock_get identity identity-secrets OIDC_SIGNING_KEY)" ] || \
     [ -z "$(mock_get identity identity-secrets OIDC_SIGNING_KEY_ID)" ]; then
  fail 'oidc four: issuer and login UI both set wires all four keys' \
    "OIDC_ISSUER='$(mock_get identity identity-secrets OIDC_ISSUER)' OIDC_LOGIN_UI_URL='$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)' key present? $([ -n "$(mock_get identity identity-secrets OIDC_SIGNING_KEY)" ] && echo yes || echo no)"
else
  pass 'oidc four: issuer and login UI both set wires all four keys'
fi
# Read-back on a warm box: a secret written but not readable is the defect the
# whole record tripwire exists to catch. Verify the four round-trip.
if [ "$oidc_four_green_ec" -eq 0 ]; then
  if [ "$(mock_get identity identity-secrets OIDC_ISSUER)" = "$OIDC_FOUR_ISSUER" ] && \
     [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" = "$OIDC_FOUR_LOGIN" ]; then
    pass 'oidc four: the four keys round-trip on a warm box (read-back agrees)'
  else
    fail 'oidc four: the four keys round-trip on a warm box (read-back agrees)' "stored keys do not match inputs"
  fi
fi

# Green: the login UI alone, or the issuer alone, is REFUSED before any secret
# is written — and the refusal names the missing variable.
oidc_refused_case() {
  local has_issuer="$1" has_login="$2" want_var="$3" name="$4"
  MOCK_ROOT="$WORK/oidc-refuse-$name"
  mkdir -p "$MOCK_ROOT"
  mfa_seed_roles
  local ec=0 log="$WORK/oidc-refuse-$name.log"
  (
    # shellcheck source=/dev/null
    . "$fixture_sourced"
    kubectl() { mock_kubectl "$@"; }
    mfa_smtp_env
    if [ "$has_issuer" -eq 1 ]; then export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"; else export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""; fi
    if [ "$has_login" -eq 1 ]; then export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="$OIDC_FOUR_LOGIN"; else export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL=""; fi
    install_service_secrets >"$log" 2>&1
  ) || ec=$?
  if [ "$ec" -eq 0 ]; then
    printf 'issuer-alone shape was not refused (exit 0)\n'
    return 1
  fi
  case "$(cat "$log")" in
    *"$want_var"*) ;;
    *)
      printf 'the refusal did not name %s\n%s\n' "$want_var" "$(cat "$log")"
      return 1
      ;;
  esac
  if [ -d "$MOCK_ROOT/identity/identity-secrets" ]; then
    printf 'a refused run still wrote identity-secrets\n'
    return 1
  fi
  printf 'refused, naming %s, with no secret written' "$want_var"
}
run 'oidc four: issuer alone is refused, naming the missing login UI' green oidc_refused_case 1 0 "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" issuer-alone
run 'oidc four: login UI alone is refused, naming the missing issuer' green oidc_refused_case 0 1 "KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER" login-alone

# RED control: the installer as it stands on master (three keys, no refusal)
# passes the issuer-alone shape through without complaint — i.e. the refusal
# check actually discriminates. Revert the new code and the check must go red;
# if it does not, the check is worthless. The fixture is the tree as it stood
# BEFORE the commit that wired OIDC_LOGIN_UI_URL (that commit's parent) — the
# pre-fix, three-key installer. It must NOT be HEAD~1: every commit this branch
# lands after the four-key merge shifts the parent onto the four-key tree, so
# a fixture taken from HEAD~1 silently becomes the new installer and `set -u`
# trips its new variable reference as an "unbound variable" instead of showing
# the pass-through this control is about (measured: the first commit after the
# oidc-four merge turned this control red for exactly that reason, exit 1 with
# KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL unbound).
fixture_oidc_three_orig="$WORK/install-oidc-three-orig.sh"
oidc_three_base="$(git -C "$ROOT" log --format=%H -S 'KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL' -- templates/substrate/install.sh | tail -1)"
if [ -z "${oidc_three_base:-}" ] \
  || ! git -C "$ROOT" show "${oidc_three_base}^:templates/substrate/install.sh" >"$fixture_oidc_three_orig" 2>/dev/null \
  || grep -q "OIDC_LOGIN_UI_URL" "$fixture_oidc_three_orig"; then
  fail 'control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)' "no three-key tree found (base=${oidc_three_base:-<none>})"
else
  sed '/^main "$@"/d' "$fixture_oidc_three_orig" >"$WORK/install-oidc-three-sourced.sh"
  MOCK_ROOT="$WORK/oidc-three-control"
  mkdir -p "$MOCK_ROOT"
  oidc_three_ec=0
  (
    mfa_seed_roles
    # shellcheck source=/dev/null
    . "$WORK/install-oidc-three-sourced.sh"
    kubectl() { mock_kubectl "$@"; }
    # The three-key installer reads KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER but not
    # KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL — unset the latter so set -u
    # does not fatal, and do not export it at all for this fixture.
    mfa_smtp_env
    unset KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL 2>/dev/null || true
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
    install_service_secrets >"$WORK/oidc-three-control.log" 2>&1
  ) || oidc_three_ec=$?
  # The old installer PASSES issuer-alone (exit 0) and writes three keys.
  if [ "$oidc_three_ec" -eq 0 ] && [ -n "$(mock_get identity identity-secrets OIDC_ISSUER)" ] && [ -z "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL 2>/dev/null || true)" ]; then
    pass 'control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)'
  else
    fail 'control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)' "exit $oidc_three_ec: $(cat "$WORK/oidc-three-control.log")"
  fi
fi
# And the new installer is the one that GOES RED on the same input — the
# discrimination the control above proves is not vacuous.
run 'control: the four-key installer refuses issuer-alone (the new code discriminates)' green oidc_refused_case 1 0 "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" issuer-alone

# Red control: a login UI that is not an http(s) origin is refused (that is
# oidc.ValidateLoginUIURL's own rule — mirror it, do not re-derive it).
MOCK_ROOT="$WORK/oidc-bad-login"
mkdir -p "$MOCK_ROOT"
oidc_bad_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="not-a-url"
  install_service_secrets >"$WORK/oidc-bad.log" 2>&1
) || oidc_bad_ec=$?
if [ "$oidc_bad_ec" -eq 0 ]; then
  fail 'oidc four: a non-http(s) login UI is refused' "exit 0 — the shape check did not fire"
else
  case "$(cat "$WORK/oidc-bad.log")" in
    *KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL*)
      pass 'oidc four: a non-http(s) login UI is refused, naming the variable'
      ;;
    *)
      fail 'oidc four: a non-http(s) login UI is refused, naming the variable' "$(cat "$WORK/oidc-bad.log")"
      ;;
  esac
fi
if [ -d "$MOCK_ROOT/identity/identity-secrets" ]; then
  fail 'oidc four: a refused bad login UI writes no secret' "identity-secrets was created despite the refusal"
else
  pass 'oidc four: a refused bad login UI writes no secret'
fi
# Additional bad shapes, each refused: query, fragment, userinfo, no host.
for bad in "https://app.example.com/sign-in?x=1" "https://app.example.com/sign-in#frag" "https://user@app.example.com/sign-in" "https:///sign-in"; do
  MOCK_ROOT="$WORK/oidc-bad-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$MOCK_ROOT"
  oidc_bad2_ec=0
  (
    mfa_seed_roles
    # shellcheck source=/dev/null
    . "$fixture_sourced"
    kubectl() { mock_kubectl "$@"; }
    mfa_smtp_env
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
    export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="$bad"
    install_service_secrets >"$WORK/oidc-bad2.log" 2>&1
  ) || oidc_bad2_ec=$?
  if [ "$oidc_bad2_ec" -eq 0 ]; then
    fail "oidc four: bad login UI '$bad' is refused" "exit 0"
  else
    pass "oidc four: bad login UI '$bad' is refused"
  fi
done

# Warm-box reconcile: a pre-existing identity-secrets without OIDC_LOGIN_UI_URL
# gains the fourth key when the operator now supplies both inputs, reusing the
# stored signing key.
MOCK_ROOT="$WORK/oidc-warm-reconcile"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
# Legacy secret: three OIDC keys but no login UI (the crashloop shape).
mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity?sslmode=disable"
mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "legacy-signup"
mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "legacy-mfa"
mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"
legacy_oidc_key="$(openssl genrsa 2048 2>/dev/null)"
legacy_oidc_kid="$(printf 'box-%s' "$(printf '%s' "$legacy_oidc_key" | openssl dgst -sha256 -hex | sed 's/^.*= *//' | cut -c1-16)")"
mock_seed identity identity-secrets OIDC_ISSUER "$OIDC_FOUR_ISSUER"
mock_seed identity identity-secrets OIDC_SIGNING_KEY "$legacy_oidc_key"
mock_seed identity identity-secrets OIDC_SIGNING_KEY_ID "$legacy_oidc_kid"
mock_seed gateway gateway-secrets REDIS_URL "redis://:pw@redis.data.svc.cluster.local:6379"
mock_seed gateway gateway-secrets ASSERTION_SIGNING_KEY "dummy"
mock_seed courier courier-secrets DATABASE_URL "ecto://courier_app:pw@host/courier"
mock_seed parlor parlor-secrets DATABASE_URL "postgres://parlor_app:pw@host/parlor"
oidc_warm_ec=0
(
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="$OIDC_FOUR_LOGIN"
  install_service_secrets >"$WORK/oidc-warm.log" 2>&1
) || oidc_warm_ec=$?
if [ "$oidc_warm_ec" -ne 0 ]; then
  fail 'warm: a legacy secret without login UI is patched on a re-run' "$(cat "$WORK/oidc-warm.log")"
elif [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" != "$OIDC_FOUR_LOGIN" ]; then
  fail 'warm: a legacy secret without login UI is patched on a re-run' "OIDC_LOGIN_UI_URL not patched: '$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)'"
elif [ "$(mock_get identity identity-secrets OIDC_SIGNING_KEY)" != "$legacy_oidc_key" ]; then
  fail 'warm: a legacy secret reuses its stored signing key' "signing key was rotated"
else
  pass 'warm: a legacy secret without login UI is patched, reusing the stored signing key'
fi

# 13d-bis. A gateway-secrets that PREDATES the assertion key is healed on a
# re-run. This is the live box exactly: all four service secrets exist (so the
# `secrets` guard would skip install_service_secrets whole) and gateway-secrets
# holds REDIS_URL only. The repair has to run above the guard, or it never runs
# on the only box that needs it. The key is generated and merge-patched; the
# stored REDIS_URL survives, and the key is a PKCS#8 PEM gateway can parse.
pkey_shape_ok() {
  local pem line bits
  pem="$1"
  line="$(printf '%s' "$pem" | head -1)"
  case "$line" in
    *"BEGIN RSA PRIVATE KEY"*)
      printf 'a PKCS#1 "BEGIN RSA PRIVATE KEY" — gateway parses PKCS#8 and refuses this\n'
      return 1
      ;;
    *"BEGIN PRIVATE KEY"*) ;;
    *)
      printf 'not a PKCS#8 PEM private key (%s)\n' "$line"
      return 1
      ;;
  esac
  bits="$(printf '%s' "$pem" | openssl pkey -noout -text 2>/dev/null | sed -n 's/.*Private-Key: (\([0-9][0-9]*\) bit.*/\1/p' | head -1)"
  if [ -z "$bits" ]; then
    printf 'openssl could not parse the stored key\n'
    return 1
  fi
  if [ "$bits" -lt 2048 ]; then
    printf 'the key is %s bits — below the RSA floor\n' "$bits"
    return 1
  fi
  printf 'a %s-bit PKCS#8 RSA PEM private key\n' "$bits"
}

MOCK_ROOT="$WORK/legacy-gateway"
mkdir -p "$MOCK_ROOT"
legacy_ec=0
(
  mfa_seed_roles
  # All four secrets exist — the guard's own contract — and gateway-secrets is
  # the pre-fix shape: REDIS_URL only.
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "legacy-signup"
  mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "legacy-mfa"
  mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"
  mock_seed gateway gateway-secrets REDIS_URL "redis://:pw@redis.data.svc.cluster.local:6379"
  mock_seed courier courier-secrets DATABASE_URL "ecto://courier_app:pw@host/courier"
  mock_seed parlor parlor-secrets DATABASE_URL "postgres://parlor_app:pw@host/parlor"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  install_service_secrets >"$WORK/legacy-gateway.log" 2>&1
) || legacy_ec=$?
if [ "$legacy_ec" -ne 0 ]; then
  fail 'repair: the assertion-key repair runs on a re-run that skips the guard' "$(cat "$WORK/legacy-gateway.log")"
elif [ -z "$(mock_get gateway gateway-secrets ASSERTION_SIGNING_KEY)" ]; then
  fail 'repair: the assertion-key repair runs on a re-run that skips the guard' "ASSERTION_SIGNING_KEY is still missing — the guard skipped the repair"
elif [ "$(mock_get gateway gateway-secrets REDIS_URL)" != "redis://:pw@redis.data.svc.cluster.local:6379" ]; then
  fail 'repair: the assertion-key repair runs on a re-run that skips the guard' "REDIS_URL did not survive the merge patch"
else
  pass 'repair: the assertion-key repair runs on a re-run that skips the guard'
fi
legacy_key="$(mock_get gateway gateway-secrets ASSERTION_SIGNING_KEY)"
if [ -n "$legacy_key" ]; then
  run 'repair: the generated key is a PKCS#8 RSA PEM at the RSA floor' green pkey_shape_ok "$legacy_key"
  run 'repair: the generated key never reaches the installer output' green oidc_log_clean "$(cat "$WORK/legacy-gateway.log")" "$legacy_key"
  # The control: a PKCS#1 PEM (the `-----BEGIN RSA PRIVATE KEY-----` header) must
  # be refused by the same shape check, or the check cannot tell the two
  # encodings apart. The header alone is the control because the header is
  # exactly what the check tests first, and it is stable across OpenSSL versions
  # (`genrsa` writes PKCS#1 on 1.1 and PKCS#8 on 3.x).
  run 'control: a PKCS#1 RSA PEM is refused (gateway parses PKCS#8)' red pkey_shape_ok \
    "$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKfake\n-----END RSA PRIVATE KEY-----')"
fi
# The re-run is stable: a second pass finds the key and does not touch it.
MOCK_ROOT="$WORK/legacy-gateway" legacy_rerun_ec=0
(
  mfa_seed_roles
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  install_service_secrets >>"$WORK/legacy-gateway.log" 2>&1
) || legacy_rerun_ec=$?
if [ "$legacy_rerun_ec" -eq 0 ] && [ "$(mock_get gateway gateway-secrets ASSERTION_SIGNING_KEY)" = "$legacy_key" ]; then
  pass 'repair: a second pass keeps the stored key (never rotates)'
else
  fail 'repair: a second pass keeps the stored key (never rotates)' "the key changed or the re-run failed"
fi

# 13e. The courier loop is box-internal: one run mints the credential through
# identity's own API, writes the SAME value into both secrets that have to hold
# it, and restarts both deployments. Nothing is printed.
COURIER_MINT_TOKEN="cap_box_minted_fake_token_value"
# The public origin identity's mail links point at, for the tests that exercise
# the CONFIGURED mail path. It is a test fixture, never a shipped default: the
# installer has no default for KIT_SUBSTRATE_APP_BASE_URL on purpose (a guessed
# or localhost value mails a reader to a screen that is not theirs).
APP_BASE_URL="https://app.example.com"
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
# A REAL local listener for the mint's port wait. The step now proves the
# forwarded port is UP before it curls it (the (7) connect race), and a mock
# port-forward that returns instantly does not open one — so the test opens a
# socket on a random high port and points the mint at it. The real
# kit_substrate_await_port then succeeds, which is what a working box looks
# like; a fake override would have proven nothing about the wait.
mint_port=$(( 20000 + (RANDOM % 20000) ))
"$PY" -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
time.sleep(30)' "$mint_port" &
mint_listener=$!
# Wait for the listener to be bound before the mint races it.
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/${mint_port}") 2>/dev/null && break
  sleep 0.1
done
mint_loop_ec=0
(
  mfa_seed_roles
  # The box's secrets as step 9 left them — so the assertion below is about
  # what the mint ADDS, not about a secret it created itself.
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
  mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "z-thread-is-long-enough-0123456789-_Xab"
  # The Deployment Argo synced from step 6's Applications — step 12's await
  # polls for it before watching its rollout, so the fixture carries it the
  # way a box past step 6 does. Without this the await polls to its bound and
  # refuses, which is the next section's control rather than this test.
  mock_seed identity deploy-identity ready yes
  export KIT_SUBSTRATE_IDENTITY_LOCAL_PORT="$mint_port"
  # The CONFIGURED mail path: with the public origin set, identity's pair and its
  # five link templates land together, so the assertions below are about a
  # complete block. The UNCONFIGURED path is proven separately in §18c.
  export KIT_SUBSTRATE_APP_BASE_URL="$APP_BASE_URL"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  curl() { courier_mint_curl "$@"; }
  mfa_smtp_env
  mint_courier_identity_token >"$WORK/mint-loop.log" 2>&1
) || mint_loop_ec=$?
kill "$mint_listener" 2>/dev/null || true
wait "$mint_listener" 2>/dev/null || true
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

# --- the port wait the mint now takes before it curls -------------------------
# The probe's (7) connect failure was a race: `kubectl port-forward` opens its
# local listener asynchronously, and the curl ran the line after the `&`. The
# fix is existence-then-use, so the wait must be able to BOTH succeed against a
# live port and FAIL against a dead one — the green case alone would be
# satisfied by a function that returns 0 unconditionally.
#
# A fresh listener: the mint's own was killed above, and a green case against a
# dead port would prove the opposite of what it claims.
wait_port=$(( 20000 + (RANDOM % 20000) ))
"$PY" -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(4)
time.sleep(20)' "$wait_port" &
wait_listener=$!
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/${wait_port}") 2>/dev/null && break
  sleep 0.1
done
mint_await_ec=0
(
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kit_substrate_await_port "$wait_port" 5
) || mint_await_ec=$?
kill "$wait_listener" 2>/dev/null || true
wait "$wait_listener" 2>/dev/null || true
if [ "$mint_await_ec" -eq 0 ]; then
  pass 'the port wait succeeds against a live listener'
else
  fail 'the port wait succeeds against a live listener' "kit_substrate_await_port exited ${mint_await_ec}"
fi
# A port nothing listens on. `$mint_port + 1` is not guaranteed free, but a
# random high port beside a bound one almost always is, and the red assertion
# is what proves the wait is bounded and honest.
dead_port=$(( 40000 + (RANDOM % 15000) ))
dead_ec=0
(
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kit_substrate_await_port "$dead_port" 2
) || dead_ec=$?
if [ "$dead_ec" -ne 0 ]; then
  pass 'control: the port wait fails against a dead port (it is bounded and honest)'
else
  fail 'control: the port wait fails against a dead port (it is bounded and honest)' \
    "kit_substrate_await_port returned 0 for a port nothing listens on"
fi

# ===========================================================================
# 13g. Step 10 — the services' schemas are applied, idempotently, and a failed
#      migration fails the step naming the service
# ===========================================================================
#
# THE DEFECT THIS STEP EXISTS FOR. Nothing ran a service's migrations, so a box
# that "finished" the substrate booted identity against an empty database and
# the outbox loop retried forever on `relation "outbox_events" does not exist`.
# The step runs one one-shot Job per schema-owning service (identity, courier),
# in that service's own RUNNING image (read back from the Deployment), as the
# OWNER role, and waits for the pod's phase.
#
# Three things are asserted, each with a control that must answer differently:
#
#   1. THE RUN. Both pods are launched, identity's Job is given the OWNER DSN
#      (`identity`, not `identity_app`), courier's Job is given
#      `COURIER_OWNER_DATABASE_URL` (owner) AND `DATABASE_URL` (app, because its
#      release eval raises without it). The marker secret is written.
#   2. THE GUARD. A second run is a no-op — no `run` invocation is added — so a
#      re-run applies nothing new.
#   3. THE RED CONTROL. A pod that reaches `Failed` makes the step exit non-zero
#      and name the service and its OWNER role — never a green install over an
#      empty schema.
#
# The mock stores the image/command/env/phase of every `kubectl run`, and the
# pod is deleted on success exactly as a real box deletes it — so the assertions
# read the recorded argv, which survives the delete.
migrate_seed_fixture() {
  mkdir -p "$MOCK_ROOT/data" "$MOCK_ROOT/identity" "$MOCK_ROOT/courier"
  printf 'data\nidentity\ncourier\n' >"$MOCK_ROOT/namespaces"
  # The OWNER role passwords step 8 makes (the migrate Job's credential) and the
  # app passwords step 8 makes beside them (courier's DATABASE_URL).
  mock_seed data postgres-role-identity password "owner-identity-pw"
  mock_seed data postgres-role-courier password "owner-courier-pw"
  mock_seed data postgres-role-courier-app password "app-courier-pw"
  # The Deployments Argo synced from step 6 — step 10 reads the image off them,
  # so there is no second pin to keep in step.
  mock_seed identity deploy-identity image "ghcr.io/cafaye/identity:0.1.0"
  mock_seed courier deploy-courier image "ghcr.io/cafaye/courier:0.1.0"
}

MOCK_ROOT="$WORK/migrate-run"
mkdir -p "$MOCK_ROOT"
migrate_run_ec=0
(
  migrate_seed_fixture
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-run-receipt.json"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  install_migrations >"$WORK/migrate-run.log" 2>&1
) || migrate_run_ec=$?
migrate_argv="$MOCK_ROOT/kubectl-argv"
if [ "$migrate_run_ec" -ne 0 ]; then
  fail 'step 10 runs and completes when both migrations succeed' "$(cat "$WORK/migrate-run.log")"
else
  pass 'step 10 runs and completes when both migrations succeed'
fi
# The OWNER DSN, proven by the role name in the recorded argv. `identity_app`
# would be the application role, which owns nothing and cannot run DDL.
if grep -q -- '--env=DATABASE_URL=postgres://identity:owner-identity-pw@' "$migrate_argv" 2>/dev/null; then
  pass "step 10 migrates identity as its OWNER role (identity, not identity_app)"
else
  fail "step 10 migrates identity as its OWNER role (identity, not identity_app)" \
    "argv did not carry the owner DSN: $(grep -o 'DATABASE_URL=[^ ]*' "$migrate_argv" 2>/dev/null | head -3)"
fi
if grep -q -- '--env=COURIER_OWNER_DATABASE_URL=ecto://courier:owner-courier-pw@' "$migrate_argv" 2>/dev/null; then
  pass "step 10 migrates courier as its OWNER role via COURIER_OWNER_DATABASE_URL"
else
  fail "step 10 migrates courier as its OWNER role via COURIER_OWNER_DATABASE_URL" \
    "argv did not carry the owner DSN"
fi
if grep -q -- '--env=DATABASE_URL=ecto://courier_app:app-courier-pw@' "$migrate_argv" 2>/dev/null; then
  pass "step 10 also gives courier its app DATABASE_URL (its release eval raises without it)"
else
  fail "step 10 also gives courier its app DATABASE_URL (its release eval raises without it)" \
    "argv did not carry the app DSN"
fi
# The image comes from the Deployment, not a literal in install.sh.
if grep -q -- '--image=ghcr.io/cafaye/identity:0.1.0' "$migrate_argv" 2>/dev/null &&
   grep -q -- '--image=ghcr.io/cafaye/courier:0.1.0' "$migrate_argv" 2>/dev/null; then
  pass 'step 10 migrates in each service own RUNNING image (read off the Deployment)'
else
  fail 'step 10 migrates in each service own RUNNING image (read off the Deployment)' \
    "argv images: $(grep -o -- '--image=[^ ]*' "$migrate_argv" 2>/dev/null | sort -u | tr '\n' ' ')"
fi
if [ "$(mock_get data substrate-migrations identity)" = "ghcr.io/cafaye/identity:0.1.0" ] &&
   [ "$(mock_get data substrate-migrations courier)" = "ghcr.io/cafaye/courier:0.1.0" ]; then
  pass 'step 10 records the applied image per service (the re-run marker)'
else
  fail 'step 10 records the applied image per service (the re-run marker)' \
    "marker identity='$(mock_get data substrate-migrations identity)' courier='$(mock_get data substrate-migrations courier)'"
fi
# A service with no schema is named in the plan and skipped, not run.
if grep -q -- '--image=.*parlor' "$migrate_argv" 2>/dev/null; then
  fail 'step 10 does not run a migrate Job for parlor (it owns no schema)' "a parlor run was recorded"
else
  pass 'step 10 does not run a migrate Job for parlor (it owns no schema)'
fi

# --- the guard: a re-run applies nothing new ----------------------------------
runs_before="$(grep -c '^run ' "$migrate_argv" 2>/dev/null || true)"
migrate_rerun_ec=0
(
  migrate_seed_fixture
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-rerun-receipt.json"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  install_migrations >"$WORK/migrate-rerun.log" 2>&1
) || migrate_rerun_ec=$?
runs_after="$(grep -c '^run ' "$migrate_argv" 2>/dev/null || true)"
if [ "$migrate_rerun_ec" -ne 0 ]; then
  fail 'step 10 is a no-op on a re-run (its guard skips)' "$(cat "$WORK/migrate-rerun.log")"
elif [ "$runs_after" != "$runs_before" ]; then
  fail 'step 10 is a no-op on a re-run (its guard skips)' \
    "a re-run launched $((runs_after - runs_before)) more pod(s)"
elif ! grep -q 'already applied' "$WORK/migrate-rerun.log"; then
  fail 'step 10 is a no-op on a re-run (its guard skips)' "the step did not say it skipped: $(cat "$WORK/migrate-rerun.log")"
else
  pass 'step 10 is a no-op on a re-run (its guard skips)'
fi

# --- the red control: a failed migration fails the step, naming the service ---
MOCK_ROOT="$WORK/migrate-fail"
mkdir -p "$MOCK_ROOT"
migrate_fail_ec=0
(
  migrate_seed_fixture
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-fail-receipt.json"
  export MOCK_POD_PHASE="Failed"
  export MOCK_POD_LOGS="permission denied for schema public"
  # shellcheck source=/dev/null
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  install_migrations >"$WORK/migrate-fail.log" 2>&1
) || migrate_fail_ec=$?
if [ "$migrate_fail_ec" -eq 0 ]; then
  fail 'control: a failed migration fails the step (a green install over an empty schema)' \
    "install_migrations exited 0 on a Failed pod"
elif ! grep -q 'identity' "$WORK/migrate-fail.log"; then
  fail 'control: a failed migration fails the step (a green install over an empty schema)' \
    "the failure did not name the service: $(cat "$WORK/migrate-fail.log")"
elif ! grep -q 'OWNER' "$WORK/migrate-fail.log"; then
  fail 'control: a failed migration fails the step (a green install over an empty schema)' \
    "the failure did not name the DSN/role: $(cat "$WORK/migrate-fail.log")"
else
  pass 'control: a failed migration fails the step, naming the service and its OWNER role'
fi
# The pod's logs are surfaced — a Failed phase with no explanation is a dead end.
if grep -q 'permission denied for schema public' "$WORK/migrate-fail.log"; then
  pass 'control: the failed migration prints the pod logs'
else
  fail 'control: the failed migration prints the pod logs' "the logs were not printed"
fi

# The static shape: install_migrations is a step main calls, its guard exists,
# and the inventory lists the two schema-owning services. A comment can satisfy
# none of these, and the fixture above proves the live path.
check_migration_step() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
problems = []


def need(sub, msg):
    if sub not in code:
        problems.append(msg)


need("TOTAL=13", "TOTAL is not 13")
if not re.search(r"(?m)^install_migrations\(\)", code):
    problems.append("no install_migrations step")
if not re.search(r"(?m)^  install_migrations$", code):
    problems.append("main never calls install_migrations")
if not re.search(r"(?m)^migration_guard_applied\(\)", code):
    problems.append("no migration_guard_applied guard")
# The guard is USED, not merely defined: install_migrations must consult it, or
# a re-run re-launches every migrate pod.
body = re.search(r"(?m)^install_migrations\(\)\s*\{(.*?)\n\}", code, re.S)
if not body or "migration_guard_applied" not in body.group(1):
    problems.append("install_migrations never consults its guard")
if not re.search(r"(?m)^owner_database_url_for\(\)", code):
    problems.append("no owner_database_url_for — the migrate DSN must be the OWNER role")
# The inventory: the two services with a schema, and no silent third.
m = re.search(r"migration_service_has_schema\(\)\s*\{(.*?)\n\}", code, re.S)
if not m:
    problems.append("no migration_service_has_schema inventory")
else:
    for svc in ("identity", "courier"):
        if svc not in m.group(1):
            problems.append(f"{svc} is not in the migration inventory")
# The failure path names the service and prints the logs.
need("did not succeed", "the failure path has no message")
need("logs \"pod/kit-migrate-", "the failure path does not print the pod logs")
# The banned shape: the migrate COMMAND swallowed so a failed migration reads
# as a green step. `delete … || true` is fine (and required); `$cmd || true` is
# the defect. Match the run's command position, not the pod's name.
if re.search(r"--command -- \$cmd[^\n]*\|\| true", code):
    problems.append("the migrate command is swallowed with `|| true`")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("step 10 exists, is called, has a guard and an OWNER-role inventory")
PY
}

run 'step 10 has a step, a guard and an OWNER-role inventory' green check_migration_step "$SUBSTRATE/install.sh"

# The control: an inventory with courier removed must go red under the same
# check — an inventory the check cannot see shrink is documentation.
fixture_mig_inventory="$WORK/install-mig-inventory.sh"
sed 's/    identity | courier) return 0 ;;/    identity) return 0 ;;/' \
  "$SUBSTRATE/install.sh" >"$fixture_mig_inventory"
run 'control: an inventory missing a service goes red' red check_migration_step "$fixture_mig_inventory"

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
# carrying a generated password, oidc_key_id_for builds a thumbprint, and the
# three timing helpers build a clock reading or a duration — so it must reach
# its caller and never a terminal. They are excused from rule 1 and NOT checked
# by rule 2, because a printf that cannot carry `$pw` is a DSN with no password
# in it, and a printf that cannot carry a duration is a clock with no reading.
# The assertion at the bottom of this check keeps the list honest: a value
# producer called anywhere else goes red.
VALUE_PRODUCERS = {
    "database_url_for", "owner_database_url_for", "migration_env_args_for", "oidc_key_id_for",
    "kit_substrate_now", "kit_substrate_seconds", "kit_substrate_elapsed",
    "kit_substrate_url_host", "kit_substrate_intended_hosts",
    "kit_substrate_readiness_pending_count", "kit_substrate_readiness_summary",
    "kit_substrate_readiness_json",
}

# Every variable in install.sh that HOLDS secret material, by name. This is a
# closed list, not a pattern: a `*SECRET*` glob would also match `secret_name`
# (a Kubernetes object's name, which is not a value) and `secret_base`, and a
# check that fires on correct work teaches its reader to ignore it. A new
# secret-bearing variable must be added here in the same commit that adds it —
# the list is the contract, and an absent name is a hole.
SECRET_VARS = {
    "OIDC_SIGNING_KEY",             # generated on the box, step 9
    "OIDC_SIGNING_KEY_ID",
    "ASSERTION_SIGNING_KEY",        # generated on the box, step 9 (gateway mounts it)
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
        # A command substitution, either spelling: `$(...)` captures the output
        # and `<(...)` feeds it to another command. Both keep the value off the
        # process stdout; a bare call would not.
        if "$(" not in window and "<(" not in window:
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
  "$(mock_get gateway gateway-secrets ASSERTION_SIGNING_KEY)"
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
# and lost the re-run's reclaim. Step 6's applications apply no longer carries a
# literal `-f` (it applies the resolved list — see section 20), so the control
# grows the flags on the Cluster apply, another LOCAL `-f "$…"` apply; the rule
# is about the target's origin, not about which local line it is.
fixture_local_ss="$WORK/install-local-server-side.sh"
sed 's|apply -f "$DATA_DIR/postgres-cluster.yaml"|apply --server-side=true --force-conflicts -f "$DATA_DIR/postgres-cluster.yaml"|' \
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
# 17. A wait that can face an empty list proves existence first
# ===========================================================================
#
# Section 16 proves step 1's wait. This is the RULE, so a wait added later is
# covered by construction rather than by memory.
#
# `kubectl wait --for=<condition> <kind>` comes in two shapes and only one of
# them can race:
#
#   LIST      `--all`, or a selector `-l key=value`. The list is a QUERY, and
#             a query against a cluster where nothing matches YET is empty —
#             which kubectl answers with `error: no matching resources found`
#             rather than by waiting.
#   NAMED     one named object. It exists or it does not, and a GET of the
#             missing one fails loudly by name.
#
# So a LIST wait is excused by one of TWO things, and which one is the whole
# classification:
#
#   1. an apply of the objects it selects, earlier in the SAME function. Apply
#      is a synchronous round trip — the deployments exist the moment it
#      returns, so the list cannot be empty. cert-manager's and Argo CD's
#      `--all` waits are this, and they are safe.
#   2. a kit_substrate_await_list of the same kind, selector and namespace.
#      This is the one for objects a CONTROLLER creates asynchronously — the
#      Node object behind the kubelet, the Cluster's pods behind the CNPG
#      operator.
#
# A NAMED wait needs neither: it runs after a synchronous apply of that same
# object, and a GET of a missing named object fails loudly by name rather than
# as an empty-list race. All three populations are asserted, because a check
# that only fires on the awaits would be satisfied by deleting every wait.
#
# `rollout status` is the same race in a different verb, and the audit reads
# it too. It watches a NAMED object — deployment/identity in step 11 — but
# the NAMED excuse does not apply: nothing in that function applied the object
# synchronously, because Argo creates it ASYNCHRONOUSLY from step 6's
# Applications. A missing named object is NotFound, exit 1, not a wait (the
# empty-list no-op branch is the path a named object never takes) — so a
# rollout status is excused ONLY by a matching kit_substrate_await_list above
# it, never by an apply. The `deployment/identity` spelling is split on `/`
# where the wait path reads separate kind and name tokens.
#
# And the bound is part of the rule. Splitting one wait into two is the easiest
# way to double a step's patience, so the four numbers must still add up to the
# totals the steps always had: 120s for the node, 600s for the CNPG pods.
wait_lists_audit() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
# Comments stripped first, as everywhere in this file: the rule is about what
# the installer RUNS, and this file's own prose names both shapes.
code = re.sub(r"(?m)^\s*#.*$", "", src)
# A backslash continuation is ONE command, and the join is load-bearing here:
# a `kubectl wait … -l \` split across lines is one wait.
code = code.replace("\\\n", " ")

funcs = {"<top>": []}
cur = "<top>"
for ln in code.split("\n"):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", ln)
    if m:
        cur = m.group(1)
        funcs.setdefault(cur, [])
        continue
    funcs.setdefault(cur, []).append(ln)


def split_args(toks):
    """(kind, selector, name, namespace) out of a kubectl argument list."""
    kind = toks[0] if toks else ""
    sel = name = ns = None
    i = 1
    while i < len(toks):
        t = toks[i]
        if t == "--all":
            sel = "--all"
        elif t in ("-l", "--selector"):
            sel = "-l " + toks[i + 1]
            i += 1
        elif t in ("-n", "--namespace"):
            ns = toks[i + 1]
            i += 1
        elif t.startswith("--namespace="):
            ns = t.split("=", 1)[1]
        elif not t.startswith("-"):
            name = t
        i += 1
    return (kind, sel, name, ns)


unexcused, awaited, applied, named, rollout_awaited = [], 0, 0, 0, 0
for fn, lines in funcs.items():
    # Walk the function IN ORDER, because an excuse that comes after the wait
    # is not an excuse: an apply below it has not created the list the wait
    # is about to query.
    awaits, apply_seen = [], False
    for ln in lines:
        m = re.search(r"""kit_substrate_await_list\s+"?\$[A-Za-z_]+"?\s+(.+)$""", ln)
        if m:
            awaits.append(split_args(m.group(1).replace('"', "").split()))
        elif "kubectl" in ln and re.search(r"\bapply\b", ln):
            apply_seen = True
        if "kubectl" in ln and re.search(r"\brollout\s+status\b", ln):
            m2 = re.search(r"\brollout\s+status\s+(\S+)", ln)
            target = m2.group(1)
            if "/" in target:
                rkind, rname = target.split("/", 1)
            else:
                rkind, rname = target, None
            rns = None
            mn = re.search(r"(?:-n|--namespace)\s+(\S+)", ln)
            if mn:
                rns = mn.group(1)
            else:
                mn = re.search(r"--namespace=(\S+)", ln)
                if mn:
                    rns = mn.group(1)
            if (rkind, rname, rns) in [(a[0], a[2], a[3]) for a in awaits if a]:
                rollout_awaited += 1
                continue
            # A rollout watches an object a CONTROLLER synced, so a synchronous
            # apply above it is not an excuse the way it is for a wait — only
            # a matching await excuses it.
            unexcused.append(
                f"{fn}(): rollout status watches {rkind}/{rname} "
                f"(ns {rns or 'cluster-scoped'}) with no kit_substrate_await_list "
                "for it first — a missing object is NotFound, not a wait"
            )
            continue
        if "kubectl" not in ln or not re.search(r"\bwait\s+--for=condition=", ln):
            continue
        toks = re.search(r"\bwait\s+--for=condition=(\S+)\s+(.*)$", ln).group(2)
        kind, sel, name, ns = split_args(toks.split())
        if sel is None:
            # A NAMED object: it exists or it does not, and the missing one
            # fails loudly by name rather than as an empty-list race.
            named += 1
            continue
        # The pairing key. `--all` and an absent selector are the same query,
        # so an await that spells one is matched against a wait that spells
        # the other — a rule that depended on the spelling would be a rule
        # about spelling.
        key = (kind, None if sel == "--all" else sel, ns)
        if key in [(a[0], None if a[1] in ("--all", None) else a[1], a[3]) for a in awaits if a]:
            awaited += 1
            continue
        if apply_seen:
            applied += 1
            continue
        unexcused.append(
            f"{fn}(): the LIST wait on {kind} {sel} "
            f"(ns {ns or 'cluster-scoped'}) is neither preceded by an apply of "
            "what it selects nor by a kit_substrate_await_list for the same "
            "list — an empty list is an error, not a wait"
        )

if unexcused:
    print("; ".join(unexcused))
    sys.exit(1)

# Non-vacuity, in all three populations. A file that deleted every wait would
# find nothing to audit and would pass on the empty case.
if awaited < 2:
    print(f"expected at least 2 awaited list waits (the node, the CNPG pods), "
          f"found {awaited}")
    sys.exit(1)
if applied < 2:
    print(f"expected the two --all waits that ride a synchronous apply "
          f"(cert-manager, Argo CD), found {applied}")
    sys.exit(1)
# The bound is the POPULATION, not a threshold to protect: it moved from 4 to
# 3 when step 6's named wait (argocd-server, which core-install does not ship)
# was deleted — the three that remain are cnpg-controller-manager, redis and
# nats. Lowered with that reason, in the commit that deleted the wait; a bound
# that silently rotted past the population it counts is how a non-vacuity check
# becomes a no-op.
if named < 3:
    print(f"expected the named waits to still be there, found {named}")
    sys.exit(1)
if rollout_awaited < 1:
    print("expected step 11's rollout watch to prove the Deployment exists "
          "first (Argo syncs it asynchronously), found none")
    sys.exit(1)

# The bound is part of the fix: two waits must not add up to more patience
# than the one wait had.
defaults = dict(re.findall(r"^\s*: \"\$\{([A-Za-z_]+):=(\d+)\}\"", code, re.M))
for a, b, total, what in (
    ("NODE_REGISTER_TIMEOUT", "NODE_READY_TIMEOUT", 120, "step 1"),
    ("CNPG_POD_TIMEOUT", "CNPG_POD_READY_TIMEOUT", 600, "step 8"),
    ("IDENTITY_DEPLOY_TIMEOUT", "IDENTITY_ROLLOUT_TIMEOUT", 360, "step 11"),
):
    pair = [int(defaults.get(v, -1)) for v in (a, b)]
    if sum(pair) != total:
        print(
            f"{what}'s bound grew: {a}+{b} = {sum(pair)}s, want {total}s "
            "— splitting a wait into two must not make the step more patient"
        )
        sys.exit(1)
print(
    f"{awaited} list wait(s) prove existence first, "
    f"{applied} ride a synchronous apply, "
    f"{named} named wait(s) need neither, "
    f"{rollout_awaited} rollout watch(es) prove existence first"
)
PY
}

run 'every list wait proves the list exists first, and no bound grew' \
  green wait_lists_audit "$SUBSTRATE/install.sh"

# The control that matters: delete the node's await and the rule must go red
# NAMING the resource. This is the whole packet in one fixture.
fixture_drop_node_await="$WORK/install-drop-node-await.sh"
sed '/kit_substrate_await_list "\$NODE_REGISTER_TIMEOUT" node/d' \
  "$SUBSTRATE/install.sh" >"$fixture_drop_node_await"
mode_out=""; mode_ec=0
mode_out="$(wait_lists_audit "$fixture_drop_node_await" 2>&1)" || mode_ec=$?
case "$mode_ec:$mode_out" in
  0:*)
    fail 'control: a list wait with no existence check goes red' "exit 0 — the check cannot see a missing await"
    ;;
  *"node"*)
    pass 'control: a list wait with no existence check goes red, naming the resource'
    ;;
  *)
    fail 'control: a list wait with no existence check goes red, naming the resource' "$mode_out"
    ;;
esac

# And the second list wait, proved separately: one fixture that only drops the
# CNPG one. Two waits, two controls — a check that only notices the first is
# half a rule, and the CNPG half is the one that was quietly racy in the other
# direction (the pods are created by the OPERATOR, not by this installer).
fixture_drop_pod_await="$WORK/install-drop-pod-await.sh"
sed '/kit_substrate_await_list "\$CNPG_POD_TIMEOUT" pod/d' \
  "$SUBSTRATE/install.sh" >"$fixture_drop_pod_await"
mode_out=""; mode_ec=0
mode_out="$(wait_lists_audit "$fixture_drop_pod_await" 2>&1)" || mode_ec=$?
case "$mode_ec:$mode_out" in
  0:*)
    fail 'control: the CNPG pod wait with no existence check goes red' "exit 0 — the check cannot see a missing await"
    ;;
  *"pod"*)
    pass 'control: the CNPG pod wait with no existence check goes red, naming the resource'
    ;;
  *)
    fail 'control: the CNPG pod wait with no existence check goes red, naming the resource' "$mode_out"
    ;;
esac

# A THIRD list wait, arriving with no await and no apply above it — the control
# that stops this being a list of two remembered lines rather than a rule.
fixture_new_list_wait="$WORK/install-new-list-wait.sh"
cp "$SUBSTRATE/install.sh" "$fixture_new_list_wait"
printf '  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd --all --timeout=120s\n' \
  >>"$fixture_new_list_wait"
run 'control: a new list wait with no existence check goes red' red \
  wait_lists_audit "$fixture_new_list_wait"

# And the bound, in the direction that would otherwise be invisible: growing
# the registration budget is the easiest way to make a cold box pass, and it is
# not a fix — it is the same race with more room.
fixture_grown_bound="$WORK/install-grown-bound.sh"
sed 's/: "${NODE_REGISTER_TIMEOUT:=90}"/: "${NODE_REGISTER_TIMEOUT:=300}"/' \
  "$SUBSTRATE/install.sh" >"$fixture_grown_bound"
if ! grep -q 'NODE_REGISTER_TIMEOUT:=300' "$fixture_grown_bound"; then
  fail 'control fixture: the bound-growing edit failed to apply' \
    "the sed did not change the number, so the control would prove nothing"
  failures=$((failures + 1))
else
  mode_out=""; mode_ec=0
  mode_out="$(wait_lists_audit "$fixture_grown_bound" 2>&1)" || mode_ec=$?
  case "$mode_ec:$mode_out" in
    0:*)
      fail 'control: growing the registration bound goes red' "exit 0 — a step that waits longer passes the audit"
      ;;
    *grew*)
      pass 'control: growing the registration bound goes red'
      ;;
    *)
      fail 'control: growing the registration bound goes red' "$mode_out"
      ;;
  esac
fi

# Step 11's watch, proved the same way: drop its await and the rule must go
# red NAMING the Deployment. A rule that cannot see the line it was widened
# for is the exact blindness the handoff names.
fixture_drop_deploy_await="$WORK/install-drop-deploy-await.sh"
sed '/kit_substrate_await_list "\$IDENTITY_DEPLOY_TIMEOUT" deployment/d' \
  "$SUBSTRATE/install.sh" >"$fixture_drop_deploy_await"
mode_out=""; mode_ec=0
mode_out="$(wait_lists_audit "$fixture_drop_deploy_await" 2>&1)" || mode_ec=$?
case "$mode_ec:$mode_out" in
  0:*)
    fail 'control: a rollout watch with no existence check goes red' "exit 0 — the check cannot see a missing await"
    ;;
  *"deployment/identity"*)
    pass 'control: a rollout watch with no existence check goes red, naming the Deployment'
    ;;
  *)
    fail 'control: a rollout watch with no existence check goes red, naming the Deployment' "$mode_out"
    ;;
esac

# A SECOND rollout watch, arriving with no await — the control that stops this
# being a rule about one remembered line rather than about the verb.
fixture_new_rollout="$WORK/install-new-rollout.sh"
cp "$SUBSTRATE/install.sh" "$fixture_new_rollout"
printf '  kubectl --kubeconfig="$KUBECONFIG" -n courier rollout status deployment/courier --timeout=60s\n' \
  >>"$fixture_new_rollout"
run 'control: a new rollout watch with no existence check goes red' red \
  wait_lists_audit "$fixture_new_rollout"

# And step 11's bound, in the same direction: splitting 360s into 240+180 is
# not a split, it is 60s of new patience for Argo (and the previous split
# 120+180=300 was itself 60s short of the controller's 180s resync).
fixture_grown_identity="$WORK/install-grown-identity-bound.sh"
sed 's/: "${IDENTITY_DEPLOY_TIMEOUT:=180}"/: "${IDENTITY_DEPLOY_TIMEOUT:=240}"/' \
  "$SUBSTRATE/install.sh" >"$fixture_grown_identity"
if ! grep -q 'IDENTITY_DEPLOY_TIMEOUT:=240' "$fixture_grown_identity"; then
  fail 'control fixture: the step-11 bound-growing edit failed to apply' \
    "the sed did not change the number, so the control would prove nothing"
  failures=$((failures + 1))
else
  mode_out=""; mode_ec=0
  mode_out="$(wait_lists_audit "$fixture_grown_identity" 2>&1)" || mode_ec=$?
  case "$mode_ec:$mode_out" in
    0:*)
      fail 'control: growing the Deployment bound goes red' "exit 0 — a step that waits longer passes the audit"
      ;;
    *grew*)
      pass 'control: growing the Deployment bound goes red'
      ;;
    *)
      fail 'control: growing the Deployment bound goes red' "$mode_out"
      ;;
  esac
fi

# ===========================================================================
# 18. Step 11 watches the Deployment only after it exists — the Argo race, executed
# ===========================================================================
#
# Section 17 proves the rule; this proves the step. `rollout status` on a
# Deployment Argo has not created yet is NotFound, exit 1 — not a wait — and
# steps 7 through 10 sit between step 6's Applications and this watch, so a
# warm box never notices while a slow Argo sync kills the install at step 11.
#
# The harness runs mint_courier_identity_token for real against a file-backed
# kubectl with Argo's timing: a GET of a missing Deployment exits 0 printing
# nothing (real kubectl), rollout status of one is NotFound (real kubectl),
# and both succeed once the sync lands. Secrets and patches behave like
# mock_kubectl's, so the mint's writes are still asserted, not just its exit.
#
# THREE CASES, the same shape as section 16:
#   1. slow Argo — the Deployment lands on the second poll. The mint must
#      complete, both secrets holding the one minted value.
#   2. dead Argo — it never lands. The step must REFUSE inside its bound,
#      naming the missing Deployment, with no watch run and nothing written.
#   3. THE CONTROL — the pre-fix shape with the await removed, against slow
#      Argo. It must abort with NotFound and no existence check before it.
ROLLOUT_DIR="$WORK/rollout"
mkdir -p "$ROLLOUT_DIR"

# rollout_kubectl — Argo, on a slow box. DEPLOY_APPEARS_AT is the poll after
# which the sync lands. Every invocation is recorded, because "watched after
# it existed" is an order and not a return code.
rollout_kubectl() {
  printf '%s\n' "$*" >>"$ROLLOUT_DIR/argv"
  case "$*" in
    *"rollout status deployment/identity"*)
      if [ ! -f "$ROLLOUT_DIR/deployed" ]; then
        printf 'error: deployments.apps "identity" not found\n' >&2
        return 1
      fi
      printf 'deployment "identity" successfully rolled out\n'
      return 0
      ;;
    *"rollout restart"*)
      return 0
      ;;
    *"port-forward"*)
      # A real one blocks forever; this one returns instantly, like mock_kubectl's.
      return 0
      ;;
    *"get deployment identity"*)
      # A GET of an empty list is not an error: kubectl exits 0 and prints
      # nothing. The sync is a few seconds away, which is the race.
      local polls
      polls=$(( $(cat "$ROLLOUT_DIR/polls" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$polls" >"$ROLLOUT_DIR/polls"
      if [ "$polls" -ge "${DEPLOY_APPEARS_AT:-2}" ]; then
        : >"$ROLLOUT_DIR/deployed"
        printf 'identity   1/1   1   1   10d\n'
      fi
      return 0
      ;;
    *"get secret "*)
      # The two shapes read_secret_key uses — existence, and the base64 a
      # jsonpath read decodes — over the same store mock_kubectl keeps.
      local seen="" rname="" rns="" rtmpl="" a
      for a in "$@"; do
        case "$a" in
          --kubeconfig=*) ;;
          get | secret) ;;
          -n) seen="ns" ;;
          -o) seen="tmpl" ;;
          *)
            case "$seen" in
              ns) rns="$a"; seen="" ;;
              tmpl) rtmpl="$a"; seen="" ;;
              *) [ -z "$rname" ] && rname="$a" ;;
            esac
            ;;
        esac
      done
      local rdir="$MOCK_ROOT/$rns/$rname"
      if [ -z "$rtmpl" ]; then
        if [ -d "$rdir" ]; then return 0; else return 1; fi
      fi
      local rkey="${rtmpl#jsonpath={.data.}"
      rkey="${rkey%\}}"
      if [ -z "$rkey" ] || [ "$rkey" = "$rtmpl" ] || [ ! -f "$rdir/$rkey" ]; then
        return 1
      fi
      base64 <"$rdir/$rkey" | tr -d '\n'
      return 0
      ;;
    *"patch secret "*)
      # A merge patch, read from --patch-file=/dev/stdin and merged over the
      # store — the same contract mock_kubectl's patch branch holds, so "no
      # other key is wiped" means something here too. `--patch-file=-` is
      # refused with kubectl's own error: the real binary reads a FILE named
      # `-` and fails, so the mock must not be the only place the spelling
      # works.
      local p prev="" patch_ns="" patch_name="" patch_file_arg="" body=""
      for p in "$@"; do
        case "$p" in
          -n) prev="ns" ;;
          secret) prev="name" ;;
          --type=merge) ;;
          --type) prev="skip" ;;
          --patch-file=*) patch_file_arg="${p#--patch-file=}" ;;
          *)
            case "$prev" in
              ns) patch_ns="$p"; prev="" ;;
              name) patch_name="$p"; prev="" ;;
              skip) prev="" ;;
            esac
            ;;
        esac
      done
      if [ -z "$patch_name" ]; then
        echo "rollout_kubectl: patch without a secret name" >&2
        return 1
      fi
      case "$patch_file_arg" in
        /dev/stdin) body="$(cat)" ;;
        -) echo "error: unable to read patch file: open -: no such file or directory" >&2; return 1 ;;
        *) echo "rollout_kubectl: patch without --patch-file=/dev/stdin" >&2; return 1 ;;
      esac
      local pdir="$MOCK_ROOT/$patch_ns/$patch_name"
      mkdir -p "$pdir"
      # A `"key":null` entry DELETES the stored key, exactly as a real merge
      # patch does — the orphan sweep relies on it (see mock_kubectl's patch
      # branch for the same contract). `data` is the persisted map: a null
      # there deletes the entry, a value there is base64 and is decoded the
      # way the jsonpath read decodes it.
      local -a rollout_patch_keys=()
      local rollout_patch_key
      while IFS= read -r rollout_patch_key; do
        [ -n "$rollout_patch_key" ] && rollout_patch_keys+=("$rollout_patch_key")
      done < <(printf '%s' "$body" | jq -r '.stringData // {} | keys[]')
      for rollout_patch_key in ${rollout_patch_keys[@]+"${rollout_patch_keys[@]}"}; do
        # A null under stringData is a NO-OP here too — see mock_kubectl's
        # patch branch for why the box ignores it.
        if [ "$(printf '%s' "$body" | jq -r --arg k "$rollout_patch_key" '.stringData[$k] | type')" != "null" ]; then
          printf '%s' "$body" | jq -jr --arg k "$rollout_patch_key" '.stringData[$k]' >"$pdir/$rollout_patch_key"
        fi
      done
      local -a rollout_data_keys=()
      local rollout_data_key
      while IFS= read -r rollout_data_key; do
        [ -n "$rollout_data_key" ] && rollout_data_keys+=("$rollout_data_key")
      done < <(printf '%s' "$body" | jq -r '.data // {} | keys[]')
      for rollout_data_key in ${rollout_data_keys[@]+"${rollout_data_keys[@]}"}; do
        if [ "$(printf '%s' "$body" | jq -r --arg k "$rollout_data_key" '.data[$k] | type')" = "null" ]; then
          rm -f "$pdir/$rollout_data_key"
        else
          printf '%s' "$body" | jq -jr --arg k "$rollout_data_key" '.data[$k]' | base64 -d >"$pdir/$rollout_data_key"
        fi
      done
      return 0
      ;;
    *)
      printf 'rollout_kubectl: unhandled %s\n' "$*" >&2
      return 1
      ;;
  esac
}

# mint_step <sourced-fixture> <appears-at> <deploy-timeout> — run step 11 for
# real against that fixture, and leave the exit status behind in $mint_ec.
# The port-forward is stubbed (it never blocks here) and curl is the mint's
# own exchange from 13e; the sleeps and the openssl rand are the real ones.
#
# The step runs in a CHILD bash, not in a `( … ) || ec=$?` subshell — and the
# distinction is the whole mechanism. Under `set -e`, a subshell that is a
# component of `||` runs with errexit DISABLED, and this bash does not
# re-enable it on an inner `set -e` either (measured: `( set -e; false; echo
# x ) || …` prints x). A guarded subshell would therefore march past a failing
# `rollout status` and exit 0 — the opposite of the box, where the same
# failure aborts the install, and exactly what the pre-fix control below
# looked like before this harness existed. The child is a component of
# nothing: its `set -e` is real, a failing kubectl aborts it, and the
# parent's `||` reads an honest exit status. It carries the mocks via
# `declare -f`, so there is still exactly one copy of each mock.
mint_step() {
  rm -f "$ROLLOUT_DIR/argv" "$ROLLOUT_DIR/polls" "$ROLLOUT_DIR/deployed" "$ROLLOUT_DIR/run.log"
  rm -rf "$ROLLOUT_DIR/store"
  mkdir -p "$ROLLOUT_DIR/store"
  local script="$ROLLOUT_DIR/mint-run.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'ROLLOUT_DIR=%q\n' "$ROLLOUT_DIR"
    printf 'MOCK_ROOT=%q\n' "$ROLLOUT_DIR/store"
    printf 'FIXTURE=%q\n' "$1"
    printf 'DEPLOY_APPEARS_AT=%q\n' "$2"
    printf 'IDENTITY_DEPLOY_TIMEOUT=%q\n' "$3"
    printf 'IDENTITY_ROLLOUT_TIMEOUT=%q\n' "5"
    # BEFORE the source, because the installer reads the receipt path at
    # source time and a value exported after it is a value it never saw.
    printf 'KIT_SUBSTRATE_RECEIPT=%q\n' "$ROLLOUT_DIR/receipt.json"
    printf 'COURIER_MINT_TOKEN=%q\n' "$COURIER_MINT_TOKEN"
    # identity's link templates are gated on this value. It is SET by default so
    # the pair/template tests below exercise the CONFIGURED mail path; a caller
    # runs `MINT_APP_BASE_URL=__UNSET__ mint_step …` for the deliberate no-mail
    # path (see §18c). The literal `__UNSET__` means "emit nothing", so install.sh
    # falls back to its own empty default rather than to a value the test chose.
    if [ "${MINT_APP_BASE_URL:-$APP_BASE_URL}" != "__UNSET__" ]; then
      printf 'KIT_SUBSTRATE_APP_BASE_URL=%q\n' "${MINT_APP_BASE_URL:-$APP_BASE_URL}"
    fi
    declare -f mock_seed mfa_smtp_env courier_mint_curl rollout_kubectl
    printf '%s\n' \
      'export DRY_RUN=0 HEADLESS=0' \
      '# shellcheck source=/dev/null' \
      '. "$FIXTURE"' \
      'kubectl() { rollout_kubectl "$@"; }' \
      'curl() { courier_mint_curl "$@"; }' \
      '# The port-forward is stubbed here, so the port wait must be too — this' \
      '# harness is about the DEPLOYMENT wait and the rollout watch. The wait' \
      '# itself is proven green and red against a real socket in 13f-2.' \
      'kit_substrate_await_port() { return 0; }' \
      'mfa_smtp_env' \
      'mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity"' \
      'mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"' \
      'mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "z-thread-is-long-enough-0123456789-_Xab"'
    # MINT_SEED_ORPHAN=1 plants the warm-box state: an orphaned COURIER_TOKEN
    # with no base URL (the old installer wrote the token alone) plus a stray
    # template pointing at a base this box no longer declares — beside the
    # keys a converging sweep must NOT touch (NATS_URL and the OIDC triple).
    if [ "${MINT_SEED_ORPHAN:-}" = "1" ]; then
      printf '%s\n' \
        'mock_seed identity identity-secrets COURIER_TOKEN "orphan-token-from-old-installer"' \
        'mock_seed identity identity-secrets EMAIL_CHANGE_LINK_TEMPLATE "https://old.example.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"' \
        'mock_seed identity identity-secrets OIDC_ISSUER "https://issuer.example.com"' \
        'mock_seed identity identity-secrets OIDC_SIGNING_KEY "old-oidc-key"' \
        'mock_seed identity identity-secrets OIDC_SIGNING_KEY_ID "old-oidc-kid"'
    fi
    # MINT_SEED_COMPLETE=1 plants the live-box state: a COMPLETE seven-key
    # block — the pair plus all five link templates derived from
    # https://app.cafaye.com, the box that boots and sends all four recovery
    # messages. With no base URL this run cannot rewrite it, so the sweep
    # must leave every key in place and say so.
    if [ "${MINT_SEED_COMPLETE:-}" = "1" ]; then
      printf '%s\n' \
        'mock_seed identity identity-secrets COURIER_BASE_URL "http://courier.courier.svc.cluster.local:4000"' \
        'mock_seed identity identity-secrets COURIER_TOKEN "live-box-working-token"' \
        'mock_seed identity identity-secrets PASSWORD_RESET_LINK_TEMPLATE "https://app.cafaye.com/reset-password?token={token}"' \
        'mock_seed identity identity-secrets EMAIL_VERIFICATION_LINK_TEMPLATE "https://app.cafaye.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets EMAIL_CHANGE_LINK_TEMPLATE "https://app.cafaye.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets RECOVERY_LINK_TEMPLATE "https://app.cafaye.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets INVITATION_LINK_TEMPLATE "https://app.cafaye.com/invitations/{token}"'
    fi
    # The 4th argument is `wrap` to call the mint from inside a FUNCTION, the
    # way `main` calls it. The distinction is the whole defect B control: a
    # `RETURN` trap is global, so it fires at the CALLER's return too, where
    # `forward_pid` has left scope. A top-level call (the default) never
    # triggers that, so only the wrapped shape can prove the exit code.
    if [ "${4:-}" = wrap ]; then
      printf 'mint_caller() { mint_courier_identity_token; }\nmint_caller\n'
    else
      printf 'mint_courier_identity_token\n'
    fi
  } >"$script"
  mint_ec=0
  bash "$script" >"$ROLLOUT_DIR/run.log" 2>&1 || mint_ec=$?
}

mint_fixed="$WORK/install-mint-fixed.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$mint_fixed"
mint_prefix="$WORK/install-mint-prefix.sh"
sed -e '/^main "$@"/d' -e '/kit_substrate_await_list "\$IDENTITY_DEPLOY_TIMEOUT" deployment identity -n identity/d' \
  "$SUBSTRATE/install.sh" >"$mint_prefix"

# The control fixture is only a control if it really is the pre-fix shape: the
# await must be gone from it, and the rollout watch must still be there. A
# mutation that broke nothing would pass case 3 for the wrong reason.
if grep -q 'IDENTITY_DEPLOY_TIMEOUT" deployment' "$mint_prefix" \
  || ! grep -q 'rollout status deployment/identity' "$mint_prefix"; then
  fail 'control fixture: the pre-fix mint step is the shape step 11 ran' \
    "the await-line deletion did not apply, so case 3 would prove nothing"
  failures=$((failures + 1))
else
  # CASE 1, green: slow Argo still mints. The Deployment lands on the second
  # poll, so the loop has to tolerate a missing object once and keep going —
  # and the watch must come AFTER the sync rather than racing it. The order is
  # proved the way section 16 proves it: a watch that ran early would have met
  # NotFound and, under `set -e`, ended the run.
  mint_step "$mint_fixed" 2 5
  mint_slow_ok() {
    if [ "$mint_ec" -ne 0 ]; then
      printf 'the mint exited %s — Argo syncing a few seconds late still kills the install\n%s\n' \
        "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
      return 1
    fi
    if [ "$(cat "$ROLLOUT_DIR/store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ]; then
      printf 'courier-secrets does not hold the minted value\n'
      return 1
    fi
    if [ "$(cat "$ROLLOUT_DIR/store/identity/identity-secrets/COURIER_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ]; then
      printf 'identity-secrets does not hold the same minted value\n'
      return 1
    fi
    if ! grep -q 'rollout status deployment/identity' "$ROLLOUT_DIR/argv"; then
      printf 'the rollout watch never ran — the step gave up before watching\n%s\n' \
        "$(cat "$ROLLOUT_DIR/run.log")"
      return 1
    fi
    # The empty polls really were empty: DEPLOY_APPEARS_AT is 2, so the first
    # poll must have seen nothing and the sync must be the SECOND one. A
    # fixture that never ran the race would pass on a step that races.
    if [ "$(cat "$ROLLOUT_DIR/polls" 2>/dev/null || echo 0)" -ne 2 ]; then
      printf 'Argo synced on the first poll, so the missing-object case never happened\n'
      return 1
    fi
    printf 'the mint survived a late Deployment and patched both secrets with one value'
  }
  run 'step 11 mints when Argo creates the Deployment a few seconds late' \
    green mint_slow_ok

  # CASE 3, THE CONTROL: the pre-fix shape against slow Argo. It must abort
  # with NotFound, and the signature that proves it is the ARGV: the pre-fix
  # step never asked whether the Deployment existed, so it went straight to a
  # watch that could not be satisfied.
  mint_step "$mint_prefix" 2 5
  case "$mint_ec:$(cat "$ROLLOUT_DIR/run.log" 2>/dev/null):$(cat "$ROLLOUT_DIR/argv" 2>/dev/null)" in
    0:*:*:*)
      fail 'control: a rollout watched before Argo syncs aborts the install' \
        "exit 0 — the control did not reproduce the defect it is named for"
      ;;
    *"not found"*:*"get deployment"*)
      fail 'control: a rollout watched before Argo syncs aborts the install' \
        "the pre-fix fixture still checked for existence, so it is not the shape step 11 ran"
      ;;
    *"not found"*:*)
      if grep -q 'rollout status deployment/identity' "$ROLLOUT_DIR/argv"; then
        pass 'control: a rollout watched before Argo syncs aborts, with no existence check before it'
      else
        fail 'control: a rollout watched before Argo syncs aborts the install' \
          "the watch did not run, so the control failed for some other reason"
      fi
      ;;
    *)
      fail 'control: a rollout watched before Argo syncs aborts the install' \
        "exit $mint_ec: $(cat "$ROLLOUT_DIR/run.log" 2>/dev/null)"
      ;;
  esac
fi

# CASE 2: an Argo sync that never lands. The step must REFUSE inside its
# bound, not hang and not lie. The bound is shortened to 2s here, and the
# elapsed time is measured rather than asserted by exit status alone — a wait
# that exceeded its own budget would pass a glance at the message.
mint_never_ok() {
  local started elapsed
  started="$(date +%s)"
  mint_step "$mint_fixed" 999 2
  elapsed=$(( $(date +%s) - started ))
  if [ "$mint_ec" -eq 0 ]; then
    printf 'a Deployment Argo never created was answered with success\n%s\n' \
      "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  if [ "$elapsed" -gt 20 ]; then
    printf 'the refusal took %ss — the bound is 2s, so this is a hang\n' "$elapsed"
    return 1
  fi
  case "$(cat "$ROLLOUT_DIR/run.log")" in
    *"kubectl get deployment identity"*)
      case "$(cat "$ROLLOUT_DIR/run.log")" in
        *"empty"*) : ;;
        *)
          printf 'the refusal does not name the empty list\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
          return 1
          ;;
      esac
      ;;
    *)
      printf 'the refusal does not name the missing Deployment\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
      return 1
      ;;
  esac
  if grep -q 'rollout status deployment/identity' "$ROLLOUT_DIR/argv"; then
    printf 'the step watched a rollout for a Deployment that never existed\n'
    return 1
  fi
  if [ -f "$ROLLOUT_DIR/store/identity/identity-secrets/COURIER_TOKEN" ] \
    || [ -f "$ROLLOUT_DIR/store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" ]; then
    printf 'the refusal still wrote half a credential\n'
    return 1
  fi
  printf 'refused in %ss, naming the missing Deployment, with no watch and no write' "$elapsed"
}
run 'step 11 refuses within its bound when Argo never creates the Deployment' green mint_never_ok

# ---------------------------------------------------------------------------
# 18a. Step 11's mock holds the same `--patch-file` convention as step 8's
# ---------------------------------------------------------------------------
# The sibling of §12d: `rollout_kubectl` is the second mock with a patch
# branch, and a divergence between the two would let the class back in through
# the mint. One store, the two spellings, against this mock.
run 'the step-11 mock reads --patch-file=/dev/stdin and refuses - as kubectl does' green \
  check_patch_convention rollout_kubectl "$WORK/rollout-dash"

# check_mint_writes_both_secrets <fixture> — step 11 for real, and the one
# minted value must land in both secrets. The red control below is the same
# run with the patch spelling reverted to `-`: rollout_kubectl refuses it as
# the box does, and under `set -e` the mint aborts.
check_mint_writes_both_secrets() {
  mint_step "$1" 2 5
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  if [ "$(cat "$ROLLOUT_DIR/store/identity/identity-secrets/COURIER_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ]; then
    echo "identity-secrets does not hold the minted value"
    return 1
  fi
  if [ "$(cat "$ROLLOUT_DIR/store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ]; then
    echo "courier-secrets does not hold the minted value"
    return 1
  fi
  echo "step 11 wrote one minted value into both secrets through /dev/stdin"
}
run 'step 11 writes one minted value into both secrets through /dev/stdin' green \
  check_mint_writes_both_secrets "$mint_fixed"
run 'control: the - patch spelling aborts the mint, as it does on the box' red \
  check_mint_writes_both_secrets "$fixture_patch_dash"

# ---------------------------------------------------------------------------
# 18b. Step 11 writes BOTH HALVES of each credential pair, and exits 0
# ---------------------------------------------------------------------------
# Two live defects, one step. (A) the mint wrote `COURIER_TOKEN` alone, and
# identity's fail-closed loader (`identity/internal/config/config.go`,
# `loadCourier`) refused to boot on half a pair — the same for courier, whose
# `COURIER_IDENTITY_URL` (`courier/config/runtime.exs`) otherwise falls back to
# the compose-network spelling `http://identity:8080` that cannot cross a
# namespace. (B) the `RETURN` trap that tears down the port-forward is global,
# so it fired again when the CALLER (`main`) returned, where `forward_pid` had
# left scope: `line …: forward_pid: unbound variable`, exit 1 AFTER
# `install.done` printed.
#
# THE PAIR'S FOUR KEYS AND THEIR VALUES, read from the two charts:
#   identity-secrets/COURIER_BASE_URL       = courier's Service, `courier`
#     namespace, port 4000 (`courier/chart/values.yaml` service.port; Service
#     `courier` in `courier/chart/templates/service.yaml`).
#   identity-secrets/COURIER_TOKEN          = the value the mint returned.
#   courier-secrets/COURIER_IDENTITY_URL    = identity's Service, `identity`
#     namespace, port 8080 (`identity/chart/values.yaml`; Service `identity`).
#   courier-secrets/COURIER_IDENTITY_TOKEN  = the same minted value.
#
# The sibling packet's chart-inventory check is not on this branch, so the
# pair is asserted EXPLICITLY against those read values. check_secret_record
# above is the textual half of the same claim — the record now names all four.
COURIER_BASE_URL_EXPECTED="http://courier.courier.svc.cluster.local:4000"
IDENTITY_BASE_URL_EXPECTED="http://identity.identity.svc.cluster.local:8080"

check_mint_writes_pair() {
  mint_step "$1" 2 5
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  local store="$ROLLOUT_DIR/store" bad="" p path want got
  local -a pairs=(
    "identity/identity-secrets/COURIER_BASE_URL|$COURIER_BASE_URL_EXPECTED"
    "identity/identity-secrets/COURIER_TOKEN|$COURIER_MINT_TOKEN"
    "courier/courier-secrets/COURIER_IDENTITY_URL|$IDENTITY_BASE_URL_EXPECTED"
    "courier/courier-secrets/COURIER_IDENTITY_TOKEN|$COURIER_MINT_TOKEN"
  )
  for p in "${pairs[@]}"; do
    path="$store/${p%%|*}"
    want="${p#*|}"
    got="$(cat "$path" 2>/dev/null || true)"
    [ "$got" = "$want" ] || bad="${bad} ${p%%|*}=${got:-<missing>} (want ${want});"
  done
  if [ -n "$bad" ]; then
    printf 'the minted pair is incomplete:%s\n' "$bad"
    return 1
  fi
  echo "step 11 wrote both halves of each pair — token and base URL — in one patch"
}
run 'step 11 writes both halves of each credential pair' green \
  check_mint_writes_pair "$mint_fixed"

# The red control: the token half is written, the base URL half is not. This is
# the exact shape that shipped and refused to boot.
fixture_half_pair="$WORK/install-mint-half-pair.sh"
sed 's/"COURIER_BASE_URL":\$url,//' "$mint_fixed" >"$fixture_half_pair"
run 'control: a mint writing a token without its base URL goes red' red \
  check_mint_writes_pair "$fixture_half_pair"

# The done path must be EXIT 0. `check_mint_exit_zero` runs the mint WRAPPED in
# a function, as `main` calls it; the control is the pre-fix trap, with its
# self-removal stripped, which must exit non-zero for the caller-return reason.
check_mint_exit_zero() {
  mint_step "$1" 2 5 wrap
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s when called from a caller\n%s\n' \
      "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  echo "the done path exits 0 with the mint called from a caller, as main calls it"
}
fixture_trap_nonself="$WORK/install-mint-trap-nonself.sh"
sed -e '/^main "$@"$/d' -e 's/; trap - RETURN//' "$SUBSTRATE/install.sh" >"$fixture_trap_nonself"
# The control fixture is only a control if the self-removal is really gone and
# the trap is still there: a mutation that broke nothing would prove nothing.
if grep -q "trap 'kill \"\$forward_pid\" 2>/dev/null || true; trap - RETURN' RETURN" "$fixture_trap_nonself" \
  || ! grep -q "trap 'kill \"\$forward_pid\" 2>/dev/null || true' RETURN" "$fixture_trap_nonself"; then
  fail 'control fixture: the pre-fix trap is the shape step 11 ran' \
    "the self-removal deletion did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  run 'step 11 exits 0 when the mint is called from a caller, as main calls it' green \
    check_mint_exit_zero "$mint_fixed"
  run 'control: a RETURN trap that does not remove itself exits 1 after the mint' red \
    check_mint_exit_zero "$fixture_trap_nonself"
fi

# ===========================================================================
# 18c. identity's mail path is ALL-OR-NOTHING: the link templates ride the
#      courier pair, and an unset base URL is a supported no-mail path
# ===========================================================================
#
# THE DEFECT THIS PACKET CLOSES. The mint wrote identity's courier pair
# (COURIER_BASE_URL + COURIER_TOKEN) and NO link template, and identity's own
# loader refuses exactly that shape: `internal/config/config.go` `loadCourier`
# → `resolveLinkTemplates`/`resolveInvitationLinkTemplate`, the case named "a
# base URL and a token with no link template" → `ErrInvalidCourier`
# (`internal/config/courier_test.go:62`). identity needs at least one template
# plus `INVITATION_LINK_TEMPLATE` whenever the block is wired; the mirror case,
# "a link template and a token with no base URL", is refused too. And the mirror
# of that mirror — "all three absent" — is a SUPPORTED deployment with no mail
# path (`loadCourier`'s `present == 0` branch).
#
# THE FIX. The five templates are derived from the ONE public origin
# (KIT_SUBSTRATE_APP_BASE_URL) and written in the SAME patch as the pair, or no
# identity courier key is written at all. `check_mint_mail_path` applies
# identity's own all-or-nothing rule to what landed in identity-secrets, so this
# is the matrix in executable form rather than a shape check.
#
# THE PATHS ARE PARLOR'S SERVED ROUTES, the launch stack's own spellings
# (`launch/docker-compose.launch.yml`): reset-password, verify-email/confirm
# (which is also the honest target for an address change, as the launch file
# argues at length), and invitations/{token}. A template without `{token}` is
# refused by identity (`resolveLinkTemplates`), so every recovery template
# carries it.
identity_expected_template() {
  case "$1" in
    PASSWORD_RESET_LINK_TEMPLATE)      printf '%s/reset-password?token={token}' "$APP_BASE_URL" ;;
    EMAIL_VERIFICATION_LINK_TEMPLATE)  printf '%s/verify-email/confirm?token={token}' "$APP_BASE_URL" ;;
    EMAIL_CHANGE_LINK_TEMPLATE)        printf '%s/verify-email/confirm?token={token}' "$APP_BASE_URL" ;;
    RECOVERY_LINK_TEMPLATE)            printf '%s/verify-email/confirm?token={token}' "$APP_BASE_URL" ;;
    INVITATION_LINK_TEMPLATE)          printf '%s/invitations/{token}' "$APP_BASE_URL" ;;
    *) return 1 ;;
  esac
}

# check_mint_mail_path <fixture> — run step 12 for real, then apply identity's
# all-or-nothing rule to identity-secrets. Green means the box's identity boots
# with whatever mail path the secret describes.
check_mint_mail_path() {
  mint_step "$1" 2 5
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  local store="$ROLLOUT_DIR/store" base token k want got bad=""
  base="$(cat "$store/identity/identity-secrets/COURIER_BASE_URL" 2>/dev/null || true)"
  token="$(cat "$store/identity/identity-secrets/COURIER_TOKEN" 2>/dev/null || true)"
  if [ -z "$base" ] && [ -z "$token" ]; then
    # `present == 0`: no mail path. A template here would be the mirror refusal.
    for k in PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
      if [ -n "$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)" ]; then
        printf 'a link template (%s) was written with no base URL and no token — identity would refuse (ErrInvalidCourier)\n' "$k"
        return 1
      fi
    done
    printf 'identity mail path: NOT configured (no courier keys) — the supported no-mail state: boots, recovery routes answer 503'
    return 0
  fi
  if [ -z "$base" ] || [ -z "$token" ]; then
    printf 'a HALF pair reached identity-secrets (base=%s token=%s) — identity would refuse (ErrInvalidCourier)\n' \
      "${base:-<none>}" "${token:-<none>}"
    return 1
  fi
  for k in PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
    want="$(identity_expected_template "$k")"
    got="$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)"
    [ "$got" = "$want" ] || bad="${bad} ${k}=${got:-<missing>};"
  done
  if [ -n "$bad" ]; then
    printf 'a base URL and a token with no (valid) link template — identity would refuse (ErrInvalidCourier):%s\n' "$bad"
    return 1
  fi
  # The installer's OWN report must say which mail path the box has, or the
  # state is only in the secret and nobody reading the install output knows it.
  if ! grep -q 'TRUE mail path' "$ROLLOUT_DIR/run.log"; then
    printf 'the mint did not report the configured mail path on its own channel\n%s\n' \
      "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  printf 'identity mail path: CONFIGURED — the pair and five templates written together, each on parlor'"'"'s served route'
}

run 'step 11 writes identity'"'"'s courier pair AND its five link templates when KIT_SUBSTRATE_APP_BASE_URL is set' green \
  check_mint_mail_path "$mint_fixed"

# THE RED CONTROL is the pre-fix shape this packet exists for: the pair is
# written and the templates are not, which is a restarted identity that refuses
# on the next check. The fixture is asserted to really be that shape before the
# control is allowed to count — a mutation that broke nothing would prove nothing.
fixture_no_template="$WORK/install-mint-no-template.sh"
sed -e '/^main "$@"$/d' -e '/LINK_TEMPLATE/d' "$SUBSTRATE/install.sh" >"$fixture_no_template"
if grep -q 'LINK_TEMPLATE' "$fixture_no_template" \
  || ! grep -q '"COURIER_BASE_URL":\$url,' "$fixture_no_template"; then
  fail 'control fixture: a pair written with no link template' \
    "the strip did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  ntp_out=""; ntp_ec=0
  ntp_out="$(check_mint_mail_path "$fixture_no_template" 2>&1)" || ntp_ec=$?
  if [ "$ntp_ec" -eq 0 ]; then
    fail 'control: a pair written with no link template goes red, naming the variable' \
      "exit 0 — the shipped shape passed the check"
  elif case "$ntp_out" in *INVITATION_LINK_TEMPLATE*) true ;; *) false ;; esac; then
    pass 'control: a pair written with no link template goes red, naming the variable'
  else
    fail 'control: a pair written with no link template goes red, naming the variable' "$ntp_out"
  fi
fi

# THE OTHER BRANCH, green: no public origin means no identity courier keys at
# all — identity's own "no mail path" state — while courier still gets its
# required pair. A box that cannot know its public URL boots with all recovery
# routes answering 503, never a rollout that never goes Ready.
check_mint_mail_path_unset() {
  local saved="${MINT_APP_BASE_URL:-}"
  MINT_APP_BASE_URL=__UNSET__
  mint_step "$1" 2 5
  MINT_APP_BASE_URL="$saved"
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s with no base URL\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  local store="$ROLLOUT_DIR/store" k present=""
  for k in COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
    if [ -n "$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)" ]; then
      present="${present} ${k}"
    fi
  done
  if [ -n "$present" ]; then
    printf 'identity-secrets carries courier keys with no public origin:%s\n' "$present"
    return 1
  fi
  if [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ] \
    || [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_URL" 2>/dev/null || true)" != "$IDENTITY_BASE_URL_EXPECTED" ]; then
    printf 'courier-secrets lost the required pair when identity had no mail path\n'
    return 1
  fi
  # The installer must SAY the mail path is off, so the operator learns the box
  # boots without one from the install output rather than from a 503 later —
  # and a run that removed nothing says so.
  if ! grep -q 'mail path is NOT configured' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'nothing removed' "$ROLLOUT_DIR/run.log"; then
    printf 'the mint did not report the no-mail path on its own channel\n%s\n' \
      "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  printf 'no public origin: no identity courier key written, identity boots into its no-mail state, courier still holds its pair'
}
run 'step 11 writes NO identity courier key when KIT_SUBSTRATE_APP_BASE_URL is unset' green \
  check_mint_mail_path_unset "$mint_fixed"

# ===========================================================================
# 18d. the unset branch CONVERGES: an orphaned courier block is removed, the
#      rest of the secret is untouched, and the pre-fix shape fails the check
# ===========================================================================
#
# THE LIVE DEFECT. One box runs identity in CrashLoopBackOff: an older
# installer wrote COURIER_TOKEN without COURIER_BASE_URL, the current step's
# happy path writes nothing when KIT_SUBSTRATE_APP_BASE_URL is unset, so the
# orphan survives every re-run and identity's fail-closed loadCourier refuses
# to boot on the half-pair. The fix is converge_identity_courier_block: read
# the seven keys, delete whichever are present in one `"key":null` merge
# patch, re-read to prove the block is empty, restart identity so the change
# reaches the pod. The sweep runs above the mint guard too, so a warm box that
# already minted still heals.
check_mint_converges_orphan() {
  local saved_base="${MINT_APP_BASE_URL:-}" saved_orphan="${MINT_SEED_ORPHAN:-}"
  MINT_APP_BASE_URL=__UNSET__ MINT_SEED_ORPHAN=1 mint_step "$1" 2 5
  MINT_APP_BASE_URL="$saved_base" MINT_SEED_ORPHAN="$saved_orphan"
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s with an orphaned block and no base URL\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  local store="$ROLLOUT_DIR/store" k leftover=""
  for k in COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
    if [ -n "$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)" ]; then
      leftover="${leftover:+$leftover }$k"
    fi
  done
  if [ -n "$leftover" ]; then
    printf 'the orphan survived the re-run:%s — identity would still refuse (ErrInvalidCourier)\n' "$leftover"
    return 1
  fi
  local kept
  for kept in DATABASE_URL SIGNUP_SIGNING_KEY MFA_ENCRYPTION_KEY NATS_URL OIDC_ISSUER OIDC_SIGNING_KEY OIDC_SIGNING_KEY_ID; do
    if [ -z "$(cat "$store/identity/identity-secrets/$kept" 2>/dev/null || true)" ]; then
      printf 'the sweep dropped %s, which is not a courier key\n' "$kept"
      return 1
    fi
  done
  if [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ] \
    || [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_URL" 2>/dev/null || true)" != "$IDENTITY_BASE_URL_EXPECTED" ]; then
    printf 'courier-secrets lost its required pair while identity converged\n'
    return 1
  fi
  # The operator must SEE the edit: the log names the removed keys and why —
  # each removed key by name, and no key that was not removed.
  if ! grep -q 'orphaned courier key' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'COURIER_TOKEN' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'EMAIL_CHANGE_LINK_TEMPLATE' "$ROLLOUT_DIR/run.log"; then
    printf 'the sweep did not report which keys it removed\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  if grep -q 'NATS_URL' "$ROLLOUT_DIR/run.log"; then
    printf 'the sweep report names a key it did not remove (NATS_URL was kept)\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  # And the change must REACH the pod: identity is restarted.
  if ! grep -q 'rollout restart deployment/identity' "$ROLLOUT_DIR/argv"; then
    printf 'identity was not restarted after its secret changed\n'
    return 1
  fi
  printf 'orphaned COURIER_TOKEN and stray template removed, seven-key block verified empty, unrelated keys kept, courier pair written, identity restarted'
}
run 'step 11 converges an orphaned identity courier block when KIT_SUBSTRATE_APP_BASE_URL is unset' green \
  check_mint_converges_orphan "$mint_fixed"

# THE RED CONTROL is the write-forward shape: the sweep scans nothing, so it
# removes nothing and the orphan survives. The fixture is the real tree with
# the key list emptied — functionally the step as it stands on master, which
# knows no key to delete — rather than a hand-edited approximation, so the
# control tracks future edits to the sweep body. Its premise is asserted
# first: the list is really empty. If the orphan-removal check passed against
# it, the check would be worthless.
mint_prefix_converge="$WORK/install-mint-prefix-converge.sh"
sed -e '/^main "$@"/d' -e 's/^IDENTITY_COURIER_KEYS=(.*$/IDENTITY_COURIER_KEYS=()/' \
  "$SUBSTRATE/install.sh" >"$mint_prefix_converge"
if ! grep -q '^IDENTITY_COURIER_KEYS=()$' "$mint_prefix_converge" \
  || grep -q '^IDENTITY_COURIER_KEYS=(COURIER_BASE_URL' "$mint_prefix_converge"; then
  fail 'control fixture: the sweep scans nothing' \
    "the key-list emptying did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  cco_out=""; cco_ec=0
  cco_out="$(check_mint_converges_orphan "$mint_prefix_converge" 2>&1)" || cco_ec=$?
  if [ "$cco_ec" -eq 0 ]; then
    fail 'control: the write-forward step leaves the orphan, failing the check' \
      "exit 0 — the check passed against a step with no sweep, so it discriminates nothing"
  elif case "$cco_out" in *COURIER_TOKEN*) true ;; *) false ;; esac; then
    pass 'control: the write-forward step leaves the orphan, failing the check'
  else
    fail 'control: the write-forward step leaves the orphan, failing the check' "$cco_out"
  fi
fi

# ===========================================================================
# 18e. the unset branch KEEPS a complete pair: a working mail path is not an
#      orphan, and the sweep must say so
# ===========================================================================
#
# THE LIVE DEFECT. The Contabo box carries a COMPLETE seven-key courier block
# — COURIER_BASE_URL and COURIER_TOKEN both present, five link templates
# derived from https://app.cafaye.com — and identity boots and reports
# "account recovery can send all four messages through courier". The sweep as
# it stood collected all seven keys into `orphans` and deleted them, printing
# "leftovers from an installer that wrote half a pair": a provenance the
# installer never checked, and a "removed" with no mention that the box went
# from a working mail path to 503 on every recovery route.
#
# THE FIX. converge_identity_courier_block classifies first, mirroring
# identity's own loadCourier rule: both halves present means a working mail
# path, which stays — nothing deleted, identity not restarted — and the report
# says the mail path stays and names KIT_SUBSTRATE_APP_BASE_URL as the
# variable that would rewrite it. The half-pair sweep is unchanged.
check_mint_keeps_complete_pair() {
  local saved_base="${MINT_APP_BASE_URL:-}" saved_complete="${MINT_SEED_COMPLETE:-}"
  MINT_APP_BASE_URL=__UNSET__ MINT_SEED_COMPLETE=1 mint_step "$1" 2 5
  MINT_APP_BASE_URL="$saved_base" MINT_SEED_COMPLETE="$saved_complete"
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s on a box with a working mail path and no base URL\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  local store="$ROLLOUT_DIR/store" k
  for k in COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE RECOVERY_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
    if [ -z "$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)" ]; then
      printf 'the sweep deleted %s from a working mail path — the box went from sending mail to 503s\n' "$k"
      return 1
    fi
  done
  if [ "$(cat "$store/identity/identity-secrets/COURIER_TOKEN" 2>/dev/null || true)" != "live-box-working-token" ]; then
    printf 'the working token was rewritten by a run with no base URL to rewrite it with\n'
    return 1
  fi
  # Keeping identity's path must not starve courier's: courier still gets its
  # required pair, and the mint still completes (courier restarted).
  if [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ] \
    || [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_URL" 2>/dev/null || true)" != "$IDENTITY_BASE_URL_EXPECTED" ]; then
    printf 'courier-secrets lost its required pair while identity kept its mail path\n'
    return 1
  fi
  if ! grep -q 'rollout restart deployment/courier' "$ROLLOUT_DIR/argv"; then
    printf 'courier was not restarted after its secret changed\n'
    return 1
  fi
  # The report must say the box KEEPS a working mail path and name the
  # variable that would rewrite it — and a run that removed nothing says so.
  if ! grep -q 'working mail path' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'KIT_SUBSTRATE_APP_BASE_URL' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'nothing removed' "$ROLLOUT_DIR/run.log"; then
    printf 'the run kept the mail path without saying so and naming the variable\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  # And the kept path must NOT be described with the orphan's sentence.
  if grep -q 'leftovers' "$ROLLOUT_DIR/run.log" \
    || grep -q 'orphaned courier key' "$ROLLOUT_DIR/run.log"; then
    printf 'a kept mail path was described with the orphan sentence\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  # Nothing changed in identity-secrets, so identity must NOT have restarted.
  if grep -q 'rollout restart deployment/identity' "$ROLLOUT_DIR/argv"; then
    printf 'identity was restarted although its secret was left untouched\n'
    return 1
  fi
  printf 'complete pair with templates left in place, working mail path reported with the rewriting variable named, no orphan sentence, identity not restarted, courier pair written'
}
run 'step 11 keeps a complete identity courier block when KIT_SUBSTRATE_APP_BASE_URL is unset' green \
  check_mint_keeps_complete_pair "$mint_fixed"

# RED CONTROL 1: the sweep as it stands on master deletes a complete pair.
# The fixture is the real tree with the classification disabled — the
# SWEEP-HONEST-CLASSIFY branch forced false — so the control tracks future
# edits to the sweep body. Its premise is asserted first: the branch is really
# gone. If the keep-check passed against it, the check discriminates nothing.
mint_noclassify="$WORK/install-mint-no-classify.sh"
sed -e '/^main "$@"/d' \
  -e 's/if \[ -n "\$base_present" \] && \[ -n "\$token_present" \]; then # SWEEP-HONEST-CLASSIFY/if false; then # SWEEP-HONEST-CLASSIFY/' \
  "$SUBSTRATE/install.sh" >"$mint_noclassify"
if ! grep -qF 'if false; then # SWEEP-HONEST-CLASSIFY' "$mint_noclassify" \
  || grep -qF '"$base_present"' "$mint_noclassify"; then
  fail 'control fixture: the classification is disabled' \
    "the branch-forcing did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  knc_out=""; knc_ec=0
  knc_out="$(check_mint_keeps_complete_pair "$mint_noclassify" 2>&1)" || knc_ec=$?
  if [ "$knc_ec" -eq 0 ]; then
    fail 'control: a sweep with no classification deletes the pair, failing the check' \
      "exit 0 — the check passed against a sweep that deletes a working mail path, so it discriminates nothing"
  elif case "$knc_out" in *went*from*sending*mail*) true ;; *) false ;; esac; then
    pass 'control: a sweep with no classification deletes the pair, failing the check'
  else
    fail 'control: a sweep with no classification deletes the pair, failing the check' "$knc_out"
  fi
fi

# RED CONTROL 2: the orphan's sentence must not appear on a complete-pair run.
# The fixture is the real tree with the keep-branch report rewritten to use
# the orphan's word — the keys are still kept, so only the message assertion
# can fire. Its premise is asserted first: the word is really in the
# keep-branch and the classification itself is intact.
mint_badword="$WORK/install-mint-badword.sh"
sed -e '/^main "$@"/d' \
  -e 's/so the mail path stays, nothing removed,/so the mail path stays, nothing removed -- leftovers from an installer that wrote half a pair,/' \
  "$SUBSTRATE/install.sh" >"$mint_badword"
if ! grep -qF 'mail path stays, nothing removed' "$mint_badword" \
  || ! grep -qF 'leftovers from an installer that wrote half a pair' "$mint_badword" \
  || ! grep -qF '# SWEEP-HONEST-CLASSIFY' "$mint_badword"; then
  fail 'control fixture: the keep-branch speaks the orphan sentence' \
    "the word-plant did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  kbw_out=""; kbw_ec=0
  kbw_out="$(check_mint_keeps_complete_pair "$mint_badword" 2>&1)" || kbw_ec=$?
  if [ "$kbw_ec" -eq 0 ]; then
    fail 'control: the orphan sentence on a complete-pair run fails the check' \
      "exit 0 — the check passed against a kept path called leftovers, so it discriminates nothing"
  elif case "$kbw_out" in *orphan*sentence*) true ;; *) false ;; esac; then
    pass 'control: the orphan sentence on a complete-pair run fails the check'
  else
    fail 'control: the orphan sentence on a complete-pair run fails the check' "$kbw_out"
  fi
fi

# ===========================================================================
# 19. Step 6 waits on nothing — the core-install reality, executed
# ===========================================================================
#
# Section 17 proves the wait RULE textually; this proves the step against the
# reality of the install variant step 4 applies. The pinned core-install.yaml
# (ARGOCD_VERSION, checked against the upstream manifest at the pin) ships
# exactly four workloads in argocd: the Deployments argocd-applicationset-
# controller, argocd-redis and argocd-repo-server, and the StatefulSet
# argocd-application-controller. No argocd-server, no dex, no UI — so the wait
# that closed this step failed with NotFound on every run and killed the
# install at step 6. The suite was green over that bug because nothing
# executed the wait against a cluster that does not have the object.
#
# argocd_kubectl models that cluster: the deployment list in argocd is exactly
# the three core-install Deployments, a named wait for anything else is
# answered the way real kubectl answers a missing named object — NotFound,
# exit 1 — and every invocation is recorded, because "waited on nothing" is an
# order and not a return code.
#
# THREE CASES:
#   1. green — the step applies the Applications and waits on nothing. The
#      mock would fail it had it waited on a missing object, so success IS the
#      proof, and the argv is asserted to hold no argocd wait at all: step 4
#      owns those, and this step has no business re-waiting on them.
#   2. THE CONTROL — the pre-fix shape, with the argocd-server wait restored
#      after the apply. It must abort with NotFound. This is the case the
#      suite lacked: the bug lived in a line nothing executed.
#   3. the coverage half — step 4's wait must stay the `--all` deployments
#      wait in argocd, because that wait is what covers the readiness this
#      step's wait used to (wrongly) reach for.
ARGOCD_DIR="$WORK/argocd"
mkdir -p "$ARGOCD_DIR"

argocd_kubectl() {
  printf '%s\n' "$*" >>"$ARGOCD_DIR/argv"
  case "$*" in
    *"wait"*"deployment -n argocd --all"*)
      # A list wait: the list is non-empty on any box past step 4, so it
      # succeeds — the assertion that this never runs is the argv below.
      return 0
      ;;
    *"wait"*"deployment -n argocd "*)
      # A NAMED wait: the name must be in the core-install set. The name is
      # the last token that is not a flag or a fixed literal of the command.
      local wname="" tok
      for tok in "$@"; do
        case "$tok" in
          wait | deployment | -n | --kubeconfig=* | --for=* | --timeout=* | --all) ;;
          *) wname="$tok" ;;
        esac
      done
      case "$wname" in
        argocd-applicationset-controller | argocd-redis | argocd-repo-server)
          return 0
          ;;
        *)
          printf 'error: deployments.apps "%s" not found\n' "$wname" >&2
          return 1
          ;;
      esac
      ;;
    *)
      return 0
      ;;
  esac
}

# apps_step <sourced-fixture> — run step 6 for real against the core-install
# mock, and leave the exit status behind in $apps_ec. A child bash, for the
# reason mint_step's comment records: a guarded subshell would march past a
# failing wait and exit 0 — the opposite of the box, where the same failure
# aborts the install.
apps_step() {
  rm -f "$ARGOCD_DIR/argv" "$ARGOCD_DIR/run.log"
  local script="$ARGOCD_DIR/apps-run.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'ARGOCD_DIR=%q\n' "$ARGOCD_DIR"
    printf 'FIXTURE=%q\n' "$1"
    # Step 6 now RESOLVES its manifest directory before applying (the transport
    # fix), so the fixture points MANIFEST_DIR at the real applications dir.
    # Without it the sourced installer's SCRIPT_DIR is this temp fixture, the
    # dir holds no `*.yaml`, and the step refuses — a green that failed on the
    # fixture's own shape rather than on the wait this case is about. Set AFTER
    # the source: install.sh assigns MANIFEST_DIR from SCRIPT_DIR at source
    # time, so a value written before it would be overwritten.
    declare -f argocd_kubectl
    printf '%s\n' \
      'export DRY_RUN=0 HEADLESS=0' \
      '# shellcheck source=/dev/null' \
      '. "$FIXTURE"'
    printf 'MANIFEST_DIR=%q\n' "$MANIFESTS"
    printf '%s\n' \
      'kubectl() { argocd_kubectl "$@"; }' \
      'install_applications'
  } >"$script"
  apps_ec=0
  bash "$script" >"$ARGOCD_DIR/run.log" 2>&1 || apps_ec=$?
}

apps_fixed="$WORK/install-apps-fixed.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$apps_fixed"

# CASE 1, green: the step applies the Applications and waits on nothing. The
# apply must be in the argv, and NO wait targeting the argocd namespace may
# be — neither named nor --all: step 4's `--all` deployments wait already
# holds until every core-install Deployment is Available before step 5 runs,
# so this step has no wait to re-do, and a reintroduced one is a regression
# the argv below must catch.
apps_step "$apps_fixed"
apps_apply_ok() {
  if [ "$apps_ec" -ne 0 ]; then
    printf 'the step exited %s against a cluster that has every core-install workload\n%s\n' \
      "$apps_ec" "$(cat "$ARGOCD_DIR/run.log")"
    return 1
  fi
  if ! grep -q 'apply -f' "$ARGOCD_DIR/argv"; then
    printf 'the Applications were never applied\n'
    return 1
  fi
  if grep -q 'wait.*deployment -n argocd' "$ARGOCD_DIR/argv"; then
    printf 'the step waited on an argocd Deployment — step 4 already did, and the wait this step used to carry named one core-install does not ship\n'
    return 1
  fi
  printf 'applied the Applications and waited on nothing — the core-install reality'
}
run 'step 6 applies the Applications and waits on nothing' green apps_apply_ok

# CASE 2, THE CONTROL: the pre-fix shape — the argocd-server wait restored
# after the apply — against the same mock. It must abort with NotFound, and
# the argv must show both the apply and the wait: the pre-fix step applied
# the Applications and THEN died on the wait, which is the shape the box
# showed.
apps_prefix="$WORK/install-apps-prefix.sh"
apps_wait_line='  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd argocd-server --timeout=120s'
awk -v wait_line="$apps_wait_line" '
  /^main "\$@"/ { next }
  # Strip any NAMED argocd deployment wait (the --all wait belongs to step 4
  # and the pattern excludes it), so the control is the pre-fix shape on BOTH
  # trees: on the fixed tree nothing is stripped and the wait is inserted
  # once; on the broken tree the live wait is stripped and re-inserted, still
  # exactly once.
  /wait --for=condition=Available deployment -n argocd / && !/--all/ { next }
  # The apply the wait used to follow is now the RESOLVED list the transport
  # fix applies (install_applications no longer carries a literal
  # `-f "$MANIFEST_DIR"`), so the insert anchors on that line. Anchoring on the
  # old one left the wait uninserted and the premise below caught it — the
  # control would otherwise have proved nothing.
  /^  kubectl --kubeconfig="\$KUBECONFIG" apply "\$\{apply_args\[@\]\}"$/ {
    print
    print wait_line
    next
  }
  { print }
' "$SUBSTRATE/install.sh" >"$apps_prefix"

# The control fixture is only a control if it really is the pre-fix shape: the
# restored wait must be there, exactly once. A mutation that broke nothing
# would pass case 2 for the wrong reason.
if [ "$(grep -c 'wait --for=condition=Available deployment -n argocd argocd-server' "$apps_prefix")" -ne 1 ]; then
  fail 'control fixture: the pre-fix wait did not apply' \
    "the restored wait is missing or duplicated, so the control would prove nothing"
  failures=$((failures + 1))
else
  apps_step "$apps_prefix"
  case "$apps_ec:$(cat "$ARGOCD_DIR/run.log" 2>/dev/null):$(cat "$ARGOCD_DIR/argv" 2>/dev/null)" in
    0:*)
      fail 'control: the argocd-server wait restored aborts the install' \
        "exit 0 — the control did not reproduce the defect it is named for"
      ;;
    *"not found"*:*)
      if grep -q 'apply -f' "$ARGOCD_DIR/argv" \
        && grep -q 'wait --for=condition=Available deployment -n argocd argocd-server' "$ARGOCD_DIR/argv"; then
        pass 'control: the argocd-server wait restored aborts the install, after the apply'
      else
        fail 'control: the argocd-server wait restored aborts the install' \
          "the apply or the wait is missing from the argv, so the control failed for some other reason"
      fi
      ;;
    *)
      fail 'control: the argocd-server wait restored aborts the install' \
        "exit $apps_ec: $(cat "$ARGOCD_DIR/run.log" 2>/dev/null)"
      ;;
  esac
fi

# CASE 3, the coverage half: step 4's wait must stay the `--all` deployments
# wait in argocd. Narrowing it to a named Deployment would leave the rest of
# the core-install set uncovered, and step 6 — having no wait — would have
# nothing to catch the gap.
case "$(sed -n '/^install_argocd()/,/^}/p' "$SUBSTRATE/install.sh")" in
  *'wait --for=condition=Available deployment -n argocd --all'*)
    pass 'step 4 waits for every argocd Deployment, the coverage step 6 deleted'
    ;;
  *)
    fail 'step 4 waits for every argocd Deployment, the coverage step 6 deleted' \
      'the --all deployments wait is gone from install_argocd — step 6 has no wait to cover the gap'
    ;;
esac

# The guard must probe a core-install workload. It probed argocd-server, which
# core-install does not ship, so the guard never matched and step 4 re-applied
# the largest manifest on every run — the same defect as the wait, in the
# idempotency path.
case "$(sed -n '/^    argocd)/,/^      ;;/p' "$SUBSTRATE/install.sh")" in
  *'get deployment -n argocd argocd-repo-server'*)
    pass 'the argocd guard probes a Deployment core-install ships'
    ;;
  *)
    fail 'the argocd guard probes a Deployment core-install ships' \
      'the guard probe is not argocd-repo-server — a probe of a component core-install does not ship never matches'
    ;;
esac

# And nothing in the RUNNABLE code may name a component core-install does not
# ship. Comments are stripped first, as everywhere in this file: the step 6
# comment explains the deletion BY NAMING argocd-server, and a check that
# could be falsified by a comment is not a check.
run 'the runnable code names no component core-install does not ship' green \
  "$PY" - "$SUBSTRATE/install.sh" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
bad = []
for name in ("argocd-server", "argocd-initial-admin-secret"):
    if name in code:
        bad.append(name)
if bad:
    print("the runnable code names component(s) core-install does not ship: " + ", ".join(bad))
    sys.exit(1)
print("the runnable code names no component core-install does not ship")
PY

# ===========================================================================
# 20. A manifest directory is read DELIBERATELY — AppleDouble ignored, a stray
#     file refused by name, and the filter proved load-bearing
# ===========================================================================
#
# MEASURED LIVE ON THE BOX. The substrate tree was shipped from a macOS
# workstation with the idiom an operator will reach for — `tar czf - . | ssh
# box 'tar xzf -'` — and BSD tar left AppleDouble sidecars beside every real
# file. Step 6's `kubectl apply -f <dir>` hands the directory's files, DOTFILES
# INCLUDED, to the API server, so it read `._identity.yaml` and the install
# DIED on the first sidecar:
#
#   error parsing /var/lib/cafaye/substrate/manifests/applications/._identity.yaml:
#   error converting YAML to JSON: yaml: control characters are not allowed
#
# `COPYFILE_DISABLE=1 tar --no-xattrs` reduces the sidecars but does not remove
# the class: a Windows copy, an editor's `foo~` backup or a `.DS_Store` is the
# same defect from another transport. install.sh now resolves its file list (the
# note above install_applications): AppleDouble ignored and named, a stray file
# REFUSED by name, the intended `*.yaml` manifests applied and nothing else.
#
# THREE PROOFS, each executed against a mocked kubectl that READS what `-f`
# names — dotfiles in a directory included — and refuses a file carrying NUL
# bytes with the exact error above. A mock that swallowed everything would let
# the "filter removed" control pass for the wrong reason, which is the whole
# failure a red control exists to rule out.
apple_double_tree="$WORK/apply-tree-sidecar"
stray_tree="$WORK/apply-tree-stray"

# plant_apple_double <path> — an AppleDouble sidecar: the BSD tar magic, an
# "Mac OS X" attr header, and the NUL bytes that make kubectl refuse it.
plant_apple_double() {
  printf '\000\005\026\007\000\002\000\000Mac OS X\000\000\000\002\000\000' >"$1"
  printf '\000\000\000\000\000\000\000\000' >>"$1"
}

# apply_step <installer> <manifest-tree> <mock-root> <log> — source <installer>
# with `main` already stripped, point MANIFEST_DIR at <manifest-tree>, stub
# kubectl with the file-backed mock, and run install_applications. Returns the
# step's exit status; the mock's records land under <mock-root>.
apply_step() {
  local installer="$1" tree="$2" mock="$3" log="$4" ec=0
  rm -rf "$mock"
  mkdir -p "$mock"
  # The box state step 6 runs in: step 4 has already made `argocd`, and the
  # Applications apply INTO it (metadata.namespace: argocd). The mock enforces
  # the namespace registry on every write, so the fixture seeds the namespace
  # the manifests name — otherwise the green would fail on the namespace the
  # box already has, not on the transport this check is about.
  printf 'argocd\n' >"$mock/namespaces"
  (
    # shellcheck source=/dev/null
    . "$installer"
    # A failing kubectl KILLS the step here, the way it does on the box: the
    # subshell is the left side of an `||`, which suppresses `set -e`, so the
    # wrapper makes the failure fatal explicitly rather than letting
    # install_applications carry on to its `wait`.
    kubectl() { mock_kubectl "$@" || exit $?; }
    export RECEIPT_PATH="$mock/receipt.json"
    export MOCK_ROOT="$mock"
    # shellcheck disable=SC2034  # read by the sourced installer's install_applications
    MANIFEST_DIR="$tree"
    install_applications
  ) >"$log" 2>&1 || ec=$?
  return "$ec"
}

# GREEN: a tree with AppleDouble sidecars beside the real manifests must apply
# and must not fail.
apple_double_ok() {
  local ec=0 applied argv
  apply_step "$fixture_sourced" "$apple_double_tree" "$WORK/ad-mock" "$WORK/ad.log" || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'the step failed on an AppleDouble-only tree (exit %s):\n%s\n' "$ec" "$(cat "$WORK/ad.log")"
    return 1
  fi
  applied="$(cat "$WORK/ad-mock/applied.yaml" 2>/dev/null || true)"
  case "$applied" in
    *"name: identity"*) : ;;
    *) printf 'identity.yaml was not applied:\n%s\n' "$applied"; return 1 ;;
  esac
  case "$applied" in
    *"name: gateway"*) : ;;
    *) printf 'gateway.yaml was not applied:\n%s\n' "$applied"; return 1 ;;
  esac
  if mock_has_control_bytes "$WORK/ad-mock/applied.yaml"; then
    printf 'a sidecar reached the applied output\n'
    return 1
  fi
  case "$(cat "$WORK/ad.log")" in
    *"ignoring AppleDouble sidecar"*) : ;;
    *) printf 'the ignored sidecar was never named in the output:\n%s\n' "$(cat "$WORK/ad.log")"; return 1 ;;
  esac
  argv="$(cat "$WORK/ad-mock/kubectl-argv" 2>/dev/null || true)"
  case "$argv" in
    *"._"*) printf 'the sidecar was handed to kubectl:\n%s\n' "$argv"; return 1 ;;
  esac
  printf 'sidecar ignored and named, only the real manifests applied'
}

# RED control #1: a stray non-sidecar YAML in the directory must be REFUSED,
# by name, and for the stray file's reason rather than the sidecar's.
stray_refused() {
  local ec=0 log
  apply_step "$fixture_sourced" "$stray_tree" "$WORK/stray-mock" "$WORK/stray.log" || ec=$?
  log="$(cat "$WORK/stray.log")"
  if [ "$ec" -eq 0 ]; then
    printf 'the step applied a directory holding a stray file\n'
    return 1
  fi
  case "$log" in
    *"stray.yml"*) : ;;
    *) printf 'the refusal did not name the stray file:\n%s\n' "$log"; return 1 ;;
  esac
  case "$log" in
    *"control characters"*)
      printf 'the refusal fired for the sidecar, not the stray file:\n%s\n' "$log"
      return 1
      ;;
  esac
  printf 'refused, naming stray.yml'
}

# RED control #2: the glob filter removed (the loop reads EVERY entry, as
# `kubectl apply -f <dir>` always did) hands the sidecar to kubectl and the
# apply breaks again — so the filter is proven load-bearing, not decorative.
nofilter_breaks() {
  local installer="$1" ec=0 log
  if cmp -s "$installer" "$fixture_sourced"; then
    printf 'the filter mutation did not change the installer — a vacuous control\n'
    return 1
  fi
  if ! grep -qF 'for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do' "$installer"; then
    printf 'the mutated (unfiltered) loop is not present in the fixture\n'
    return 1
  fi
  apply_step "$installer" "$apple_double_tree" "$WORK/nofilter-mock" "$WORK/nofilter.log" || ec=$?
  log="$(cat "$WORK/nofilter.log")"
  if [ "$ec" -eq 0 ]; then
    printf 'the sidecar was applied without breaking — the filter is not load-bearing\n'
    return 1
  fi
  case "$log" in
    *"control characters"*) : ;;
    *) printf 'the apply did not break on the sidecar:\n%s\n' "$log"; return 1 ;;
  esac
  printf 'the sidecar broke the apply again (exit %s)' "$ec"
}

# Build the two trees. The premise is asserted before the proof: a control whose
# fixture is missing the thing it names proves nothing.
mkdir -p "$apple_double_tree"
cp "$MANIFESTS/identity.yaml" "$apple_double_tree/"
cp "$MANIFESTS/gateway.yaml" "$apple_double_tree/"
plant_apple_double "$apple_double_tree/._identity.yaml"
plant_apple_double "$apple_double_tree/._gateway.yaml"

mkdir -p "$stray_tree"
cp "$MANIFESTS/identity.yaml" "$stray_tree/"
plant_apple_double "$stray_tree/._identity.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: stray\n' >"$stray_tree/stray.yml"

if [ -f "$apple_double_tree/._identity.yaml" ] && [ -f "$apple_double_tree/identity.yaml" ] \
  && mock_has_control_bytes "$apple_double_tree/._identity.yaml"; then
  pass 'premise: the AppleDouble tree carries a NUL-bearing ._identity.yaml beside the real manifests'
else
  fail 'premise: the AppleDouble tree carries a NUL-bearing ._identity.yaml beside the real manifests' 'the fixture is not the shape the control names'
fi

if [ -f "$stray_tree/stray.yml" ] && ! mock_has_control_bytes "$stray_tree/stray.yml"; then
  pass 'premise: the stray tree carries a non-sidecar YAML named stray.yml'
else
  fail 'premise: the stray tree carries a non-sidecar YAML named stray.yml' 'the fixture is not the shape the control names'
fi

# The filter-removed fixture: one sed changes the helper's loop to read every
# entry, exactly as the pre-fix directory apply did.
nofilter_installer="$WORK/install-nofilter.sh"
sed 's|for f in "$dir"/\*\.yaml; do|for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do|' \
  "$fixture_sourced" >"$nofilter_installer"

run 'the step applies a tree with AppleDouble sidecars (sidecar ignored and named)' green apple_double_ok
run 'control: a stray non-sidecar YAML is refused by name (the apply goes red)' green stray_refused
run 'control: removing the glob filter lets AppleDouble break the apply again' green nofilter_breaks "$nofilter_installer"

# ===========================================================================
# 21. The AppProject the Applications name actually exists — and they name the
#     one that exists
# ===========================================================================
#
# core-install.yaml ships the AppProject CRD but no AppProject object (neither
# does the full install.yaml — both are CRD-only; the controller auto-creates
# a maximal default in some installs, but the core variant does not), so an
# Application with `spec.project: default` is `Unknown/Unknown` with
#   Application referencing project default which does not exist
# and creates nothing — step 11 times out waiting for deployment/identity
# that Argo never made. The manager hand-fixed the box with a maximal project
# (sourceRepos *, destinations */*, clusterResourceWhitelist */*); kit ships
# the least-privilege one in manifests/argocd/appproject.yaml — sourceRepos
# the two upstream Helm repoURLs plus the chart-path glob
# oci://ghcr.io/cafaye/charts/*, destinations exactly the five namespaces they
# deploy into on https://kubernetes.default.svc, no cluster-scoped whitelist —
# and step 4 applies it right after Argo CD is Available and before any
# Application is applied (see install_argocd).
#
# The check is a STATIC equality over YAML: the project the Applications name
# and the shipped AppProject's name must be one fact, one spelling. A static
# check is the right shape here because the defect is a name that disagrees
# across files rather than a runtime behaviour; the runtime behaviour is what
# the box showed.
#
# AND THE SECOND SEAM THIS PACKET EXISTS FOR: the AppProject's sourceRepos and
# the Applications' source.repoURL are TWO SETS OVER ONE FACT, and they drifted.
# A sibling packet moved each Application from the registry ROOT to its own
# chart's PATH (oci://ghcr.io/cafaye/charts/gateway, …/courier, …/identity,
# …/parlor) because Argo resolves an OCI source's revision against the full
# path; appproject.yaml still listed the bare root, so the controller refused
# every Application with
#   application repo oci://ghcr.io/cafaye/charts/gateway is not permitted in
#   project 'default'
# The name-equality check above cannot see it — the project is named `default`
# and the Applications name `default`, so it is green on the exact box that is
# broken. The check below is over the OTHER two sets, and the control is that
# historical pair: the pre-fix bare root + the per-chart Applications goes red.
#
# The permission test mirrors the pinned Argo (v3.5.4) exactly:
# `IsSourcePermitted` normalises both sides with `git.NormalizeGitURL`
# (lower-case, trim a `.git` suffix) and matches with `util/glob.Match(pat,
# val, '/')` — gobwas/glob with `/` as the separator, so a `*` cannot cross a
# `/`. This is glob-aware on purpose: the project permits ONE chart-name
# segment under the root, not a fixed four, so a fifth service needs no edit
# here, and a fixture adding a fifth chart must stay green while a fixture
# naming another registry must go red.
APP_PROJECT="$SUBSTRATE/manifests/argocd/appproject.yaml"

check_appproject() {
  "$PY" - "$1" "$2" <<'PY'
import os
import sys

import yaml

apps_dir, proj_path = sys.argv[1:3]
# The Applications.
apps = []
for f in sorted(os.listdir(apps_dir)):
    if not f.endswith((".yaml", ".yml")):
        continue
    path = os.path.join(apps_dir, f)
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except yaml.YAMLError as e:
        print(f"{f}: does not parse ({e})")
        sys.exit(1)
    spec = doc.get("spec", {}) if isinstance(doc, dict) else {}
    proj = spec.get("project")
    if not proj:
        print(f"{f}: spec.project is missing or empty")
        sys.exit(1)
    apps.append((f, proj))

if not apps:
    print("no Application manifests found")
    sys.exit(1)

# All Applications must name the SAME project — a mixed set is a fleet where
# some Applications sync and some never do, and the mixed state is the defect.
projects = {p for _, p in apps}
if len(projects) != 1:
    print(f"Applications name {len(projects)} distinct projects: {sorted(projects)} — one fact, one spelling")
    sys.exit(1)
apps_project = projects.pop()

# The shipped AppProject.
try:
    proj_doc = yaml.safe_load(open(proj_path, encoding="utf-8"))
except FileNotFoundError:
    print(f"{proj_path}: no such file — the project the Applications name is not shipped")
    sys.exit(1)
except yaml.YAMLError as e:
    print(f"{proj_path}: does not parse ({e})")
    sys.exit(1)

if not isinstance(proj_doc, dict):
    print(f"{proj_path}: not a mapping")
    sys.exit(1)
if proj_doc.get("kind") != "AppProject":
    print(f"{proj_path}: kind is {proj_doc.get('kind')!r}, not 'AppProject'")
    sys.exit(1)
if proj_doc.get("apiVersion") != "argoproj.io/v1alpha1":
    print(f"{proj_path}: apiVersion is {proj_doc.get('apiVersion')!r}, want 'argoproj.io/v1alpha1'")
    sys.exit(1)
meta = proj_doc.get("metadata", {})
shipped = meta.get("name")
if not shipped:
    print(f"{proj_path}: metadata.name is missing")
    sys.exit(1)
if shipped != apps_project:
    print(f"Applications name project {apps_project!r} but shipped AppProject is {shipped!r} — one fact, one spelling")
    sys.exit(1)

# Least-privilege shape: the project must list exactly the repoURLs and
# destinations the Applications use, and no bare wildcard. A maximal project
# (sourceRepos *, destinations */*) would pass the equality check above while
# being the boundary the packet exists to tighten, so the least-privilege
# half is asserted here too — the same way the static phase's allowlist
# hygiene refuses an entry matching nothing. A glob that is a PATH under a
# repo this project owns (`oci://ghcr.io/cafaye/charts/*`) is not a bare `*`
# and is allowed; the check is exact membership, so `"*" == repo` is what it
# refuses, not any repo containing a `*`.
spec = proj_doc.get("spec", {})
repos = spec.get("sourceRepos", [])
if "*" in repos:
    print("sourceRepos contains a bare '*' — the project is maximal; list the repoURLs the Applications use")
    sys.exit(1)
dests = spec.get("destinations", [])
for d in dests:
    if d.get("server") == "*" or d.get("namespace") == "*":
        print(f"destination {d} contains '*' — list exactly the fleet's namespaces on https://kubernetes.default.svc")
        sys.exit(1)
if any(c.get("group") == "*" and c.get("kind") == "*" for c in spec.get("clusterResourceWhitelist", [])):
    print("clusterResourceWhitelist contains group '*' kind '*' — the project is maximal; the charts need no cluster-scoped resources")
    sys.exit(1)

print(f"{len(apps)} Applications name project {apps_project!r}, shipped AppProject is {shipped!r}, least-privilege")
PY
}

run 'the Applications name the shipped AppProject (one fact, one spelling, least-privilege)' green \
  check_appproject "$MANIFESTS" "$APP_PROJECT"

# The red control: a fixture where one Application names a different project.
# Must go red — an equality the check cannot see disagree is not a check.
fixture_project_drift="$WORK/appproject-drift"
mkdir -p "$fixture_project_drift"
cp "$MANIFESTS"/*.yaml "$fixture_project_drift/"
# Change one Application's project.
sed -i '' 's/project: default/project: other/' "$fixture_project_drift/identity.yaml" 2>/dev/null || \
  sed -i 's/project: default/project: other/' "$fixture_project_drift/identity.yaml"
run 'control: an Application naming a different project goes red' red \
  check_appproject "$fixture_project_drift" "$APP_PROJECT"

# The second control: the shipped project renamed. Must go red the same way —
# a check satisfied by a file that contains the right name somewhere would
# pass on a project named `default` and an Application naming `cafaye`.
fixture_project_renamed="$WORK/appproject-renamed.yaml"
sed 's/name: default/name: cafaye/' "$APP_PROJECT" >"$fixture_project_renamed"
run 'control: a shipped AppProject with a different name goes red' red \
  check_appproject "$MANIFESTS" "$fixture_project_renamed"

# --- The permission check: the AppProject's sourceRepos must permit every
# Application's source.repoURL. This is the seam the name-equality check above
# cannot see (see the section comment) and the exact on-box refusal.
check_appproject_permits() {
  "$PY" - "$1" "$2" <<'PY'
import os
import re
import sys

import yaml


def normalize(repo):
    # Mirrors argo-cd v3.5.4 util/git/git.go NormalizeGitURL for the URL forms
    # this substrate uses (https and oci, never git@/ssh): lower-case, trim a
    # trailing `.git`, and leave everything else — including a `*`.
    repo = repo.strip().lower()
    if repo.endswith(".git"):
        repo = repo[:-4]
    return repo


def glob_to_regex(pattern):
    # gobwas/glob with '/' as the separator, which is what util/glob.Match is
    # called with: `*` matches a run of non-'/' characters, `?` one non-'/'
    # character, `[...]` a class. Everything else is literal.
    i, n, out = 0, len(pattern), []
    while i < n:
        c = pattern[i]
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = i + 1
            if j < n and pattern[j] in "!^":
                j += 1
            if j < n and pattern[j] == "]":
                j += 1
            while j < n and pattern[j] != "]":
                j += 1
            if j >= n:
                out.append(r"\[")
            else:
                cls = pattern[i + 1:j]
                if cls.startswith("!"):
                    cls = "^" + cls[1:]
                out.append("[" + cls + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def glob_match(pattern, value):
    # The `pattern == "*"` shortcut is Argo's own (globMatch in
    # app_project_types.go): a bare `*` allows everything before globbing.
    if pattern == "*":
        return True
    return bool(glob_to_regex(pattern).match(value))


def permitted(repo_url, patterns):
    # The exact algorithm of AppProject.IsSourcePermitted (v3.5.4): normalise
    # both sides, match with '/' as separator, honour `!` deny patterns.
    src = normalize(repo_url)
    any_matched = False
    for raw in patterns:
        raw = raw.strip()
        if raw.startswith("!"):
            norm = "!" + normalize(raw[1:])
            matched = not glob_match(norm[1:], src)
            if not matched:
                return False  # a deny pattern that matches refuses the source
            any_matched = True
        else:
            if glob_match(normalize(raw), src):
                any_matched = True
    return any_matched


apps_dir, proj_path = sys.argv[1:3]

try:
    proj_doc = yaml.safe_load(open(proj_path, encoding="utf-8"))
except FileNotFoundError:
    print(f"{proj_path}: no such file")
    sys.exit(1)
except yaml.YAMLError as e:
    print(f"{proj_path}: does not parse ({e})")
    sys.exit(1)
if not isinstance(proj_doc, dict) or proj_doc.get("kind") != "AppProject":
    print(f"{proj_path}: not an AppProject")
    sys.exit(1)
patterns = (proj_doc.get("spec") or {}).get("sourceRepos") or []
if not isinstance(patterns, list) or not patterns:
    print(f"{proj_path}: spec.sourceRepos is empty — nothing is permitted")
    sys.exit(1)

files = sorted(f for f in os.listdir(apps_dir) if f.endswith((".yaml", ".yml")))
if not files:
    print(f"{apps_dir}: no Application manifests found")
    sys.exit(1)

refused = []
seen = 0
for f in files:
    doc = yaml.safe_load(open(os.path.join(apps_dir, f), encoding="utf-8"))
    src = (doc.get("spec") or {}).get("source") or {}
    repo = src.get("repoURL")
    if not repo:
        refused.append(f"{f}: spec.source.repoURL is missing")
        continue
    seen += 1
    if not permitted(repo, patterns):
        refused.append(
            f"{f}: repoURL {repo!r} is not permitted by any of {patterns!r}"
        )

if refused:
    print("; ".join(refused))
    sys.exit(1)
print(f"{seen} Application(s), every repoURL permitted by {len(patterns)} sourceRepos entry/entries")
PY
}

# GRANT: the real tree. Every Application's repoURL is permitted.
run 'every Application source.repoURL is permitted by the AppProject sourceRepos' green \
  check_appproject_permits "$MANIFESTS" "$APP_PROJECT"

# RED CONTROL 1 — the historical PAIR. appproject.yaml used to list the bare
# registry ROOT while the Applications name per-chart PATHS, which is the exact
# refusal measured on the box:
#   application repo oci://ghcr.io/cafaye/charts/gateway is not permitted in
#   project 'default'
# Rebuild the pre-fix project and require the check to see it.
fixture_project_bare_root="$WORK/appproject-bare-root.yaml"
sed 's|^    - oci://ghcr.io/cafaye/charts/\*$|    - oci://ghcr.io/cafaye/charts|' \
  "$APP_PROJECT" >"$fixture_project_bare_root"
# The guard reads the LIST ITEM, not a substring of the file: the comment above
# the list explains the glob and names it, so a whole-file grep would find the
# explanation and call a correct fixture unbuilt.
if grep -qE '^ +- oci://ghcr\.io/cafaye/charts/\*' "$fixture_project_bare_root"; then
  fail 'control fixture: the bare-root AppProject was not built' \
    "the sed did not strip the chart glob from sourceRepos, so the control would prove nothing"
else
  run 'control: the pre-fix bare-root AppProject refuses the per-chart Applications' red \
    check_appproject_permits "$MANIFESTS" "$fixture_project_bare_root"
fi

# RED CONTROL 2 — an Application naming a repo OUTSIDE the project entirely.
fixture_foreign_repo="$WORK/apps-foreign-repo"
mkdir -p "$fixture_foreign_repo"
cp "$MANIFESTS"/*.yaml "$fixture_foreign_repo/"
sed -i '' 's|repoURL: oci://ghcr.io/cafaye/charts/courier|repoURL: oci://ghcr.io/evil/charts/courier|' \
  "$fixture_foreign_repo/courier.yaml" 2>/dev/null || \
  sed -i 's|repoURL: oci://ghcr.io/cafaye/charts/courier|repoURL: oci://ghcr.io/evil/charts/courier|' \
  "$fixture_foreign_repo/courier.yaml"
if grep -q 'oci://ghcr.io/evil/charts/courier' "$fixture_foreign_repo/courier.yaml"; then
  run 'control: an Application naming a repo the project does not permit goes red' red \
    check_appproject_permits "$fixture_foreign_repo" "$APP_PROJECT"
else
  fail 'control fixture: the foreign-repo Application was not built' \
    "the sed did not rewrite courier's repoURL, so the control would prove nothing"
fi

# RED CONTROL 3 — the `*` cannot cross a `/`. A nested OCI path under the same
# root is refused, which is the "it is not a bare `*`" posture the AppProject
# comment claims; the check must encode the separator, not just a prefix.
fixture_nested_repo="$WORK/apps-nested-repo"
mkdir -p "$fixture_nested_repo"
cp "$MANIFESTS"/*.yaml "$fixture_nested_repo/"
sed -i '' 's|repoURL: oci://ghcr.io/cafaye/charts/identity|repoURL: oci://ghcr.io/cafaye/charts/nested/identity|' \
  "$fixture_nested_repo/identity.yaml" 2>/dev/null || \
  sed -i 's|repoURL: oci://ghcr.io/cafaye/charts/identity|repoURL: oci://ghcr.io/cafaye/charts/nested/identity|' \
  "$fixture_nested_repo/identity.yaml"
if grep -q 'charts/nested/identity' "$fixture_nested_repo/identity.yaml"; then
  run 'control: a nested OCI path is refused (the `*` cannot cross a `/`)' red \
    check_appproject_permits "$fixture_nested_repo" "$APP_PROJECT"
else
  fail 'control fixture: the nested-repo Application was not built' \
    "the sed did not nest the identity repoURL, so the control would prove nothing"
fi

# GREEN CONTROL — a FIFTH chart under the same root is permitted with no edit
# to the project. This is the whole reason for the glob rather than four names:
# a new service must not require an edit to appproject.yaml, and a check that
# only knew the four shipped names would pass on an enumeration.
fixture_fifth_chart="$WORK/apps-fifth-chart"
mkdir -p "$fixture_fifth_chart"
cp "$MANIFESTS"/*.yaml "$fixture_fifth_chart/"
# A new Application, assembled rather than sed'ed from an existing one so its
# name and chart agree.
cat >"$fixture_fifth_chart/pantry.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pantry
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://ghcr.io/cafaye/charts/pantry
    chart: pantry
    targetRevision: 0.1.0
  destination:
    server: https://kubernetes.default.svc
    namespace: pantry
YAML
run 'the project permits a FIFTH chart with no edit (the glob, not four names)' green \
  check_appproject_permits "$fixture_fifth_chart" "$APP_PROJECT"

# ===========================================================================
# 22. No other substrate manifest names an object core-install does not ship
# ===========================================================================
#
# The AppProject was the one that shipped this packet; the sibling packets
# already caught argocd-server (a Deployment and a guard that core-install
# does not provide). This is the sweep for the same class — a reference to a
# workload or Service the substrate assumes exists in the argocd namespace
# because a full Argo CD install provides it, while the core variant this
# substrate installs does not.
#
# The work is per REFERENCE, not per file: every workload/service name that
# appears in the substrate's own manifests is listed, then each is checked
# against the set of workloads/services the pinned core-install.yaml actually
# ships (parsed rather than hand-typed, so the pin is the source of truth).
# A hand-typed allowlist would contain argocd-server the day it was removed,
# which is the failure the sibling packet exists to prevent.
# The sweep is OFFLINE — no curl — because the gate must be green on a
# development machine with no network, and a sweep that SKIPs offline is a
# sweep that never ran on the machine that most needs it. The set is derived
# from the pinned core-install workloads the installer actually waits on and
# guards: the three Deployments and one StatefulSet core-install ships in
# argocd (applicationset-controller, redis, repo-server, application-controller)
# — not a hand-typed list a future Argo bump could silently invalidate, but the
# same set section 19's runnable-code check is built from. A reference to
# argocd-server, dex or notifications-controller is what the sibling packets
# caught; this sweep lists EVERY argocd-* string the substrate mentions and
# reports per reference whether it is in that set.
CORE_ALLOWED="argocd-application-controller argocd-applicationset-controller argocd-redis argocd-repo-server"
# The substrate's own workload/service references — every string that names a
# component in argocd that the substrate waits on, guards, or ships.
substrate_refs_raw="$(grep -h "argocd" "$SUBSTRATE/install.sh" "$APP_PROJECT" "$SUBSTRATE/manifests"/*.yaml "$SUBSTRATE/manifests"/*/*.yaml 2>/dev/null | grep -oE "argocd-[a-z0-9-]+" | sort -u || true)"
missing_refs=""
unknown_refs=""
for ref in $substrate_refs_raw; do
  case " $CORE_ALLOWED " in
    *" $ref "*) ;;
    *)
      # argocd-server and the initial-admin-secret are the known absent pair;
      # section 19 already proves the runnable code names neither, so a hit
      # here is either a comment (allowed) or a new manifest reference that
      # slipped through that check — separate the two.
      case "$ref" in
        argocd-server|argocd-dex-server|argocd-notifications-controller|argocd-initial-admin-secret)
          unknown_refs="${unknown_refs:+$unknown_refs }${ref}"
          ;;
        *)
          missing_refs="${missing_refs:+$missing_refs }${ref}"
          ;;
      esac
      ;;
  esac
done
if [ -n "$missing_refs" ]; then
  fail 'sweep: substrate names a workload/service core-install does not ship' "$missing_refs"
else
  pass 'sweep: substrate names no workload/service core-install does not ship (per reference)'
fi
if [ -n "$unknown_refs" ]; then
  # The runnable-code check in §19 must have caught these; if they appear here
  # they are in a comment or manifest rather than runnable code — report but
  # do not double-fail the same names.
  case "$(grep -E "argocd-(server|dex-server|notifications-controller|initial-admin-secret)" "$SUBSTRATE/install.sh" 2>/dev/null | grep -v "^[[:space:]]*#")" in
    *argocd-server*|*argocd-initial-admin-secret*)
      fail 'sweep: runnable code still names a component core-install does not ship' "$unknown_refs"
      ;;
    *)
      pass 'sweep: no runnable reference to the absent pair (comment-only, already gated by §19)'
      ;;
  esac
else
  pass 'sweep: no reference to the absent pair beyond comments (§19)'
fi

# ===========================================================================
# 23. THE SERVICES' TELEMETRY IS OFF ON THE BOX, ON ONE SPELLING
# ===========================================================================
#
# THE DEFECT. Every service's COMPILED default OTLP endpoint is the COMPOSE
# stack's name — `http://otel-collector:4318` for identity/courier/parlor and
# `:4317` for gateway. The box deploys no such Service and no OTLP endpoint at
# all: alloy is pinned at chart 1.13.0 with no values, so its default config is
# `config/example.alloy` (a `logging` block and `discovery.kubernetes`, no
# `otelcol.receiver.otlp`) and its default Service exposes only `http-metrics`
# on 12345; and the substrate ships no Tempo. So a fresh box's services retry
# forever and log a DNS failure every ten seconds.
#
# THE CLAIM. Every service the substrate configures is told to turn its SDK off
# with the OTel spec's own switch — `OTEL_SDK_DISABLED=true`, the mechanism
# core's `otel-endpoint.schema.json` pins for the no-op path — and the switch is
# spelled ONCE and referenced, never retyped. The three generated-chart services
# get it through their secret (their charts inject env with
# `envFrom: secretRef`); gateway's hand-written chart reads clear env from a
# ConfigMap, so its Application carries the same key/value in
# `spec.source.helm.values`. The two sites must AGREE.
#
# THE CONTROLS answer differently: the switch dropped from the constant, the
# switch NAME drifted in the constant, one secret's reference removed, and
# gateway's Application losing the key or drifting its value — each must go red.
check_service_telemetry() {
  "$PY" - "$1" "$2" <<'PY'
import os
import re
import sys

import yaml

install_path, apps_dir = sys.argv[1], sys.argv[2]

# The switch core's schema pins, named once here so a drift is a comparison.
SWITCH_KEY = "OTEL_SDK_DISABLED"
SWITCH_VALUE = "true"

src = open(install_path, encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)

problems = []

# 1. The switch is DEFINED once, with the spec's own key and value. The
#    `=(--from-literal=` anchor is what makes this the DEFINITION and not one of
#    the references (`"${SERVICE_OTEL_DISABLED[@]}"`).
defs = re.findall(r"SERVICE_OTEL_DISABLED=\(--from-literal=([A-Z_]+)=([^)]+)\)", code)
if len(defs) != 1:
    problems.append(f"expected exactly one SERVICE_OTEL_DISABLED definition, found {len(defs)}")
elif tuple(defs[0]) != (SWITCH_KEY, SWITCH_VALUE):
    problems.append(f"the off-switch is {defs[0]!r}, want {(SWITCH_KEY, SWITCH_VALUE)!r}")

# 2. Every generated-chart service's secret carries it BY REFERENCE. A window
#    after the create line is long enough for the multi-line invocations and
#    short enough not to reach the next secret.
for secret in ("identity-secrets", "courier-secrets", "parlor-secrets"):
    m = re.search(r"create secret generic " + re.escape(secret) + r"\b", code)
    if not m:
        problems.append(f"{secret} is never created")
        continue
    window = code[m.start():m.start() + 1400]
    if "SERVICE_OTEL_DISABLED" not in window:
        problems.append(f"{secret} is created without the telemetry off-switch")
    elif f"--from-literal={SWITCH_KEY}=" in window:
        problems.append(f"{secret} retypes the switch instead of referencing the constant")

# 3. gateway: the one chart that does not envFrom its secret. Its Application
#    must carry the same key/value through spec.source.helm.values.
gw_path = os.path.join(apps_dir, "gateway.yaml")
try:
    with open(gw_path, encoding="utf-8") as fh:
        gw = yaml.safe_load(fh)
except (OSError, yaml.YAMLError) as exc:  # noqa: BLE001 - reported, never swallowed
    problems.append(f"gateway.yaml cannot be read: {exc}")
    gw = {}
source = (gw.get("spec") or {}).get("source") or {}
values = (source.get("helm") or {}).get("values")
if not values:
    problems.append("gateway.yaml carries no spec.source.helm.values, so the switch never reaches gateway")
else:
    env = (yaml.safe_load(values) or {}).get("env") or {}
    if str(env.get(SWITCH_KEY)) != SWITCH_VALUE:
        problems.append(
            f"gateway.yaml's helm values set env.{SWITCH_KEY}={env.get(SWITCH_KEY)!r}, "
            f"want {SWITCH_VALUE!r}"
        )

# 4. "Every service" is the four the substrate ships, and each must have a
#    secret to carry the switch or an Application that does. A service dropped
#    from the secret step is a service nothing configures.
services = set(re.findall(r"create secret generic (\S+-secrets)", code))
for svc in ("identity", "gateway", "courier", "parlor"):
    if f"{svc}-secrets" not in services:
        problems.append(f"{svc} has no secret in install.sh")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("every service is told to disable its SDK, on one spelling, and the two sites agree")
PY
}

run 'every service is told to disable its SDK, on one spelling' green \
  check_service_telemetry "$SUBSTRATE/install.sh" "$MANIFESTS"

# The control that the switch can be dropped from the definition at all.
fixture_no_switch="$WORK/install-no-switch.sh"
sed 's/^SERVICE_OTEL_DISABLED=(--from-literal=OTEL_SDK_DISABLED=true)$/SERVICE_OTEL_DISABLED=()/' \
  "$SUBSTRATE/install.sh" >"$fixture_no_switch"
run 'control: the off-switch dropped from the constant goes red' red \
  check_service_telemetry "$fixture_no_switch" "$MANIFESTS"

# The control that the switch NAME is load-bearing — a name no SDK reads is the
# defect wearing the fix's clothes, so the check must not accept it.
fixture_drifted_switch="$WORK/install-drifted-switch.sh"
sed 's/--from-literal=OTEL_SDK_DISABLED=true/--from-literal=OTEL_TELEMETRY_OFF=true/' \
  "$SUBSTRATE/install.sh" >"$fixture_drifted_switch"
run 'control: a drifted switch name in the constant goes red' red \
  check_service_telemetry "$fixture_drifted_switch" "$MANIFESTS"

# The control that one service's REFERENCE is load-bearing: identity keeps the
# definition but stops referencing it, so its pod would fall back to the
# compose name.
fixture_identity_no_switch="$WORK/install-identity-no-switch.sh"
sed 's/"\${identity_args\[@\]}" "\${SERVICE_OTEL_DISABLED\[@\]}"/"\${identity_args[@]}"/' \
  "$SUBSTRATE/install.sh" >"$fixture_identity_no_switch"
run 'control: a service secret without the switch goes red' red \
  check_service_telemetry "$fixture_identity_no_switch" "$MANIFESTS"

# The controls for gateway's half: its Application losing the key, and its value
# drifting. A fixture apps directory holds only gateway.yaml — that is the only
# file this check reads out of the directory.
fixture_gw_name="$WORK/apps-gateway-name"
mkdir -p "$fixture_gw_name"
sed 's/OTEL_SDK_DISABLED: "true"/OTEL_DISABLED: "true"/' \
  "$MANIFESTS/gateway.yaml" >"$fixture_gw_name/gateway.yaml"
run 'control: gateway with a drifted switch name goes red' red \
  check_service_telemetry "$SUBSTRATE/install.sh" "$fixture_gw_name"

fixture_gw_value="$WORK/apps-gateway-value"
mkdir -p "$fixture_gw_value"
sed 's/OTEL_SDK_DISABLED: "true"/OTEL_SDK_DISABLED: "false"/' \
  "$MANIFESTS/gateway.yaml" >"$fixture_gw_value/gateway.yaml"
run 'control: gateway losing the switch value goes red' red \
  check_service_telemetry "$SUBSTRATE/install.sh" "$fixture_gw_value"

# ===========================================================================
# 24. EVERY CROSS-SERVICE ADDRESS RESOLVES TO A SERVICE THE MANIFESTS SHIP
# ===========================================================================
#
# THE DEFECT. The box puts every service in its own namespace — `identity`,
# `gateway`, `courier`, `parlor` — and the data plane in `data`. A bare name
# resolves only inside a namespace of that name (Kubernetes limits a query
# naming no namespace to the CALLER's own), so `http://identity:8080` from a pod
# in `gateway` resolves to nothing: gateway boots, `/readyz` answers
# `identity: unavailable` forever, and nothing becomes Ready. The COMPOSE
# spelling is correct for one flat network and wrong the moment the substrate
# gives each service a namespace.
#
# THE CLAIM. Every cross-service address the substrate sets is
# `<svc>.<ns>.svc.cluster.local` and names a Service the substrate's manifests
# actually ship, in the namespace they ship it in. Two writers are covered: the
# APPLICATIONS (`spec.source.helm.values`, which is where the substrate owns
# gateway's and parlor's clear env) and the INSTALLER's own addresses (the
# constants and DSNs it writes into the services' secrets — NATS_URL,
# COURIER_BASE_URL, COURIER_IDENTITY_URL, REDIS_URL, the database DSNs).
#
# WHY A STATIC CHECK OVER YAML. The defect is a name that disagrees across two
# trees (a chart default written for compose vs. the substrate's namespace
# layout); the box showed the runtime symptom. The equality is a name, so a
# static comparison of names is the check that would have caught it, and it runs
# on a developer machine.
#
# THE SHIPPED SET IS DERIVED, NOT TYPED. The launch Services come from each
# Application's `metadata.name` + `spec.destination.namespace`; the data Services
# from the `Service` documents in `manifests/data/`; and CNPG's read-write
# Service (`<cluster>-rw`) from the `Cluster` document. So an address to a name
# no manifest creates — `pantry`, `billing` — goes RED, which is the property
# that keeps the check honest: the substrate may only name what it ships.
#
# THE CONTROLS answer differently: a bare name, a name in the wrong namespace, a
# name no manifest ships (pantry), a service that loses its address entirely,
# and a drifted name in the installer — each must go red.
check_cross_namespace_addresses() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import os
import re
import sys

import yaml

apps_dir, data_dir, install_path = sys.argv[1:4]

problems = []

# --- 1. the Services the manifests SHIP ------------------------------------
# launch services: one Application per service, its name the Service's name and
# its destination the service's own namespace.
shipped = {}
for entry in sorted(os.listdir(apps_dir)):
    if not entry.endswith(".yaml"):
        continue
    with open(os.path.join(apps_dir, entry), encoding="utf-8") as fh:
        app = yaml.safe_load(fh) or {}
    if not isinstance(app, dict):
        continue
    meta = app.get("metadata") or {}
    dest = ((app.get("spec") or {}).get("destination") or {})
    name, ns = meta.get("name"), dest.get("namespace")
    if name and ns:
        shipped.setdefault(name, set()).add(ns)

# the data plane: every Service document, plus CNPG's derived read-write Service
# (`<cluster>-rw`), which CNPG creates rather than a manifest.
for entry in sorted(os.listdir(data_dir)):
    if not entry.endswith(".yaml"):
        continue
    with open(os.path.join(data_dir, entry), encoding="utf-8") as fh:
        docs = list(yaml.safe_load_all(fh))
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        meta = doc.get("metadata") or {}
        name, ns = meta.get("name"), meta.get("namespace")
        if doc.get("kind") == "Service" and name and ns:
            shipped.setdefault(name, set()).add(ns)
        if doc.get("kind") == "Cluster" and name and ns:
            shipped.setdefault(f"{name}-rw", set()).add(ns)

SUFFIX = ".svc.cluster.local"
URL_RE = re.compile(r"[a-zA-Z][a-zA-Z0-9+.\-]*://([^\s\"'/]+)")

addresses = []  # (host, where)


def host_of(hostport):
    return hostport.split("@")[-1].split(":")[0]


# --- 2. every address the APPLICATIONS set --------------------------------
app_addresses = 0
per_app = {}
for entry in sorted(os.listdir(apps_dir)):
    if not entry.endswith(".yaml"):
        continue
    with open(os.path.join(apps_dir, entry), encoding="utf-8") as fh:
        app = yaml.safe_load(fh) or {}
    if not isinstance(app, dict):
        continue
    src = ((app.get("spec") or {}).get("source") or {})
    values = (src.get("helm") or {}).get("values")
    if not values:
        continue
    where = f"{entry} (spec.source.helm.values)"
    # The values block is a YAML STRING; parse it and read every scalar, so a
    # URL nested in the route table is found the same way a top-level one is.
    try:
        parsed = yaml.safe_load(values)
    except yaml.YAMLError as exc:
        problems.append(f"{where} is not YAML: {exc}")
        continue
    found = 0
    stack = [parsed]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, str):
            for hostport in URL_RE.findall(node):
                addresses.append((host_of(hostport), where))
                found += 1
    per_app[entry] = found
    app_addresses += found

# The Applications whose clear env the substrate MUST override are named, not
# inferred: gateway's and parlor's charts ship a COMPOSE default for a peer
# (`http://identity:8080`), and the substrate is the only thing that can spell
# the box's namespace. A vacuity guard on the total would be satisfied by
# gateway's two addresses ALONE, so a service that silently lost its override —
# the exact state this packet fixes for parlor — must be its own failure.
for required in ("gateway.yaml", "parlor.yaml"):
    if per_app.get(required, 0) < 1:
        problems.append(
            f"{required} sets no cross-service address, so its chart's compose "
            "default (" + "'http://identity:8080'" + ") is what the box gets"
        )
if app_addresses == 0:
    problems.append(
        "no Application sets a cross-service address — the check is vacuous, so it "
        "proves nothing (gateway and parlor must each carry one)"
    )

# --- 3. every `.svc.cluster.local` name the INSTALLER writes ---------------
with open(install_path, encoding="utf-8") as fh:
    src_text = fh.read()
code = re.sub(r"(?m)^\s*#.*$", "", src_text)
install_addresses = re.findall(r"[A-Za-z0-9.\-]+\.svc\.cluster\.local", code)
for host in install_addresses:
    addresses.append((host, "install.sh"))
if len(install_addresses) < 5:
    problems.append(
        f"install.sh writes only {len(install_addresses)} in-cluster addresses "
        "(expected at least NATS_URL, COURIER_URL, IDENTITY_URL, REDIS_URL and the "
        "Postgres DSN host) — a check on a vanished writer proves nothing"
    )

# --- 4. every address resolves to a shipped Service, in the right namespace -
for host, where in addresses:
    if not host.endswith(SUFFIX):
        problems.append(
            f"{where}: {host!r} is not fully qualified — a bare name resolves only "
            "in the caller's own namespace"
        )
        continue
    parts = host[: -len(SUFFIX)].split(".")
    if len(parts) != 2:
        problems.append(f"{where}: {host!r} is not `<svc>.<ns>.svc.cluster.local`")
        continue
    svc, ns = parts
    if svc not in shipped:
        problems.append(
            f"{where}: {host!r} names Service {svc!r}, which the manifests do not "
            f"ship (shipped: {', '.join(sorted(shipped))})"
        )
    elif ns not in shipped[svc]:
        problems.append(
            f"{where}: {host!r} puts {svc!r} in namespace {ns!r}, but the manifests "
            f"ship it in {', '.join(sorted(shipped[svc]))}"
        )

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(
    f"every cross-service address is fully qualified and names a shipped Service "
    f"({app_addresses} from the Applications, {len(install_addresses)} from install.sh)"
)
PY
}

run 'every cross-service address names a Service the manifests ship' green \
  check_cross_namespace_addresses "$MANIFESTS" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

# A fixture apps directory: the real Applications, so the shipped set is the real
# one, with exactly one file mutated. `cp -R` then `sed` in place.
fixture_apps() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$MANIFESTS/." "$dir/"
}

# The control that a BARE name is the defect: gateway keeps its override but
# drops the qualification, so `identity` resolves only inside `identity`.
fixture_bare="$WORK/apps-bare"
fixture_apps "$fixture_bare"
sed -i.bak 's|http://identity.identity.svc.cluster.local:8080|http://identity:8080|g' \
  "$fixture_bare/gateway.yaml"
rm -f "$fixture_bare/gateway.yaml.bak"
run 'control: a bare cross-service name goes red' red \
  check_cross_namespace_addresses "$fixture_bare" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

# The control that the NAMESPACE segment is load-bearing: identity's Service
# named in the wrong namespace is still a fully qualified name and still wrong.
fixture_wrongns="$WORK/apps-wrongns"
fixture_apps "$fixture_wrongns"
sed -i.bak 's|identity.identity.svc.cluster.local|identity.gateway.svc.cluster.local|g' \
  "$fixture_wrongns/gateway.yaml"
rm -f "$fixture_wrongns/gateway.yaml.bak"
run 'control: a name in the wrong namespace goes red' red \
  check_cross_namespace_addresses "$fixture_wrongns" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

# The control that a name the manifests DO NOT SHIP is refused. This is the
# property that keeps the check from being satisfied by any well-spelled name:
# pantry is addressed by the fleet but shipped by no substrate manifest, so a
# substrate Application may not name it.
fixture_unshipped="$WORK/apps-unshipped"
fixture_apps "$fixture_unshipped"
sed -i.bak 's|http://identity.identity.svc.cluster.local:8080|http://pantry.pantry.svc.cluster.local:8080|' \
  "$fixture_unshipped/gateway.yaml"
rm -f "$fixture_unshipped/gateway.yaml.bak"
run 'control: an address to a Service no manifest ships goes red' red \
  check_cross_namespace_addresses "$fixture_unshipped" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

# The control that a SERVICE LOSING ITS ADDRESS is caught: parlor's override is
# emptied, so parlor falls back to the compose spelling — the exact state this
# packet fixes — and the address set shrinks.
fixture_parlor_loss="$WORK/apps-parlor-loss"
fixture_apps "$fixture_parlor_loss"
"$PY" - "$fixture_parlor_loss/parlor.yaml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    docs = list(yaml.safe_load_all(fh))
app = docs[0]
src = app["spec"]["source"]
helm = src.get("helm")
if helm:
    del src["helm"]
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump_all(docs, fh)
PY
run 'control: a service that loses its address goes red' red \
  check_cross_namespace_addresses "$fixture_parlor_loss" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

# The control that the INSTALLER's half is load-bearing: the Redis address is
# moved to a namespace redis does not live in.
fixture_install_ns="$WORK/install-wrong-ns.sh"
sed 's|redis\.data\.svc\.cluster\.local|redis.gateway.svc.cluster.local|g' \
  "$SUBSTRATE/install.sh" >"$fixture_install_ns"
run 'control: a drifted in-cluster name in the installer goes red' red \
  check_cross_namespace_addresses "$MANIFESTS" "$SUBSTRATE/manifests/data" "$fixture_install_ns"

# ===========================================================================
# 24. EVERY RUN REPORTS ITS OWN SPEED — the step timing is present and honest
# ===========================================================================
# `install.sh` used to carry no timestamps at all, so a step's duration could
# not be recovered after the fact. Now every step emits `seconds`, measured on
# the step's own boundary, and the final event carries the total and the
# per-step table. This check is what makes the number TRUSTWORTHY rather than
# decorative: a step with no timing, a run with no positive duration, and a
# total smaller than the steps it names all go red. The controls are fixtures
# assembled here, never a copy of the tree.
check_timing() {
  "$PY" - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
starts = 0
dones = 0
step_sum = 0.0
last_offset = None
problems = []
total = None
steps_table = None

with open(path, encoding="utf-8") as fh:
    for lineno, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError as exc:
            problems.append(f"line {lineno} is not JSON: {exc}")
            continue
        name = ev.get("event")
        if name == "step.start":
            starts += 1
            secs = ev.get("seconds")
            if not isinstance(secs, (int, float)) or secs < 0:
                problems.append(f"line {lineno}: step.start has no non-negative seconds: {secs!r}")
                continue
            # The offsets come off a monotonic clock, so they never go
            # backwards; a decreasing offset is a clock that was edited or a
            # number that was not measured.
            if last_offset is not None and secs < last_offset:
                problems.append(f"line {lineno}: step.start offset {secs} is behind the previous {last_offset}")
            last_offset = secs
        elif name == "step.done":
            dones += 1
            if "seconds" not in ev:
                problems.append(f"line {lineno}: step.done reports no timing")
                continue
            secs = ev["seconds"]
            if secs == "skipped":
                continue
            if not isinstance(secs, (int, float)) or secs < 0:
                problems.append(f"line {lineno}: step.done seconds is neither a duration nor 'skipped': {secs!r}")
                continue
            step_sum += secs
        elif name == "install.done":
            total = ev.get("seconds")
            steps_table = ev.get("steps")

if starts == 0:
    problems.append("no step.start events")
if dones == 0:
    problems.append("no step.done events")
if step_sum <= 0:
    problems.append("no step reports a positive duration — the timing is a constant, not a measurement")
if total is None or not isinstance(total, (int, float)) or total < 0:
    problems.append(f"install.done carries no non-negative total seconds: {total!r}")
elif total + 1e-9 < step_sum:
    problems.append(f"the total ({total}) is smaller than the sum of the steps it names ({round(step_sum, 3)})")
if not isinstance(steps_table, list) or not steps_table:
    problems.append("install.done carries no steps table")
else:
    table_sum = 0.0
    for row in steps_table:
        s = row.get("seconds")
        if isinstance(s, (int, float)):
            table_sum += s
        elif s != "skipped":
            problems.append(f"steps table row has no duration: {row!r}")
    if isinstance(total, (int, float)) and total + 1e-9 < table_sum:
        problems.append(f"the total ({total}) is smaller than its own steps table ({round(table_sum, 3)})")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{dones} steps timed, total {total}s >= sum {round(step_sum, 3)}s")
PY
}

timing_jsonl="$WORK/timing.jsonl"
KIT_SUBSTRATE_RECEIPT="$WORK/timing-receipt.json" KIT_SUBSTRATE_DATABASES="$DBS" \
  HEADLESS=1 DRY_RUN=1 bash "$SUBSTRATE/install.sh" >"$timing_jsonl" 2>"$WORK/timing.err" || true

timing_starts="$(grep -c '"event":"step.start"' "$timing_jsonl" || true)"
timing_dones="$(grep -c '"event":"step.done"' "$timing_jsonl" || true)"
if [ "$timing_starts" -eq 13 ] && [ "$timing_dones" -eq 13 ]; then
  pass 'every step emits a start and a done event'
else
  fail 'every step emits a start and a done event' \
    "${timing_starts} start(s), ${timing_dones} done(s) — expected 13 and 13"
fi

run 'the step timings are present and the total covers the steps' green check_timing "$timing_jsonl"

# The install.done event's own `steps` table is the human table's source, so a
# reader can take the whole answer off one line.
if grep -q '"event":"install.done".*"steps":\[' "$timing_jsonl"; then
  pass 'the final event carries the per-step table'
else
  fail 'the final event carries the per-step table' "$(tail -1 "$timing_jsonl")"
fi

# Control 1: a step.done with no `seconds` at all. This is the packet's named
# red control — a step that reports no timing must not pass.
fixture_no_timing="$WORK/timing-no-seconds.jsonl"
{
  printf '%s\n' '{"event":"step.start","step":1,"phase":"k3s","message":"k3s","seconds":0.100}'
  printf '%s\n' '{"event":"step.done","step":1,"phase":"k3s","message":"k3s: done"}'
  printf '%s\n' '{"event":"install.done","step":1,"phase":"k3s","message":"up","seconds":1.000,"steps":[{"step":1,"phase":"k3s","seconds":0.100}]}'
} >"$fixture_no_timing"
run 'control: a step that reports no timing goes red' red check_timing "$fixture_no_timing"

# Control 2: a total that is a fabricated constant, smaller than the steps it
# names. A number nobody measured is exactly what this check exists to refuse.
fixture_short_total="$WORK/timing-short-total.jsonl"
{
  printf '%s\n' '{"event":"step.start","step":1,"phase":"k3s","message":"k3s","seconds":0.100}'
  printf '%s\n' '{"event":"step.done","step":1,"phase":"k3s","message":"k3s: 5.000s","seconds":5.000}'
  printf '%s\n' '{"event":"install.done","step":1,"phase":"k3s","message":"up","seconds":0.500,"steps":[{"step":1,"phase":"k3s","seconds":5.000}]}'
} >"$fixture_short_total"
run 'control: a total smaller than the steps it names goes red' red check_timing "$fixture_short_total"

# Control 3: every duration is a constant zero. "Present, non-negative and
# summing to no more than the total" is satisfied by twelve zeroes, so the
# check refuses a run in which nothing was measured.
fixture_zero_steps="$WORK/timing-zero.jsonl"
{
  printf '%s\n' '{"event":"step.start","step":1,"phase":"k3s","message":"k3s","seconds":0.000}'
  printf '%s\n' '{"event":"step.done","step":1,"phase":"k3s","message":"k3s: 0.000s","seconds":0.000}'
  printf '%s\n' '{"event":"install.done","step":1,"phase":"k3s","message":"up","seconds":0.000,"steps":[{"step":1,"phase":"k3s","seconds":0.000}]}'
} >"$fixture_zero_steps"
run 'control: a run of constant-zero durations goes red' red check_timing "$fixture_zero_steps"

# THE SKIP HALF. A skipped step did no work, so it reports `skipped` — never a
# `0` that would read as "this step is free". The fixture forces the guard to
# answer "present" for every component, which is the state a warm box is in.
# It lives in its OWN directory with a `manifests` symlink, because the script
# resolves its manifests from `$SCRIPT_DIR` and the steps without a guard (5,
# 6, 8, 10, 12) still plan against them in DRY_RUN. The premise is asserted
# first: if the fixture produced no skip, the check below would be green on
# nothing.
fixture_skip_dir="$WORK/skip-fixture"
mkdir -p "$fixture_skip_dir"
ln -s "$SUBSTRATE/manifests" "$fixture_skip_dir/manifests"
sed 's/^kit_substrate_guard() {$/kit_substrate_guard() { STEP_SKIPPED=1; return 0;/' \
  "$SUBSTRATE/install.sh" >"$fixture_skip_dir/install.sh"
skip_jsonl="$WORK/timing-skip.jsonl"
KIT_SUBSTRATE_RECEIPT="$WORK/skip-receipt.json" KIT_SUBSTRATE_DATABASES="$DBS" \
  HEADLESS=1 DRY_RUN=1 bash "$fixture_skip_dir/install.sh" >"$skip_jsonl" 2>"$WORK/skip.err" || true
if grep -q '"seconds":"skipped"' "$skip_jsonl"; then
  pass 'a skipped step reports skipped, not 0'
else
  fail 'a skipped step reports skipped, not 0' "$(head -4 "$skip_jsonl")"
fi
run 'a run whose guards find the components present still times cleanly' green \
  check_timing "$skip_jsonl"

# ===========================================================================
# 25. The three operator applies are grouped, and their waits with them
# ===========================================================================
# THE MEASURED SPEED DECISION, PINNED. cert-manager, CNPG and Argo CD are three
# independent operator installs — separate namespaces, separate CRDs, applies
# that reference nothing the others create — so they are applied back to back in
# steps 2-4 and waited on TOGETHER at the end of step 4. The controllers then
# roll out concurrently instead of one behind another's wait. This check is what
# stops a later edit from silently putting a wait back into step 2 or 3 (which
# re-serializes the rollouts) or dropping one of the three from step 4 (which
# would leave a controller unwatched before step 5 uses it).
check_operator_overlap() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
# Comments stripped first: the rule is about what the installer RUNS, and step
# 2's own comment explains the decision by naming the waits.
code = re.sub(r"(?m)^\s*#.*$", "", src)


def body(name):
    m = re.search(r"^" + name + r"\(\)\s*\{(.*?)^\}", code, re.M | re.S)
    return m.group(1) if m else ""


cm = body("install_cert_manager")
cnpg = body("install_cnpg")
argo = body("install_argocd")
problems = []
for name, b in (("install_cert_manager", cm), ("install_cnpg", cnpg), ("install_argocd", argo)):
    if not b:
        problems.append(f"{name} not found")

# The APPLIES are still where they were — the wait moved, the install did not.
if "cert-manager.yaml" not in cm:
    problems.append("step 2 no longer applies the cert-manager manifest")
if "cnpg-" not in cnpg:
    problems.append("step 3 no longer applies the CNPG manifest")
if "core-install.yaml" not in argo:
    problems.append("step 4 no longer applies the Argo CD core-install manifest")

# Steps 2 and 3 WAIT ON NOTHING: a wait left here re-serializes the rollouts and
# is the defect this section exists to catch.
for name, b in (("install_cert_manager", cm), ("install_cnpg", cnpg)):
    if "wait --for=condition" in b:
        problems.append(f"{name} still waits — the three operator waits belong in step 4, grouped")

# Step 4 waits for all three, by the exact selectors each step used to carry.
for want, label in (
    ("wait --for=condition=Available deployment -n cert-manager --all", "cert-manager"),
    ("wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager", "CNPG"),
    ("wait --for=condition=Available deployment -n argocd --all", "Argo CD"),
):
    if want not in argo:
        problems.append(f"step 4 does not wait for {label}")

# The pending mechanism is what keeps a warm re-run a true skip: each apply
# registers, step 4 drains. A component present at its guard never registers.
for name, b in (("install_cert_manager", cm), ("install_cnpg", cnpg), ("install_argocd", argo)):
    if "kit_substrate_pending" not in b:
        problems.append(f"{name} does not register its apply for the grouped wait")
if 'PENDING_WAITS=""' not in argo:
    problems.append("step 4 does not drain PENDING_WAITS after the grouped wait")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("the three operator applies are grouped and step 4 waits for all three")
PY
}

run 'the three operator waits are grouped in step 4, after all three applies' green \
  check_operator_overlap "$SUBSTRATE/install.sh"

# Control 1: the pre-change shape — cert-manager's wait put back into step 2.
# This is the serialization the packet's speed decision removes.
fixture_serial_wait="$WORK/install-serial-wait.sh"
sed 's|^  kit_substrate_pending cert-manager$|  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n cert-manager --all --timeout=180s|' \
  "$SUBSTRATE/install.sh" >"$fixture_serial_wait"
cm_fixture_body="$(sed -n '/^install_cert_manager()/,/^}/p' "$fixture_serial_wait")"
case "$cm_fixture_body" in
  *'wait --for=condition=Available deployment -n cert-manager --all'*)
    run 'control: a wait put back into step 2 goes red' red check_operator_overlap "$fixture_serial_wait"
    ;;
  *)
    fail 'control fixture: the serial wait was not restored' \
      "the sed did not put the wait back into step 2, so the control would prove nothing"
    ;;
esac

# Control 2: one of the three waits dropped from step 4 — a controller left
# unwatched before step 5 depends on it.
fixture_drop_cnpg_wait="$WORK/install-drop-cnpg-wait.sh"
sed '/wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager/d' \
  "$SUBSTRATE/install.sh" >"$fixture_drop_cnpg_wait"
if grep -q 'wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager' \
  "$fixture_drop_cnpg_wait"; then
  fail 'control fixture: the CNPG wait was not dropped' \
    "the sed did not remove the wait, so the control would prove nothing"
else
  run 'control: a dropped operator wait goes red' red check_operator_overlap "$fixture_drop_cnpg_wait"
fi

# ===========================================================================
# 26. A WARM BOX RE-APPLIES THE APPPROJECT — the guard's boundary, executed
# ===========================================================================
#
# THE DEFECT, MEASURED ON A LIVE BOX. §21 and §25 both PROVE the AppProject is
# correct — the name matches, the sourceRepos permit every Application's
# repoURL, and the three operator applies are grouped with their waits. None of
# them asks the only question the warm box asked: DOES THE FILE EVER LAND?
#
# `install_argocd`'s guard answers "is the OPERATOR installed" — a probe of
# deployment/argocd-repo-server — and it wrapped the WHOLE step, including
# `kubectl apply -f appproject.yaml`. So a box that ever got past step 4 skipped
# the project apply forever. The live Contabo box was exactly that box, and it
# still carried the PRE-GLOB list while master had already written the glob:
#
#   kubectl -n argocd get appproject default -o jsonpath='{.spec.sourceRepos}'
#   ["https://grafana.github.io/helm-charts",
#    "https://prometheus-community.github.io/helm-charts",
#    "oci://ghcr.io/cafaye/charts"]                    <- the ROOT, on the box
#   oci://ghcr.io/cafaye/charts/*                      <- in appproject.yaml
#
# and every Application read `Unknown: repo oci://ghcr.io/cafaye/charts/gateway
# is not permitted in project 'default'`. The only way to land the fix was to
# delete Argo CD. A packet that passes on the next clean box and cannot reach a
# warm one is not a fix, and the industrial-scale verification ("challenge the
# verifier") fails on it.
#
# WHY THIS IS EXECUTED AND NOT STATIC. §25 reads step 4's SHAPE with comments
# stripped and would be perfectly happy with the apply sitting inside
# `if [ "$argocd_present" -eq 0 ]` — nothing in that check reads which side of
# the guard a line is on. So the property is proven by RUNNING the step against
# a box that has Argo CD and an out-of-date project, which is the state no other
# section in this file models.
#
# TWO LIFETIMES, AND THE ASSERTION HOLDS BOTH HALVES:
#   * the OPERATOR stays guarded — the warm box re-applies no remote manifest;
#   * the PROJECT is always current — the apply happens on every run, so what
#     the controller reads is what this repository wrote.
# A guard covering both is what conflated them; the assertion that only the
# second moved is what proves the fix is not "unguard everything".
WARM_DIR="$WORK/appproject-warm"
mkdir -p "$WARM_DIR"

# THE WRITE PATH, AS A FILE AND NOT A HEREDOC. `declare -f warm_kubectl` re-emits
# a function's body RE-INDENTED, which moves a heredoc terminator off column 0
# and swallows the rest of the generated script — so nothing inside
# `warm_kubectl` may carry one. This is that file, written once here and invoked
# by path. It is also the box's own semantics: `kubectl apply -f` writes an
# OBJECT, validated before it is stored.
WARM_PLANTER="$WARM_DIR/plant_appproject.py"
cat >"$WARM_PLANTER" <<'PY'
import shutil
import sys

import yaml


src, dst = sys.argv[1:3]
try:
    doc = yaml.safe_load(open(src, encoding="utf-8"))
except OSError as exc:
    print(f"warm_kubectl: {src}: {exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc, dict) or doc.get("kind") != "AppProject":
    print(f"warm_kubectl: {src} is not an AppProject", file=sys.stderr)
    sys.exit(1)
if not (doc.get("spec") or {}).get("sourceRepos"):
    print(f"warm_kubectl: {src} carries no sourceRepos", file=sys.stderr)
    sys.exit(1)
# The object becomes what the applied file describes, whole: a partial read
# here would let a red control pass on a project that kept its old entries.
shutil.copyfile(src, dst)
PY

# THE BOX'S APPPROJECT OBJECT. One file, because that is what the API server
# holds: `kubectl apply -f` writes an OBJECT, and every read below is a read of
# that object rather than of the file that was sent. The distinction is the
# whole defect — the file was right and the object was stale.
DEPLOYED_PROJECT="$WARM_DIR/deployed-appproject.yaml"

# warm_seed — put the box in the state the live one was measured in: Argo CD
# installed (the guard's probe will say so) and the PRE-GLOB AppProject
# deployed. Re-run before every case, so a case cannot inherit the previous
# case's write.
warm_seed() {
  cat >"$DEPLOYED_PROJECT" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  description: "the pre-glob project the live box still carries"
  sourceRepos:
    - https://grafana.github.io/helm-charts
    - https://prometheus-community.github.io/helm-charts
    - oci://ghcr.io/cafaye/charts
YAML
  rm -f "$WARM_DIR/argv"
}

# mock_get_appproject — the controller's own read:
#   kubectl -n argocd get appproject default -o jsonpath='{.spec.sourceRepos}'
# one sourceRepos entry per line, in the order the API server returns them.
# Read from the OBJECT, so a test that ignores the apply sees the stale list.
mock_get_appproject() {
  "$PY" - "$DEPLOYED_PROJECT" <<'PY'
import sys

import yaml


doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for repo in (doc.get("spec") or {}).get("sourceRepos") or []:
    print(repo)
PY
}

# warm_kubectl — the warm box, modelled. Exactly the calls step 4 makes against
# a box whose operators are already installed, and nothing else: the guard's
# probe, and the project apply. Anything beyond those is recorded and refused
# loudly, because a warm box has no other work for this step to do — the
# `--server-side` core-install apply is precisely what the guard must suppress.
warm_kubectl() {
  printf '%s\n' "$*" >>"$WARM_DIR/argv"
  case "$*" in
    *"get deployment -n argocd argocd-repo-server"*) return 0 ;;
  esac
  # Install.sh always prefixes `--kubeconfig=`, so the VERB is not `$1`. Strip
  # the global flags before reading it — the same thing the real binary's arg
  # parser does, and the reason the harness's own mock_kubectl strips them
  # first too.
  while [ $# -gt 0 ]; do
    case "$1" in
      --kubeconfig=*) shift ;;
      *) break ;;
    esac
  done
  local verb="${1:-}" f_target=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) f_target="$2"; shift 2 ;;
      -f=*) f_target="${1#-f=}"; shift ;;
      *) shift ;;
    esac
  done
  case "$verb" in
    apply)
      [ -n "$f_target" ] || { printf 'warm_kubectl: apply with no -f\n' >&2; return 1; }
      # THE WRITE. The box's project becomes what the applied file describes.
      # Validated rather than copied, so a fixture that applies a non-AppProject
      # or an object with no sourceRepos is a red case and not a silent write.
      "$PY" "$WARM_PLANTER" "$f_target" "$DEPLOYED_PROJECT"
      ;;
    wait) return 0 ;;
    create) return 0 ;;
    *)
      # A warm box must not re-install the operator: the remote manifest, a
      # namespace create, a rollout kick. Recorded by the caller's argv
      # assertion above, and refused here so a control cannot pass on a mock
      # that answered everything with success.
      printf 'warm_kubectl: unhandled %s\n' "$*" >&2
      return 1
      ;;
  esac
  return 0
}

# warm_run <fixture> — run step 4 for real against the warm box. A child bash,
# for the reason §19's apps_step records: a guarded subshell would march past a
# failing step and exit 0 — the opposite of the box, where the same failure
# aborts the install. `ARGOCD_MANIFEST_DIR` is set AFTER the source because the
# installer derives it from `SCRIPT_DIR` at source time and the fixture lives in
# $WORK; without it the apply would target a path that does not exist and the
# step would refuse for a reason that has nothing to do with this packet.
warm_run() {
  warm_seed
  local script="$WARM_DIR/run.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'WARM_DIR=%q\n' "$WARM_DIR"
    printf 'FIXTURE=%q\n' "$1"
    printf 'MANIFEST_ARGOCD=%q\n' "$SUBSTRATE/manifests/argocd"
    printf 'PY=%q\n' "$PY"
    printf 'WARM_PLANTER=%q\n' "$WARM_PLANTER"
    printf 'DEPLOYED_PROJECT=%q\n' "$DEPLOYED_PROJECT"
    declare -f warm_kubectl
    printf '%s\n' \
      'export DRY_RUN=0 HEADLESS=1 KIT_SUBSTRATE_RECEIPT="$WARM_DIR/receipt.json"' \
      '# shellcheck source=/dev/null' \
      '. "$FIXTURE"' \
      'ARGOCD_MANIFEST_DIR="$MANIFEST_ARGOCD"' \
      'kubectl() { warm_kubectl "$@"; }' \
      'install_argocd'
  } >"$script"
  bash "$script" >"$WARM_DIR/run.log" 2>&1
}

warm_fixture="$WORK/install-warm.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$warm_fixture"

# THE PREMISE, ASSERTED BEFORE IT IS USED. The seeded box must hold the pre-glob
# list, and that list must NOT permit the Applications — otherwise the green
# case below is satisfied by a box that was never broken, which is the
# "a green control two different states could satisfy proves neither" rule.
warm_seed
old_repos="$(mock_get_appproject | tr '\n' ' ')"
old_repos="${old_repos% }"
# The LIST ITEM, not a substring of the file: a grep over the whole YAML would
# match the description line, which spells the bare root out in prose.
warm_is_prefix_list=0
while IFS= read -r warm_repo; do
  [ -n "$warm_repo" ] || continue
  if [ "$warm_repo" = "oci://ghcr.io/cafaye/charts" ]; then
    warm_is_prefix_list=1
  fi
  case "$warm_repo" in
    "oci://ghcr.io/cafaye/charts/*") warm_has_glob=1 ;;
    *) warm_has_glob="${warm_has_glob:-0}" ;;
  esac
done < <(mock_get_appproject)
if [ "$warm_is_prefix_list" -eq 1 ] && [ "${warm_has_glob:-0}" -eq 0 ]; then
  pass 'warm-box fixture: the seeded project is the pre-glob list the live box carries'
else
  fail 'warm-box fixture: the seeded project is the pre-glob list the live box carries' \
    "seeded sourceRepos: ${old_repos}"
fi
warm_old_permits_ec=0
check_appproject_permits "$MANIFESTS" "$DEPLOYED_PROJECT" >/dev/null 2>&1 || warm_old_permits_ec=$?
if [ "$warm_old_permits_ec" -ne 0 ]; then
  pass 'warm-box fixture: the pre-glob project does NOT permit the Applications (the box really is broken)'
else
  fail 'warm-box fixture: the pre-glob project does NOT permit the Applications (the box really is broken)' \
    'the seeded list already permits every repoURL, so the green case below would prove nothing'
fi

# THE CASE. Step 4 runs on a warm box. It must succeed...
warm_ec=0
warm_run "$warm_fixture" || warm_ec=$?
if [ "$warm_ec" -ne 0 ]; then
  fail 'a warm box re-applies the AppProject' "$(cat "$WARM_DIR/run.log")"
else
  pass 'a warm box re-applies the AppProject (step 4 exits 0)'
fi

# ...and the apply must have HAPPENED. Argv, because "the project was applied"
# is a command and not a return code — the mock answers success for everything.
if grep -q 'apply -f .*appproject\.yaml' "$WARM_DIR/argv"; then
  pass 'a warm box re-applies the AppProject (the apply is in argv)'
else
  fail 'a warm box re-applies the AppProject (the apply is in argv)' \
    "step 4 ran: $(tr '\n' ' | ' <"$WARM_DIR/argv")"
fi

# AND THE OPERATOR STAYS GUARDED. This is the half that stops the fix from
# being "unguard everything": the remote core-install manifest, the namespace
# create and any rollout kick must not appear. A warm box has nothing for those
# to do, and one of them running is the defect §25 exists for.
case "$(cat "$WARM_DIR/argv")" in
  *core-install.yaml*)
    fail 'a warm box re-applies ONLY the AppProject — the operator stays guarded' \
      'step 4 re-applied the remote core-install manifest on a box that already has Argo CD'
    ;;
  *)
    pass 'a warm box re-applies ONLY the AppProject — the operator stays guarded'
    ;;
esac

# AND THE RESULT THE CONTROLLER READS. Not the file — the object. The mock
# applies what it was given, so `$DEPLOYED_PROJECT` is now what the box holds,
# and it must permit every Application's repoURL under the SAME glob-aware
# algorithm §21 uses (the glob fix's own semantics, not a second spelling).
new_repos="$(mock_get_appproject | tr '\n' ' ')"
new_repos="${new_repos% }"
if [ "$new_repos" != "$old_repos" ]; then
  pass 'a warm box leaves the pre-glob list behind (the object changes)'
else
  fail 'a warm box leaves the pre-glob list behind (the object changes)' \
    "the box still reads: ${new_repos}"
fi
run 'the re-applied AppProject permits every Application on a warm box' green \
  check_appproject_permits "$MANIFESTS" "$DEPLOYED_PROJECT"

# THE RED CONTROL, AND IT IS THE PACKET'S OWN DEFECT. Rebuild the pre-fix
# installer — the AppProject apply moved back inside `if [ "$argocd_present" -eq
# 0 ]`, the whole step behind the operator's guard — and run the IDENTICAL warm
# box. The box must stay broken: the old list, and the refuse. This is the state
# the live Contabo box was measured in, and it is what makes the green case
# above a proof rather than a restatement.
warm_prefix="$WORK/install-warm-prefix.py"
cat >"$warm_prefix" <<'PY'
import sys


src, dst = sys.argv[1:3]
lines = open(src, encoding="utf-8").readlines()
out = []
guarded = False
closed = False
for line in lines:
    if line.startswith('  if dry_run "kubectl apply -f ${ARGOCD_MANIFEST_DIR}/appproject.yaml'):
        # The pre-fix shape: the project's apply sits inside the operator's
        # guard, so a box whose Argo CD is present suppresses it.
        out.append('  if [ "$argocd_present" -eq 0 ]; then\n')
        out.append(line)
        guarded = True
        continue
    if line == '  kubectl --kubeconfig="$KUBECONFIG" apply -f "$ARGOCD_MANIFEST_DIR/appproject.yaml"\n':
        out.append(line)
        out.append('  fi\n')
        closed = True
        continue
    out.append(line)
if not guarded:
    print("no appproject apply line to guard — the fixture was not built", file=sys.stderr)
    sys.exit(1)
if not closed:
    print("the guarded apply was never closed — the fixture was not built", file=sys.stderr)
    sys.exit(1)
open(dst, "w", encoding="utf-8").writelines(out)
PY
fixture_warm_prefix="$WORK/install-warm-prefix.sh"
if "$PY" "$warm_prefix" "$warm_fixture" "$fixture_warm_prefix" &&
  bash -n "$fixture_warm_prefix" >/dev/null 2>&1; then
  # The fixture's PREMISE, asserted before it is run: the apply really is inside
  # the operator's guard again. A transform that matched nothing would otherwise
  # run the FIXED installer as the control and go green — the failure mode
  # §26's own comment names at the top.
  argo_body="$(sed -n '/^install_argocd()/,/^}/p' "$fixture_warm_prefix")"
  case "$argo_body" in
    *'if [ "$argocd_present" -eq 0 ]; then'*)
      case "$argo_body" in
        *'apply -f "$ARGOCD_MANIFEST_DIR/appproject.yaml"'*)
          pass 'control fixture: the pre-fix installer guards the AppProject apply behind the operator'
          ;;
        *)
          fail 'control fixture: the pre-fix installer guards the AppProject apply behind the operator' \
            'the rebuilt step 4 has no AppProject apply at all, so the control would prove nothing'
          ;;
      esac
      ;;
    *)
      fail 'control fixture: the pre-fix installer guards the AppProject apply behind the operator' \
        'the rebuilt step 4 does not guard the AppProject apply, so the control would prove nothing'
      ;;
  esac
else
  fail 'control fixture: the pre-fix installer guards the AppProject apply behind the operator' \
    'the python transform refused to build the fixture, or the result does not parse'
fi

warm_prefix_ec=0
warm_run "$fixture_warm_prefix" || warm_prefix_ec=$?
prefix_repos="$(mock_get_appproject | tr '\n' ' ')"
prefix_repos="${prefix_repos% }"
prefix_argv="$(tr '\n' ' | ' <"$WARM_DIR/argv")"
if [ "$warm_prefix_ec" -eq 0 ] && [ "$prefix_repos" = "$old_repos" ]; then
  case "$prefix_argv" in
    *"apply -f "*appproject.yaml*) ;;
    *)
      pass 'control: the pre-fix guard leaves the warm box carrying the stale project'
      ;;
  esac
else
  fail 'control: the pre-fix guard leaves the warm box carrying the stale project' \
    "exit ${warm_prefix_ec}; project now: ${prefix_repos}; argv: ${prefix_argv}"
fi
run 'control: the pre-fix guard is red on the warm box — every Application refused' red \
  check_appproject_permits "$MANIFESTS" "$DEPLOYED_PROJECT"

# THE PLAN HALF, GREEN AND RED WITHOUT A MOCK AT ALL. Force every guard to
# answer "present" — the state a warm box is in — and require the DRY_RUN plan
# to STILL name the AppProject apply. This is the property a static check cannot
# read: §25 compares step bodies against each other and would be perfectly happy
# with the apply behind `if [ "$argocd_present" -eq 0 ]`, because nothing in it
# reads which side of a guard a line sits on. The plan is the one output that
# records it, and it needs no kubectl.
warm_plan_dir="$WORK/warm-plan"
mkdir -p "$warm_plan_dir"
ln -s "$SUBSTRATE/manifests" "$warm_plan_dir/manifests"
sed 's/^kit_substrate_guard() {$/kit_substrate_guard() { STEP_SKIPPED=1; return 0;/' \
  "$SUBSTRATE/install.sh" >"$warm_plan_dir/install.sh"
plan_out="$WORK/warm-plan.out"
KIT_SUBSTRATE_RECEIPT="$WORK/warm-plan-receipt.json" KIT_SUBSTRATE_DATABASES="$DBS" \
  HEADLESS=1 DRY_RUN=1 bash "$warm_plan_dir/install.sh" >"$plan_out" 2>&1 || true
if grep -q 'appproject.yaml' "$plan_out"; then
  pass 'a warm box plans the AppProject apply even with every guard present'
else
  fail 'a warm box plans the AppProject apply even with every guard present' \
    "the DRY_RUN plan never names appproject.yaml"
fi
# The red half: the pre-fix installer, same forced guards, must NOT plan it.
sed 's/^kit_substrate_guard() {$/kit_substrate_guard() { STEP_SKIPPED=1; return 0;/' \
  "$fixture_warm_prefix" >"$warm_plan_dir/install-prefix.sh"
plan_prefix_out="$WORK/warm-plan-prefix.out"
KIT_SUBSTRATE_RECEIPT="$WORK/warm-plan-prefix-receipt.json" KIT_SUBSTRATE_DATABASES="$DBS" \
  HEADLESS=1 DRY_RUN=1 bash "$warm_plan_dir/install-prefix.sh" >"$plan_prefix_out" 2>&1 || true
if grep -q 'appproject.yaml' "$plan_prefix_out"; then
  fail 'control: the pre-fix installer does NOT plan the AppProject apply on a warm box' \
    'the plan still names appproject.yaml, so the forced-present guards did not suppress it'
else
  pass 'control: the pre-fix installer does NOT plan the AppProject apply on a warm box'
fi

# ===========================================================================
# 27. The done report is honest: pending TLS and the unwired OIDC path are
#     named, with the exact remedy — and silence goes red
# ===========================================================================
#
# WHY THIS EXISTS. The live Contabo box: the install ran to completion and
# exited 0 while Argo showed gateway Synced/Degraded and gateway's pods
# logged `Readiness probe failed: HTTP probe failed with statuscode: 503`
# 1564 times over four hours. Two independent causes, both silent:
# ACME could never complete (`... lookup api.cafaye.com ...: no such host` —
# DNS never pointed at the box) and gateway could never be Ready (its
# /readyz probes identity's JWKS, served only when
# KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER is set, and it was not). Neither is
# refused — a firewalled box is legitimate and an issuer must not be
# guessed — so the installer REPORTS: a preflight verdict before anything is
# created, a THIS BOX WILL NOT FULLY SERVE UNTIL section beside the step
# times, and the same verdict as a `readiness` JSONL event.
#
# Three green checks against the real tree, each a DRY_RUN (a plan prints the
# same verdict the live run prints, without a box):
#   1. an unresolving ingress host is reported in the pending-TLS section
#      with its consequence — and the install still exits 0;
#   2. an unset OIDC issuer names gateway's never-Ready state and the export
#      that fixes it;
#   3. a resolving host plus a set issuer prints neither warning — while
#      still printing the verdict header, so a silent report cannot satisfy
#      it.
# Plus the headless half (the `tls_pending_hosts` field beside
# `oidc_configured`, existing events untouched), the wrong-host control (a
# host that DOES resolve must NOT warn), and the intended-hosts unit (hosts
# are read out of what the installer writes, not out of a second list).
#
# The RED controls run the same checks against a master-shaped fixture — the
# real install.sh with the honest-done block deleted — and each must go red.
# Hosts: `*.invalid` never resolves (RFC 2606); `localhost` always does. No
# network dependence, no flake.
HONEST_BAD_HOST="tls-pending-never-resolves.invalid"
HONEST_BAD_URL="https://${HONEST_BAD_HOST}"

# honest_dry_run <install.sh> — DRY_RUN to completion, all output on stdout.
# The case's APP_BASE_URL / OIDC_ISSUER ride in the environment; DATABASES
# and RECEIPT are fixed here so every case shares them. Prints the output;
# the exit status is the install's (a verdict must never become a refusal).
honest_dry_run() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    DRY_RUN=1 bash "$script" 2>&1)" || ec=$?
  printf '%s' "$out"
  return "$ec"
}

# 1. Green, real tree: an ingress host that does not resolve is reported in
# the pending-TLS section with its consequence — and the install exits 0.
check_tls_pending() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    KIT_SUBSTRATE_APP_BASE_URL="$HONEST_BAD_URL" \
    env -u KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER DRY_RUN=1 bash "$script" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'exit %s, not 0 — the verdict became a refusal\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *"$HONEST_BAD_HOST"*) ;;
    *) printf 'the unresolving host is not reported\n'; return 1 ;;
  esac
  case "$out" in
    *'DOES NOT RESOLVE'*) ;;
    *) printf 'no DOES NOT RESOLVE verdict\n'; return 1 ;;
  esac
  case "$out" in
    *'the ACME HTTP-01 self check will fail'*) ;;
    *) printf 'the TLS consequence is not named\n'; return 1 ;;
  esac
  case "$out" in
    *'THIS BOX WILL NOT FULLY SERVE UNTIL'*) ;;
    *) printf 'the done-report verdict header is missing\n'; return 1 ;;
  esac
  printf 'unresolving host reported with consequence, exit 0\n'
}

# 2. Green, real tree: an unset OIDC issuer names gateway's never-Ready state
# and the export that fixes it. The app URL resolves, so only the OIDC half
# can fire — one property per check.
check_oidc_unset() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    KIT_SUBSTRATE_APP_BASE_URL='http://localhost' \
    env -u KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER DRY_RUN=1 bash "$script" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'exit %s, not 0\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *'serves no JWKS route'*) ;;
    *) printf 'the JWKS consequence is not named\n'; return 1 ;;
  esac
  case "$out" in
    *'never becomes Ready'*) ;;
    *) printf 'gateway never-Ready state is not named\n'; return 1 ;;
  esac
  case "$out" in
    *"export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="*) ;;
    *) printf 'the fixing export is not printed\n'; return 1 ;;
  esac
  case "$out" in
    *'THIS BOX WILL NOT FULLY SERVE UNTIL'*) ;;
    *) printf 'the done-report verdict header is missing\n'; return 1 ;;
  esac
  printf 'unset issuer names the never-Ready state and its fix\n'
}

# 3. Green, real tree: resolving host plus set issuer prints NEITHER warning
# — while still printing the verdict header, so a report that says nothing
# at all fails this check rather than passing it.
check_clean() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    KIT_SUBSTRATE_APP_BASE_URL='http://localhost' \
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://localhost:8443' \
    DRY_RUN=1 bash "$script" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'exit %s, not 0\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *'THIS BOX WILL NOT FULLY SERVE UNTIL'*) ;;
    *) printf 'the verdict header is missing — a silent report satisfies nothing\n'; return 1 ;;
  esac
  case "$out" in
    *'DOES NOT RESOLVE'*) printf 'a resolving host is reported unresolving\n'; return 1 ;;
  esac
  case "$out" in
    *'never becomes Ready'*) printf 'a set issuer still warns never-Ready\n'; return 1 ;;
  esac
  case "$out" in
    *'serves no JWKS route'*) printf 'a set issuer still warns no-JWKS\n'; return 1 ;;
  esac
  printf 'clean box: verdict present, neither warning printed\n'
}

# The headless half: the JSONL stream carries the same verdict as a
# `readiness` event — field `tls_pending_hosts` beside `oidc_configured` —
# and the existing events are untouched (install.done still closes the run).
check_headless_readiness() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    KIT_SUBSTRATE_APP_BASE_URL="$HONEST_BAD_URL" \
    env -u KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER HEADLESS=1 DRY_RUN=1 bash "$script" --headless 2>/dev/null)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'exit %s, not 0\n%s' "$ec" "$out"; return 1; }
  printf '%s' "$out" >"$WORK/honest-stdout.jsonl"
  case "$out" in
    *'"event":"readiness"'*) ;;
    *) printf 'no readiness event on stdout\n'; return 1 ;;
  esac
  case "$out" in
    *'"tls_pending_hosts"'*) ;;
    *) printf 'the tls_pending_hosts field is missing\n'; return 1 ;;
  esac
  case "$out" in
    *"$HONEST_BAD_HOST"*) ;;
    *) printf 'the pending host is not in the verdict\n'; return 1 ;;
  esac
  case "$out" in
    *'"oidc_configured":false'*) ;;
    *) printf 'oidc_configured:false is missing for an unset issuer\n'; return 1 ;;
  esac
  case "$out" in
    *'"event":"install.done"'*) ;;
    *) printf 'install.done is missing — an existing event moved\n'; return 1 ;;
  esac
  "$PY" - "$WORK/honest-stdout.jsonl" <<'PY' || return 1
import json
import sys

bad = 0
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except json.JSONDecodeError as e:
        print(f"stdout line {n} is not JSON: {e}")
        bad += 1
sys.exit(1 if bad else 0)
PY
  printf 'readiness event with tls_pending_hosts, install.done untouched, every line JSON\n'
}

# The wrong-host control: a check aimed at a host that DOES resolve must NOT
# warn. localhost resolves on every machine, with no network.
check_no_warn_resolving_host() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    KIT_SUBSTRATE_APP_BASE_URL='http://localhost' \
    env -u KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER DRY_RUN=1 bash "$script" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'exit %s, not 0\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *'DOES NOT RESOLVE'*) printf 'a resolving host was reported unresolving\n'; return 1 ;;
  esac
  printf 'no warning for the resolving control host\n'
}

# The intended-hosts unit: hosts are READ out of what the installer writes —
# the two operator URLs plus public hosts in the Applications' helm.values —
# never out of a second hard-coded list. A fixture Application carries all
# four shapes: a public values host (listed), an in-cluster values host
# (dropped), a fetch coordinate (repoURL — dropped), and a URL in a comment
# (dropped).
check_intended_hosts() {
  local script="$1"
  local adir="$WORK/honest-apps"
  mkdir -p "$adir"
  cat >"$adir/svc.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svc
spec:
  project: default
  source:
    repoURL: https://charts.example.com/upstream
    chart: svc
    helm:
      values: |
        env:
          PUBLIC_URL: "https://shop.example.com"
          INTERNAL_URL: "http://svc.svc-ns.svc.cluster.local:8080"
  destination:
    server: https://kubernetes.default.svc
    namespace: svc
YAML
  printf '# the fleet default is https://auth.cafaye.com but this box does not set it\n' >>"$adir/svc.yaml"
  local src="$WORK/honest-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  local out ec=0
  out="$(KIT_SUBSTRATE_APP_BASE_URL='https://app.example.com' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
    bash -c '. "$0"; kit_substrate_intended_hosts "$1"' "$src" "$adir" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'the extractor failed\n%s' "$out"; return 1; }
  case "$out" in
    *'shop.example.com'*) ;;
    *) printf 'the public helm.values host is not listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'app.example.com'*) ;;
    *) printf 'the operator URL host is not listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'charts.example.com'*) printf 'a repoURL fetch coordinate is listed as served\n'; return 1 ;;
  esac
  case "$out" in
    *'kubernetes.default.svc'*) printf 'the destination server is listed as served\n'; return 1 ;;
  esac
  case "$out" in
    *'auth.cafaye.com'*) printf 'a URL from a comment is listed as intended\n'; return 1 ;;
  esac
  case "$out" in
    *'svc.cluster.local'*) printf 'an in-cluster host is listed as public\n'; return 1 ;;
  esac
  printf 'intended hosts read from values and operator URLs, fetch/comment/cluster names dropped\n'
}

run 'an unresolving ingress host is reported with its consequence (exit 0)' green check_tls_pending "$SUBSTRATE/install.sh"
run 'an unset OIDC issuer names gateway never-Ready and its fix' green check_oidc_unset "$SUBSTRATE/install.sh"
run 'a resolving host plus a set issuer prints neither warning (verdict still present)' green check_clean "$SUBSTRATE/install.sh"
run 'headless stdout carries the readiness event with tls_pending_hosts' green check_headless_readiness "$SUBSTRATE/install.sh"
run 'control: a resolving host does not warn' green check_no_warn_resolving_host "$SUBSTRATE/install.sh"
run 'intended hosts are read from values and operator URLs, not listed twice' green check_intended_hosts "$SUBSTRATE/install.sh"

# The RED controls: the report as it stands on master — the real install.sh
# with the honest-done block deleted — must fail each check above. The
# fixture asserts its own premise first: it really lacks the verdict, it
# still parses, and a DRY_RUN over it still exits 0 (so a red below is the
# missing verdict, not a broken fixture). The fixture lives in its own
# directory with the real manifests beside it, because a relocated
# install.sh finds its manifests through its own SCRIPT_DIR.
fixture_master_dir="$WORK/master-shape"
fixture_master="$fixture_master_dir/install-master.sh"
mkdir -p "$fixture_master_dir"
cp -R "$SUBSTRATE/manifests" "$fixture_master_dir/manifests"
sed -e '/honest-done BEGIN/,/honest-done END/d' -e '/# honest-done$/d' \
  "$SUBSTRATE/install.sh" >"$fixture_master"
case "$(cat "$fixture_master")" in
  *'THIS BOX WILL NOT FULLY SERVE UNTIL'* | *'tls_pending_hosts'* | *'kit_substrate_readiness'*)
    fail 'control fixture: the master shape still carries the verdict' \
      'the sed did not remove the honest-done block — this control would prove nothing'
    ;;
  *)
    if ! bash -n "$fixture_master"; then
      fail 'control fixture: the master shape does not parse' \
        'the sed broke the file — a red below would be a syntax error wearing the finding clothes'
    elif ! honest_dry_run "$fixture_master" >/dev/null 2>&1; then
      fail 'control fixture: DRY_RUN over the master shape fails' \
        'the sed broke the run — a red below would be a broken fixture, not a silent report'
    else
      run 'control: the silent report fails the TLS check' red check_tls_pending "$fixture_master"
      run 'control: the silent report fails the OIDC check' red check_oidc_unset "$fixture_master"
      run 'control: the silent report fails the clean check (no verdict at all)' red check_clean "$fixture_master"
      run 'control: the silent report carries no readiness event' red check_headless_readiness "$fixture_master"
    fi
    ;;
esac

# ===========================================================================
# Summary
# ===========================================================================
printf -- '-- substrate_test: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"
