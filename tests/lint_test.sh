#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "lint_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
. "$ROOT/tests/bootstrap.sh"
kit_activate_mise
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/kit-lint-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

passes=0
skips=0
failures=0

have() { command -v "$1" >/dev/null 2>&1; }

pass() {
  printf '      PASS lint_test: %s\n' "$1"
  passes=$((passes + 1))
}

skip() {
  printf '      SKIP lint_test: %s — %s\n' "$1" "$2"
  skips=$((skips + 1))
}

fail() {
  printf '      FAIL lint_test: %s\n' "$1"
  printf '%s\n' "$2" | head -12 | sed 's/^/             /'
  failures=$((failures + 1))
}

run() {
  local name="$1" want="$2" out ec=0
  shift 2
  out=$("$@" 2>&1) || ec=$?
  case "$want:$ec" in
    red:0)
      fail "$name" "$out"
      ;;
    red:*)
      pass "$name"
      ;;
    green:0)
      pass "$name"
      ;;
    green:*)
      fail "$name" "$out"
      ;;
  esac
}

printf -- '-- lint_test: a config nobody runs is a comment\n'

KIT_GOLANGCI="$ROOT/lint/golangci.yml"
KIT_RUBOCOP="$ROOT/lint/rubocop.yml"
KIT_ESLINT="$ROOT/lint/eslint.config.mjs"
KIT_YAMLLINT="$ROOT/lint/yamllint.yml"

section_go() {
  if have golangci-lint; then
  g="$WORK/gosvc"
  mkdir -p "$g/pkg"
  cat >"$g/go.mod" <<'EOF'
module example.com/kitlinttest

go 1.24
EOF
  cat >"$g/pkg/a.go" <<'EOF'
package pkg

import "os"

// A helper to recieve a file handle and hand back its size.
func Size(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer func() {
		if cerr := f.Close(); cerr != nil {
			return
		}
	}()
	info, err := f.Stat()
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}
EOF

  if ! gofmt -w "$g/pkg/a.go" 2>/dev/null; then
    skip 'go: the fixture could not be formatted' 'gofmt not installed'
  elif ! (cd "$g" && go build ./... >/dev/null 2>&1); then
    skip 'go: the fixture does not build' "$(cd "$g" && go build ./... 2>&1 | head -3)"
  else
    run 'go: kit config REJECTS a misspelling the default set accepts' red \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run "--config=$KIT_GOLANGCI" ./pkg
    run 'go: the SAME file is GREEN without --config (the default set has no misspell)' green \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run ./pkg
    mkdir -p "$g/pkg/clean"
    cat >"$g/pkg/clean/b.go" <<'EOF'
package clean

import "os"

// Size reports the size of the file at path.
func Size(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer func() {
		if cerr := f.Close(); cerr != nil {
			return
		}
	}()
	info, err := f.Stat()
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}
EOF
    gofmt -w "$g/pkg/clean/b.go"
    run 'go: kit config ACCEPTS a clean file (strict, not broken)' green \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run "--config=$KIT_GOLANGCI" ./pkg/clean

    cp -R "$g" "$WORK/gosvc-local"
    printf '%s\n' '---' 'version: "2"' 'linters:' '  disable:' '    - misspell' \
      >"$g/.golangci.yml"
    printf '%s\n' '---' 'version: "2"' 'linters:' '  disable:' '    - misspell' \
      >"$WORK/gosvc-local/.golangci.yml"
    run 'go: a repo-root .golangci.yml disabling misspell is INERT under --config' red \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run "--config=$KIT_GOLANGCI" ./pkg
    run 'go: ...and that same local file DOES govern the run when no --config is passed' green \
      env -C "$WORK/gosvc-local" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run ./pkg
    rm -f "$g/.golangci.yml"
  fi
else
  skip 'go: golangci-lint is not installed' 'the go lint proof did not run'
  skip 'go: golangci-lint is not installed' 'the go control did not run'
  skip 'go: golangci-lint is not installed' 'the go negative control did not run'
fi
}

section_ruby() {
  if have rubocop; then
  r="$WORK/rubysvc"
  mkdir -p "$r/lib"
  cat >"$r/lib/widget.rb" <<'EOF'
# frozen_string_literal: true

class Widget
  def initialize(value)
    @value = value
  end

  def total
    running = @value
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running += 1
    running
  end
end
EOF
  RUBY_OK=0
  if ! ruby -c "$r/lib/widget.rb" >/dev/null 2>&1; then
    RUBY_OK=0
    skip 'ruby: the fixture does not parse' "$(ruby -c "$r/lib/widget.rb" 2>&1 | head -2)"
  else
    RUBY_OK=1
    LEN=$("$PY" - "$r/lib/widget.rb" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"def total\n(.*?)\n  end", src, re.S)
body = [ln for ln in m.group(1).splitlines() if ln.strip() and not ln.strip().startswith("#")]
print(len(body))
PY
)
    if [ "$LEN" -lt 12 ] || [ "$LEN" -gt 15 ]; then
      skip 'ruby: the fixture no longer straddles the threshold' \
        "method body is $LEN lines; it must be >10 (rubocop default) and <=15 (kit)"
    elif [ "$RUBY_OK" -eq 1 ]; then
      run 'ruby: a 13-line method is GREEN under kit config (Max 15)' green \
        rubocop --format simple --only Metrics/MethodLength \
        --config "$KIT_RUBOCOP" "$r/lib/widget.rb"
      run 'ruby: the SAME method is RED on rubocop defaults (Max 10) — so kit config was read' red \
        rubocop --format simple --only Metrics/MethodLength \
        --force-default-config "$r/lib/widget.rb"
    fi
  fi
else
  skip 'ruby: rubocop is not installed' 'the rubocop proof did not run'
  skip 'ruby: rubocop is not installed' 'the rubocop control did not run'
fi
}

section_node() {
  if have node && have npm; then
  e="$WORK/eslintsvc"
  mkdir -p "$e/src" "$e/fixtures" "$e/.kit/lint"
  cat >"$e/package.json" <<'EOF'
{
  "name": "kit-eslint-fixture",
  "version": "0.0.0",
  "private": true,
  "type": "module"
}
EOF
  cat >"$e/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "noEmit": true
  },
  "include": ["src"]
}
EOF
  cat >"$e/src/a.ts" <<'EOF'
export function add(a: number, b: number): number {
  if (a == b) {
    return a + b;
  }
  return b;
}
EOF
  cp "$KIT_ESLINT" "$e/.kit/lint/eslint.config.mjs"

  cat >"$e/fixtures/without-kit-rules.config.mjs" <<'EOF'
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

// kit/lint/eslint.config.mjs with its `rules` block removed and nothing else
// changed. eqeqeq is in that block and in neither recommended set, so this file
// must pass and kit's must fail on the same input.
export default tseslint.config(
  { ignores: ['fixtures/**', '.kit/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    files: ['**/*.ts'],
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
  },
);
EOF

  if ! (cd "$e" && timeout 900 npm install --silent --no-audit --no-fund \
    --no-save eslint@^9 @eslint/js@^9 typescript-eslint@^8 typescript@^5 \
    >"$e/install.log" 2>&1); then
    skip 'node: eslint could not be installed for the fixture' \
      "$(tail -2 "$e/install.log" 2>/dev/null | tr '\n' ' ')"
  else
    run 'node: the control is GREEN — kit config minus its rules block accepts `==`' green \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/fixtures/without-kit-rules.config.mjs' ./src"
    run 'node: kit config REJECTS `==` (eqeqeq: error) — so the config was read' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/.kit/lint/eslint.config.mjs' ./src"
    mkdir -p "$WORK/unrelated"
    run 'node: the same lint from a CWD that cannot reach the project exits non-zero (so working-directory is load-bearing)' red \
      sh -c "cd '$WORK/unrelated' && '$e/node_modules/.bin/eslint' --config '$e/fixtures/without-kit-rules.config.mjs' '$e/src'"
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/.kit/lint/eslint.config.mjs" . 2>&1); then
      :
    fi
    if printf '%s\n' "$out" | grep -q '\.kit/lint/'; then
      fail "node: the .kit/** ignore keeps kit's own config out of the lint" "$out"
    else
      pass "node: the .kit/** ignore keeps kit's own config out of the lint"
    fi
    mkdir -p "$WORK/eslint-outside"
    cp "$KIT_ESLINT" "$WORK/eslint-outside/eslint.config.mjs"
    run 'node: the SAME config BESIDE the repo cannot resolve @eslint/js (so kit must be checked out INSIDE)' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$WORK/eslint-outside/eslint.config.mjs' ./src"

    cat >"$e/tsconfig.mts.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "noEmit": true
  },
  "include": ["src", "*.mts"]
}
EOF
    mv "$e/tsconfig.mts.json" "$e/tsconfig.json"
    cat >"$e/vite.config.mts" <<'EOF'
const limit = 10;

export default { limit: limit == 10 };
EOF
    sed "s#'\*\*/\*\.{js,mjs,cjs,ts,tsx,mts,cts}'#'**/*.{js,mjs,cjs,ts,tsx}'#" \
      "$e/.kit/lint/eslint.config.mjs" >"$e/fixtures/narrow-glob.config.mjs"
    run 'node: kit config lints a root-level .mts file (the glob covers what recommendedTypeChecked can lint)' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/.kit/lint/eslint.config.mjs' ./vite.config.mts"
    run 'node: ...and the SAME file under the PRE-FIX glob is the crash instead, not a finding (so the glob is what fixed it)' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/fixtures/narrow-glob.config.mjs' ./vite.config.mts"
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/fixtures/narrow-glob.config.mjs" ./vite.config.mts 2>&1); then
      :
    fi
    case "$out" in
      *"requires type information"*)
        pass 'node: the pre-fix glob dies on the type-information error, and the fixed glob reports eqeqeq instead'
        ;;
      *)
        fail 'node: the pre-fix glob dies on the type-information error, and the fixed glob reports eqeqeq instead' "$out"
        ;;
    esac
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/.kit/lint/eslint.config.mjs" ./vite.config.mts 2>&1); then
      :
    fi
    case "$out" in
      *"eqeqeq"*) pass 'node: the fixed glob reports a real finding on the .mts file, rather than making it unlintable' ;;
      *) fail 'node: the fixed glob reports a real finding on the .mts file, rather than making it unlintable' "$out" ;;
    esac
    sed "s#projectService: true#projectService: { allowDefaultProject: ['*.mts'] }#" \
      "$e/.kit/lint/eslint.config.mjs" >"$e/fixtures/adp-at-caller.config.mjs"
    sed "s#\(parserOptions: { projectService: { allowDefaultProject: \['\*\.mts'\] }, \)tsconfigRootDir: [^}]*#\1tsconfigRootDir: import.meta.dirname#" \
      "$e/fixtures/adp-at-caller.config.mjs" >"$e/fixtures/adp-at-kit.config.mjs"
    if node --check "$e/fixtures/adp-at-kit.config.mjs" >/dev/null 2>&1; then
      pass 'node: the tsconfigRootDir control parses as JS (so it can fail for the reason it is here to fail)'
    else
      fail 'node: the tsconfigRootDir control parses as JS (so it can fail for the reason it is here to fail)' \
        "$(node --check "$e/fixtures/adp-at-kit.config.mjs" 2>&1 | head -3)"
    fi
    if cmp -s "$e/fixtures/adp-at-caller.config.mjs" "$e/fixtures/adp-at-kit.config.mjs"; then
      fail 'node: the tsconfigRootDir control is a DISTINCT file (so the pair below is not one run twice)' \
        "both fixtures are byte-identical, so \`tsconfigRootDir\` was not found in kit's config to replace"
    else
      pass 'node: the tsconfigRootDir control is a DISTINCT file (so the pair below is not one run twice)'
    fi
    cat >"$e/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "noEmit": true
  },
  "include": ["src"]
}
EOF
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/fixtures/adp-at-caller.config.mjs" ./vite.config.mts 2>&1); then
      :
    fi
    case "$out" in
      *eqeqeq*)
        pass 'node: allowDefaultProject resolves against the CALLER workspace, so a caller root .mts is LINTED and its == found'
        ;;
      *)
        fail 'node: allowDefaultProject resolves against the CALLER workspace, so a caller root .mts is LINTED and its == found' "$out"
        ;;
    esac
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/fixtures/adp-at-kit.config.mjs" ./vite.config.mts 2>&1); then
      :
    fi
    case "$out" in
      *"does not match"*)
        pass 'node: ...and the SAME config rooted at KIT`S directory cannot match a caller file (so tsconfigRootDir is load-bearing)'
        ;;
      *)
        fail 'node: ...and the SAME config rooted at KIT`S directory cannot match a caller file (so tsconfigRootDir is load-bearing)' "$out"
        ;;
    esac
  fi
else
  skip 'node: node or npm is not installed' 'the eslint control did not run'
  skip 'node: node or npm is not installed' 'the eslint proof did not run'
  skip 'node: node or npm is not installed' 'the working-directory requirement did not run'
  skip 'node: node or npm is not installed' 'the .kit/** ignore did not run'
  skip 'node: node or npm is not installed' 'the checkout-location constraint did not run'
  skip 'node: node or npm is not installed' 'the .mts/.cts glob width did not run'
  skip 'node: node or npm is not installed' 'the pre-fix control for the .mts glob did not run'
  skip 'node: node or npm is not installed' 'the fixed glob reporting a finding did not run'
  skip 'node: node or npm is not installed' 'the tsconfigRootDir/allowDefaultProject resolution did not run'
  skip 'node: node or npm is not installed' 'the tsconfigRootDir control being distinct did not run'
  skip 'node: node or npm is not installed' 'the tsconfigRootDir control parsing did not run'
fi
}

section_yaml() {
  if kit_bootstrap_console_script yamllint yamllint "$ROOT"; then
  y="$WORK/yamlsvc"
  mkdir -p "$y"
  "$PY" - "$y/bad.yml" <<'PY'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("rules:\n  enabled: yes\n")
PY
  run 'yaml: kit config REJECTS a truthy value outside {true,false,on}' red \
    "$CONSOLE" --strict -c "$KIT_YAMLLINT" "$y/bad.yml"
  run 'yaml: the SAME file is only a WARNING without --strict (exit 0), so --strict is load-bearing' green \
    "$CONSOLE" -c "$KIT_YAMLLINT" "$y/bad.yml"
else
  skip 'yaml: yamllint could not be bootstrapped' 'the yamllint proof did not run'
  skip 'yaml: yamllint could not be bootstrapped' 'the yamllint control did not run'
fi
}

printf '\n'
section_go >"$WORK/go.log" 2>&1 &
section_ruby >"$WORK/ruby.log" 2>&1 &
section_node >"$WORK/node.log" 2>&1 &
section_yaml >"$WORK/yaml.log" 2>&1 &
wait
cat "$WORK/go.log" "$WORK/ruby.log" "$WORK/node.log" "$WORK/yaml.log"
if grep -q 'FAIL lint_test:' "$WORK/go.log" "$WORK/ruby.log" "$WORK/node.log" "$WORK/yaml.log"; then
  echo "FAIL: lint_test — at least one assertion did not hold (see the section logs above)."
  exit 1
fi
if grep -q 'SKIP lint_test:' "$WORK/go.log" "$WORK/ruby.log" "$WORK/node.log" "$WORK/yaml.log"; then
  echo "FAIL: lint_test — assertion(s) skipped for a missing toolchain."
  echo "      A skipped lint proof is not a proof. Install the toolchain and re-run:"
  echo "        golangci-lint, rubocop, node+npm — all three are exercised above."
  exit 1
fi
echo "PASS: lint_test — every linter ran with kit's config and rejected a bad file."
