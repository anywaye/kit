#!/usr/bin/env bash

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FP="$ROOT/tests/fingerprint.py"
PY="${PYTHON:-python3}"

work="$(mktemp -d "${TMPDIR:-/tmp}/kit-fingerprint-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fails=0
passes=0

report() {
  printf '%-4s %s\n' "$1" "$2"
  case "$1" in
    FAIL) fails=$((fails + 1)) ;;
    PASS) passes=$((passes + 1)) ;;
  esac
}

expect_exit() {
  local want="$1" label="$2"
  shift 2
  local got=0
  "$@" >"$work/.out" 2>"$work/.err" || got=$?
  if [ "$got" -eq "$want" ]; then
    report PASS "$label"
  else
    report FAIL "$label (wanted exit $want, got $got)"
    sed 's/^/       /' "$work/.err" | head -6
  fi
}

new_tree() {
  local dir="$work/$1"
  rm -rf "$dir"
  mkdir -p "$dir/out"
  printf 'declared input, 1.0\n' >"$dir/in.txt"
  printf 'tool version\n' >"$dir/VERSION"
  printf '1.0.0\n' >"$dir/VERSION"
  printf ' artefact v1\n' >"$dir/out/artefact.txt"
  printf '%s' "$dir"
}

manifest_for() {
  "$PY" "$FP" --root "$1" --cache-dir "$2" manifest \
    --check "expensive-gate" \
    --inputs "in.txt,VERSION" \
    --outputs "out/*" \
    --command "run the expensive thing" \
    --out "$1/manifest.json"
}

cache_a="$work/cache-a"

echo "fingerprint_test: the skip must be provable able to be WRONG"
echo

t1="$(new_tree tree1)"
manifest_for "$t1" "$cache_a"

expect_exit 1 "0a. a cold cache is a MISS, not a crash" \
  "$PY" "$FP" --root "$t1" --cache-dir "$cache_a" lookup --manifest "$t1/manifest.json"

printf 'expensive gate: 1 fact learned\n' >"$t1/check.out"
"$PY" "$FP" --root "$t1" --cache-dir "$cache_a" record \
  --manifest "$t1/manifest.json" --exit 0 --stdout-file "$t1/check.out"

expect_exit 0 "0b. the identical second lookup is a HIT" \
  "$PY" "$FP" --root "$t1" --cache-dir "$cache_a" lookup --manifest "$t1/manifest.json"

if "$PY" "$FP" --root "$t1" --cache-dir "$cache_a" lookup \
     --manifest "$t1/manifest.json" 2>/dev/null | grep -q '1 fact learned'; then
  report PASS "0c. a HIT replays the recorded evidence, so the run still shows it"
else
  report FAIL "0c. a HIT replayed no evidence — the run would go silent after the first pass"
fi

t2="$(new_tree tree2)"
manifest_for "$t2" "$cache_a"
printf 'expensive gate: 1 fact learned\n' >"$t2/check.out"
"$PY" "$FP" --root "$t2" --cache-dir "$cache_a" record \
  --manifest "$t2/manifest.json" --exit 0 --stdout-file "$t2/check.out"

rm -f "$t2/out/artefact.txt"
expect_exit 1 "1a. SAME fingerprint, outputs DELETED -> RE-RUN (the second clause)" \
  "$PY" "$FP" --root "$t2" --cache-dir "$cache_a" lookup --manifest "$t2/manifest.json"

mkdir -p "$t2/out"
printf ' artefact v1\n' >"$t2/out/artefact.txt"
printf 'a second file appeared\n' >"$t2/out/unexpected.txt"
expect_exit 1 "1b. SAME fingerprint, a DIFFERENT set of outputs -> RE-RUN" \
  "$PY" "$FP" --root "$t2" --cache-dir "$cache_a" lookup --manifest "$t2/manifest.json"
rm -f "$t2/out/unexpected.txt"

expect_exit 0 "1c. outputs restored -> HIT again, so 1a was the outputs and not a wedge" \
  "$PY" "$FP" --root "$t2" --cache-dir "$cache_a" lookup --manifest "$t2/manifest.json"

t3="$(new_tree tree3)"
manifest_for "$t3" "$cache_a"
manifest_before="$work/before.json"
cp "$t3/manifest.json" "$manifest_before"
printf 'expensive gate: 1 fact learned\n' >"$t3/check.out"
"$PY" "$FP" --root "$t3" --cache-dir "$cache_a" record \
  --manifest "$t3/manifest.json" --exit 0 --stdout-file "$t3/check.out"

expect_exit 0 "2a. warm, before the edit" \
  "$PY" "$FP" --root "$t3" --cache-dir "$cache_a" lookup --manifest "$t3/manifest.json"

"$PY" - "$t3/in.txt" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    body = fh.read()
with open(path, "w", encoding="utf-8") as fh:
    fh.write(body.replace("1.0", "2.0", 1))
PY
manifest_for "$t3" "$cache_a"
expect_exit 1 "2b. ONE BYTE of a declared input changed -> RE-RUN" \
  "$PY" "$FP" --root "$t3" --cache-dir "$cache_a" lookup --manifest "$t3/manifest.json"

if "$PY" "$FP" --root "$t3" --cache-dir "$cache_a" diff \
     "$manifest_before" "$t3/manifest.json" | grep -q 'in.txt'; then
  report PASS "2c. diff names the input that changed, in one line"
else
  report FAIL "2c. diff did not name in.txt — a reader would have no way to find the cause"
fi

"$PY" "$FP" --root "$t3" --cache-dir "$cache_a" manifest \
  --check "expensive-gate" --inputs "VERSION,in.txt" --outputs "out/*" \
  --command "run the expensive thing" --out "$work/reordered.json"
if [ "$("$PY" "$FP" fingerprint "$work/reordered.json")" = \
     "$("$PY" "$FP" fingerprint "$t3/manifest.json")" ]; then
  report PASS "2d. input ORDER does not change the fingerprint (a reformat is not a change)"
else
  report FAIL "2d. reordering the declared inputs changed the fingerprint"
fi

t4="$(new_tree tree4)"
manifest_for "$t4" "$cache_a"
printf 'expensive gate: 1 fact learned\n' >"$t4/check.out"
"$PY" "$FP" --root "$t4" --cache-dir "$cache_a" record \
  --manifest "$t4/manifest.json" --exit 0 --stdout-file "$t4/check.out"
rec="$cache_a/expensive-gate.json"
[ -f "$rec" ] || report FAIL "3a. SETUP: no record was written to $rec"

head -c 40 "$rec" >"$rec.trunc" && mv "$rec.trunc" "$rec"
expect_exit 2 "3a. TRUNCATED record -> RE-RUN, with its own code and no traceback" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

printf '\000\001\002not json at all\377\n' >"$rec"
expect_exit 2 "3b. BINARY record -> RE-RUN, not a crash" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

printf '{"schema":1,"tool":"1.0.0","check":"expensive-gate","exit":"zero"}\n' >"$rec"
expect_exit 2 "3c. WELL-FORMED but wrong-typed record -> RE-RUN" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

"$PY" - "$rec" "$t4/manifest.json" <<'PY'
import json, sys
rec_path, man_path = sys.argv[1], sys.argv[2]
with open(rec_path, "w", encoding="utf-8") as fh:
    json.dump({
        "schema": 1, "tool": "1.0.0", "check": "expensive-gate",
        "fingerprint": "0" * 64, "exit": 0,
        "outputs": ["out/artefact.txt"], "output_paths": ["out/artefact.txt"],
        "output_paths_hash": "0" * 64, "stdout": "a verdict about something else\n",
        "written_at": "1970-01-01T00:00:00Z",
    }, fh)
PY
expect_exit 1 "3d. a record whose FINGERPRINT field lies -> RE-RUN (not honour its exit)" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

t5="$(new_tree tree5)"
manifest_for "$t5" "$cache_a"
printf 'expensive gate: 1 fact learned\n' >"$t5/check.out"
"$PY" "$FP" --root "$t5" --cache-dir "$cache_a" record \
  --manifest "$t5/manifest.json" --exit 0 --stdout-file "$t5/check.out"
rec5="$cache_a/expensive-gate.json"

"$PY" - "$rec5" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    rec = json.load(fh)
rec["tool"] = "0.0.1-ancient"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(rec, fh)
PY
expect_exit 3 "4a. a record from ANOTHER kit version -> REFUSED, not honoured" \
  "$PY" "$FP" --root "$t5" --cache-dir "$cache_a" lookup --manifest "$t5/manifest.json"

"$PY" - "$rec5" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    rec = json.load(fh)
rec["tool"] = "1.0.0"
rec["schema"] = 99
with open(path, "w", encoding="utf-8") as fh:
    json.dump(rec, fh)
PY
expect_exit 3 "4b. a record from a FOREIGN record schema -> REFUSED by name" \
  "$PY" "$FP" --root "$t5" --cache-dir "$cache_a" lookup --manifest "$t5/manifest.json"

t6="$(new_tree tree6)"
manifest_for "$t6" "$cache_a"
"$PY" "$FP" --root "$t6" --cache-dir "$cache_a" record \
  --manifest "$t6/manifest.json" --exit 1 --stdout-file "$t6/VERSION"
expect_exit 1 "5a. a recorded FAILURE is never a HIT" \
  "$PY" "$FP" --root "$t6" --cache-dir "$cache_a" lookup --manifest "$t6/manifest.json"

manifest_for "$t6" "$cache_a"
first="$("$PY" "$FP" fingerprint "$t6/manifest.json")"
sleep 1
manifest_for "$t6" "$cache_a"
second="$("$PY" "$FP" fingerprint "$t6/manifest.json")"
if [ "$first" = "$second" ]; then
  report PASS "6a. two manifests over one tree agree — nothing time-derived is hashed"
else
  report FAIL "6a. the fingerprint moved between two reads of an unchanged tree"
fi

if "$PY" "$FP" --root "$t6" --cache-dir "$cache_a" manifest \
     --check "holey" --inputs "in.txt,not-a-file.txt" \
     >/dev/null 2>"$work/.err"; then
  report FAIL "6b. a manifest naming an absent input was BUILT — that is a hole that hashes"
else
  if grep -q 'does not exist' "$work/.err"; then
    report PASS "6b. a manifest naming an absent input is REFUSED, named, never hashed"
  else
    report FAIL "6b. refused for the wrong reason: $(head -1 "$work/.err")"
  fi
fi

t7="$(new_tree tree7)"
"$PY" "$FP" --root "$t7" --cache-dir "$cache_a" manifest \
  --check "under-declared" \
  --inputs "VERSION" \
  --outputs "out/artefact.txt" \
  --command "run the expensive thing" \
  --out "$t7/manifest.json"
printf 'expensive gate: 1 fact learned\n' >"$t7/check.out"
"$PY" "$FP" --root "$t7" --cache-dir "$cache_a" record \
  --manifest "$t7/manifest.json" --exit 0 --stdout-file "$t7/check.out"

"$PY" - "$t7/in.txt" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    body = fh.read()
with open(path, "w", encoding="utf-8") as fh:
    fh.write(body.replace("1.0", "9.9", 1))
PY

if "$PY" "$FP" --root "$t7" --cache-dir "$cache_a" lookup \
     --manifest "$t7/manifest.json" >/dev/null 2>&1; then
  report PASS "7a. GREEN CONTROL: an UNDECLARED input change still HITs — the skip CAN lie"
  report PASS "7b. ...so the rollout's real risk is an incomplete declaration, and this"
  report PASS "       suite is what catches one when it is written"
else
  report FAIL "7a. GREEN CONTROL FAILED TO REPRODUCE. A cache that cannot be made to lie"
  report FAIL "       by an incomplete declaration has something else wrong with it, and"
  report FAIL "       this file was written on the assumption that it could."
fi

echo
printf 'fingerprint_test: %d passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]