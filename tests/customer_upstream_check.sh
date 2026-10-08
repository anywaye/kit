#!/usr/bin/env bash
# tests/customer_upstream_check.sh — the customer path is linked, names every
# pin it promises, and carries a Renovate block that parses and matches.
#
#   bash tests/customer_upstream_check.sh
#
# WHY THIS EXISTS
#
#   m167 adds docs/customer-upstream.md: the page that tells an external
#   customer how to adopt Kit (SHA pins with a `# master` branch comment on
#   the YAML lines, bare SHA in kit.ref, one reviewable PR per bump), how
#   Kit updates reach them as Renovate PRs via the github-digest datasource
#   (no tags needed — Kit is public), how to send improvements back
#   (fork + PR, narrow local verification, CI owns the full gate), and what
#   is NOT proven yet (no end-to-end Renovate run observed). Every half rots
#   the same way: the README stops linking the page, the page stops naming
#   a pin site Kit actually has, the fenced Renovate block stops parsing,
#   its patterns stop matching the pin shapes, the digest shape regresses
#   to github-tags, the ref comments go missing, the retracted tag/access
#   caveats return, or the contribution section reinstates the full gate as
#   a customer pre-commit step — and every one of those is a green gate on
#   a page that misleads.
#
# WHAT IS AND IS NOT PROVEN HERE
#   Proven: the page exists and is reachable from the README; it names all
#   three pin sites (`uses:`, `kit-lint-ref`, `kit.ref`); it states Kit is
#   public; its fenced ```json block parses (stdlib `json.load`, skipped
#   loudly without python3) and every `matchStrings` in it matches the §2
#   pin shape it claims to watch (same translation check, sample lines
#   asserted on the captured groups, not just the exit status); the block
#   tracks the `github-digest` datasource and nothing else; the YAML pin
#   examples carry their `# master` branch comments; the retracted
#   tag/access caveats are absent; the contribution path asks for narrow
#   local verification and names CI — not the customer — as the owner of
#   the full gate; it separates §1 app fixes upstream (fork + PR to the
#   canonical app, branding stays downstream) from §4 Kit PRs; and it
#   forbids the history-rewriting mechanisms by name.
#   NOT proven: that a Renovate run produces PRs (none observed; the page
#   says the managers are configured but live behavior is unverified, and
#   the grouping batch is unverified too).
#
# WHAT THIS DELIBERATELY DOES NOT PIN DOWN
#   Manager decisions that can change are not asserted: the branch name
#   (`master` today), the group name, and the dep name appear in the page
#   but no case fails if they are renamed — the cases guard the durable
#   facts (public, digest-not-tags, comments present, caveats absent, gate
#   ownership), not the values a later packet may move.
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

  # Kit is public — verified 2026-10-08 via `gh repo view`. A fixed-text
  # assertion, no network: the page must SAY it, so no reader is left
  # assuming a grant is needed.
  if grep -q 'Kit is public' "$DOC"; then
    ok 'customer-upstream  (states Kit is public and externally fetchable)'
  else
    no 'customer-upstream  (states Kit is public and externally fetchable)' \
      'the page never says Kit is public — a reader assumes access needs a grant.'
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

  # Every matchStrings in the block must MATCH the §2 pin shape it claims
  # to watch — asserted on the captured groups, not the exit status. A red
  # run that matched nothing would be the same confusion the page warns
  # about: an error-shaped success. kit.ref is a bare SHA (bin/dev reads
  # the whole line as the ref); kit-lint-ref carries its branch comment.
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
lint = managers["/\\.github/workflows/[^/]*\\.ya?ml$/"]
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

  # The digest shape: github-digest tracks the branch, and nothing in the
  # block may ask for tags. A github-tags datasource needs v* tags that
  # need not exist; asserting its absence is what keeps the "no tag
  # needed" promise true.
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

  # The YAML pin examples must carry their branch comments: a bare SHA on
  # a uses: line is one Renovate ignores by default, and a bare SHA is the
  # only shape the old (wrong) page showed.
  if grep -q 'uses:.*# master' "$DOC" && grep -q 'kit-lint-ref:.*# master' "$DOC"; then
    ok 'customer-upstream  (the YAML pin examples carry their # master comments)'
  else
    no 'customer-upstream  (the YAML pin examples carry their # master comments)' \
      'a pin example lost its branch comment — Renovate would ignore that line.'
  fi

  # The retracted caveats must not return: no tag wait, no access wait, no
  # manager decision pending. Each needle is the invalid CLAIM, not a
  # common word, so ordinary prose cannot trip it.
  stale=''
  for needle in 'first tag' 'once tags exist' 'manager decision' 'announced' 'explicitly granted' 'release workflow'; do
    case "$needle" in
    'release workflow')
      # The phrase survives only inside core/release/release.yml-style paths
      # outside this page; here any occurrence is the old §5 talking.
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

  # Contribution guidance: narrow local verification, CI owns the full
  # gate. Telling customers to run the whole gate before every commit is
  # the Kit-CI-docs-fast-path contradiction this case exists to catch.
  # The needle is the RUN instruction (`bash tests/validate.sh`), not the
  # name: the page must be able to say CI runs the gate.
  if grep -q 'bash tests/validate\.sh' "$DOC"; then
    no 'customer-upstream  (asks narrow verification; CI owns the full gate)' \
      'the page hands customers the full gate — Kit CI has a docs fast path and owns validate.sh.'
  elif grep -q 'git diff --check' "$DOC" && grep -q 'CI owns the full gate' "$DOC"; then
    ok 'customer-upstream  (asks narrow verification; CI owns the full gate)'
  else
    no 'customer-upstream  (asks narrow verification; CI owns the full gate)' \
      'the page neither shows narrow verification nor names CI as the gate owner.'
  fi

  # Two upstream directions, kept apart: §1 sends general app fixes to
  # the canonical APP (fork + PR off the named `upstream` remote,
  # branding stays downstream); §4 sends Kit improvements to canonical
  # Kit. A page merging them tells a customer to PR branding to Kit or
  # app fixes to Kit's repo — both wrong. The needles are the §1
  # subsection header and its stay-downstream sentence, not common
  # words, so ordinary prose cannot trip them.
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
