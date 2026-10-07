#!/usr/bin/env bash
#
# Two concurrent port-block selections with the SAME seed must not return the
# same block. No docker, no stack: this exercises the `--select-block` seam of
# tests/onecluster_test.sh only, which is the selection step two live
# onecluster runs execute before either has bound anything.
#
#   bash tests/onecluster_ports_race_test.sh
#
# WHY THIS EXISTS. `port_block_free` probes and then closes the sockets it
# opened, so between the probe and `bin/dev up` binding the block another run
# can take it — and the `$$ % 400` seed does not prevent two concurrent runs
# from starting at the same offset and both seeing the same block free.
# Measured 2026-10-07: a false-RED onecluster run on a tree whose files were
# absent from the onecluster path. The single-run test proves one run passes;
# that is exactly what did not catch it. This control starts two selections at
# the same time, with the same forced seed (the worst case), while each holds
# its claim for the bind window — and requires different blocks.
#
# IT CAN GO RED, AND THAT WAS MEASURED. Against the pre-claim selection loop
# (probe, no mkdir claim), two concurrent selectors forced to the same start
# offset both printed 15500. With the claim, the second skips the block the
# first holds and prints the next one.
#
# The claim directory is a per-run temp dir (KIT_ONECLUSTER_CLAIM_DIR), so this
# control never touches live runs' claims and live runs never touch its.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONE="$ROOT/tests/onecluster_test.sh"

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

[ -x "$ONE" ] || {
  fail "ports race: $ONE is not executable"
  exit 1
}

CLAIMS="$(mktemp -d "${TMPDIR:-/tmp}/kit-onecluster-race-claims.XXXXXX")"
cleanup() { rm -rf "$CLAIMS"; }
trap cleanup EXIT

export KIT_ONECLUSTER_CLAIM_DIR="$CLAIMS"
export KIT_ONECLUSTER_SEED=7
export KIT_ONECLUSTER_HOLD=10

bash "$ONE" --select-block >"$CLAIMS/a.out" 2>"$CLAIMS/a.err" &
bash "$ONE" --select-block >"$CLAIMS/b.out" 2>"$CLAIMS/b.err" &
wait

a_ec=0; b_ec=0
a_out="$(cat "$CLAIMS/a.out" 2>/dev/null)"
b_out="$(cat "$CLAIMS/b.out" 2>/dev/null)"
[ -s "$CLAIMS/a.out" ] || { a_ec=1; }
[ -s "$CLAIMS/b.out" ] || { b_ec=1; }

if [ "$a_ec" -ne 0 ] || [ "$b_ec" -ne 0 ]; then
  fail "ports race: a selector failed (a='${a_out:-<empty>}' b='${b_out:-<empty>}')"
  [ -s "$CLAIMS/a.err" ] && sed 's/^/   a-err: /' "$CLAIMS/a.err"
  [ -s "$CLAIMS/b.err" ] && sed 's/^/   b-err: /' "$CLAIMS/b.err"
  exit 1
fi

case "$a_out $b_out" in
  *[^0-9\ ]*)
    fail "ports race: non-numeric block selected (a='$a_out' b='$b_out')"
    exit 1
    ;;
esac

if [ "$a_out" = "$b_out" ]; then
  fail "ports race: two concurrent selections with the same seed shared block $a_out — the probe-then-bind race is open"
  exit 1
fi
pass "ports race: two concurrent selections with the same seed diverged ($a_out vs $b_out)"

if [ "$failures" -eq 0 ]; then
  exit 0
fi
exit 1
