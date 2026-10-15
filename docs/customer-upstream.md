# Using Kit in your own application, and sending improvements back

Two things travel in two directions, and this page keeps them apart:
**your application** (you own it; Kit's updates must never overwrite your
work) and **Kit's platform pieces inside it** (Kit owns them; you take
updates as a reviewable PR). A third direction — your improvements to Kit
itself — goes back as a fork + PR.

This is the customer-facing path. The fleet-internal adoption checklist
(still `@master`, still inside the org) is unchanged; see
[How a service repo adopts kit](../README.md#how-a-service-repo-adopts-kit).

## 1. Your application source: fork it, keep your commits, merge updates

The model is Jumpstart Pro's, verified against its README: your app is a
repository you own, with the canonical template kept as a **named remote**
you merge from — never a copy you re-download.

```sh
git clone https://github.com/cafaye/kit.git myapp
cd myapp
git remote rename origin upstream
git remote add origin https://github.com/your-handle/kit.git
git push -u origin main
```

To receive template updates later, merge — do not re-apply, do not copy
over your tree:

```sh
git fetch upstream
git merge upstream/main
```

(Jumpstart Pro documents exactly this: `git remote rename origin
jumpstart-pro`, re-add `origin`, then `git fetch jumpstart-pro` /
`git merge jumpstart-pro/main`; contributors send improvements via
fork + pull request.)

The properties that preserve your work, all from the mechanism rather
than from discipline:

- Your commits live on your branches; updates arrive as a **merge you
  review**, conflicts resolved by you, file by file.
- No subtree, no submodule, no recursive repo copies, no forced
  updates, no sync bot. Anything that rewrites your history or
  overwrites your tree is the thing this page forbids.
- Never force-push a branch someone else pulls from.

**Sending an application fix upstream — not a Kit change.** If a fix or
general improvement belongs in the canonical app itself (for example,
Parlor), send it upstream to that app's canonical repository as a
fork + PR, using the same named `upstream` remote above as the source
of truth: branch off `upstream/main`, push to your `origin`, and open
the PR against the canonical repo — the Jumpstart Pro contributor
model this section follows. App-specific branding and features stay in
your downstream repo; upstream takes general fixes, not every
customization. (PRs to Kit itself are the separate §4 path.)

## 2. Kit's platform pieces inside your app: call, pin, review the bump

Kit reaches your repo through three mechanisms, and each updates
differently. Reuse them; do not invent a fourth (in particular: no
subtree/submodule of Kit, which would fuse the two directions above
into one tree that can no longer be merged cleanly).

Kit is public — `github.com/cafaye/kit`, verified 2026-10-08 — so every
mechanism below is fetchable from any repo, inside or outside the org,
with no grant to request.

| Piece | How it reaches you | How an update lands |
|---|---|---|
| Reusable workflows (`ci`, `image`, `chart`, `publish`) | **Called** via `uses: cafaye/kit/.github/workflows/<file>@<ref>` — never copied | A PR bumping the ref |
| Lint configs (`lint/`) | **Fetched at run time** by the workflow (`kit-lint-ref` input) | With the workflow bump; nothing in your tree |
| Local stack (`templates/compose/`) | **Fetched** by `bin/dev` from your committed `kit.ref` | `bin/dev pin <new-sha>` (prints the stack diff first) |
| Copied files (`docker/Dockerfile`, `bin/prime`, `mise.toml`, `AGENTS.md`, …) | **Copied** once | Re-copy + review the diff. Nothing automates this; a fix in Kit sits un-copied until you copy it — the documented cost of copy-adoption |

**The pin contract (opt in).** Pin all three Kit refs to the **same full
commit SHA** — never a branch, and never `@master` in a customer app
(the fleet's internal repos use `@master`; yours must not, because a
branch moves under you between two runs of the same command):

```yaml
# .github/workflows/ci.yml
uses: cafaye/kit/.github/workflows/ci.reusable.yml@<40-char-sha> # master
with:
  kit-lint-ref: '<the same 40-char-sha>' # master
```

```sh
$ cat kit.ref
# the stack this service runs; see bin/dev pin
e3a91c0d2f6b48a1c5d7e8f9a0b1c2d3e4f5a6b7
```

Three facts about the `# master` comments, all load-bearing:

- On the two YAML lines the comment is what makes the pin updatable, not
  a note. Renovate's built-in `github-actions` manager leaves a bare SHA
  alone — with no ref it cannot tell which branch the SHA belongs to —
  and moves a SHA carrying a branch comment against that branch.
  `master` there does not move you; it tells Renovate what to follow.
  The `uses:` line needs nothing else: the manager recognises it
  natively. The `kit-lint-ref` line needs the regex manager in §3,
  because it is a `with:` value, not a `uses:` ref.
- `kit.ref` stays a **bare SHA with no trailing comment**. `bin/dev`
  reads the whole line as the ref and refuses anything that is not 40
  hex characters, so `<sha> # master` in that file is a refused pin, not
  a documented one. The branch it follows lives in the Renovate config
  (`currentValueTemplate` in §3), not in the file.
- Get the SHA with `git -C <kit-checkout> rev-parse HEAD`. The workflow
  file's own header warns that a `kit-lint-ref` left at `master` beside a
  pinned `uses:` mixes one revision's workflow with another revision's
  lint policy — the contract above is what closes that seam.

## 3. Receiving Kit updates as PRs: the opt-in Renovate block

Copy this `renovate.json` into your repo root. It tracks Kit's `master`
branch and opens PRs moving the pins forward — a PR per pin/update set
(see the grouping note below):

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/(^|/)kit\\.ref$/"],
      "matchStrings": ["(?<currentDigest>[0-9a-f]{40})"],
      "depNameTemplate": "cafaye/kit",
      "packageNameTemplate": "cafaye/kit",
      "currentValueTemplate": "master",
      "datasourceTemplate": "github-digest"
    },
    {
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/[^/]*\\.ya?ml$/"],
      "matchStrings": ["kit-lint-ref:\\s*['\"]?(?<currentDigest>[0-9a-f]{40})['\"]?\\s*#\\s*(?<currentValue>\\S+)"],
      "depNameTemplate": "cafaye/kit",
      "packageNameTemplate": "cafaye/kit",
      "datasourceTemplate": "github-digest"
    }
  ],
  "packageRules": [
    {
      "matchDepNames": ["cafaye/kit"],
      "groupName": "kit pins"
    }
  ]
}
```

Why this shape, per Renovate's current docs (the `github-actions`
manager page; the `github-digest` datasource page):

- `master` is a non-semver ref, so the built-in manager routes the
  `uses:` pin to the `github-digest` datasource, which follows the
  branch and updates only the digest. The two regex managers do the same
  for the other pins: `github-digest` tracks a branch and moves a
  digest, so each rule names the branch — `kit-lint-ref` reads it off
  its `# master` comment, `kit.ref` carries it as
  `currentValueTemplate` because the file itself must stay a bare SHA.
- Tags and releases play no role here. Digest tracking follows `master`
  directly, so whether Kit has cut any tag changes nothing — an empty
  `git tag` is not a missing update path. The branch SHA plus the
  comment/digest above is the update path, and it works today.

Verification status, stated honestly: the JSON parses (`python3 -c
json.load`) and every `matchStrings` matches the pin shapes in §2 —
checked locally by translating JavaScript `(?<name>…)` groups to Python
`(?P<name>…)` (characters and anchors identical) and matching sample
lines. No end-to-end Renovate run has been observed from this file, so
the custom managers are configured but their live behavior is
unverified. The `groupName` rule asks Renovate to batch the three Kit
pins into one PR, but that batching is likewise unverified — expect a PR
per pin/update set until you have seen them land together.

## 4. Sending Kit improvements upstream: fork + PR

App owners change Kit the same way Jumpstart contributors do — a fork,
a branch, a pull request to canonical Kit:

```sh
git clone https://github.com/your-handle/kit.git
cd kit
git remote add canonical https://github.com/cafaye/kit.git
git checkout -b docs-update-the-pin
# …edit, then verify narrowly:
git diff --check
# plus the focused check for what you touched, if one exists —
# e.g. bash tests/customer_upstream_check.sh after editing this page
git push -u origin docs-update-the-pin
# open the PR against cafaye/kit
```

Kit's CI owns the full gate — `tests/validate.sh` runs there, and
docs-only changes take the fast `docs` CI route — so do not run the
whole gate before every commit. Narrow local verification plus a green
CI run is the contract. What the PR needs: a `CHANGELOG.md` entry, and
agreement rather than presence — if you touch a template, the check
that would catch its absence travels in the same commit. What Kit will
not take: a second copy of a standard, a per-repo preference promoted
to shared policy, or a weakened check made green by weakening (see
`AGENTS.md`).

## 5. What this page does not promise

- **No end-to-end Renovate proof.** The §3 block is configured and its
  patterns are matched locally, but no Renovate run has been observed
  producing PRs from it — neither the digest moves nor the grouping.
  Until one is, treat the PR flow as set up, not proven.
