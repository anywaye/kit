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
git clone https://github.com/<canonical>/<app>.git myapp
cd myapp
git remote rename origin upstream
git remote add origin https://github.com/<you>/<app>.git
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

## 2. Kit's platform pieces inside your app: call, pin, review the bump

Kit reaches your repo through three mechanisms, and each updates
differently. Reuse them; do not invent a fourth (in particular: no
subtree/submodule of Kit, which would fuse the two directions above
into one tree that can no longer be merged cleanly).

| Piece | How it reaches you | How an update lands |
|---|---|---|
| Reusable workflows (`ci`, `image`, `chart`, `publish`) | **Called** via `uses: cafaye/kit/.github/workflows/<file>@<ref>` — never copied | One PR bumping the ref |
| Lint configs (`lint/`) | **Fetched at run time** by the workflow (`kit-lint-ref` input) | With the workflow bump; nothing in your tree |
| Local stack (`templates/compose/`) | **Fetched** by `bin/dev` from your committed `kit.ref` | `bin/dev pin <new-sha>` (prints the stack diff first) |
| Copied files (`docker/Dockerfile`, `bin/prime`, `mise.toml`, `AGENTS.md`, …) | **Copied** once | Re-copy + review the diff. Nothing automates this; a fix in Kit sits un-copied until you copy it — the documented cost of copy-adoption |

**The pin contract (opt in).** Pin all three Kit refs to the **same full
commit SHA** — never a branch, and never `@master` in a customer app
(the fleet's internal repos use `@master`; yours must not, because a
branch moves under you between two runs of the same command):

```yaml
# .github/workflows/ci.yml
uses: cafaye/kit/.github/workflows/ci.reusable.yml@<40-char-sha>
with:
  kit-lint-ref: '<the same 40-char-sha>'
```

```sh
$ cat kit.ref
# the stack this service runs; see bin/dev pin
<the same 40-char-sha>
```

Get the SHA with `git -C <kit-checkout> rev-parse HEAD`. The workflow
file's own header warns that a `kit-lint-ref` left at `master` beside a
pinned `uses:` mixes one revision's workflow with another revision's
lint policy — the contract above is what closes that seam.

## 3. Receiving Kit updates as a PR: the opt-in Renovate block

Renovate's built-in `github-actions` manager already bumps `uses:
…@<sha>` pins natively. For the other two pins, copy this
`renovate.json` into your repo root — it watches this repository's tags
and opens one PR moving every Kit pin together:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/(^|/)kit\\.ref$/"],
      "matchStrings": ["^(?<currentValue>[0-9a-f]{40})\\s*$"],
      "depNameTemplate": "cafaye/kit",
      "datasourceTemplate": "github-tags"
    },
    {
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/[^/]*\\.ya?ml$/"],
      "matchStrings": ["kit-lint-ref:\\s*['\"]?(?<currentValue>[0-9a-f]{40})['\"]?"],
      "depNameTemplate": "cafaye/kit",
      "datasourceTemplate": "github-tags"
    }
  ]
}
```

Verification status, stated honestly: the JSON parses and both patterns
match the pin shapes in §2 (checked locally with Python). No
end-to-end Renovate run has been observed from this file. And it
produces **no PRs today by design**: `github-tags` yields versions only
once Kit publishes `v*` tags, and none exist yet (see §5). Adopt the
pin contract now; the PRs begin with the first tag, with no change to
your config.

## 4. Sending Kit improvements upstream: fork + PR

App owners change Kit the same way Jumpstart contributors do — a fork,
a branch, a pull request to canonical Kit:

```sh
git clone https://github.com/<you>/kit.git
cd kit
git remote add canonical https://github.com/cafaye/kit.git
git checkout -b <what-you-are-changing>
# …edit, then:
bash tests/validate.sh   # Kit's gate; must be green before any commit
git push -u origin <what-you-are-changing>
# open the PR against cafaye/kit
```

What the PR needs: a `CHANGELOG.md` entry, and agreement rather than
presence — if you touch a template, the check that would catch its
absence travels in the same commit. Docs-only changes take the fast
`docs` CI route. What Kit will not take: a second copy of a standard,
a per-repo preference promoted to shared policy, or a weakened check
made green by weakening (see `AGENTS.md`).

## 5. What is not decided yet — follow-ups, not promises

- **Tags / releases.** Verified 2026-10-08: `git tag` is empty and no
  release workflow exists in `.github/workflows/`. The `v<semver>` pin
  shape and the Renovate PRs in §3 activate on Kit's first tag. Until
  then, pin to SHAs. Whether and when Kit tags is a manager decision;
  this page claims nothing that needs one to exist.
- **External access.** A reusable-workflow `uses:` line resolves in
  private repositories *inside the organisation*. Customers outside it
  need Kit public or explicitly granted — likewise a manager decision.
  Do not assume you can fetch Kit until that is announced; the
  commands above are the path for when you can.
