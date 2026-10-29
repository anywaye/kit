#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLASSIFY="$ROOT/tests/classify.py"
RULES="$ROOT/tests/rules.json"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "classify_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-classify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
passes=0

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

case_setup() {
  OLD="$WORK/$1/old"
  NEW="$WORK/$1/new"
  mkdir -p "$OLD" "$NEW"
  base_schema "$OLD/example.schema.json"
  cp "$OLD/example.schema.json" "$NEW/example.schema.json"
}

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

case_setup unmodelled-keyword
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["unevaluatedProperties"] = False
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect_unrecognised 'an unmodelled JSON Schema keyword is FILE, at the loosest tier too'

case_setup keyword-removed
"$PY" - "$OLD/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
del doc["additionalProperties"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect_unrecognised 'a removed keyword is reported, not skipped'

case_setup enum-removed
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["type"]["enum"] = ["a"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'an enum value removed breaks FILE' 1

case_setup enum-removed-wire
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["type"]["enum"] = ["a"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect WIRE 'a FILE change also breaks WIRE (tiers are cumulative)' 1

case_setup property-added
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["extra"] = {"type": "string"}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'an added optional property does not break a FILE consumer' 0

case_setup property-added-json
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["extra"] = {"type": "string"}
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect WIRE_JSON 'an added optional property breaks a WIRE_JSON consumer' 1

case_setup documentation
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["description"] = "a fixture, reworded"
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect WIRE 'a description change does not break WIRE' 0

case_setup identical
expect FILE 'an unchanged schema set breaks nothing at FILE' 0

case_setup file-removed
rm "$NEW/example.schema.json"
expect FILE 'a removed schema file breaks FILE' 1

case_setup file-added
cat >"$NEW/second.schema.json" <<'JSON'
{ "type": "object", "properties": { "x": { "type": "string" } } }
JSON
expect FILE 'an added schema file does not break a FILE consumer' 0

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

case_setup mixed
"$PY" - "$NEW/example.schema.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["description"] = "reworded"
doc["properties"]["id"]["type"] = "integer"
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
expect FILE 'a mixed change reduces to its strictest tier' 1
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

case_setup set-reordered
"$PY" - "$NEW/example.schema.json" <<'PYFIX'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["properties"]["type"]["enum"] = ["b", "a"]
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PYFIX
expect FILE 'a reordered set-valued keyword does not break FILE' 0

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
