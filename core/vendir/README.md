# The core fan-out: vendir + Renovate

Thirteen repositories copy bytes out of `anywaye/core` and nothing makes the copy
reach them. This directory is the standard that does.

- **`vendir.yml.{muse,pantry,caf}`** — the three real consumers, in three
  different languages. Two of the three are proven byte-identical to what those
  repositories have committed today; the third cannot migrate without a rename,
  and says so.
- **`vendir.yml.template`** — what a fourth repository copies.
- **`../renovate/`** — the one config that governs all of them.
- **`../release/`** — what `core` needs before any of this can move.
- **`../README.md`** — why, and the three failure modes this design defends
  against.

## What vendir actually does, verified by running it

Every claim in this directory was checked against vendir 0.46.2 running against
the real `anywaye/core`, not against documentation. Three of those checks changed
what is written here.

### `includePaths` is an exact glob, not a directory

vendir joins each pattern to the sync root and matches every file against it
(`pkg/vendir/directory/file_filter.go`: `filepath.Join(dirPath, pattern)` then
`doublestar.PathMatch(pattern, path)`). So:

| `includePaths` | result |
| --- | --- |
| `schemas` | matches the **directory**, therefore no file — vendir fails |
| `schemas/**` | every file under `schemas` |
| `schemas/anywaye.manifest.schema.json` | that one file |

The first row is the lucky failure: vendir reports `Expected to find at least one
file within directory` and exits non-zero. Loud, and correct.

### The trap that is not loud

`includePaths` is a field of a content entry — a **sibling** of `git:`, not a
child of it:

```yaml
# right
- path: .
  includePaths: [schemas/**]
  git: { url: …, ref: … }

# wrong, and SILENT
- path: .
  git: { url: …, ref: …, includePaths: [schemas/**] }
```

The second form was run. It exits **0** and vendors the entire upstream
repository — `AGENTS.md`, `anywaye/notes/decisions.md`, the test suite, `.git` and all —
because vendir unmarshals through `sigs.k8s.io/yaml`, which drops keys the
target struct does not declare, and then `includePaths` is empty. An empty
`includePaths` means `matched = true` for every file, so the filter removes
nothing and reports success.

A green sync that vendored ten times the intended bytes, from a config that reads
correctly. `tests/validate.sh` has a check for exactly this shape.

### `newRootPath` is how a document changes directory

It strips a prefix from every copied path. This is what makes the courier
asymmetry — a document not at the conventional path — expressible without a
per-repository script, and it is why the three templates differ only in their
`path`, `includePaths` and `newRootPath` lines.

### A `git:` source resolves a tag to that tag's tree

Proven against a purpose-built repository with two tags whose contents differ:
`ref: v0.3.0` copied the v0.3.0 bytes, not the branch head. The lockfile records
both the tag and the sha:

```yaml
- git:
    commitTitle: three
    sha: f1ce5306e13b9ce0e7d98032698a9629c06ea5e1
    tags: [v0.4.0]
  path: .
```

The sha is the machine-readable form, and pinning it is what makes a tag that
moved after the fact detectable at all. Nothing in kit compares it any more — the
reporter that did read the fleet's pins and was removed with the cross-repo
surface (MD36) — so the sha is now what a lockfile diff shows you, rather than
something a gate asserts.

### An `http:` source is not updatable, and an `ssh://` URL is invisible

Both read out of Renovate's vendir extractor (`lib/modules/manager/vendir/extract.ts`
at `f998d68`):

- `http:` becomes a dependency with `skipReason: 'unsupported-datasource'`. It is
  extracted and then never updated. This is why the template uses `git:`.
- `extractGitSource` requires a URL matching `^(?:ssh|https?):\/\/` and derives
  the dependency name with `getHttpUrl`. A `git@github.com:anywaye/core.git` URL
  syncs perfectly well under vendir and is **not extracted at all**, so Renovate
  never sees it. A working local sync and a silently unbumped pin.

## The lockfile is not optional

Renovate's `updateArtifacts` opens with:

```ts
const lockFileName = getSiblingFileName(packageFileName, 'vendir.lock.yml');
if (!lockFileName) { logger.warn('No vendir.lock.yml found'); return null; }
```

No lockfile means no artifact update. The pin moves, the bytes are not re-copied,
and the diff looks like a successful one-line bump. Commit `vendir.lock.yml`.

## What vendir will not do for you

`git subtree` is rejected and this is the whole argument: a `subtree pull` inside
a routine commit changes specification bytes with no pull request, no version, and
no review signal. It bypasses review entirely, and it is the one mechanism in this
space that can do that quietly. If someone proposes it, this paragraph is the
answer.

## The guard vendir does not know about

`anywaye-ts/specs/index.json` carries a hand-set `expectOperations` per service,
and `vendor.mjs` refuses to absorb a document whose operation count moved.
**vendir will re-copy such a document without comment.** It copies bytes; it has
no opinion about whether the copy should have been allowed to change size.

That guard is a real asset and it does not survive this migration inside
vendir.yml. Keep it where it is — as its own CI test in `anywaye-ts` — rather than
looking for a vendir feature to hold it. A guard that has been moved into a tool
that cannot enforce it is a guard that has been deleted, and the person who
notices is the one debugging a client built from a document that changed under it.
