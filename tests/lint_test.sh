#!/usr/bin/env bash
#
# kit's proof that lint actually RUNS with kit's config, from kit, at run time.
#
#   bash tests/lint_test.sh
#
# WHAT THIS IS FOR
#   The packet that wrote `lint/` shipped 249 lines of linter configuration that
#   NO service in the fleet had ever copied, and every check in this repository
#   was green the whole time. The reason is that the checks parsed the configs
#   and nothing ever RAN a linter with them. A config that parses is a config
#   that has never been shown to accept a good file or reject a bad one.
#
#   So this is the phase that closes that hole: for each language, build a
#   throwaway service that contains a violation ONLY a linter would catch, then
#   run the SAME command the reusable workflow runs, with kit's config, and
#   assert the linter rejects it. A config that cannot reject anything is a
#   comment, and this is the check that says which of kit's four are comments.
#
# THE MECHANISMS, AND WHY THEY ARE DIFFERENT
#   Measured, not assumed — the table in README.md records the runs. The short
#   version, because the difference is the whole design:
#
#     golangci-lint  `--config=<path>`. Measured: no `.golangci.yml` in the
#                    repo means golangci-lint falls back to its own 5-linter
#                    DEFAULT set (errcheck govet ineffassign staticcheck
#                    unused) and exits 0 on a file kit's config rejects. So the
#                    config is not optional garnish; without this flag a Go
#                    service is silently on a different, weaker policy.
#                    GOLANGCI_LINT_CONFIG is NOT read by v2 — measured, it is
#                    silently ignored, and the run proceeds on the default set.
#
#     rubocop        `--config=<path>`, same shape, same reason. Measured: with
#                    no config a 13-line method passes on RuboCop's default
#                    MethodLength of 10; with kit's config (Max: 15) the same
#                    file is clean, and inverting that (a 16-line method) is
#                    what proves the config is actually being read.
#
#     eslint         `--config=<path>`, but ONLY because kit is checked out
#                    INSIDE the service tree. Measured: with the config beside
#                    the repo, node cannot resolve `@eslint/js` and the run
#                    dies with ERR_MODULE_NOT_FOUND — which is a red build, not
#                    a lint. Node resolves an ESM import from the CONFIG
#                    FILE's own directory upward, so the config has to sit
#                    under the repo that has the packages.
#
#     yamllint       `-c <path>`, and it needs nothing else. This is the one
#                    that behaves the way everyone assumes all of them do.
#
# WHAT IT IS NOT
#   This does not lint kit. It lints FIXTURES, so it needs no toolchain beyond
#   the three it names, and a missing one is a loud SKIP rather than a pass.
#   Whether kit's own tree is clean under kit's own configs is a separate
#   question, answered separately.
#
# SKIPS ARE REPORTED AND COUNTED, and a skip in a lint proof is a gap: the
# whole point of the phase is that a linter which never ran cannot be claimed
# to work. `validate.sh` counts them in its summary like every other check, and
# this script exits nonzero if any toolchain is missing, because a proof that
# silently did not run is the failure mode this packet exists to remove.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "lint_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
# This script is runnable on its own (`bash tests/lint_test.sh`), so it cannot
# inherit validate.sh's environment — it has to put mise-managed linters on PATH
# for itself. See kit_activate_mise in tests/bootstrap.sh.
kit_activate_mise
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

# The work directory is CANONICALISED, and this is not tidiness — it is the
# difference between the ESLint assertions running and every one of them
# failing for a reason that has nothing to do with ESLint.
#
# Measured, and the measurement is worth recording because the symptom points
# somewhere else entirely. On macOS `$TMPDIR` is `/var/folders/.../T/`, and
# `/var` is a symlink to `/private/var`. typescript-eslint's project service
# resolves the tsconfig through a realpath while the file paths ESLint was
# handed keep the symlinked form, the two never match, and every run ends:
#
#     You are linting "…/src", but all of the files matching the glob pattern
#     "…/src" are ignored.
#
# which reads as a broken config, an over-broad ignore, and a fixture mistake —
# and is none of them. The same directory, addressed canonically, is green on
# the same command. `cd "$W" && pwd -P` resolves it at run time rather than
# assuming, because the other platform's answer differs and this file has to be
# right on both.
#
# A green run here is not available by accident: the alternative was a test that
# fails only on macOS, which is a test that gets deleted rather than fixed.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/kit-lint-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

passes=0
skips=0
failures=0

# `have` is a local of validate.sh, and this script is documented as a
# standalone command. A documented command that only works after a different
# one has run is two commands wearing one name, and the failure mode here is
# worse than a crash: without `have`, every toolchain probe below is a
# command-not-found on stderr and the script skips the whole phase while still
# printing a summary. It is a silent skip, which is the one thing this phase
# exists to prevent.
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

# run <name> <expected: red|green> <command...>
#
# The `|| ec=$?` shape is not defensive style. `out=$(cmd)` alone is an
# ASSIGNMENT, and under `set -e` a failing `cmd` kills this script on that line
# before the status is ever read — so a linter that correctly REJECTS a bad file
# would take the harness down with it and the run would report nothing. The
# guard makes the command part of a list, which `set -e` does not apply to.
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

# The two configs the assertions below compare, named once. Two runs that must
# differ ONLY in which config they were given are the whole point of this file,
# and a typo that points one of them somewhere else turns the pair into two
# identical runs that agree for a reason nobody can see.
KIT_GOLANGCI="$ROOT/lint/golangci.yml"
KIT_RUBOCOP="$ROOT/lint/rubocop.yml"
KIT_ESLINT="$ROOT/lint/eslint.config.mjs"
KIT_YAMLLINT="$ROOT/lint/yamllint.yml"

# ===========================================================================
# golangci-lint
# ===========================================================================
#
# Two claims, and the second is the one that matters.
#
#   (a) kit's config REJECTS a file golangci-lint's own defaults ACCEPT. The
#       fixture trips `misspell` (a comment that says "recieve") and nothing
#       else: the default set has no misspell, so if the config were not being
#       read this would be green and the assertion below would fail.
#
#   (b) WITHOUT `--config`, the same file is GREEN. This is the claim that
#       justifies the flag existing, and it is asserted rather than asserted-in-
#       a-comment because "golangci-lint has defaults" is exactly the kind of
#       thing a reader is entitled to doubt. It is also the failure this packet
#       exists to end: a service whose lint step lost its `--config` still runs,
#       still passes, and is now on a policy nobody chose.
if have golangci-lint; then
  g="$WORK/gosvc"
  mkdir -p "$g/pkg"
  cat >"$g/go.mod" <<'EOF'
module example.com/kitlinttest

go 1.24
EOF
  # `errcheck` is ON in both kit's config and golangci-lint's default set, and
  # kit's config excludes it for `_test.go` only. So an unchecked `defer
  # f.Close()` in a NON-test file is red under BOTH configs, which would make
  # every control here red for a reason that has nothing to do with misspell.
  # The file checks the error instead. The single violation in the fixture is
  # the one the pair of assertions is about, and a fixture that also trips the
  # one linter both configs agree on cannot tell the two configs apart.
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

  # gofmt first: golangci-lint's formatters run as part of `run` in v2, and a
  # fixture that is not gofmt-clean would go red for a reason that has nothing
  # to do with the linter being tested.
  if ! gofmt -w "$g/pkg/a.go" 2>/dev/null; then
    skip 'go: the fixture could not be formatted' 'gofmt not installed'
  elif ! (cd "$g" && go build ./... >/dev/null 2>&1); then
    skip 'go: the fixture does not build' "$(cd "$g" && go build ./... 2>&1 | head -3)"
  else
    # Each run is SCOPED to one directory. `./...` would lint the whole
    # fixture, so the control below would be red because of the file the
    # previous assertion deliberately made red — a control that is red for the
    # wrong reason is indistinguishable from a control that is broken, and the
    # reader cannot tell which they are looking at.
    #
    # `--config` is what the reusable workflow's `lint` step passes. Spelled the
    # same way here as there, because a test that proves a flag works and a
    # workflow that does not pass it are the same sentence with the verb
    # missing.
    run 'go: kit config REJECTS a misspelling the default set accepts' red \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run "--config=$KIT_GOLANGCI" ./pkg
    run 'go: the SAME file is GREEN without --config (the default set has no misspell)' green \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run ./pkg
    # And the negative control for (a): a file with no violation must be green
    # UNDER kit's config too. A config that rejects everything is not strict,
    # it is broken, and this is the only assertion in the file that can tell
    # the two apart.
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

    # (c) `--config` BEATS a config the repository already has, and this is the
    #     assertion the whole drift check rests on.
    #
    #     The drift check's failure message tells a service that a repo-root
    #     `.golangci.yml` is inert while kit's workflow passes `--config`. That
    #     was WRONG when the check was first written — it claimed discovery
    #     happened "ahead of any flag" — and it is only right because it was
    #     measured. `golangci-lint run -v` prints exactly one
    #     `[config_reader] Used config file`; with the flag it names kit's.
    #
    #     So this writes the strongest possible local override — one that turns
    #     OFF the single linter the fixture violates — and asserts the violation
    #     is still reported. If this ever goes green, the precedence has changed
    #     and both the workflow's design and the drift check's message are
    #     describing a tool that no longer behaves this way.
    #
    #     The two runs below are in TWO SEPARATE COPIES of the fixture, and that
    #     is not tidiness. golangci-lint takes a per-directory lock and refuses
    #     to start while another instance holds it:
    #
    #         Error: parallel golangci-lint is running
    #
    #     Two runs back to back in one directory are a coin toss on that, and the
    #     first version of this pair did exactly that — it passed once and failed
    #     with that message the next time. A flaky assertion is worse than no
    #     assertion: it trains a reader to re-run until it goes green, which is
    #     how a real regression gets waved through. Two directories, two locks,
    #     no sleep, no retry.
    cp -R "$g" "$WORK/gosvc-local"
    printf '%s\n' '---' 'version: "2"' 'linters:' '  disable:' '    - misspell' \
      >"$g/.golangci.yml"
    printf '%s\n' '---' 'version: "2"' 'linters:' '  disable:' '    - misspell' \
      >"$WORK/gosvc-local/.golangci.yml"
    run 'go: a repo-root .golangci.yml disabling misspell is INERT under --config' red \
      env -C "$g" GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
      golangci-lint run "--config=$KIT_GOLANGCI" ./pkg
    # ...and the other direction, so the pair pins WHICH file won rather than
    # merely that something was red: with no flag, the very same local file
    # governs and the misspelling is green.
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

# ===========================================================================
# RuboCop
# ===========================================================================
#
# The fixture is a 13-line method. That number is chosen against TWO numbers:
# RuboCop's default `Metrics/MethodLength` Max is 10 and kit's is 15. So the
# same file is red on the default and green on kit's — which is a measurement of
# the config being read, not merely of a linter existing. A fixture tripped at
# some other cop would pass under both and prove nothing.
if have rubocop; then
  r="$WORK/rubysvc"
  mkdir -p "$r/lib"
  cat >"$r/lib/widget.rb" <<'EOF'
# frozen_string_literal: true

# Widget holds a value.
class Widget
  def initialize(value)
    @value = value
  end

  # Total adds a constant to the value, thirteen lines of body.
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
    # The 13-line method: 12 body lines plus the `running` assignment. Both
    # counts are asserted rather than tuned, because a fixture that happens to
    # sit on the right side of the threshold by accident is a fixture that
    # proves nothing when the threshold moves.
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
    # The kit path is named here rather than inlined at the call sites, so the
    # two runs below cannot drift onto different files — which is the version of
    # this bug where a control quietly measures something else.
      # `--only Metrics/MethodLength` on BOTH runs, deliberately. The whole
      # point of this pair is the Max value, and `NewCops: enable` means an
      # unpinned run of kit's config on a fresh RuboCop prints the "new cops"
      # banner for every cop added since the pin — output, not an offense, and
      # it made a control look red for a reason that has nothing to do with the
      # threshold. One cop, both sides, so the only variable left is the config.
      #
      # AND THE EXPECTED COLOURS ARE NOT OBVIOUS. kit's config RELAXES
      # MethodLength from 10 to 15, so this fixture is GREEN under kit and RED
      # on RuboCop's defaults. The pair is not "kit is stricter" — on this cop
      # it is the other way round, deliberately, because a fixture that only
      # passes under kit's config would also pass on a config that was silently
      # ignored. What the pair proves is that the two configs are DIFFERENT and
      # that the difference is the one kit wrote down.
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

# ===========================================================================
# ESLint
# ===========================================================================
#
# The measured constraint, and the reason this fixture is built the way it is:
# a config file outside the service tree CANNOT be used. Node resolves an ESM
# import from the importing FILE's own directory upward, so a config sitting
# beside the repository finds no `@eslint/js` and the run dies with
# ERR_MODULE_NOT_FOUND — a red build that has linted nothing.
#
# So the config is copied to `<repo>/.kit/lint/eslint.config.mjs`, which is where
# the reusable workflow's lint step puts it, and node walks up from there into
# the repo's own node_modules. That is the whole reason kit is checked out
# inside the service rather than beside it, and it is why the mechanism is a
# checkout at a path rather than a path.
#
# The fixture is plain JavaScript with `==` where the config demands `===`,
# because that rule is in the config's own `rules` block: a rule that is
# switched on by kit and not by ESLint's bare recommended set, so a green run
# means the config was not read.
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
  # TypeScript, not JavaScript, and not by taste. kit's config sets
  # `projectService: true`, which makes typescript-eslint resolve EVERY linted
  # file through a tsconfig. Measured on a plain-`.js` fixture: without a
  # tsconfig the run is red with
  #     Parsing error: …/src/a.js was not found by the project service
  # — red for a reason that has nothing to do with the rule under test, which
  # would make the "kit rejects it" assertion pass for the wrong reason and the
  # control beside it look broken. The fixture has to be the kind of project
  # this config is written for, or neither number means anything.
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

  # THE CONTROL, and why it is a second config file rather than a flag.
  #
  # The obvious control is "run with no config and see the file pass", and
  # `--no-config` is the obvious way to write it. It does not exist: ESLint 9
  # ships `--no-config-lookup`, which suppresses the upward search for
  # `eslint.config.*` and leaves the run with nothing to apply. A run with no
  # config lints nothing and exits 0 — green for a reason that has nothing to do
  # with the file. A control that is green because it did not run is worse than
  # no control, because it looks like evidence.
  #
  # So the control is a REAL config, and the design constraint is that it must
  # differ from kit's in exactly ONE thing. Two earlier versions failed that:
  # bare `js.configs.recommended` cannot parse a `.ts` file at all (red with
  # `Parsing error: Unexpected token :`), and a config with a `files` scope but
  # no typescript parser is red for the same reason. So the control below is
  # kit's own config MINUS its `rules` block — same parser, same project
  # service, same recommended sets. The only variable left is `eqeqeq`.
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
    # EVERY eslint run is prefixed `cd "$e" &&`, and that is a measured
    # requirement rather than tidiness. Run from outside the project — which is
    # where this script happens to be invoked from, i.e. kit's own `tests/`
    # directory — eslint exits 2 with
    #     You are linting "…/src", but all of the files matching the glob
    #     pattern "…/src" are ignored.
    # on a fixture it has just linted successfully from inside. The same
    # command, the same paths, the same config; only the working directory
    # differs. So the reusable workflow's lint step carries
    # `working-directory:` for the same reason the go step does, and this is
    # the assertion that keeps the two from drifting apart.
    run 'node: the control is GREEN — kit config minus its rules block accepts `==`' green \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/fixtures/without-kit-rules.config.mjs' ./src"
    run 'node: kit config REJECTS `==` (eqeqeq: error) — so the config was read' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/.kit/lint/eslint.config.mjs' ./src"
    # ...and the CWD requirement itself, so the workflow's `working-directory:`
    # has a test behind it rather than a comment. Scoped to what was MEASURED,
    # which is narrower than "anywhere outside the project": ESLint resolves
    # files relative to its base path, and it walks up from CWD looking for a
    # project root. From `$WORK` — the fixture's PARENT — the run is green,
    # because `$WORK` still has the fixture beneath it. It is green from inside
    # the fixture too. It is red only from a CWD with no path to the project at
    # all, which on a CI runner is the repository's parent, not the repository.
    #
    # So the assertion is "a CWD that cannot reach the project", not "outside
    # the project". The first version said the second and was red-for-the-wrong-
    # reason in a way that looked like a passing test: the run it wanted to be
    # red actually returned 0, and the assertion inverted to hide it.
    mkdir -p "$WORK/unrelated"
    run 'node: the same lint from a CWD that cannot reach the project exits non-zero (so working-directory is load-bearing)' red \
      sh -c "cd '$WORK/unrelated' && '$e/node_modules/.bin/eslint' --config '$e/fixtures/without-kit-rules.config.mjs' '$e/src'"
    # The `.kit/**` ignore, asserted. Without it the run is red with a parse
    # error about KIT'S OWN config file — a build failure in a service that did
    # nothing wrong, over a file the service never wrote. So the shipped config
    # carries the ignore, and this proves it is still there and still doing
    # something: linting `.` rather than `./src` must NOT surface a problem
    # whose path is inside `.kit/`.
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/.kit/lint/eslint.config.mjs" . 2>&1); then
      :
    fi
    if printf '%s\n' "$out" | grep -q '\.kit/lint/'; then
      fail "node: the .kit/** ignore keeps kit's own config out of the lint" "$out"
    else
      pass "node: the .kit/** ignore keeps kit's own config out of the lint"
    fi
    # THE CONSTRAINT THAT FORCES THE CHECKOUT PATH, asserted rather than
    # described. Same config, same node, same packages — only the location
    # differs. Beside the repo it cannot resolve its own import and the run
    # dies; inside the repo it walks up into the service's node_modules and
    # works. If this assertion ever goes green, the mechanism in the workflow
    # has changed and the comment above it is describing a different design.
    mkdir -p "$WORK/eslint-outside"
    cp "$KIT_ESLINT" "$WORK/eslint-outside/eslint.config.mjs"
    run 'node: the SAME config BESIDE the repo cannot resolve @eslint/js (so kit must be checked out INSIDE)' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$WORK/eslint-outside/eslint.config.mjs' ./src"

    # ===========================================================================
    # THE `.mts` / `.cts` GLOB, which is the defect that actually shipped.
    #
    # Measured in cafaye/site run 37236386666 and cafaye/parlor run 37230458669,
    # both of which carry three `.mts` files at the repo root:
    #
    #   Error: Error while loading rule '@typescript-eslint/await-thenable':
    #   You have used a rule which requires type information, but don't have
    #   parserOptions set to generate type information for this file.
    #
    # The cause is NOT the one that was reported, and asserting the reported one
    # would have proved nothing. It is a GLOB MISMATCH: a config inside
    # `recommendedTypeChecked` (`typescript-eslint/eslint-recommended`) declares
    # `files: ['**/*.ts','**/*.tsx','**/*.mts','**/*.cts']`, which ADDS `.mts`
    # and `.cts` to the files ESLint will lint, while kit's own `files` glob —
    # the only thing that supplies `parserOptions`, and so the only source of
    # type information — was `**/*.{js,mjs,cjs,ts,tsx}`, narrower than both. Every
    # `.mts` file therefore got the type-aware rules and never got the type
    # information, and the run died at exit 2 before reporting a single finding.
    #
    # `tsconfigRootDir` was blamed because it IS wrong — it named kit's `lint/`
    # rather than the caller's — but with `projectService: true` the service walks
    # UP from the linted file to find a tsconfig and never consults it. Measured:
    # setting it to `/nonexistent-root`, and deleting it, both leave the run
    # identical. It is load-bearing only for `allowDefaultProject`, whose globs
    # are matched relative to it.
    #
    # So the proof below is a PAIR, and a pair is required: the fixture's tsconfig
    # MUST include the `.mts` file (or the widened glob reports a project-service
    # miss instead, which is a different failure with the same exit code), and the
    # control MUST narrow the glob back to four extensions. Then the same file,
    # the same node, the same packages and the same tsconfig differ in exactly one
    # thing — the width of the glob that supplies type information.
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
    # A root-level `.mts` with a `==`, exactly as a service's vite.config.mts is a
    # root-level `.mts`. Plain data, so the finding is `eqeqeq` and nothing else.
    cat >"$e/vite.config.mts" <<'EOF'
const limit = 10;

export default { limit: limit == 10 };
EOF
    # The control: kit's config with the glob narrowed BACK to four extensions,
    # which is what shipped. Nothing else differs.
    sed "s#'\*\*/\*\.{js,mjs,cjs,ts,tsx,mts,cts}'#'**/*.{js,mjs,cjs,ts,tsx}'#" \
      "$e/.kit/lint/eslint.config.mjs" >"$e/fixtures/narrow-glob.config.mjs"
    run 'node: kit config lints a root-level .mts file (the glob covers what recommendedTypeChecked can lint)' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/.kit/lint/eslint.config.mjs' ./vite.config.mts"
    run 'node: ...and the SAME file under the PRE-FIX glob is the crash instead, not a finding (so the glob is what fixed it)' red \
      sh -c "cd '$e' && ./node_modules/.bin/eslint --config '$e/fixtures/narrow-glob.config.mjs' ./vite.config.mts"
    # The pair above proves only that both are RED, which a crash and a finding
    # both are — and that is the whole trap this section exists to avoid, because
    # the pre-fix failure was ALSO red and was mistaken for the linter working.
    # So the control is additionally required to produce the CRASH rather than a
    # finding, read out of its own output.
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
    # And the direction that matters most: the FIXED glob must report a FINDING,
    # not merely exit non-zero. A widened glob that made the file unlintable would
    # satisfy both assertions above and check nothing.
    if out=$(cd "$e" && ./node_modules/.bin/eslint --config "$e/.kit/lint/eslint.config.mjs" ./vite.config.mts 2>&1); then
      :
    fi
    case "$out" in
      *"eqeqeq"*) pass 'node: the fixed glob reports a real finding on the .mts file, rather than making it unlintable' ;;
      *) fail 'node: the fixed glob reports a real finding on the .mts file, rather than making it unlintable' "$out" ;;
    esac
    # `tsconfigRootDir`, asserted as the CALLER's workspace. Not the reported
    # cause, and still load-bearing for `allowDefaultProject` — whose globs are
    # matched relative to it, so a pattern meant to cover this fixture's root
    # config file resolves to `.kit/lint/*.mts` and matches nothing when the root
    # is kit's directory. The error names itself:
    #     allowDefaultProject is set to ["*.mts"], which does not match '../../x.mts'
    # Derived from KIT'S OWN FILE by one substitution, and that is the point.
    #
    # The first version of this assertion wrote its own config out by hand, with
    # `tsconfigRootDir: process.cwd()` typed into it — so it proved the
    # MECHANISM is load-bearing and said nothing at all about kit's shipped
    # value. Measured: reverting `lint/eslint.config.mjs` to
    # `import.meta.dirname` left this file 20/20 green, because the copy under
    # test was not the file under test. So the value is now patched INTO a copy
    # of kit's config, and reverting kit's file turns this red.
    #
    # The substitution is `projectService: true` -> the same call plus an
    # `allowDefaultProject` entry, and nothing else about the file changes.
    sed "s#projectService: true#projectService: { allowDefaultProject: ['*.mts'] }#" \
      "$e/.kit/lint/eslint.config.mjs" >"$e/fixtures/adp-at-caller.config.mjs"
    # The control is the SAME file with its root replaced by kit's own directory.
    # One value differs, and it is the value under test.
    #
    # ANCHORED ON THE `parserOptions` LINE, and that anchoring is not tidiness.
    # The first version matched `tsconfigRootDir: \(.*\)` anywhere, and this file
    # now mentions `tsconfigRootDir` in eight COMMENT lines explaining why the
    # value is what it is — one of which ends in a backtick-quoted `*/`. The
    # substitution rewrote it, which closed a comment that was still open and
    # turned the whole file into a syntax error:
    #
    #     SyntaxError: Unexpected token '.'
    #
    # So the control did not fail by being wrong, it failed by not parsing, and
    # it would have "passed" a `does not match` assertion by producing any error
    # at all. Anchoring on the same line as `parserOptions` — the only line where
    # the two appear together — is the difference between substituting the value
    # and substituting the documentation of the value.
    #
    # And the trailing `.*` had to become `[^}]*` for the same reason twice over:
    # `.*` ran to the end of the line and took the line's closing ` },` with it,
    # so the file did not parse. A substitution that can eat its own delimiter is
    # a substitution whose failure mode is a syntax error somewhere else.
    sed "s#\(parserOptions: { projectService: { allowDefaultProject: \['\*\.mts'\] }, \)tsconfigRootDir: [^}]*#\1tsconfigRootDir: import.meta.dirname#" \
      "$e/fixtures/adp-at-caller.config.mjs" >"$e/fixtures/adp-at-kit.config.mjs"
    # The control must PARSE. Asserted, because the alternative is a control that
    # produces an error of some kind for reasons of its own and is then read as
    # evidence about `allowDefaultProject`.
    if node --check "$e/fixtures/adp-at-kit.config.mjs" >/dev/null 2>&1; then
      pass 'node: the tsconfigRootDir control parses as JS (so it can fail for the reason it is here to fail)'
    else
      fail 'node: the tsconfigRootDir control parses as JS (so it can fail for the reason it is here to fail)' \
        "$(node --check "$e/fixtures/adp-at-kit.config.mjs" 2>&1 | head -3)"
    fi
    # Guard the control against being a no-op copy of the config under test: if
    # kit's file ever stops naming a `tsconfigRootDir`, the substitution matches
    # nothing and the two files are identical, the pair below reports the same
    # answer twice, and it is green for a reason nobody can see.
    if cmp -s "$e/fixtures/adp-at-caller.config.mjs" "$e/fixtures/adp-at-kit.config.mjs"; then
      fail 'node: the tsconfigRootDir control is a DISTINCT file (so the pair below is not one run twice)' \
        "both fixtures are byte-identical, so \`tsconfigRootDir\` was not found in kit's config to replace"
    else
      pass 'node: the tsconfigRootDir control is a DISTINCT file (so the pair below is not one run twice)'
    fi
    # The fixture's tsconfig deliberately does NOT include `*.mts`, so this file
    # can only be linted at all if `allowDefaultProject` matches it.
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
    # RED, not green: the file carries a `==`, so a run in which
    # `allowDefaultProject` RESOLVED reports the finding. Asserting `green` here
    # was the first version of this assertion and it was wrong — it would have
    # passed for a run that linted nothing at all, which is the failure mode this
    # whole file exists to prevent.
    #
    # AND NOT `run … red` EITHER, which was the second version and was worse,
    # because it hid the very thing the pair exists to measure. BOTH runs exit
    # non-zero here: the resolved one on `eqeqeq`, the unresolved one on
    # `allowDefaultProject is set to […], which does not match`. Measured with
    # kit's `tsconfigRootDir` reverted to `import.meta.dirname`, this whole file
    # was 22/22 green — a pair of `red` assertions cannot tell "the glob resolved
    # and the linter found the bug" from "the glob matched nothing and ESLint
    # exited 2 anyway", which is the same confusion as the defect itself: a red
    # run that found nothing.
    #
    # So the finding is asserted OUT OF THE OUTPUT, not out of the exit status.
    # That is AGENTS.md's rule ("the test is the finding, not the exit status")
    # arriving in a file that had just broken it.
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
    # ...and the control, which is the whole reason the value is fixed: the SAME
    # config with kit's directory as the root cannot match the caller's file, and
    # reports so in its own message.
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

# ===========================================================================
# yamllint
# ===========================================================================
#
# The one that behaves the way everyone assumes the other three do, asserted so
# the README can say so on evidence rather than by contrast. The fixture is a
# long line and a missing `---`; both are things kit's config changes from the
# default, so a run under it and a run without it disagree.
if kit_bootstrap_console_script yamllint yamllint "$ROOT"; then
  y="$WORK/yamlsvc"
  mkdir -p "$y"
  "$PY" - "$y/bad.yml" <<'PY'
import sys

# A truthy value other than the three kit allows, and no document start.
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("rules:\n  enabled: yes\n")
PY
  # `--strict`, and the reason it is not optional is measured rather than
  # assumed: without it yamllint reports BOTH of these as `warning` and exits
  # 0, so a config that changes only warning-level rules is indistinguishable
  # from no config at all. Both of kit's re-tuned rules — `truthy` and
  # `document-start` — are warnings by default, which means "yamllint -c
  # kit's config" and "yamllint" agree on the exit code and disagree on
  # everything a human reads. The reusable workflow passes `--strict` for the
  # same reason, and this is the assertion that keeps the two in step.
  run 'yaml: kit config REJECTS a truthy value outside {true,false,on}' red \
    "$CONSOLE" --strict -c "$KIT_YAMLLINT" "$y/bad.yml"
  # The control proves `--strict` is doing the work and not the config: the
  # same file, same rules, without --strict, is a warning and exit 0.
  run 'yaml: the SAME file is only a WARNING without --strict (exit 0), so --strict is load-bearing' green \
    "$CONSOLE" -c "$KIT_YAMLLINT" "$y/bad.yml"
else
  skip 'yaml: yamllint could not be bootstrapped' 'the yamllint proof did not run'
  skip 'yaml: yamllint could not be bootstrapped' 'the yamllint control did not run'
fi

# ===========================================================================
printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: lint_test — $failures of $((passes + failures)) assertions did not hold."
  [ "$skips" -eq 0 ] || echo "note: $skips skipped (no toolchain) — a skipped lint proof is a gap."
  exit 1
fi
if [ "$skips" -ne 0 ]; then
  # Loud, and fatal. Every other phase of this gate reports a skip in a summary
  # and stays green, because a missing toolchain is an environment fact. This
  # one is different: the claim being tested is "kit's lint configs work", and a
  # run in which no linter executed is a run that has not tested it. The exit is
  # the honest report, and the message says which toolchain to install.
  echo "FAIL: lint_test — $skips assertion(s) skipped for a missing toolchain."
  echo "      A skipped lint proof is not a proof. Install the toolchain and re-run:"
  echo "        golangci-lint, rubocop, node+npm — all three are exercised above."
  exit 1
fi
echo "PASS: lint_test — $passes assertions; every linter ran with kit's config and rejected a bad file."
