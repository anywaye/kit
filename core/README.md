# The core fan-out

`cafaye/core` owns the event envelope, the manifest schema, the per-event payload
schemas and the telemetry signal schemas. Six repositories copy bytes out of it.
**Nothing in the fleet makes that copy reach them.**

This directory is the standard that does, and — as importantly — the record of
what is still unproven about it.

## What the measurement actually found

Before designing anything, the fleet was measured. The design below was built for
the problem that is there, not the one in the packet.

```
core master: 39acaed6f1e25a895b0410e0689fe68d523b1b63

repository  pin           source    behind  state
muse        15e541cd9988  CORE_REF      19  behind
billing     -             none          ?  undeclared
gateway     -             none          ?  undeclared
pantry      -             none          ?  undeclared
caf         -             none          ?  undeclared
(…)
```

(`tests/staleness.py --repos-dir …`, run against the real working tree.)

**One repository declares a core pin, and it is nineteen commits behind.** That is
not twelve copies of a hand-bump, and the difference matters:

| repository | how it gets core's bytes | pin? |
| --- | --- | --- |
| `muse` | checked out at a hand-bumped `CORE_REF`, and one document copied | yes, 19 behind |
| `caf` | one document committed, `go:embed`ded | **no** |
| `pantry` | one document committed, used as a workspace marker | **no** |
| `billing` | `actions/checkout` at `ref: master` in CI | no, by choice |
| `gateway` | `curl` from `raw.githubusercontent.com` at test time | no, by choice |

Three findings that changed the plan:

1. **`caf` and `pantry` hold vendored bytes with no recorded origin at all.** The
   packet's own literature says 4.3% of vendored copies record a recoverable
   origin; these two are in that 4.3%, inside our own fleet, today. The
   staleness reporter reports them `undeclared`, which is a different statement
   from `current` and is the only honest thing to say.
2. **`billing` and `gateway` fetch core at test time on purpose, and say so in
   comments.** `gateway`'s reads: *"The schema is fetched rather than vendored so
   this tracks what core publishes today instead of freezing a copy that silently
   goes stale."* Adopting vendir there means *introducing* a frozen copy — a
   policy change, not a migration. Their authors made a considered choice; this
   packet does not overrule it by adding a config file.
3. **Three of the five parity guards skip when the thing they check is absent.**
   `muse`'s `test_contracts.py` calls `pytest.skip` without `MUSE_CORE_SCHEMAS`;
   `pantry`'s `drift.rs` returns early with a message on stderr. A guard that
   skips when its input is missing is a guard that reports green precisely when
   there is something to report. Fixing this is independent of vendir and more
   urgent than vendir.

## The design

Four pieces, and the dependency order matters.

1. **`vendir/`** — a `vendir.yml` per consuming repository, `core` as a `git:`
   source pinned to a semver tag, and a committed `vendir.lock.yml`. Three real
   repositories in three languages are provided; two are proven byte-identical to
   what those repositories have committed today. See `vendir/README.md`.
2. **`release/`** — the workflow `core` needs before any of it can move, because
   `cafaye/core` has **zero tags** and `ref: v0.3.0` therefore fails. Verified by
   running it.
3. **`renovate/`** — one `cafaye/renovate-config` repository with
   `inheritConfig`, so a policy change is one pull request in one place. See
   `renovate/SETUP.md` for the ordered steps and for what to verify before
   onboarding a second repository.
4. **The backstop** — every repository keeps its own sha256 parity guard. This is
   what makes a stale copy *unmergeable* rather than merely detected, and it
   survives Renovate being down, the shared config being wrong, and this design
   being wrong. It is not being replaced by anything here.

## The three failure modes, and what defends each

### F1 — the self-test stops covering the real diff

**The defence is `tests/classify.py`, and it fails closed.**

kit's self-test proves eighteen synthetic breakages go red. It cannot prove that
a future change to `event-envelope.schema.json` is one of those eighteen shapes.
So the classifier compares a repository's schema set before and after and places
every difference into one of four tiers borrowed from buf — `FILE` (strictest) /
`PACKAGE` / `WIRE_JSON` / `WIRE` — because the useful distinction there is *pick
the category that matches what your consumers actually depend on*. A Go struct is
a `FILE` consumer. A JSON payload validator is `WIRE_JSON`.

The property that matters is not the tiering. It is this: **a change no rule
matches is `UNRECOGNISED`, and `UNRECOGNISED` is the strictest tier.** The
classifier models a fixed set of JSON Schema keywords; a keyword it does not
model produces the `unmodelled-keyword` observation, which is `FILE`. Adding a
keyword to core — `unevaluatedProperties`, `dependentSchemas`, anything — cannot
be auto-merged green by omission. It has to be classified by a human, which is
the only correct answer to "I do not know what this is".

The escape hatch is fenced. A rule may declare `breaking: false` — the
documentation rules need somewhere to go, or the gate is red on every typo in
core — but only for an operation named in `advisoryOps`, and the catalogue
**refuses to load** otherwise. Otherwise the one escape hatch is the first place
a fail-open classifier reappears. That is ESLint's
`reportUnusedDisableDirectives` shape: an escape hatch with no hygiene rule is a
ratchet that only turns one way.

Proven by `tests/classify_test.sh`, whose first case is a brand-new keyword
arriving in core and which asserts the failure *at the loosest tier a caller can
declare* — because a fail-closed property that only holds when the consumer is
careful is not a property.

### F2 — `expectOperations` is a guard vendir knows nothing about

`cafaye-ts/specs/index.json` carries a hand-set `expectOperations` per service,
and `vendor.mjs` refuses to absorb a document whose operation count moved. vendir
will re-copy such a document without comment.

**This is a real migration cost and it is not resolved here.** The guard does not
move into `vendir.yml`, because vendir copies bytes and has no opinion about
whether a copy should have been allowed to change size. It stays where it is, as
its own CI test in `cafaye-ts`. A guard relocated into a tool that cannot enforce
it is a guard deleted, and the person who finds out is debugging a client built
from a document that changed under it. If the next person reads this and thinks
"that could be simplified into the vendor step", this paragraph is the answer.

### F3 — a re-vendor PR can be green about the copy and red about the code

A breaking change needs consumer changes. Thirteen pull requests land at once,
three go red for a reason the diff does not explain, and the platform team eats
three interruptions to fix a bug in one repository.

**The defence is in `renovate/renovate.json5`:** additive bumps may auto-merge;
breaking-class bumps carry `needs-code-change` and `automerge: false`. The label
is advice; the missing automerge is the mechanism.

Renovate has **no `needsCodeChanges` option** at the ref checked — zero matches
for "codechange" anywhere in `lib/`, and no such name in the option schema. The
first version of this design assumed it existed. It does not, and the label-plus-
no-automerge form is the better control anyway.

## `git subtree` is rejected

Once, and here is the whole argument: a `subtree pull` inside a routine commit
changes specification bytes with **no pull request, no version, and no review
signal**. It bypasses review entirely, and it is the only mechanism in this space
that can do so quietly. Everything else here is slower on purpose.

## What is still unproven

Stated here rather than in a report nobody reads:

- **The tag mechanism has never run.** `cafaye/core` has no tags, so
  `ref: v0.3.0` fails, so all three templates say `ref: master`. That a tag
  resolves correctly *is* proven — against a purpose-built repository with two
  tags whose contents differ, where `ref: v0.3.0` copied the v0.3.0 bytes — but
  that `core` will produce tags is a claim about a workflow that has not run.
- **No Renovate run has happened.** Every Renovate claim here is read out of
  source at commit `f998d68`. What has not been observed is a real pull request
  moving a real pin and re-copying real bytes. `renovate/SETUP.md` step 5 exists
  to make that the first thing the next person does.
- **The classifier has never seen a real core diff.** It has been tested against
  fixtures, including the fail-closed case, and against a real `vendir sync` of
  core's `schemas/`. The first real spec change is still its first real input.
- **`muse` and `pantry` are byte-identical under this config; `caf` is not, and
  cannot be until it is renamed.** Verified, not assumed.

## Why `oasdiff` is not wired in

For the OpenAPI half, `oasdiff` is the right tool: a static Go binary, a real
GitHub Action, and **755 level-tagged checks** — measured by running
`oasdiff checks changelog` at v1.32.1, which prints 399 `info`, 339 `err` and 17
`warning`. Its three severity levels map onto this design well, and the 17
`warning` checks are precisely the "cannot be confirmed programmatically"
material.

It is not wired in because **core's fan-out is raw JSON Schema, not OpenAPI**,
and because adding a pinned Go binary would make `kit` a repository with a
dependency — which `AGENTS.md` forbids and which is the whole reason this design
chose a static vendir binary over a per-language vendor script. If a service's
*OpenAPI* documents move into the fan-out, `oasdiff` is the answer and it should
be provisioned by the workflow that runs it, not vendored by kit.

`tests/classify.py` and `oasdiff` do not overlap. The classifier is not a weaker
substitute for anything: there is no off-the-shelf tool with a published,
auditable rule catalogue for raw JSON Schema, which is why the catalogue is a
data file in this repository.
