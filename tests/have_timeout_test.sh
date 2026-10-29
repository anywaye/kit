#!/usr/bin/env bash

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
