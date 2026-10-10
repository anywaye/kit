# REPORT-kit-lic-framework-01 — the grant moves to MIT, and the manifest appears

`ops/w0-lic-framework-kit`, worktree `/Users/kaka/Code/any/ops-wt/lic-framework-kit`.
One brief, one worker, no subprocess doing independent work. Three commits, all
committed and none pushed and none merged.

| commit | what |
|---|---|
| `ffe8b8f` | `LICENSE` → the fleet's byte-identical MIT text |
| `efffe57` | `cafaye.yml`, the manifest OPS-D2 said was missing |
| `a78dda9` | README / AGENTS / CHANGELOG stop claiming a closed grant |

## The gate's real exit code

```
exit: 1
FAIL: 1 check(s) failed.
note: 9 check(s) skipped (reported above).
```

`timeout 560 bash tests/validate.sh`, run twice, 226 seconds the second time.
Both runs identical. **Exactly one check failed, and it is the licence check:**

```
FAIL LICENSE  (Cafaye proprietary, and nothing in the tree can disagree with it)
```

I am not going to dress that up. It is red, and section *Why the gate is red*
below says exactly why, what it does not mean, and who owes the fix. The other
9 skips are environmental (`rustc` absent, `node --check` cannot read
TypeScript, `wrangler` absent, the three tenancy `.sql` files parsed by
`tests/tenancy_test.sh` rather than the static loop) and were the same on both
runs.

## What landed, and the measurement behind each claim

### 1. `LICENSE` — MIT, and not a new draft

The wording is the fleet's, not kit's. **Seven cafaye repositories already carry
this exact text** — `billing`, `caf`, `cafaye-py`, `cafaye-ts`, `core`,
`darkroom`, `docs` — each 1063 bytes and each md5
`cb5ecefdf779acdeacb8709d2ddd56cf`. Measured:

```
$ md5 -q billing/License caf/... cafaye-py/... cafaye-ts/... core/... darkroom/... docs/...
1 distinct hash across 7 files
$ cmp LICENSE ../core/LICENSE && echo IDENTICAL
IDENTICAL (byte-for-byte)
```

The grant wording is uniform, so a reader diffing two framework repos sees no
grant and only the repository differing. That was the point of matching core
rather than writing kit's own MIT.

### 2. `cafaye.yml` — schema-valid, with one review decision flagged

The brief cited `core/schemas/manifest-0.2.json`. **That file does not exist.**
The schema core actually publishes is
`core/schemas/cafaye.manifest.schema.json` (`$id`
`https://cafaye.com/schemas/cafaye.manifest.schema.json`), and the manifests
themselves point at it — `pantry/cafaye.yml` and `caf/cafaye.yml` both name it in
a header comment. Validated against that.

`jsonschema` is not installed on this machine (`.venv` has PyYAML only, system
`python3` has neither), so **no third-party validator ran**. Instead I read the
schema's own constraints off the file and asserted them directly — required keys,
`additionalProperties: false` at root and in `repository`/`owner`, the
`serviceName` pattern, `semverRange`, the `repository.url` SSH pattern, the
`defaultBranch` const and the `visibility` enum:

```
SCHEMA CONSTRAINTS vs cafaye.manifest.schema.json: ALL PASS
root keys: ['core', 'dependencies', 'description', 'language', 'name', 'owner', 'repository']
description: 152/200
yaml parses: dict
```

The values, each with its reason written into the file:

| key | value | why |
|---|---|---|
| `name` | `kit` | the repo's own name; matches `^[a-z][a-z0-9]*(-[a-z0-9]+)*$` |
| `language` | `spec` | the enum is `go ruby elixir python typescript rust spec` and has no config member; AGENTS.md says kit is configuration and documentation only |
| `core` | `^0.2.0` | the fleet range, declared though kit compiles against no core schema |
| `dependencies` | `[]` | kit is a dependency *of* the fleet, never a consumer |
| `repository.url` | `git@github.com:cafaye/kit.git` | measured, `git remote -v` in this checkout |
| `repository.defaultBranch` | `master` | measured, `symbolic-ref refs/remotes/origin/HEAD` |
| `repository.visibility` | `public` | OPS-D2, now that the grant is MIT |
| `owner.team` / `contact` | `kit` / `kit@cafaye.com` | the fleet spelling — core@, caf@, pantry@, identity@, courier@, billing@, parlor@, muse@, gateway@, darkroom@, docs@ |

`exposes` and `consumes` are omitted rather than left empty: kit is not a running
process, so it has no runtime contract to break, which is the reason `core` gives
for its own omission.

**The one line that is a review decision and not a derivation** is `name: kit`.
`core/docs/manifest-conventions.md` ("Namespace rules") lists
`cafaye`, `caf`, `kit`, `core`, `docs`, `pantry` as "reserved, never usable as a
service name". It is named anyway, which is the exception core already makes for
itself — the schema does **not** enforce the list, and the rule's purpose is to
stop one service *calling* another `kit`. The file says so in a comment and flags
it for the manager. This is not re-litigating OPS-D2; it is naming the one place
where implementing it required a call the register did not make.

### 3. The prose sweep

Re-pointed, with file:line citations, every present-tense claim that kit is
closed:

- `README.md:171` — the layout-table `LICENSE` row. The old row said "kit has no
  package manifest, so there is no metadata field that could disagree with the
  file"; that is now *precise* rather than *absent*, because kit has exactly one
  manifest and core's schema declares no licence key for it.
- `README.md:172` — a new `cafaye.yml` row, added in the same edit. AGENTS.md's
  own checklist requires README to match the tree.
- `README.md:684-706` ("### kit's own licence") — MIT, the byte-identity
  measurement, and why MIT one-way can never acquire AGPL's terms.
- `README.md:1794-1835` ("## License") — states MIT, names Cafaye, links
  `[LICENSE](LICENSE)`, keeps the AGPL separation paragraph, and names the
  stale check in the open.
- `AGENTS.md:20` — the layout comment, `# Proprietary (Cafaye)` → `# MIT`, plus
  a `cafaye.yml` line.
- `AGENTS.md:1142-1157` — the licence rule, now MIT, with the successor's
  documented move on `license_check` and the standing *do not weaken a check to
  get green*.
- `CHANGELOG.md` — a `### Licensing` subsection under `## Unreleased`.

**Deliberately not touched**, and this is the judgement call of the packet:
`REPORT-kit-license-m168.md`, `REPORT-kit-license-check-m172.md`,
`REPORT-kit-19.md:11`, and the m168 / m172 / kit-19 `CHANGELOG.md` entries
(`CHANGELOG.md:299-307`, `:4550`). They are dated records of what was decided
*then*, and they read correctly as history. A changelog that edits its own
history is a changelog nobody can read. Under `templates/substrate/README.md:165`,
`CHANGELOG.md:469` and `tests/validate.sh:4624` there are "closed-source" hits
that are correct as written and were left alone: OPS-D2 keeps `conductor` and the
artifact distribution closed, and those sentences are about the service charts,
not about kit.

## Why the gate is red

`license_check` (`tests/validate.sh:2044-2191`) was written in m172 for the
proprietary grant. It requires three of the grant's own sentences in `LICENSE`,
refuses MIT's permission sentence, requires README's `## License` section to
state `Proprietary` and name `Cafaye`, and requires it to name AGPL. Measured
against the re-granted tree, **6 of its 8 sub-assertions are red**:

```
LICENSE missing 'All rights reserved'
LICENSE missing 'proprietary property of Cafaye'
LICENSE missing 'separate written Cafaye agreement'
LICENSE still contains MIT permission grant
LICENSE names no Cafaye copyright holder
README License section does not state the proprietary grant
```

The 2 that stay green were never about the grant's wording: README links
`[LICENSE](LICENSE)`, and README names AGPL.

**The fix is one file and it is not mine to make.** The hard rules say never
touch tests, and `tests/validate.sh` is that. A licensing packet does not get to
edit a gate to make itself green — that is the failure mode this repository
documents more than any other. So the grant moved, the gate did not, and the gate
is red on exactly one check, which is the honest state of it. The successor's
move is written into `AGENTS.md` beside the rule: re-point the three phrases and
the README assertions at MIT, keep the two-direction shape (the file grants MIT;
the section states MIT and links it), and keep point 4 unchanged — `cafaye.yml`
declares no licence field, so "manifests inspected, none disagreeing" is still
the measurement the check prints.

Worth noting for whoever does that work: the check's own comment
(`tests/validate.sh:2086`) says *"If kit's grant changed, say so in README.md
instead of leaving the two files to disagree"* — which is what this packet did in
README but could not do in the check.

## Disagreements and notes for the manager

1. **The brief's schema path does not exist.** `core/schemas/manifest-0.2.json`
   is not a file. The working schema is
   `core/schemas/cafaye.manifest.schema.json`, named by the manifests
   themselves. I implemented against the file that exists rather than inventing
   a description for one that does not.
2. **`name: kit` needs a manager call.** It is on the reserved-name list. core
   takes the exception for itself; kit is asking for the same one.
3. **`owner.contact: kit@cafaye.com` follows the fleet spelling, not a record.**
   kit declared no mailbox before this file existed. Every other cafaye repo
   uses `<repo>@cafaye.com`. This may need correcting, and it is one line.
4. **The gate is red and the fix is owned elsewhere.** Section above. If the
   manager wants a green gate in the same merge, `tests/validate.sh:2044-2191`
   has to move in the same series, by someone authorised to touch tests.
5. **The brief's `SPECIFIED` grant wording is not what core/LICENSE says.** The
   brief said "MIT text worded to match cafaye/core/LICENSE exactly" *and*
   separately described Licensor "Cafaye" with a Change Date — which is BSL
   boilerplate, not MIT. I implemented the first instruction because it is the
   one that matches the TARGET line and OPS-D2, and because the second is
   BSL 1.1 vocabulary that MIT has no field for. Flagging it in case the two
   halves of the brief came from different drafts: the packet is MIT, not BSL,
   and `LICENSE` carries no Change Date because MIT has nowhere to put one.

## What I did not do

No `install.sh`, no `templates/`, no `tests/`, no `.github/`. The gate was not
weakened. Nothing was pushed or merged. Nothing was claimed green that was red.
