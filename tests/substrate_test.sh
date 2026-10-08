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
#   no image floats on `latest`, and no secret is a literal in the tree.
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

# The ten steps, in order. The markers are `[1/10]` … `[10/10]`; the check reads
# them out of the output in the order they appear and compares against the
# expected sequence, so a script that printed them out of order — or skipped
# one — would go red here rather than passing on the presence of all ten.
# The `|| true` is load-bearing: with no `[n/10]` markers printed yet, grep
# exits 1, and under `set -o pipefail` a failing command substitution would
# take the harness down before the status is ever read — the same shape the
# `run` helper's comment describes four lines below.
found="$(printf '%s\n' "$dry_run_out" | grep -o '\[[0-9][0-9]*/10\]' | tr -d '[]' | cut -d/ -f1 | tr '\n' ' ' || true)"
found="${found% }"
if [ "$found" = "1 2 3 4 5 6 7 8 9 10" ]; then
  pass 'DRY_RUN prints the ten steps in order'
else
  fail 'DRY_RUN prints the ten steps in order' "found step sequence: '${found}'"
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
sourced_vars="KIT_SUBSTRATE_PULL_SECRET KIT_SUBSTRATE_ACME_EMAIL KIT_SUBSTRATE_DATABASES KIT_SUBSTRATE_POSTGRES_EXTENSIONS KIT_SUBSTRATE_SMTP_ADAPTER KIT_SUBSTRATE_SMTP_HOST KIT_SUBSTRATE_SMTP_PORT KIT_SUBSTRATE_SMTP_USERNAME KIT_SUBSTRATE_SMTP_PASSWORD KIT_SUBSTRATE_COURIER_IDENTITY_TOKEN KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET KIT_SUBSTRATE_MAIL_FROM KIT_SUBSTRATE_MAIL_FROM_NAME KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY_ID KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY KIT_SUBSTRATE_IDENTITY_COURIER_TOKEN"
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
# Conditional keys: set only when the operator sets the surface (identity's
# OIDC/OAuth block, its courier credential, courier's mail-from). They
# are deliberately UNRECORDED — absent is a valid reduced surface, and the
# record lists the keys every install creates. MFA_ENCRYPTION_KEY is NOT
# conditional: the installer generates it on first creation, so every
# install creates it and the record must name it.
conditional = {
    "COURIER_TOKEN",
    "OIDC_SIGNING_KEY",
    "OIDC_SIGNING_KEY_ID",
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
        if f"--from-literal={key}=" not in code:
            problems.append(f"{secret} records {key} but no --from-literal sets it")
created = set(re.findall(r"create secret generic (\S+)", code))
for secret in created:
    if secret not in recorded and secret.startswith(("identity", "gateway", "courier", "parlor")):
        problems.append(f"{secret} is created but not recorded")
for key in set(re.findall(r"--from-literal=([A-Z_]+)=", code)):
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


need("TOTAL=10", "TOTAL is not 10 — step 10 (NATS) widens the plan and the DRY_RUN order check with it")
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
  while [ $# -gt 0 ]; do
    case "$1" in
      --kubeconfig=*) shift ;;
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
      local name="${1:-}"
      shift || true
      local ns=""
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
      cat >/dev/null
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
# elsewhere; here they only open the gate to the secrets half.
mfa_smtp_env() {
  export DRY_RUN=0
  export KIT_SUBSTRATE_SMTP_HOST="relay.example.com"
  export KIT_SUBSTRATE_SMTP_USERNAME="relay-user"
  export KIT_SUBSTRATE_SMTP_PASSWORD="relay-pass"
  export KIT_SUBSTRATE_COURIER_IDENTITY_TOKEN="identity-minted-token"
  export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="provider-signing-secret"
  # Empty, not unset: the sourced installer runs under `set -u` and reads
  # these unconditionally, so an unset variable is a fatal rather than an
  # absent surface. Empty is the absent surface the installer documents.
  export KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY=""
  export KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY_ID=""
  export KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_IDENTITY_COURIER_TOKEN=""
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
# Summary
# ===========================================================================
printf -- '-- substrate_test: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"
