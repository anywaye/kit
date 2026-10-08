#!/usr/bin/env bash
# tests/customer_upstream_check.sh — the customer path is linked, names every
# pin it promises, and carries a Renovate block that parses.
#
#   bash tests/customer_upstream_check.sh
#
# WHY THIS EXISTS
#
#   m167 adds docs/customer-upstream.md: the page that tells an external
#   customer how to adopt Kit (pinned SHAs, one reviewable PR per bump),
#   how to send improvements back (fork + PR), and what is NOT promised
#   yet (no tags, no external access). All three halves rot the same way:
#   the README stops linking the page, the page stops naming a pin site
#   Kit actually has, the fenced Renovate block stops parsing, or the
#   no-tags caveat is deleted while `git tag` is still empty — and every
#   one of those is a green gate on a page that misleads.
#
# WHAT IS AND IS NOT PROVEN HERE
#   Proven: the page exists and is reachable from the README; it names all
#   three pin sites (`uses:`, `kit-lint-ref`, `kit.ref`); its fenced
#   ```json block parses (stdlib `json.load`, skipped loudly without
#   python3); it forbids the history-rewriting mechanisms by name; and
#   while Kit has no tags it says so.
#   NOT proven: that a Renovate run produces a PR (none observed; the
#   block is `github-tags`, which yields nothing until the first tag),
#   or that an external customer can fetch Kit (a manager decision, and
#   the page says that rather than promising it).
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

  # Agreement, not presence: the page promises one SHA across three sites,
  # so it must NAME all three. A page naming two is a contract with a hole.
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

  # The page forbids the mechanisms that destroy local work. If none is
  # named, the "preserve your modifications" promise is a sentence with no
  # mechanism behind it.
  if grep -qiE 'subtree|submodule|forced updates|force-push' "$DOC"; then
    ok 'customer-upstream  (names the forbidden update mechanisms)'
  else
    no 'customer-upstream  (names the forbidden update mechanisms)' \
      'the page promises preserved modifications without naming what is forbidden.'
  fi

  # The fenced ```json Renovate block must PARSE. Extracted with awk, not
  # grep: the verdict is the exit status of json.load on the block bytes.
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
  rm -f "$block"

  # While Kit has no tags, the page must SAY so. When the first tag
  # lands, this case goes red on purpose: the page then promises PRs
  # that have started flowing, and the caveat must be rewritten, not
  # silently left true.
  if [ -z "$(git -C "$ROOT" tag 2>/dev/null)" ]; then
    if grep -q 'git tag' "$DOC" && grep -q 'release workflow' "$DOC"; then
      ok 'customer-upstream  (states the no-tags caveat while no tags exist)'
    else
      no 'customer-upstream  (states the no-tags caveat while no tags exist)' \
        'Kit has no tags and the page no longer says so — it promises PRs nothing can produce.'
    fi
  else
    printf 'SKIP customer-upstream  (tags now exist — revisit the §5 caveat by hand)\n'
  fi
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'FAIL: customer_upstream_check — %d of %d case(s) failed.\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'PASS: customer_upstream_check — %d case(s), the customer path is linked and agrees.\n' "$pass"
