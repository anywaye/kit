#!/usr/bin/env bash
#
# kit's proof that `tests/fingerprint.py` cannot lie.
#
#   bash tests/fingerprint_test.sh
#
# WHAT THIS IS FOR
#
#   A cache is a device for handing back a verdict somebody already reached. The
#   only thing standing between that and a machine that reports PASS for work it
#   never did is the set of conditions under which it is allowed to hand one
#   back. Nothing in `fingerprint.py` can make a check green on its own, and
#   this file is what makes that claim checkable rather than a sentence in a
#   docstring.
#
#   So every claim below is a COUNTEREXAMPLE: a cache that says HIT, and a tree
#   where the honest answer is "run it". A test suite that only proves the happy
#   path has proved that the happy path works, which is the one thing a cache is
#   guaranteed to do.
#
# THE FOUR WAYS, AND WHY THESE FOUR
#
#   1. outputs deleted, fingerprint unchanged  -> RE-RUN. This is P0-4's second
#      clause and the one that matters most: "same hash AND outputs still on
#      disk". A cache that honours the hash and ignores the disk returns green
#      for a tree whose work was thrown away, and the failure is silent because
#      every number in the log looks right.
#   2. one byte of one declared input changed -> RE-RUN. The whole mechanism,
#      in its smallest possible unit. A cache keyed on mtime would pass this
#      only when the clock moved, and a cache keyed on the file NAME would never
#      pass it at all.
#   3. a corrupt or truncated record           -> RE-RUN, distinctly, and never
#      a crash. Corrupt is given its own exit code precisely so that it is not
#      indistinguishable from a cold cache in the logs.
#   4. a record from another kit version       -> REFUSED, by name. Honoring it
#      means honoring a verdict about a check that may no longer exist.
#
# AND THE GREEN CONTROL, which is the sharpest line in the file
#
#   Proof 9 does NOT prove the cache is correct. It proves the cache CAN BE
#   WRONG: a manifest that forgets to declare the file the check reads returns
#   HIT after that file changes, and hands back the old PASS. That is not a bug
#   in `fingerprint.py` — a fingerprint can only be as complete as its
#   declaration, and no amount of hashing repairs an omission. It is a fact about
#   the mechanism, and it is the reason the rollout in the report is a list of
#   declarations to be written rather than a flag to be flipped.

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

# expect_exit <wanted> <label> <command...> -- the whole grammar of this file.
# A test that only asserted "it did not crash" would pass on a cache that always
# says MISS, which is not a cache.
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

# A throwaway tree with the two files the declarations below name. Not a copy
# of kit: this file is about the mechanism, and a fixture that were the real
# tree would make every failure ambiguous between "the cache is wrong" and "the
# tree is wrong".
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

# manifest_for <tree> <cache> -- the declaration every proof below shares, so
# that a proof is a change to ONE variable and not a rediscovery of the setup.
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

# ---------------------------------------------------------------------------
# 0. the warm-up, and the arithmetic everything else is measured against
# ---------------------------------------------------------------------------
t1="$(new_tree tree1)"
manifest_for "$t1" "$cache_a"

# No record yet: a cold cache is a MISS and nothing else. If this is the only
# thing the mechanism does, it is not a cache, it is a slower way to run checks.
expect_exit 1 "0a. a cold cache is a MISS, not a crash" \
  "$PY" "$FP" --root "$t1" --cache-dir "$cache_a" lookup --manifest "$t1/manifest.json"

# Run the check. It passed, and it printed evidence — which is what the record
# has to keep, because a later caller replays it instead of re-deriving it.
printf 'expensive gate: 1 fact learned\n' >"$t1/check.out"
"$PY" "$FP" --root "$t1" --cache-dir "$cache_a" record \
  --manifest "$t1/manifest.json" --exit 0 --stdout-file "$t1/check.out"

expect_exit 0 "0b. the identical second lookup is a HIT" \
  "$PY" "$FP" --root "$t1" --cache-dir "$cache_a" lookup --manifest "$t1/manifest.json"

# The replay, which is P0-1's "a later caller READS THE RECORD". Without it a
# hit is indistinguishable from a check that ran and printed nothing, and the
# evidence this gate exists to produce disappears from every run after the
# first.
if "$PY" "$FP" --root "$t1" --cache-dir "$cache_a" lookup \
     --manifest "$t1/manifest.json" 2>/dev/null | grep -q '1 fact learned'; then
  report PASS "0c. a HIT replays the recorded evidence, so the run still shows it"
else
  report FAIL "0c. a HIT replayed no evidence — the run would go silent after the first pass"
fi

# ---------------------------------------------------------------------------
# 1. outputs deleted, fingerprint unchanged -> RE-RUN  (P0-4's second clause)
# ---------------------------------------------------------------------------
t2="$(new_tree tree2)"
manifest_for "$t2" "$cache_a"
printf 'expensive gate: 1 fact learned\n' >"$t2/check.out"
"$PY" "$FP" --root "$t2" --cache-dir "$cache_a" record \
  --manifest "$t2/manifest.json" --exit 0 --stdout-file "$t2/check.out"

# The manifest is untouched; nothing about the inputs moved. The ONLY change is
# that the work is gone. A cache that honoured the hash here would return a
# green for a tree that has never been checked — which is exactly the failure
# P0-4 exists to prevent, and exactly the one a reader cannot see.
rm -f "$t2/out/artefact.txt"
expect_exit 1 "1a. SAME fingerprint, outputs DELETED -> RE-RUN (the second clause)" \
  "$PY" "$FP" --root "$t2" --cache-dir "$cache_a" lookup --manifest "$t2/manifest.json"

# And the distinct one: the output REPLACED by a DIFFERENT SET of files. Still
# the same fingerprint, still not a hit — the record promised a set of paths and
# a different set is on disk. The declaration is the glob `out/*` rather than a
# literal path, and that is the whole of the difference: a literal output names
# ONE file and is therefore blind to a file that appeared beside it, which is
# moon's `hash_output_globs` being a hash of globs for the same reason.
mkdir -p "$t2/out"
printf ' artefact v1\n' >"$t2/out/artefact.txt"
printf 'a second file appeared\n' >"$t2/out/unexpected.txt"
expect_exit 1 "1b. SAME fingerprint, a DIFFERENT set of outputs -> RE-RUN" \
  "$PY" "$FP" --root "$t2" --cache-dir "$cache_a" lookup --manifest "$t2/manifest.json"
rm -f "$t2/out/unexpected.txt"

# And once the work is back, the hit returns. Proving the miss was about the
# outputs and not about the mechanism having wedged itself.
expect_exit 0 "1c. outputs restored -> HIT again, so 1a was the outputs and not a wedge" \
  "$PY" "$FP" --root "$t2" --cache-dir "$cache_a" lookup --manifest "$t2/manifest.json"

# ---------------------------------------------------------------------------
# 2. one byte of one declared input -> RE-RUN
# ---------------------------------------------------------------------------
t3="$(new_tree tree3)"
manifest_for "$t3" "$cache_a"
manifest_before="$work/before.json"
cp "$t3/manifest.json" "$manifest_before"
printf 'expensive gate: 1 fact learned\n' >"$t3/check.out"
"$PY" "$FP" --root "$t3" --cache-dir "$cache_a" record \
  --manifest "$t3/manifest.json" --exit 0 --stdout-file "$t3/check.out"

expect_exit 0 "2a. warm, before the edit" \
  "$PY" "$FP" --root "$t3" --cache-dir "$cache_a" lookup --manifest "$t3/manifest.json"

# ONE BYTE. Same length, same name, same mtime granularity that a cache keyed on
# time would be blind to within the same second. This is the smallest change
# that can invalidate a fingerprint and it is the one that has to work.
"$PY" - "$t3/in.txt" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    body = fh.read()
# 1.0 -> 2.0 : one character, in the middle, same file length.
with open(path, "w", encoding="utf-8") as fh:
    fh.write(body.replace("1.0", "2.0", 1))
PY
manifest_for "$t3" "$cache_a"
expect_exit 1 "2b. ONE BYTE of a declared input changed -> RE-RUN" \
  "$PY" "$FP" --root "$t3" --cache-dir "$cache_a" lookup --manifest "$t3/manifest.json"

# `diff` is how a human finds WHICH input moved, and it is the reason the
# manifest is a list rather than an opaque hash. The tree is UNCHANGED here, so
# anything `diff` reports is the edit and nothing else.
if "$PY" "$FP" --root "$t3" --cache-dir "$cache_a" diff \
     "$manifest_before" "$t3/manifest.json" | grep -q 'in.txt'; then
  report PASS "2c. diff names the input that changed, in one line"
else
  report FAIL "2c. diff did not name in.txt — a reader would have no way to find the cause"
fi

# The ORDER of the declarations is not the content of the manifest. A cache that
# changed its mind because a list was written in a different order would miss on
# a reformat, which is the cheapest possible way to make a cache useless.
"$PY" "$FP" --root "$t3" --cache-dir "$cache_a" manifest \
  --check "expensive-gate" --inputs "VERSION,in.txt" --outputs "out/*" \
  --command "run the expensive thing" --out "$work/reordered.json"
if [ "$("$PY" "$FP" fingerprint "$work/reordered.json")" = \
     "$("$PY" "$FP" fingerprint "$t3/manifest.json")" ]; then
  report PASS "2d. input ORDER does not change the fingerprint (a reformat is not a change)"
else
  report FAIL "2d. reordering the declared inputs changed the fingerprint"
fi

# ---------------------------------------------------------------------------
# 3. a corrupt or truncated record -> RE-RUN, distinctly, and no crash
# ---------------------------------------------------------------------------
t4="$(new_tree tree4)"
manifest_for "$t4" "$cache_a"
printf 'expensive gate: 1 fact learned\n' >"$t4/check.out"
"$PY" "$FP" --root "$t4" --cache-dir "$cache_a" record \
  --manifest "$t4/manifest.json" --exit 0 --stdout-file "$t4/check.out"
rec="$cache_a/expensive-gate.json"
[ -f "$rec" ] || report FAIL "3a. SETUP: no record was written to $rec"

# Truncated mid-object. This is what an interrupted write leaves behind, and it
# is a HIT-shaped hole: the file exists, the name is right, and everything about
# the log says the cache was consulted.
head -c 40 "$rec" >"$rec.trunc" && mv "$rec.trunc" "$rec"
expect_exit 2 "3a. TRUNCATED record -> RE-RUN, with its own code and no traceback" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

# Not JSON at all — binary garbage, or an editor that mangled it.
printf '\000\001\002not json at all\377\n' >"$rec"
expect_exit 2 "3b. BINARY record -> RE-RUN, not a crash" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

# Valid JSON, wrong shape. A record that parses but says something the reader
# does not understand is the case a `json.load` alone waves through.
printf '{"schema":1,"tool":"1.0.0","check":"expensive-gate","exit":"zero"}\n' >"$rec"
expect_exit 2 "3c. WELL-FORMED but wrong-typed record -> RE-RUN" \
  "$PY" "$FP" --root "$t4" --cache-dir "$cache_a" lookup --manifest "$t4/manifest.json"

# Valid JSON, every field the right type, and the fingerprint field LIES: it
# claims to describe the manifest in front of it while the recorded outputs and
# exit belong to something else. Nothing in a JSON parse can see this, so the
# comparison has to be explicit — and it has to come before the outputs check,
# or a hand-mangled record is honoured on the strength of the paths it names.
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

# ---------------------------------------------------------------------------
# 4. a record from another kit version -> REFUSED, by name
# ---------------------------------------------------------------------------
t5="$(new_tree tree5)"
manifest_for "$t5" "$cache_a"
printf 'expensive gate: 1 fact learned\n' >"$t5/check.out"
"$PY" "$FP" --root "$t5" --cache-dir "$cache_a" record \
  --manifest "$t5/manifest.json" --exit 0 --stdout-file "$t5/check.out"
rec5="$cache_a/expensive-gate.json"

# Another kit VERSION, everything else identical — same fingerprint, same
# outputs, a green record. This is the record a shared cache accumulates the
# moment two checkouts of different kits meet, and it is the one that must
# never be honoured: the check it describes may not be the check that runs now.
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

# A record from a FUTURE schema, under THIS kit's version. A schema bump is a
# wholesale invalidation and it has to be one even when the bytes still parse.
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

# ---------------------------------------------------------------------------
# 5. a FAILED run is never a hit
# ---------------------------------------------------------------------------
# moon's first conjunct, and the reason a cache of failures would make the next
# run red for a reason nobody can reproduce. Recorded here so the property is
# something the suite proves rather than something the reader is asked to trust.
t6="$(new_tree tree6)"
manifest_for "$t6" "$cache_a"
"$PY" "$FP" --root "$t6" --cache-dir "$cache_a" record \
  --manifest "$t6/manifest.json" --exit 1 --stdout-file "$t6/VERSION"
expect_exit 1 "5a. a recorded FAILURE is never a HIT" \
  "$PY" "$FP" --root "$t6" --cache-dir "$cache_a" lookup --manifest "$t6/manifest.json"

# ---------------------------------------------------------------------------
# 6. determinism, and a declaration with a hole in it
# ---------------------------------------------------------------------------
# No timestamp in the hashed material: two manifests built minutes apart from
# the same tree are the same bytes. This is `cafe lock`'s rule and the reason a
# diff between two manifests is a diff between two trees.
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

# A declared input that is not there. It RAISES rather than hashing a hole,
# because a hole hashes identically on every run and would make the check
# permanently uncacheable with nothing anywhere to say why.
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

# ---------------------------------------------------------------------------
# 7. THE GREEN CONTROL — the skip is provable able to be WRONG
# ---------------------------------------------------------------------------
#
# Everything above proves the mechanism enforces what it was told. This proves
# the thing that actually matters about a cache: that it is capable of handing
# back a green that is not true, and that the only thing standing between it and
# a lie is the completeness of the declaration.
#
# So here the declaration is INCOMPLETE on purpose: it does not name `in.txt`,
# the file the "check" actually reads. `in.txt` then changes, the fingerprint
# does not move, and the cache hands back the old PASS. Exit 0. That is a lie,
# produced by a correct implementation of the contract.
#
# It is here for the rollout. A cache wired to a check whose declaration omits
# one input file is not a cache that is "probably fine" — it is a green light
# wired to a switch that was never connected, and the failure surfaces as a
# broken build somewhere else entirely.
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

# The check's real input changes. Nothing else does.
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

# ---------------------------------------------------------------------------
echo
printf 'fingerprint_test: %d passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]