#!/usr/bin/env bash

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="$root/templates/compose/postgres/initdb/10-cluster.sh"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

[ -r "$script" ] || { fail "multi-tenant split: $script is not readable"; exit 1; }

provision() { provision_locale "${LC_ALL:-C}" "$1"; }

provision_locale() {
  local loc="$1" value="$2" sandbox
  sandbox="$(mktemp -d)"

  cat >"$sandbox/psql" <<'STUB'
#!/usr/bin/env bash
printf 'psql\n'
exit 0
STUB
  chmod +x "$sandbox/psql"

  env LC_ALL="$loc" LANG="$loc" PATH="$sandbox:$PATH" \
    POSTGRES_USER=anywaye \
    POSTGRES_DB=anywaye_platform \
    POSTGRES_PASSWORD=anywaye \
    KIT_POSTGRES_DATABASES="$value" \
    bash "$script" 2>&1
  local rc=$?

  rm -rf "$sandbox"
  return $rc
}

tenants() { grep -oE 'provisioning [a-z_][a-z0-9_]*' | sed 's/provisioning //'; }

out="$(provision 'billing neighbour')"; rc=$?
if [ $rc -eq 0 ]; then
  fail "two tenants separated by a space are refused (the script exited 0 and provisioned: $(tenants <<<"$out" | paste -sd, -))"
  printf '       A space instead of a comma fuses the names into ONE database,\n'
  printf '       and the stack reported itself healthy while doing it.\n'
elif ! grep -q 'REFUSING' <<<"$out"; then
  fail "two tenants separated by a space are refused (exited $rc but never said REFUSING)"
  printf '%s\n' "$out" | sed 's/^/       /'
else
  if grep -q 'billingneighbour' <<<"$out"; then
    fail "the refusal did not create the fused database 'billingneighbour'"
    printf '%s\n' "$out" | grep -E 'provisioning|REFUSING' | sed 's/^/       /'
  else
    pass "two tenants separated by a space are refused, and nothing was provisioned"
  fi
fi

while IFS='|' read -r label value want; do
  [ -n "$label" ] || continue
  out="$(provision "$value")"; rc=$?
  got="$(tenants <<<"$out" | paste -sd, -)"
  if [ $rc -ne 0 ]; then
    fail "$label (exited $rc: $(grep -m1 'REFUSING' <<<"$out"))"
  elif [ "$got" != "$want" ]; then
    fail "$label — provisioned [$got], expected [$want]"
  else
    pass "$label"
  fi
done <<'CASES'
one tenant, bare|billing|billing
two tenants, comma-separated|billing,courier|billing,courier
two tenants, space AFTER the comma|billing, courier|billing,courier
two tenants, spaces either side of the comma|billing , courier|billing,courier
three tenants, mixed spacing|billing, courier ,identity|billing,courier,identity
CASES

out="$(provision 'billing,,courier')"; rc=$?
got="$(tenants <<<"$out" | paste -sd, -)"
if [ $rc -eq 0 ] && [ "$got" = "billing,courier" ]; then
  pass "an empty entry between two commas is skipped rather than fatal"
else
  fail "an empty entry between two commas is skipped (exited $rc, provisioned [$got])"
fi

out="$(provision 'billing,')"; rc=$?
got="$(tenants <<<"$out" | paste -sd, -)"
if [ $rc -eq 0 ] && [ "$got" = "billing" ]; then
  pass "a trailing comma is skipped rather than fatal"
else
  fail "a trailing comma is skipped (exited $rc, provisioned [$got])"
fi

out="$(provision 'Billing')"; rc=$?
if [ $rc -ne 0 ] && grep -q 'REFUSING' <<<"$out"; then
  pass "a capitalised tenant name is still refused by require_identifier"
else
  fail "a capitalised tenant name is still refused (exited $rc: $out)"
fi

out="$(provision 'billing;drop')"; rc=$?
if [ $rc -ne 0 ] && grep -q 'REFUSING' <<<"$out"; then
  pass "a tenant name carrying a statement separator is still refused"
else
  fail "a tenant name carrying a statement separator is still refused (exited $rc: $out)"
fi

for loc in C en_US.UTF-8 en_GB.UTF-8 POSIX; do
  for name in Billing BILLING 'cafayé'; do
    out="$(provision_locale "$loc" "$name")"; rc=$?
    if [ $rc -ne 0 ] && grep -q 'REFUSING' <<<"$out"; then
      pass "under LC_ALL=$loc, '$name' is refused"
    else
      fail "under LC_ALL=$loc, '$name' is refused (exited $rc: $out)"
    fi
  done
done

for loc in C en_US.UTF-8 en_GB.UTF-8 POSIX; do
  out="$(provision_locale "$loc" 'billing')"; rc=$?
  got="$(tenants <<<"$out" | paste -sd, -)"
  if [ $rc -eq 0 ] && [ "$got" = "billing" ]; then
    pass "under LC_ALL=$loc, a legal tenant name is still provisioned"
  else
    fail "under LC_ALL=$loc, a legal tenant name is still provisioned (exited $rc, got [$got])"
  fi
done

out="$(env PATH="$PATH" POSTGRES_USER=anywaye POSTGRES_DB=anywaye_platform bash "$script" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && grep -q 'KIT_POSTGRES_DATABASES' <<<"$out"; then
  pass "an unset KIT_POSTGRES_DATABASES is still a loud failure"
else
  fail "an unset KIT_POSTGRES_DATABASES is still a loud failure (exited $rc)"
fi

if [ "$failures" -eq 0 ]; then
  printf '\nPASS: every multi-tenant split check passed.\n'
  exit 0
fi
printf '\nFAIL: %d multi-tenant split check(s) failed.\n' "$failures"
exit 1
