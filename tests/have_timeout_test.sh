#!/usr/bin/env bash
#
# have_timeout_test.sh — the gate's toolchain probes cannot re-enter the gate.
#
#   bash tests/have_timeout_test.sh
#
# WHAT IT PROVES. `have()` resolves its probe runner through `_timeout_bin()`
# (`runner="$(_timeout_bin ...)"`), so `_timeout_bin()` calling `have()` back
# is unbounded mutual recursion: each `$( )` nests a forked child of the
# same gate process, and `have`'s cache is assigned only after the recursion
# returns — i.e. never. That shape fork-bombed a focused-publish run into a
# 624-deep same-command process tree. This test fails if `_timeout_bin()`'s
# body ever names `have` again.
#
# WHAT IT READS. The function bodies only, cut by awk on the `name() {`
# ... `}` boundaries — not comments or help strings. Full-line comments are
# stripped before matching: the rule's own explanation names `have`, and a
# check a comment can falsify is not a check.
#
# WHAT IT NEVER DOES. It never sources or executes tests/validate.sh —
# executing any gate path is how the incident happened. Static text only,
# stdlib only, no venv, no network.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/tests/validate.sh"

fail=0

body_timeout="$(awk '/^_timeout_bin\(\)/,/^}$/' "$GATE")"
if [ -z "$body_timeout" ]; then
  printf 'FAIL: _timeout_bin() not found in tests/validate.sh\n' >&2
  fail=1
else
  code_only="$(printf '%s\n' "$body_timeout" | grep -v '^[[:space:]]*#' || true)"
  case "$code_only" in
    *have*)
      printf 'FAIL: _timeout_bin() names have — have() resolves its runner through _timeout_bin(), so this is unbounded mutual recursion (one forked gate child per $( ) level)\n' >&2
      printf '%s\n' "$code_only" | grep 'have' | sed 's/^/       /' >&2 || true
      fail=1
      ;;
    *)
      printf 'PASS: _timeout_bin() never calls have() (probes resolve by command -v)\n'
      ;;
  esac
fi

body_have="$(awk '/^have\(\)/,/^}$/' "$GATE")"
if [ -z "$body_have" ]; then
  printf 'FAIL: have() not found in tests/validate.sh\n' >&2
  fail=1
else
  printf 'PASS: have() present (its _timeout_bin use is the intended one direction)\n'
fi

[ "$fail" -eq 0 ]
