#!/usr/bin/env bash
# How `KIT_POSTGRES_DATABASES` is split into tenants.
#
# ONE shared Postgres cluster with a database and a role PER SERVICE is the whole
# point of this fleet's database topology, and this file is the only check in kit
# that asks what that means for the SECOND name in the list. Every other check —
# including the harness rule that insists a harness declares its tenant, and the
# live stack test that asserts a tenant was really provisioned — exercises the
# single-tenant case, which is the case that had always worked.
#
# The defect this exists for was measured, live, on billing's stack:
#
#   $ KIT_POSTGRES_DATABASES="billing neighbour" bin/dev up
#   postgres-1 | [cluster] provisioning billingneighbour
#   postgres-1 | [cluster] done: 1 service database(s), one role each, PUBLIC holds CONNECT on none of them
#
# One database named after both services, and a green stack. The parse stripped
# whitespace before validating, so the two names arrived at `require_identifier`
# already fused into one legal identifier — and a legal identifier is precisely
# what the validator is built to accept.
#
# WHAT MAKES THIS A TEST AND NOT A COMMENT
# ---------------------------------------
# It runs the real `templates/compose/postgres/initdb/10-cluster.sh` and reads the
# real parse out of it. It does not re-implement the split in a way that could
# agree with a broken script, and it does not need a container: `psql` is a
# recording stub, so this costs milliseconds where the live measurement took a
# full `bin/dev up`. The thing under test is the parsing in the init script, so
# the init script is what runs — the stub replaces the DATABASE, not the LOGIC.
#
# The cases are chosen so that a fix which simply stopped trimming whitespace
# would fail here: "billing, neighbour" must still provision two tenants, because
# a space after a comma is how people actually write these lists and refusing it
# would be a regression in the other direction.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
script="$root/templates/compose/postgres/initdb/10-cluster.sh"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

[ -r "$script" ] || { fail "multi-tenant split: $script is not readable"; exit 1; }

# Run the real init script against a stubbed `psql`, and report what it did.
#
# `provision` is the stub: the init script calls `admin()`, which calls `psql`,
# and everything that matters here happens BEFORE the first psql call — the split,
# the validation, and the refusal. What comes back is one line per provisioned
# service, plus whatever the script itself printed, so a refusal is observable.
#
# `POSTGRES_HOST_AUTH_METHOD` and friends are set because the script refuses an
# unset `KIT_POSTGRES_DATABASES` before it reaches anything else; passing them
# through the environment keeps the harness from re-implementing that contract.
provision() { provision_locale "${LC_ALL:-C}" "$1"; }

# The same, with the locale FORCED rather than inherited.
#
# This parameter exists because of a bug that inherited the locale would have
# hidden from this entire file: `require_identifier`'s bracket ranges follow
# collation, so under `en_US.UTF-8` an uppercase name passed a check whose error
# message said it could not. A harness that ran the script in whatever locale the
# shell happened to have — which on this machine is `en_US.UTF-8` — would have
# reported that bug as correct behaviour.
provision_locale() {
  local loc="$1" value="$2" sandbox
  sandbox="$(mktemp -d)"

  cat >"$sandbox/psql" <<'STUB'
#!/usr/bin/env bash
# Records that a statement was issued; the arguments are not this test's subject.
printf 'psql\n'
exit 0
STUB
  chmod +x "$sandbox/psql"

  # `create database`/`create role` run through the stub, and the script's own
  # `note` output goes to stdout, so the tenant names are greppable. PATH is
  # prefixed rather than the script edited: this test must run the shipped file.
  # LC_ALL is in the environment the SCRIPT sees, which is the point — the fix is
  # the script exporting it for itself, and a test that set it here instead would
  # pass against a script that had no fix at all.
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

# The tenant names the script announced, in order, one per line.
tenants() { grep -oE 'provisioning [a-z_][a-z0-9_]*' | sed 's/provisioning //'; }

# --- the defect: two names, no comma --------------------------------------
out="$(provision 'billing neighbour')"; rc=$?
if [ $rc -eq 0 ]; then
  fail "two tenants separated by a space are refused (the script exited 0 and provisioned: $(tenants <<<"$out" | paste -sd, -))"
  printf '       A space instead of a comma fuses the names into ONE database,\n'
  printf '       and the stack reported itself healthy while doing it.\n'
elif ! grep -q 'REFUSING' <<<"$out"; then
  fail "two tenants separated by a space are refused (exited $rc but never said REFUSING)"
  printf '%s\n' "$out" | sed 's/^/       /'
else
  # The refusal must not have provisioned the fused name on its way out.
  if grep -q 'billingneighbour' <<<"$out"; then
    fail "the refusal did not create the fused database 'billingneighbour'"
    printf '%s\n' "$out" | grep -E 'provisioning|REFUSING' | sed 's/^/       /'
  else
    pass "two tenants separated by a space are refused, and nothing was provisioned"
  fi
fi

# --- the ordinary cases must still work -----------------------------------
# Each of these is a shape somebody has actually written into a `.env`. A fix
# that made the validator refuse all whitespace would pass the test above and
# break every one of these, which is why they are here and not implied.
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

# --- an empty entry is skipped, not an error ------------------------------
# "billing,,courier" and a trailing comma are both things people type. Neither
# may become a database named "", and neither may abort the cluster.
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

# --- and the identifier rule still holds on a real entry ------------------
# The whitespace fix must not have displaced the check it sits beside: a name
# that is illegal for a different reason is still refused, by the same function,
# naming the same thing.
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

# --- AND IT HOLDS IN EVERY LOCALE, which is the half that was broken -------
#
# `require_identifier` is built out of shell bracket ranges, and those are
# collation-dependent: under `en_US.UTF-8` — the default on the machine this
# fleet is developed on — `[!a-z]` does not match an uppercase letter, so the
# rule enforced roughly half of what its own message claimed. `Billing` was
# provisioned, and because Postgres folds unquoted identifiers to lower case it
# silently shared one database with any `billing` beside it.
#
# These run the real script with the locale FORCED, including the one that used
# to defeat it. A check that only ran under the developer's own shell would have
# passed throughout, which is the same mistake as testing one tenant.
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

# And the check is not merely refusing more — it is not refusing everything. A
# locale fix that broke the valid names would turn this file green for the wrong
# reason, so one legal name is run under each locale too.
for loc in C en_US.UTF-8 en_GB.UTF-8 POSIX; do
  out="$(provision_locale "$loc" 'billing')"; rc=$?
  got="$(tenants <<<"$out" | paste -sd, -)"
  if [ $rc -eq 0 ] && [ "$got" = "billing" ]; then
    pass "under LC_ALL=$loc, a legal tenant name is still provisioned"
  else
    fail "under LC_ALL=$loc, a legal tenant name is still provisioned (exited $rc, got [$got])"
  fi
done

# --- and an UNSET list is still the loud failure it was -------------------
# `:?` on KIT_POSTGRES_DATABASES is the original defect this file's whole
# neighbourhood was written around: an unset variable used to leave you with a
# cluster that looked fine and no database on it.
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
