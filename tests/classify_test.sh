#!/usr/bin/env bash
#
# tests/classify_test.sh — the fail-closed property, asserted rather than assumed.
#
#   bash tests/classify_test.sh
#
# WHY THIS IS A SEPARATE SCRIPT AND NOT MORE self_test CASES
#
#   `self_test.sh` breaks a copy of kit's TREE and asserts the gate goes red. That
#   is the right shape for a check that reads a file. The classifier's property is
#   different: it is a statement about what the classifier does with a pair of
#   schema DIRECTORIES, including changes no rule names. So the cases here build
#   two trees in a temp dir and run the classifier over them, which is the only
#   way to exercise the property that matters.
#
# THE PROPERTY
#
#   An unrecognised change fails. Not "fails loudly" — fails, at the strictest
#   tier, with a non-zero exit. Everything else in this file is a corollary.
#
#   The cases below are ordered so the sharpest is first and the cheapest
#   regression checks follow. `fail_closed` is the one this packet exists for: a
#   brand-new JSON Schema keyword arriving in core, which nobody wrote a rule
#   for, and which a fail-open classifier would wave through.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLASSIFY="$ROOT/tests/classify.py"
RULES="$ROOT/tests/rules.json"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "classify_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-classify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
passes=0

# The base schema every case starts from. Small on purpose: a fixture that needs
# a parser to understand is a fixture whose failure is hard to read.
base_schema() {
  cat >"$1" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://anywaye.dev/schemas/example.schema.json",
  "title": "example",
  "description": "a fixture",
  "type": "object",
  "additionalProperties": false,
  "required": ["id", "type"],
  "properties": {
    "id": { "type": "string" },
    "type": { "type": "string", "enum": ["a", "b"] },
    "note": { "type": "string", "maxLength": 10 }
  }
}
JSON
}

# case_setup <name> — a fresh old/ new pair with the base schema on both sides.
case_setup() {
  OLD="$WORK/$1/old"
  NEW="$WORK/$1/new"
  mkdir -p "$OLD" "$NEW"
  base_schema "$OLD/example.schema.json"
  cp "$OLD/example.schema.json" "$NEW/example.schema.json"
}

# expect <tier> <label> <want-exit>
#
# want-exit is 0 or 1 and is the assertion; the label is for the human. The exit
# code is read from the command itself, never from a pipe: `cmd | tail` reports
# tail's status, and a test that asserts tail's status is a test that cannot fail.
expect() {
  local tier="$1" label="$2" want="$3"
  local out ec=0
  out=$("$PY" "$CLASSIFY" "$OLD" "$NEW" --tier "$tier" --rules "$RULES" 2>&1) || ec=$?
  if [ "$ec" -eq "$want" ]; then
    printf 'PASS classify_test: %s\n' "$label"
    passes=$((passes + 1))
  else
    printf 'FAIL classify_test: %s — exit %s, wanted %s\n' "$label" "$ec" "$want"
    printf '%s\n' "$out" | sed 's/^/       /'
    failures=$((failures + 1))
  fi
}

# expect_unrecognised <label> — the classifier must both fail AND name the
# unmodelled keyword. Failing for the wrong reason is a pass on this gate's
# worst day, so the message is asserted, not just the exit code.
expect_unrecognised() {
  local label="$1" ec=0
  local out
  out=$("$PY" "$CLASSIFY" "$OLD" "$NEW" --tier WIRE --rules "$RULES" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ] && grep -q 'unrecognised' <<<"$out"; then
    printf 'PASS classify_test: %s\n' "$label"
    passes=$((passes + 1))
  else
    printf 'FAIL classify_test: %s — exit %s, no UNRECOGNISED report\n' "$label" "$ec"
    printf '%s\n' "$out" | sed 's/^/       /'
    failures=$((failures + 1))
  fi
}

printf -- '-- classify_test: the change classifier fails closed\n'

# 1. THE PROPERTY. `unevaluatedProperties` is real JSON Schema 2020-12 and no rule
#    in rules.json names it. A fail-open classifier reports "no recognised
#    breakage" and exits 0 here, which is precisely the F1 defect: an unknown
#    change auto-merged green across thirteen repositories. Note the tier is
#    WIRE, the loosest a caller can declare: even a consumer that claims to care
#    about nothing but payload bytes must fail on a change nobody classified.
case_setup unmodelled-keyword
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["unevaluatedProperties"] = False
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect_unrecognised 'an unmodelled JSON Schema keyword is FILE, at the loosest tier too'

# 2. The same, expressed as a keyword being REMOVED. A removal is the case a
#    `for key in new` loop drops, and dropping a removal is how a breaking change
#    becomes invisible.
case_setup keyword-removed
"$PY" - "$OLD/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
del doc["additionalProperties"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect_unrecognised 'a removed keyword is reported, not skipped'

# 3. A recognisable change at the strictest tier: an enum value removed. A
#    producer still emitting it now builds a document core rejects.
case_setup enum-removed
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["type"]["enum"] = ["a"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'an enum value removed breaks FILE' 1

# 4. The same change, declared against the loosest tier. Cumulative tiers mean a
#    FILE change breaks every tier, so this must fail at WIRE too. If this case
#    ever passes, the tier ordering has stopped being cumulative and every
#    conclusion drawn from it is void.
case_setup enum-removed-wire
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["type"]["enum"] = ["a"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect WIRE 'a FILE change also breaks WIRE (tiers are cumulative)' 1

# 5. A recognisable additive change at the strictest tier. Adding an optional
#    property is WIRE_JSON, looser than FILE, so a FILE consumer survives it. This
#    is the case that would be most annoying to get wrong in the fail-closed
#    direction, and it is the one that proves the gate is not simply always-red.
case_setup property-added
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["extra"] = {"type": "string"}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'an added optional property does not break a FILE consumer' 0

# 6. ...and the same change against a WIRE_JSON consumer, which must fail. If
#    case 5 passed for the wrong reason (a gate that fails on everything) case 6
#    would too, so the pair is what distinguishes "correctly permissive" from
#    "always red".
case_setup property-added-json
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["extra"] = {"type": "string"}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect WIRE_JSON 'an added optional property breaks a WIRE_JSON consumer' 1

# 7. A documentation-only edit is the one change that may be absorbed silently,
#    and asserting that it passes at WIRE is what keeps "fail closed" from
#    decaying into "red on every PR", which is the other way this gate rots.
case_setup documentation
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["description"] = "a fixture, reworded"
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect WIRE 'a description change does not break WIRE' 0

# 8. The control: two identical trees classify clean at the strictest tier. If
#    this fails, every failure above is meaningless.
case_setup identical
expect FILE 'an unchanged schema set breaks nothing at FILE' 0

# 9. A file removed from the vendored set. Every vendoring repo has the path in
#    its own tree, so this is FILE whatever else is true.
case_setup file-removed
rm "$NEW/example.schema.json"
expect FILE 'a removed schema file breaks FILE' 1

# 10. A file added is additive: a consumer that does not reference it yet cannot
#     be broken by it. This is the tier the catalogue exists to make expressible.
case_setup file-added
cat >"$NEW/second.schema.json" <<'JSON'
{ "type": "object", "properties": { "x": { "type": "string" } } }
JSON
expect FILE 'an added schema file does not break a FILE consumer' 0

# 11. `required` gaining a name. The document now demands a field a conforming
#     producer may not send: PACKAGE, so a FILE consumer still survives and a
#     PACKAGE consumer does not.
case_setup required-added
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["required"].append("note")
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'a newly required property does not break a FILE consumer' 0
case_setup required-added-package
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["required"].append("note")
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect PACKAGE 'a newly required property breaks a PACKAGE consumer' 1

# 12. The reduction is exercised end to end: a `type` change (FILE) and a
#     description change (WIRE) in one document must reduce to FILE, and the
#     report must show both observations rather than only the winner.
case_setup mixed
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["description"] = "reworded"
doc["properties"]["id"]["type"] = "integer"
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'a mixed change reduces to its strictest tier' 1
#
# The first version of this assertion piped the classifier into grep, and it
# failed for a reason worth recording, because this file runs under `pipefail`
# and the classifier deliberately exits 1 on this case: with `pipefail` the
# pipeline reports the rightmost non-zero status, so a successful `grep -q` was
# masked by the classifier's own failure and the assertion could never pass. A
# piped exit code is the exit of the last stage, and a test that reads one is a
# test that asserts the wrong thing. The output is captured to a variable first,
# and the status is read from the command, never from a pipe.
mixed_out=""
mixed_ec=0
mixed_out=$("$PY" "$CLASSIFY" "$OLD" "$NEW" --tier FILE --rules "$RULES" 2>&1) || mixed_ec=$?
if [ "$mixed_ec" -ne 0 ] \
    && grep -q 'type-changed' <<<"$mixed_out" \
    && grep -q 'documentation-changed' <<<"$mixed_out"; then
  printf 'PASS classify_test: every observation is reported, not only the strictest\n'
  passes=$((passes + 1))
else
  printf 'FAIL classify_test: only the strictest observation was reported (exit %s)\n' \
    "$mixed_ec"
  printf '%s\n' "$mixed_out" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 12b. An advisory change is REPORTED and does not FAIL. These are two different
#      claims and this asserts both: a documentation edit appearing in the output
#      is what makes the gate auditable, and a non-zero exit would be a gate that
#      is red on every typo in core.
case_setup advisory-reported
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["description"] = "reworded"
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
advisory_out=""
advisory_ec=0
advisory_out=$("$PY" "$CLASSIFY" "$OLD" "$NEW" --tier FILE --rules "$RULES" 2>&1) \
  || advisory_ec=$?
if [ "$advisory_ec" -eq 0 ] \
    && grep -q 'documentation-changed' <<<"$advisory_out"; then
  printf 'PASS classify_test: an advisory change is reported and does not fail the gate\n'
  passes=$((passes + 1))
else
  printf 'FAIL classify_test: an advisory change was mishandled (exit %s)\n' "$advisory_ec"
  printf '%s\n' "$advisory_out" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 12c. Allowlist hygiene, in the direction that matters: the escape hatch cannot
#      be widened by a later commit flipping a flag. Marking a real breaking
#      change as non-breaking must make the catalogue refuse to load.
case_setup hygiene
if "$PY" - "$RULES" "$WORK/widened.json" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
for rule in raw["rules"]:
    if rule["id"] == "enum-value-removed":
        rule["breaking"] = False
json.dump(raw, open(sys.argv[2], "w"), indent=2)
PY
then
  ec=0
  "$PY" "$CLASSIFY" "$OLD" "$NEW" --rules "$WORK/widened.json" >/dev/null 2>&1 || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'PASS classify_test: a non-advisory op cannot be marked non-breaking\n'
    passes=$((passes + 1))
  else
    printf 'FAIL classify_test: enum-value-removed was waved through as non-breaking\n'
    failures=$((failures + 1))
  fi
else
  printf 'FAIL classify_test: could not build the widened catalogue\n'
  failures=$((failures + 1))
fi

# 13. rules.json is a data file, so it can be edited into something the
#     classifier cannot act on. Two operations claiming the same name would give a
#     change no single tier, and the loader must refuse rather than pick one.
case_setup catalogue-clash
if "$PY" - "$RULES" "$WORK/clash.json" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
raw["rules"].append(dict(raw["rules"][0]))
json.dump(raw, open(sys.argv[2], "w"), indent=2)
PY
then
  ec=0
  "$PY" "$CLASSIFY" "$OLD" "$NEW" --rules "$WORK/clash.json" >/dev/null 2>&1 || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'PASS classify_test: a rules.json with two rules for one operation is refused\n'
    passes=$((passes + 1))
  else
    printf 'FAIL classify_test: a rules.json with two rules for one operation was accepted\n'
    failures=$((failures + 1))
  fi
else
  printf 'FAIL classify_test: could not build the clashing catalogue\n'
  failures=$((failures + 1))
fi

# 14. A reorder of `required` or `enum` is not a semantic change - JSON Schema
#     defines both as sets - so it is reported and absorbed rather than escalated
#     to FILE. Asserted because the alternative is a gate that goes red on a
#     cosmetic edit, and the first response to that is to stop trusting the gate.
case_setup set-reordered
"$PY" - "$NEW/example.schema.json" <<'PYFIX'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["required"] = ["type", "id"]          # same members, other order
doc["properties"]["type"]["enum"] = ["b", "a"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PYFIX
expect FILE 'a reordered set-valued keyword does not break FILE' 0

# 15. The flag the sharpest self-test breakage flips is REAL, and this asserts
#     it. Without this case a breakage that set `unrecognisedIsBreaking: false`
#     would prove nothing: if the key were ignored entirely, flipping it would
#     leave the suite green and the self_test would pass for the wrong reason.
#     So here the flag is flipped on purpose, and the unmodelled case is required
#     to STOP failing.
case_setup fail-open-flag
"$PY" - "$NEW/example.schema.json" <<'PYOPEN'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["unevaluatedProperties"] = False
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PYOPEN
"$PY" - "$RULES" "$WORK/fail-open.json" <<'PYOPEN2'
import json, sys
raw = json.load(open(sys.argv[1]))
raw["unrecognisedIsBreaking"] = False
json.dump(raw, open(sys.argv[2], "w"), indent=2)
PYOPEN2
open_ec=0
open_out=$("$PY" "$CLASSIFY" "$OLD" "$NEW" --tier FILE --rules "$WORK/fail-open.json" 2>&1) \
  || open_ec=$?
if [ "$open_ec" -eq 0 ]; then
  printf 'PASS classify_test: unrecognisedIsBreaking is load-bearing (false really does fail open)\n'
  passes=$((passes + 1))
else
  printf 'FAIL classify_test: unrecognisedIsBreaking is ignored, so the self_test breakage is vacuous\n'
  printf '%s\n' "$open_out" | sed 's/^/       /'
  failures=$((failures + 1))
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: classify_test — $failures case(s) failed, $passes passed."
  exit 1
fi
echo "PASS: classify_test — $passes case(s), including the fail-closed property."
