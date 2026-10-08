# REPORT-m167-kit-upstream-01 — customer adoption and upstream contribution path

## What this packet is for

Make Kit legible to external customers: how to build their own app on
Kit without losing local work on update, how to receive Kit updates as
a reviewable PR, and how to send improvements back — without copies of
Kit's tree, subtrees, submodules, forced updates, or sync bots.

## What was delivered (3 commits, this worktree only, not pushed)

- `f71f02b` — `docs/customer-upstream.md` (new), README link from
  "How a service repo adopts kit", CHANGELOG entry.
- `3da6ca9` — `tests/customer_upstream_check.sh` (new, 5 cases) wired
  into `tests/validate.sh` static phase; honest wording on the
  Renovate regex verification.
- `a39f419` — README "What is in here" table row; CHANGELOG names
  the check.

## The two update cases (kept separate in the doc)

1. **Application source** — Jumpstart Pro model, commands verified
   against `/Users/kaka/Code/any/moon/refs/jumpstart-pro/README.md`:
   clone, `git remote rename origin upstream`, add own `origin`,
   later `git fetch upstream` + `git merge upstream/main`. Merge-only;
   your commits survive by construction.
2. **Kit platform pieces** — reuse existing mechanisms only: reusable
   workflows *called* via `uses:` (never copied), lint configs fetched
   at run time via `kit-lint-ref`, stack fetched by `bin/dev` from
   committed `kit.ref`, copied files re-copied by hand (staleness
   stated as the documented cost). New opt-in **pin contract**: one
   shared full SHA across `uses:` + `kit-lint-ref` + `kit.ref`, never
   a branch, never `@master` for customers.
3. **Contribute back** — fork + branch + PR to canonical Kit, gate
   green first, CHANGELOG entry required.

## The smallest update mechanism, and its honest limits

- Opt-in `renovate.json` block in the doc: built-in `github-actions`
  manager covers `uses:` pins; two `regex` customManagers cover
  `kit.ref` and `kit-lint-ref` via `github-tags` on `cafaye/kit`.
- Verified here: JSON parses (`json.load`); both patterns match the
  §2 pin shapes (JS `(?<name>)` → Python `(?P<name>)` translation,
  anchors/character classes identical, sample-SHA match demonstrated).
- **Not verified**: no end-to-end Renovate run observed — stated in
  the doc.
- **No PRs flow today by design**: `git tag` is empty (verified
  2026-10-08) and no release workflow exists; `github-tags` yields
  nothing until the first `v*` tag. Nothing published, tagged, or
  released in this packet; no on-push release workflow added.

## Evidence

- `bash tests/customer_upstream_check.sh` → 5/5 PASS.
- `bash tests/validate.sh --only=customer_upstream` → PASS (filtered;
  37 others excluded, banner printed — not a full-gate claim).
- Red direction proved both standalone and through the gate: first
  run failed on the caveat needle (line-wrapped phrase, fixed to a
  wrap-proof needle); a planted `uses:`-deletion failed the pin-sites
  case in both harnesses; doc restored byte-identical and green.
- `bash -n` + `shellcheck -S warning` clean on the new/edited scripts.
- Full `tests/validate.sh` and Docker **not run** per the brief;
  manager gates the merged tree.

## Manager follow-ups (decisions, not defects)

1. **Tags/releases**: `v<semver>` pin shape and Renovate PRs activate
   on Kit's first tag. When tags exist, the §5 caveat must be
   rewritten — `customer_upstream_check` goes red on the stale caveat
   by design (SKIPs once tags exist; revisit by hand).
2. **External access**: `uses:` resolves in private repos *inside the
   org*. Customers outside need Kit public or granted. The doc tells
   readers not to assume fetch works until announced.
3. **Fleet stays on `@master`**: the pin contract is customer-only;
   no internal caller was touched.
