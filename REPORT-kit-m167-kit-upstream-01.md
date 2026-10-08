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

---

## Continuation (2026-10-08) — corrections against actual upstreams

The three claims above were wrong, and this packet corrects them. No
other repository touched; worktree/branch unchanged.

### What was wrong

1. **External access.** `gh repo view cafaye/kit --json
   nameWithOwner,visibility,url` returned `visibility: PUBLIC` on
   2026-10-08 — Kit was already public. There was no access decision
   pending and nothing to announce.
2. **Renovate/tag path.** The `github-tags` config needed `v*` tags
   that did not exist (`git tag` empty), so the page promised PRs
   "from the first tag" — a decision it then waited on. Per
   Renovate's current `github-actions` manager docs, a SHA pin with a
   branch comment (`@<sha> # master`) routes to the `github-digest`
   datasource (non-semver refs fetch branches, exact versioning,
   digest-only updates); bare SHAs without the comment are disabled
   by default. No tag or release is needed — the update path works
   today.
3. **Contribution gate.** The page told customers to run
   `bash tests/validate.sh` before every commit. Kit CI has a docs
   fast path (`docs` route runs `git diff --check` and nothing else);
   the page now asks narrow local verification and names CI as the
   full-gate owner.

### What was delivered (2 commits, this worktree only, not pushed)

- `042dbfa` — rewrote `docs/customer-upstream.md` (§2 pin contract
  with `# master` comments + bare-`kit.ref` rationale read off
  `stack_ref`/`validate_ref` in `templates/bin/dev.sh`; §3
  `github-digest` Renovate block with `currentValueTemplate` for
  `kit.ref` and branch-capture for `kit-lint-ref`, plus a `groupName`
  batching rule stated as unverified; §4 narrow verification;
  §5 reduced to the one honest unverified claim) and rewrote
  `tests/customer_upstream_check.sh` (10 cases: linkage, three pin
  sites, forbidden mechanisms, Kit-is-public fixed text, JSON parse,
  matchStrings-vs-shape on captured groups, digest-not-tags,
  `# master` comments, retracted-caveat absence, gate ownership).
- `a54b677` — README table row + adoption section and the
  `## Unreleased` CHANGELOG entry rewritten to the corrected claims.

### Evidence (commands and actual output)

- `gh repo view cafaye/kit --json nameWithOwner,visibility,url` →
  `{"nameWithOwner":"cafaye/kit","url":"https://github.com/cafaye/kit","visibility":"PUBLIC"}`.
- `git tag | wc -l` → `0`, kept as a measurement only: with
  `github-digest` it no longer gates anything.
- `bash tests/customer_upstream_check.sh` → 10/10 PASS.
- `shellcheck -S warning tests/customer_upstream_check.sh` → clean;
  `bash -n` clean.
- Red probes (restored after each): deleting every `# master` fails
  only the ref-comments case; replacing `github-digest` with
  `github-tags` fails only the digest case — each fix is load-bearing
  on its own claim.
- Full `tests/validate.sh`, Docker, release/tag, publish, push: not
  run, per the brief; manager gates the merged tree.

### What remains honestly unverified

No end-to-end Renovate run observed — the custom managers and the
`groupName` batching are configured, patterns matched locally, live
behavior unproven. The page says exactly this; expect a PR per
pin/update set until the batch is seen landing together.

---

## Follow-up (2026-10-08) — the application-upstream direction

The page separated the customer's source updates from Kit's platform
updates but said nothing about improvements to the application itself:
a reader with a fix belonging in the canonical app (for example,
Parlor) had no path for it. §1 now carries it, kept distinct from §4's
PRs to Kit.

### What was delivered (2 commits, this worktree only, not pushed)

- Q1: `docs/customer-upstream.md` §1 gains **"Sending an application
  fix upstream — not a Kit change"**: general fixes go to the
  canonical app as fork + PR, branched off `upstream/main` on the same
  named `upstream` remote the section's Jumpstart Pro model already
  uses; app-specific branding/features stay downstream; upstream takes
  general fixes, not every customization (no claim every
  customization is accepted, no CAF command, no automation invented).
  `tests/customer_upstream_check.sh` gains the 11th case guarding the
  separation (header + branch needles, not common words).
- Q2: README table row + adoption section and the `## Unreleased`
  CHANGELOG entry rewritten to name both upstream directions distinctly
  (app fixes to the canonical app, Kit improvements to Kit).

### Evidence (commands and actual output)

- `bash tests/customer_upstream_check.sh` → 11/11 PASS.
- `bash -n` + `shellcheck -S warning` clean on the check script.
- Red probe (restored after): deleting the "PRs to Kit itself are the
  separate" line fails only the new separation case — the case is
  load-bearing on its own claim.
- Full `tests/validate.sh`, Docker, network, tags/releases, push: not
  run, per the brief; manager gates the merged tree.
