#!/usr/bin/env bash
# tests/kamal_agreement_test.sh — the template and its README must agree, and the
# template's defaults must be paths the fleet actually serves.
#
#   bash tests/kamal_agreement_test.sh
#
# WHY THIS EXISTS
#
#   kit-23 asked for a README/template agreement test and it never landed
#   (`git log --oneline | grep -i unusable` is empty). Two defects prove the gap
#   is load-bearing, and both are invisible to a parse:
#
#     1. `proxy.healthcheck.path: /up` — a path NO cafaye service serves. All
#        six services that adopt this template (`identity`, `courier`,
#        `gateway`, `parlor`, `darkroom`, `muse`) serve `/healthz` and `/readyz`;
#        none serves `/up`. `billing` does, and does not use this template.
#        Kamal gates the rollout on that path, so a fresh copy of the template
#        deploys a container the proxy can never accept — a deploy that cannot
#        succeed. `identity` and `courier` each hand-patched their own copy to
#        `/readyz`; the template still shipped the defect.
#
#     2. The README told services to "set the `migrate` command in
#        `deploy.yml.erb`". The template has no `migrate` key, and Kamal 2.12.0
#        refuses the config outright with `unknown key: migrate` — measured
#        against courier's copy. Migrations run from `.kamal/hooks/pre-deploy`,
#        which is not a key in the file at all. Following the README produced a
#        config kamal rejects.
#
#   Both are agreement defects: the README describes a template that is not the
#   template, and the template defaults to a path the fleet does not serve. A
#   parse check is green on both. This test reads the two files and asserts the
#   agreement, the way `tests/kamal_test.sh` runs the real binaries.
#
# WHAT IS AND IS NOT PROVEN HERE
#   Proven: the default healthcheck is a path the fleet serves; every key the
#   README tells a service to set exists in the template; the adoption steps
#   produce `bin/drill`.
#   NOT proven: that a real deploy works — that needs a host, credentials and
#   SSH, and is `tests/deploy_test.sh`'s claim on the local-daemon path. The
#   claim this file makes is the narrow one, and it is the one a template can
#   silently lose.
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

# section <file> <heading> — the body of one `## ` heading, stopped at the next
# one. Bounded on both sides: an unbounded awk to EOF would let a defect in one
# section be excused by text in a later one, which is the false green this file
# exists to refuse.
section() {
  awk -v heading="$2" '
    $0 == heading { p = 1; next }
    p && /^## / { exit }
    p { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# 1. The template's default healthcheck path is a path the fleet serves.
#
# The measured fleet fact, 2026-10-07: all six services that adopt this
# template serve `/readyz` (readiness) and `/healthz` (liveness). None serves
# `/up`. `billing` serves `/up` — Rails' boot check — and does not use this
# template. So the default must be `/readyz`: the readiness path every adopting
# service serves, and the path the template's own comment already claims ("A
# READINESS endpoint, not a liveness one").
#
# The red proof is one line: change `/readyz` back to `/up` and this goes red.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. Every key the README tells a service to set in the template exists in the
#    template.
#
# The `migrate:` case: the README's "Adapting per language" section said "set
# the `migrate` command in `deploy.yml.erb` to yours". The template has no
# `migrate` key, and Kamal 2.12.0 refuses the config outright with
# `unknown key: migrate` — measured against courier's copy. Migrations run
# from `.kamal/hooks/pre-deploy`, which is not a key in the file at all.
#
# So: extract every YAML-key-shaped backticked token from that section and
# assert the template contains it as a key. `postgres` passes (it is the
# accessory name); `migrate` fails. After the fix the section points at
# `.kamal/hooks/pre-deploy`, which is a path and not key-shaped, so it is
# correctly excluded.
#
# Comments are stripped before the key search, because a key mentioned in a
# comment is not a key in the file — the same rule the rest of this repository
# applies to `run:` bodies.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3. The adoption steps produce `bin/drill`.
#
# A fleet-wide search finds `bin/drill` in ZERO repositories: the backup path
# is configured and never proven to restore, which is the one thing a backup
# is for. The README's adoption steps are the only thing that tells a service
# to copy `drill.sh`, and step 1 named the two .erb files but not the drill —
# so a service that followed the steps exactly ended up with backups
# configured and no way to prove them.
#
# So: the "Adopting this" section must name the drill copy. The red proof is
# deleting the `drill.sh` -> `bin/drill` mention from step 1.
# ---------------------------------------------------------------------------
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
