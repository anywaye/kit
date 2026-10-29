#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/templates/tier"

pass=0
fail=0
skip=0

have() { command -v "$1" >/dev/null 2>&1; }

line() { printf '%s %s\n' "$1" "$2"; }

ok() { line PASS "$1"; pass=$((pass + 1)); }
no() { line FAIL "$1"; fail=$((fail + 1)); }
sk() { line SKIP "$1"; skip=$((skip + 1)); }

[ -d "$DIR" ] || { no "templates/tier/  (missing directory)"; }

for f in "$DIR"/go/*.go; do
  [ -f "$f" ] || continue
  p="${f#"$ROOT"/}"
  if have gofmt; then
    if gofmt -e "$f" >/dev/null; then ok "$p  (gofmt parses)"; else no "$p  (gofmt parses)"; fi
  else
    sk "$p  (gofmt not installed)"
  fi
done

for f in "$DIR"/python/*.py; do
  [ -f "$f" ] || continue
  p="${f#"$ROOT"/}"
  if have python3; then
    if python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"; then
      ok "$p  (compile)"
    else
      no "$p  (compile)"
    fi
  else
    sk "$p  (python3 not installed)"
  fi
done

for f in "$DIR"/ruby/*.rb; do
  [ -f "$f" ] || continue
  p="${f#"$ROOT"/}"
  if have ruby; then
    if ruby -c "$f" >/dev/null; then ok "$p  (ruby -c)"; else no "$p  (ruby -c)"; fi
  else
    sk "$p  (ruby not installed)"
  fi
done

for f in "$DIR"/elixir/*.ex; do
  [ -f "$f" ] || continue
  p="${f#"$ROOT"/}"
  if have elixir; then
    if elixir -e 'case Code.string_to_quoted(File.read!(hd(System.argv()))) do
               {:error, e} -> IO.puts("syntax: #{inspect e}"); System.halt(1)
               {:ok, _} -> :ok
             end' "$f"; then
      ok "$p  (Code.string_to_quoted!)"
    else
      no "$p  (Code.string_to_quoted!)"
    fi
  else
    sk "$p  (elixir not installed)"
  fi
done

for f in "$DIR"/rust/*.rs; do
  [ -f "$f" ] || continue
  p="${f#"$ROOT"/}"
  if have rustc; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/kit-tier-rust.XXXXXX")"
    if rustc --test --edition 2021 -o "$tmp" "$f" && "$tmp" --list >/dev/null; then
      ok "$p  (rustc --test)"
    else
      no "$p  (rustc --test)"
    fi
    rm -f "$tmp"
  else
    sk "$p  (rustc not installed)"
  fi
done

for f in "$DIR"/bun/*.ts "$DIR"/node/*.ts; do
  [ -f "$f" ] || continue
  p="${f#"$ROOT"/}"
  sk "$p  (node --check cannot read TypeScript; needs a type-stripping parser)"
done

if [ -f "$DIR/README.md" ]; then
  ok "templates/tier/README.md  (markdown; presence is its check)"
else
  no "templates/tier/README.md  (missing)"
fi

if [ -f "$DIR/skip-allowlist" ]; then
  sk "templates/tier/skip-allowlist  (no parser for this file type)"
else
  no "templates/tier/skip-allowlist  (missing)"
fi

printf 'FOCUSED=tier  pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
printf 'NOT RUN: telemetry, observability, lint, tenancy, substrate, chart publish, and every other family — focused tier proof only, not a platform-test pass. Full proof: bash tests/validate.sh\n'
[ "$fail" -eq 0 ]
