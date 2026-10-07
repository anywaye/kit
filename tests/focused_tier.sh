#!/usr/bin/env bash
#
# focused_tier.sh — the tier focused proof: family syntax + disclosure.
#
#   bash tests/focused_tier.sh
#
# WHAT IT RUNS. The per-file parse for every file under templates/tier/,
# using the SAME commands as the gate's artifact-parse loop in
# tests/validate.sh (same tool, same flags, same skip-when-missing rule):
#
#   go (*.go)        gofmt -e  (the gate's telemetry gofmt; not reported twice there)
#   python (*.py)    compile(), never py_compile (no __pycache__ side effects)
#   ruby (*.rb)      ruby -c
#   elixir (*.ex)    Code.string_to_quoted/1 (stdlib parse, offline)
#   rust (*.rs)      rustc --test, then --list (parse + strongest offline check)
#   typescript       SKIP, loud: node --check cannot read TypeScript (gate's words)
#   README.md        presence is its check (markdown has no syntax to be wrong about)
#   skip-allowlist   SKIP, loud: the gate has no parser for it either
#
# WHAT IT DOES NOT RUN. Everything else in tests/validate.sh: the other
# families' parses, telemetry, observability, lint, tenancy, substrate,
# chart publish. The tail of this script says so by name, because a focused
# run reported as a platform-test pass is the defect this packet exists to
# remove. The full proof is `bash tests/validate.sh` with no flags.
#
# Offline and dependency-free beyond the language toolchains themselves:
# no venv, no network, no docker. A missing toolchain is a loud SKIP for
# that file — never a silent pass, never a failure of the template.

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
