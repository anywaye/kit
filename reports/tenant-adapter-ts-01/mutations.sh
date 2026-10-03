#!/usr/bin/env bash
#
# Six cases against `subject-audit.sh`, the measurement that decides whether a
# TypeScript cross-tenant adapter is even DEFINED. A control that is GREEN, then
# every breakage RED naming the assertion that caught it, then each reverted and
# GREEN again.
#
#   bash reports/tenant-adapter-ts-01/mutations.sh
#
# WHY THIS RECIPE EXISTS, AND WHY IT MUTATES A COPY OF THE FLEET
#
#   `reports/tenant-adapter-go-01/mutations.sh` breaks identity's own query layer,
#   in a COPY under the harness's work directory, because the assertion under
#   test is about source the service owns. This recipe's subject is the fleet
#   itself, and the fleet is not this repository's to break — so it builds a
#   scratch fleet root out of the real services' package.json and sources, with
#   node_modules pruned, and breaks THAT. The control is additionally run against
#   the REAL fleet, read-only, so the numbers the audit reports are the fleet's
#   and not a fixture's.
#
#   node_modules is pruned rather than excluded-after-the-fact for a reason that
#   is not tidiness: `grep -r` followed by `grep -v node_modules` still WALKS
#   node_modules, and the first draft of `subject-audit.sh` exceeded its own time
#   bound before it reached the fourth service. `src_list` prunes in `find`.
#
# WHAT THE AUDIT ASSERTS, AND WHY THE FIXTURE CASE IS A CASE
#
#   The audit's whole claim is an ABSENCE — no TypeScript service holds a
#   database — and an absence is the easiest kind of claim to satisfy by accident.
#   A green audit proves nothing unless the thing it would have gone red on can
#   actually make it go red, which is what B1/B2/B3 are for. B4 is the other
#   half: `site` really does ship a `.sql`, under `e2e/`, and it is a
#   hand-written fixture for IDENTITY's migration rather than site's own schema.
#   Counting it would be the same category of error as reading `guard` as a Go
#   service, so the audit excludes it — and an exclusion with no control is an
#   exclusion nobody has tested. B4 plants a second fixture and requires the audit
#   to STAY GREEN, which is the only way to show the exclusion is discriminating
#   rather than blanket.
#
#   B5 is the one worth the most. It deletes an ASSERTION rather than breaking the
#   fleet: the migrations check is removed from a copy of the audit and B3's
#   mutation is re-applied. If the audit goes green there, the check B3 was
#   resting on was not load-bearing and B3 proved nothing. A check that cannot see
#   the defect it is written for is worse than no check, because it reports green.
#
# EVERY ANCHOR IS COUNTED BEFORE IT IS BELIEVED
#
#   `edit` refuses an anchor that does not appear EXACTLY once and prints the
#   count, rather than reporting the remaining cases green over a substrate it no
#   longer understands. B6 is that refusal exercised on purpose: it points an
#   anchor at text that is not there and requires the recipe to STOP.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/reports/tenant-adapter-ts-01"
AUDIT="$OUT/subject-audit.sh"

# The real fleet, for the control only. Never written to.
REAL_FLEET="${KIT_FLEET_ROOT:-$(cd "$ROOT/.." && pwd)}"

controls=0
breakages=0
observed_red=0
observed_green=0
failures=0

say() { printf '%s\n' "$*"; }

# `contains` — a shell `case` over a variable already in memory, never
# `printf … | grep -q`. kit has been bitten twice: `grep -q` closes the pipe, the
# writer dies of SIGPIPE, and `pipefail` promotes 141, so the verdict flips on
# the SIZE of the output rather than on its content.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# first_line_with — the literal line carrying a substring, kept rather than
# paraphrased. "the audit caught it" is a claim about the recipe; this is a
# receipt.
first_line_with() {
  local text="$1" needle="$2" line
  while IFS= read -r line; do
    case "$line" in
      *"$needle"*) printf '%s' "$line"; return 0 ;;
    esac
  done <<EOF
$text
EOF
  return 1
}

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || {
  say "mutations.sh: python3 not on PATH. Exiting 2: the recipe cannot be applied, and a recipe that did not apply proves nothing."
  exit 2
}
[ -r "$AUDIT" ] || {
  say "mutations.sh: $AUDIT is missing. Exiting 2."
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-ts-audit-recipe.XXXXXX")" || {
  say "mutations.sh: could not create a scratch directory. Exiting 2."
  exit 2
}
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# edit <file> <from> <to> — a textual mutation that FAILS LOUDLY if the anchor is
# absent or ambiguous. The count is printed because "anchor appears 3 times" is
# the message a reader needs and "recipe is stale" is not.
edit() {
  "$PYTHON" - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path, encoding="utf-8").read()
n = body.count(old)
if n != 1:
    sys.stderr.write(
        f"anchor appears {n} times in {path}, expected exactly 1:\n{old!r}\n"
    )
    sys.exit(1)
open(path, "w", encoding="utf-8").write(body.replace(old, new, 1))
PY
}

# --------------------------------------------------------------------------
# THE SCRATCH FLEET. The real TS services, sources and manifests only.
# --------------------------------------------------------------------------
build_scratch_fleet() {
  local dst="$WORK/fleet" name
  mkdir -p "$dst" || return 1
  for name in cafaye-ts docs guard parlor site; do
    [ -d "$REAL_FLEET/$name" ] || continue
    ( cd "$REAL_FLEET/$name" && tar -cf - --exclude='./.git' --exclude='./node_modules' \
        --exclude='./.next' --exclude='./dist' . ) | ( cd "$dst" && mkdir -p "$name" && cd "$name" && tar -xf - ) || return 1
  done
  [ -f "$dst/parlor/package.json" ] || return 1
  return 0
}

SCRATCH=""
build_scratch_fleet || {
  say "mutations.sh: could not build the scratch fleet under $WORK. Exiting 2."
  exit 2
}
SCRATCH="$WORK/fleet"
SUBJECT="parlor"

# run_audit <fleet root> <audit script> — exit status in AUDIT_CODE, output in
# AUDIT_OUT. Never through a pipe: kit's own rule, and the reason is a SIGPIPE
# bug that flipped a verdict on output SIZE rather than content.
run_audit() {
  AUDIT_OUT="$(KIT_FLEET_ROOT="$1" bash "$2" 2>&1)"
  AUDIT_CODE=$?
}

# expect_red <label> <needle> — the breakage must go red AND the output must
# contain the needle naming the assertion that caught it. Both halves: a red that
# does not name its assertion is a red some OTHER defect produced, which is the
# "a green control two checks could satisfy proves neither" rule pointed the other
# way.
expect_red() {
  local label="$1" needle="$2"
  if [ "$AUDIT_CODE" -eq 0 ]; then
    say "  $label: FAIL — the audit stayed GREEN."
    failures=$(( failures + 1 ))
    return 1
  fi
  if ! contains "$AUDIT_OUT" "$needle"; then
    say "  $label: FAIL — red, but NOT via \"$needle\"."
    first_line_with "$AUDIT_OUT" "RESULT:" | sed 's/^/      /'
    failures=$(( failures + 1 ))
    return 1
  fi
  observed_red=$(( observed_red + 1 ))
  say "  $label: RED, caught by \"$needle\""
  return 0
}

expect_green() {
  local label="$1"
  if [ "$AUDIT_CODE" -ne 0 ]; then
    say "  $label: FAIL — the audit went red on an UNMUTATED tree."
    first_line_with "$AUDIT_OUT" "RESULT:" | sed 's/^/      /'
    failures=$(( failures + 1 ))
    return 1
  fi
  observed_green=$(( observed_green + 1 ))
  say "  $label: GREEN"
  return 0
}

say "recipe:   $0"
say "audit:    $AUDIT"
say "real fleet (control only, read-only): $REAL_FLEET"
say "scratch fleet (every breakage):       $SCRATCH"
say ""

# --------------------------------------------------------------------------
# CONTROL. Two of them: the real fleet, and the scratch fleet built from it.
# A control that only ran against a fixture would be evidence about the fixture.
# --------------------------------------------------------------------------
say "CONTROL"
controls=$(( controls + 1 ))
run_audit "$REAL_FLEET" "$AUDIT"
expect_green "real fleet: no TypeScript service holds a database" || true
if contains "$AUDIT_OUT" "RESULT: NO TypeScript service in this fleet holds a database."; then
  say "      and it said so in the words the finding rests on"
else
  say "      FAIL — green, but not with the RESULT line the finding rests on."
  failures=$(( failures + 1 ))
fi

controls=$(( controls + 1 ))
run_audit "$SCRATCH" "$AUDIT"
expect_green "scratch fleet: identical verdict before any mutation" || true
say ""

# --------------------------------------------------------------------------
# B1 — a DECLARED driver. Reported, and sufficient: a service that ships the
# driver has crossed from "no query layer" to "a query layer nobody has called",
# and the adapter becomes something a packet can be written about.
# --------------------------------------------------------------------------
say "B1  a TypeScript service DECLARES a postgres driver nothing imports"
breakages=$(( breakages + 1 ))
P="$SCRATCH/$SUBJECT/package.json"
cp "$P" "$WORK/package.json.bak"
"$PYTHON" - "$P" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("dependencies", {})["pg"] = "^8.11.0"
json.dump(d, open(p, "w"), indent=2)
PY
run_audit "$SCRATCH" "$AUDIT"
# A declared-but-unimported driver is NOT a query layer, so it must not be
# reported as one — it gets its own verdict and its own needle, because
# "eligible for an adapter" and "declares a driver nothing uses" are two
# different findings and a red that does not say which is not a receipt.
expect_red "B1" "DECLARES a db driver that nothing imports"
cp "$WORK/package.json.bak" "$P"
run_audit "$SCRATCH" "$AUDIT"
expect_green "B1 reverted"
say ""

# --------------------------------------------------------------------------
# B2 — an IMPORTED driver. The load-bearing signal, and the one the finding rests
# on: a declared driver is scaffolding, an imported one is a query layer.
# --------------------------------------------------------------------------
say "B2  a TypeScript service IMPORTS an ORM driver"
breakages=$(( breakages + 1 ))
IMPORTER="$SCRATCH/$SUBJECT/src/kit_probe_import.ts"
cat >"$IMPORTER" <<'TS'
import { eq } from "drizzle-orm";

export const scope = (accountId: string) => eq((globalThis as never as { accountId: string }).accountId, accountId);
TS
run_audit "$SCRATCH" "$AUDIT"
expect_red "B2" "IMPORTS a db driver   : 1"
rm -f "$IMPORTER"
run_audit "$SCRATCH" "$AUDIT"
expect_green "B2 reverted"
say ""

# --------------------------------------------------------------------------
# B3 — MIGRATIONS. The signal `adapter_migrate` would have nothing to apply
# without. This is the case that most directly un-defines the adapter.
# --------------------------------------------------------------------------
say "B3  a TypeScript service ships its OWN .sql migration"
breakages=$(( breakages + 1 ))
mkdir -p "$SCRATCH/$SUBJECT/src/db/migrations"
printf 'create table accounts (id text primary key, account_id text not null);\n' \
  >"$SCRATCH/$SUBJECT/src/db/migrations/0001_init.sql"
run_audit "$SCRATCH" "$AUDIT"
expect_red "B3" "MIGRATES (.sql own)   : 1"
rm -rf "$SCRATCH/$SUBJECT/src/db"
run_audit "$SCRATCH" "$AUDIT"
expect_green "B3 reverted"
say ""

# --------------------------------------------------------------------------
# B4 — a FIXTURE is not a migration, and this is the only case that must STAY
# GREEN. `site` really ships one .sql under e2e/, for IDENTITY's migration. An
# exclusion with no control is an exclusion nobody has tested.
# --------------------------------------------------------------------------
say "B4  a TypeScript service ships a .sql FIXTURE for another service"
breakages=$(( breakages + 1 ))
mkdir -p "$SCRATCH/$SUBJECT/e2e/postgres-initdb"
printf -- '-- a fixture for identity, not %s own schema\ncreate role if not exists identity_app login;\n' \
  "$SUBJECT" >"$SCRATCH/$SUBJECT/e2e/postgres-initdb/10-identity-app.sql"
run_audit "$SCRATCH" "$AUDIT"
expect_green "B4 stayed green — the fixture exclusion discriminates"
if contains "$AUDIT_OUT" "MIGRATES (.sql own)   : 0"; then
  say "      and it reported 0 own migrations rather than 1"
else
  say "      FAIL — green, but it did not report the exclusion it made."
  failures=$(( failures + 1 ))
fi
rm -rf "$SCRATCH/$SUBJECT/e2e/postgres-initdb"
run_audit "$SCRATCH" "$AUDIT"
expect_green "B4 reverted"
say ""

# --------------------------------------------------------------------------
# B5 — DELETE AN ASSERTION, not the fleet. This is the case worth the most.
#
# The migrations check is removed from a COPY of the audit, B3's mutation is
# re-applied, and the audit is required to go GREEN. If it does, the check B3
# rested on was not load-bearing and B3 proved nothing at all.
# --------------------------------------------------------------------------
say "B5  the migrations ASSERTION is deleted — does B3 stop being caught?"
breakages=$(( breakages + 1 ))
MUTANT="$WORK/audit-no-migrations.sh"
cp "$AUDIT" "$MUTANT"
if ! edit "$MUTANT" \
  '  n_migrations="$(count_lines "$migrations")"' \
  '  n_migrations=0  # ASSERTION DELETED'; then
  say "  B5: FAIL — could not delete the assertion; the anchor moved."
  failures=$(( failures + 1 ))
  say ""
else
  say "  deleted: n_migrations -> 0, in $MUTANT"
  mkdir -p "$SCRATCH/$SUBJECT/src/db/migrations"
  printf 'create table accounts (id text primary key, account_id text not null);\n' \
    >"$SCRATCH/$SUBJECT/src/db/migrations/0001_init.sql"
  run_audit "$SCRATCH" "$MUTANT"
  if [ "$AUDIT_CODE" -eq 0 ]; then
    say "  B5: GREEN WITH THE ASSERTION DELETED — and that is the point."
    say "       B3's breakage is NO LONGER CAUGHT, which is what proves B3's check"
    say "       was the thing catching it rather than the audit's exit status."
    observed_green=$(( observed_green + 1 ))
  else
    say "  B5: FAIL — the breakage was STILL caught without the assertion, so B3"
    say "       was resting on something else and its check is not load-bearing."
    first_line_with "$AUDIT_OUT" "RESULT:" | sed 's/^/      /'
    failures=$(( failures + 1 ))
  fi
  rm -rf "$SCRATCH/$SUBJECT/src/db"

  # And with the assertion restored, the same tree must go red again — otherwise
  # "B5 went green" would be evidence about a broken copy of the audit.
  run_audit "$SCRATCH" "$AUDIT"
  expect_green "B5 with the real audit, tree reverted"
fi
say ""

# --------------------------------------------------------------------------
# B6 — an ANCHOR THAT IS NOT THERE. The recipe must STOP, not shrug and report
# the remaining cases green over a substrate it does not understand.
# --------------------------------------------------------------------------
say "B6  an anchor points at text that is not there — the recipe must STOP"
breakages=$(( breakages + 1 ))
STOP_ANCHOR='this exact text is deliberately absent from the audit'
STUB="$WORK/stub-for-anchor-test.sh"
cp "$AUDIT" "$STUB"
if edit "$STUB" "$STOP_ANCHOR" 'mutated'; then
  say "  B6: FAIL — the recipe APPLIED an anchor that does not exist. `edit` is"
  say "       not refusing, and a recipe that mutates nothing reports green."
  failures=$(( failures + 1 ))
else
  observed_red=$(( observed_red + 1 ))
  say "  B6: RED and STOPPED — \`edit\` refused an absent anchor (0 occurrences,"
  say "       expected exactly 1) and returned non-zero, so the case is a failure"
  say "       of the recipe rather than a pass over a tree it never changed."
fi
say ""

# --------------------------------------------------------------------------
# TALLIES. Reported separately from the passes, because they are four different
# claims: a control says the audit agrees with the fleet; a red says a breakage
# was caught BY NAME; a green-inside-B5 says a check was load-bearing.
# --------------------------------------------------------------------------
say "---------------------------------------------------------------"
say "tally"
say "  controls run                     : $controls"
say "  breakages planted                : $breakages"
say "  breakages caught, assertion named: $observed_red"
say "  greens (controls + reverts + B5) : $observed_green"
say "  failures                         : $failures"
say "---------------------------------------------------------------"
say "  the six breakages are NOT six reds, and a recipe that counted them as"
say "  such would be asserting a number rather than a property:"
say "    B1 B2 B3  red, each naming its own assertion   -> 3"
say "    B6        red: the recipe STOPPED on a bad anchor -> 1"
say "    B4        MUST STAY GREEN (a fixture is not a migration)"
say "    B5        MUST GO GREEN once the assertion is deleted, which is what"
say "             proves B3's check was load-bearing"
say "  so: 4 reds and 9 greens (2 controls, 5 reverts, B4 itself, and B5's"
say "  load-bearing green), or the recipe has stopped testing what it claims."
if [ "$failures" -eq 0 ] && [ "$observed_red" -eq 4 ] && [ "$observed_green" -eq 9 ] \
  && [ "$controls" -eq 2 ] && [ "$breakages" -eq 6 ]; then
  say "VERDICT: PASS"
  exit 0
fi
say "VERDICT: FAIL"
exit 1
