#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBSTRATE="$ROOT/templates/substrate"
MANIFESTS="$SUBSTRATE/manifests/applications"
TLS_DIR="$SUBSTRATE/manifests/tls"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "substrate_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
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

run 'install.sh parses (bash -n)' green bash -n "$SUBSTRATE/install.sh"

DBS="identity,gateway,courier,parlor,billing"
dry_run_out="$(KIT_SUBSTRATE_DATABASES="$DBS" DRY_RUN=1 bash "$SUBSTRATE/install.sh" 2>&1)" && dry_run_ec=0 || dry_run_ec=$?

if [ "$dry_run_ec" -ne 0 ]; then
  fail 'DRY_RUN=1 runs to completion' "$dry_run_out"
else
  pass 'DRY_RUN=1 runs to completion'
fi

found="$(printf '%s\n' "$dry_run_out" | grep -o '\[[0-9][0-9]*/13\]' | tr -d '[]' | cut -d/ -f1 | tr '\n' ' ' || true)"
found="${found% }"
if [ "$found" = "1 2 3 4 5 6 7 8 9 10 11 12 13" ]; then
  pass 'DRY_RUN prints the thirteen steps in order'
else
  fail 'DRY_RUN prints the thirteen steps in order' "found step sequence: '${found}'"
fi

dry_count="$(printf '%s\n' "$dry_run_out" | grep -c 'DRY_RUN:' || true)"
if [ "$dry_count" -ge 10 ]; then
  pass 'DRY_RUN prints a per-step action for every step'
else
  fail 'DRY_RUN prints a per-step action for every step' "found ${dry_count} DRY_RUN action(s), expected >= 9"
fi

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

fixture_latest="$WORK/install-latest.sh"
sed 's/^K3S_VERSION="v1.37.1+k3s1"/K3S_VERSION="latest"/' \
  "$SUBSTRATE/install.sh" >"$fixture_latest"
run 'control: a latest pin goes red under the same check' red check_pins "$fixture_latest"

fixture_latest_nats="$WORK/install-latest-nats.sh"
sed 's/^NATS_VERSION="2.10.24-alpine"/NATS_VERSION="latest"/' \
  "$SUBSTRATE/install.sh" >"$fixture_latest_nats"
run 'control: a latest NATS pin goes red under the same check' red check_pins "$fixture_latest_nats"


check_manifests_pin() {
  "$PY" - "$1" "$2" <<'PY'
import re
import subprocess
import sys

installer, repo = sys.argv[1], sys.argv[2]
src = open(installer, encoding="utf-8").read()
m = re.search(r'^KIT_SUBSTRATE_MANIFESTS_REF="([0-9a-fA-F]+)"$', src, re.M)
if not m:
    print("KIT_SUBSTRATE_MANIFESTS_REF is not set to a bare hex ref")
    sys.exit(1)
ref = m.group(1)
if not re.fullmatch(r"[0-9a-f]{40}", ref):
    print(f"KIT_SUBSTRATE_MANIFESTS_REF={ref!r} is not a 40-character commit sha — a branch or a tag floats")
    sys.exit(1)


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


if git("cat-file", "-e", ref + "^{commit}").returncode != 0:
    print(f"KIT_SUBSTRATE_MANIFESTS_REF={ref} does not resolve to a commit in this repository")
    sys.exit(1)
if git("diff", "--quiet", ref, "--", "templates/substrate/manifests").returncode != 0:
    print(
        f"the manifests at {ref} differ from the working tree — bump"
        " KIT_SUBSTRATE_MANIFESTS_REF so a served run installs the tree it ships with"
    )
    sys.exit(1)
print(f"the served-manifests pin {ref[:12]} is exact and matches the manifests on disk")
PY
}
run 'the served-manifests pin is an exact sha that tracks the manifests on disk' green \
  check_manifests_pin "$SUBSTRATE/install.sh" "$ROOT"

fixture_manifest_float="$WORK/install-manifest-float.sh"
sed 's/^KIT_SUBSTRATE_MANIFESTS_REF="[0-9a-f]*"/KIT_SUBSTRATE_MANIFESTS_REF="master"/' \
  "$SUBSTRATE/install.sh" >"$fixture_manifest_float"
run 'control: a floating manifest ref goes red under the same pin check' red \
  check_manifests_pin "$fixture_manifest_float" "$ROOT"

manifest_root_commit="$(git -C "$ROOT" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1 || true)"
if [ -n "$manifest_root_commit" ]; then
  fixture_manifest_stale="$WORK/install-manifest-stale.sh"
  sed "s/^KIT_SUBSTRATE_MANIFESTS_REF=\"[0-9a-f]*\"/KIT_SUBSTRATE_MANIFESTS_REF=\"$manifest_root_commit\"/" \
    "$SUBSTRATE/install.sh" >"$fixture_manifest_stale"
  if [ "$(grep -c "KIT_SUBSTRATE_MANIFESTS_REF=\"$manifest_root_commit\"" "$fixture_manifest_stale" || true)" -eq 1 ]; then
    run 'control: a pinned ref whose manifests differ goes red (the pin is a tie)' red \
      check_manifests_pin "$fixture_manifest_stale" "$ROOT"
  else
    fail 'control: a pinned ref whose manifests differ goes red (the pin is a tie)' \
      'the sed did not substitute the ref — the control would prove nothing'
  fi
else
  skip 'control: a pinned ref whose manifests differ goes red (the pin is a tie)' \
    'no root commit resolved in this checkout'
fi

served_fetch_bin="$WORK/served-fetch-bin"
served_tarball="$WORK/served/manifests.tgz"
mkdir -p "$served_fetch_bin" "$WORK/served/src/kit-fixture/templates/substrate"
cp -R "$SUBSTRATE/manifests" "$WORK/served/src/kit-fixture/templates/substrate/manifests"
tar czf "$served_tarball" -C "$WORK/served/src" kit-fixture
cat >"$served_fetch_bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *codeload.github.com/anywaye/kit*) exec cat "$served_tarball" ;;
  *) printf 'fake-curl: unexpected call: %s\n' "\$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$served_fetch_bin/curl"

served_fail_bin="$WORK/served-fail-bin"
mkdir -p "$served_fail_bin"
printf '#!/usr/bin/env bash\nexit 22\n' >"$served_fail_bin/curl"
chmod +x "$served_fail_bin/curl"

served_run() {
  local fakebin="$1" out ec=0
  out="$(env PATH="$fakebin:$PATH" KIT_SUBSTRATE_RECEIPT="$WORK/served-receipt.json" \
    KIT_SUBSTRATE_DATABASES="$DBS" DRY_RUN=1 bash -s <"$SUBSTRATE/install.sh" 2>&1)" || ec=$?
  printf '%s' "$out"
  return "$ec"
}

check_bash_source_fallback() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^[ \t]*#.*$", "", src)
if 'KIT_SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"' not in code:
    print(
        "the served-script read of BASH_SOURCE has no `:-` empty fallback — under a"
        " pipe `set -u` makes `${BASH_SOURCE[0]}` fatal"
    )
    sys.exit(1)
rest = code.replace('KIT_SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"', "")
if re.search(r"BASH_SOURCE\[0\]", rest):
    print("BASH_SOURCE[0] is read somewhere without the `:-` empty fallback")
    sys.exit(1)
print("BASH_SOURCE[0] is read with an explicit empty fallback")
PY
}
run 'the served-script read of BASH_SOURCE carries an explicit empty fallback' green \
  check_bash_source_fallback "$SUBSTRATE/install.sh"

served_unsafe="$WORK/served-unsafe.sh"
sed 's|KIT_SCRIPT_SOURCE="${BASH_SOURCE\[0\]:-}"|KIT_SCRIPT_SOURCE="${BASH_SOURCE[0]}"|' \
  "$SUBSTRATE/install.sh" >"$served_unsafe"
if grep -q '^KIT_SCRIPT_SOURCE="${BASH_SOURCE\[0\]}"$' "$served_unsafe" \
  && bash -n "$served_unsafe"; then
  run 'control: the pre-fix BASH_SOURCE read goes red under the fallback check' red \
    check_bash_source_fallback "$served_unsafe"
  unsafe_ec=0
  unsafe_out="$(env PATH="$served_fail_bin:$PATH" KIT_SUBSTRATE_RECEIPT="$WORK/served-receipt.json" \
    KIT_SUBSTRATE_DATABASES="$DBS" DRY_RUN=1 bash -s <"$served_unsafe" 2>&1)" || unsafe_ec=$?
  case "$unsafe_ec:${unsafe_out}" in
    0:*)
      fail 'control: the pre-fix shape crashes on BASH_SOURCE[0] under a pipe' \
        "exit 0 — the unguarded read did not crash: ${unsafe_out}"
      ;;
    *'BASH_SOURCE[0]: unbound variable'*)
      pass 'control: the pre-fix shape crashes on BASH_SOURCE[0] under a pipe'
      ;;
    *)
      fail 'control: the pre-fix shape crashes on BASH_SOURCE[0] under a pipe' \
        "exit ${unsafe_ec}, but not on BASH_SOURCE: ${unsafe_out}"
      ;;
  esac
else
  fail 'control fixture: the fallback delete did not apply' \
    'the sed did not restore the unguarded read, so the control would prove nothing'
fi

served_ok_out="$(served_run "$served_fetch_bin")" && served_ok_ec=0 || served_ok_ec=$?
served_ok=0
case "$served_ok_out" in
  *"fetching the manifests at"*)
    case "$served_ok_out" in
      *"[1/13]"*"[13/13]"*) served_ok=1 ;;
    esac
    ;;
esac
if [ "$served_ok_ec" -eq 0 ] && [ "$served_ok" -eq 1 ]; then
  pass 'a served install fetches the pinned manifests and plans all thirteen steps'
else
  fail 'a served install fetches the pinned manifests and plans all thirteen steps' \
    "exit=${served_ok_ec}: $(printf '%s\n' "$served_ok_out" | head -6)"
fi

served_fail_out="$(served_run "$served_fail_bin")" && served_fail_ec=0 || served_fail_ec=$?
served_refusal_ok=0
if [ "$served_fail_ec" -ne 0 ]; then
  case "$served_fail_out" in
    *"could not be fetched from https://codeload.github.com/anywaye/kit/tar.gz/"*)
      case "$served_fail_out" in
        *KIT_SUBSTRATE_BOX_ID*) ;;
        *"[5/13]"*) ;;
        *"unbound variable"*) ;;
        *) served_refusal_ok=1 ;;
      esac
      ;;
  esac
fi
if [ "$served_refusal_ok" -eq 1 ]; then
  pass 'a manifest set that cannot be fetched is refused by name, before step 5'
else
  fail 'a manifest set that cannot be fetched is refused by name, before step 5' \
    "exit=${served_fail_ec}: $(printf '%s\n' "$served_fail_out" | head -6)"
fi

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

fixture_broken="$WORK/broken-manifests"
mkdir -p "$fixture_broken"
cp "$MANIFESTS/identity.yaml" "$fixture_broken/"
printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: broken\n  spec:\n    destination: {}\n' \
  >"$fixture_broken/broken.yaml"
run 'control: a manifest missing spec.source goes red' red check_manifests "$fixture_broken"

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

if ls "$TLS_DIR"/*.yaml >/dev/null 2>&1; then
  fixture_shared_key="$WORK/issuers-shared-key"
  mkdir -p "$fixture_shared_key"
  sed 's/letsencrypt-staging-account-key/letsencrypt-prod-account-key/' \
    "$TLS_DIR"/*.yaml >"$fixture_shared_key/clusterissuer.yaml"
  run 'control: issuers sharing one account key go red' red check_issuers "$fixture_shared_key"

  fixture_no_solvers="$WORK/issuers-no-solvers"
  mkdir -p "$fixture_no_solvers"
  sed -e 's/^    solvers:/    solvers: []/' \
    -e '/^      - http01:/,/ingressClassName: traefik/d' \
    "$TLS_DIR"/*.yaml >"$fixture_no_solvers/clusterissuer.yaml"
  run 'control: an issuer with no solver goes red' red check_issuers "$fixture_no_solvers"
else
  fail 'controls: the issuer fixtures need the real manifests' "$TLS_DIR has no YAML — the green check above names what is missing"
fi

if grep -rn ':latest' "$SUBSTRATE" >/dev/null 2>&1; then
  fail 'no :latest image tag in the substrate tree' "$(grep -rn ':latest' "$SUBSTRATE")"
else
  pass 'no :latest image tag in the substrate tree'
fi

fixture_latest_tag="$WORK/latest-tag"
mkdir -p "$fixture_latest_tag"
printf 'image: ghcr.io/anywaye/charts/identity:latest\n' >"$fixture_latest_tag/pod.yaml"
if grep -rn ':latest' "$fixture_latest_tag" >/dev/null 2>&1; then
  pass 'control: a planted :latest tag is found by the same grep'
else
  fail 'control: a planted :latest tag is found by the same grep' "the grep did not find the planted tag"
fi

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

sourced_vars="KIT_SUBSTRATE_BOX_ID KIT_SUBSTRATE_REGISTRY_CAPABILITY KIT_SUBSTRATE_BOX_URL KIT_SUBSTRATE_ACME_EMAIL KIT_SUBSTRATE_DATABASES KIT_SUBSTRATE_POSTGRES_EXTENSIONS KIT_SUBSTRATE_SMTP_ADAPTER KIT_SUBSTRATE_SMTP_HOST KIT_SUBSTRATE_SMTP_PORT KIT_SUBSTRATE_SMTP_USERNAME KIT_SUBSTRATE_SMTP_PASSWORD KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET KIT_SUBSTRATE_CLOUDFLARE_API_KEY KIT_SUBSTRATE_CF_ACCOUNT_ID KIT_SUBSTRATE_MAIL_FROM KIT_SUBSTRATE_MAIL_FROM_NAME KIT_SUBSTRATE_STRIPE_API_KEY KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET KIT_SUBSTRATE_APP_BASE_URL KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY"
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

databases_try() {
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
print("1 Cluster (data/postgres), 5 services provisioned, no imageName")
PY
}

run 'the Cluster manifest carries the per-role provisioning' green check_cluster "$DATA_DIR/postgres-cluster.yaml"

fixture_no_revoke="$WORK/no-revoke-cluster.yaml"
grep -v 'REVOKE ALL ON DATABASE' "$DATA_DIR/postgres-cluster.yaml" >"$fixture_no_revoke"
run 'control: a Cluster without the REVOKE goes red' red check_cluster "$fixture_no_revoke"

fixture_app_sql="$WORK/app-sql-cluster.yaml"
awk '/^      owner: app$/{print; print "      postInitApplicationSQL:"; print "        - SELECT 1"; next}1' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_app_sql"
run 'control: a Cluster re-adding postInitApplicationSQL goes red' red check_cluster "$fixture_app_sql"

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

fixture_storage_cfg="$WORK/crd-storage"
mkdir -p "$fixture_storage_cfg/applications" "$fixture_storage_cfg/data" "$fixture_storage_cfg/tls"
cp -R "$SUBSTRATE/manifests/applications/." "$fixture_storage_cfg/applications/"
cp -R "$SUBSTRATE/manifests/data/." "$fixture_storage_cfg/data/"
cp -R "$SUBSTRATE/manifests/tls/." "$fixture_storage_cfg/tls/"
sed 's/^  storage:$/  storageConfiguration:/' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_storage_cfg/data/postgres-cluster.yaml"
run 'control: spec.storageConfiguration goes red' red \
  check_crd_fields "$CRD_MODEL" "$fixture_storage_cfg" "$SUBSTRATE/install.sh"

fixture_nested="$WORK/crd-nested"
mkdir -p "$fixture_nested/applications" "$fixture_nested/data" "$fixture_nested/tls"
cp -R "$SUBSTRATE/manifests/applications/." "$fixture_nested/applications/"
cp -R "$SUBSTRATE/manifests/data/." "$fixture_nested/data/"
cp -R "$SUBSTRATE/manifests/tls/." "$fixture_nested/tls/"
sed 's/^    storageClass: local-path$/    storageClassName: local-path/' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_nested/data/postgres-cluster.yaml"
run 'control: a nested unknown field (storageClassName) goes red' red \
  check_crd_fields "$CRD_MODEL" "$fixture_nested" "$SUBSTRATE/install.sh"

fixture_pin_drift="$WORK/install-cnpg-drift.sh"
sed 's/^CNPG_VERSION="v1.30.1"/CNPG_VERSION="v1.31.0"/' \
  "$SUBSTRATE/install.sh" >"$fixture_pin_drift"
run 'control: a pin bump without re-deriving the model goes red' red \
  check_crd_fields "$CRD_MODEL" "$SUBSTRATE/manifests" "$fixture_pin_drift"

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

fixture_no_creates="$WORK/no-creates-cluster.yaml"
grep -v 'CREATE ROLE' "$DATA_DIR/postgres-cluster.yaml" >"$fixture_no_creates"
run 'control: bootstrap SQL naming roles it never creates goes red' red check_cluster_bootstrap_order "$fixture_no_creates"

fixture_ghost="$WORK/ghost-role-cluster.yaml"
awk '/- CREATE DATABASE "identity" OWNER "identity"$/{print "        - CREATE ROLE \"ghost\" WITH LOGIN"; print "        - GRANT CONNECT ON DATABASE \"identity\" TO \"ghost\""}1' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_ghost"
run 'control: bootstrap SQL naming a role no managed entry creates goes red' red check_cluster_bootstrap_order "$fixture_ghost"

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

fixture_latest_redis="$WORK/latest-redis.yaml"
sed 's/image: redis:7.4.1-alpine/image: redis:latest/' "$DATA_DIR/redis.yaml" >"$fixture_latest_redis"
run 'control: a Redis floating on latest goes red' red check_redis "$fixture_latest_redis"

check_secret_record() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
records = re.findall(r"^#\s+RECORD\s+(\S+):\s*(.*)$", src, re.M)
if len(records) != 5:
    print(f"expected 5 RECORD lines, found {len(records)}")
    sys.exit(1)
patch_keys = set()
for block in re.findall(r'"stringData"\s*:\s*\{([^}]*)\}', code):
    patch_keys.update(re.findall(r'"([A-Z_]+)"\s*:', block))
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

fixture_dropped_key="$WORK/install-dropped-key.sh"
grep -v -- '--from-literal=COURIER_SMTP_PASSWORD=' "$SUBSTRATE/install.sh" >"$fixture_dropped_key"
run 'control: a secret with a key removed goes red' red check_secret_record "$fixture_dropped_key"

fixture_dropped_patch="$WORK/install-dropped-patch.sh"
sed 's/,"COURIER_IDENTITY_TOKEN":\$t//' "$SUBSTRATE/install.sh" >"$fixture_dropped_patch"
run 'control: a secret whose patched key is removed goes red' red check_secret_record "$fixture_dropped_patch"

fixture_dropped_url="$WORK/install-dropped-url.sh"
sed 's/"COURIER_BASE_URL":\$url,//' "$SUBSTRATE/install.sh" >"$fixture_dropped_url"
run 'control: a patched base URL removed from the pair goes red' red check_secret_record "$fixture_dropped_url"

fixture_extra_key="$WORK/install-extra-key.sh"
cp "$SUBSTRATE/install.sh" "$fixture_extra_key"
printf '\n--from-literal=EXTRA_UNRECORDED_KEY=x\n' >>"$fixture_extra_key"
run 'control: a secret with an unrecorded key goes red' red check_secret_record "$fixture_extra_key"

check_chart_secret_keys() {
  "$PY" - "$1" "$2" <<'PY'
import glob
import os
import re
import sys

import yaml

install_path, fleet = sys.argv[1], sys.argv[2]

SERVICES = ("identity", "gateway", "courier", "parlor", "billing")

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
    def sub(m):
        got = dotted(values, m.group(1).strip())
        return str(got) if got is not None else m.group(0)

    return re.sub(r"\{\{-?\s*\.Values\.([A-Za-z0-9_.]+)\s*-?\}\}", sub, text)


def refs_from(text):
    for m in re.finditer(r"secretRef:\s*\n\s*name:\s*([^\s]+)", text):
        names.add(m.group(1))
    for m in re.finditer(r"secretKeyRef:\s*\n\s*name:\s*([^\s]+)\s*\n\s*key:\s*([^\s]+)", text):
        names.add(m.group(1))
        refs.add((m.group(1), m.group(2)))
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

run 'every secret key a chart mounts or names is written by install.sh' green \
  check_chart_secret_keys "$SUBSTRATE/install.sh" "$ROOT/.."

build_chart_fixture() {
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

fixture_chart_name="$WORK/chart-fleet-missing-secret"
build_chart_fixture "$fixture_chart_name" "ASSERTION_SIGNING_KEY"
sed -i.bak 's/secretName: gateway-secrets/secretName: gateway-secrets-TYPO/' \
  "$fixture_chart_name/gateway/charts/gateway/values.yaml"
rm -f "$fixture_chart_name/gateway/charts/gateway/values.yaml.bak"
run 'control: a chart reading a secret install.sh never creates goes red' red \
  check_chart_secret_keys "$SUBSTRATE/install.sh" "$fixture_chart_name"

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
need("nats stream info anywaye", "the stream is never inspected before creation")
need("nats stream add anywaye", "the stream anywaye is never created")
if not any(
    "nats stream info anywaye" in ln and "||" in ln and "nats stream add anywaye" in ln
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
print("step 10 applies the broker and defines stream anywaye idempotently")
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
    i = text.find("nats stream add anywaye")
    if i < 0:
        problems.append(f"{label}: no `nats stream add anywaye`")
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
print(f"broker {itag} + nats-box {ibox}, stream anywaye {cflags['subjects']} storage={cflags['storage']} retention={cflags['retention']} max-age={cflags['max-age']}")
PY
}

run 'the NATS manifest carries the broker (Deployment + Service + PVC, -js, monitor probes)' green check_nats_manifest "$DATA_DIR/nats.yaml"

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

run 'install.sh applies the broker and defines stream anywaye idempotently' green check_nats_install "$SUBSTRATE/install.sh"

fixture_subjects="$WORK/install-nats-subjects.sh"
sed 's/muse\.>,darkroom\.>/muse.>/' "$SUBSTRATE/install.sh" >"$fixture_subjects"
run 'control: a stream missing a publisher goes red' red check_nats_install "$fixture_subjects"

run 'the substrate stream spec equals the compose stack nats-stream-init args' green check_nats_drift "$COMPOSE_STACK" "$SUBSTRATE/install.sh"

fixture_drift="$WORK/install-nats-drift.sh"
sed 's/--max-age 7d/--max-age 30d/' "$SUBSTRATE/install.sh" >"$fixture_drift"
run 'control: a substrate with a drifted max-age goes red' red check_nats_drift "$COMPOSE_STACK" "$fixture_drift"

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

fixture_sourced="$WORK/install-sourced.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$fixture_sourced"

mock_seed() {
  local d="$MOCK_ROOT/$1/$2"
  mkdir -p "$d"
  printf '%s' "$4" >"$d/$3"
}

mock_get() {
  cat "$MOCK_ROOT/$1/$2/$3" 2>/dev/null || true
}

mock_namespace_exists() {
  [ -n "${MOCK_ROOT:-}" ] || return 0
  [ -f "$MOCK_ROOT/namespaces" ] || return 1
  grep -qx -- "$1" "$MOCK_ROOT/namespaces" 2>/dev/null
}

mock_has_control_bytes() {
  "$PY" -c 'import sys; sys.exit(0 if b"\x00" in open(sys.argv[1], "rb").read() else 1)' "$1"
}

mock_apply_plant() {
  local manifest="$1" apply_ns
  apply_ns="$(printf '%s\n' "$manifest" | sed -n 's/^  namespace: //p' | head -1)"
  if [ -n "$apply_ns" ] && ! mock_namespace_exists "$apply_ns"; then
    printf 'Error from server (NotFound): namespaces "%s" not found\n' "$apply_ns" >&2
    return 1
  fi
  printf '%s\n' "$manifest" >>"$MOCK_ROOT/applied.yaml"
  local apply_kind apply_name
  apply_kind="$(printf '%s\n' "$manifest" | sed -n 's/^kind: //p' | head -1)"
  apply_name="$(printf '%s\n' "$manifest" | sed -n 's/^  name: //p' | head -1)"
  if [ "$apply_kind" = "Cluster" ] && [ -n "$apply_name" ] && [ -n "$apply_ns" ]; then
    [ -f "$MOCK_ROOT/$apply_ns/cluster-$apply_name" ] || : >"$MOCK_ROOT/$apply_ns/cluster-$apply_name"
  fi
}
mock_kubectl() {
  if [ -n "${MOCK_ROOT:-}" ]; then
    printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"
  fi
  local fallback_ns="" patch_file_arg=""
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
        local ns_name="${1:-}"
        shift || true
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
          case "$1" in
            -n) ns="$2"; shift 2 ;;
            --namespace=*) ns="${1#--namespace=}"; shift ;;
            --from-file=.dockerconfigjson=*) src="${1#--from-file=.dockerconfigjson=}"; shift ;;
            --dry-run=client) client_dry_run=1; shift ;;
            *) shift ;;
          esac
        done
        if [ -z "$src" ]; then
          echo "mock_kubectl: create secret docker-registry without a --from-file path" >&2
          return 1
        fi
        if ! mock_namespace_exists "$ns"; then
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "$ns" >&2
          return 1
        fi
        local d="$MOCK_ROOT/$ns/$name"
        mkdir -p "$d"
        cat "$src" >"$d/.dockerconfigjson"
        if [ "$client_dry_run" -eq 1 ]; then
          printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/dockerconfigjson\ndata:\n  .dockerconfigjson: %s\n' \
            "$name" "$ns" "$(base64 <"$d/.dockerconfigjson" | tr -d '\n')"
        fi
        return 0
      fi
      local name="${1:-}"
      shift || true
      local ns="$fallback_ns"
      local -a lits=()
        case "$1" in
          -n) ns="$2"; shift 2 ;;
          --from-literal=*) lits+=("${1#--from-literal=}"); shift ;;
          *) shift ;;
        esac
      done
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
        shift || true
        local dep_name="${1:-}"
        shift || true
        local dep_ns="" dep_tmpl=""
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
        shift || true
        local pod_name="${1:-}"
        shift || true
        local pod_ns="$fallback_ns" pod_tmpl=""
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
        shift || true
        local cl_name="${1:-}"
        shift || true
        local cl_ns="$fallback_ns" cl_tmpl=""
          case "$1" in
            -n) cl_ns="$2"; shift 2 ;;
            -o) cl_tmpl="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -f "$MOCK_ROOT/$cl_ns/cluster-$cl_name" ] || return 1
        case "$cl_tmpl" in
          *status.phase*)
            cat "$MOCK_ROOT/$cl_ns/cluster-$cl_name-phase" 2>/dev/null || printf 'Unknown'
            ;;
        esac
        return 0
      fi
      if [ "${1:-}" != "secret" ]; then
        echo "mock_kubectl: unhandled get ${1:-}" >&2
        return 1
      fi
      shift || true
      local name="${1:-}"
      shift || true
      local ns="" tmpl=""
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
      mkdir -p "$MOCK_ROOT/applied"
      local -a apply_targets=()
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
      return 0
      ;;
    patch)
      local patch_ns="$fallback_ns" patch_name="" body=""
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
          echo "error: unable to read patch file: open -: no such file or directory" >&2
          return 1
          ;;
        /dev/stdin) body="$(cat)" ;;
        *) body="$(cat "$patch_file_arg")" ;;
      esac
      local d="$MOCK_ROOT/$patch_ns/$patch_name"
      mkdir -p "$d"
      local -a patch_keys=()
      local patch_key
      while IFS= read -r patch_key; do
        [ -n "$patch_key" ] && patch_keys+=("$patch_key")
      done < <(printf '%s' "$body" | jq -r '.stringData // {} | keys[]')
      for patch_key in ${patch_keys[@]+"${patch_keys[@]}"}; do
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
      local run_name="${1:-}"
      shift || true
      local run_ns="$fallback_ns" run_image="" run_cmd="" run_env=""
        case "$1" in
          -n) run_ns="$2"; shift 2 ;;
          --restart=*) shift ;;
          --image=*) run_image="${1#--image=}"; shift ;;
          --env=*)
            run_env="${run_env}${run_env:+
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
      local del_res="${1:-}"
      shift || true
      local del_name="${1:-}"
      shift || true
      local del_ns="$fallback_ns"
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
      local log_ref="${1:-}"
      shift || true
      local log_ns="$fallback_ns"
        case "$1" in
          -n) log_ns="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      cat "$MOCK_ROOT/$log_ns/pod-${log_ref#pod/}/logs" 2>/dev/null || true
      return 0
      ;;
    port-forward)
      return 0
      ;;
    wait)
      local wait_args="$*"
      case "$wait_args" in
        *--for=condition=Ready\ cluster.postgresql.cnpg.io/*)
          local wname wns="$fallback_ns"
          wname="$(printf '%s' "$wait_args" | sed -E 's|.*cluster\.postgresql\.cnpg\.io/([^ ]+).*|\1|')"
          case "$wait_args" in
            *-n\ *)
              wns="$(printf '%s' "$wait_args" | sed -E 's|.*-n ([^ ]+).*|\1|')"
              ;;
          esac
          if [ -f "$MOCK_ROOT/$wns/cluster-$wname-ready" ]; then
            printf 'cluster.postgresql.cnpg.io/%s condition met\n' "$wname"
            return 0
          fi
          printf 'error: timed out waiting for the condition on clusters/%s\n' "$wname" >&2
          return 1
          ;;
        *)
          echo "mock_kubectl: unhandled wait $wait_args" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "mock_kubectl: unhandled verb $verb" >&2
      return 1
      ;;
  esac
}

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

mfa_seed_roles() {
  local svc
  for svc in identity gateway courier parlor billing; do
    mock_seed data "postgres-role-$svc-app" password "pw-$svc-app"
  done
  mock_seed data redis-password password "redis-pw"
}

mfa_smtp_env() {
  export DRY_RUN=0
  export KIT_SUBSTRATE_SMTP_HOST="relay.example.com"
  export KIT_SUBSTRATE_SMTP_USERNAME="relay-user"
  export KIT_SUBSTRATE_SMTP_PASSWORD="relay-pass"
  export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="provider-signing-secret"
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL=""
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_STRIPE_API_KEY="sk_test_dummy_for_the_gate"
  export KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET="whsec_dummy_for_the_gate"
}

MOCK_ROOT="$WORK/mfa-a"
mkdir -p "$MOCK_ROOT"
mfa_a_ec=0
(
  mfa_seed_roles
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

MFA_OVERRIDE="Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
MOCK_ROOT="$WORK/mfa-b"
mkdir -p "$MOCK_ROOT"
mfa_b_ec=0
(
  mfa_seed_roles
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

MOCK_ROOT="$WORK/mfa-c"
mkdir -p "$MOCK_ROOT"
mfa_c_ec=0
(
  mfa_seed_roles
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

MOCK_ROOT="$WORK/mfa-d"
mkdir -p "$MOCK_ROOT"
mfa_d_ec=0
(
  mfa_seed_roles
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

MOCK_ROOT="$WORK/mfa-e"
mkdir -p "$MOCK_ROOT"
mfa_e_ec=0
(
  mfa_seed_roles
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity?sslmode=disable"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
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

BROKER_URL="nats://nats.data.svc.cluster.local:4222"
MOCK_ROOT="$WORK/nats-url"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
nats_url_1_ec=0
(
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  mfa_smtp_env
  install_service_secrets >"$WORK/nats-url-1.log" 2>&1
) || nats_url_1_ec=$?
first_broker_url="$(mock_get identity identity-secrets NATS_URL)"

nats_url_2_ec=0
(
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
courier_broker_url="$(mock_get courier courier-secrets NATS_URL)"
if [ "$courier_broker_url" != "$BROKER_URL" ]; then
  fail 'courier-secrets: the first run completes carrying the broker address' "stored: '${courier_broker_url}'"
else
  pass 'courier-secrets: the first run completes carrying the broker address'
fi
if [ "$courier_broker_url" != "$first_broker_url" ]; then
  fail 'broker agreement: courier and identity point at the same broker' "courier: '${courier_broker_url}', identity: '${first_broker_url}'"
else
  pass 'broker agreement: courier and identity point at the same broker'
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

fixture_short_live="$WORK/install-nats-short-live.sh"
sed 's|--from-literal=NATS_URL="$NATS_URL"|--from-literal=NATS_URL="nats://nats:4222"|' \
  "$SUBSTRATE/install.sh" | sed '/^main "$@"/d' >"$fixture_short_live"
MOCK_ROOT="$WORK/nats-url-control"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
control_short_ec=0
(
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


cf_mail_env() {
  export DRY_RUN=0
  export KIT_SUBSTRATE_SMTP_ADAPTER="$1"
  export KIT_SUBSTRATE_SMTP_HOST="relay.example.com"
  export KIT_SUBSTRATE_SMTP_PORT="587"
  export KIT_SUBSTRATE_SMTP_USERNAME="relay-user"
  export KIT_SUBSTRATE_SMTP_PASSWORD="relay-pass"
  export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="${2-provider-signing-secret}"
  export KIT_SUBSTRATE_CLOUDFLARE_API_KEY="mailchannels-key-fake"
  if [ "${3:-set}" = "unset-key" ]; then
    export KIT_SUBSTRATE_CLOUDFLARE_API_KEY=""
  fi
  export KIT_SUBSTRATE_CF_ACCOUNT_ID="cf-account-id-fake"
  if [ "${4:-set-account}" = "unset-account" ]; then
    export KIT_SUBSTRATE_CF_ACCOUNT_ID=""
  fi
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
  export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL=""
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_STRIPE_API_KEY="sk_test_dummy_for_the_gate"
  export KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET="whsec_dummy_for_the_gate"
}

cf_run() {
  MOCK_ROOT="$1"
  local adapter="$2" secret="${3-provider-signing-secret}" key="${4:-set}" account="${5:-set-account}"
  mkdir -p "$MOCK_ROOT"
  mfa_seed_roles
  cf_ec=0
  (
    . "$fixture_sourced"
    kubectl() { mock_kubectl "$@"; }
    cf_mail_env "$adapter" "$secret" "$key" "$account"
    install_service_secrets >"$MOCK_ROOT.log" 2>&1
  ) || cf_ec=$?
}

cf_run "$WORK/cf-a" cloudflare
if [ "$cf_ec" -ne 0 ]; then
  fail 'cloudflare: the run succeeds with the MailChannels key supplied' "$(cat "$WORK/cf-a.log")"
elif [ "$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)" != "mailchannels-key-fake" ]; then
  fail 'cloudflare: courier-secrets holds the MailChannels key' \
    "stored: '$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)'"
elif [ "$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)" != "cf-account-id-fake" ]; then
  fail 'cloudflare: courier-secrets holds the account id' \
    "stored: '$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)'"
elif [ "$(mock_get courier courier-secrets COURIER_MAIL_ADAPTER)" != "cloudflare" ]; then
  fail 'cloudflare: the adapter is written as cloudflare' \
    "stored: '$(mock_get courier courier-secrets COURIER_MAIL_ADAPTER)'"
else
  pass 'cloudflare: courier-secrets holds the adapter and the MailChannels key'
fi
if [ "$(mock_get courier courier-secrets COURIER_MAIL_ADAPTER)" = "cloudflare" ] \
  && [ "$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)" = "mailchannels-key-fake" ] \
  && [ "$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)" = "cf-account-id-fake" ]; then
  pass 'cloudflare: key and account id are written together with the adapter'
else
  fail 'cloudflare: key and account id are written together with the adapter' \
    "adapter='$(mock_get courier courier-secrets COURIER_MAIL_ADAPTER)' key='$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)' account='$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)'"
fi
cf_smtp_keys_absent() {
  local leaked=""
  for key in COURIER_SMTP_HOST COURIER_SMTP_PORT COURIER_SMTP_USERNAME COURIER_SMTP_PASSWORD; do
    if [ -n "$(mock_get courier courier-secrets "$key")" ]; then
      leaked="${leaked} $key"
    fi
  done
  if [ -n "$leaked" ]; then
    printf 'the secret carries:%s\n' "$leaked"
    return 1
  fi
  printf 'the cloudflare branch writes no SMTP key'
}
run 'cloudflare: the SMTP tuple is not written' green cf_smtp_keys_absent
if [ "$(mock_get courier courier-secrets COURIER_INBOUND_RESEND_SECRET)" = "provider-signing-secret" ]; then
  pass 'cloudflare: the inbound signing secret is still written'
else
  fail 'cloudflare: the inbound signing secret is still written' \
    "stored: '$(mock_get courier courier-secrets COURIER_INBOUND_RESEND_SECRET)'"
fi

cf_run "$WORK/cf-a2" cloudflare ""
if [ "$cf_ec" -ne 0 ]; then
  fail 'cloudflare: the run succeeds with no signing secret supplied' "$(cat "$WORK/cf-a2.log")"
elif [ "$(mock_get courier courier-secrets COURIER_MAIL_ADAPTER)" != "cloudflare" ]; then
  fail 'cloudflare: no-secret run still writes the adapter' \
    "stored: '$(mock_get courier courier-secrets COURIER_MAIL_ADAPTER)'"
elif [ "$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)" != "mailchannels-key-fake" ]; then
  fail 'cloudflare: no-secret run still writes the key' \
    "stored: '$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)'"
elif [ "$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)" != "cf-account-id-fake" ]; then
  fail 'cloudflare: no-secret run still writes the account id' \
    "stored: '$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)'"
elif [ -n "$(mock_get courier courier-secrets COURIER_INBOUND_RESEND_SECRET)" ]; then
  fail 'cloudflare: no-secret run writes no inbound signing secret' \
    "stored: '$(mock_get courier courier-secrets COURIER_INBOUND_RESEND_SECRET)'"
elif grep -q "COURIER_INBOUND_RESEND_SECRET" "$WORK/cf-a2/kubectl-argv"; then
  fail 'cloudflare: no-secret run keeps the key out of the --from-literal list' \
    "the mock records every kubectl argv in full: $(grep "COURIER_INBOUND_RESEND_SECRET" "$WORK/cf-a2/kubectl-argv" | head -2)"
else
  pass 'cloudflare: no signing secret is a supported run, and the key stays absent'
fi

cf_run "$WORK/cf-b" cloudflare "provider-signing-secret" "unset-key"
if [ "$cf_ec" -eq 0 ]; then
  fail 'cloudflare: a missing MailChannels key refuses' "exit 0 — the run should have refused"
elif [ -e "$MOCK_ROOT/courier/courier-secrets" ]; then
  fail 'cloudflare: the refusal comes before any write' \
    "courier-secrets exists: $(ls "$MOCK_ROOT/courier/courier-secrets" 2>/dev/null | tr '\n' ' ')"
elif ! grep -q "KIT_SUBSTRATE_CLOUDFLARE_API_KEY" "$WORK/cf-b.log"; then
  fail 'cloudflare: the refusal names the missing variable' "$(cat "$WORK/cf-b.log")"
else
  pass 'cloudflare: a missing MailChannels key refuses before any write, naming the variable'
fi
if grep -q "signing secret" "$WORK/cf-b.log"; then
  fail 'cloudflare: the refusal no longer names the signing secret' \
    "the old demand for a provider signing secret is still in the refusal log"
elif ! grep -q "export KIT_SUBSTRATE_CLOUDFLARE_API_KEY='<cloudflare-token>' and KIT_SUBSTRATE_CF_ACCOUNT_ID='<account-id>'" "$WORK/cf-b.log"; then
  fail 'cloudflare: the refusal names exactly the two Cloudflare variables' "$(cat "$WORK/cf-b.log")"
else
  pass 'cloudflare: the refusal names exactly the two Cloudflare variables'
fi
case "$(cat "$WORK/cf-a.log")" in
  *"mailchannels-key-fake"*)
    fail 'cloudflare: the MailChannels key is never printed' "the key value appears in the output"
    ;;
  *)
    pass 'cloudflare: the MailChannels key is never printed'
    ;;
esac
case "$(cat "$WORK/cf-a.log")" in
  *"cf-account-id-fake"*)
    fail 'cloudflare: the account id is never printed' "the account id value appears in the output"
    ;;
  *)
    pass 'cloudflare: the account id is never printed'
    ;;
esac

cf_run "$WORK/cf-e" cloudflare "provider-signing-secret" "set" "unset-account"
if [ "$cf_ec" -eq 0 ]; then
  fail 'cloudflare: a missing account id refuses' "exit 0 — the run should have refused"
elif [ -e "$MOCK_ROOT/courier/courier-secrets" ]; then
  fail 'cloudflare: the account-id refusal comes before any write' \
    "courier-secrets exists: $(ls "$MOCK_ROOT/courier/courier-secrets" 2>/dev/null | tr '\n' ' ')"
elif ! grep -q "KIT_SUBSTRATE_CF_ACCOUNT_ID" "$WORK/cf-e.log"; then
  fail 'cloudflare: the account-id refusal names the missing variable' "$(cat "$WORK/cf-e.log")"
else
  pass 'cloudflare: a missing account id refuses before any write, naming the variable'
fi
if grep -q "signing secret" "$WORK/cf-e.log"; then
  fail 'cloudflare: the account-id refusal no longer names the signing secret' \
    "the old demand for a provider signing secret is still in the refusal log"
else
  pass 'cloudflare: the account-id refusal no longer names the signing secret'
fi

cf_run "$WORK/cf-c" smtp
if [ "$cf_ec" -ne 0 ]; then
  fail 'smtp: the run still succeeds unchanged' "$(cat "$WORK/cf-c.log")"
elif [ "$(mock_get courier courier-secrets COURIER_SMTP_PASSWORD)" != "relay-pass" ]; then
  fail 'smtp: the SMTP tuple is still written' \
    "stored: '$(mock_get courier courier-secrets COURIER_SMTP_PASSWORD)'"
elif [ -n "$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)" ]; then
  fail 'smtp: no Cloudflare key is written on the smtp branch' \
    "stored: '$(mock_get courier courier-secrets COURIER_CLOUDFLARE_API_KEY)'"
elif [ -n "$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)" ]; then
  fail 'smtp: no Cloudflare account id is written on the smtp branch' \
    "stored: '$(mock_get courier courier-secrets COURIER_CF_ACCOUNT_ID)'"
else
  pass 'smtp: the default branch writes the SMTP tuple and no Cloudflare key'
fi

cf_run "$WORK/cf-c2" smtp ""
if [ "$cf_ec" -eq 0 ]; then
  fail 'smtp: a missing signing secret still refuses' "exit 0 — the run should have refused"
elif [ -e "$MOCK_ROOT/courier/courier-secrets" ]; then
  fail 'smtp: the signing-secret refusal comes before any write' \
    "courier-secrets exists: $(ls "$MOCK_ROOT/courier/courier-secrets" 2>/dev/null | tr '\n' ' ')"
elif ! grep -q "the signing secret comes from the PROVIDER's dashboard" "$WORK/cf-c2.log"; then
  fail 'smtp: the refusal still names the signing secret' "$(cat "$WORK/cf-c2.log")"
else
  pass 'smtp: a missing signing secret still refuses before any write, naming the variable'
fi

cf_run "$WORK/cf-d" resend
if [ "$cf_ec" -eq 0 ]; then
  fail 'guard: an unknown adapter refuses' "exit 0"
elif ! grep -q "smtp, postmark, or cloudflare" "$WORK/cf-d.log"; then
  fail 'guard: the refusal names all three adapters' "$(cat "$WORK/cf-d.log")"
else
  pass 'guard: an unknown adapter refuses naming all three choices'
fi
if [ -e "$MOCK_ROOT/courier/courier-secrets" ]; then
  fail 'guard: the refusal comes before any write' "courier-secrets exists"
else
  pass 'guard: the refusal comes before any write'
fi

python_control="$WORK/install-cf-both.py"
cat >"$python_control" <<'PY'
import sys
src_path, dst_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()
needle = '      --from-literal=COURIER_CLOUDFLARE_API_KEY="$KIT_SUBSTRATE_CLOUDFLARE_API_KEY"\n'
if needle not in src:
    print("the cloudflare --from-literal line was not found — install.sh drifted",
          file=sys.stderr)
    sys.exit(1)
out = src.replace(
    needle,
    needle
    + '      --from-literal=COURIER_SMTP_HOST="$KIT_SUBSTRATE_SMTP_HOST"\n'
    + '      --from-literal=COURIER_SMTP_PASSWORD="$KIT_SUBSTRATE_SMTP_PASSWORD"\n',
)
open(dst_path, "w", encoding="utf-8").write(out)
PY
fixture_cf_both="$WORK/install-cf-both.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$WORK/install-cf-both-unsourced.sh"
"$PY" "$python_control" "$WORK/install-cf-both-unsourced.sh" "$fixture_cf_both"
MOCK_ROOT="$WORK/cf-control"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
control_cf_ec=0
(
  . "$WORK/install-cf-both.sh"
  kubectl() { mock_kubectl "$@"; }
  cf_mail_env cloudflare
  install_service_secrets >"$WORK/cf-control.log" 2>&1
) || control_cf_ec=$?
if [ "$control_cf_ec" -eq 0 ] && [ -n "$(mock_get courier courier-secrets COURIER_SMTP_HOST)" ]; then
  pass 'control: a cloudflare branch that also writes the SMTP tuple goes red'
else
  fail 'control: a cloudflare branch that also writes the SMTP tuple goes red' \
    "exit ${control_cf_ec}; COURIER_SMTP_HOST='$(mock_get courier courier-secrets COURIER_SMTP_HOST)'"
fi

check_role_secret_wiring() {
  local install_sh="$1" cluster="$2" root ec=0
  root="$(mktemp -d "$WORK/role-wiring.XXXXXX")"
  sed '/^main "$@"/d' "$install_sh" >"$root/install-no-main.sh"
  (
    export MOCK_ROOT="$root"
    mkdir -p "$MOCK_ROOT"
    printf 'data\n' >"$MOCK_ROOT/namespaces"
    export KUBECONFIG=/dev/null
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

fixture_user_drift="$WORK/install-username-drift.sh"
sed 's|--from-literal=username="\$role"|--from-literal=username="${role//_/-}"|' \
  "$SUBSTRATE/install.sh" >"$fixture_user_drift"
run 'control: a hyphenated app username (the live defect) goes red' red \
  check_role_secret_wiring "$fixture_user_drift" "$DATA_DIR/postgres-cluster.yaml"

fixture_role_drift="$WORK/cluster-role-name-drift.yaml"
sed 's/^      - name: identity_app$/      - name: identity-app/' \
  "$DATA_DIR/postgres-cluster.yaml" >"$fixture_role_drift"
run 'control: one role name drifting from its secret goes red' red \
  check_role_secret_wiring "$SUBSTRATE/install.sh" "$fixture_role_drift"

fixture_dsn_drift="$WORK/install-dsn-drift.sh"
sed 's|read_secret_key data "postgres-role-\$1-app" password|read_secret_key data "postgres-role-$1" password|' \
  "$SUBSTRATE/install.sh" >"$fixture_dsn_drift"
run 'control: a DATABASE_URL built from the owner secret goes red' red \
  check_role_secret_wiring "$fixture_dsn_drift" "$DATA_DIR/postgres-cluster.yaml"

check_rerun_repairs_username() {
  local install_sh="$1" root ec=0 svc problems=""
  root="$(mktemp -d "$WORK/rerun-repair.XXXXXX")"
  mkdir -p "$root/data"
  printf 'data\n' >"$root/namespaces"
  cp -R "$SUBSTRATE/manifests" "$root/manifests"
  MOCK_ROOT="$root"
  for svc in identity gateway courier parlor; do
    mock_seed data "postgres-role-$svc" username "$svc"
    mock_seed data "postgres-role-$svc" password "pw-$svc"
    mock_seed data "postgres-role-$svc-app" password "pw-$svc-app"
  done
  sed '/^main "$@"/d' "$install_sh" >"$root/install-no-main.sh"
  (
    export MOCK_ROOT="$root" KUBECONFIG=/dev/null
    . "$root/install-no-main.sh"
    kubectl() { mock_kubectl "$@"; }
    export KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor,billing"
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


check_patch_convention() {
  local mock="$1" root="$2" ec=0
  local want="error: unable to read patch file: open -: no such file or directory"
  rm -rf "$root"
  mkdir -p "$root"
  (
    export MOCK_ROOT="$root"
    mock_seed data probe username old
    printf '%s' '{"stringData":{"username":"new"}}' |
      "$mock" -n data patch secret probe --type=merge --patch-file=/dev/stdin ||
      { echo "$mock refused the /dev/stdin patch"; exit 3; }
    printf '%s' '{"stringData":{"username":"never"}}' |
      "$mock" -n data patch secret probe --type=merge --patch-file=- 2>"$root/dash.err" &&
      { echo "$mock accepted --patch-file=-, which real kubectl refuses"; exit 4; }
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

CAP_GOOD="cap_$(printf 'a%.0s' $(seq 64))"
CAP_B64_PULL_SECRET="$(printf '{"auths":{"ghcr.io":{"auth":"ZmFrZS1ub3QtYS1jcmVkZW50aWFs"}}}' | base64 | tr -d '\n')"
CAP_BOX_ID_UUID="11111111-2222-3333-4444-555555555555"
CAP_OTHER_BOX_UUID="88888887-7777-6666-5555-444444444444"
CAP_ACCOUNT_UUID="99999999-8888-7777-6666-555555555555"

installer_code="$WORK/install-code-only.sh"
sed -e 's/^[[:space:]]*#.*$//' "$SUBSTRATE/install.sh" >"$installer_code"
for retired in KIT_SUBSTRATE_PULL_SECRET KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY KIT_SUBSTRATE_IDENTITY_OIDC_SIGNING_KEY_ID KIT_SUBSTRATE_COURIER_IDENTITY_TOKEN KIT_SUBSTRATE_IDENTITY_COURIER_TOKEN; do
  if grep -n "$retired" "$installer_code" >/dev/null 2>&1; then
    fail "the installer no longer reads $retired" "$(grep -n "$retired" "$installer_code" | head -3)"
  else
    pass "the installer no longer reads $retired"
  fi
done

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

. "$fixture_sourced"

run 'the capability is validated: the minted shape is accepted' green registry_capability_shape_ok "$CAP_GOOD"
export MANIFEST_DIR="$MANIFESTS"
run 'control: a dockerconfigjson is refused as a capability' red registry_capability_shape_ok "$CAP_B64_PULL_SECRET"
run 'control: a short capability is refused' red registry_capability_shape_ok "cap_deadbeef"
run 'control: an empty capability is refused' red registry_capability_shape_ok ""

receipt_expires="$("$PY" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=58)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
receipt_past="$("$PY" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

EXCHANGE_B64="$(printf '{"auths":{"ghcr.io":{"username":"x-access-token","password":"ghs_a-labelled-fake"}}}' | base64 | tr -d '\n')"
  printf '{"registry":"ghcr.io","expires_at":"%s","seconds_remaining":%s,"dockerconfigjson":"%s"}' "$2" "$3" "$1"
}

MOCK_ROOT="$WORK/pull-secret"
mkdir -p "$MOCK_ROOT"
rm -f "$MOCK_ROOT/curl-calls" "$MOCK_ROOT/curl-response" "$MOCK_ROOT/kubectl-argv" "$MOCK_ROOT/applied.yaml" "$WORK/pull-secret.log"

MOCK_CURL_MODE="answer"
exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT/curl-response"
pull_secret_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() {
    printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"
    [ "${MOCK_CURL_MODE:-}" = "fail" ] && return 1
    cat "$MOCK_ROOT/curl-response"
    case "$*" in
      *"-w"*) printf '\n%s\n' "${MOCK_CURL_STATUS:-200}" ;;
    esac
    return 0
  }
  export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
  install_pull_secret >"$WORK/pull-secret.log" 2>&1
) || pull_secret_ec=$?

if [ "$pull_secret_ec" -ne 0 ]; then
  fail 'the pull-secret step exchanges the capability and writes the secret' "exit $pull_secret_ec: $(cat "$WORK/pull-secret.log")"
else
  pass 'the pull-secret step exchanges the capability and writes the secret'
fi

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
  case "$call" in
    *"Authorization: Bearer $CAP_GOOD"*) ;;
    *) printf 'the capability did not travel as a bearer header\n%s\n' "$call"; return 1 ;;
  esac
  case "$call" in
    *"/v1/registry-credentials/cap_"*|*registration-credentials/cap_*)
      printf 'the capability appears in the URL path\n%s\n' "$call"; return 1 ;;
    *) ;;
  esac
  case "$call" in
    *"$CAP_OTHER_BOX_UUID"*)
      printf 'the request names a box that is not this box\n%s\n' "$call"; return 1 ;;
    *) ;;
  esac
  case "$call" in
    *"$CAP_ACCOUNT_UUID"*)
      printf 'the request names the account — it travels in the capability\n%s\n' "$call"; return 1 ;;
    *) ;;
  esac
  printf 'a POST to the exchange route, the capability as a bearer, a body naming the box'
}
run 'the exchange speaks the registry-credentials route, bearer + box' green curl_call_ok

APPLIED_NAMESPACES=(argocd identity gateway courier parlor billing observability)
applied_pull_secrets_ok() {
  local ns found
  for ns in "${APPLIED_NAMESPACES[@]}"; do
    if ! grep -q "namespace: $ns" "$MOCK_ROOT/applied.yaml" 2>/dev/null; then
      printf 'no pull secret was applied in %s\n' "$ns"
      return 1
    fi
  done
  grep -q "kubernetes.io/dockerconfigjson" "$MOCK_ROOT/applied.yaml" || {
    printf 'the applied Secret is not a dockerconfigjson Secret'
    return 1
  }
  printf 'a dockerconfigjson Secret applied in %d namespaces' "${#APPLIED_NAMESPACES[@]}"
}
run 'the dockerconfigjson is written as a pull Secret in every pulling namespace' green applied_pull_secrets_ok

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

MOCK_ROOT_NS="$WORK/pull-secret-ns"
mkdir -p "$MOCK_ROOT_NS"
rm -f "$MOCK_ROOT_NS/curl-calls" "$MOCK_ROOT_NS/curl-response" "$MOCK_ROOT_NS/kubectl-argv" \
  "$MOCK_ROOT_NS/applied.yaml" "$MOCK_ROOT_NS/namespaces" "$WORK/pull-secret-ns.log" "$WORK/ns-runner.sh"
exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT_NS/curl-response"
cat >"$WORK/ns-runner.sh" <<RUNNER
set -euo pipefail
export MOCK_ROOT="$MOCK_ROOT_NS"
export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
. "$fixture_sourced"
export MANIFEST_DIR="$MANIFESTS"
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

pull_secret_order_ok() {
  local ns made wrote
  for ns in "${REGISTRY_PULL_NAMESPACES[@]}"; do
    made="$(grep -n -m1 -- "create namespace $ns " "$MOCK_ROOT_NS/kubectl-argv" 2>/dev/null | cut -d: -f1 || true)"
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
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
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

fixture_no_ns="$WORK/install-no-namespace.sh"
rm -f "$fixture_no_ns"
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
while block_end + 1 < len(lines) and lines[block_end + 1].strip() == "fi":
    block_end += 1
del lines[block_start:block_end + 1]
out_lines = [ln for ln in lines if ln != 'main "$@"']
out = "\n".join(out_lines)
body = out[out.index("apply_pull_secret() {"):out.index("install_pull_secret() {")]
if 'create namespace "$ns"' in body:
    sys.exit("control fixture: the creation is still inside apply_pull_secret")
if '--from-file=.dockerconfigjson=/dev/stdin' not in body:
    sys.exit("control fixture: the secret write is no longer inside apply_pull_secret")
if 'create namespace "$ns"' not in out:
    sys.exit("control fixture: the edit removed more than the one call site")
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
  cat >"$WORK/no-ns-runner.sh" <<RUNNER
set -euo pipefail
export MOCK_ROOT="$MOCK_ROOT_NONS"
export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
printf 'argocd\n' >"\$MOCK_ROOT/namespaces"
. "$fixture_no_ns"
export MANIFEST_DIR="$MANIFESTS"
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
    if ! grep -q "namespace: argocd" "$MOCK_ROOT_NONS/applied.yaml" 2>/dev/null; then
      printf 'argocd was not written, which is not the state the box was measured in\n'
      return 1
    fi
    local ns
    for ns in identity gateway courier parlor billing observability; do
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

stray_files_ok() {
  local f
  for f in "$MOCK_ROOT"/*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
      curl-calls|curl-response|kubectl-argv|applied|applied.yaml) continue ;;
      namespaces) continue ;;
      argocd|identity|gateway|courier|parlor|billing|observability) continue ;;
    esac
    printf 'unexpected file in the store: %s\n' "${f##*/}"
    return 1
  done
  printf 'nothing but the applied Secret and the records of the call hold the credential'
}
run 'no stray file on the box holds the credential' green stray_files_ok

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
    export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
    install_pull_secret >"$log" 2>&1
  ) || ec=$?
  MOCK_CURL_MODE=""
  MOCK_CURL_STATUS=""
  if [ "$ec" -ne 0 ] && grep -q "$want" "$log" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "exit $ec, log: $(cat "$log" 2>/dev/null)"
  fi
  if [ -s "$MOCK_ROOT/kubectl-argv" ] 2>/dev/null || [ -s "$MOCK_ROOT/applied.yaml" ] 2>/dev/null; then
    fail "a refusal writes nothing: $name" "argv or applied.yaml is non-empty after the refusal"
  else
    pass "a refusal writes nothing: $name"
  fi
}
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

rm -f "$MOCK_ROOT/curl-calls" "$MOCK_ROOT/kubectl-argv" "$MOCK_ROOT/applied.yaml"
(
  kubectl() { mock_kubectl "$@"; }
  curl() { printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"; cat "$MOCK_ROOT/curl-response"; printf '\n%s\n' "${MOCK_CURL_STATUS:-200}"; }
  export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_B64_PULL_SECRET"
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
  install_pull_secret >"$WORK/pull-secret-paste.log" 2>&1
) || true
if grep -q "OLD runbook" "$WORK/pull-secret-paste.log" 2>/dev/null \
  && ! grep -q "$CAP_B64_PULL_SECRET" "$MOCK_ROOT/curl-calls" 2>/dev/null \
  && ! grep -q "/v1/registry-credentials" "$MOCK_ROOT/curl-calls" 2>/dev/null; then
  pass 'control: a pasted dockerconfigjson is refused before the capability could be spent or sent'
else
  fail 'control: a pasted dockerconfigjson is refused before the capability could be spent or sent' "$(cat "$WORK/pull-secret-paste.log")"
fi

PROBE_APPS="$WORK/probe-apps"
mkdir -p "$PROBE_APPS"
  cat >"$PROBE_APPS/$1.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $1
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $2
    chart: $3
    targetRevision: $4
  destination:
    server: https://kubernetes.default.svc
    namespace: $1
YAML
}
probe_app anon-identity oci://ghcr.io/anywaye/charts/identity identity 0.1.0
probe_app anon-gateway oci://ghcr.io/anywaye/charts/gateway gateway 0.1.0
probe_app anon-grafana https://grafana.github.io/helm-charts grafana 10.5.15

mock_probe_curl() {
  printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"
  case "$*" in
    *"/token?"*)
      case "$*" in
        *"repository:${MOCK_TOKEN_DENY:-__none__}:"*)
          printf '{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}'
          return 0 ;;
      esac
      printf '{"token":"mock-anon-token"}'
      return 0 ;;
    *"/manifests/"*)
      case "$*" in
        *"manifests/${MOCK_MANIFEST_DENY:-__none__}"*)
          printf '404' ;;
        *)
          printf '200' ;;
      esac
      return 0 ;;
    *"/v1/registry-credentials"*)
      cat "$MOCK_ROOT/curl-response"
      case "$*" in
        *"-w"*) printf '\n%s\n' "${MOCK_CURL_STATUS:-200}" ;;
      esac
      return 0 ;;
  esac
  printf 'mock_probe_curl: unhandled call: %s\n' "$*" >&2
  return 1
}

derived_ok() {
  local rows n want
  rows="$(MANIFEST_DIR="$MANIFESTS" registry_derived_artifacts | sort)"
  n="$(printf '%s\n' "$rows" | grep -c .)"
  [ "$n" -eq 10 ] || { printf 'derived %s artifact rows, expected 10\n%s\n' "$n" "$rows"; return 1; }
  for want in "anywaye/charts/billing 0.1.2" "anywaye/billing 0.1.2" \
    "anywaye/charts/courier 0.1.0" "anywaye/courier 0.1.0" \
    "anywaye/charts/gateway 0.1.0" "anywaye/gateway 0.1.0" \
    "anywaye/charts/identity 0.1.0" "anywaye/identity 0.1.0" \
    "anywaye/charts/parlor 0.1.0" "anywaye/parlor 0.1.0"; do
    case "$rows" in
      *"$want"*) ;;
      *) printf 'missing derived row: %s\n%s\n' "$want" "$rows"; return 1 ;;
    esac
  done
  case "$rows" in
    *grafana* | *alloy* | *prometheus*)
      printf 'a plain-HTTPS chart was probed:\n%s\n' "$rows"; return 1 ;;
  esac
  printf '8 rows: 4 charts + 4 images, no plain-HTTPS chart'
}
run 'the probe derives every GHCR chart and image off the real manifests' green derived_ok

PROBE_FIX_DERIVE="$WORK/probe-derive"
mkdir -p "$PROBE_FIX_DERIVE"
cat >"$PROBE_FIX_DERIVE/demo.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://ghcr.io/anywaye/charts/demo
    chart: demo
    targetRevision: 2.0.0
YAML
cat >"$PROBE_FIX_DERIVE/grafana.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: grafana
    targetRevision: 10.5.15
YAML
derived_fixture_ok() {
  local rows
  rows="$(MANIFEST_DIR="$PROBE_FIX_DERIVE" registry_derived_artifacts | sort)"
  [ "$rows" = "$(printf 'anywaye/charts/demo 2.0.0\nanywaye/demo 2.0.0')" ] || {
    printf 'fixture derivation is not exactly the chart plus its image:\n%s\n' "$rows"
    return 1
  }
  printf 'exactly the chart and its image; the HTTPS chart excluded'
}
run 'control: the derivation lists a fixture chart plus its image, nothing else' green derived_fixture_ok

MOCK_ROOT_ANON="$WORK/pull-secret-anon"
mkdir -p "$MOCK_ROOT_ANON"
rm -f "$MOCK_ROOT_ANON/curl-calls" "$MOCK_ROOT_ANON/curl-response" "$MOCK_ROOT_ANON/kubectl-argv" \
  "$MOCK_ROOT_ANON/applied.yaml" "$MOCK_ROOT_ANON/namespaces" "$WORK/pull-secret-anon.log"
anon_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() { mock_probe_curl "$@"; }
  export MOCK_ROOT="$MOCK_ROOT_ANON"
  export MANIFEST_DIR="$PROBE_APPS"
  export MOCK_TOKEN_DENY="__none__" MOCK_MANIFEST_DENY="__none__"
  export KIT_SUBSTRATE_BOX_ID="" KIT_SUBSTRATE_REGISTRY_CAPABILITY=""
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
  install_pull_secret >"$WORK/pull-secret-anon.log" 2>&1
  printf 'REGISTRY_PATH=%s\n' "$REGISTRY_PATH" >>"$WORK/pull-secret-anon.log"
) || anon_ec=$?
anon_ok() {
  [ "$anon_ec" -eq 0 ] || { printf 'exit %s: %s\n' "$anon_ec" "$(cat "$WORK/pull-secret-anon.log")"; return 1; }
  case "$(cat "$WORK/pull-secret-anon.log")" in
    *"every artifact is public; no registry credential was needed"*) ;;
    *) printf 'the anonymous line is missing\n%s\n' "$(cat "$WORK/pull-secret-anon.log")"; return 1 ;;
  esac
  case "$(cat "$WORK/pull-secret-anon.log")" in
    *"REGISTRY_PATH=anonymous"*) ;;
    *) printf 'the step did not record the anonymous path\n'; return 1 ;;
  esac
  case "$(cat "$MOCK_ROOT_ANON/curl-calls" 2>/dev/null || true)" in
    *"/v1/registry-credentials"*)
      printf 'the exchange route was spoken on the anonymous path\n'; return 1 ;;
  esac
  local ns
  for ns in "${REGISTRY_PULL_NAMESPACES[@]}"; do
    grep -q "namespace: $ns" "$MOCK_ROOT_ANON/applied.yaml" 2>/dev/null || {
      printf 'no pull secret was applied in %s\n' "$ns"; return 1
    }
  done
  printf 'anonymous path: anonymous line, no exchange call, secret in every namespace'
}
run 'all public with no box id and no capability: step 5 succeeds anonymously' green anon_ok

pull_secret_anon_kubelet_ok() {
  "$PY" - "$MOCK_ROOT_ANON/applied.yaml" <<'PY'
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
        doc = json.loads(base64.b64decode(v))
    except Exception as e:
        print("the applied data does not decode once to JSON (%s)" % (e,))
        sys.exit(1)
    if doc.get("auths") != {}:
        print("the anonymous Secret carries credentials: %r" % (doc.get("auths"),))
        sys.exit(1)
print("%d Secret(s), each decoding once to empty auths" % (len(vals),))
PY
}
run 'the anonymous Secret decodes once, as the kubelet does, to empty auths' green pull_secret_anon_kubelet_ok

PROBE_PRIV="$WORK/probe-priv"
mkdir -p "$PROBE_PRIV"
cat >"$PROBE_PRIV/priv.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: priv
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://ghcr.io/anywaye/charts/priv-fixture
    chart: priv-fixture
    targetRevision: 9.9.9
YAML

MOCK_ROOT_PRIV="$WORK/pull-secret-priv"
mkdir -p "$MOCK_ROOT_PRIV"
rm -f "$MOCK_ROOT_PRIV/curl-calls" "$MOCK_ROOT_PRIV/curl-response" "$MOCK_ROOT_PRIV/kubectl-argv" \
  "$MOCK_ROOT_PRIV/applied.yaml" "$MOCK_ROOT_PRIV/namespaces" "$WORK/pull-secret-priv.log"
priv_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() { mock_probe_curl "$@"; }
  export MOCK_ROOT="$MOCK_ROOT_PRIV"
  export MANIFEST_DIR="$PROBE_PRIV"
  export MOCK_TOKEN_DENY="anywaye/charts/priv-fixture" MOCK_MANIFEST_DENY="__none__"
  export KIT_SUBSTRATE_BOX_ID="" KIT_SUBSTRATE_REGISTRY_CAPABILITY=""
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
  install_pull_secret >"$WORK/pull-secret-priv.log" 2>&1
) || priv_ec=$?
priv_ok() {
  [ "$priv_ec" -ne 0 ] || { printf 'the step succeeded with a private artifact and no capability\n'; return 1; }
  case "$(cat "$WORK/pull-secret-priv.log")" in
    *"anywaye/charts/priv-fixture:9.9.9"*) ;;
    *) printf 'the refusal does not name the private artifact\n%s\n' "$(cat "$WORK/pull-secret-priv.log")"; return 1 ;;
  esac
  case "$(cat "$WORK/pull-secret-priv.log")" in
    *"KIT_SUBSTRATE_BOX_ID is not set"*) ;;
    *) printf 'the refusal is not in the capability words\n%s\n' "$(cat "$WORK/pull-secret-priv.log")"; return 1 ;;
  esac
  case "$(cat "$WORK/pull-secret-priv.log")" in
    *"public: anywaye/priv-fixture:9.9.9"*) ;;
    *) printf 'the public image row was not measured public\n%s\n' "$(cat "$WORK/pull-secret-priv.log")"; return 1 ;;
  esac
  printf 'refused in the capability words, naming the one private artifact'
}
run 'one private artifact with no capability: the refusal names that artifact' green priv_ok

PROBE_TAG="$WORK/probe-tag"
mkdir -p "$PROBE_TAG"
cat >"$PROBE_TAG/tag.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tag
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://ghcr.io/anywaye/charts/identity
    chart: identity
    targetRevision: 0.0.0-no-such-tag
YAML
MOCK_ROOT_TAG="$WORK/pull-secret-tag"
mkdir -p "$MOCK_ROOT_TAG"
rm -f "$MOCK_ROOT_TAG/curl-calls" "$MOCK_ROOT_TAG/curl-response" "$MOCK_ROOT_TAG/kubectl-argv" \
  "$MOCK_ROOT_TAG/applied.yaml" "$MOCK_ROOT_TAG/namespaces" "$WORK/pull-secret-tag.log"
tag_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() { mock_probe_curl "$@"; }
  export MOCK_ROOT="$MOCK_ROOT_TAG"
  export MANIFEST_DIR="$PROBE_TAG"
  export MOCK_TOKEN_DENY="__none__" MOCK_MANIFEST_DENY="0.0.0-no-such-tag"
  export KIT_SUBSTRATE_BOX_ID="" KIT_SUBSTRATE_REGISTRY_CAPABILITY=""
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
  install_pull_secret >"$WORK/pull-secret-tag.log" 2>&1
) || tag_ec=$?
tag_ok() {
  [ "$tag_ec" -ne 0 ] || { printf 'the step went anonymous on a token-answered, manifest-missing artifact\n'; return 1; }
  case "$(cat "$WORK/pull-secret-tag.log")" in
    *"anywaye/charts/identity:0.0.0-no-such-tag"*) ;;
    *) printf 'the refusal does not name the unfetchable artifact\n%s\n' "$(cat "$WORK/pull-secret-tag.log")"; return 1 ;;
  esac
  printf 'a token with a missing manifest is still private'
}
run 'control: a probe that cannot fail is not a probe — answered token, missing manifest' green tag_ok

MOCK_ROOT_CAP="$WORK/pull-secret-cap"
mkdir -p "$MOCK_ROOT_CAP"
rm -f "$MOCK_ROOT_CAP/curl-calls" "$MOCK_ROOT_CAP/curl-response" "$MOCK_ROOT_CAP/kubectl-argv" \
  "$MOCK_ROOT_CAP/applied.yaml" "$MOCK_ROOT_CAP/namespaces" "$WORK/pull-secret-cap.log"
exchange_body "$EXCHANGE_B64" "$receipt_expires" 3480 >"$MOCK_ROOT_CAP/curl-response"
cap_ec=0
(
  kubectl() { mock_kubectl "$@"; }
  curl() { mock_probe_curl "$@"; }
  export MOCK_ROOT="$MOCK_ROOT_CAP"
  export MANIFEST_DIR="$PROBE_PRIV"
  export MOCK_TOKEN_DENY="anywaye/charts/priv-fixture" MOCK_MANIFEST_DENY="__none__"
  export KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID"
  export KIT_SUBSTRATE_REGISTRY_CAPABILITY="$CAP_GOOD"
  export KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test"
  install_pull_secret >"$WORK/pull-secret-cap.log" 2>&1
  printf 'REGISTRY_PATH=%s\n' "$REGISTRY_PATH" >>"$WORK/pull-secret-cap.log"
) || cap_ec=$?
cap_ok() {
  [ "$cap_ec" -eq 0 ] || { printf 'exit %s: %s\n' "$cap_ec" "$(cat "$WORK/pull-secret-cap.log")"; return 1; }
  case "$(cat "$WORK/pull-secret-cap.log")" in
    *"1 artifact(s) are private; the capability exchange was used"*) ;;
    *) printf 'the private line is missing\n%s\n' "$(cat "$WORK/pull-secret-cap.log")"; return 1 ;;
  esac
  case "$(cat "$WORK/pull-secret-cap.log")" in
    *"REGISTRY_PATH=capability"*) ;;
    *) printf 'the step did not record the capability path\n'; return 1 ;;
  esac
  printf 'capability path: private line, minted credential exchanged'
}
run 'private artifacts with a valid box id and capability: the exchange runs unchanged' green cap_ok
MOCK_ROOT_SAVED_CAP="$MOCK_ROOT"
MOCK_ROOT="$MOCK_ROOT_CAP"
run 'the capability-path Secret decodes once to the minted ghcr.io credential' green pull_secret_kubelet_ok
MOCK_ROOT="$MOCK_ROOT_SAVED_CAP"

PROBE_EMPTY="$WORK/probe-empty"
mkdir -p "$PROBE_EMPTY"
probe_empty() {
  MANIFEST_DIR="$PROBE_EMPTY" registry_probe_artifacts >/dev/null 2>&1
}
run 'an empty manifest dir refuses rather than going anonymous' red probe_empty

master_refusal_pins() {
  local out ec=0
  out="$(KIT_SUBSTRATE_BOX_ID="$CAP_BOX_ID_UUID" KIT_SUBSTRATE_REGISTRY_CAPABILITY="" REGISTRY_PRIVATE_ARTIFACTS="" exchange_registry_credential 2>&1)" || ec=$?
  [ "$ec" -ne 0 ] || { printf 'the exchange succeeded with no capability\n'; return 0; }
  case "$out" in
    *"export KIT_SUBSTRATE_REGISTRY_CAPABILITY='<cap_… from cafe box enroll>'"*) return 1 ;;
    *) printf 'the refusal does not carry the capability line\n%s\n' "$out"; return 0 ;;
  esac
}
run 'control: the exchange alone still demands a capability before seeing any artifact' red master_refusal_pins

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

MOCK_ROOT="$WORK/oidc-b"
mkdir -p "$MOCK_ROOT"
oidc_b_ec=0
(
  mfa_seed_roles
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

OIDC_FOUR_ISSUER="https://identity.example.com"
OIDC_FOUR_LOGIN="https://app.example.com/sign-in/oidc"

MOCK_ROOT="$WORK/oidc-four-green"
mkdir -p "$MOCK_ROOT"
oidc_four_green_ec=0
(
  mfa_seed_roles
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
if [ "$oidc_four_green_ec" -eq 0 ]; then
  if [ "$(mock_get identity identity-secrets OIDC_ISSUER)" = "$OIDC_FOUR_ISSUER" ] && \
     [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" = "$OIDC_FOUR_LOGIN" ]; then
    pass 'oidc four: the four keys round-trip on a warm box (read-back agrees)'
  else
    fail 'oidc four: the four keys round-trip on a warm box (read-back agrees)' "stored keys do not match inputs"
  fi
fi

oidc_refused_case() {
  local has_issuer="$1" has_login="$2" want_var="$3" name="$4"
  MOCK_ROOT="$WORK/oidc-refuse-$name"
  mkdir -p "$MOCK_ROOT"
  mfa_seed_roles
  local ec=0 log="$WORK/oidc-refuse-$name.log"
  (
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
  if [ "$oidc_three_ec" -eq 0 ] && [ -n "$(mock_get identity identity-secrets OIDC_ISSUER)" ] && [ -z "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL 2>/dev/null || true)" ]; then
    pass 'control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)'
  else
    fail 'control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)' "exit $oidc_three_ec: $(cat "$WORK/oidc-three-control.log")"
  fi
fi
run 'control: the four-key installer refuses issuer-alone (the new code discriminates)' green oidc_refused_case 1 0 "KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL" issuer-alone

MOCK_ROOT="$WORK/oidc-bad-login"
mkdir -p "$MOCK_ROOT"
oidc_bad_ec=0
(
  mfa_seed_roles
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
for bad in "https://app.example.com/sign-in?x=1" "https://app.example.com/sign-in#frag" "https://user@app.example.com/sign-in" "https:///sign-in"; do
  MOCK_ROOT="$WORK/oidc-bad-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$MOCK_ROOT"
  oidc_bad2_ec=0
  (
    mfa_seed_roles
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

oidc_jwks_curl() {
  printf '%s\n' "$*" >>"$MOCK_ROOT/curl-calls"
  case "$*" in
    *"/.well-known/jwks.json"*)
      printf '%s' "${OIDC_JWKS_STATUS:-200}"
      return 0
      ;;
    *)
      printf 'oidc_jwks_curl: unmocked %s\n' "$*" >&2
      return 1
      ;;
  esac
}

MOCK_ROOT="$WORK/oidc-warm-reconcile"
mkdir -p "$MOCK_ROOT"
mfa_seed_roles
mkdir -p "$MOCK_ROOT/identity/deploy-identity"
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
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  curl() { oidc_jwks_curl "$@"; }
  kit_substrate_await_port() { return 0; }
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
if grep -q 'rollout restart deployment/identity' "$MOCK_ROOT/kubectl-argv"; then
  pass 'warm: identity is restarted after its OIDC secret is patched'
else
  fail 'warm: identity is restarted after its OIDC secret is patched' "no rollout restart in $(cat "$MOCK_ROOT/kubectl-argv" 2>/dev/null)"
fi
if grep -q 'rollout status deployment/identity.*--timeout=' "$MOCK_ROOT/kubectl-argv"; then
  pass 'warm: the OIDC restart is watched with a bounded rollout status'
else
  fail 'warm: the OIDC restart is watched with a bounded rollout status' "no bounded rollout status in $(cat "$MOCK_ROOT/kubectl-argv" 2>/dev/null)"
fi
case "$(cat "$WORK/oidc-warm.log")" in
  *'JWKS route answers 2'*)
    pass 'warm: the JWKS route is verified serving after the restart'
    ;;
  *)
    fail 'warm: the JWKS route is verified serving after the restart' "$(cat "$WORK/oidc-warm.log")"
    ;;
esac

oidc_patch_seed() {
  mfa_seed_roles
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity?sslmode=disable"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "legacy-signup"
  mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "legacy-mfa"
  mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"
  mock_seed identity identity-secrets OIDC_ISSUER "$OIDC_FOUR_ISSUER"
  mock_seed identity identity-secrets OIDC_SIGNING_KEY "legacy-oidc-key"
  mock_seed identity identity-secrets OIDC_SIGNING_KEY_ID "legacy-oidc-kid"
  mock_seed gateway gateway-secrets REDIS_URL "redis://:pw@redis.data.svc.cluster.local:6379"
  mock_seed gateway gateway-secrets ASSERTION_SIGNING_KEY "dummy"
  mock_seed courier courier-secrets DATABASE_URL "ecto://courier_app:pw@host/courier"
  mock_seed parlor parlor-secrets DATABASE_URL "postgres://parlor_app:pw@host/parlor"
  mkdir -p "$MOCK_ROOT/identity/deploy-identity"
}

oidc_patch_kubectl() {
  case "$*" in
    *"rollout status deployment/identity"*)
      if [ -n "${OIDC_ROLLOUT_FAIL:-}" ]; then
        printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"
        printf 'error: deployment "identity" exceeded its progress deadline\n' >&2
        return 1
      fi
      ;;
  esac
  mock_kubectl "$@"
}

oidc_nodeploy_kubectl() {
  case "$*" in
    *"get deployment identity"*)
      printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"
      printf 'Error from server (NotFound): deployments.apps "identity" not found\n' >&2
      return 1
      ;;
    *)
      oidc_patch_kubectl "$@"
      ;;
  esac
}

oidc_patch_run() {
  oidc_patch_ec=0
  (
    . "$1"
    kubectl() { "${OIDC_KUBECTL_FN:-oidc_patch_kubectl}" "$@"; }
    curl() { oidc_jwks_curl "$@"; }
    kit_substrate_await_port() { return 0; }
    mfa_smtp_env
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
    export KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL="$OIDC_FOUR_LOGIN"
    if [ -n "${OIDC_PATCH_TIMEOUT:-}" ]; then
      IDENTITY_ROLLOUT_TIMEOUT="$OIDC_PATCH_TIMEOUT"
    fi
    install_service_secrets >"$WORK/oidc-patch-run.log" 2>&1
  ) || oidc_patch_ec=$?
}

check_oidc_patch_restart() {
  MOCK_ROOT="$WORK/oidc-patch-green"
  rm -rf "$MOCK_ROOT"; mkdir -p "$MOCK_ROOT"
  OIDC_PATCH_TIMEOUT=5
  oidc_patch_seed
  oidc_patch_run "$1"
  OIDC_PATCH_TIMEOUT=""
  if [ "$oidc_patch_ec" -ne 0 ]; then
    printf 'the warm patch exited %s\n%s\n' "$oidc_patch_ec" "$(cat "$WORK/oidc-patch-run.log")"
    return 1
  fi
  if ! grep -q 'rollout restart deployment/identity' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
    printf 'identity was not restarted after its OIDC secret changed\n'
    return 1
  fi
  if ! grep -q 'rollout status deployment/identity.*--timeout=5s' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
    printf 'the restart was not watched with the bounded rollout status\n%s\n' "$(cat "$MOCK_ROOT/kubectl-argv")"
    return 1
  fi
  case "$(cat "$WORK/oidc-patch-run.log")" in
    *'JWKS route answers 2'*) ;;
    *)
      printf 'the JWKS route was not verified serving after the restart\n%s\n' "$(cat "$WORK/oidc-patch-run.log")"
      return 1
      ;;
  esac
  if [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" != "$OIDC_FOUR_LOGIN" ]; then
    printf 'the fourth key did not land: OIDC_LOGIN_UI_URL=%s\n' "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)"
    return 1
  fi
  printf 'patched, restarted, rollout watched bounded, JWKS answers 2xx'
}
run 'warm: the OIDC patch restarts identity, watches the rollout bounded, and verifies the JWKS route' green \
  check_oidc_patch_restart "$fixture_sourced"

check_oidc_patch_noop() {
  MOCK_ROOT="$WORK/oidc-patch-noop"
  rm -rf "$MOCK_ROOT"; mkdir -p "$MOCK_ROOT"
  oidc_patch_seed
  oidc_patch_run "$1"
  if [ "$oidc_patch_ec" -ne 0 ]; then
    printf 'the converging run exited %s\n%s\n' "$oidc_patch_ec" "$(cat "$WORK/oidc-patch-run.log")"
    return 1
  fi
  : >"$MOCK_ROOT/kubectl-argv"
  oidc_patch_run "$1"
  if [ "$oidc_patch_ec" -ne 0 ]; then
    printf 'the converged re-run exited %s\n%s\n' "$oidc_patch_ec" "$(cat "$WORK/oidc-patch-run.log")"
    return 1
  fi
  if grep -q 'rollout restart deployment/identity' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
    printf 'a converged re-run restarted identity — the guard early return is broken\n'
    return 1
  fi
  printf 'converged re-run restarts nothing'
}
run 'warm: a converged OIDC box restarts nothing on a re-run' green \
  check_oidc_patch_noop "$fixture_sourced"

check_oidc_create_no_restart() {
  MOCK_ROOT="$WORK/oidc-patch-create"
  rm -rf "$MOCK_ROOT"; mkdir -p "$MOCK_ROOT"
  mfa_seed_roles
  oidc_patch_run "$1"
  if [ "$oidc_patch_ec" -ne 0 ]; then
    printf 'the fresh install exited %s\n%s\n' "$oidc_patch_ec" "$(cat "$WORK/oidc-patch-run.log")"
    return 1
  fi
  for k in OIDC_ISSUER OIDC_SIGNING_KEY OIDC_SIGNING_KEY_ID OIDC_LOGIN_UI_URL; do
    if [ -z "$(mock_get identity identity-secrets "$k")" ]; then
      printf 'the creation path did not write %s\n' "$k"
      return 1
    fi
  done
  if grep -q 'rollout restart deployment/identity' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
    printf 'the creation path restarted a pod that does not exist yet\n'
    return 1
  fi
  printf 'creation writes all four keys and restarts nothing'
}
run 'warm: the OIDC creation path writes the keys and restarts nothing' green \
  check_oidc_create_no_restart "$fixture_sourced"

oidc_norestart_fixture="$WORK/install-oidc-norestart.sh"
awk '
  /^reconcile_oidc_identity_secrets\(\)/ { in_fn=1 }
  in_fn && /^  if kubectl .* get deployment identity -n identity/ { skip=1; next }
  skip && /^  fi$/ { skip=0; next }
  skip { next }
  { print }
' "$fixture_sourced" >"$oidc_norestart_fixture"
if grep -q 'verify_oidc_jwks_route || exit 1' "$oidc_norestart_fixture" \
  || grep -q 'restarted deployment/identity so the patched OIDC surface' "$oidc_norestart_fixture"; then
  fail 'control fixture: reconcile restarts nothing' \
    "the restart/wait/probe deletion did not apply, so the control would prove nothing"
  failures=$((failures + 1))
elif ! grep -q 'did not round-trip' "$oidc_norestart_fixture"; then
  fail 'control fixture: reconcile restarts nothing' \
    "the round-trip check is gone too — the fixture is no longer the patch path"
  failures=$((failures + 1))
else
  oidc_red_out=""; oidc_red_ec=0
  oidc_red_out="$(check_oidc_patch_restart "$oidc_norestart_fixture" 2>&1)" || oidc_red_ec=$?
  if [ "$oidc_red_ec" -eq 0 ]; then
    fail 'control: the master-shaped patch leaves the pod stale, failing the check' \
      "exit 0 — the check passed against a patch with no restart, so it discriminates nothing"
  elif case "$oidc_red_out" in *'was not restarted'*) true ;; *) false ;; esac; then
    pass 'control: the master-shaped patch leaves the pod stale, failing the check'
  else
    fail 'control: the master-shaped patch leaves the pod stale, failing the check' "$oidc_red_out"
  fi
fi

MOCK_ROOT="$WORK/oidc-patch-stuck"
rm -rf "$MOCK_ROOT"; mkdir -p "$MOCK_ROOT"
oidc_patch_seed
OIDC_ROLLOUT_FAIL=1
oidc_patch_run "$fixture_sourced"
OIDC_ROLLOUT_FAIL=""
if [ "$oidc_patch_ec" -eq 0 ]; then
  fail 'warm: a stuck OIDC rollout refuses rather than reporting success' "exit 0 — the wait forgave the stuck rollout"
elif ! grep -q 'rollout restart deployment/identity' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
  fail 'warm: a stuck OIDC rollout refuses rather than reporting success' "the restart never ran — the wait was skipped, not lost"
elif ! grep -q 'rollout status deployment/identity' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
  fail 'warm: a stuck OIDC rollout refuses rather than reporting success' "the rollout was never watched"
else
  case "$(cat "$WORK/oidc-patch-run.log")" in
    *'did not roll out after the OIDC patch'*)
      case "$(cat "$WORK/oidc-patch-run.log")" in
        *'JWKS route answers 2'*)
          fail 'warm: a stuck OIDC rollout refuses rather than reporting success' "the run refused AND claimed the route verified"
          ;;
        *)
          pass 'warm: a stuck OIDC rollout refuses rather than reporting success'
          ;;
      esac
      ;;
    *)
      fail 'warm: a stuck OIDC rollout refuses rather than reporting success' "$(cat "$WORK/oidc-patch-run.log")"
      ;;
  esac
fi

MOCK_ROOT="$WORK/oidc-patch-404"
rm -rf "$MOCK_ROOT"; mkdir -p "$MOCK_ROOT"
oidc_patch_seed
OIDC_JWKS_STATUS=404
oidc_patch_run "$fixture_sourced"
OIDC_JWKS_STATUS=""
if [ "$oidc_patch_ec" -eq 0 ]; then
  fail 'warm: a 404 JWKS after the OIDC restart refuses rather than reporting success' "exit 0 — identity_jwks=404 reported as success"
else
  case "$(cat "$WORK/oidc-patch-run.log")" in
    *'answers 404'*)
      pass 'warm: a 404 JWKS after the OIDC restart refuses rather than reporting success'
      ;;
    *)
      fail 'warm: a 404 JWKS after the OIDC restart refuses rather than reporting success' "$(cat "$WORK/oidc-patch-run.log")"
      ;;
  esac
fi

MOCK_ROOT="$WORK/oidc-patch-nodeploy"
rm -rf "$MOCK_ROOT"; mkdir -p "$MOCK_ROOT"
mfa_seed_roles
mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity?sslmode=disable"
mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "legacy-signup"
mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "legacy-mfa"
mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"
mock_seed identity identity-secrets OIDC_ISSUER "$OIDC_FOUR_ISSUER"
mock_seed identity identity-secrets OIDC_SIGNING_KEY "legacy-oidc-key"
mock_seed identity identity-secrets OIDC_SIGNING_KEY_ID "legacy-oidc-kid"
mock_seed gateway gateway-secrets REDIS_URL "redis://:pw@redis.data.svc.cluster.local:6379"
mock_seed gateway gateway-secrets ASSERTION_SIGNING_KEY "dummy"
mock_seed courier courier-secrets DATABASE_URL "ecto://courier_app:pw@host/courier"
mock_seed parlor parlor-secrets DATABASE_URL "postgres://parlor_app:pw@host/parlor"
OIDC_KUBECTL_FN=oidc_nodeploy_kubectl
oidc_patch_run "$fixture_sourced"
OIDC_KUBECTL_FN=""
if [ "$oidc_patch_ec" -ne 0 ]; then
  fail 'warm: the OIDC patch without a Deployment converges the secret and skips the restart' "$(cat "$WORK/oidc-patch-run.log")"
elif [ "$(mock_get identity identity-secrets OIDC_LOGIN_UI_URL)" != "$OIDC_FOUR_LOGIN" ]; then
  fail 'warm: the OIDC patch without a Deployment converges the secret and skips the restart' "the fourth key did not land"
elif grep -q 'rollout restart deployment/identity' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
  fail 'warm: the OIDC patch without a Deployment converges the secret and skips the restart' "a missing Deployment was restarted"
else
  case "$(cat "$WORK/oidc-patch-run.log")" in
    *'restart skipped'*'unverified by this run'*)
      pass 'warm: the OIDC patch without a Deployment converges the secret and skips the restart'
      ;;
    *)
      fail 'warm: the OIDC patch without a Deployment converges the secret and skips the restart' "$(cat "$WORK/oidc-patch-run.log")"
      ;;
  esac
fi

oidc_report_final() {
  (
    . "$fixture_sourced"
    READINESS_TLS_PENDING=""
    READINESS_DNS_SPLIT=""
    READINESS_DNS_STATUS=""
    REGISTRY_PATH="anonymous"
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="$OIDC_FOUR_ISSUER"
    OIDC_ROUTE_VERIFIED="$1"
    OIDC_SECRET_PATCHED="$2"
    kit_substrate_readiness_final
  ) 2>&1
}
oidc_report_out="$(oidc_report_final 1 "")"
case "$oidc_report_out" in
  *'watched its JWKS route answer 2xx'*)
    pass 'report: a verified OIDC run says the route was watched this run'
    ;;
  *)
    fail 'report: a verified OIDC run says the route was watched this run' "$oidc_report_out"
    ;;
esac
oidc_report_out="$(oidc_report_final "" 1)"
case "$oidc_report_out" in
  *'no rollout was watched and the JWKS route is unverified'*)
    pass 'report: a patched-but-unwatched OIDC run names the unverified route'
    ;;
  *)
    fail 'report: a patched-but-unwatched OIDC run names the unverified route' "$oidc_report_out"
    ;;
esac
oidc_report_out="$(oidc_report_final "" "")"
case "$oidc_report_out" in
  *'did not verify identity'"'"'s JWKS route'*)
    pass 'report: an unverified OIDC run does not promise a watched route'
    ;;
  *)
    fail 'report: an unverified OIDC run does not promise a watched route' "$oidc_report_out"
    ;;
esac

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
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "legacy-signup"
  mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "legacy-mfa"
  mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"
  mock_seed gateway gateway-secrets REDIS_URL "redis://:pw@redis.data.svc.cluster.local:6379"
  mock_seed courier courier-secrets DATABASE_URL "ecto://courier_app:pw@host/courier"
  mock_seed parlor parlor-secrets DATABASE_URL "postgres://parlor_app:pw@host/parlor"
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
  run 'control: a PKCS#1 RSA PEM is refused (gateway parses PKCS#8)' red pkey_shape_ok \
    "$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKfake\n-----END RSA PRIVATE KEY-----')"
fi
MOCK_ROOT="$WORK/legacy-gateway" legacy_rerun_ec=0
(
  mfa_seed_roles
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

COURIER_MINT_TOKEN="cap_box_minted_fake_token_value"
APP_BASE_URL="https://app.example.com"
courier_mint_curl() {
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
mint_port=$(( 20000 + (RANDOM % 20000) ))
"$PY" -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
time.sleep(30)' "$mint_port" &
mint_listener=$!
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/${mint_port}") 2>/dev/null && break
  sleep 0.1
done
mint_loop_ec=0
(
  mfa_seed_roles
  mock_seed identity identity-secrets DATABASE_URL "postgres://identity_app:pw@host/identity"
  mock_seed identity identity-secrets SIGNUP_SIGNING_KEY "Ou1NSDx0wZAm5Mbykh8R7gxs8t6Y0-U1fI4kwRmSsd8"
  mock_seed identity identity-secrets MFA_ENCRYPTION_KEY "z-thread-is-long-enough-0123456789-_Xab"
  mock_seed identity deploy-identity ready yes
  export KIT_SUBSTRATE_IDENTITY_LOCAL_PORT="$mint_port"
  export KIT_SUBSTRATE_APP_BASE_URL="$APP_BASE_URL"
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
for kept in DATABASE_URL SIGNUP_SIGNING_KEY MFA_ENCRYPTION_KEY; do
  if [ -n "$(mock_get identity identity-secrets "$kept")" ]; then
    pass "the mint patches identity-secrets without dropping ${kept}"
  else
    fail "the mint patches identity-secrets without dropping ${kept}" "the key is gone after the mint"
  fi
done
run 'the mint loop never echoes the minted credential' green oidc_log_clean "$(cat "$WORK/mint-loop.log")" "$COURIER_MINT_TOKEN"
run 'control: a minted credential echoed into the log is caught' red oidc_log_clean "patched with COURIER_IDENTITY_TOKEN=${COURIER_MINT_TOKEN}" "$COURIER_MINT_TOKEN"

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
dead_port=$(( 40000 + (RANDOM % 15000) ))
dead_ec=0
(
  . "$fixture_sourced"
  kit_substrate_await_port "$dead_port" 2
) || dead_ec=$?
if [ "$dead_ec" -ne 0 ]; then
  pass 'control: the port wait fails against a dead port (it is bounded and honest)'
else
  fail 'control: the port wait fails against a dead port (it is bounded and honest)' \
    "kit_substrate_await_port returned 0 for a port nothing listens on"
fi

migrate_seed_fixture() {
  mkdir -p "$MOCK_ROOT/data" "$MOCK_ROOT/identity" "$MOCK_ROOT/courier" "$MOCK_ROOT/billing"
  printf 'data\nidentity\ncourier\nbilling\n' >"$MOCK_ROOT/namespaces"
  mock_seed data postgres-role-identity password "owner-identity-pw"
  mock_seed data postgres-role-courier password "owner-courier-pw"
  mock_seed data postgres-role-courier-app password "app-courier-pw"
  mock_seed data postgres-role-billing password "owner-billing-pw"
  mock_seed data postgres-role-billing-app password "app-billing-pw"
  mock_seed identity deploy-identity image "ghcr.io/anywaye/identity:0.1.0"
  mock_seed courier deploy-courier image "ghcr.io/anywaye/courier:0.1.0"
  mock_seed billing deploy-billing image "ghcr.io/anywaye/billing:0.1.0"
  mock_seed billing billing-secrets SECRET_KEY_BASE "base64-secret-for-the-gate"
  : >"$MOCK_ROOT/data/cluster-postgres"
  : >"$MOCK_ROOT/data/cluster-postgres-ready"
  printf 'Cluster in healthy state' >"$MOCK_ROOT/data/cluster-postgres-phase"
}

MOCK_ROOT="$WORK/migrate-run"
mkdir -p "$MOCK_ROOT"
migrate_run_ec=0
(
  migrate_seed_fixture
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-run-receipt.json"
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
if grep -q -- '--image=ghcr.io/anywaye/identity:0.1.0' "$migrate_argv" 2>/dev/null &&
   grep -q -- '--image=ghcr.io/anywaye/courier:0.1.0' "$migrate_argv" 2>/dev/null &&
   grep -q -- '--image=ghcr.io/anywaye/billing:0.1.0' "$migrate_argv" 2>/dev/null; then
  pass 'step 10 migrates in each service own RUNNING image (read off the Deployment)'
else
  fail 'step 10 migrates in each service own RUNNING image (read off the Deployment)' \
    "argv images: $(grep -o -- '--image=[^ ]*' "$migrate_argv" 2>/dev/null | sort -u | tr '\n' ' ')"
fi
if [ "$(mock_get data substrate-migrations identity)" = "ghcr.io/anywaye/identity:0.1.0" ] &&
   [ "$(mock_get data substrate-migrations courier)" = "ghcr.io/anywaye/courier:0.1.0" ] &&
   [ "$(mock_get data substrate-migrations billing)" = "ghcr.io/anywaye/billing:0.1.0" ]; then
  pass 'step 10 records the applied image per service (the re-run marker)'
else
  fail 'step 10 records the applied image per service (the re-run marker)' \
    "marker identity='$(mock_get data substrate-migrations identity)' courier='$(mock_get data substrate-migrations courier)' billing='$(mock_get data substrate-migrations billing)'"
fi
if grep -q -- '--image=.*parlor' "$migrate_argv" 2>/dev/null; then
  fail 'step 10 does not run a migrate Job for parlor (it owns no schema)' "a parlor run was recorded"
else
  pass 'step 10 does not run a migrate Job for parlor (it owns no schema)'
fi

runs_before="$(grep -c '^run ' "$migrate_argv" 2>/dev/null || true)"
migrate_rerun_ec=0
(
  migrate_seed_fixture
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-rerun-receipt.json"
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

MOCK_ROOT="$WORK/migrate-fail"
mkdir -p "$MOCK_ROOT"
migrate_fail_ec=0
(
  migrate_seed_fixture
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-fail-receipt.json"
  export MOCK_POD_PHASE="Failed"
  export MOCK_POD_LOGS="permission denied for schema public"
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
if grep -q 'permission denied for schema public' "$WORK/migrate-fail.log"; then
  pass 'control: the failed migration prints the pod logs'
else
  fail 'control: the failed migration prints the pod logs' "the logs were not printed"
fi
if grep -q "cluster: postgres in namespace data (phase: 'Cluster in healthy state')" "$WORK/migrate-fail.log"; then
  pass 'control: the failed migration names the Cluster and its phase'
else
  fail 'control: the failed migration names the Cluster and its phase' \
    "no cluster phase in the failure: $(cat "$WORK/migrate-fail.log")"
fi
if grep -q -- 'wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data --timeout=600s' "$migrate_argv" 2>/dev/null; then
  pass 'step 10 waits for the Cluster to be Ready before launching any migrate pod, under the 600s bound'
else
  fail 'step 10 waits for the Cluster to be Ready before launching any migrate pod, under the 600s bound' \
    "no bounded Cluster wait in the recorded argv"
fi

MOCK_ROOT="$WORK/migrate-halfready"
mkdir -p "$MOCK_ROOT"
migrate_halfready_ec=0
(
  migrate_seed_fixture
  rm -f "$MOCK_ROOT/data/cluster-postgres-ready"
  printf 'Setting up primary' >"$MOCK_ROOT/data/cluster-postgres-phase"
  export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-halfready-receipt.json"
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  install_migrations >"$WORK/migrate-halfready.log" 2>&1
) || migrate_halfready_ec=$?
if [ "$migrate_halfready_ec" -eq 0 ]; then
  fail 'control: a half-ready Cluster refuses the migrations (no race into connection refused)' \
    "install_migrations exited 0 with the Cluster never Ready"
elif ! grep -q 'Setting up primary' "$WORK/migrate-halfready.log"; then
  fail 'control: a half-ready Cluster refuses the migrations (no race into connection refused)' \
    "the refusal did not name the Cluster phase: $(cat "$WORK/migrate-halfready.log")"
elif grep -q '^run kit-migrate' "$MOCK_ROOT/kubectl-argv" 2>/dev/null; then
  fail 'control: a half-ready Cluster refuses the migrations (no race into connection refused)' \
    "a migrate pod launched against a Cluster that never reported Ready"
else
  pass 'control: a half-ready Cluster refuses the migrations, naming its phase, launching nothing'
fi
MOCK_ROOT="$WORK/migrate-fail"

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
body = re.search(r"(?m)^install_migrations\(\)\s*\{(.*?)\n\}", code, re.S)
if not body or "migration_guard_applied" not in body.group(1):
    problems.append("install_migrations never consults its guard")
if not re.search(r"(?m)^owner_database_url_for\(\)", code):
    problems.append("no owner_database_url_for — the migrate DSN must be the OWNER role")
m = re.search(r"migration_service_has_schema\(\)\s*\{(.*?)\n\}", code, re.S)
if not m:
    problems.append("no migration_service_has_schema inventory")
else:
    for svc in ("identity", "courier", "billing"):
        if svc not in m.group(1):
            problems.append(f"{svc} is not in the migration inventory")
need("did not succeed", "the failure path has no message")
need("logs \"pod/kit-migrate-", "the failure path does not print the pod logs")
if re.search(r"--command -- \$cmd[^\n]*\|\| true", code):
    problems.append("the migrate command is swallowed with `|| true`")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("step 10 exists, is called, has a guard and an OWNER-role inventory")
PY
}

run 'step 10 has a step, a guard and an OWNER-role inventory' green check_migration_step "$SUBSTRATE/install.sh"

fixture_mig_inventory="$WORK/install-mig-inventory.sh"
sed 's/    identity | courier | billing) return 0 ;;/    identity) return 0 ;;/' \
  "$SUBSTRATE/install.sh" >"$fixture_mig_inventory"
run 'control: an inventory missing a service goes red' red check_migration_step "$fixture_mig_inventory"


check_migration_parallel() {
  local argv="$1/kubectl-argv"
  if [ ! -f "$argv" ]; then
    echo "no kubectl-argv at $argv — the mock recorded nothing"
    return 1
  fi
  local last_run first_get
  last_run="$(grep -n "run kit-migrate" "$argv" | tail -1 | cut -d: -f1)"
  first_get="$(grep -n "get pod kit-migrate" "$argv" | head -1 | cut -d: -f1)"
  if [ -z "$last_run" ] || [ -z "$first_get" ]; then
    echo "the run did not record both a run and a get (run:${last_run:-none} get:${first_get:-none})"
    return 1
  fi
  if [ "$first_get" -le "$last_run" ]; then
    echo "a phase poll appears before the last launch (first_get $first_get, last_run $last_run) — the Jobs are still sequential"
    return 1
  fi
  local runs_before
  runs_before="$(head -n "$((first_get - 1))" "$argv" | grep -c "run kit-migrate" || true)"
  local total_runs
  total_runs="$(grep -c "run kit-migrate" "$argv" || true)"
  if [ "$runs_before" != "$total_runs" ]; then
    echo "only $runs_before of $total_runs runs before the first poll — interleaved"
    return 1
  fi
  echo "applies grouped: $total_runs runs before first poll (first_get $first_get, last_run $last_run)"
}

run 'step 10 launches the independent Jobs before waiting on any (grouped)' green \
  check_migration_parallel "$MOCK_ROOT"

check_migration_timeout() {
  MOCK_ROOT="$WORK/migrate-timeout"
  mkdir -p "$MOCK_ROOT"
  migrate_run_ec=0
  (
    MOCK_ROOT="$MOCK_ROOT"
    migrate_seed_fixture
    export KIT_SUBSTRATE_RECEIPT="$WORK/migrate-timeout-receipt.json"
    . "$fixture_sourced"
    kubectl() {
      if [ -n "${MOCK_ROOT:-}" ]; then printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"; fi
      local verb="${1:-}"; shift || true
      case "$verb" in
        create) local r="${1:-}"; shift || true
          if [ "$r" = "secret" ]; then [ "${1:-}" = "generic" ] && shift; local n="${1:-}"; shift || true; local ns="$fallback_ns" lits=()
            local d="$MOCK_ROOT/$ns/$n"; mkdir -p "$d"; local e k v; for e in ${lits[@]+"${lits[@]}"}; do k="${e%%=*}"; v="${e#*=}"; printf '%s' "$v" >"$d/$k"; done; return 0; fi; return 0;;
        get) if [ "${1:-}" = "deployment" ]; then shift; local dn="${1:-}"; shift || true; local d_ns="" d_tmpl=""
            if [ -d "$MOCK_ROOT/$d_ns/deploy-$dn" ]; then case "$d_tmpl" in *image*) cat "$MOCK_ROOT/$d_ns/deploy-$dn/image" 2>/dev/null || true;; *) printf '%s   1/1\n' "$dn";; esac; fi; return 0; fi
          if [ "${1:-}" = "pod" ]; then shift; local pn="${1:-}"; shift || true; local p_ns="$fallback_ns" p_tmpl=""
            local pdir="$MOCK_ROOT/$p_ns/pod-$pn"; [ -d "$pdir" ] || { printf 'Pending'; return 0; }
            case "$p_tmpl" in *status.phase*) cat "$pdir/phase" 2>/dev/null || printf 'Pending';; *) printf '%s   0/1\n' "$pn";; esac; return 0; fi
          if [ "${1:-}" != "secret" ]; then return 1; fi
          shift || true; local nm="${1:-}"; shift || true; local n_ns="" t=""
          local dir="$MOCK_ROOT/$n_ns/$nm"
          if [ -z "$t" ]; then [ -d "$dir" ] && return 0 || return 1; fi
          local k2="${t#jsonpath={.data.}"; k2="${k2%\}}"; [ -z "$k2" ] || [ "$k2" = "$t" ] || [ ! -f "$dir/$k2" ] && return 1
          base64 <"$dir/$k2" | tr -d '\n'; return 0;;
        delete) return 0;;
        run) local rn="${1:-}"; shift || true; local r_ns="$fallback_ns" r_img="" r_cmd="" r_env=""
          local rdir="$MOCK_ROOT/$r_ns/pod-$rn"; mkdir -p "$rdir"
          printf '%s' "$r_img" >"$rdir/image"; printf '%s' "$r_cmd" >"$rdir/command"; printf '%s' "$r_env" >"$rdir/env"
          printf 'Pending' >"$rdir/phase"
          return 0;;
        logs) return 0;;
        *) return 0;; esac
    }
    sleep() { :; }
    install_migrations >"$WORK/migrate-timeout.log" 2>&1
  ) || migrate_run_ec=$?
  if [ "$migrate_run_ec" -eq 0 ]; then
    echo "install_migrations exited 0 on a never-Completing pod"
    return 1
  fi
  if ! grep -q "did not succeed" "$WORK/migrate-timeout.log"; then
    echo "the timeout did not report the failing service"
    cat "$WORK/migrate-timeout.log" | head -20
    return 1
  fi
  local polls
  polls="$(grep -c "get pod kit-migrate" "$MOCK_ROOT/kubectl-argv" || true)"
  if [ "$polls" -lt 36 ]; then
    echo "only $polls phase polls before timeout, want 36 per Job (today's bound)"
    return 1
  fi
  echo "timed out after $polls phase polls, naming the Job"
}
run 'step 10 times out on today bound when a Job never Completes' green \
  check_migration_timeout

check_migration_timing() {
  local jsonl="$WORK/timing-migrate.jsonl"
  KIT_SUBSTRATE_RECEIPT="$WORK/timing-migrate-receipt.json" \
  KIT_SUBSTRATE_DATABASES="$DBS" HEADLESS=1 DRY_RUN=1 \
    bash "$SUBSTRATE/install.sh" >"$jsonl" 2>/dev/null || true
  if ! grep -q '"phase":"migrations"' "$jsonl"; then
    echo "no migrations phase in the headless JSONL"
    return 1
  fi
  if ! grep -q '"event":"step.done".*"phase":"migrations"' "$jsonl"; then
    echo "no step.done for migrations"
    return 1
  fi
  if ! grep -q '"event":"step.done".*"seconds":' "$jsonl"; then
    echo "step.done carries no seconds"
    return 1
  fi
  echo "migrations step reports seconds in both start and done"
}
run 'step 10 seconds are still reported per-step (the measurement ledger)' green \
  check_migration_timing


fixture_seq="$WORK/install-seq.sh"
cat >"$fixture_seq" <<'FIXSEQ'
install_migrations() {
  for svc in identity courier; do
    kubectl run kit-migrate-$svc -n $svc --image=x --command -- /app/bin/migrate || true
    kubectl get pod kit-migrate-$svc -n $svc -o jsonpath={.status.phase} >/dev/null || true
  done
}
FIXSEQ
check_seq_grouped() {
  MOCK_ROOT="$WORK/migrate-seq"
  mkdir -p "$MOCK_ROOT"
  printf '%s\n' \
    "--kubeconfig=x run kit-migrate-identity -n identity --image=x" \
    "--kubeconfig=x get pod kit-migrate-identity -n identity -o jsonpath={.status.phase}" \
    "--kubeconfig=x run kit-migrate-courier -n courier --image=x" \
    "--kubeconfig=x get pod kit-migrate-courier -n courier -o jsonpath={.status.phase}" \
    >"$MOCK_ROOT/kubectl-argv"
  check_migration_parallel "$MOCK_ROOT"
}
run 'control: the sequential (master) shape fails the grouped-applies check' red \
  check_seq_grouped

check_migration_ordering() {
  local src="$1"
  local code
  code="$(sed -e 's/#.*//' "$src")"
  if grep -q "courier.*after.*identity\|courier.*depends.*identity" "$src" 2>/dev/null; then
    if grep -q 'launched+=.*\$svc' "$src" 2>/dev/null; then
      echo "courier depends on identity but is launched in the first wave"
      return 1
    fi
  fi
  case "$code" in
    *'launched+=('*'$svc'*) ;;
    *)
      echo "the parallel launch set is not present"
      return 1
      ;;
  esac
  if ! grep -q 'CREATE DATABASE "identity" OWNER "identity"' "$SUBSTRATE/manifests/data/postgres-cluster.yaml"; then
    echo "postgres-cluster does not provision separate OWNER databases"
    return 1
  fi
  if ! grep -q 'CREATE DATABASE "courier" OWNER "courier"' "$SUBSTRATE/manifests/data/postgres-cluster.yaml"; then
    echo "postgres-cluster does not provision courier OWNER database"
    return 1
  fi
  echo "no ordering constraint between identity and courier (separate OWNER databases, per postgres-cluster.yaml)"
}
run 'step 10 ordering: no constraint between identity and courier (separate OWNER databases)' green \
  check_migration_ordering "$SUBSTRATE/install.sh"

fixture_dep="$WORK/install-dep.sh"
sed 's/# INDEPENDENCE:.*/# DEPENDS: courier after identity/' "$SUBSTRATE/install.sh" >"$fixture_dep"
printf '\n# courier depends on identity\n' >>"$fixture_dep"
run 'control: a dependent Job launched in the first wave fails the ordering check' red \
  check_migration_ordering "$fixture_dep"


check_headless_stdout() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

EMITTERS = {
    "json_str",
    "kit_substrate_emit",
    "kit_substrate_out",
    "kit_substrate_write_receipt",
    "kit_substrate_refuse",
}

VALUE_PRODUCERS = {
    "database_url_for", "owner_database_url_for", "migration_env_args_for", "oidc_key_id_for",
    "kit_substrate_now", "kit_substrate_seconds", "kit_substrate_elapsed",
    "kit_substrate_url_host", "kit_substrate_intended_hosts",
    "kit_substrate_intended_host_table", "kit_substrate_host_source",
    "kit_substrate_ingress_host", "kit_substrate_ingress_hosts",
    "kit_substrate_readiness_pending_count", "kit_substrate_readiness_summary",
    "kit_substrate_readiness_json", "kit_substrate_log_store",
    "registry_derived_artifacts",
}

SECRET_VARS = {
    "OIDC_SIGNING_KEY_ID",
    "KIT_SUBSTRATE_REGISTRY_CAPABILITY",
    "KIT_SUBSTRATE_SMTP_PASSWORD",
    "KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET",
    "KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY",
    "KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY",
    "signup_key", "mfa_key", "oidc_key", "oidc_key_id",
    "secret_base", "secret_box", "relay_token", "redis_pw", "pw",
    "token", "session_token", "owner_password",
    "mint_timestamp", "mint_signature", "out", "session", "account_id",
}

fn_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
stmt_re = re.compile(r"^\s*(echo|printf)\b(.*)$")
var_re = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")

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
    if ">&2" in rest:
        continue
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
    for name in var_re.findall(line):
        if name in SECRET_VARS:
            problems.append(
                f"line {n}: ${name} reaches the stdout path — "
                "a secret-shaped variable must never be expanded there"
            )

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
out_body = re.search(r"^kit_substrate_out\(\)\s*\{(.*?)^\}", src, re.M | re.S)
if not out_body or ">&2" not in out_body.group(1):
    problems.append("kit_substrate_out does not send the human channel to stderr")

for name in sorted(VALUE_PRODUCERS):
    for m in re.finditer(r"(?<![\w$])" + re.escape(name) + r"\s*\(", src):
        before = src[: m.start()]
        line_start = before.rfind("\n") + 1
        if not src[line_start : m.start()].strip():
        window = src[max(0, line_start - 2) : m.start()]
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

fixture_secret_out="$WORK/install-secret-out.sh"
cp "$SUBSTRATE/install.sh" "$fixture_secret_out"
printf '\n  kit_substrate_out "relay password ${KIT_SUBSTRATE_SMTP_PASSWORD}"\n' >>"$fixture_secret_out"
run 'control: a secret-shaped variable on the human channel goes red' red check_headless_stdout "$fixture_secret_out"

fixture_secret_emit="$WORK/install-secret-emit.sh"
cp "$SUBSTRATE/install.sh" "$fixture_secret_emit"
printf '\n  kit_substrate_emit progress "redeemed ${response}"\n' >>"$fixture_secret_emit"
run 'control: a secret-shaped variable on the stdout channel goes red' red check_headless_stdout "$fixture_secret_emit"

fixture_no_pipe="$WORK/install-no-pipe.sh"
cp "$SUBSTRATE/install.sh" "$fixture_no_pipe"
printf '\n  printf "%%s" "$response"\n' >>"$fixture_no_pipe"
run 'control: a piped secret moved onto stdout goes red' red check_headless_stdout "$fixture_no_pipe"

headless_receipt="$WORK/headless-receipt.json"
MOCK_ROOT="$WORK/headless"
mkdir -p "$MOCK_ROOT"
headless_ec=0
(
  export DRY_RUN=0
  export HEADLESS=1
  export KIT_SUBSTRATE_RECEIPT="$headless_receipt"
  export KIT_SUBSTRATE_SMTP_HOST="relay.example.com"
  export KIT_SUBSTRATE_SMTP_USERNAME="relay-user"
  export KIT_SUBSTRATE_SMTP_PASSWORD="relay-pass-fake"
  export KIT_SUBSTRATE_COURIER_INBOUND_RESEND_SECRET="provider-signing-fake"
  export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
  export KIT_SUBSTRATE_IDENTITY_MFA_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_IDENTITY_OAUTH_ENCRYPTION_KEY=""
  export KIT_SUBSTRATE_STRIPE_API_KEY="sk_test_dummy_for_the_gate"
  export KIT_SUBSTRATE_STRIPE_WEBHOOK_SECRET="whsec_dummy_for_the_gate"
  mfa_seed_roles
  . "$fixture_sourced"
  kubectl() { mock_kubectl "$@"; }
  CURRENT_PHASE="redis-and-secrets"
  log_step "Redis (single instance) and the services' secrets (identity, gateway, courier, parlor)"
  install_service_secrets
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
  "sk_test_dummy_for_the_gate"
  "whsec_dummy_for_the_gate"
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

run 'headless: a generated DATABASE_URL never reaches stdout' green \
  headless_absent "$WORK/headless.jsonl" \
  "$(mock_get identity identity-secrets DATABASE_URL)" \
  "$(mock_get courier courier-secrets DATABASE_URL)"

case "$(cat "$WORK/headless.human")" in
  *"secret identity-secrets created"*"error: KIT_SUBSTRATE_ACME_EMAIL is not set"*)
    pass 'headless: the human channel still carries the detail lines and the refusal'
    ;;
  *)
    fail 'headless: the human channel still carries the detail lines and the refusal' "$(cat "$WORK/headless.human")"
    ;;
esac
if grep -q 'secret identity-secrets created' "$WORK/headless.jsonl"; then
  fail 'headless: the human detail lines are not on stdout' "a prose line reached the JSONL channel"
else
  pass 'headless: the human detail lines are not on stdout'
fi

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

fixture_receipt_no_human="$WORK/receipt-no-human.json"
sed 's/  "human": .*$/  "human": "",/' "$headless_receipt" >"$fixture_receipt_no_human"
run 'control: a receipt with no human destination goes red' red headless_receipt_ok "$fixture_receipt_no_human"

fixture_receipt_running="$WORK/receipt-running.json"
sed 's/"status": "refused"/"status": "running"/' "$headless_receipt" >"$fixture_receipt_running"
run 'control: a refusal recorded as running goes red' red headless_receipt_ok "$fixture_receipt_running"

refusal_hint_ok() {
  local log mode="$2"
  case "$1" in
    *"error: KIT_SUBSTRATE_DATABASES is not set"*"export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing'"*)
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
KIT_SUBSTRATE_RECEIPT="$headless_refuse_hint" KIT_SUBSTRATE_DATABASES="" DRY_RUN=1 \
  bash "$SUBSTRATE/install.sh" --headless >"$WORK/headless-refuse.jsonl" \
  2>"$WORK/headless-refuse.human" || headless_refuse_ec=$?
if [ "$headless_refuse_ec" -eq 0 ]; then
  fail 'the refusal names the variable and the fix that clears it (headless)' "exit 0 — the plan was not refused"
else
  run 'the refusal names the variable and the fix that clears it (headless)' green \
    refusal_hint_ok "$(cat "$WORK/headless-refuse.human")" headless
fi
case "$(cat "$WORK/headless-refuse.jsonl")" in
  *'"event":"refusal"'*'"input_needed":"KIT_SUBSTRATE_DATABASES"'*'"human":"export KIT_SUBSTRATE_DATABASES='*)
    pass 'headless: the refusal event names the input needed and where the human goes'
    ;;
  *)
    fail 'headless: the refusal event names the input needed and where the human goes' "$(cat "$WORK/headless-refuse.jsonl")"
    ;;
esac
refusal_no_human='{"event":"refusal","step":8,"phase":"postgres","input_needed":"KIT_SUBSTRATE_DATABASES","human":null,"message":"x"}'
case "$refusal_no_human" in
  *'"event":"refusal"'*'"input_needed":"KIT_SUBSTRATE_DATABASES"'*'"human":"export KIT_SUBSTRATE_DATABASES='*)
    fail 'control: a refusal event with no human destination goes red' 'a null human matched the want'
    ;;
  *)
    pass 'control: a refusal event with no human destination goes red'
    ;;
esac

check_apply_modes() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
code = code.replace("\\\n", " ")

problems = []
remote = 0
local = 0
for ln in code.splitlines():
    if "kubectl" not in ln or "apply" not in ln:
        continue
    m = re.search(r"(?:^|\s)-f\s+\"?([^\s\"]+)\"?", ln)
    if not m:
        continue
    target = m.group(1)
    if target.startswith(("http://", "https://")):
        remote += 1
        for flag in ("--server-side=true", "--force-conflicts"):
            if flag not in ln:
                problems.append(f"{target}: a remote apply without {flag}")
    elif target == "-" or target.startswith(("$", "/", ".")):
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

fixture_new_remote="$WORK/install-new-remote.sh"
cp "$SUBSTRATE/install.sh" "$fixture_new_remote"
printf '  kubectl --kubeconfig="$KUBECONFIG" apply -f "https://example.com/some-new-operator.yaml"\n' \
  >>"$fixture_new_remote"
run 'control: a fourth remote apply with no flags goes red' red check_apply_modes "$fixture_new_remote"

fixture_local_ss="$WORK/install-local-server-side.sh"
sed 's|apply -f "$DATA_DIR/postgres-cluster.yaml"|apply --server-side=true --force-conflicts -f "$DATA_DIR/postgres-cluster.yaml"|' \
  "$SUBSTRATE/install.sh" >"$fixture_local_ss"
run 'control: a local apply carrying the remote flags goes red' red check_apply_modes "$fixture_local_ss"

fixture_plan_drift="$WORK/install-plan-drift.sh"
awk '/dry_run/ { gsub(/ --server-side=true --force-conflicts/, ""); } { print }' \
  "$SUBSTRATE/install.sh" >"$fixture_plan_drift"
run 'control: a plan that lost the flags while the run kept them goes red' red \
  check_apply_modes "$fixture_plan_drift"

K3S_DIR="$WORK/k3s"
mkdir -p "$K3S_DIR"

node_kubectl() {
  printf '%s\n' "$*" >>"$K3S_DIR/argv"
  case "$*" in
    *"wait --for=condition=Ready node"*)
      if [ ! -f "$K3S_DIR/node-registered" ]; then
        printf 'error: no matching resources found\n' >&2
        return 1
      fi
      printf 'node/box condition met\n'
      ;;
    *"get node --no-headers"*)
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

k3s_step() {
  rm -f "$K3S_DIR/argv" "$K3S_DIR/polls" "$K3S_DIR/node-registered"
  k3s_ec=0
  (
    export DRY_RUN=0
    export HEADLESS=0
    export KIT_SUBSTRATE_RECEIPT="$K3S_DIR/receipt.json"
    export NODE_APPEARS_AT="$2"
    export NODE_REGISTER_TIMEOUT="$3"
    export NODE_READY_TIMEOUT=5
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

if grep -q 'kit_substrate_await_list "\$NODE_REGISTER_TIMEOUT" node' "$k3s_no_await" \
  || ! grep -q 'wait --for=condition=Ready node' "$k3s_no_await"; then
  fail 'control fixture: the pre-fix k3s step is the shape the box ran' \
    "the await-line deletion did not apply, so case 3 would prove nothing"
  failures=$((failures + 1))
else
  k3s_step "$k3s_cold" 2 5
  k3s_cold_ok() {
    if [ "$k3s_ec" -ne 0 ]; then
      printf 'step 1 exited %s — an empty list still kills the install\n%s\n' \
        "$k3s_ec" "$(cat "$K3S_DIR/run.log")"
      return 1
    fi
    if ! grep -q 'wait --for=condition=Ready node' "$K3S_DIR/argv"; then
      printf 'the Ready wait never ran — the step gave up before waiting\n%s\n' \
        "$(cat "$K3S_DIR/run.log")"
      return 1
    fi
    if [ "$(cat "$K3S_DIR/polls" 2>/dev/null || echo 0)" -ne 2 ]; then
      printf 'the fake registered the node on the first poll, so the empty-list case never happened\n'
      return 1
    fi
    printf 'the step survived an empty list and reached Ready'
  }
  run 'step 1 reaches Ready when the node registers a few seconds after k3s starts' \
    green k3s_cold_ok

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

wait_lists_audit() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
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
            named += 1
            continue
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

if awaited < 1:
    print(f"expected at least 1 awaited list wait (the node), "
          f"found {awaited}")
    sys.exit(1)
if applied < 2:
    print(f"expected the two --all waits that ride a synchronous apply "
          f"(cert-manager, Argo CD), found {applied}")
    sys.exit(1)
if named < 3:
    print(f"expected the named waits to still be there, found {named}")
    sys.exit(1)
if rollout_awaited < 1:
    print("expected step 11's rollout watch to prove the Deployment exists "
          "first (Argo syncs it asynchronously), found none")
    sys.exit(1)

defaults = dict(re.findall(r"^\s*: \"\$\{([A-Za-z_]+):=(\d+)\}\"", code, re.M))
for a, b, total, what in (
    ("NODE_REGISTER_TIMEOUT", "NODE_READY_TIMEOUT", 120, "step 1"),
    ("IDENTITY_DEPLOY_TIMEOUT", "IDENTITY_ROLLOUT_TIMEOUT", 360, "step 11"),
    ("OPERATOR_IMAGE_PULL_TIMEOUT", "CNPG_READY_TIMEOUT", 480, "step 4 cnpg (pull+ready)"),
    ("OPERATOR_IMAGE_PULL_TIMEOUT", "CERT_MANAGER_READY_TIMEOUT", 480, "step 4 cert-manager (pull+ready)"),
    ("OPERATOR_IMAGE_PULL_TIMEOUT", "ARGOCD_READY_TIMEOUT", 600, "step 4 argocd (pull+ready)"),
):
    pair = [int(defaults.get(v, -1)) for v in (a, b)]
    if sum(pair) != total:
        print(
            f"{what}'s bound grew: {a}+{b} = {sum(pair)}s, want {total}s "
            "— splitting a wait into two must not make the step more patient"
        )
        sys.exit(1)
for v, total, what in (
    ("CNPG_CLUSTER_READY_TIMEOUT", 600, "step 8 (fresh install) and step 10 (re-run pre-wait)"),
):
    if int(defaults.get(v, -1)) != total:
        print(
            f"{what}'s bound {v} is {defaults.get(v, 'absent')}, want {total}s "
            "— the Cluster wait must not grow more patient than the pod wait it replaced"
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

fixture_grown_cluster_bound="$WORK/install-grown-cluster-bound.sh"
sed 's/: "${CNPG_CLUSTER_READY_TIMEOUT:=600}"/: "${CNPG_CLUSTER_READY_TIMEOUT:=900}"/' \
  "$SUBSTRATE/install.sh" >"$fixture_grown_cluster_bound"
if ! grep -q 'CNPG_CLUSTER_READY_TIMEOUT:=900' "$fixture_grown_cluster_bound"; then
  fail 'control fixture: the Cluster bound-growing edit failed to apply' \
    "the sed did not change the number, so the control would prove nothing"
  failures=$((failures + 1))
else
  mode_out=""; mode_ec=0
  mode_out="$(wait_lists_audit "$fixture_grown_cluster_bound" 2>&1)" || mode_ec=$?
  case "$mode_ec:$mode_out" in
    0:*)
      fail 'control: growing the Cluster bound goes red' "exit 0 — a step that waits longer passes the audit"
      ;;
    *CNPG_CLUSTER_READY_TIMEOUT*)
      pass 'control: growing the Cluster bound goes red, naming the bound'
      ;;
    *)
      fail 'control: growing the Cluster bound goes red, naming the bound' "$mode_out"
      ;;
  esac
fi

fixture_new_list_wait="$WORK/install-new-list-wait.sh"
cp "$SUBSTRATE/install.sh" "$fixture_new_list_wait"
printf '  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd --all --timeout=120s\n' \
  >>"$fixture_new_list_wait"
run 'control: a new list wait with no existence check goes red' red \
  wait_lists_audit "$fixture_new_list_wait"

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

fixture_new_rollout="$WORK/install-new-rollout.sh"
cp "$SUBSTRATE/install.sh" "$fixture_new_rollout"
printf '  kubectl --kubeconfig="$KUBECONFIG" -n courier rollout status deployment/courier --timeout=60s\n' \
  >>"$fixture_new_rollout"
run 'control: a new rollout watch with no existence check goes red' red \
  wait_lists_audit "$fixture_new_rollout"

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

check_cnpg_cluster_wait() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
problems = []

CLUSTER_WAIT = "wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data"
if code.count(CLUSTER_WAIT) < 2:
    problems.append(
        "expected the Cluster Ready wait in BOTH step 8 and step 10's pre-wait, "
        f"found {code.count(CLUSTER_WAIT)}"
    )
if '--timeout="${CNPG_CLUSTER_READY_TIMEOUT}s"' not in code:
    problems.append("the Cluster wait is not bounded by CNPG_CLUSTER_READY_TIMEOUT")
if "wait --for=condition=Ready pod -l cnpg.io/cluster=postgres" in code:
    problems.append("the pod-selector wait is still there — the initdb Job pod satisfies it")
if "CNPG_POD_TIMEOUT" in code or "CNPG_POD_READY_TIMEOUT" in code:
    problems.append("the old pod-wait bound names survive — retire them with the wait")
if not re.search(r"(?m)^cnpg_cluster_phase\(\)", code):
    problems.append("no cnpg_cluster_phase helper for the failure messages")
for step in ("install_postgres_cluster", "install_migrations"):
    body = re.search(r"(?m)^" + step + r"\(\)\s*\{(.*?)\n\}", code, re.S)
    if not body or "cnpg_cluster_phase" not in body.group(1):
        problems.append(f"{step} never reads the Cluster phase for its failures")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("the Cluster Ready wait (x2, bounded), no pod-selector wait, phase named in both steps")
PY
}

run 'step 8 and step 10 wait on the Cluster Ready condition, never on its pods' green \
  check_cnpg_cluster_wait "$SUBSTRATE/install.sh"

fixture_pod_wait="$WORK/install-pod-wait.sh"
"$PY" - "$SUBSTRATE/install.sh" "$fixture_pod_wait" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
pod_wait = ("  kit_substrate_await_list \"$CNPG_POD_TIMEOUT\" pod -l cnpg.io/cluster=postgres -n data\n"
            "  kubectl --kubeconfig=\"$KUBECONFIG\" wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n data --timeout=\"$((CNPG_POD_READY_TIMEOUT))s\"\n")
cluster_wait = "wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data"
assert src.count(cluster_wait) >= 1, "premise: the real tree has no Cluster wait to replace"
first = src.index(cluster_wait)
line_start = src.rindex("\n", 0, first) + 1
line_end = src.index("\n", first) + 1
fixture = src[:line_start] + pod_wait + src[line_end:]
open(sys.argv[2], "w", encoding="utf-8").write(fixture)
PY
if grep -q 'wait --for=condition=Ready pod -l cnpg.io/cluster=postgres' "$fixture_pod_wait"; then
  run 'control: the master pod-selector wait goes red' red \
    check_cnpg_cluster_wait "$fixture_pod_wait"
else
  fail 'control fixture: the pod-wait restoration failed to apply' \
    "the fixture carries no pod wait, so the control would prove nothing"
  failures=$((failures + 1))
fi

fixture_no_cluster_wait="$WORK/install-no-cluster-wait.sh"
grep -v 'wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres' \
  "$SUBSTRATE/install.sh" >"$fixture_no_cluster_wait"
if grep -q 'wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres' "$fixture_no_cluster_wait"; then
  fail 'control fixture: the Cluster-wait deletion failed to apply' \
    "the fixture still carries the wait, so the control would prove nothing"
  failures=$((failures + 1))
else
  run 'control: a deleted Cluster wait goes red (it would forgive a stuck cluster)' red \
    check_cnpg_cluster_wait "$fixture_no_cluster_wait"
fi

pg8_seed() {
  mkdir -p "$1" "$1/data"
  if [ "$2" = "yes" ]; then
    : >"$1/data/cluster-postgres-ready"
    printf 'Cluster in healthy state' >"$1/data/cluster-postgres-phase"
  else
    printf 'Setting up primary' >"$1/data/cluster-postgres-phase"
  fi
}

pg8_step() {
  pg8_ec=0
  (
    export DRY_RUN=0
    export HEADLESS=0
    export KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor,billing"
    export KIT_SUBSTRATE_RECEIPT="$2/receipt.json"
    MOCK_ROOT="$2"
    . "$1"
    kubectl() { mock_kubectl "$@"; }
    DATA_DIR="$SUBSTRATE/manifests/data"
    install_postgres_cluster >"$2/run.log" 2>&1
  ) || pg8_ec=$?
}

pg8_cold="$WORK/install-pg8-cold.sh"
sed '/^main "$@"/d' "$SUBSTRATE/install.sh" >"$pg8_cold"

MOCK_ROOT="$WORK/pg8-cold"
pg8_seed "$MOCK_ROOT" yes
pg8_step "$pg8_cold" "$MOCK_ROOT"
if [ "$pg8_ec" -ne 0 ]; then
  fail 'step 8 succeeds once the Cluster reports Ready' "$(cat "$MOCK_ROOT/run.log")"
elif ! grep -q -- 'wait --for=condition=Ready cluster.postgresql.cnpg.io/postgres -n data --timeout=600s' "$MOCK_ROOT/kubectl-argv"; then
  fail 'step 8 succeeds once the Cluster reports Ready' "the bounded Cluster wait never ran: $(cat "$MOCK_ROOT/run.log")"
elif grep -q 'cnpg.io/cluster' "$MOCK_ROOT/kubectl-argv"; then
  fail 'step 8 succeeds once the Cluster reports Ready' "the step still queries the pod selector the initdb Job satisfies"
else
  pass 'step 8 succeeds once the Cluster reports Ready, waiting on the Cluster and never listing pods'
fi

MOCK_ROOT="$WORK/pg8-stuck"
pg8_seed "$MOCK_ROOT" no
pg8_step "$pg8_cold" "$MOCK_ROOT"
case "$pg8_ec:$(cat "$MOCK_ROOT/run.log" 2>/dev/null)" in
  0:*)
    fail 'control: a stuck Cluster fails step 8, naming the Cluster and its phase' \
      "exit 0 — the wait forgave a cluster that never came up"
    ;;
  *did\ not\ become\ Ready*Setting\ up\ primary*)
    pass 'control: a stuck Cluster fails step 8, naming the Cluster and its phase'
    ;;
  *)
    fail 'control: a stuck Cluster fails step 8, naming the Cluster and its phase' \
      "exit $pg8_ec: $(cat "$MOCK_ROOT/run.log" 2>/dev/null)"
    ;;
esac

ROLLOUT_DIR="$WORK/rollout"
mkdir -p "$ROLLOUT_DIR"

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
      return 0
      ;;
    *"get deployment identity"*)
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
      local -a rollout_patch_keys=()
      local rollout_patch_key
      while IFS= read -r rollout_patch_key; do
        [ -n "$rollout_patch_key" ] && rollout_patch_keys+=("$rollout_patch_key")
      done < <(printf '%s' "$body" | jq -r '.stringData // {} | keys[]')
      for rollout_patch_key in ${rollout_patch_keys[@]+"${rollout_patch_keys[@]}"}; do
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
    printf 'KIT_SUBSTRATE_RECEIPT=%q\n' "$ROLLOUT_DIR/receipt.json"
    printf 'COURIER_MINT_TOKEN=%q\n' "$COURIER_MINT_TOKEN"
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
    if [ "${MINT_SEED_ORPHAN:-}" = "1" ]; then
      printf '%s\n' \
        'mock_seed identity identity-secrets COURIER_TOKEN "orphan-token-from-old-installer"' \
        'mock_seed identity identity-secrets EMAIL_CHANGE_LINK_TEMPLATE "https://old.example.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets NATS_URL "nats://nats.data.svc.cluster.local:4222"' \
        'mock_seed identity identity-secrets OIDC_ISSUER "https://issuer.example.com"' \
        'mock_seed identity identity-secrets OIDC_SIGNING_KEY "old-oidc-key"' \
        'mock_seed identity identity-secrets OIDC_SIGNING_KEY_ID "old-oidc-kid"'
    fi
    if [ "${MINT_SEED_COMPLETE:-}" = "1" ]; then
      printf '%s\n' \
        'mock_seed identity identity-secrets COURIER_BASE_URL "http://courier.courier.svc.cluster.local:4000"' \
        'mock_seed identity identity-secrets COURIER_TOKEN "live-box-working-token"' \
        'mock_seed identity identity-secrets PASSWORD_RESET_LINK_TEMPLATE "https://app.anywaye.com/reset-password?token={token}"' \
        'mock_seed identity identity-secrets EMAIL_VERIFICATION_LINK_TEMPLATE "https://app.anywaye.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets EMAIL_CHANGE_LINK_TEMPLATE "https://app.anywaye.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets RECOVERY_LINK_TEMPLATE "https://app.anywaye.com/verify-email/confirm?token={token}"' \
        'mock_seed identity identity-secrets INVITATION_LINK_TEMPLATE "https://app.anywaye.com/invitations/{token}"'
    fi
    if [ "${MINT_SEED_COMPLETE:-}" != "1" ]; then
      printf '%s\n' \
        'mock_seed identity identity-secrets RECOVERY_LINK_TEMPLATE "https://old.example.com/verify-email/confirm?token={token}"'
    fi
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

if grep -q 'IDENTITY_DEPLOY_TIMEOUT" deployment' "$mint_prefix" \
  || ! grep -q 'rollout status deployment/identity' "$mint_prefix"; then
  fail 'control fixture: the pre-fix mint step is the shape step 11 ran' \
    "the await-line deletion did not apply, so case 3 would prove nothing"
  failures=$((failures + 1))
else
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
    if [ "$(cat "$ROLLOUT_DIR/polls" 2>/dev/null || echo 0)" -ne 2 ]; then
      printf 'Argo synced on the first poll, so the missing-object case never happened\n'
      return 1
    fi
    printf 'the mint survived a late Deployment and patched both secrets with one value'
  }
  run 'step 11 mints when Argo creates the Deployment a few seconds late' \
    green mint_slow_ok

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

run 'the step-11 mock reads --patch-file=/dev/stdin and refuses - as kubectl does' green \
  check_patch_convention rollout_kubectl "$WORK/rollout-dash"

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

fixture_half_pair="$WORK/install-mint-half-pair.sh"
sed 's/"COURIER_BASE_URL":\$url,//' "$mint_fixed" >"$fixture_half_pair"
run 'control: a mint writing a token without its base URL goes red' red \
  check_mint_writes_pair "$fixture_half_pair"

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
# THE FIX. The four templates are derived from the ONE public origin
# (KIT_SUBSTRATE_APP_BASE_URL) and written in the SAME patch as the pair —
# and the legacy RECOVERY_LINK_TEMPLATE an older installer wrote is deleted
# in that same patch — or no identity courier key is written at all.
# `check_mint_mail_path` applies identity's own all-or-nothing rule to what
# landed in identity-secrets, so this is the matrix in executable form rather
# than a shape check.
#
# THE PATHS ARE PARLOR'S SERVED ROUTES, the launch stack's own spellings
# (`launch/docker-compose.launch.yml`): reset-password, verify-email/confirm
# (which is also the substitution for an address change — parlor serves no
# email-change screen, so the installer documents the shared screen rather
# than invent one — and the reason the legacy default must go: identity's
# warning compares VALUES, so a default equal to either purpose re-fires it),
# and invitations/{token}. A template without `{token}` is refused by
# identity (`resolveLinkTemplates`), so every recovery template carries it.
identity_expected_template() {
  case "$1" in
    PASSWORD_RESET_LINK_TEMPLATE)      printf '%s/reset-password?token={token}' "$APP_BASE_URL" ;;
    EMAIL_VERIFICATION_LINK_TEMPLATE)  printf '%s/verify-email/confirm?token={token}' "$APP_BASE_URL" ;;
    EMAIL_CHANGE_LINK_TEMPLATE)        printf '%s/verify-email/confirm?token={token}' "$APP_BASE_URL" ;;
    INVITATION_LINK_TEMPLATE)          printf '%s/invitations/{token}' "$APP_BASE_URL" ;;
    *) return 1 ;;
  esac
}

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
  for k in PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
    want="$(identity_expected_template "$k")"
    got="$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)"
    [ "$got" = "$want" ] || bad="${bad} ${k}=${got:-<missing>};"
  done
  if [ -n "$bad" ]; then
    printf 'a base URL and a token with no (valid) link template — identity would refuse (ErrInvalidCourier):%s\n' "$bad"
    return 1
  fi
  if [ -n "$(cat "$store/identity/identity-secrets/RECOVERY_LINK_TEMPLATE" 2>/dev/null || true)" ]; then
    printf 'RECOVERY_LINK_TEMPLATE survived the rewrite with value %s — identity would warn that %s\n' \
      "$(cat "$store/identity/identity-secrets/RECOVERY_LINK_TEMPLATE")" \
      "email_change and verify_email resolve to the shared default"
    return 1
  fi
  if [ "$(cat "$store/identity/identity-secrets/EMAIL_CHANGE_LINK_TEMPLATE")" != "$(cat "$store/identity/identity-secrets/EMAIL_VERIFICATION_LINK_TEMPLATE")" ]; then
    printf 'EMAIL_CHANGE_LINK_TEMPLATE is not the documented shared screen /verify-email/confirm — parlor serves no email-change screen of its own\n'
    return 1
  fi
  if [ "$(cat "$store/identity/identity-secrets/PASSWORD_RESET_LINK_TEMPLATE")" = "$(cat "$store/identity/identity-secrets/EMAIL_VERIFICATION_LINK_TEMPLATE")" ]; then
    printf 'the reset link and the verification link are one string — two purposes sharing one screen they do not both redeem\n'
    return 1
  fi
  if ! grep -q 'TRUE mail path' "$ROLLOUT_DIR/run.log"; then
    printf 'the mint did not report the configured mail path on its own channel\n%s\n' \
      "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  printf 'identity mail path: CONFIGURED — the pair and four templates written together with the legacy default deleted, each on parlor'"'"'s served route'
}

run 'step 11 writes identity'"'"'s courier pair AND its four link templates when KIT_SUBSTRATE_APP_BASE_URL is set, deleting the legacy default' green \
  check_mint_mail_path "$mint_fixed"

fixture_master_shape="$WORK/install-mint-master-shape.sh"
cp "$mint_fixed" "$fixture_master_shape"
"$PY" - "$fixture_master_shape" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
old = '''      --arg reset "$reset" --arg verify "$verify" --arg change "$change" \\
      --arg invite "$invite" \\'''
new = '''      --arg reset "$reset" --arg verify "$verify" --arg change "$change" \\
      --arg recovery "$verify" --arg invite "$invite" \\'''
assert old in src, "the --arg derivation site moved"
src = src.replace(old, new)
old2 = '''        "EMAIL_CHANGE_LINK_TEMPLATE":$change,
        "INVITATION_LINK_TEMPLATE":$invite'''
new2 = '''        "EMAIL_CHANGE_LINK_TEMPLATE":$change,
        "RECOVERY_LINK_TEMPLATE":$recovery,
        "INVITATION_LINK_TEMPLATE":$invite'''
assert old2 in src, "the patch body site moved"
src = src.replace(old2, new2)
old3 = '''      },"data":{
        "RECOVERY_LINK_TEMPLATE":null
      }}')'''
new3 = '''      }}')'''
assert old3 in src, "the legacy-deletion site moved"
src = src.replace(old3, new3)
open(path, "w", encoding="utf-8").write(src)
PY
if ! grep -q '"RECOVERY_LINK_TEMPLATE":\$recovery' "$fixture_master_shape" \
  || ! grep -q -- '--arg recovery "\$verify"' "$fixture_master_shape" \
  || grep -q '"RECOVERY_LINK_TEMPLATE":null' "$fixture_master_shape"; then
  fail 'control fixture: the master derivation writes three identical strings' \
    "the pre-fix shape did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  msp_out=""; msp_ec=0
  msp_out="$(check_mint_mail_path "$fixture_master_shape" 2>&1)" || msp_ec=$?
  if [ "$msp_ec" -eq 0 ]; then
    fail 'control: the master three-identical-strings derivation goes red, naming the shared default' \
      "exit 0 — the shipped shape passed the check"
  elif case "$msp_out" in *RECOVERY_LINK_TEMPLATE*) true ;; *) false ;; esac; then
    pass 'control: the master three-identical-strings derivation goes red, naming the shared default'
  else
    fail 'control: the master three-identical-strings derivation goes red, naming the shared default' "$msp_out"
  fi
fi

fixture_unserved_change="$WORK/install-mint-unserved-change.sh"
sed 's|change="\$verify"|change="${base}/email-change/confirm?token={token}"|' \
  "$mint_fixed" >"$fixture_unserved_change"
if ! grep -q 'email-change/confirm' "$fixture_unserved_change"; then
  fail 'control fixture: EMAIL_CHANGE points at an unserved path' \
    "the unserved-path substitution did not apply, so the control would prove nothing"
  failures=$((failures + 1))
else
  ucp_out=""; ucp_ec=0
  ucp_out="$(check_mint_mail_path "$fixture_unserved_change" 2>&1)" || ucp_ec=$?
  if [ "$ucp_ec" -eq 0 ]; then
    fail 'control: EMAIL_CHANGE at an unserved path goes red' \
      "exit 0 — the check blessed a link that answers 404"
  elif case "$ucp_out" in *EMAIL_CHANGE_LINK_TEMPLATE*) true ;; *) false ;; esac; then
    pass 'control: EMAIL_CHANGE at an unserved path goes red'
  else
    fail 'control: EMAIL_CHANGE at an unserved path goes red' "$ucp_out"
  fi
fi

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
  if ! grep -q 'rollout restart deployment/identity' "$ROLLOUT_DIR/argv"; then
    printf 'identity was not restarted after its secret changed\n'
    return 1
  fi
  printf 'orphaned COURIER_TOKEN and stray template removed, seven-key block verified empty, unrelated keys kept, courier pair written, identity restarted'
}
run 'step 11 converges an orphaned identity courier block when KIT_SUBSTRATE_APP_BASE_URL is unset' green \
  check_mint_converges_orphan "$mint_fixed"

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

check_mint_keeps_complete_pair() {
  local saved_base="${MINT_APP_BASE_URL:-}" saved_complete="${MINT_SEED_COMPLETE:-}"
  MINT_APP_BASE_URL=__UNSET__ MINT_SEED_COMPLETE=1 mint_step "$1" 2 5
  MINT_APP_BASE_URL="$saved_base" MINT_SEED_COMPLETE="$saved_complete"
  if [ "$mint_ec" -ne 0 ]; then
    printf 'the mint exited %s on a box with a working mail path and no base URL\n%s\n' "$mint_ec" "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  local store="$ROLLOUT_DIR/store" k
  for k in COURIER_BASE_URL COURIER_TOKEN PASSWORD_RESET_LINK_TEMPLATE EMAIL_VERIFICATION_LINK_TEMPLATE EMAIL_CHANGE_LINK_TEMPLATE INVITATION_LINK_TEMPLATE; do
    if [ -z "$(cat "$store/identity/identity-secrets/$k" 2>/dev/null || true)" ]; then
      printf 'the sweep deleted %s from a working mail path — the box went from sending mail to 503s\n' "$k"
      return 1
    fi
  done
  if [ "$(cat "$store/identity/identity-secrets/RECOVERY_LINK_TEMPLATE" 2>/dev/null || true)" != "https://app.anywaye.com/verify-email/confirm?token={token}" ]; then
    printf 'the sweep touched the legacy default on a kept mail path — keep means keep: %s\n' \
      "$(cat "$store/identity/identity-secrets/RECOVERY_LINK_TEMPLATE" 2>/dev/null || echo '<missing>')"
    return 1
  fi
  if [ "$(cat "$store/identity/identity-secrets/COURIER_TOKEN" 2>/dev/null || true)" != "live-box-working-token" ]; then
    printf 'the working token was rewritten by a run with no base URL to rewrite it with\n'
    return 1
  fi
  if [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_TOKEN" 2>/dev/null || true)" != "$COURIER_MINT_TOKEN" ] \
    || [ "$(cat "$store/courier/courier-secrets/COURIER_IDENTITY_URL" 2>/dev/null || true)" != "$IDENTITY_BASE_URL_EXPECTED" ]; then
    printf 'courier-secrets lost its required pair while identity kept its mail path\n'
    return 1
  fi
  if ! grep -q 'rollout restart deployment/courier' "$ROLLOUT_DIR/argv"; then
    printf 'courier was not restarted after its secret changed\n'
    return 1
  fi
  if ! grep -q 'working mail path' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'KIT_SUBSTRATE_APP_BASE_URL' "$ROLLOUT_DIR/run.log" \
    || ! grep -q 'nothing removed' "$ROLLOUT_DIR/run.log"; then
    printf 'the run kept the mail path without saying so and naming the variable\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  if grep -q 'leftovers' "$ROLLOUT_DIR/run.log" \
    || grep -q 'orphaned courier key' "$ROLLOUT_DIR/run.log"; then
    printf 'a kept mail path was described with the orphan sentence\n%s\n' "$(cat "$ROLLOUT_DIR/run.log")"
    return 1
  fi
  if grep -q 'rollout restart deployment/identity' "$ROLLOUT_DIR/argv"; then
    printf 'identity was restarted although its secret was left untouched\n'
    return 1
  fi
  printf 'complete pair with templates left in place, working mail path reported with the rewriting variable named, no orphan sentence, identity not restarted, courier pair written'
}
run 'step 11 keeps a complete identity courier block when KIT_SUBSTRATE_APP_BASE_URL is unset' green \
  check_mint_keeps_complete_pair "$mint_fixed"

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

ARGOCD_DIR="$WORK/argocd"
mkdir -p "$ARGOCD_DIR"

argocd_kubectl() {
  printf '%s\n' "$*" >>"$ARGOCD_DIR/argv"
  case "$*" in
    *"wait"*"deployment -n argocd --all"*)
      return 0
      ;;
    *"wait"*"deployment -n argocd "*)
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

apps_step() {
  rm -f "$ARGOCD_DIR/argv" "$ARGOCD_DIR/run.log"
  local script="$ARGOCD_DIR/apps-run.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'ARGOCD_DIR=%q\n' "$ARGOCD_DIR"
    printf 'FIXTURE=%q\n' "$1"
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

apps_prefix="$WORK/install-apps-prefix.sh"
apps_wait_line='  kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Available deployment -n argocd argocd-server --timeout=120s'
awk -v wait_line="$apps_wait_line" '
  /^main "\$@"/ { next }
  /wait --for=condition=Available deployment -n argocd / && !/--all/ { next }
  /^  kubectl --kubeconfig="\$KUBECONFIG" apply "\$\{apply_args\[@\]\}"$/ {
    print
    print wait_line
    next
  }
  { print }
' "$SUBSTRATE/install.sh" >"$apps_prefix"

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

case "$(sed -n '/^install_argocd()/,/^}/p' "$SUBSTRATE/install.sh")" in
  *'wait --for=condition=Available deployment -n argocd --all'*)
    pass 'step 4 waits for every argocd Deployment, the coverage step 6 deleted'
    ;;
  *)
    fail 'step 4 waits for every argocd Deployment, the coverage step 6 deleted' \
      'the --all deployments wait is gone from install_argocd — step 6 has no wait to cover the gap'
    ;;
esac

case "$(sed -n '/^    argocd)/,/^      ;;/p' "$SUBSTRATE/install.sh")" in
  *'get deployment -n argocd argocd-repo-server'*)
    pass 'the argocd guard probes a Deployment core-install ships'
    ;;
  *)
    fail 'the argocd guard probes a Deployment core-install ships' \
      'the guard probe is not argocd-repo-server — a probe of a component core-install does not ship never matches'
    ;;
esac

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

apple_double_tree="$WORK/apply-tree-sidecar"
stray_tree="$WORK/apply-tree-stray"

plant_apple_double() {
  printf '\000\005\026\007\000\002\000\000Mac OS X\000\000\000\002\000\000' >"$1"
  printf '\000\000\000\000\000\000\000\000' >>"$1"
}

apply_step() {
  local installer="$1" tree="$2" mock="$3" log="$4" ec=0
  rm -rf "$mock"
  mkdir -p "$mock"
  printf 'argocd\n' >"$mock/namespaces"
  (
    . "$installer"
    kubectl() { mock_kubectl "$@" || exit $?; }
    export RECEIPT_PATH="$mock/receipt.json"
    export MOCK_ROOT="$mock"
    MANIFEST_DIR="$tree"
    install_applications
  ) >"$log" 2>&1 || ec=$?
  return "$ec"
}

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

nofilter_installer="$WORK/install-nofilter.sh"
sed 's|for f in "$dir"/\*\.yaml; do|for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do|' \
  "$fixture_sourced" >"$nofilter_installer"

run 'the step applies a tree with AppleDouble sidecars (sidecar ignored and named)' green apple_double_ok
run 'control: a stray non-sidecar YAML is refused by name (the apply goes red)' green stray_refused
run 'control: removing the glob filter lets AppleDouble break the apply again' green nofilter_breaks "$nofilter_installer"

APP_PROJECT="$SUBSTRATE/manifests/argocd/appproject.yaml"

check_appproject() {
  "$PY" - "$1" "$2" <<'PY'
import os
import sys

import yaml

apps_dir, proj_path = sys.argv[1:3]
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

projects = {p for _, p in apps}
if len(projects) != 1:
    print(f"Applications name {len(projects)} distinct projects: {sorted(projects)} — one fact, one spelling")
    sys.exit(1)
apps_project = projects.pop()

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
    print("clusterResourceWhitelist contains group '*' kind '*' — the project stays bounded: whitelist exactly the kinds the Applications declare, never */*")
    sys.exit(1)

print(f"{len(apps)} Applications name project {apps_project!r}, shipped AppProject is {shipped!r}, least-privilege")
PY
}

run 'the Applications name the shipped AppProject (one fact, one spelling, least-privilege)' green \
  check_appproject "$MANIFESTS" "$APP_PROJECT"

fixture_project_drift="$WORK/appproject-drift"
mkdir -p "$fixture_project_drift"
cp "$MANIFESTS"/*.yaml "$fixture_project_drift/"
sed -i '' 's/project: default/project: other/' "$fixture_project_drift/identity.yaml" 2>/dev/null || \
  sed -i 's/project: default/project: other/' "$fixture_project_drift/identity.yaml"
run 'control: an Application naming a different project goes red' red \
  check_appproject "$fixture_project_drift" "$APP_PROJECT"

fixture_project_renamed="$WORK/appproject-renamed.yaml"
sed 's/name: default/name: anywaye/' "$APP_PROJECT" >"$fixture_project_renamed"
run 'control: a shipped AppProject with a different name goes red' red \
  check_appproject "$MANIFESTS" "$fixture_project_renamed"

check_appproject_permits() {
  "$PY" - "$1" "$2" <<'PY'
import os
import re
import sys

import yaml


def normalize(repo):
    repo = repo.strip().lower()
    if repo.endswith(".git"):
        repo = repo[:-4]
    return repo


def glob_to_regex(pattern):
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
    if pattern == "*":
        return True
    return bool(glob_to_regex(pattern).match(value))


def permitted(repo_url, patterns):
    src = normalize(repo_url)
    any_matched = False
    for raw in patterns:
        raw = raw.strip()
        if raw.startswith("!"):
            norm = "!" + normalize(raw[1:])
            matched = not glob_match(norm[1:], src)
            if not matched:
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

run 'every Application source.repoURL is permitted by the AppProject sourceRepos' green \
  check_appproject_permits "$MANIFESTS" "$APP_PROJECT"

fixture_project_bare_root="$WORK/appproject-bare-root.yaml"
sed 's|^    - oci://ghcr.io/anywaye/charts/\*$|    - oci://ghcr.io/anywaye/charts|' \
  "$APP_PROJECT" >"$fixture_project_bare_root"
if grep -qE '^ +- oci://ghcr\.io/anywaye/charts/\*' "$fixture_project_bare_root"; then
  fail 'control fixture: the bare-root AppProject was not built' \
    "the sed did not strip the chart glob from sourceRepos, so the control would prove nothing"
else
  run 'control: the pre-fix bare-root AppProject refuses the per-chart Applications' red \
    check_appproject_permits "$MANIFESTS" "$fixture_project_bare_root"
fi

fixture_foreign_repo="$WORK/apps-foreign-repo"
mkdir -p "$fixture_foreign_repo"
cp "$MANIFESTS"/*.yaml "$fixture_foreign_repo/"
sed -i '' 's|repoURL: oci://ghcr.io/anywaye/charts/courier|repoURL: oci://ghcr.io/evil/charts/courier|' \
  "$fixture_foreign_repo/courier.yaml" 2>/dev/null || \
  sed -i 's|repoURL: oci://ghcr.io/anywaye/charts/courier|repoURL: oci://ghcr.io/evil/charts/courier|' \
  "$fixture_foreign_repo/courier.yaml"
if grep -q 'oci://ghcr.io/evil/charts/courier' "$fixture_foreign_repo/courier.yaml"; then
  run 'control: an Application naming a repo the project does not permit goes red' red \
    check_appproject_permits "$fixture_foreign_repo" "$APP_PROJECT"
else
  fail 'control fixture: the foreign-repo Application was not built' \
    "the sed did not rewrite courier's repoURL, so the control would prove nothing"
fi

fixture_nested_repo="$WORK/apps-nested-repo"
mkdir -p "$fixture_nested_repo"
cp "$MANIFESTS"/*.yaml "$fixture_nested_repo/"
sed -i '' 's|repoURL: oci://ghcr.io/anywaye/charts/identity|repoURL: oci://ghcr.io/anywaye/charts/nested/identity|' \
  "$fixture_nested_repo/identity.yaml" 2>/dev/null || \
  sed -i 's|repoURL: oci://ghcr.io/anywaye/charts/identity|repoURL: oci://ghcr.io/anywaye/charts/nested/identity|' \
  "$fixture_nested_repo/identity.yaml"
if grep -q 'charts/nested/identity' "$fixture_nested_repo/identity.yaml"; then
  run 'control: a nested OCI path is refused (the `*` cannot cross a `/`)' red \
    check_appproject_permits "$fixture_nested_repo" "$APP_PROJECT"
else
  fail 'control fixture: the nested-repo Application was not built' \
    "the sed did not nest the identity repoURL, so the control would prove nothing"
fi

fixture_fifth_chart="$WORK/apps-fifth-chart"
mkdir -p "$fixture_fifth_chart"
cp "$MANIFESTS"/*.yaml "$fixture_fifth_chart/"
cat >"$fixture_fifth_chart/ledger.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ledger
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://ghcr.io/anywaye/charts/ledger
    chart: ledger
    targetRevision: 0.1.0
  destination:
    server: https://kubernetes.default.svc
    namespace: ledger
YAML
run 'the project permits a FIFTH chart with no edit (the glob, not four names)' green \
  check_appproject_permits "$fixture_fifth_chart" "$APP_PROJECT"

CORE_ALLOWED="argocd-application-controller argocd-applicationset-controller argocd-redis argocd-repo-server"
substrate_refs_raw="$(grep -h "argocd" "$SUBSTRATE/install.sh" "$APP_PROJECT" "$SUBSTRATE/manifests"/*.yaml "$SUBSTRATE/manifests"/*/*.yaml 2>/dev/null | grep -oE "argocd-[a-z0-9-]+" | sort -u || true)"
missing_refs=""
unknown_refs=""
for ref in $substrate_refs_raw; do
  case " $CORE_ALLOWED " in
    *" $ref "*) ;;
    *)
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

check_service_telemetry() {
  "$PY" - "$1" "$2" <<'PY'
import os
import re
import sys

import yaml

install_path, apps_dir = sys.argv[1], sys.argv[2]

SWITCH_KEY = "OTEL_SDK_DISABLED"
SWITCH_VALUE = "true"

src = open(install_path, encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)

problems = []

defs = re.findall(r"SERVICE_OTEL_DISABLED=\(--from-literal=([A-Z_]+)=([^)]+)\)", code)
if len(defs) != 1:
    problems.append(f"expected exactly one SERVICE_OTEL_DISABLED definition, found {len(defs)}")
elif tuple(defs[0]) != (SWITCH_KEY, SWITCH_VALUE):
    problems.append(f"the off-switch is {defs[0]!r}, want {(SWITCH_KEY, SWITCH_VALUE)!r}")

for secret in ("identity-secrets", "courier-secrets", "parlor-secrets", "billing-secrets"):
    m = re.search(r"create secret generic " + re.escape(secret) + r"\b", code)
    if not m:
        problems.append(f"{secret} is never created")
        continue
    window = code[m.start():m.start() + 1400]
    if "SERVICE_OTEL_DISABLED" not in window:
        problems.append(f"{secret} is created without the telemetry off-switch")
    elif f"--from-literal={SWITCH_KEY}=" in window:
        problems.append(f"{secret} retypes the switch instead of referencing the constant")

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

services = set(re.findall(r"create secret generic (\S+-secrets)", code))
for svc in ("identity", "gateway", "courier", "parlor", "billing"):
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

fixture_no_switch="$WORK/install-no-switch.sh"
sed 's/^SERVICE_OTEL_DISABLED=(--from-literal=OTEL_SDK_DISABLED=true)$/SERVICE_OTEL_DISABLED=()/' \
  "$SUBSTRATE/install.sh" >"$fixture_no_switch"
run 'control: the off-switch dropped from the constant goes red' red \
  check_service_telemetry "$fixture_no_switch" "$MANIFESTS"

fixture_drifted_switch="$WORK/install-drifted-switch.sh"
sed 's/--from-literal=OTEL_SDK_DISABLED=true/--from-literal=OTEL_TELEMETRY_OFF=true/' \
  "$SUBSTRATE/install.sh" >"$fixture_drifted_switch"
run 'control: a drifted switch name in the constant goes red' red \
  check_service_telemetry "$fixture_drifted_switch" "$MANIFESTS"

fixture_identity_no_switch="$WORK/install-identity-no-switch.sh"
sed 's/"\${identity_args\[@\]}" "\${SERVICE_OTEL_DISABLED\[@\]}"/"\${identity_args[@]}"/' \
  "$SUBSTRATE/install.sh" >"$fixture_identity_no_switch"
run 'control: a service secret without the switch goes red' red \
  check_service_telemetry "$fixture_identity_no_switch" "$MANIFESTS"

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

check_cross_namespace_addresses() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import os
import re
import sys

import yaml

apps_dir, data_dir, install_path = sys.argv[1:4]

problems = []

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



def host_of(hostport):
    return hostport.split("@")[-1].split(":")[0]


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

fixture_apps() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$MANIFESTS/." "$dir/"
}

fixture_bare="$WORK/apps-bare"
fixture_apps "$fixture_bare"
sed -i.bak 's|http://identity.identity.svc.cluster.local:8080|http://identity:8080|g' \
  "$fixture_bare/gateway.yaml"
rm -f "$fixture_bare/gateway.yaml.bak"
run 'control: a bare cross-service name goes red' red \
  check_cross_namespace_addresses "$fixture_bare" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

fixture_wrongns="$WORK/apps-wrongns"
fixture_apps "$fixture_wrongns"
sed -i.bak 's|identity.identity.svc.cluster.local|identity.gateway.svc.cluster.local|g' \
  "$fixture_wrongns/gateway.yaml"
rm -f "$fixture_wrongns/gateway.yaml.bak"
run 'control: a name in the wrong namespace goes red' red \
  check_cross_namespace_addresses "$fixture_wrongns" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

fixture_unshipped="$WORK/apps-unshipped"
fixture_apps "$fixture_unshipped"
sed -i.bak 's|http://identity.identity.svc.cluster.local:8080|http://pantry.pantry.svc.cluster.local:8080|' \
  "$fixture_unshipped/gateway.yaml"
rm -f "$fixture_unshipped/gateway.yaml.bak"
run 'control: an address to a Service no manifest ships goes red' red \
  check_cross_namespace_addresses "$fixture_unshipped" "$SUBSTRATE/manifests/data" "$SUBSTRATE/install.sh"

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

fixture_install_ns="$WORK/install-wrong-ns.sh"
sed 's|redis\.data\.svc\.cluster\.local|redis.gateway.svc.cluster.local|g' \
  "$SUBSTRATE/install.sh" >"$fixture_install_ns"
run 'control: a drifted in-cluster name in the installer goes red' red \
  check_cross_namespace_addresses "$MANIFESTS" "$SUBSTRATE/manifests/data" "$fixture_install_ns"

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

if grep -q '"event":"install.done".*"steps":\[' "$timing_jsonl"; then
  pass 'the final event carries the per-step table'
else
  fail 'the final event carries the per-step table' "$(tail -1 "$timing_jsonl")"
fi

fixture_no_timing="$WORK/timing-no-seconds.jsonl"
{
  printf '%s\n' '{"event":"step.start","step":1,"phase":"k3s","message":"k3s","seconds":0.100}'
  printf '%s\n' '{"event":"step.done","step":1,"phase":"k3s","message":"k3s: done"}'
  printf '%s\n' '{"event":"install.done","step":1,"phase":"k3s","message":"up","seconds":1.000,"steps":[{"step":1,"phase":"k3s","seconds":0.100}]}'
} >"$fixture_no_timing"
run 'control: a step that reports no timing goes red' red check_timing "$fixture_no_timing"

fixture_short_total="$WORK/timing-short-total.jsonl"
{
  printf '%s\n' '{"event":"step.start","step":1,"phase":"k3s","message":"k3s","seconds":0.100}'
  printf '%s\n' '{"event":"step.done","step":1,"phase":"k3s","message":"k3s: 5.000s","seconds":5.000}'
  printf '%s\n' '{"event":"install.done","step":1,"phase":"k3s","message":"up","seconds":0.500,"steps":[{"step":1,"phase":"k3s","seconds":5.000}]}'
} >"$fixture_short_total"
run 'control: a total smaller than the steps it names goes red' red check_timing "$fixture_short_total"

fixture_zero_steps="$WORK/timing-zero.jsonl"
{
  printf '%s\n' '{"event":"step.start","step":1,"phase":"k3s","message":"k3s","seconds":0.000}'
  printf '%s\n' '{"event":"step.done","step":1,"phase":"k3s","message":"k3s: 0.000s","seconds":0.000}'
  printf '%s\n' '{"event":"install.done","step":1,"phase":"k3s","message":"up","seconds":0.000,"steps":[{"step":1,"phase":"k3s","seconds":0.000}]}'
} >"$fixture_zero_steps"
run 'control: a run of constant-zero durations goes red' red check_timing "$fixture_zero_steps"

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

check_operator_overlap() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
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

if "cert-manager.yaml" not in cm:
    problems.append("step 2 no longer applies the cert-manager manifest")
if "cnpg-" not in cnpg:
    problems.append("step 3 no longer applies the CNPG manifest")
if "core-install.yaml" not in argo:
    problems.append("step 4 no longer applies the Argo CD core-install manifest")

for name, b in (("install_cert_manager", cm), ("install_cnpg", cnpg)):
    if "wait --for=condition" in b:
        problems.append(f"{name} still waits — the three operator waits belong in step 4, grouped")

for want, label in (
    ("wait --for=condition=Available deployment -n cert-manager --all", "cert-manager"),
    ("wait --for=condition=Available deployment -n cnpg-system cnpg-controller-manager", "CNPG"),
    ("wait --for=condition=Available deployment -n argocd --all", "Argo CD"),
):
    if want not in argo:
        problems.append(f"step 4 does not wait for {label}")

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

WARM_DIR="$WORK/appproject-warm"
mkdir -p "$WARM_DIR"

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
shutil.copyfile(src, dst)
PY

DEPLOYED_PROJECT="$WARM_DIR/deployed-appproject.yaml"

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
    - oci://ghcr.io/anywaye/charts
YAML
  rm -f "$WARM_DIR/argv"
}

mock_get_appproject() {
  "$PY" - "$DEPLOYED_PROJECT" <<'PY'
import sys

import yaml


doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for repo in (doc.get("spec") or {}).get("sourceRepos") or []:
    print(repo)
PY
}

warm_kubectl() {
  printf '%s\n' "$*" >>"$WARM_DIR/argv"
  case "$*" in
    *"get deployment -n argocd argocd-repo-server"*) return 0 ;;
  esac
    case "$1" in
      --kubeconfig=*) shift ;;
      *) break ;;
    esac
  done
  local verb="${1:-}" f_target=""
  shift || true
    case "$1" in
      -f) f_target="$2"; shift 2 ;;
      -f=*) f_target="${1#-f=}"; shift ;;
      *) shift ;;
    esac
  done
  case "$verb" in
    apply)
      [ -n "$f_target" ] || { printf 'warm_kubectl: apply with no -f\n' >&2; return 1; }
      "$PY" "$WARM_PLANTER" "$f_target" "$DEPLOYED_PROJECT"
      ;;
    wait) return 0 ;;
    create) return 0 ;;
    *)
      printf 'warm_kubectl: unhandled %s\n' "$*" >&2
      return 1
      ;;
  esac
  return 0
}

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

warm_seed
old_repos="$(mock_get_appproject | tr '\n' ' ')"
old_repos="${old_repos% }"
warm_is_prefix_list=0
while IFS= read -r warm_repo; do
  [ -n "$warm_repo" ] || continue
  if [ "$warm_repo" = "oci://ghcr.io/anywaye/charts" ]; then
    warm_is_prefix_list=1
  fi
  case "$warm_repo" in
    "oci://ghcr.io/anywaye/charts/*") warm_has_glob=1 ;;
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

warm_ec=0
warm_run "$warm_fixture" || warm_ec=$?
if [ "$warm_ec" -ne 0 ]; then
  fail 'a warm box re-applies the AppProject' "$(cat "$WARM_DIR/run.log")"
else
  pass 'a warm box re-applies the AppProject (step 4 exits 0)'
fi

if grep -q 'apply -f .*appproject\.yaml' "$WARM_DIR/argv"; then
  pass 'a warm box re-applies the AppProject (the apply is in argv)'
else
  fail 'a warm box re-applies the AppProject (the apply is in argv)' \
    "step 4 ran: $(tr '\n' ' | ' <"$WARM_DIR/argv")"
fi

case "$(cat "$WARM_DIR/argv")" in
  *core-install.yaml*)
    fail 'a warm box re-applies ONLY the AppProject — the operator stays guarded' \
      'step 4 re-applied the remote core-install manifest on a box that already has Argo CD'
    ;;
  *)
    pass 'a warm box re-applies ONLY the AppProject — the operator stays guarded'
    ;;
esac

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
# ACME could never complete (`... lookup api.anywaye.com ...: no such host` —
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

honest_dry_run() {
  local script="$1" out ec=0
  out="$(KIT_SUBSTRATE_DATABASES="$DBS" KIT_SUBSTRATE_RECEIPT="$WORK/honest-receipt.json" \
    DRY_RUN=1 bash "$script" 2>&1)" || ec=$?
  printf '%s' "$out"
  return "$ec"
}

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
  printf '# the fleet default is https://auth.anywaye.com but this box does not set it\n' >>"$adir/svc.yaml"
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
    *'auth.anywaye.com'*) printf 'a URL from a comment is listed as intended\n'; return 1 ;;
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


check_ingress_hosts_listed() {
  local script="$1" adir="$WORK/ingress-apps"
  mkdir -p "$adir"
  cat >"$adir/gw.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gw
spec:
  source:
    repoURL: oci://ghcr.io/anywaye/charts/gateway
    chart: gateway
    helm:
      values: |
        ingress:
          host: values-host.example.com
        env:
          PUBLIC_URL: "https://url-host.example.com"
  destination:
    server: https://kubernetes.default.svc
    namespace: gateway
YAML
  cat >"$adir/ingress.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gw
spec:
  rules:
    - host: ingress-host.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gw
                port:
                  number: 80
YAML
  local src="$WORK/ingress-sourced.sh"
  sed '/^main "\$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'the sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(KIT_SUBSTRATE_APP_BASE_URL='https://operator-app.example.com' \
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='https://operator-auth.example.com' \
    bash -c '. "$0"; kit_substrate_intended_hosts "$1"' "$src" "$adir" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'the extractor failed\n%s' "$out"; return 1; }
  case "$out" in
    *'values-host.example.com'*) ;;
    *) printf 'a host in the chart values is not listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'ingress-host.example.com'*) ;;
    *) printf 'an Ingress spec.rules host is not listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'url-host.example.com'*) ;;
    *) printf 'the https URL source was displaced\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'operator-app.example.com'*) ;;
    *) printf 'the APP_BASE_URL host is not listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'operator-auth.example.com'*) ;;
    *) printf 'the OIDC issuer host is not listed\n%s' "$out"; return 1 ;;
  esac
  local shipped shippedout h
  shipped="$(grep -hE '^[[:space:]]*(-[[:space:]]+)?host:[[:space:]]+' "$MANIFESTS"/*.yaml 2>/dev/null \
    | sed -E -e 's/^[[:space:]]*(-[[:space:]]+)?host:[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'\$/\1/" \
    | awk 'NF' || true)"
  if [ -n "$shipped" ]; then
    shippedout="$(KIT_SUBSTRATE_APP_BASE_URL='' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
      bash -c '. "$0"; kit_substrate_intended_hosts "$1"' "$src" "$MANIFESTS" 2>&1)" || shippedout=""
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      case "$shippedout" in
        *"$h"*) ;;
        *) printf 'the shipped manifests declare %s and the derivation does not list it\n' "$h"; return 1 ;;
      esac
    done <<EOF
$shipped
EOF
  fi
  printf 'intended hosts include the chart-values host, the Ingress host and the URL sources\n'
}

check_ingress_host_dedup() {
  local script="$1" adir="$WORK/dual-apps"
  mkdir -p "$adir"
  cat >"$adir/dual.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dual
spec:
  source:
    repoURL: oci://ghcr.io/anywaye/charts/dual
    chart: dual
    helm:
      values: |
        ingress:
          host: dual.example.com
        env:
          PUBLIC_URL: "https://dual.example.com"
  destination:
    server: https://kubernetes.default.svc
    namespace: dual
YAML
  local src="$WORK/dual-sourced.sh"
  sed '/^main "\$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'the sourced copy does not parse\n'; return 1; }
  local out t sn ec=0
  out="$(KIT_SUBSTRATE_APP_BASE_URL='https://dual.example.com' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
    bash -c '. "$0"; kit_substrate_intended_hosts "$1"' "$src" "$adir" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'the extractor failed\n%s' "$out"; return 1; }
  local n
  n="$(printf '%s' "$out" | grep -c '^dual\.example\.com$')"
  [ "$n" -eq 1 ] || { printf 'dual.example.com is reported %s time(s), not once\n%s' "$n" "$out"; return 1; }
  t="$(KIT_SUBSTRATE_APP_BASE_URL='https://dual.example.com' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
    bash -c '. "$0"; kit_substrate_intended_host_table "$1"' "$src" "$adir" 2>&1)" || t=""
  sn="$(printf '%s' "$t" | awk -F '\t' -v h='dual.example.com' '$1 == h { n++ } END { print n + 0 }')"
  [ "$sn" -eq 1 ] || { printf 'the table carries %s row(s) for dual.example.com\n%s' "$sn" "$t"; return 1; }
  printf 'a host named by an Ingress and a URL is reported once\n'
}

check_ingress_host_exclusions() {
  local script="$1" adir="$WORK/exclude-apps"
  mkdir -p "$adir"
  cat >"$adir/svc.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svc
spec:
  source:
    repoURL: oci://ghcr.io/anywaye/charts/svc
    chart: svc
    helm:
      values: |
        ingress:
          host: localhost
        internal:
          host: identity.identity.svc.cluster.local
          port: 8080
        loopback:
          host: 127.0.0.1
        bare:
          host: redis-master
        public:
          host: real.example.com
  destination:
    server: https://kubernetes.default.svc
    namespace: svc
YAML
  local src="$WORK/exclude-sourced.sh"
  sed '/^main "\$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'the sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(KIT_SUBSTRATE_APP_BASE_URL='' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
    bash -c '. "$0"; kit_substrate_intended_hosts "$1"' "$src" "$adir" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'the extractor failed\n%s' "$out"; return 1; }
  case "$out" in
    *'real.example.com'*) ;;
    *) printf 'the checkable host is not listed — every assertion below is vacuous\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *localhost*) printf 'localhost is listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *svc.cluster.local*) printf 'an in-cluster name is listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *127.0.0.1*) printf '127.0.0.1 is listed\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *redis-master*) printf 'a single-label name is listed\n%s' "$out"; return 1 ;;
  esac
  printf 'localhost, in-cluster, loopback and single-label host values stay out\n'
}

check_no_manifestless_host() {
  local script="$1" adir="$WORK/ghost-apps"
  mkdir -p "$adir"
  cat >"$adir/ghost.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ghost
spec:
  source:
    repoURL: oci://ghcr.io/anywaye/charts/ghost
    chart: ghost
    helm:
      values: |
        ingress:
          host: live.example.com
  destination:
    server: https://kubernetes.default.svc
    namespace: ghost
YAML
  grep -q '# host: ghost.example.com' "$adir/ghost.yaml" \
    || { printf 'the fixture lost its commented host — the red below would prove nothing\n'; return 1; }
  local src="$WORK/ghost-sourced.sh"
  sed '/^main "\$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'the sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(KIT_SUBSTRATE_APP_BASE_URL='' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
    bash -c '. "$0"; kit_substrate_intended_hosts "$1"' "$src" "$adir" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'the extractor failed\n%s' "$out"; return 1; }
  case "$out" in
    *ghost.example.com*) printf 'a host named only in a comment is resolved — a condition that does not exist\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *live.example.com*) ;;
    *) printf 'the fixture live host is not listed — silence satisfies nothing\n%s' "$out"; return 1 ;;
  esac
  printf 'a host no manifest serves is not added; the live one is\n'
}

check_readiness_count() {
  local script="$1" src="$WORK/count-sourced.sh"
  sed '/^main "\$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'the sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(bash -c '. "$0"
    KIT_SUBSTRATE_APP_BASE_URL="https://one.example.invalid"
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://localhost:8443"
    kit_substrate_compute_readiness
    printf "round1 pending=[%s] count=[%s]\n" "$(printf "%s" "$READINESS_TLS_PENDING" | grep -c .)" "$(kit_substrate_readiness_pending_count)"
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    kit_substrate_compute_readiness
    printf "round2 pending=[%s] count=[%s]\n" "$(printf "%s" "$READINESS_TLS_PENDING" | grep -c .)" "$(kit_substrate_readiness_pending_count)"
    READINESS_TLS_PENDING="a.example.invalid
b.example.invalid"
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    printf "round3 pending=[%s] count=[%s]\n" "$(printf "%s" "$READINESS_TLS_PENDING" | grep -c .)" "$(kit_substrate_readiness_pending_count)"
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER="https://localhost:8443"
    printf "round4 pending=[%s] count=[%s]\n" "$(printf "%s" "$READINESS_TLS_PENDING" | grep -c .)" "$(kit_substrate_readiness_pending_count)"
  ' "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'the count unit failed\n%s' "$out"; return 1; }
  case "$out" in
    *'round1 pending=[1] count=[1]'*) ;;
    *) printf 'one pending host is not count 1\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'round2 pending=[1] count=[2]'*) ;;
    *) printf 'the unset issuer does not add its one condition\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'round3 pending=[2] count=[3]'*) ;;
    *) printf 'two pending hosts plus the OIDC half is not count 3\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'round4 pending=[2] count=[2]'*) ;;
    *) printf 'the count does not follow the list\n%s' "$out"; return 1 ;;
  esac
  printf 'the readiness count equals the pending list, plus the OIDC half\n'
}

run 'an Ingress host is intended — the chart-values host, spec.rules, and the URL sources beside them' green \
  check_ingress_hosts_listed "$SUBSTRATE/install.sh"
run 'a host named by an Ingress and a URL is reported once' green \
  check_ingress_host_dedup "$SUBSTRATE/install.sh"
run 'localhost, in-cluster, 127.0.0.1 and single-label host values stay out' green \
  check_ingress_host_exclusions "$SUBSTRATE/install.sh"
run 'a host named only in a comment is not added' green \
  check_no_manifestless_host "$SUBSTRATE/install.sh"
run 'the readiness count equals the pending list, plus the OIDC half' green \
  check_readiness_count "$SUBSTRATE/install.sh"

fixture_master_hosts_dir="$WORK/master-shape-hosts"
fixture_master_hosts="$fixture_master_hosts_dir/install-master-hosts.sh"
mkdir -p "$fixture_master_hosts_dir"
cp -R "$SUBSTRATE/manifests" "$fixture_master_hosts_dir/manifests"
sed -e '/# --- ingress-host-parse BEGIN/,/# --- ingress-host-parse END/d' \
    -e '/# --- ingress-host-source BEGIN/,/# --- ingress-host-source END/d' \
    "$SUBSTRATE/install.sh" >"$fixture_master_hosts"
if ! bash -n "$fixture_master_hosts"; then
  fail 'control fixture: the master shape does not parse' \
    'the sed broke the file — a red below would be a syntax error wearing the finding clothes'
elif ! honest_dry_run "$fixture_master_hosts" >/dev/null 2>&1; then
  fail 'control fixture: DRY_RUN over the master shape fails' \
    'the sed broke the run — a red below would be a broken fixture, not a URL-only derivation'
else
  mkdir -p "$WORK/master-hosts-apps"
  cat >"$WORK/master-hosts-apps/ingress.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  rules:
    - host: premise-host.example.com
YAML
  sed '/^main "\$@"/d' "$fixture_master_hosts" >"$WORK/master-hosts-sourced.sh"
  master_hosts_out="$(KIT_SUBSTRATE_APP_BASE_URL='https://premise-url.example.com' KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' \
    bash -c '. "$0"; kit_substrate_intended_hosts "$1"' \
      "$WORK/master-hosts-sourced.sh" "$WORK/master-hosts-apps" 2>&1)" || master_hosts_out=""
  case "$master_hosts_out" in
    *'premise-url.example.com'*) ;;
    *) fail 'control fixture: the master shape lost the URL source' \
         'the URL-only derivation must still list the operator URL — the reds below would prove nothing'
       ;;
  esac
  case "$master_hosts_out" in
    *'premise-host.example.com'*)
      fail 'control fixture: the master shape still reads Ingress hosts' \
        'the sed did not remove the derivation — the reds below would prove nothing'
      ;;
    *) ;;
  esac
  run 'control: the URL-only derivation fails the Ingress-host check' red \
    check_ingress_hosts_listed "$fixture_master_hosts"
  run 'control: the URL-only derivation fails the exclusions check' red \
    check_ingress_host_exclusions "$fixture_master_hosts"
fi

fixture_over_dir="$WORK/over-shape"
fixture_over="$fixture_over_dir/install-over.sh"
mkdir -p "$fixture_over_dir"
cp -R "$SUBSTRATE/manifests" "$fixture_over_dir/manifests"
"$PY" - "$SUBSTRATE/install.sh" "$fixture_over" <<'PY' || fixture_over=""
import re
import sys

src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
loose_fn = '''kit_substrate_ingress_hosts() {
  local dir="$1"
  grep -h 'host:' "$dir"/*.yaml 2>/dev/null | sed -E -e 's/.*host:[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\\1/' -e "s/^'(.*)'\\$/\\1/" | grep -v '^$' || true
}
'''
fn = re.compile(r"kit_substrate_ingress_hosts\(\) \{.*?\n\}\n", re.S)
loose_text, n = fn.subn(lambda _m: loose_fn, text, count=1)
if n != 1:
    raise SystemExit(f"the reader matched {n} time(s), not once")
open(out, "w", encoding="utf-8").write(loose_text)
PY
if [ -z "$fixture_over" ] || [ ! -f "$fixture_over" ]; then
  fail 'control fixture: the loose mutant did not build' \
    'the python replacement of the fenced block failed — the red below would prove nothing'
elif ! bash -n "$fixture_over"; then
  fail 'control fixture: the loose mutant does not parse' \
    'the replacement broke the file — a red below would be a syntax error'
elif ! honest_dry_run "$fixture_over" >/dev/null 2>&1; then
  fail 'control fixture: DRY_RUN over the loose mutant fails' \
    'the replacement broke the run — a red below would be a broken fixture'
else
  over_out="$(sed '/^main "\$@"/d' "$fixture_over" >"$WORK/over-host-sourced.sh"; KIT_SUBSTRATE_APP_BASE_URL='' \
    KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER='' bash -c '. "$0"; kit_substrate_intended_hosts "$1"' \
      "$WORK/over-host-sourced.sh" "$WORK/ghost-apps" 2>&1)" || over_out=""
  case "$over_out" in
    *ghost.example.com*) ;;
    *) fail 'control fixture: the loose mutant does not over-report' \
         'the mutant lists no commented host — the red below would prove nothing about the parsing rule'
       ;;
  esac
  run 'control: a loose grep reading a commented host fails the no-invented check' red \
    check_no_manifestless_host "$fixture_over"
fi


rs_mock_kubectl() {
  if [ -n "${MOCK_ROOT:-}" ]; then
    printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"
  fi
    case "$1" in
      --kubeconfig=*) shift ;;
      -n) RS_MOCK_NS="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local verb="${1:-}"
  shift || true
  case "$verb" in
    get)
      local res="${1:-}"
      shift || true
      local name="" is_json=0
        case "$1" in
          -n) RS_MOCK_NS="$2"; shift 2 ;;
          -o) if [ "${2:-}" = "json" ]; then is_json=1; fi; shift 2 ;;
          *) name="$1"; shift ;;
        esac
      done
      [ "$is_json" -eq 1 ] || { echo "rs_mock_kubectl: only -o json is emulated" >&2; return 1; }
      if [ "$res" = "deployment" ]; then
        [ -f "$MOCK_ROOT/$RS_MOCK_NS/deploy-$name.json" ] || return 1
        cat "$MOCK_ROOT/$RS_MOCK_NS/deploy-$name.json"
        return 0
      fi
      if [ "$res" = "rs" ] || [ "$res" = "replicaset" ] || [ "$res" = "replicasets" ]; then
        if [ -f "$MOCK_ROOT/$RS_MOCK_NS/rs.json" ]; then
          cat "$MOCK_ROOT/$RS_MOCK_NS/rs.json"
        else
          printf '{"items":[]}'
        fi
        return 0
      fi
      echo "rs_mock_kubectl: unhandled get $res" >&2
      return 1
      ;;
    scale)
      local target="${1:-}"
      shift || true
      local replicas=""
        case "$1" in
          -n) RS_MOCK_NS="$2"; shift 2 ;;
          --replicas=*) replicas="${1#--replicas=}"; shift ;;
          *) shift ;;
        esac
      done
      local rs_name="${target#replicaset/}"
      rs_name="${rs_name#rs/}"
      [ "$replicas" = "0" ] || { echo "rs_mock_kubectl: only --replicas=0 is emulated" >&2; return 1; }
      "$PY" - "$MOCK_ROOT/$RS_MOCK_NS/rs.json" "$rs_name" <<'PY'
import json
import sys
path, name = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
hit = False
for item in doc.get("items", []):
    if item.get("metadata", {}).get("name") == name:
        item["spec"]["replicas"] = 0
        hit = True
if not hit:
    sys.exit(1)
json.dump(doc, open(path, "w"), indent=2)
PY
      printf '%s/%s\n' "$RS_MOCK_NS" "$rs_name" >>"$MOCK_ROOT/scaled"
      return 0
      ;;
    *)
      echo "rs_mock_kubectl: unhandled verb $verb" >&2
      return 1
      ;;
  esac
}

rs_seed_standard() {
  "$PY" - "$1" <<'PY'
import json
import os
import sys
root = sys.argv[1]

def deploy(ns, name, replicas, updated, image):
    doc = {
        "metadata": {"name": name, "namespace": ns},
        "spec": {"replicas": replicas,
                 "template": {"metadata": {"labels": {"app": name}},
                              "spec": {"containers": [{"name": name, "image": image}]}}},
        "status": {"replicas": replicas, "updatedReplicas": updated,
                   "availableReplicas": replicas},
    }
    os.makedirs(os.path.join(root, ns), exist_ok=True)
    json.dump(doc, open(os.path.join(root, ns, "deploy-%s.json" % name), "w"), indent=2)

def rs_list(ns, items):
    out = []
    for name, dep, h, live, image, created in items:
        out.append({
            "metadata": {"name": name, "namespace": ns, "creationTimestamp": created,
                         "labels": {"pod-template-hash": h},
                         "ownerReferences": [{"apiVersion": "apps/v1", "kind": "Deployment",
                                              "name": dep, "uid": "uid-%s" % name}]},
            "spec": {"replicas": 1 if live else 0,
                     "template": {"metadata": {"labels": {"app": dep, "pod-template-hash": h}},
                                  "spec": {"containers": [{"name": dep, "image": image}]}}},
        })
    os.makedirs(os.path.join(root, ns), exist_ok=True)
    json.dump({"items": out}, open(os.path.join(root, ns, "rs.json"), "w"), indent=2)

deploy("gateway", "gateway", 1, 1, "ghcr.io/anywaye/gateway@sha256:NEWLABEL")
rs_list("gateway", [
    ("gateway-aaaaaa", "gateway", "AAAAAA", True, "ghcr.io/anywaye/gateway@sha256:NEWLABEL", "2026-10-14T10:00:00Z"),
    ("gateway-bbbbbb", "gateway", "BBBBBB", True, "ghcr.io/anywaye/gateway:0.1.0", "2026-10-13T01:00:00Z"),
    ("gateway-cccccc", "gateway", "CCCCCC", False, "ghcr.io/anywaye/gateway:0.0.9", "2026-10-12T01:00:00Z"),
])
deploy("identity", "identity", 1, 1, "ghcr.io/anywaye/identity@sha256:I1LABEL")
rs_list("identity", [
    ("identity-xxxxxx", "identity", "XXXXXX", True, "ghcr.io/anywaye/identity@sha256:I1LABEL", "2026-10-14T09:00:00Z"),
])
deploy("parlor", "parlor", 0, 0, "ghcr.io/anywaye/parlor@sha256:P1LABEL")
rs_list("parlor", [
    ("parlor-pppppp", "parlor", "PPPPPP", True, "ghcr.io/anywaye/parlor@sha256:P0LABEL", "2026-10-13T05:00:00Z"),
])
deploy("courier", "courier", 1, 0, "ghcr.io/anywaye/courier@sha256:C1LABEL")
rs_list("courier", [
    ("courier-oooooo", "courier", "OOOOOO", True, "ghcr.io/anywaye/courier:0.1.0", "2026-10-14T08:00:00Z"),
])
print("standard RS store seeded")
PY
}

check_rs_converge() {
  local src="$1"
  local MOCK_ROOT="$2"
  local out ec=0
  out="$(
    DRY_RUN=0 HEADLESS=0
    unset -f converge_one_deployment_rs converge_residual_replicasets
    . "$src"
    kubectl() { rs_mock_kubectl "$@"; }
    converge_one_deployment_rs gateway gateway
  )" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'converge exited %s\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *'residual gateway/gateway-bbbbbb'*'(deployment gateway'*'ghcr.io/anywaye/gateway:0.1.0'*'2026-10-13T01:00:00Z'*) ;;
    *) printf 'the residual is not reported with its image, its age and its Deployment\n%s' "$out"; return 1 ;;
  esac
  case "$(cat "$MOCK_ROOT/scaled" 2>/dev/null || true)" in
    *'gateway/gateway-bbbbbb'*) ;;
    *) printf 'the residual was not scaled to 0\n%s' "$out"; return 1 ;;
  esac
  "$PY" - "$MOCK_ROOT/gateway/rs.json" <<'PY'
import json
import sys
doc = json.load(open(sys.argv[1]))
by_name = {i["metadata"]["name"]: i["spec"]["replicas"] for i in doc.get("items", [])}
if by_name.get("gateway-bbbbbb") != 0:
    print("the residual still names a replica: %r" % (by_name,))
    sys.exit(1)
if by_name.get("gateway-aaaaaa") != 1:
    print("the CURRENT RS was scaled: %r" % (by_name,))
    sys.exit(1)
print("residual at 0, current at 1")
PY
}

check_rs_idempotent() {
  local src="$1"
  local MOCK_ROOT="$2"
  local first ec_first=0 second ec_second=0
  first="$(
    DRY_RUN=0 HEADLESS=0
    . "$src"
    kubectl() { rs_mock_kubectl "$@"; }
    converge_one_deployment_rs gateway gateway
  )" || ec_first=$?
  second="$(
    DRY_RUN=0 HEADLESS=0
    . "$src"
    kubectl() { rs_mock_kubectl "$@"; }
    converge_one_deployment_rs gateway gateway
  )" || ec_second=$?
  [ "$ec_first" -eq 0 ] || { printf 'first converge exited %s\n%s' "$ec_first" "$first"; return 1; }
  [ "$ec_second" -eq 0 ] || { printf 'second converge exited %s\n%s' "$ec_second" "$second"; return 1; }
  case "$second" in
    *'no residual ReplicaSets'*) ;;
    *) printf 'the second run does not report a converged box\n%s' "$second"; return 1 ;;
  esac
  case "$(cat "$MOCK_ROOT/scaled" 2>/dev/null || true)" in
    'gateway/gateway-bbbbbb') printf 'converged once, second run scaled nothing new\n' ;;
    *) printf 'the scale record is not exactly one scale:\n%s' "$(cat "$MOCK_ROOT/scaled" 2>/dev/null || echo '(no scales)')"; return 1 ;;
  esac
}

check_rs_safe() {
  local src="$1"
  local MOCK_ROOT="$2"
  local out ec=0
  out="$(
    DRY_RUN=0 HEADLESS=0
    . "$src"
    kubectl() { rs_mock_kubectl "$@"; }
    converge_one_deployment_rs identity identity
    converge_one_deployment_rs parlor parlor
    converge_one_deployment_rs courier courier
    converge_one_deployment_rs gateway nosuchdeploy
  )" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'converge exited %s\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *'identity/identity: no residual ReplicaSets'*) ;;
    *) printf 'the current-only Deployment is not reported clean\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'parlor/parlor is scaled to 0 by its operator'*) ;;
    *) printf 'the deliberately scaled-down Deployment is not named as operator intent\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'courier/courier is mid-rollout'*) ;;
    *) printf 'the mid-rollout Deployment is not left to its controller\n%s' "$out"; return 1 ;;
  esac
  case "$out" in
    *'nosuchdeploy'*) printf 'the unsynced Deployment is not silent\n%s' "$out"; return 1 ;;
  esac
  if [ -f "$MOCK_ROOT/scaled" ]; then
    printf 'a protected Deployment was scaled:\n%s' "$(cat "$MOCK_ROOT/scaled")"
    return 1
  fi
  printf 'current, scaled-to-zero, mid-rollout and unsynced Deployments all untouched\n'
}

check_rs_dryrun() {
  local src="$1"
  local MOCK_ROOT="$2"
  local out ec=0
  out="$(
    DRY_RUN=1 HEADLESS=0
    . "$src"
    kubectl() { rs_mock_kubectl "$@"; }
    converge_one_deployment_rs gateway gateway
  )" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'dry-run converge exited %s\n%s' "$ec" "$out"; return 1; }
  case "$out" in
    *'residual gateway/gateway-bbbbbb'*'DRY_RUN: scale replicaset/gateway-bbbbbb'*) ;;
    *) printf 'the dry run does not print the residual it would converge\n%s' "$out"; return 1 ;;
  esac
  if [ -f "$MOCK_ROOT/scaled" ]; then
    printf 'the dry run scaled:\n%s' "$(cat "$MOCK_ROOT/scaled")"
    return 1
  fi
  "$PY" - "$MOCK_ROOT/gateway/rs.json" <<'PY'
import json
import sys
doc = json.load(open(sys.argv[1]))
by_name = {i["metadata"]["name"]: i["spec"]["replicas"] for i in doc.get("items", [])}
if by_name.get("gateway-bbbbbb") != 1:
    print("the dry run changed the store: %r" % (by_name,))
    sys.exit(1)
print("dry run changed nothing")
PY
}

check_rs_current_untouched() {
  local src="$1"
  local MOCK_ROOT="$2"
  local out ec=0
  out="$(
    DRY_RUN=0 HEADLESS=0
    unset -f converge_one_deployment_rs converge_residual_replicasets
    . "$src"
    kubectl() { rs_mock_kubectl "$@"; }
    converge_one_deployment_rs gateway gateway
  )" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'converge exited %s\n%s' "$ec" "$out"; return 1; }
  if [ -f "$MOCK_ROOT/scaled" ]; then
    printf 'the CURRENT RS was converged:\n%s' "$(cat "$MOCK_ROOT/scaled")"
    return 1
  fi
  printf 'the current RS was not converged\n'
}

rs_store_green="$WORK/rs-green"
mkdir -p "$rs_store_green"
rs_seed_standard "$rs_store_green" >/dev/null
run 'a residual RS is reported (image, age, Deployment) and scaled to 0' green \
  check_rs_converge "$fixture_sourced" "$rs_store_green"

rs_store_idem="$WORK/rs-idempotent"
mkdir -p "$rs_store_idem"
rs_seed_standard "$rs_store_idem" >/dev/null
run 'a second run on a converged box changes nothing' green \
  check_rs_idempotent "$fixture_sourced" "$rs_store_idem"

rs_store_safe="$WORK/rs-safe"
mkdir -p "$rs_store_safe"
rs_seed_standard "$rs_store_safe" >/dev/null
run 'the current RS, the scaled-to-zero Deployment, the mid-rollout and the unsynced Deployment are untouched' green \
  check_rs_safe "$fixture_sourced" "$rs_store_safe"

rs_store_dry="$WORK/rs-dry"
mkdir -p "$rs_store_dry"
rs_seed_standard "$rs_store_dry" >/dev/null
run 'the dry run prints the residual it would converge and converges nothing' green \
  check_rs_dryrun "$fixture_sourced" "$rs_store_dry"

mkdir -p "$WORK/rs-empty"
run 'control: the converge check needs its fixture (empty store goes red)' red \
  check_rs_converge "$fixture_sourced" "$WORK/rs-empty"

rs_store_full="$WORK/rs-full"
mkdir -p "$rs_store_full"
rs_seed_standard "$rs_store_full" >/dev/null
rs_full_human="$WORK/rs-full.human"
rs_full_ec=0
rs_full_out="$(
  export KIT_SUBSTRATE_RECEIPT="$WORK/rs-full-receipt.json"
  export HEADLESS=1 DRY_RUN=0
  MOCK_ROOT="$rs_store_full"
  unset -f converge_one_deployment_rs converge_residual_replicasets
  . "$fixture_sourced"
  kubectl() { rs_mock_kubectl "$@"; }
  CURRENT_PHASE="rs-residual"
  {
    converge_residual_replicasets
    printf 'STEP_SKIPPED=%s\n' "$STEP_SKIPPED" >&2
    kit_substrate_step_finalize
  } 2>"$rs_full_human"
)" || rs_full_ec=$?
if [ "$rs_full_ec" -ne 0 ]; then
  fail 'the whole step converges all four Deployments' "exit ${rs_full_ec}: $(printf '%s' "$rs_full_out" | head -8)"
else
  case "$rs_full_out" in
    *'"event":"step.start"'*'"event":"step.done"'*'"seconds":'[0-9]*) ;;
    *) fail 'the whole step emits step.start/step.done with seconds' "$(printf '%s' "$rs_full_out" | head -4)" ;;
  esac
  if [ "$failures" -ne 0 ]; then
  elif ! grep -q 'residual gateway/gateway-bbbbbb' "$rs_full_human"; then
    fail 'the whole step reports the residual' "$(head -8 "$rs_full_human")"
  elif ! grep -q 'STEP_SKIPPED=0' "$rs_full_human"; then
    fail 'the whole step clears STEP_SKIPPED on real work' "$(tail -4 "$rs_full_human")"
  elif [ "$(cat "$rs_store_full/scaled" 2>/dev/null || true)" != "gateway/gateway-bbbbbb" ]; then
    fail 'the whole step scales only the residual' "$(cat "$rs_store_full/scaled" 2>/dev/null || echo '(no scales)')"
  else
    pass 'the whole step converges all four Deployments, timed, STEP_SKIPPED cleared'
  fi
fi

fixture_rs_master="$WORK/rs-master.sh"
sed -e '/^converge_residual_replicasets() {$/,/^}$/d' \
    -e '/^converge_one_deployment_rs() {$/,/^}$/d' \
    -e '/^  CURRENT_PHASE="rs-residual"$/d' \
    -e '/^  converge_residual_replicasets$/d' \
    "$SUBSTRATE/install.sh" >"$fixture_rs_master"
case "$(grep -v '^[[:space:]]*#' "$fixture_rs_master")" in
  *'converge_one_deployment_rs'* | *'converge_residual_replicasets'* | *'rs-residual'*)
    fail 'control fixture: the master shape still carries the RS step' \
      'the sed did not remove the step — this control would prove nothing'
    ;;
  *)
    if ! bash -n "$fixture_rs_master"; then
      fail 'control fixture: the master shape does not parse' \
        'the sed broke the file — a red below would be a syntax error wearing the finding clothes'
    else
      fixture_rs_master_sourced="$WORK/rs-master-sourced.sh"
      sed '/^main "$@"/d' "$fixture_rs_master" >"$fixture_rs_master_sourced"
      rs_store_master="$WORK/rs-master"
      mkdir -p "$rs_store_master"
      rs_seed_standard "$rs_store_master" >/dev/null
      run 'control: without the step the residual survives' red \
        check_rs_converge "$fixture_rs_master_sourced" "$rs_store_master"
    fi
    ;;
esac

rs_store_current="$WORK/rs-current"
mkdir -p "$rs_store_current/gateway"
"$PY" - "$rs_store_current" <<'PY'
import json
import os
import sys
root = sys.argv[1]
deploy = {
    "metadata": {"name": "gateway", "namespace": "gateway"},
    "spec": {"replicas": 1,
             "template": {"metadata": {"labels": {"app": "gateway"}},
                          "spec": {"containers": [{"name": "gateway",
                                                   "image": "ghcr.io/anywaye/gateway@sha256:ONLYLABEL"}]}}},
    "status": {"replicas": 1, "updatedReplicas": 1, "availableReplicas": 1},
}
json.dump(deploy, open(os.path.join(root, "gateway", "deploy-gateway.json"), "w"), indent=2)
rs = {"metadata": {"name": "gateway-only", "namespace": "gateway",
                   "creationTimestamp": "2026-10-14T10:00:00Z",
                   "labels": {"pod-template-hash": "ONLYHASH"},
                   "ownerReferences": [{"apiVersion": "apps/v1", "kind": "Deployment",
                                        "name": "gateway", "uid": "uid-only"}]},
      "spec": {"replicas": 1,
               "template": {"metadata": {"labels": {"app": "gateway",
                                                    "pod-template-hash": "ONLYHASH"}},
                            "spec": {"containers": [{"name": "gateway",
                                                     "image": "ghcr.io/anywaye/gateway@sha256:ONLYLABEL"}]}}}}
json.dump({"items": [rs]}, open(os.path.join(root, "gateway", "rs.json"), "w"), indent=2)
PY
run 'a box whose only live RS is current is converged to nothing' green \
  check_rs_current_untouched "$fixture_sourced" "$rs_store_current"
fixture_rs_inverted="$WORK/rs-inverted.sh"
sed 's/!= \$hash/== $hash/' \
  "$SUBSTRATE/install.sh" >"$fixture_rs_inverted"
case "$(cat "$fixture_rs_inverted")" in
  *'// "") == $hash'*)
    if ! bash -n "$fixture_rs_inverted"; then
      fail 'control fixture: the inverted shape does not parse' \
        'the sed broke the file — a red below would be a syntax error wearing the finding clothes'
    else
      fixture_rs_inverted_sourced="$WORK/rs-inverted-sourced.sh"
      sed '/^main "$@"/d' "$fixture_rs_inverted" >"$fixture_rs_inverted_sourced"
      rs_store_inverted="$WORK/rs-inverted"
      mkdir -p "$rs_store_inverted/gateway"
      cp "$rs_store_current/gateway/deploy-gateway.json" "$rs_store_inverted/gateway/"
      cp "$rs_store_current/gateway/rs.json" "$rs_store_inverted/gateway/"
      run 'control: an inverted hash check converges the current RS' red \
        check_rs_current_untouched "$fixture_rs_inverted_sourced" "$rs_store_inverted"
    fi
    ;;
  *)
    fail 'control fixture: the inversion did not land' \
      'the sed matched nothing — this control would prove nothing'
    ;;
esac

check_loki_honest() {
  local apps_dir="$1" install_sh="$2"
  local problems=""
  local count
  count="$(ls -1 "$apps_dir"/*.yaml 2>/dev/null | wc -l)"
  if [ "$count" -lt 7 ]; then
    printf 'apps_dir has %s manifest(s), expected 7 (empty or partial directory proves nothing)\n' "$count"
    return 1
  fi
  if [ -f "$apps_dir/loki.yaml" ]; then
    "$PY" - "$apps_dir/loki.yaml" <<'PY'
import sys
import yaml
path = sys.argv[1]
doc = yaml.safe_load(open(path, encoding="utf-8"))
src = (doc.get("spec") or {}).get("source") or {}
helm = src.get("helm") or {}
values = helm.get("values") or ""
if not isinstance(values, str) or not values.strip():
    print("loki.yaml has no helm.values — chart requires loki.storage.bucketNames.chunks")
    sys.exit(1)
try:
    v = yaml.safe_load(values)
except Exception as e:
    print(f"loki helm.values does not parse: {e}")
    sys.exit(1)
if not isinstance(v, dict):
    print("loki helm.values is not a mapping")
    sys.exit(1)
loki = v.get("loki") or {}
storage = loki.get("storage") or {}
bucketNames = storage.get("bucketNames") or {}
deploymentMode = v.get("deploymentMode") or "SimpleScalable"
storage_type = storage.get("type") or "s3"
if storage_type == "filesystem":
    if deploymentMode != "SingleBinary":
        print(f"filesystem storage requires deploymentMode SingleBinary, not {deploymentMode}")
        sys.exit(1)
    if v.get("singleBinary", {}).get("replicas", 0) == 0:
        print("filesystem SingleBinary requires singleBinary.replicas > 0")
        sys.exit(1)
else:
    for k in ("chunks", "ruler", "admin"):
        if not bucketNames.get(k):
            print(f"loki.storage.bucketNames.{k} is missing — chart fails at write statefulset with 'Please define loki.storage.bucketNames.{k}'")
            sys.exit(1)
    s3 = storage.get("s3") or {}
    missing = []
    if not s3.get("endpoint"):
        missing.append("endpoint")
    if not s3.get("accessKeyId"):
        missing.append("accessKeyId")
    if not s3.get("secretAccessKey"):
        missing.append("secretAccessKey")
    if missing:
        print(f"half object-storage config: missing {', '.join(missing)} — bucketNames alone stores nothing (ComparisonError would persist as a runtime error)")
        sys.exit(1)
print("loki present with complete storage config")
PY
    ec=$?
    if [ "$ec" -ne 0 ]; then
      return 1
    fi
    local out
    out="$(KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor,billing" KIT_SUBSTRATE_RECEIPT="$WORK/loki-report.json" DRY_RUN=1 bash "$install_sh" 2>&1 || true)"
    case "$out" in
      *"logs: centralized Loki installed"*) ;;
      *) printf 'loki present but install.sh does not report "centralized Loki installed"\n'; return 1 ;;
    esac
    return 0
  fi
  local out
  out="$(KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor,billing" KIT_SUBSTRATE_RECEIPT="$WORK/loki-report.json" DRY_RUN=1 bash "$install_sh" 2>&1 || true)"
  case "$out" in
    *"centralized Loki not installed"* ) ;;
    *) printf 'install.sh does not report "centralized Loki not installed"\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *"loki.storage.bucketNames.chunks"* ) ;;
    *) printf 'install.sh log report does not name loki.storage.bucketNames.chunks (the ComparisonError evidence)\n'; return 1 ;;
  esac
  case "$out" in
    *"journald"* ) ;;
    *) printf 'install.sh log report does not name journald/kubectl logs (what replaces Loki)\n'; return 1 ;;
  esac
  local jsonl="$WORK/loki-headless.jsonl"
  KIT_SUBSTRATE_DATABASES="identity,gateway,courier,parlor,billing" KIT_SUBSTRATE_RECEIPT="$WORK/loki-headless-receipt.json" HEADLESS=1 DRY_RUN=1 bash "$install_sh" --headless >"$jsonl" 2>/dev/null || true
  if ! grep -q '"event":"readiness"' "$jsonl"; then
    printf 'headless stream has no readiness event\n'; return 1
  fi
  if ! grep -q '"log_store":"journald"' "$jsonl"; then
    printf 'readiness event missing "log_store":"journald"\n'; cat "$jsonl"; return 1
  fi
  if ! grep -q '"tls_pending_hosts"' "$jsonl"; then
    printf 'readiness event lost tls_pending_hosts after log_store addition\n'; return 1
  fi
  if ! grep -q '"oidc_configured"' "$jsonl"; then
    printf 'readiness event lost oidc_configured after log_store addition\n'; return 1
  fi
  printf 'loki absent, install.done honest: journald + bucketNames evidence, headless log_store journald\n'
}

run 'loki Application absent and install.done reports journald + bucketNames evidence (headless log_store journald)' green \
  check_loki_honest "$MANIFESTS" "$SUBSTRATE/install.sh"

fixture_loki_broken="$WORK/loki-broken"
mkdir -p "$fixture_loki_broken"
cp "$MANIFESTS"/*.yaml "$fixture_loki_broken"/ 2>/dev/null || true
cat >"$fixture_loki_broken/loki.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: loki
    targetRevision: 7.3.0
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML
run 'control: the broken loki values (no bucketNames) go red' red \
  check_loki_honest "$fixture_loki_broken" "$SUBSTRATE/install.sh"
if grep -q "bucketNames" "$fixture_loki_broken/loki.yaml"; then
  fail 'control fixture premise: broken loki must carry no bucketNames' 'fixture has bucketNames, so it would not test the master shape'
else
  pass 'control fixture premise: broken loki carries no bucketNames (master shape)'
fi

fixture_loki_half="$WORK/loki-half"
mkdir -p "$fixture_loki_half"
cp "$MANIFESTS"/*.yaml "$fixture_loki_half"/ 2>/dev/null || true
cat >"$fixture_loki_half/loki.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: loki
    targetRevision: 7.3.0
    helm:
      values: |
        loki:
          storage:
            type: s3
            bucketNames:
              chunks: chunks
              ruler: ruler
              admin: admin
            s3:
              region: us-east-1
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
YAML
run 'control: half object-storage config (bucketNames without endpoint/keys) goes red' red \
  check_loki_honest "$fixture_loki_half" "$SUBSTRATE/install.sh"

empty_apps="$WORK/empty-apps"
mkdir -p "$empty_apps"
run 'control: empty apps directory goes red (vacuity guard)' red \
  check_loki_honest "$empty_apps" "$SUBSTRATE/install.sh"

check_appproject_cluster_scope() {
  "$PY" - "$1" "$2" <<'PY'
import os
import sys

import yaml

apps_dir, proj_path = sys.argv[1:3]

files = sorted(f for f in os.listdir(apps_dir) if f.endswith((".yaml", ".yml")))
if len(files) < 7:
    print(f"{apps_dir} holds {len(files)} Application manifest(s), expected at least 7 — an empty or partial directory proves nothing")
    sys.exit(1)

try:
    proj_doc = yaml.safe_load(open(proj_path, encoding="utf-8"))
except FileNotFoundError:
    print(f"{proj_path}: no such file — the project the Applications name is not shipped")
    sys.exit(1)
except yaml.YAMLError as e:
    print(f"{proj_path}: does not parse ({e})")
    sys.exit(1)
if not isinstance(proj_doc, dict) or proj_doc.get("kind") != "AppProject":
    print(f"{proj_path}: not an AppProject")
    sys.exit(1)
spec = proj_doc.get("spec") or {}
raw_wl = spec.get("clusterResourceWhitelist") or []
if not isinstance(raw_wl, list):
    print(f"{proj_path}: spec.clusterResourceWhitelist is not a list")
    sys.exit(1)
whitelist = set()
for entry in raw_wl:
    if not isinstance(entry, dict) or "group" not in entry or "kind" not in entry:
        print(f"{proj_path}: clusterResourceWhitelist entry {entry!r} is not a {{group, kind}} pair")
        sys.exit(1)
    whitelist.add((entry["group"], entry["kind"]))

problems = []
for group, kind in sorted(whitelist):
    if group == "*" or kind == "*":
        problems.append(
            f"clusterResourceWhitelist entry group {group!r} kind {kind!r} is a wildcard — whitelist exactly the kinds the Applications declare, never */*"
        )

needs = {}
for f in files:
    path = os.path.join(apps_dir, f)
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except yaml.YAMLError as e:
        problems.append(f"{f}: does not parse ({e})")
        continue
    if not isinstance(doc, dict):
        problems.append(f"{f}: not a mapping")
        continue
    ann = ((doc.get("metadata") or {}).get("annotations") or {}).get("anywaye.io/cluster-resources", "")
    declared = set()
    if ann and ann.strip():
        for item in ann.split(","):
            item = item.strip()
            if item.count("/") != 1 or item.startswith("/") or item.endswith("/"):
                problems.append(f"{f}: annotation anywaye.io/cluster-resources entry {item!r} is not 'group/kind'")
                continue
            group, kind = item.split("/")
            declared.add((group.strip(), kind.strip()))
    needs[f] = declared

for f in files:
    for pair in sorted(needs.get(f, set())):
        if pair not in whitelist:
            problems.append(
                f"{f} declares cluster-scoped {pair[0]}/{pair[1]} but the AppProject does not whitelist it — this is the live-box SyncError ('is not permitted in project default')"
            )

declared_union = set()
for pairs in needs.values():
    declared_union.update(pairs)
for pair in sorted(whitelist):
    if pair[0] != "*" and pair[1] != "*" and pair not in declared_union:
        problems.append(
            f"clusterResourceWhitelist entry {pair[0]}/{pair[1]} is declared by no Application — an over-grant is the same defect as an under-grant"
        )

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(files)} Applications, every declared cluster-scoped kind whitelisted, every whitelist entry declared ({len(whitelist)} pairs, no wildcards)")
PY
}

check_appproject_cluster_scope_pins() {
  "$PY" - "$1" <<'PY'
import os
import sys

import yaml

apps_dir = sys.argv[1]

EXPECTED = {
    "billing.yaml": set(),
    "alloy.yaml": {
        ("apiextensions.k8s.io", "CustomResourceDefinition"),
        ("rbac.authorization.k8s.io", "ClusterRole"),
        ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    },
    "grafana.yaml": {
        ("rbac.authorization.k8s.io", "ClusterRole"),
        ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    },
    "prometheus.yaml": {
        ("rbac.authorization.k8s.io", "ClusterRole"),
        ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    },
    "courier.yaml": set(),
    "gateway.yaml": set(),
    "identity.yaml": set(),
    "parlor.yaml": set(),
}

files = sorted(f for f in os.listdir(apps_dir) if f.endswith((".yaml", ".yml")))
if len(files) < 7:
    print(f"{apps_dir} holds {len(files)} Application manifest(s), expected at least 7 — an empty or partial directory proves nothing")
    sys.exit(1)

problems = []
for f in files:
    if f not in EXPECTED:
        problems.append(
            f"{f}: no cluster-scope record — render its chart (defaults, --include-crds, the pinned targetRevision) and record its cluster-scoped kinds"
        )
        continue
    path = os.path.join(apps_dir, f)
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except yaml.YAMLError as e:
        problems.append(f"{f}: does not parse ({e})")
        continue
    ann = ((doc.get("metadata") or {}).get("annotations") or {}).get("anywaye.io/cluster-resources", "")
    declared = set()
    if ann and ann.strip():
        for item in ann.split(","):
            item = item.strip()
            if item.count("/") == 1 and not item.startswith("/") and not item.endswith("/"):
                group, kind = item.split("/")
                declared.add((group.strip(), kind.strip()))
    if declared != EXPECTED[f]:
        problems.append(
            f"{f}: annotation declares {sorted(declared)} but the pinned render is {sorted(EXPECTED[f])} — the annotation must tell the truth about its chart"
        )

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(files)} Applications, every annotation equals its pinned render (service Applications: no cluster scope)")
PY
}

check_appproject_no_star() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

proj_path = sys.argv[1]
try:
    proj_doc = yaml.safe_load(open(proj_path, encoding="utf-8"))
except FileNotFoundError:
    print(f"{proj_path}: no such file")
    sys.exit(1)
except yaml.YAMLError as e:
    print(f"{proj_path}: does not parse ({e})")
    sys.exit(1)
spec = (proj_doc or {}).get("spec") or {}
raw_wl = spec.get("clusterResourceWhitelist") or []
stars = [(e.get("group"), e.get("kind")) for e in raw_wl if isinstance(e, dict) and (e.get("group") == "*" or e.get("kind") == "*")]
if stars:
    print(f"clusterResourceWhitelist carries wildcard entries {stars} — the project stays bounded, never */*")
    sys.exit(1)
print(f"clusterResourceWhitelist holds {len(raw_wl)} exact {{group, kind}} pair(s), no wildcards")
PY
}

run 'every Application-declared cluster-scoped kind is whitelisted, every whitelist entry declared, no wildcards' green \
  check_appproject_cluster_scope "$MANIFESTS" "$APP_PROJECT"
run 'every Application annotation equals its pinned chart render (services: no cluster scope)' green \
  check_appproject_cluster_scope_pins "$MANIFESTS"
run 'the clusterResourceWhitelist contains no wildcard entry' green \
  check_appproject_no_star "$APP_PROJECT"

fixture_project_no_wl="$WORK/appproject-no-whitelist.yaml"
"$PY" - "$APP_PROJECT" "$fixture_project_no_wl" <<'PY'
import sys

import yaml

src, dst = sys.argv[1:3]
doc = yaml.safe_load(open(src, encoding="utf-8"))
(spec := doc.get("spec") or {}).pop("clusterResourceWhitelist", None)
yaml.safe_dump(doc, open(dst, "w", encoding="utf-8"), default_flow_style=False)
PY
case "$(cat "$fixture_project_no_wl")" in
  *clusterResourceWhitelist*)
    fail 'control fixture: the master shape still carries a whitelist' \
      'the transform did not remove clusterResourceWhitelist — this control would prove nothing'
    ;;
  *)
    run 'control: the master-shape project (no whitelist) fails the completeness check' red \
      check_appproject_cluster_scope "$MANIFESTS" "$fixture_project_no_wl"
    ;;
esac

fixture_apps_grown="$WORK/apps-grown-kind"
rm -rf "$fixture_apps_grown"
mkdir -p "$fixture_apps_grown"
cp -R "$MANIFESTS/." "$fixture_apps_grown/"
"$PY" - "$fixture_apps_grown/grafana.yaml" <<'PY'
import sys

import yaml

path = sys.argv[1]
docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
doc = docs[0]
ann = (doc.setdefault("metadata", {}).setdefault("annotations", {}))
have = ann.get("anywaye.io/cluster-resources", "")
ann["anywaye.io/cluster-resources"] = (have + ", admissionregistration.k8s.io/MutatingWebhookConfiguration").lstrip(", ")
yaml.safe_dump_all(docs, open(path, "w", encoding="utf-8"), default_flow_style=False)
PY
if grep -q 'admissionregistration.k8s.io/MutatingWebhookConfiguration' "$fixture_apps_grown/grafana.yaml"; then
  run 'control: a chart growing an unwhitelisted cluster-scoped kind goes red' red \
    check_appproject_cluster_scope "$fixture_apps_grown" "$APP_PROJECT"
else
  fail 'control fixture: the grown kind did not land' \
    'grafana.yaml carries no MutatingWebhookConfiguration, so the control would prove nothing'
fi

fixture_project_star="$WORK/appproject-star.yaml"
"$PY" - "$APP_PROJECT" "$fixture_project_star" <<'PY'
import sys

import yaml

src, dst = sys.argv[1:3]
doc = yaml.safe_load(open(src, encoding="utf-8"))
(doc.get("spec") or {})["clusterResourceWhitelist"] = [{"group": "*", "kind": "*"}]
yaml.safe_dump(doc, open(dst, "w", encoding="utf-8"), default_flow_style=False)
PY
if grep -q "kind: '\*'" "$fixture_project_star"; then
  run 'control: a project whitelisting */* goes red' red \
    check_appproject_no_star "$fixture_project_star"
else
  fail 'control fixture: the */* whitelist did not land' \
    'the fixture carries no wildcard entry, so the control would prove nothing'
fi

run 'control: empty apps directory goes red (vacuity guard)' red \
  check_appproject_cluster_scope "$empty_apps" "$APP_PROJECT"

check_substrate_operated_absent() {
  "$PY" - "$1" <<'PY'
import os
import re
import sys

import yaml

apps_dir = sys.argv[1]
OPERATED = ("pantry", "box", "keyholder")

problems = []
for f in sorted(os.listdir(apps_dir)):
    if not f.endswith((".yaml", ".yml")):
        continue
    stem = f.rsplit(".", 1)[0]
    if stem in OPERATED:
        problems.append(
            f"{f}: names an operated service — pantry, box and keyholder are "
            "Anywaye-operated and reached over HTTPS, never deployed to the box"
        )
        continue
    try:
        doc = yaml.safe_load(open(os.path.join(apps_dir, f), encoding="utf-8"))
    except yaml.YAMLError as e:
        problems.append(f"{f}: does not parse ({e})")
        continue
    name = (doc.get("metadata") or {}).get("name") if isinstance(doc, dict) else None
    if name in OPERATED:
        problems.append(
            f"{f}: metadata.name {name!r} is an operated service — see above"
        )

if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{apps_dir}: no Application names pantry, box or keyholder — the box runs four services, and talks to the other three")
PY
}

run 'the substrate ships no pantry, box or keyholder Application' green \
  check_substrate_operated_absent "$MANIFESTS"

check_substrate_operated_wiring() {
  "$PY" - "$1" "$2" <<'PY'
import re
import sys

cluster_path, install_path = sys.argv[1:3]

def code_without_comments(path):
    out = []
    for line in open(path, encoding="utf-8"):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        out.append(line.split("#", 1)[0])
    return "\n".join(out)

problems = []
cluster = code_without_comments(cluster_path)
for svc in ("pantry", "box", "keyholder"):
    for pat in (f'"{svc}"', f'"{svc}_app"', f"postgres-role-{svc}"):
        if pat in cluster:
            problems.append(
                f"postgres-cluster.yaml still provisions {pat} — the {svc} database and roles left with its Application"
            )
install = code_without_comments(install_path)
for svc in ("pantry", "keyholder"):
    if re.search(rf"(?m)^\s*(?:for\s+\S+\s+in\s+.*|.*\b){svc}\b.*(?:;|\bdo\b)|\b{svc}/", install):
        problems.append(
            f"install.sh still wires {svc} (a service loop, secret or namespace) — see above"
        )
if re.search(r"(?m)\bfor svc in .*\bbox\b", install):
    problems.append("install.sh still loops over the box service — see above")
if re.search(r"(?m)database_url_for box\b|MIGRATE_CMD_box\b|secret generic box-secrets", install):
    problems.append("install.sh still names a box-service secret or migrator — see above")

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("the Cluster provisions four services and install.sh wires four services — pantry, box and keyholder appear only in comments")
PY
}

run 'the Cluster and the installer wire no operated service' green \
  check_substrate_operated_wiring "$SUBSTRATE/manifests/data/postgres-cluster.yaml" "$SUBSTRATE/install.sh"

fixture_apps_operated="$WORK/apps-operated"
rm -rf "$fixture_apps_operated"
mkdir -p "$fixture_apps_operated"
cp "$MANIFESTS"/*.yaml "$fixture_apps_operated/"
for svc in pantry keyholder box; do
  sed "s/courier/$svc/g" "$MANIFESTS/courier.yaml" >"$fixture_apps_operated/$svc.yaml"
done
if grep -q 'repoURL: oci://ghcr.io/anywaye/charts/pantry' "$fixture_apps_operated/pantry.yaml" && \
   grep -q 'repoURL: oci://ghcr.io/anywaye/charts/keyholder' "$fixture_apps_operated/keyholder.yaml" && \
   grep -q 'repoURL: oci://ghcr.io/anywaye/charts/box' "$fixture_apps_operated/box.yaml"; then
  run 'control: the master shape (operated Applications present) fails the absence check' red \
    check_substrate_operated_absent "$fixture_apps_operated"
else
  fail 'control fixture: the operated Applications did not land' \
    'a fixture Application names no fleet chart, so the control would prove nothing'
fi

# The licence half: BSL-1.1 with its Change Date and Change License is the
# runnable shape; EITHER proprietary operated sentence is refused — box's
# "never part of … the Kit deployment substrate" and pantry's "runs on
# Anywaye infrastructure … never … a second, forked catalog", each matched on
# its wording rather than on the service's name. Anything else — or an
# unreadable licence — fails closed. Only Applications pulling the fleet's
# own registry are classified; the observability three are counted and
# skipped, never failed. An absent sibling checkout is NAMED in a note (the
# §11b precedent): on a fresh clone every service is a note, and a note is
# an environment gap, not a verdict.
check_substrate_licences() {
  "$PY" - "$1" "$2" <<'PY'
import os
import sys

import yaml

apps_dir, fleet_dir = sys.argv[1:3]
FLEET_ROOT = "oci://ghcr.io/anywaye/charts/"

def classify(text):
    stripped = text.lstrip()
    if stripped.startswith("Business Source License 1.1") and \
            "Change Date:" in text and "Change License:" in text:
        return "runnable"
    lowered = text.lower()
    if "never part of" in lowered and "deployment substrate" in lowered:
        return "refused"
    if "runs on anywaye infrastructure" in lowered and \
            ("forked catalog" in lowered or "operated registry" in lowered):
        return "refused"
    return "unclassifiable"

files = sorted(f for f in os.listdir(apps_dir) if f.endswith((".yaml", ".yml")))
fleet_apps = []
upstream = 0
for f in files:
    path = os.path.join(apps_dir, f)
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except yaml.YAMLError as e:
        print(f"{f}: does not parse ({e})")
        sys.exit(1)
    if not isinstance(doc, dict):
        print(f"{f}: not a mapping")
        sys.exit(1)
    repo = ((doc.get("spec") or {}).get("source") or {}).get("repoURL", "")
    if isinstance(repo, str) and repo.startswith(FLEET_ROOT):
        chart = repo[len(FLEET_ROOT):]
        if not chart or "/" in chart:
            print(f"{f}: fleet repoURL {repo!r} names no single chart — the licence cannot be found")
            sys.exit(1)
        fleet_apps.append((f, chart))
    else:
        upstream += 1

if not fleet_apps:
    print(f"{apps_dir} names no fleet Application — a check that graded nothing proves nothing")
    sys.exit(1)

problems = []
notes = []
runnable = []
for f, svc in fleet_apps:
    checkout = os.path.join(fleet_dir, svc)
    lic = os.path.join(checkout, "LICENSE")
    if not os.path.isdir(checkout):
        notes.append(f"{svc}: no sibling checkout under {fleet_dir} — not asserted")
        continue
    if not os.path.isfile(lic):
        problems.append(
            f"{f}: the {svc} checkout carries no LICENSE — an unreadable licence is not a permission"
        )
        continue
    try:
        with open(lic, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        problems.append(f"{f}: the {svc} LICENSE cannot be read ({exc}) — an unreadable licence is not a permission")
        continue
    verdict = classify(text)
    if verdict == "runnable":
        runnable.append(svc)
    elif verdict == "refused":
        problems.append(
            f"{f}: the {svc} licence names it Anywaye-operated — a customer's box has no licence to run it"
        )
    else:
        problems.append(
            f"{f}: the {svc} LICENSE is neither BSL-1.1 nor a proprietary operated sentence — an unclassifiable licence is not a permission"
        )

if problems:
    print("; ".join(problems))
    sys.exit(1)
for note in notes:
    print(f"note: {note}")
print(f"licences: {len(runnable)} runnable under BSL-1.1 ({', '.join(sorted(runnable)) or 'none graded'}), "
      f"{upstream} upstream (out of scope), {len(notes)} absent checkout(s) noted")
PY
}

run 'every fleet Application carries a licence permitting a customer box to run it' green \
  check_substrate_licences "$MANIFESTS" "$ROOT/.."

fixture_fleet="$WORK/operated-fleet"
rm -rf "$fixture_fleet"
mkdir -p "$fixture_fleet/identity" "$fixture_fleet/gateway" "$fixture_fleet/courier" "$fixture_fleet/parlor" \
  "$fixture_fleet/pantry" "$fixture_fleet/box" "$fixture_fleet/keyholder" "$fixture_fleet/ledger"
for svc in identity gateway courier parlor keyholder ledger; do
  cat >"$fixture_fleet/$svc/LICENSE" <<'LICENSE'
Business Source License 1.1

Parameters

Licensor:             Anywaye
Additional Use Grant: None
Change Date:          2030-10-10
Change License:       Apache-2.0
LICENSE
done
cat >"$fixture_fleet/box/LICENSE" <<'LICENSE'
Copyright (c) 2026 Anywaye. All rights reserved.

Box is Anywaye-proprietary, and it is closed by decision rather than by
omission. It is the operated control plane. It runs on Anywaye
infrastructure, is never part of a customer source bundle, a customer
install or the Kit deployment substrate, and no Box code may assume
otherwise.

There is no Business Source Licence in this file and no Change Date.
LICENSE
cat >"$fixture_fleet/pantry/LICENSE" <<'LICENSE'
Copyright (c) 2026 Anywaye. All rights reserved.

Pantry is Anywaye-proprietary, and it is closed by decision rather than by
omission. It is the operated registry. It runs on Anywaye infrastructure.
Nothing here may be run as a second, forked catalog.

There is no Business Source Licence in this file and no Change Date.
LICENSE
if grep -q 'never part of a customer' "$fixture_fleet/box/LICENSE" && \
   grep -q 'forked catalog' "$fixture_fleet/pantry/LICENSE" && \
   grep -q 'Business Source License 1.1' "$fixture_fleet/keyholder/LICENSE"; then
  run 'licences: the shipped services classify runnable (BSL)' green \
    check_substrate_licences "$MANIFESTS" "$fixture_fleet"
  fixture_apps_pantry="$WORK/apps-pantry-licence"
  rm -rf "$fixture_apps_pantry"
  mkdir -p "$fixture_apps_pantry"
  sed 's/courier/pantry/g' "$MANIFESTS/courier.yaml" >"$fixture_apps_pantry/pantry.yaml"
  if grep -q 'repoURL: oci://ghcr.io/anywaye/charts/pantry' "$fixture_apps_pantry/pantry.yaml"; then
    run 'control: pantry under its proprietary operated licence fails the licence check' red \
      check_substrate_licences "$fixture_apps_pantry" "$fixture_fleet"
  else
    fail 'control fixture: the pantry Application did not land' \
      'the fixture carries no pantry chart reference, so the control would prove nothing'
  fi
  fixture_apps_box="$WORK/apps-box-licence"
  rm -rf "$fixture_apps_box"
  mkdir -p "$fixture_apps_box"
  sed 's/courier/box/g' "$MANIFESTS/courier.yaml" >"$fixture_apps_box/box.yaml"
  if grep -q 'repoURL: oci://ghcr.io/anywaye/charts/box' "$fixture_apps_box/box.yaml"; then
    run 'control: box under its proprietary substrate licence fails the licence check' red \
      check_substrate_licences "$fixture_apps_box" "$fixture_fleet"
  else
    fail 'control fixture: the box Application did not land' \
      'the fixture carries no box chart reference, so the control would prove nothing'
  fi
  mkdir -p "$fixture_fleet/stranger"
  printf 'Copyright (c) 2026 Anywaye. All rights reserved. Ask nicely.\n' >"$fixture_fleet/stranger/LICENSE"
  fixture_apps_stranger="$WORK/apps-stranger-licence"
  rm -rf "$fixture_apps_stranger"
  mkdir -p "$fixture_apps_stranger"
  sed 's/courier/stranger/g' "$MANIFESTS/courier.yaml" >"$fixture_apps_stranger/stranger.yaml"
  sed -i.bak 's|repoURL: oci://ghcr.io/anywaye/charts/stranger|repoURL: oci://ghcr.io/anywaye/charts/stranger|' "$fixture_apps_stranger/stranger.yaml"
  rm -f "$fixture_apps_stranger/stranger.yaml.bak"
  if grep -q 'repoURL: oci://ghcr.io/anywaye/charts/stranger' "$fixture_apps_stranger/stranger.yaml"; then
    run 'control: an unclassifiable licence fails the licence check' red \
      check_substrate_licences "$fixture_apps_stranger" "$fixture_fleet"
  else
    fail 'control fixture: the stranger Application did not land' \
      'the fixture carries no stranger chart reference, so the control would prove nothing'
  fi
else
  fail 'control fixture: the licence fleet did not land' \
    'a fixture LICENCE carries no classifying sentence, so the controls would prove nothing'
fi

check_substrate_deployment_role() {
  "$PY" - "$1" "$2" <<'PY'
import os
import sys

import yaml

apps_dir, fleet_dir = sys.argv[1:3]
FLEET_ROOT = "oci://ghcr.io/anywaye/charts/"

def classify(text):
    stripped = text.lstrip()
    if stripped.startswith("Business Source License 1.1") and \
            "Change Date:" in text and "Change License:" in text:
        return "runnable"
    lowered = text.lower()
    if "never part of" in lowered and "deployment substrate" in lowered:
        return "refused"
    if "runs on anywaye infrastructure" in lowered and \
            ("forked catalog" in lowered or "operated registry" in lowered):
        return "refused"
    return "unclassifiable"

def fleet_service(app_file):
    try:
        doc = yaml.safe_load(open(app_file, encoding="utf-8"))
    except yaml.YAMLError as e:
        return None, f"{os.path.basename(app_file)}: does not parse ({e})"
    if not isinstance(doc, dict):
        return None, f"{os.path.basename(app_file)}: not a mapping"
    repo = ((doc.get("spec") or {}).get("source") or {}).get("repoURL", "")
    if isinstance(repo, str) and repo.startswith(FLEET_ROOT):
        chart = repo[len(FLEET_ROOT):]
        if chart and "/" not in chart:
            return chart, None
    return None, None

refused = set()
for svc in sorted(os.listdir(fleet_dir)):
    lic = os.path.join(fleet_dir, svc, "LICENSE")
    if not os.path.isfile(lic):
        continue
    try:
        with open(lic, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        continue
    if classify(text) == "refused":
        refused.add(svc)

problems = []
notes = []
graded = []
for f in sorted(os.listdir(apps_dir)):
    if not f.endswith((".yaml", ".yml")):
        continue
    svc, err = fleet_service(os.path.join(apps_dir, f))
    if err:
        problems.append(err)
        continue
    if svc is None:
        continue
    manifest = os.path.join(fleet_dir, svc, "anywaye.yml")
    if not os.path.isfile(manifest):
        notes.append(f"{svc}: no sibling anywaye.yml under {fleet_dir} — not asserted")
        continue
    try:
        man = yaml.safe_load(open(manifest, encoding="utf-8"))
    except yaml.YAMLError as e:
        problems.append(f"{f}: the {svc} anywaye.yml does not parse ({e}) — an unreadable manifest is not a permission")
        continue
    deps = (man.get("dependencies") or []) if isinstance(man, dict) else []
    if not isinstance(deps, list):
        problems.append(f"{f}: the {svc} anywaye.yml dependencies is not a list — an unreadable manifest is not a permission")
        continue
    graded.append(svc)
    for dep in deps:
        if not isinstance(dep, dict):
            continue
        name = dep.get("name")
        if dep.get("required", True) and name in refused:
            problems.append(
                f"{f}: {svc} requires {name}, which its licence names Anywaye-operated — "
                "a service that needs the operated plane at runtime is operated-side, not box-run"
            )

if problems:
    print("; ".join(problems))
    sys.exit(1)
for note in notes:
    print(f"note: {note}")
print(f"deployment role: {len(graded)} manifest(s) graded ({', '.join(sorted(graded)) or 'none'}), "
      f"{len(refused)} licence-refused anchor(s) ({', '.join(sorted(refused)) or 'none'}), {len(notes)} noted")
PY
}

run 'no fleet Application requires an operated service at runtime' green \
  check_substrate_deployment_role "$MANIFESTS" "$ROOT/.."

fixture_apps_ledger="$WORK/apps-ledger-role"
rm -rf "$fixture_apps_ledger"
mkdir -p "$fixture_apps_ledger"
sed 's/courier/ledger/g' "$MANIFESTS/courier.yaml" >"$fixture_apps_ledger/ledger.yaml"
cat >"$fixture_fleet/ledger/anywaye.yml" <<'YAML'
name: ledger
description: A BSL service that requires the operated control plane.
language: go
core: ^0.2.0
dependencies:
  - name: box
    version: ^0.1.0
    required: true
repository:
  url: git@github.com:anywaye/ledger.git
  visibility: private
owner:
  team: ledger
  contact: ledger@anywaye.com
YAML
if grep -q 'repoURL: oci://ghcr.io/anywaye/charts/ledger' "$fixture_apps_ledger/ledger.yaml" && \
   grep -q 'name: box' "$fixture_fleet/ledger/anywaye.yml" && \
   grep -q 'never part of a customer' "$fixture_fleet/box/LICENSE"; then
  run 'control: a BSL service requiring an operated service fails the deployment-role check' red \
    check_substrate_deployment_role "$fixture_apps_ledger" "$fixture_fleet"
else
  fail 'control fixture: the ledger shape did not land' \
    'the fixture names no ledger chart, no box dependency or no refused anchor, so the control would prove nothing'
fi

OPERATED_PANTRY_ORIGIN="https://pantry.anywaye.com"
check_gateway_operated_pantry() {
  "$PY" - "$1" "$2" <<'PY'
import json
import os
import sys

import yaml

apps_flag, fleet_dir = sys.argv[1:3]
checkout = os.path.join(fleet_dir, "gateway")
values_path = os.path.join(checkout, "charts", "gateway", "values.yaml")
if not os.path.isfile(values_path):
    print(f"note: no sibling gateway checkout under {fleet_dir} — not asserted")
    print("route: gateway checkout absent, noted")
    sys.exit(0)
try:
    values = yaml.safe_load(open(values_path, encoding="utf-8"))
except yaml.YAMLError as e:
    print(f"gateway's chart values do not parse ({e})")
    sys.exit(1)
table_raw = ((values.get("env") or {}).get("ROUTE_TABLE")) if isinstance(values, dict) else None
if not table_raw:
    print("gateway's chart ships no env.ROUTE_TABLE — the pantry route's origin cannot be found")
    sys.exit(1)
try:
    table = json.loads(table_raw)
except (ValueError, TypeError) as e:
    print(f"gateway's ROUTE_TABLE is not JSON ({e})")
    sys.exit(1)
problems = []
for prefix in ("/v1/pantry", "/v1/pantry-writes"):
    entry = table.get(prefix)
    if not isinstance(entry, dict):
        problems.append(f"{prefix} is not a routed entry — the published pantry surface moved without its origin")
        continue
    base = entry.get("baseUrl", "")
    if base != "https://pantry.anywaye.com":
        problems.append(
            f"{prefix} names {base!r}, want the operated origin https://pantry.anywaye.com — "
            "an in-cluster pantry is the live 503 again"
        )
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("both pantry routes name the operated origin https://pantry.anywaye.com, from the one ROUTE_TABLE value")
PY
}

run 'gateway routes pantry at the operated origin' green \
  check_gateway_operated_pantry "$MANIFESTS" "$ROOT/.."

fixture_gw="$WORK/gateway-incluster"
rm -rf "$fixture_gw/gateway/charts/gateway"
mkdir -p "$fixture_gw/gateway/charts/gateway"
cat >"$fixture_gw/gateway/charts/gateway/values.yaml" <<'YAML'
env:
  ROUTE_TABLE: '{"/v1/pantry":{"baseUrl":"http://pantry:8080","public":true},"/v1/pantry-writes":{"baseUrl":"http://pantry:8080","principal":["sub"]}}'
YAML
if grep -q 'http://pantry:8080' "$fixture_gw/gateway/charts/gateway/values.yaml"; then
  run 'control: an in-cluster pantry ROUTE_TABLE fails the route check' red \
    check_gateway_operated_pantry "$MANIFESTS" "$fixture_gw"
else
  fail 'control fixture: the in-cluster ROUTE_TABLE did not land' \
    'the fixture names no in-cluster pantry, so the control would prove nothing'
fi

lc_kubeconfig="$WORK/lc-kubeconfig.yaml"
cat >"$lc_kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    server: https://127.0.0.1:6443
contexts:
- name: local
  context:
    cluster: local
    user: local
current-context: local
users:
- name: local
  user:
    token: fixture
EOF

lc_mock_kubectl() {
  if [ -n "${MOCK_ROOT:-}" ]; then
    printf '%s\n' "$*" >>"$MOCK_ROOT/kubectl-argv"
  fi
  local rest="$*"
  case "$rest" in
    *"get namespaces"*)
      printf 'NAME              STATUS   AGE\ndefault           Active   1m\n'
      return 0
      ;;
    *"get nodes --no-headers"*)
      if [ -n "${LC_NO_NODE:-}" ]; then
        return 0
      fi
      printf 'node-0   Ready   control-plane   1m   v1.35.5+k3s1\n'
      return 0
      ;;
    *apply*)
      printf 'namespace/cnpg-system serverside-applied\n'
      printf 'customresourcedefinition.apiextensions.k8s.io/clusters.postgresql.cnpg.io serverside-applied\n'
      return 0
      ;;
    *"get deployment"*)
      return 1
      ;;
  esac
  return 0
}

lc_cycle() {
  local name="$1" want="$2" installer="$3" kubeconfig="$4" no_node="${5:-}"
  local dir="$WORK/lc-$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "verify return:1\\n"\n'
    printf 'exit 0\n'
  } >"$dir/bin/openssl"
  chmod +x "$dir/bin/openssl"
  local out ec=0
  out="$(
    set +e
    (
      export MOCK_ROOT="$dir"
      export PATH="$dir/bin:$PATH"
      export KIT_SUBSTRATE_RECEIPT="$dir/receipt.json"
      export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing'
      export KIT_SUBSTRATE_ACME_EMAIL='dev@anywaye.test'
      export HEADLESS=1
      export DRY_RUN=0
      export LC_NO_NODE="$no_node"
      if [ -z "$kubeconfig" ]; then
        unset KIT_SUBSTRATE_KUBECONFIG
      else
        export KIT_SUBSTRATE_KUBECONFIG="$kubeconfig"
      fi
      . "$installer"
      kubectl() { lc_mock_kubectl "$@"; }
      curl() {
        printf '%s\n' "$*" >>"$MOCK_ROOT/curl-argv"
        printf '{}'
      }
      preflight
      install_k3s
    ) 2>"$dir/human" >"$dir/jsonl"
    echo "exit=$?"
  )"
  ec="${out##*exit=}"
  ec="${ec%%$'\n'*}"
  local argv curl_argv human
  argv="$(cat "$dir/kubectl-argv" 2>/dev/null || true)"
  curl_argv="$(cat "$dir/curl-argv" 2>/dev/null || true)"
  human="$(cat "$dir/human" 2>/dev/null || true)"

  if [ "$want" = green ]; then
    if [ "$ec" != 0 ]; then
      printf 'the cycle exited %s, want 0 — stdout: %s\n' "$ec" "$(head -3 "$dir/jsonl" 2>/dev/null | tr '\n' ' ')"
      return 1
    fi
    case "$argv" in
      *"get namespaces"*)
        ;;
      *)
        printf 'the cluster was never asked for its namespaces — the preflight answered on the host\n'
        return 1
        ;;
    esac
    case "$argv" in
      *"get nodes --no-headers"*)
        ;;
      *)
        printf 'step 1 never asked the cluster for a Node\n'
        return 1
        ;;
    esac
    case "$curl_argv" in
      *"get.k3s.io"*)
        printf 'the host k3s install was attempted against a supplied cluster: %s\n' "$curl_argv"
        return 1
        ;;
    esac
    case "$human" in
      *"already has a Node"*)
        ;;
      *)
        printf 'step 1 did not say the cluster already has a Node; human channel: %s\n' "$human"
        return 1
        ;;
    esac
    printf 'the supplied cycle asked the cluster, skipped step 1 on the cluster evidence, and fetched no host k3s'
    return 0
  fi
  case "$curl_argv" in
    *"get.k3s.io"*)
      printf 'a supplied cluster with no Node INSTALLED the host k3s instead of refusing\n'
      return 1
      ;;
  esac
  case "$argv" in
    *"get nodes --no-headers"*)
      ;;
    *)
      printf 'a supplied cluster with no Node was never asked — it cannot refuse on the cluster evidence it never read\n'
      return 1
      ;;
  esac
  printf 'the cluster with no Node was asked, and nothing installed the host k3s'
  return 0
}

run 'a supplied cluster: the preflight answers on the cluster and step 1 skips on the cluster evidence' green \
  lc_cycle supplied green "$fixture_sourced" "$lc_kubeconfig"

run 'a supplied cluster with no Node refuses naming the input, and installs no host k3s' green \
  lc_cycle no-node red "$fixture_sourced" "$lc_kubeconfig" NO_NODE

lc_unsets_the_input() {
  local dir="$WORK/lc-unset"
  rm -rf "$dir"
  mkdir -p "$dir"
  local out ec=0
  out="$(
    set +e
    (
      export MOCK_ROOT="$dir"
      export KIT_SUBSTRATE_RECEIPT="$dir/receipt.json"
      export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing'
      export KIT_SUBSTRATE_ACME_EMAIL='dev@anywaye.test'
      export HEADLESS=1
      unset KIT_SUBSTRATE_KUBECONFIG
      . "$fixture_sourced"
      kubectl() { lc_mock_kubectl "$@"; }
      preflight
    ) 2>"$dir/human" >"$dir/jsonl"
    echo "exit=$?"
  )"
  ec="${out##*exit=}"
  ec="${ec%%$'\n'*}"
  local human
  human="$(cat "$dir/human" 2>/dev/null || true)"
  if [ "$ec" = 0 ]; then
    printf 'the run did NOT refuse — the host preflight stopped deciding on this workstation\n'
    return 1
  fi
  case "$human" in
    *"must run as root"*)
      printf 'unset, the preflight still refuses on the host probe (exit %s): %s\n' "$ec" "$(printf '%s' "$human" | head -1)"
      return 0
      ;;
  esac
  printf 'it refused, but not on the host probe — the fresh-box path changed: %s\n' "$human"
  return 1
}
run 'RED control: with the input unset, this workstation still refuses on the host probe' green \
  lc_unsets_the_input

lc_stdout_is_jsonl() {
  local installer="$1" dir="$2"
  local out
  out="$(
    set +e
    (
      export MOCK_ROOT="$dir"
      export KIT_SUBSTRATE_RECEIPT="$dir/receipt.json"
      export KIT_SUBSTRATE_DATABASES='identity,gateway,courier,parlor,billing'
      export KIT_SUBSTRATE_ACME_EMAIL='dev@anywaye.test'
      export KIT_SUBSTRATE_KUBECONFIG="$3"
      export HEADLESS=1
      export DRY_RUN=0
      . "$installer"
      kubectl() { lc_mock_kubectl "$@"; }
      curl() { printf '{}'; }
      install_cert_manager
      install_cnpg
    ) 2>/dev/null
  )"
  printf '%s\n' "$out" >"$dir/jsonl"
  if [ ! -s "$dir/jsonl" ]; then
    printf 'stdout was empty — no events at all\n'
    return 1
  fi
  headless_jsonl_ok "$dir/jsonl"
}
lc_pollution_dir="$WORK/lc-pollution"
rm -rf "$lc_pollution_dir"
mkdir -p "$lc_pollution_dir"
run 'a headless run whose kubectl apply prints its own progress still emits one JSON object per line' green \
  lc_stdout_is_jsonl "$fixture_sourced" "$lc_pollution_dir" "$lc_kubeconfig"

lc_fixture_no_fd3="$WORK/lc-install-no-fd3.sh"
"$PY" - "$fixture_sourced" "$lc_fixture_no_fd3" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
out = []
drop_function = False
for ln in src.split("\n"):
    if ln.startswith("kit_substrate_open_jsonl_channel() {"):
        drop_function = True
    if drop_function:
        if ln == "}":
            drop_function = False
        continue
    stripped = re.sub(r"(?m)^\s*#.*$", "", ln)
    if "exec 3>&1" in stripped or "kit_substrate_open_jsonl_channel" in stripped:
        continue
    stripped = re.sub(r"\s*>&3\s*$", "", stripped)
    out.append(stripped)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
if grep -q '3>&1' "$lc_fixture_no_fd3" || grep -q '>&3' "$lc_fixture_no_fd3"; then
  fail 'control fixture: the saved descriptor is still there' \
    'the fixture still redirects through the saved descriptor, so the control would prove nothing'
else
  run 'control: without the saved descriptor, kubectl apply output reaches the JSONL stream' red \
    lc_stdout_is_jsonl "$lc_fixture_no_fd3" "$WORK/lc-pollution-control" "$lc_kubeconfig"
fi

check_no_remote_box() {
  "$PY" - "$1" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
code = re.sub(r"(?m)^\s*#.*$", "", src)
problems = []
for i, line in enumerate(code.splitlines(), 1):
    if re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", line):
        problems.append(f"line {i} carries an IP literal")
    if re.search(r"(?:^|[\s|&;])ssh\s", line):
        problems.append(f"line {i} reaches for ssh")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("no IP literal and no ssh — the local cycle only ever names the local cluster")
PY
}
run "the local cycle names no box address and dials no ssh" green \
  check_no_remote_box "$SUBSTRATE/local-cycle.sh"
lc_fixture_with_box="$WORK/local-cycle-with-box.sh"
sed 's|k3d cluster create|ssh root@203.0.113.9 k3d cluster create|' \
  "$SUBSTRATE/local-cycle.sh" >"$lc_fixture_with_box"
if grep -q 'ssh root@203.0.113.9' "$lc_fixture_with_box"; then
  run 'control: a local cycle that reaches for a remote box goes red' red \
    check_no_remote_box "$lc_fixture_with_box"
else
  fail 'control fixture: the ssh reach did not land' \
    'the fixture carries no ssh line, so the control would prove nothing'
fi

installer_has_no_k3d() {
  local code
  code="$("$PY" - "$1" <<'PY'
import re
import sys

print(re.sub(r"(?m)^\s*#.*$", "", open(sys.argv[1], encoding="utf-8").read()))
PY
)"
  case "$code" in
    *k3d*)
      printf 'the installer names k3d — a customer with their own Kubernetes has a kubeconfig and no k3d\n'
      return 1
      ;;
  esac
  printf 'the installer names no k3d; the developer entry does'
}
run 'the installer has no k3d dependency' green installer_has_no_k3d "$SUBSTRATE/install.sh"

DNS_SPLIT_HOST="dns-split-never-resolves.invalid"
DNS_BOTH_HOST="localhost"

check_dns_split_pending() {
  local script="$1" src="$WORK/dns-split-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(bash -c '
    . "$1"
    kit_substrate_host_resolves() { case "$1" in dns-split-never-resolves.invalid) return 0;; *) return 1;; esac; }
    kit_substrate_cluster_host_resolves() { case "$1" in dns-split-never-resolves.invalid) return 1;; *) return 0;; esac; }
    export KIT_SUBSTRATE_APP_BASE_URL="https://dns-split-never-resolves.invalid"
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export MANIFEST_DIR="/tmp/dns-split-manifests"
    mkdir -p "$MANIFEST_DIR"
    cat > "$MANIFEST_DIR/test.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: test}
spec:
  source:
    helm: {values: | env: {}}
  destination: {server: https://kubernetes.default.svc, namespace: test}
YAML
    kit_substrate_compute_readiness
    case "$READINESS_TLS_PENDING" in *dns-split-never-resolves.invalid*) ;; *) printf "pending does not contain split host\n"; exit 1;; esac
    case "$READINESS_DNS_SPLIT" in *dns-split-never-resolves.invalid*) ;; *) printf "split does not contain host\n"; exit 1;; esac
    out=$(kit_substrate_readiness_preflight 2>&1)
    case "$out" in *"RESOLVES ON NODE BUT NOT THROUGH CLUSTER DNS"*) ;; *) printf "missing split sentence\n%s\n" "$out"; exit 1;; esac
    case "$out" in *"CoreDNS at 10.43.0.10:53"*) ;; *) printf "missing CoreDNS path\n%s\n" "$out"; exit 1;; esac
    case "$out" in *"dns-split-never-resolves.invalid"*) ;; *) printf "missing host\n"; exit 1;; esac
    printf "split pending with own sentence and CoreDNS path\n"
  ' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  case "$out" in *split\ pending*) ;; *) printf '%s\n' "$out"; return 1;; esac
  printf 'host that resolves on node but not through cluster DNS is reported as pending with its own sentence\n'
}

check_dns_both_resolve() {
  local script="$1" src="$WORK/dns-both-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(bash -c '
    . "$1"
    kit_substrate_host_resolves() { return 0; }
    kit_substrate_cluster_host_resolves() { return 0; }
    export KIT_SUBSTRATE_APP_BASE_URL="https://both-resolve.example.com"
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export MANIFEST_DIR="/tmp/dns-both-manifests"
    mkdir -p "$MANIFEST_DIR"
    cat > "$MANIFEST_DIR/test.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: test}
spec:
  source:
    helm: {values: | env: {}}
  destination: {server: https://kubernetes.default.svc, namespace: test}
YAML
    kit_substrate_compute_readiness
    [ -z "$READINESS_TLS_PENDING" ] || { printf "pending not empty\n"; exit 1; }
    [ -z "$READINESS_DNS_SPLIT" ] || { printf "split not empty\n"; exit 1; }
    out=$(kit_substrate_readiness_preflight 2>&1)
    case "$out" in *"every intended host resolves"*) ;; *) printf "missing every-host-resolves\n%s\n" "$out"; exit 1;; esac
    case "$out" in *"cluster DNS"*"agrees"*) ;; *) printf "missing cluster agrees\n%s\n" "$out"; exit 1;; esac
    printf "both paths resolve => reported as resolving\n"
  ' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  printf 'host that resolves on both paths is reported as resolving\n'
}

check_dns_opposite_split() {
  local script="$1" src="$WORK/dns-opp-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(bash -c '
    . "$1"
    kit_substrate_host_resolves() { case "$1" in opp-split.example.com) return 1;; *) return 1;; esac; }
    kit_substrate_cluster_host_resolves() { case "$1" in opp-split.example.com) return 0;; *) return 1;; esac; }
    export KIT_SUBSTRATE_APP_BASE_URL="https://opp-split.example.com"
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export MANIFEST_DIR="/tmp/dns-opp-manifests"
    mkdir -p "$MANIFEST_DIR"
    cat > "$MANIFEST_DIR/test.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: test}
spec:
  source:
    helm: {values: | env: {}}
  destination: {server: https://kubernetes.default.svc, namespace: test}
YAML
    kit_substrate_compute_readiness
    case "$READINESS_TLS_PENDING" in *opp-split.example.com*) ;; *) printf "pending missing\n"; exit 1;; esac
    out=$(kit_substrate_readiness_preflight 2>&1)
    case "$out" in *"RESOLVES THROUGH CLUSTER DNS BUT NOT ON NODE"*) ;; *) printf "missing opposite split sentence\n%s\n" "$out"; exit 1;; esac
    printf "opposite split pending\n"
  ' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  printf 'host that resolves through cluster DNS but not on node is reported as pending\n'
}

check_resolver_config() {
  local script="$1" src="$WORK/resolver-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  local conf_no="$WORK/resolver-no-public.conf"
  rm -f "$conf_no"
  bash -c '
    . "$1"
    export KIT_SUBSTRATE_APP_BASE_URL=""
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export KIT_SUBSTRATE_RESOLVED_CONF="$2"
    export MANIFEST_DIR="/tmp/resolver-empty"
    mkdir -p "$MANIFEST_DIR"
    kit_substrate_ensure_public_resolver
  ' bash "$src" "$conf_no" 2>&1
  if [ -f "$conf_no" ]; then printf 'resolver written when no public host\n'; return 1; fi
  local conf_yes="$WORK/resolver-yes.conf"
  rm -f "$conf_yes"
  bash -c '
    . "$1"
    export KIT_SUBSTRATE_APP_BASE_URL="https://public.example.com"
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export KIT_SUBSTRATE_RESOLVED_CONF="$2"
    export MANIFEST_DIR="/tmp/resolver-public"
    mkdir -p "$MANIFEST_DIR"
    cat > "$MANIFEST_DIR/test.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: test}
spec:
  source: {helm: {values: | env: {}}}
  destination: {server: https://kubernetes.default.svc, namespace: test}
YAML
    export DRY_RUN=0
    kit_substrate_ensure_public_resolver >"$3" 2>&1
  ' bash "$src" "$conf_yes" "$WORK/resolver-out.txt" 2>&1
  if [ ! -f "$conf_yes" ]; then printf 'resolver not written when serving public names\n'; cat "$WORK/resolver-out.txt"; return 1; fi
  if ! grep -q "DNS=1.1.1.1 8.8.8.8" "$conf_yes"; then printf 'resolver content wrong\n'; cat "$conf_yes"; return 1; fi
  if ! grep -q "FallbackDNS=1.0.0.1 8.8.4.4" "$conf_yes"; then printf 'resolver fallback wrong\n'; cat "$conf_yes"; return 1; fi
  if ! grep -q "wrote public resolver" "$WORK/resolver-out.txt"; then printf 'resolver write not reported\n'; cat "$WORK/resolver-out.txt"; return 1; fi
  bash -c '
    . "$1"
    export KIT_SUBSTRATE_APP_BASE_URL="https://public.example.com"
    export KIT_SUBSTRATE_RESOLVED_CONF="$2"
    export MANIFEST_DIR="/tmp/resolver-public"
    export DRY_RUN=0
    kit_substrate_ensure_public_resolver >"$3" 2>&1
  ' bash "$src" "$conf_yes" "$WORK/resolver-out2.txt" 2>&1
  if ! grep -q "already configured" "$WORK/resolver-out2.txt"; then printf 'resolver second run not idempotent\n'; cat "$WORK/resolver-out2.txt"; return 1; fi
  printf 'resolver written only when serving public names, content correct, visible and idempotent\n'
}

check_node_only_red() {
  local script="$1" src="$WORK/node-only-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  local fixture="$WORK/install-node-only.sh"
  "$PY" - "$src" "$fixture" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
text = open(src, encoding="utf-8").read()
old = '''kit_substrate_compute_readiness() {
  READINESS_TLS_PENDING=""
  READINESS_DNS_SPLIT=""
  READINESS_DNS_STATUS=""
  local h all pending="" split="" status=""
  all="$(kit_substrate_intended_hosts "$MANIFEST_DIR")"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    local node_ok=0 cluster_ok=0
    if kit_substrate_host_resolves "$h"; then node_ok=1; fi
    if kit_substrate_cluster_host_resolves "$h"; then cluster_ok=1; fi
    status="${status}${h}	${node_ok}	${cluster_ok}
"
    if [ "$node_ok" -eq 1 ] && [ "$cluster_ok" -eq 1 ]; then
      continue
    fi
    pending="${pending}${h}
"
    if [ "$node_ok" -ne "$cluster_ok" ]; then
      split="${split}${h}
"
    fi
  done <<EOF
$all
EOF
  READINESS_TLS_PENDING="$pending"
  READINESS_DNS_SPLIT="$split"
  READINESS_DNS_STATUS="$status"
}'''
new = '''kit_substrate_compute_readiness() {
  READINESS_TLS_PENDING=""
  local h all pending=""
  all="$(kit_substrate_intended_hosts)"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if ! kit_substrate_host_resolves "$h"; then
      pending="${pending}${h}
"
    fi
  done <<EOF
$all
EOF
  READINESS_TLS_PENDING="$pending"
}'''
if old not in text:
    sys.exit(f"could not find compute_readiness to replace")
text = text.replace(old, new)
open(dst, "w", encoding="utf-8").write(text)
PY
  if [ $? -ne 0 ]; then printf 'fixture build failed\n'; return 1; fi
  bash -n "$fixture" || { printf 'node-only fixture does not parse\n'; return 1; }
  local out ec=0
  out="$(bash -c '
    . "$1"
    kit_substrate_host_resolves() { case "$1" in dns-split-never-resolves.invalid) return 0;; *) return 1;; esac; }
    kit_substrate_cluster_host_resolves() { case "$1" in dns-split-never-resolves.invalid) return 1;; *) return 0;; esac; }
    export KIT_SUBSTRATE_APP_BASE_URL="https://dns-split-never-resolves.invalid"
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export MANIFEST_DIR="/tmp/dns-split-manifests"
    kit_substrate_compute_readiness
    if [ -n "$READINESS_TLS_PENDING" ]; then printf "node-only pending not empty: [%s]\n" "$READINESS_TLS_PENDING"; exit 1; fi
    out=$(kit_substrate_readiness_preflight 2>&1)
    case "$out" in *"RESOLVES ON NODE BUT NOT THROUGH CLUSTER DNS"*) printf "node-only still prints split\n"; exit 1;; esac
    case "$out" in *"every intended host resolves"*) ;; *) printf "missing resolves\n%s\n" "$out"; exit 1;; esac
    printf "node-only reports resolving for split\n"
  ' bash "$fixture" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  printf 'node-only preflight reports split as resolving (proves discrimination)\n'
}

run 'a host that resolves on node but not through cluster DNS is reported as pending with its own sentence' green check_dns_split_pending "$SUBSTRATE/install.sh"
run 'a host that resolves on both paths is reported as resolving' green check_dns_both_resolve "$SUBSTRATE/install.sh"
run 'a host that resolves through cluster DNS but not on node is reported as pending' green check_dns_opposite_split "$SUBSTRATE/install.sh"
run 'the public resolver is written only when serving public names, content correct and visible' green check_resolver_config "$SUBSTRATE/install.sh"
run 'control: node-only preflight reports split as resolving' green check_node_only_red "$SUBSTRATE/install.sh"

check_dns_agreement() {
  local script="$1" src="$WORK/dns-agree-sourced.sh"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  local out ec=0
  out="$(bash -c '
    . "$1"
    kit_substrate_host_resolves() { return 1; }
    kit_substrate_cluster_host_resolves() { return 0; }
    export KIT_SUBSTRATE_APP_BASE_URL="https://agree.invalid"
    export KIT_SUBSTRATE_IDENTITY_OIDC_ISSUER=""
    export MANIFEST_DIR="/tmp/dns-agree-manifests"
    mkdir -p "$MANIFEST_DIR"
    cat > "$MANIFEST_DIR/test.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: test}
spec:
  source:
    helm: {values: | env: {}}
  destination: {server: https://kubernetes.default.svc, namespace: test}
YAML
    kit_substrate_compute_readiness
    [ -n "$READINESS_TLS_PENDING" ] || { printf "should be pending\n"; exit 1; }
    out=$(kit_substrate_readiness_preflight 2>&1)
    case "$out" in *"every intended host resolves"*) printf "should not say every resolves\n%s\n" "$out"; exit 1;; esac
    printf "agreement check holds\n"
  ' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf '%s\n' "$out"; return 1; }
  printf 'agreement: a host that resolves only on one path is not reported as resolving\n'
}
run 'control: a fixture where CoreDNS answers and node does not is not reported as resolving' green check_dns_agreement "$SUBSTRATE/install.sh"


trust_fakebin="$WORK/trust-fakebin"
mkdir -p "$trust_fakebin"
cat >"$trust_fakebin/openssl" <<'TRUST_OPENSSL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_OPENSSL_LOG:-/dev/null}"
host=""; prev=""
for a in "$@"; do
  case "$prev" in
    -connect) host="${a%%:*}" ;;
    -servername) host="$a" ;;
  esac
  prev="$a"
done
if [ "$host" = "${FAKE_OPENSSL_UNREACHABLE_HOST:-__none__}" ]; then
  printf 'connect:errno=61\n' >&2
  printf '80DEC2EE01000000:error:8000003D:system library:BIO_connect:Connection refused:crypto/bio/bio_sock2.c:183:calling connect()\n' >&2
  exit 1
fi
if [ "$host" = "${FAKE_OPENSSL_FAIL_HOST:-__none__}" ] && [ ! -f "${FAKE_TRUST_MARKER:-/nonexistent}" ]; then
  printf 'depth=2 CN = Test Root\nverify error:num=20:unable to get local issuer certificate\n' >&2
  printf 'Certificate chain\n 0 s:CN = %s\n' "$host" >&2
  printf 'Verify return code: 20 (unable to get local issuer certificate)\n'
  exit 1
fi
printf 'CONNECTED(00000003)\nVerify return code: 0 (ok)\n'
exit 0
TRUST_OPENSSL
chmod +x "$trust_fakebin/openssl"

cat >"$trust_fakebin/apt-get" <<'TRUST_APT'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"${FAKE_APT_LOG:-/dev/null}"
if [ -n "${FAKE_APT_FAIL_ON:-}" ] && [ "$1" = "${FAKE_APT_FAIL_ON}" ]; then
  exit 100
fi
exit 0
TRUST_APT
chmod +x "$trust_fakebin/apt-get"

cat >"$trust_fakebin/update-ca-certificates" <<'TRUST_UPD'
#!/usr/bin/env bash
printf 'update-ca-certificates %s\n' "$*" >>"${FAKE_APT_LOG:-/dev/null}"
if [ -n "${FAKE_TRUST_MARKER:-}" ]; then
  : >"$FAKE_TRUST_MARKER"
fi
exit 0
TRUST_UPD
chmod +x "$trust_fakebin/update-ca-certificates"

cat >"$trust_fakebin/kubectl" <<'TRUST_KUBECTL'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"${FAKE_KUBECTL_LOG:-/dev/null}"
exit 0
TRUST_KUBECTL
chmod +x "$trust_fakebin/kubectl"

cat >"$trust_fakebin/curl" <<'TRUST_CURL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${FAKE_CURL_LOG:-/dev/null}"
exit 0
TRUST_CURL
chmod +x "$trust_fakebin/curl"

trust_empty_manifests="$WORK/trust-empty-manifests"
mkdir -p "$trust_empty_manifests"
: >"$WORK/trust-kubeconfig"

trust_run() {
  local src="$1" body="$2" child="$WORK/trust-child.sh" ec=0 out
  sed '/^main "$@"/d' "$src" >"$child.sourced"
  {
    echo 'set -euo pipefail'
    printf 'export PATH="%s:$PATH"\n' "$trust_fakebin"
    printf 'export KIT_SUBSTRATE_KUBECONFIG="%s"\n' "$WORK/trust-kubeconfig"
    printf 'export MANIFEST_DIR="%s"\n' "$trust_empty_manifests"
    printf 'export KIT_SUBSTRATE_BOX_URL="%s"\n' "$TRUST_BOX_URL"
    printf 'export KIT_SUBSTRATE_REGISTRY_URL="%s"\n' "$TRUST_REGISTRY_URL"
    printf 'export DRY_RUN="%s"\n' "${TRUST_DRY_RUN:-0}"
    printf 'export HEADLESS="%s"\n' "${TRUST_HEADLESS:-0}"
    printf 'export FAKE_OPENSSL_LOG="%s"\n' "$WORK/trust-child-openssl.log"
    printf 'export FAKE_APT_LOG="%s"\n' "$WORK/trust-child-apt.log"
    printf 'export FAKE_KUBECTL_LOG="%s"\n' "$WORK/trust-child-kubectl.log"
    printf 'export FAKE_CURL_LOG="%s"\n' "$WORK/trust-child-curl.log"
    printf '%s\n' "$TRUST_CHILD_ARGS"
    printf '. "%s"\n' "$child.sourced"
    printf '%s\n' "$body"
  } >"$child"
  out="$(bash "$child" 2>&1)" || ec=$?
  printf '%s\n%s' "$ec" "$out"
}

trust_reset_logs() {
  : >"$WORK/trust-child-openssl.log"
  : >"$WORK/trust-child-apt.log"
  : >"$WORK/trust-child-kubectl.log"
  : >"$WORK/trust-child-curl.log"
}

TRUST_BOX_URL="https://box.svc.anywaye.test"
TRUST_REGISTRY_URL="https://registry.svc.anywaye.test"
TRUST_CHILD_ARGS=""
TRUST_DRY_RUN=0
TRUST_HEADLESS=0

check_trust_verified() {
  local script="$1" src="$WORK/trust-verified-src.sh" out ec=0
  local olog="$WORK/trust-verified-openssl.log" alog="$WORK/trust-verified-apt.log"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  : >"$olog"; : >"$alog"
  out="$(env PATH="$trust_fakebin:$PATH" \
    FAKE_OPENSSL_LOG="$olog" FAKE_APT_LOG="$alog" \
    KIT_SUBSTRATE_BOX_URL="https://box.svc.anywaye.test" \
    KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test" \
    DRY_RUN=0 HEADLESS=0 \
    bash -c '. "$1"; kit_substrate_trust_preflight' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'a verifiable box was refused (exit %s):\n%s\n' "$ec" "$out"; return 1; }
  case "$out" in
    *'TLS chain verified against the system trust store: https://box.svc.anywaye.test'*) ;;
    *) printf 'the control-plane origin is not reported verified\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *'TLS chain verified against the system trust store: https://registry.svc.anywaye.test'*) ;;
    *) printf 'the registry origin is not reported verified\n%s\n' "$out"; return 1 ;;
  esac
  [ -s "$olog" ] || { printf 'openssl was never invoked — the check is not a check\n'; return 1; }
  case "$(cat "$olog")" in
    *"-connect box.svc.anywaye.test:443 -servername box.svc.anywaye.test"*) ;;
    *) printf 'openssl was not asked to verify the control-plane origin\n%s\n' "$(cat "$olog")"; return 1 ;;
  esac
  case "$(cat "$olog")" in
    *"-connect registry.svc.anywaye.test:443 -servername registry.svc.anywaye.test"*) ;;
    *) printf 'openssl was not asked to verify the registry origin\n%s\n' "$(cat "$olog")"; return 1 ;;
  esac
  [ ! -s "$alog" ] || { printf 'the remedy ran on a box that verified\n'; return 1; }
  printf 'a verifiable box is reported verified, both origins openssl-checked, the remedy untouched\n'
}

check_trust_remedied() {
  local script="$1" src="$WORK/trust-remedied-src.sh" out ec=0
  local olog="$WORK/trust-remedied-openssl.log" alog="$WORK/trust-remedied-apt.log" marker="$WORK/trust-remedied.marker"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  rm -f "$marker"; : >"$olog"; : >"$alog"
  out="$(env PATH="$trust_fakebin:$PATH" \
    FAKE_OPENSSL_LOG="$olog" FAKE_APT_LOG="$alog" \
    FAKE_OPENSSL_FAIL_HOST="box.svc.anywaye.test" FAKE_TRUST_MARKER="$marker" \
    KIT_SUBSTRATE_BOX_URL="https://box.svc.anywaye.test" \
    KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test" \
    DRY_RUN=0 HEADLESS=0 \
    bash -c '. "$1"; kit_substrate_trust_preflight' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'a box fixable by a refresh was refused (exit %s):\n%s\n' "$ec" "$out"; return 1; }
  case "$out" in
    *'TLS chain NOT verifiable: https://box.svc.anywaye.test'*) ;;
    *) printf 'the failing chain was not reported\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *'trust store refreshed: https://box.svc.anywaye.test now verifies'*) ;;
    *) printf 'the refresh was not reported as fixing the chain\n%s\n' "$out"; return 1 ;;
  esac
  [ "$(grep -c 'box.svc.anywaye.test' "$olog")" -ge 2 ] || {
    printf 'the failing origin was verified only %s time(s) — the remedy was not re-checked\n' \
      "$(grep -c 'box.svc.anywaye.test' "$olog")"
    return 1
  }
  [ -s "$alog" ] || { printf 'the remedy was never attempted\n'; return 1; }
  [ -f "$marker" ] || { printf 'the fake trust store was never rebuilt\n'; return 1; }
  printf 'a failing chain is refreshed, re-checked, and reported fixed\n'
}

check_trust_refused() {
  local script="$1" src="$WORK/trust-refused-src.sh" out ec=0
  local olog="$WORK/trust-refused-openssl.log" alog="$WORK/trust-refused-apt.log"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  : >"$olog"; : >"$alog"
  out="$(env PATH="$trust_fakebin:$PATH" \
    FAKE_OPENSSL_LOG="$olog" FAKE_APT_LOG="$alog" \
    FAKE_OPENSSL_FAIL_HOST="box.svc.anywaye.test" \
    KIT_SUBSTRATE_BOX_URL="https://box.svc.anywaye.test" \
    KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test" \
    DRY_RUN=0 HEADLESS=0 \
    bash -c '. "$1"; kit_substrate_trust_preflight' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -ne 0 ] || { printf 'an unverifiable chain did not refuse\n%s\n' "$out"; return 1; }
  case "$out" in
    *'https://box.svc.anywaye.test'*) ;;
    *) printf 'the refusal does not name the failing origin\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *'unable to get local issuer certificate'*) ;;
    *) printf 'the refusal does not carry the verification error\n%s\n' "$out"; return 1 ;;
  esac
  [ -s "$alog" ] || { printf 'the remedy was not attempted before refusing\n'; return 1; }
  case "$(cat "$olog")" in
    *registry.svc.anywaye.test*) printf 'the run continued to the registry origin after refusing\n'; return 1 ;;
  esac
  printf 'an unfixable chain refuses, naming the origin and the verification error\n'
}

check_trust_unreachable() {
  local script="$1" src="$WORK/trust-unreachable-src.sh" out ec=0
  local olog="$WORK/trust-unreachable-openssl.log" alog="$WORK/trust-unreachable-apt.log"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  : >"$olog"; : >"$alog"
  out="$(env PATH="$trust_fakebin:$PATH" \
    FAKE_OPENSSL_LOG="$olog" FAKE_APT_LOG="$alog" \
    FAKE_OPENSSL_UNREACHABLE_HOST="box.svc.anywaye.test" \
    KIT_SUBSTRATE_BOX_URL="https://box.svc.anywaye.test" \
    KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test" \
    DRY_RUN=0 HEADLESS=0 \
    bash -c '. "$1"; kit_substrate_trust_preflight' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -ne 0 ] || { printf 'an origin that never answered did not refuse\n%s\n' "$out"; return 1; }
  case "$out" in
    *'https://box.svc.anywaye.test'*) ;;
    *) printf 'the refusal does not name the failing origin\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *'did not answer'*'reachability'*) ;;
    *) printf 'the refusal does not say this is reachability rather than the trust store\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *'trust store is stale'*)
      printf 'the refusal blames the trust store for a network failure\n%s\n' "$out"
      return 1
      ;;
  esac
  [ ! -s "$alog" ] || { printf 'the remedy ran on an origin that never answered a handshake\n'; return 1; }
  printf 'an unreachable origin refuses as reachability, and the remedy is not run\n'
}

check_trust_remedy_failure() {
  local script="$1" src="$WORK/trust-remedyfail-src.sh" out ec=0
  local olog="$WORK/trust-remedyfail-openssl.log" alog="$WORK/trust-remedyfail-apt.log"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  : >"$olog"; : >"$alog"
  out="$(env PATH="$trust_fakebin:$PATH" \
    FAKE_OPENSSL_LOG="$olog" FAKE_APT_LOG="$alog" FAKE_APT_FAIL_ON="install" \
    FAKE_OPENSSL_FAIL_HOST="box.svc.anywaye.test" \
    KIT_SUBSTRATE_BOX_URL="https://box.svc.anywaye.test" \
    KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test" \
    DRY_RUN=0 HEADLESS=0 \
    bash -c '. "$1"; kit_substrate_trust_preflight' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -ne 0 ] || { printf 'a failed remedy and a still-broken chain did not refuse\n%s\n' "$out"; return 1; }
  case "$out" in
    *'apt-get install -y --reinstall ca-certificates exited 100'*) ;;
    *) printf 'the refusal does not name the remedy that failed\n%s\n' "$out"; return 1 ;;
  esac
  printf 'a remedy that failed is named in the refusal\n'
}

check_trust_preflight() {
  local script="$1" mode="$2" out ec=0
  local olog="$WORK/trust-child-openssl.log" clog="$WORK/trust-child-curl.log"
  TRUST_CHILD_ARGS=""
  TRUST_DRY_RUN=0
  trust_reset_logs
  case "$mode" in
    wired)
      out="$(trust_run "$script" 'preflight')"
      ec="${out%%$'\n'*}"
      out="${out#*$'\n'}"
      [ "$ec" -eq 0 ] || { printf 'preflight refused a verifiable box (exit %s):\n%s\n' "$ec" "$out"; return 1; }
      case "$(cat "$olog")" in
        *"-connect box.svc.anywaye.test:443"*) ;;
        *) printf 'preflight did not open the control-plane origin\n%s\n' "$(cat "$olog")"; return 1 ;;
      esac
      case "$(cat "$clog")" in
        *'https://ghcr.io/v2/'*) ;;
        *) printf 'preflight did not reach the ghcr.io probe, so the trust check stopped it\n%s\n' "$(cat "$clog")"; return 1 ;;
      esac
      printf 'preflight verifies both origins and continues to the ghcr.io probe\n'
      ;;
    stops)
      TRUST_CHILD_ARGS='export FAKE_OPENSSL_FAIL_HOST="box.svc.anywaye.test"'
      out="$(trust_run "$script" 'preflight')"
      ec="${out%%$'\n'*}"
      out="${out#*$'\n'}"
      [ "$ec" -ne 0 ] || { printf 'preflight continued past an unverifiable origin\n%s\n' "$out"; return 1; }
      case "$out" in
        *'cannot verify the TLS chain of https://box.svc.anywaye.test'*) ;;
        *) printf 'preflight did not refuse naming the origin\n%s\n' "$out"; return 1 ;;
      esac
      case "$(cat "$clog")" in
        *'https://ghcr.io/v2/'*)
          printf 'the ghcr.io probe ran after the trust refusal — the install went past it\n'
          return 1
          ;;
      esac
      printf 'preflight stops at an unverifiable origin, before the ghcr.io probe\n'
      ;;
    *) printf 'unknown mode %s\n' "$mode"; return 1 ;;
  esac
}

check_trust_dry_run() {
  local script="$1" src="$WORK/trust-dryrun-src.sh" out ec=0
  local olog="$WORK/trust-dryrun-openssl.log" alog="$WORK/trust-dryrun-apt.log"
  sed '/^main "$@"/d' "$script" >"$src"
  bash -n "$src" || { printf 'sourced copy does not parse\n'; return 1; }
  : >"$olog"; : >"$alog"
  out="$(env PATH="$trust_fakebin:$PATH" \
    FAKE_OPENSSL_LOG="$olog" FAKE_APT_LOG="$alog" \
    FAKE_OPENSSL_FAIL_HOST="box.svc.anywaye.test" \
    KIT_SUBSTRATE_BOX_URL="https://box.svc.anywaye.test" \
    KIT_SUBSTRATE_REGISTRY_URL="https://registry.svc.anywaye.test" \
    DRY_RUN=1 HEADLESS=0 \
    bash -c '. "$1"; kit_substrate_trust_preflight' bash "$src" 2>&1)" || ec=$?
  [ "$ec" -eq 0 ] || { printf 'DRY_RUN refused (exit %s):\n%s\n' "$ec" "$out"; return 1; }
  case "$out" in
    *'DRY_RUN:'*'KIT_SUBSTRATE_BOX_URL'*'KIT_SUBSTRATE_REGISTRY_URL'*) ;;
    *) printf 'the plan does not name the trust check\n%s\n' "$out"; return 1 ;;
  esac
  case "$out" in
    *'refreshing ca-certificates'*) ;;
    *) printf 'the plan does not say it would refresh the trust store\n%s\n' "$out"; return 1 ;;
  esac
  [ ! -s "$olog" ] || { printf 'DRY_RUN called openssl\n'; return 1; }
  [ ! -s "$alog" ] || { printf 'DRY_RUN ran the package manager\n'; return 1; }
  printf 'DRY_RUN plans the trust check, runs neither the check nor the remedy\n'
}

run 'a box whose TLS chain verifies is reported verified (exit 0)' green check_trust_verified "$SUBSTRATE/install.sh"
run 'a failing TLS chain is refreshed, re-checked, and reported fixed' green check_trust_remedied "$SUBSTRATE/install.sh"
run 'an unfixable TLS chain refuses, naming the origin and the verification error' green check_trust_refused "$SUBSTRATE/install.sh"
run 'an origin that never answers a handshake refuses as reachability, and the remedy is not run' green check_trust_unreachable "$SUBSTRATE/install.sh"
run 'a remedy that itself failed is named in the refusal' green check_trust_remedy_failure "$SUBSTRATE/install.sh"
run "preflight verifies the control plane's TLS chain, and continues when it verifies" green check_trust_preflight "$SUBSTRATE/install.sh" wired
run 'preflight stops at an unverifiable origin, before anything is created' green check_trust_preflight "$SUBSTRATE/install.sh" stops
run 'DRY_RUN plans the trust check and runs neither the check nor the remedy' green check_trust_dry_run "$SUBSTRATE/install.sh"

trust_stripped="$WORK/trust-stripped.sh"
sed -e '/trust-preflight BEGIN/,/trust-preflight END/d' "$SUBSTRATE/install.sh" >"$trust_stripped"
if grep -q 'kit_substrate_trust_preflight()' "$trust_stripped" || ! bash -n "$trust_stripped"; then
  fail 'control fixture: the trust-preflight block was not removed' \
    'the sed did not strip the block — this control would prove nothing'
else
  run 'control: with the trust-preflight block gone there is no verification (red)' red \
    check_trust_verified "$trust_stripped"
fi

if "$PY" - "$SUBSTRATE/install.sh" "$WORK/trust-nodryrun.sh" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
out = open(sys.argv[2], "w", encoding="utf-8")
lines = src.split("\n")
start = None
for i, ln in enumerate(lines):
    if ln.startswith("kit_substrate_trust_preflight() {"):
        start = i
        break
if start is None:
    sys.exit("control fixture: kit_substrate_trust_preflight was not found")
end = None
for i in range(start, len(lines)):
    if lines[i] == "}":
        end = i
        break
if end is None:
    sys.exit("control fixture: kit_substrate_trust_preflight has no closing brace")
body = lines[start:end]
gstart = None
for i, ln in enumerate(body):
    if ln == '  if [ "$DRY_RUN" -eq 1 ]; then':
        gstart = i
        break
if gstart is None:
    sys.exit("control fixture: the DRY_RUN guard was not found inside the function")
gend = None
for i in range(gstart, len(body)):
    if body[i] == "  fi":
        gend = i
        break
if gend is None:
    sys.exit("control fixture: the DRY_RUN guard has no closing fi")
span = body[gstart : gend + 1]
if len(span) != 4:
    sys.exit(
        "control fixture: the DRY_RUN guard is %d lines, not the 4 this edit removes"
        % len(span)
    )
if not any("step.plan" in ln for ln in span):
    sys.exit("control fixture: the guard does not plan the check")
if not any("return 0" in ln for ln in span):
    sys.exit("control fixture: the guard does not return before the check")
kept = body[:gstart] + body[gend + 1 :]
out.write("\n".join(lines[:start] + kept + lines[end:]))
PY
then
  :
else
  echo 'control fixture: the DRY_RUN-guard delete did not apply, so the control proves nothing' >&2
fi
if [ -s "$WORK/trust-nodryrun.sh" ] && bash -n "$WORK/trust-nodryrun.sh"; then
  run 'control: a plan that runs the openssl check and the remedy goes red' red \
    check_trust_dry_run "$WORK/trust-nodryrun.sh"
else
  fail 'control fixture: the DRY_RUN-guard delete produced nothing that parses' \
    'the fixture is empty or unparseable, so the control would prove nothing'
fi

if "$PY" - "$SUBSTRATE/install.sh" "$WORK/trust-noremedy.sh" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("kit_substrate_refresh_trust_store() {")
end = src.index("\n}\n", start) + 3
body = src[start:end]
if "apt-get install -y --reinstall ca-certificates" not in body:
    sys.exit("control fixture: the apt-get reinstall is not inside the remedy")
if "update-ca-certificates --fresh" not in body:
    sys.exit("control fixture: update-ca-certificates --fresh is not inside the remedy")
stripped = "kit_substrate_refresh_trust_store() {\n  TRUST_REFRESH_NOTE=\"\"\n  return 1\n}\n"
src = src[:start] + stripped + src[end:]
for call in ("kit_substrate_refresh_trust_store", "kit_substrate_tls_verify"):
    if call not in src:
        sys.exit("control fixture: the edit removed %s from the tree" % call)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
then
  :
else
  echo 'control fixture: the remedy delete did not apply, so the control proves nothing' >&2
fi
if [ -s "$WORK/trust-noremedy.sh" ] && bash -n "$WORK/trust-noremedy.sh"; then
  run 'control: with the remedy gone, a refreshable box refuses (red)' red \
    check_trust_remedied "$WORK/trust-noremedy.sh"
else
  fail 'control fixture: the remedy delete produced nothing that parses' \
    'the fixture is empty or unparseable, so the control would prove nothing'
fi

if "$PY" - "$SUBSTRATE/install.sh" "$WORK/trust-nodiscriminator.sh" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
needle = 'if [ "$TLS_VERIFY_REACHED" != "yes" ]; then'
if src.count(needle) != 1:
    sys.exit(
        "control fixture: the reachability guard appears %d time(s), not once"
        % src.count(needle)
    )
src = src.replace(needle, 'if [ "$TLS_VERIFY_REACHED" != "no" ]; then', 1)
if "TLS_VERIFY_REACHED" not in src:
    sys.exit("control fixture: the edit removed TLS_VERIFY_REACHED entirely")
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
then
  :
else
  echo 'control fixture: the discriminator edit did not apply, so the control proves nothing' >&2
fi
if [ -s "$WORK/trust-nodiscriminator.sh" ] && bash -n "$WORK/trust-nodiscriminator.sh"; then
  run 'control: a copy that cannot see an unreachable origin runs the remedy anyway (red)' red \
    check_trust_unreachable "$WORK/trust-nodiscriminator.sh"
else
  fail 'control fixture: the discriminator edit produced nothing that parses' \
    'the fixture is empty or unparseable, so the control would prove nothing'
fi

if "$PY" - "$SUBSTRATE/install.sh" "$WORK/trust-unwired.sh" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
needle = "  kit_substrate_trust_preflight # trust-preflight\n"
if src.count(needle) != 2:
    sys.exit(
        "control fixture: the preflight call site appears %d time(s), not twice (DRY_RUN plan and live check)"
        % src.count(needle)
    )
src = src.replace(needle, "")
start = src.index("preflight() {")
end = src.index("\n}\n", start)
if "kit_substrate_trust_preflight" in src[start:end]:
    sys.exit("control fixture: preflight still calls the trust preflight")
if "kit_substrate_trust_preflight() {" not in src:
    sys.exit("control fixture: the edit removed the definition, not the call")
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
then
  :
else
  echo 'control fixture: the call-site delete did not apply, so the control proves nothing' >&2
fi
if [ -s "$WORK/trust-unwired.sh" ] && bash -n "$WORK/trust-unwired.sh"; then
  run 'control: with the calls removed from preflight, no origin is verified (red)' red \
    check_trust_preflight "$WORK/trust-unwired.sh" wired
else
  fail 'control fixture: the call-site delete produced nothing that parses' \
    'the fixture is empty or unparseable, so the control would prove nothing'
fi

printf -- '-- substrate_test: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: %d passed, %d failed, %d skipped\n' "$passes" "$failures" "$skips"
