#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/templates/kamal/deploy.yml.erb"
README="$ROOT/templates/kamal/README.md"

pass=0
fail=0

ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf 'FAIL %s\n' "$1"
  shift
  [ "$#" -eq 0 ] || printf '     %s\n' "$@"
  fail=$((fail + 1))
}

section() {
  awk -v heading="$2" '
    $0 == heading { p = 1; next }
    p { print }
  ' "$1"
}

hc_path="$(awk '/^  healthcheck:/{p=1} p && /^    path:/{print $2; exit}' "$TEMPLATE")"
if [ "$hc_path" = "/readyz" ]; then
  ok 'deploy.yml.erb  (the default healthcheck path is /readyz, which every adopting service serves)'
else
  no 'deploy.yml.erb  (the default healthcheck path is /readyz, which every adopting service serves)' \
    "the template defaults to '${hc_path:-<none>}'. /up is served by no service that adopts this
     template — identity, courier, gateway, parlor, darkroom and muse all serve /readyz — and
     kamal gates the rollout on this path, so a fresh copy deploys a container the proxy can
     never accept. billing serves /up and does not use this template."
fi

adapting="$(section "$README" '## Adapting per language')"
keys="$(printf '%s\n' "$adapting" | grep -oE '`[a-z][a-z0-9_]*`' | tr -d '`' | sort -u)"
template_keys="$(sed 's/[[:space:]]*#.*$//' "$TEMPLATE")"
missing=""
for key in $keys; do
  if ! printf '%s\n' "$template_keys" | grep -qE "(^|[^a-z0-9_])${key}:"; then
    missing="$missing $key"
  fi
done
if [ -z "$missing" ]; then
  ok 'README  (every key the "Adapting per language" section tells a service to set exists in the template)'
else
  no 'README  (every key the "Adapting per language" section tells a service to set exists in the template)' \
    "the README names key(s)$missing as settable in deploy.yml.erb, but the template has no such
     key. Kamal 2 refuses unknown key: migrate outright — measured — so following the README
     produces a config kamal rejects. Migrations run from .kamal/hooks/pre-deploy, which is not
     a key in the file at all."
fi

adopting="$(section "$README" '## Adopting this')"
if printf '%s\n' "$adopting" | grep -qE 'drill\.sh.*bin/drill|bin/drill.*drill\.sh'; then
  ok 'README  (the adoption steps copy drill.sh to bin/drill)'
else
  no 'README  (the adoption steps copy drill.sh to bin/drill)' \
    'the "Adopting this" section never tells a service to copy drill.sh to bin/drill, so a
     service that follows the steps exactly ends up with backups configured and no drill —
     the fleet-wide state this packet exists to end.'
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'FAIL: kamal_agreement_test — %d of %d case(s) failed.\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'PASS: kamal_agreement_test — %d case(s), the template and its README agree.\n' "$pass"
