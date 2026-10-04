# Standing up `cafaye/renovate-config`

Ordered, and the order is the point. Steps 4 and 5 are the ones that go wrong
when they are swapped.

## 1. Create the repository

Empty, public, named `renovate-config`, under the `cafaye` organisation. **No
initialisation files** — not a README, not a licence, not a `.gitignore`. A
repository created from a template carries a commit whose only content is a
default README, and `inheritConfig` reads the file by name, so a default that
happens to collide is a silent override of the policy for thirteen
repositories.

## 2. Add exactly one file

`renovate.json5` at the repository root, containing the contents of
`renovate.json5` in this directory. The filename is not a default: it is what
`inheritConfigFileName` points at, and the default for that option is
`renovate-config.js`. The default would work; naming it explicitly means nobody
has to know that.

## 3. Turn on inheritance globally

In the self-hosted Renovate configuration, **not** in the inherited file:

```json
{
  "inheritConfig": true,
  "inheritConfigRepoName": "cafaye/renovate-config",
  "inheritConfigFileName": "renovate.json5",
  "inheritConfigStrict": true
}
```

`inheritConfig` is a global option — `lib/config/options/index.ts` marks it
`globalOnly` — so it cannot be set in the inherited file it configures, and
`inheritConfigStrict: true` is what makes a repository whose own config
contradicts the shared one fail loudly instead of quietly preferring one of them.

## 4. Verify inheritance BEFORE onboarding any repository

This is the step that is easy to skip and expensive to skip. Ask Renovate to
resolve its own configuration and read the result:

```sh
renovate-config-validator --strict
renovate --dry-run=lookup 2>&1 | grep -E 'vendir|git-refs'
```

What to look for, and what each outcome means:

| what you see | what it means |
| --- | --- |
| the `vendir` manager listed for a repo with a `vendir.yml` | inheritance works |
| no `vendir` manager, no error | the shared config is not being read — stop here |
| `constraints.vendir` absent | inheritance works but the tool constraint is not inheriting; **this is the documented-but-unconfirmed detail, so confirm it explicitly** |
| `installTools` reported as an array | the file is wrong; it is an object keyed by tool name |

The third row is the one worth a second look. The reasoning is in
`renovate.json5` and it was checked in Renovate's source, but "checked in source"
and "observed running" are different claims, and this is the one that decides
whether the policy lives in one place or thirteen.

## 5. Onboard ONE repository first

Not thirteen. One, with `enabled: false` in its own `renovate.json5`, and a
`vendir.yml` plus a committed `vendir.lock.yml` already in place. Then:

```sh
# in the consuming repository
vendir sync
git add vendir.yml vendir.lock.yml
git commit -m "vendor: core via vendir"
```

Switch `enabled` to `true` in a separate pull request, and watch one Renovate run
end to end before touching the rest. The thing to confirm is not that a PR
appears — it is that **the PR changes `vendir.lock.yml` and the vendored bytes**,
not only `vendir.yml`. A PR that changes only the pin is the silent failure
described in `core/vendir/README.md`, and it looks like success.

## 6. The remaining twelve

One pull request each, in the order of the three real consumers first:

| repository | language | template | notes |
| --- | --- | --- | --- |
| `muse` | python | `vendir.yml.muse` | proven byte-identical; drop the hand-bumped `CORE_REF` |
| `pantry` | rust | `vendir.yml.pantry` | proven byte-identical; `cafaye_root()` reads the path, so do not move it |
| `caf` | go | `vendir.yml.caf` | **needs the filename rename first** — see that file's banner |
| `billing`, `gateway` | — | none | they fetch core at `master` at test time and vendor nothing. Adopting vendir means *introducing* a frozen copy, which is a policy change, not a migration. Both have comments in their workflows explaining why they chose live fetch; read those first. |

A repository that vendors nothing gets no `vendir.yml`. Adding one to a
repository whose authors deliberately chose to fetch the schema at test time
would be replacing a decision with a default.

## 7. The backstop, which is the reason any of this is safe

Every consuming repository keeps its own sha256/parity guard in CI, and it is
what makes a stale copy **unmergeable** rather than merely detected. It survives
Renovate being down, the shared config being wrong, and this whole design being
wrong. The existing guards are:

| repository | guard | does it fail closed? |
| --- | --- | --- |
| `caf` | `internal/contract/contract_test.go` — sha256 of the embedded copy | yes |
| `muse` | `tests/test_contracts.py` — byte-identity against a core checkout | **skips** without `MUSE_CORE_SCHEMAS` |
| `pantry` | `tests/drift.rs` — resolves core through a sibling checkout | **skips** without a workspace |

Two of the three skip. That is the finding to act on, and it is independent of
everything else in this directory: a guard that skips when the thing it guards is
absent is a guard that reports green precisely when there is something to report.
`core/README.md` records what to do about it.
