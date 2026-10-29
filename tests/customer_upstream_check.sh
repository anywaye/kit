#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/customer-upstream.md"
README="$ROOT/README.md"

pass=0
fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf 'FAIL %s\n' "$1"
  shift
  [ "$#" -eq 0 ] || printf '     %s\n' "$@"
  fail=$((fail + 1))
}

[ -f "$DOC" ] || { no 'docs/customer-upstream.md  (the customer path exists)' \
  'the file is absent; the README links a page that is not there.'; }

if [ -f "$DOC" ]; then
  if grep -q 'docs/customer-upstream\.md' "$README"; then
    ok 'README  (links the customer upstream path)'
  else
    no 'README  (links the customer upstream path)' \
      'README.md never mentions docs/customer-upstream.md, so the page exists and no reader finds it.'
  fi

  missing=''
  for site in 'kit\.ref' 'kit-lint-ref' 'uses:'; do
    grep -q "$site" "$DOC" || missing="$missing $site"
  done
  if [ -z "$missing" ]; then
    ok 'customer-upstream  (names all three pin sites: uses:, kit-lint-ref, kit.ref)'
  else
    no 'customer-upstream  (names all three pin sites: uses:, kit-lint-ref, kit.ref)' \
      "the page never names:$missing — a pin contract with a hole in it."
  fi

  if grep -qiE 'subtree|submodule|forced updates|force-push' "$DOC"; then
    ok 'customer-upstream  (names the forbidden update mechanisms)'
  else
    no 'customer-upstream  (names the forbidden update mechanisms)' \
      'the page promises preserved modifications without naming what is forbidden.'
  fi

  if grep -q 'Kit is public' "$DOC"; then
    ok 'customer-upstream  (states Kit is public and externally fetchable)'
  else
    no 'customer-upstream  (states Kit is public and externally fetchable)' \
      'the page never says Kit is public — a reader assumes access needs a grant.'
  fi

  block="$ROOT/.tmp-customer-renovate.json"
  awk '/^```json$/{p=1;next} p&&/^```$/{p=0;exit} p{print}' "$DOC" >"$block"
  if [ ! -s "$block" ]; then
    no 'customer-upstream  (carries a fenced ```json Renovate block)' \
      'no ```json block found; §3 promises a block that is not there.'
  elif command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$block" 2>/dev/null; then
      ok 'customer-upstream  (the Renovate block parses as JSON)'
    else
      no 'customer-upstream  (the Renovate block parses as JSON)' \
        'the fenced block is not JSON; a customer copying it gets a Renovate error, not a PR.'
    fi
  else
    printf 'SKIP customer-upstream  (python3 not installed — the Renovate block was parsed by nothing)\n'
  fi

  if [ -s "$block" ] && command -v python3 >/dev/null 2>&1; then
    if python3 - "$block" <<'PY' 2>/dev/null; then
import json, re, sys
block = json.load(open(sys.argv[1]))
managers = {m["managerFilePatterns"][0]: m for m in block["customManagers"]}
sha = "9" * 40
kitref = managers["/(^|/)kit\\.ref$/"]
(pat,) = kitref["matchStrings"]
rx = re.compile(pat.replace("(?<", "(?P<"))
m = rx.search(sha + "\n")
assert m and m.group("currentDigest") == sha, "kit.ref pattern misses a bare SHA"
lint = managers["/ci/[^/]*\\.ya?ml$/"]
(pat,) = lint["matchStrings"]
rx = re.compile(pat.replace("(?<", "(?P<"))
line = "  kit-lint-ref: '%s' # master" % sha
m = rx.search(line)
assert m and m.group("currentDigest") == sha, "kit-lint-ref pattern misses the SHA"
assert m.group("currentValue") == "master", "kit-lint-ref pattern loses the branch"
PY
      ok 'customer-upstream  (every matchStrings matches its §2 pin shape)'
    else
      no 'customer-upstream  (every matchStrings matches its §2 pin shape)' \
        'a pattern no longer matches the pin it watches; Renovate would silently watch nothing.'
    fi
  elif [ ! -s "$block" ]; then
    no 'customer-upstream  (every matchStrings matches its §2 pin shape)' \
      'no block to test; the parse case above already failed.'
  else
    printf 'SKIP customer-upstream  (python3 not installed — the patterns were matched by nothing)\n'
  fi
  rm -f "$block"

  if grep -q 'github-digest' "$DOC"; then
    if grep -q 'github-tags' "$DOC"; then
      no 'customer-upstream  (tracks github-digest, never github-tags)' \
        'the page still names github-tags — PRs would wait on tags that need not exist.'
    else
      ok 'customer-upstream  (tracks github-digest, never github-tags)'
    fi
  else
    no 'customer-upstream  (tracks github-digest, never github-tags)' \
      'the page never names the github-digest datasource its §3 depends on.'
  fi

  if grep -q 'uses:.*# master' "$DOC" && grep -q 'kit-lint-ref:.*# master' "$DOC"; then
    ok 'customer-upstream  (the YAML pin examples carry their # master comments)'
  else
    no 'customer-upstream  (the YAML pin examples carry their # master comments)' \
      'a pin example lost its branch comment — Renovate would ignore that line.'
  fi

  stale=''
  for needle in 'first tag' 'once tags exist' 'manager decision' 'announced' 'explicitly granted' 'release workflow'; do
    case "$needle" in
    'release workflow')
      grep -q "$needle" "$DOC" && stale="$stale [$needle]"
      ;;
    *)
      grep -qi "$needle" "$DOC" && stale="$stale [$needle]"
      ;;
    esac
  done
  if [ -z "$stale" ]; then
    ok 'customer-upstream  (no retracted tag/access caveat has returned)'
  else
    no 'customer-upstream  (no retracted tag/access caveat has returned)' \
      "the old §5 is back wearing new words:$stale"
  fi

  if grep -q 'bash tests/validate\.sh' "$DOC"; then
    no 'customer-upstream  (asks narrow verification; CI owns the full gate)' \
      'the page hands customers the full gate — Kit CI has a docs fast path and owns validate.sh.'
  elif grep -q 'git diff --check' "$DOC" && grep -q 'CI owns the full gate' "$DOC"; then
    ok 'customer-upstream  (asks narrow verification; CI owns the full gate)'
  else
    no 'customer-upstream  (asks narrow verification; CI owns the full gate)' \
      'the page neither shows narrow verification nor names CI as the gate owner.'
  fi

  if grep -q 'Sending an application fix upstream' "$DOC" \
    && grep -q 'fork + PR' "$DOC" \
    && grep -qiE 'branding.*stay|stay.*downstream' "$DOC" \
    && grep -q 'upstream.*remote' "$DOC"; then
    if grep -q 'PRs to Kit itself are the separate' "$DOC"; then
      ok 'customer-upstream  (separates app fixes upstream from Kit PRs in §4)'
    else
      no 'customer-upstream  (separates app fixes upstream from Kit PRs in §4)' \
        'the §1 app-fix path never says Kit PRs are the separate §4 path — the two directions blur.'
    fi
  else
    no 'customer-upstream  (separates app fixes upstream from Kit PRs in §4)' \
      '§1 never names the app-upstream path (fork + PR off the named upstream remote, branding stays downstream).'
  fi
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'FAIL: customer_upstream_check — %d of %d case(s) failed.\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'PASS: customer_upstream_check — %d case(s), the customer path is linked and agrees.\n' "$pass"
