#!/usr/bin/env bash
#
# Six breakages in identity's own query layer, each one observed going RED, each
# reverted and green again.
#
#   bash reports/tenant-adapter-go-01/mutations.sh
#
# THIS IS THE GO RECIPE, AND THE ANCHORS ARE GO'S OWN
#
#   `reports/tenant-isolation-harness/mutations.sh` is language-neutral except
#   for its six anchors, which are courier's Elixir source. It is NOT edited and
#   not reused: a second language gets its own recipe with its own anchors, and
#   this is it. Every anchor below was chosen by READING
#   `identity/internal/accounts/store.go` and counting occurrences of the exact
#   text, not by pattern-matching what a Go service usually looks like. A guessed
#   anchor is how a recipe reports "stayed green" for a breakage it never planted.
#
#   Where the predicate lives is a property of the service, and it is what moved
#   the anchors. In courier the account predicate is `where account_id ==
#   ^account_id` in a context module two frames above the write, which is why two
#   of its six breakages are one-word edits in a controller. In identity there
#   is no context module and no controller: `internal/accounts/store.go` IS the
#   boundary, and five of its functions spell `WHERE account_id = $1`. So every
#   anchor here is a line of a statement, and every breakage removes or inverts a
#   predicate ON THAT STATEMENT.
#
# WHAT IT PROVES AND WHAT IT DOES NOT
#
#   `tests/tenancy_test.sh` already proves identity's row-level security. This
#   recipe proves the thing underneath it: that identity's own SQL statements
#   scope themselves. The probe connects as a superuser, which Postgres exempts
#   from RLS unconditionally, so a predicate removed from these statements is a
#   predicate NOTHING catches — and the recipe below is what makes that statement
#   true rather than plausible.
#
# WHY SIX, AND WHY THESE SIX
#
#   1  missing WHERE           Store.Members loses its account predicate, so the
#                              member list answers with every account's rows
#   2  missing bind parameter  Store.Members KEEPS the predicate and pins a
#                              constant instead of the caller's account. The
#                              word `account_id` is still right there on the line
#                              and every denial is still green; only the ALLOWANCE
#                              notices, which is why it is its own case.
#   3  IDOR on fetch-by-id     Store.Member's `AND user_id = $2` becomes an OR, so
#                              A asking for one member by id gets B's
#   4  unscoped update         Store.SetRole writes a role on a membership A does
#                              not own
#   5  unscoped delete         Store.RemoveMember deletes one, on the one
#                              operation in this set whose damage is irreversible
#   6  unscoped update, ANOTHER TABLE
#                              Store.RevokePendingInvitation revokes B's pending
#                              invitation. A boundary held on account_users and
#                              dropped on account_invitations is an ordinary
#                              outcome, not a contradiction, so it needs its own
#                              case and its own table.
#
#   Each is a SEPARATE EDIT in a SEPARATE FUNCTION of the SAME FILE, applied and
#   reverted one at a time, so a case can never be "caught" by a defect the
#   previous case left behind.
#
# EVERY ANCHOR IS COUNTED BEFORE IT IS BELIEVED
#
#   `edit` refuses an anchor that does not appear EXACTLY once and prints the
#   count, so a stale recipe fails loudly instead of reporting "stayed green".
#   All six anchors were measured against identity's `store.go` before this recipe
#   was written, and all six report 1. `go vet`, `golangci-lint` and
#   `internal/tenancy`'s own suite are all blind to every one of these six: they
#   assert the SUBSTRATE, never these clauses.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/tests/tenant_isolation/cross_tenant_harness.sh"
OUT="$ROOT/reports/tenant-adapter-go-01"

mkdir -p "$OUT"

# The adapter, named explicitly. The harness's own default is
# `adapters/elixir.sh`, which is right for the Elixir recipe and wrong for this
# one; KIT_TENANT_ADAPTER is the documented override, and using it is what keeps
# the harness language-neutral instead of teaching it about a second language.
export KIT_TENANT_ADAPTER="$ROOT/tests/tenant_isolation/adapters/go.sh"

# THE SERVICE. `cross_tenant_harness.sh`'s own search is `$ROOT/../courier` then
# `$ROOT/../../courier` — courier is the Elixir adapter's subject, and a
# language-neutral harness has no business knowing the name of a Go service any
# more than it knows Elixir. KIT_SERVICE_REPO is the documented override and this
# recipe sets it. The `adapters/README.md` rule that a second adapter must not
# edit the harness is satisfied by USING the override, not by a fork.
if [ -z "${KIT_SERVICE_REPO:-}" ]; then
  for candidate in "$ROOT/../identity" "$ROOT/../../identity"; do
    if [ -d "$candidate" ]; then
      KIT_SERVICE_REPO="$( cd "$candidate" && pwd )"
      break
    fi
  done
fi
if [ -z "${KIT_SERVICE_REPO:-}" ] || [ ! -d "${KIT_SERVICE_REPO:-}" ]; then
  printf 'mutations.sh: no identity checkout at %s/../identity or %s/../../identity.\n' \
    "$ROOT" "$ROOT" >&2
  printf '  Point KIT_SERVICE_REPO at one. Exiting 2: nothing was proven.\n' >&2
  exit 2
fi
export KIT_SERVICE_REPO

# The harness, sourced rather than shelled out to, so one container, one
# compilation and one migrated database serve all thirteen runs and the service
# COPY is the same tree throughout. `KIT_TENANT_SESSION` is exported because the
# harness derives its container name and its host port from it.
export KIT_TENANT_SESSION="${KIT_TENANT_SESSION:-$$}"
# shellcheck source=/dev/null
. "$HARNESS"

controls=0
breakages=0
observed_red=0
failures=0
MUTATED=""

say() { printf '%s\n' "$*"; }

# `contains` — a shell `case` over a variable already in memory, never
# `printf … | grep -q`. kit has been bitten by that twice: `grep -q` closes the
# pipe on its first match, the writer dies of SIGPIPE, and `pipefail` promotes
# 141, so the verdict flips on the SIZE of the output rather than its content.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# `count_prefix` — how many lines of a captured output start with a prefix. A
# `while read` loop over a herestring rather than a pipe, for the reason above:
# `grep -c` is safe, but the whole point of this recipe is that reading kit's own
# output is where the SIGPIPE bug has bitten twice.
count_prefix() {
  local text="$1" prefix="$2" n=0 line
  while IFS= read -r line; do
    case "$line" in
      "$prefix"*) n=$(( n + 1 )) ;;
    esac
  done <<EOF
$text
EOF
  printf '%s' "$n"
}

# `first_line_with` — the literal line carrying a substring, kept rather than
# paraphrased. "the harness covers unscoped lists" is a claim about the recipe;
# this is a receipt.
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

# restore — ARMED, not installed. `MUTATED` is set only once a mutation has
# actually written something, so a run that never mutated anything never touches
# the tree.
restore() {
  [ -n "$MUTATED" ] || return 0
  # shellcheck disable=SC2086
  eval "$RESTORE_CMD" >/dev/null 2>&1 || true
  MUTATED=""
}
trap 'restore; tenant_harness_down' EXIT

# edit <file> <from> <to> — a textual mutation that FAILS LOUDLY if the tree has
# moved past it. A stale recipe that "passes" is the whole class of defect here:
# it reports a breakage stayed green when it never broke anything. The count is
# printed because "anchor appears 3 times" is the message a reader needs and
# "recipe is stale" is not.
edit() {
  if ! "$PYTHON" - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path, encoding="utf-8").read()
n = body.count(old)
if n != 1:
    sys.exit(f"anchor appears {n} times in {path}, expected exactly 1:\n{old!r}")
open(path, "w", encoding="utf-8").write(body.replace(old, new, 1))
PY
  then
    return 1
  fi
  return 0
}

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || {
  say "mutations.sh: python3 not on PATH. Exiting 2: the recipe cannot be applied, and a recipe that did not apply proves nothing."
  exit 2
}

[ -r "$HARNESS" ] || {
  say "mutations.sh: $HARNESS is missing. Exiting 2."
  exit 2
}

say "recipe:   $0"
say "harness:  $HARNESS"
say "adapter:  $KIT_TENANT_ADAPTER"
say "service:  $KIT_SERVICE_REPO"
say ""

# The tree the six edits are applied to. Read out of the harness's own session
# state rather than reconstructed, because reconstructing it is how a mutation
# pass ends up editing a path it is not reporting on.
tenant_harness_up || exit 2
# shellcheck disable=SC1090
. "${TMPDIR:-/tmp}/kit-tenant-iso.$KIT_TENANT_SESSION/session.env"
export KIT_TENANT_WORK KIT_TENANT_PROJECT KIT_TENANT_PGPORT KIT_TENANT_SERVICE KIT_TENANT_ADAPTER_DIR

# ONE file holds all five predicates, so one BEFORE copy and one restore command
# restore all six cases. They are still six separate edits in six separate
# functions, which is the property that matters — a shared file is not a shared
# mutation.
STORE="$KIT_TENANT_WORK/service/internal/accounts/store.go"
cp "$STORE" "$OUT/BEFORE-store.go"
RESTORE_CMD="cp '$OUT/BEFORE-store.go' '$STORE'"

# The seven tests the probe carries, and the five of them the six breakages are
# written for. `PROBE_TESTS` is stated HERE as well as in the probe file, and that
# duplication is deliberate and it fails TOWARD RED: a test added to the probe
# without this line updated makes the control fail and names both numbers. The
# alternative — counting whatever the runner printed and comparing it to itself —
# is the property stated in one place and therefore asserted in none, and it is
# the shape this repository has already been bitten by twice.
ALLOWANCE="TestCrossTenantListOwnRowsVisible"
SUBSTRATE="TestTheSubstrateIsNotWhatHoldsThisLine"
PROBE_TESTS="7"

say "=== THE CONTROL: an unmodified identity that scopes correctly ==="
say ""
out="$(tenant_harness_run '__all__')"
code=$?
printf '%s\n' "$out" | tail -14

if [ "$code" -ne 0 ]; then
  say ""
  say "FAIL: the control is RED on the unmodified service. Nothing below is interpretable:"
  say "  a harness that cannot see correct code is not a harness."
  failures=$(( failures + 1 ))
  restore
  tenant_harness_down
  exit 1
fi

# The vacuous-green guard, from the RUNNER's output and not from this file: the
# adapter already refuses a `go test -run` that started zero tests, and this is
# the other half — a green run that started some tests but passed none of the
# ones the recipe is about is a probe that has stopped asserting anything.
passed="$( count_prefix "$out" '--- PASS: ' )"
if [ "${passed:-0}" -ne "$PROBE_TESTS" ]; then
  say ""
  say "FAIL: the control reported ${passed:-0} passing tests; this recipe declares $PROBE_TESTS."
  say "  Either the probe gained or lost a test and this line was not updated with it"
  say "  — which is the intended direction for that mistake to fail in — or the run"
  say "  measured less than it claims. A run that measured nothing must not be"
  say "  reported as a control."
  failures=$(( failures + 1 ))
  restore
  tenant_harness_down
  exit 1
fi

# THE ALLOWANCE, IN THE BASE PHASE. Not only inside the mutations: a probe whose
# allowance control exists only after a breakage cannot tell "identity scopes
# correctly" from "the probe never ran", and a denial-only base phase is
# satisfied by a service that returns nothing to anybody.
if ! contains "$out" "--- PASS: $ALLOWANCE "; then
  say ""
  say "FAIL: the base phase did not run the ALLOWANCE control \`$ALLOWANCE\`."
  say "  Every denial is satisfied by a service that returns nothing to anybody,"
  say "  so the base phase has to assert that A sees its OWN rows."
  failures=$(( failures + 1 ))
  restore
  tenant_harness_down
  exit 1
fi

# The substrate control, for the same reason and a sharper one: without it, every
# denial below could be green because of row-level security rather than because
# of identity's SQL, and the whole recipe would be a second measurement of the
# substrate under a different name.
if ! contains "$out" "--- PASS: $SUBSTRATE "; then
  say ""
  say "FAIL: the base phase did not run the SUBSTRATE control \`$SUBSTRATE\`."
  say "  Row-level security being what holds the line is a claim this recipe"
  say "  cannot make, and the control that refuses it is what makes the six reds"
  say "  mean what they say."
  failures=$(( failures + 1 ))
  restore
  tenant_harness_down
  exit 1
fi

controls=$(( controls + 1 ))
say ""
say "PASS control 1/1: $passed assertions against a real Postgres, 0 failures."
say "  the ALLOWANCE ran in the BASE phase: $ALLOWANCE"
say "  the SUBSTRATE was armed and bypassed:  $SUBSTRATE"

# breakage <n> <label> <needle> <file> <from> <to>
#
# Four assertions per case, and the fourth is the one that makes the first three
# mean something:
#
#   1. the mutation IS IN THE FILE   (text, not exit status)
#   2. the NAMED test went RED       (the test written for this defect, not
#                                     "something went red")
#   3. the literal failure line is on the record
#   4. REVERTED, AND GREEN AGAIN     (the cost of the deletion, measured)
breakage() {
  local n="$1" label="$2" needle="$3" file="$4" from="$5" to="$6"
  local out code line

  restore
  say ""
  say "=== BREAKAGE $n: $label ==="

  if ! edit "$file" "$from" "$to"; then
    printf 'NO ANCHOR  breakage %s: %s — the exact text is not there exactly once\n' "$n" "$label"
    failures=$(( failures + 1 ))
    return
  fi
  MUTATED="planted"

  # (1) BY TEXT. `grep -c` prints the count and can be read; `grep -q` would exit
  # on the first match and its status would say nothing about how many there were.
  local after
  after="$(grep -c -F -- "$to" "$file" 2>/dev/null)" || after=0
  if [ "$after" -lt 1 ]; then
    printf 'NO MUTATION breakage %s: the edit reported success and left the file byte-identical\n' "$n"
    failures=$(( failures + 1 ))
    restore
    return
  fi
  printf '  planted: %s\n' "$to"

  # (2) THE NAMED ASSERTION FAILED.
  out="$(tenant_harness_run "$needle")"
  code=$?
  if [ "$code" -eq 0 ]; then
    printf 'NOT BITTEN breakage %s: %s — the suite stayed GREEN\n' "$n" "$label"
    printf '%s\n' "$out" | tail -6 | sed 's/^/  /'
    failures=$(( failures + 1 ))
    restore
    return
  fi
  if ! contains "$out" "--- FAIL: $needle "; then
    printf 'WRONG FAILURE breakage %s: %s — it went red as something else and never said `%s`\n' \
      "$n" "$label" "$needle"
    printf '%s\n' "$out" | tail -8 | sed 's/^/  /'
    failures=$(( failures + 1 ))
    restore
    return
  fi

  # (3) THE LITERAL LINE, kept rather than paraphrased. It is printed from the
  # captured output and never through a pipe, for the reason `contains` above
  # says: `grep -m1` closes the pipe on its first match and `pipefail` turns the
  # SIGPIPE into a verdict that depends on the size of the output.
  line="$(first_line_with "$out" "--- FAIL: $needle ")"
  printf 'BITTEN     breakage %s: %s\n' "$n" "$label"
  printf '  %s\n' "${line:-$needle red, line not recoverable from the output}"
  # The assertion's own message, which is the receipt that names WHAT caught it
  # rather than which test failed.
  message="$(first_line_with "$out" "cross_tenant_probe_test.go:" || true)"
  [ -n "$message" ] && printf '  %s\n' "$message"
  breakages=$(( breakages + 1 ))
  observed_red=$(( observed_red + 1 ))

  # (4) REVERTED, AND GREEN AGAIN.
  restore
  out="$(tenant_harness_run "$needle")"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'NOT REVERTED breakage %s: green before, red planted, still red after the revert\n' "$n"
    printf '%s\n' "$out" | tail -8 | sed 's/^/  /'
    failures=$(( failures + 1 ))
    return
  fi
  printf '  reverted: green again\n'
}

# --------------------------------------------------------------------------
# 1. missing WHERE. `Store.Members` keeps its join and its ordering and loses the
#    predicate that makes the list one account's, so the line still reads like a
#    scoped query — the whole difficulty, in one word.
# --------------------------------------------------------------------------
breakage 1 "Store.Members loses its account predicate" \
  'TestCrossTenantListDeniesOtherAccount' "$STORE" \
  'WHERE a.id = $1' \
  'WHERE a.id = $1 OR true'

# --------------------------------------------------------------------------
# 2. missing bind parameter. The predicate is THERE and the value under it is not
#    the caller's account. This is the one a grep cannot see and the one that
#    makes the allowance worth having: `account_id` is still spelled correctly on
#    the line, every denial is still green, and A's own list is empty.
#
#    The pin is `id.UUID{15: 1}` — a real, non-zero UUID no account row can
#    have — rather than the zero value, because `Members` refuses the zero value
#    in its own guard and that would make this a breakage of the guard rather
#    than of the bind. It passes `IsZero`, reaches the query, and matches
#    nothing.
# --------------------------------------------------------------------------
breakage 2 "Store.Members pins a constant instead of the caller's account" \
  'TestCrossTenantListOwnRowsVisible' "$STORE" \
  'func (s *Store) Members(ctx context.Context, q db.Querier, accountID id.UUID) ([]MemberSummary, error) {' \
  $'func (s *Store) Members(ctx context.Context, q db.Querier, accountID id.UUID) ([]MemberSummary, error) {\n\t// KIT PROBE BREAKAGE: the predicate is present and correctly spelled, and the\n\t// value UNDER it is not the account the caller asked for.\n\taccountID = id.UUID{15: 1}'

# --------------------------------------------------------------------------
# 3. IDOR on fetch-by-id. `Store.Member` is asked for one membership by
#    (account, user); changing `AND` to `OR` means a caller holding any account
#    can name any user and be handed the membership. One word, and the entire
#    authorization boundary of a fetch-by-id.
# --------------------------------------------------------------------------
breakage 3 "Store.Member turns its AND into an OR on fetch-by-id" \
  'TestCrossTenantMemberByIDDeniesOtherAccount' "$STORE" \
  'const query = `SELECT ` + membershipColumns + ` FROM account_users WHERE account_id = $1 AND user_id = $2`' \
  'const query = `SELECT ` + membershipColumns + ` FROM account_users WHERE account_id = $1 OR user_id = $2`'

# --------------------------------------------------------------------------
# 4. unscoped update. The scoping is on the statement here, so removing it is one
#    predicate on an UPDATE, and the row it reaches is somebody else's membership.
#    The probe reads the row back on B's OWN account afterwards, because a
#    statement that updated four rows returns one of them and says nothing about
#    the other three.
# --------------------------------------------------------------------------
breakage 4 "Store.SetRole writes a role on a membership A does not own" \
  'TestCrossTenantSetRoleDeniesOtherAccount' "$STORE" \
  $'\t\tWHERE account_id = $1 AND user_id = $2' \
  $'\t\tWHERE account_id = $1 OR user_id = $2'

# --------------------------------------------------------------------------
# 5. unscoped delete. Same shape as 4 and the same blindness, on the one
#    operation here whose damage is not reversible.
# --------------------------------------------------------------------------
breakage 5 "Store.RemoveMember deletes a membership A does not own" \
  'TestCrossTenantRemoveMemberDeniesOtherAccount' "$STORE" \
  $'\t\t`DELETE FROM account_users WHERE account_id = $1 AND user_id = $2`,' \
  $'\t\t`DELETE FROM account_users WHERE account_id = $1 OR user_id = $2`,'

# --------------------------------------------------------------------------
# 6. the same unscoped write on ANOTHER TABLE. account_users and
#    account_invitations are two tables with two sets of clauses, and a
#    predicate dropped from one of them says nothing whatever about the other —
#    which is exactly why a recipe that only ever breaks one function cannot
#    claim a service scopes correctly.
# --------------------------------------------------------------------------
breakage 6 "Store.RevokePendingInvitation stops scoping by account" \
  'TestCrossTenantRevokeInvitationDeniesOtherAccount' "$STORE" \
  'WHERE id = $1 AND account_id = $2 AND accepted_at IS NULL AND revoked_at IS NULL' \
  'WHERE id = $1 AND (account_id = $2 OR true) AND accepted_at IS NULL AND revoked_at IS NULL'

say ""
say "=== BASELINE: the tree, reverted, one more time ==="
restore
out="$(tenant_harness_run '__all__')"
code=$?
printf '%s\n' "$out" | tail -6
cp "$STORE" "$OUT/AFTER-store.go"
if ! cmp -s "$OUT/BEFORE-store.go" "$OUT/AFTER-store.go"; then
  say ""
  say "FAIL: the tree is NOT byte-identical after every revert. The BEFORE and AFTER"
  say "  copies in $OUT are the evidence; diff them before trusting any tally above."
  failures=$(( failures + 1 ))
fi

say ""
if [ "$failures" -ne 0 ]; then
  say "FAIL: mutations.sh — $failures case(s) failed."
  exit 1
fi
# The two "nothing ran" guards. A self-test whose recipes have gone stale reports
# zero breakages and exits 0, which is the exact failure this repository's rules
# forbid: a checker that has stopped checking, reported as one that passed.
if [ "$breakages" -eq 0 ] || [ "$controls" -eq 0 ]; then
  say "FAIL: mutations.sh — $breakages breakages and $controls controls ran. A run with a zero in it proved nothing, not that nothing was wrong."
  exit 1
fi
if [ "$observed_red" -ne "$breakages" ]; then
  say "FAIL: mutations.sh — $breakages breakages planted and $observed_red observed RED. Those two numbers are different claims."
  exit 1
fi
# The two counts, separately, always. "6 passed" could be six reds or six
# controls; the whole packet turns on a reader being able to tell which.
say "PASS: mutations.sh — $controls control green, $breakages breakages planted and all"
say "  $observed_red observed RED with the assertion each was written for named, each"
say "  reverted and green again, and the tree byte-identical at the end."