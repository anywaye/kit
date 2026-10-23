# Test tiers — `templates/tier/`

A **tier** is a class of test that needs a real dependency to mean anything: a
database, Redis, a broker. The failure this convention exists to prevent is
specific and has already happened in this fleet — **a green run in which the
whole database tier never executed once**, because the suite reported `ok` and
`ok` is the only thing anybody read.

A Dockerfile that never copied a root-level test file produced exactly that
result. Nothing in the report was wrong, and nothing in it was right either.

## The hole in the format

JUnit XML is the de facto cross-language substrate for test results, and it
**cannot express "filtered out"**. That is not a tooling gap; it is a gap in the
format. The canonical reference defines `skipped` as a *runtime* decision: a
test excluded by `-k`, a build tag, `--run-ignored` or `testpaths` **does not
appear in the report at all**.

An absent `<testcase>` is indistinguishable from a test that was never written.
No amount of counting fixes that — only a **set difference against an
independently derived inventory** does.

The ecosystem has already conceded the policy: *a JUnit report is a lossless
record, not a verdict.* GitLab documents the consequence directly, noting that
skipped tests "are showing up as successful test executions in the GitLab
reports, an incorrect signal about the reliability of their code." Every major
consumer treats a skip as a pass. You cannot push the policy into the runner or
the report, so it lives here, in the convention, and the gate enforces it.

## The declaration, per language

Tier membership is **declared in the test source** and read by **the runner's own
collector**. It is never grepped for a sentinel.

A sentinel is the thing to avoid, and the reason is worth stating precisely,
because it is not a style preference — it **fails open**. Identity's current
check greps for `dbtest.Pool|Schema|EnvVar|TEST_DATABASE_URL`. A DB test that
reaches Postgres through `db.Pool(ctx)` directly, through a helper two files
away, or through a fixture does not match, so **its package never enters the
required list and the run is never required to contain it.** The test is
written. It is not gated. Nobody finds out.

The first column is the `language` option value, not a display name: it is
what goes in your caller, and `tests/validate.sh` reads this table to check
that every language kit ships a job for also appears here.

| `language` | Declaration | Collector that already exists | Adapter? |
|---|---|---|---|
| `rust` | `#[ignore = "anywaye:tier=db reason=…"]` | `cargo test -- --list` | none |
| `go` | `//go:build tier_db` on the test file | `go test -tags tier_db -list '.*' ./...` | none |
| `python` | `@pytest.mark.tier_db` | `pytest --collect-only -q -m tier_db` | none |
| `elixir` | `@tier :db` | none — needs one | ~15 lines |
| `node` | `export const TIER` | none — needs one | ~15 lines |
| `bun` | `export const TIER` | `bun test --reporter=junit` (partial) | ~15 lines |
| `ruby` | `tier :db` class macro | none — needs one | ~15 lines |

Where a language has no declaration channel, kit ships one that is **a no-op at
runtime** — an exported const, a module attribute, a class macro — so the
collector is a ~15-line adapter rather than a parser. Those adapters are
`cafe gate`'s job, not kit's; see [Who implements what](#who-implements-what).

### Rust is the model, with one measured correction

`#[ignore = "..."]`'s message is a **documented, stable field of the attribute**,
and it is carried all the way to the output. Declared tier, declared reason and
declared inventory all come from the standard library, free.

The correction is about the collector, and it was **measured, not assumed**,
because the recipe usually quoted does not work on a stable toolchain:

```console
$ cargo test -- --list --format json
error: The "json" format is only accepted on the nightly compiler
       with -Z unstable-options          # rustc 1.95.0, stable
```

So on stable there is no JSON inventory today. The two stable commands that do
work carry what the JSON would have:

```console
$ cargo test -- --list                 # INVENTORY, ignored tests INCLUDED
$ cargo test -- --list --ignored       # the ignored subset
$ cargo test                           # a run prints the reason:
                                       #   test tests::tier_db_needs_postgres
                                       #     ... ignored, anywaye:tier=db reason=…
```

`--list --include-ignored` is a trap, and `templates/tier/rust/tier.rs` says so:
it lists *all* the tests, exactly as `--list` does. `--ignored` is the flag that
filters.

The load-bearing property, and the reason a tier works here and not in JUnit:
**`--list` includes ignored tests.** A test that did not run is still in the
inventory, because the same compiler produced both.

### Bun: measured, and better than the general claim

`bun test` 1.3.12's JUnit reporter was run against a two-test file rather than
assumed:

```console
$ bun test -t "alpha_ran" --reporter=junit --reporter-outfile=r.xml
 1 pass
 1 filtered out
$ grep testcase r.xml
    <testcase name="alpha_ran" .../>
    <testcase name="beta_filtered_out" .../>   # present, empty body
```

So **bun's reporter emits a full inventory** — a filtered-out test is present,
which is the exact property the general claim about JUnit lacks. What it lacks is
a **declared reason**: `test.skip(name, fn)` takes no reason argument, so there
is nowhere to put `reason=needs a live postgres` for an allowlist entry to read.

The filtered-vs-skipped distinction is an **empty child element** versus
`<skipped/>`. That is observed behaviour, not a documented contract, and an
absence of a field is not a promise. Pin the version or do not build on it.

### Ruby: the gap is real, and it is a dependency gap

Minitest 6.0.6, asked directly:

```console
$ ruby -e 'require "minitest"; puts Minitest.constants.grep(/Report|Junit/i)'
[:StatisticsReporter, :ProgressReporter, :SummaryReporter, :Reportable, ...]
```

Every built-in reporter is human-readable text. `minitest-reporters` provides a
JUnit one, but it is a separate gem the service has to add. On plain minitest —
and on Rails, whose default runner *is* minitest — there is **no
machine-readable reporter at all**, and `2 runs, 1 assertions, 0 failures, 0
errors, 1 skips` has nothing in it that addresses a test.

The good news is that Ruby needs no new syntax for the reason: `skip "reason"`
already carries it.

## The normalised result format

One flat format, carrying the three-way distinction JUnit cannot:

```
ran      <tier> <suite-id> <test-id>
skipped  <tier> <suite-id> <test-id> <reason>
filtered <tier> <suite-id> <test-id>
```

`<suite-id>` is the language-relative file the test lives in. `<test-id>` is
**whatever the runner's collector already calls the test** — the Go function
name, the Minitest method name, the Elixir test string. There is no mapping
table to maintain and therefore no id that can mean two different tests in two
different languages.

`kit` owns this contract. `cafe gate` produces it; a service's own suite can
produce it directly, and the simplest version is a line printed to stdout.

## The skip allowlist

[`skip-allowlist`](skip-allowlist), in this directory, is **one file for the
whole fleet**. Its four hygiene rules, and why each exists, are written into the
file itself — read them there, they are the load-bearing part:

1. every entry names a **reason**;
2. every entry names an **owner**;
3. every entry has a **`until`** (and a `since`);
4. **an entry matching nothing is a failure.**

Rule 4 is borrowed from ESLint's `reportUnusedDisableDirectives`, which reports
a disable comment that no longer suppresses anything. Without it the allowlist is
a ratchet that only turns one way, and within two quarters it contains every
test in the repository.

The **total is printed on every run, green included.** Individual entries look
justified; the aggregate is the problem, and an aggregate nobody is shown is an
aggregate nobody watches. Conftest reports exceptions as a separate tally for
this reason.

The gate reads the clock: an expired entry is a failure on the day it expires.
This file is expected to go red about four times a year. That is the design.

**The cost of one file, stated plainly:** a service repo that cannot read kit's
copy at run time — no submodule, no network inside the test step — cannot use
this without one. The alternative, a generated per-repo copy, is a drifting copy
with extra steps, and this repo exists to prevent exactly that. Until a service
needs it, the honest answer is that the decision is untested at that repo.

## `REQUIRED_<TIER>=1`, demanded and not inferred

The gate variable is **demanded**. Set it and zero tests may run:

```sh
REQUIRED_DB=1 go test -tags tier_db -count=1 ./...
```

`gateway`'s `GATEWAY_REDIS_REQUIRED` is the best of the six designs in the fleet and
is the pattern: it fails at **tier-invocation time, before a report exists**, so
nothing downstream can misreport. A run that cannot happen cannot be summarised
as a pass.

`tests/validate.sh` asserts that **every language kit ships a job for also ships
a tier declaration, a documented gate variable, and a `required-tier` input on
the reusable workflow that every language job exports.** The other five services
are not covered yet and each needs its own packet; see the report.

## Floors are decrease detectors, and are not the gate

Identity's `1254/1166`-style floors are cheap and they catch deletion. Keep
them. But name them for what they are:

> **A floor is satisfied by any 1254 tests, including the wrong 1254.**
> It is a decrease detector, not a tier detector.

Nothing about a floor knows which tier a test belongs to, so a floor can be met
by a suite that lost its entire database tier and gained 600 unit tests. It is
a useful, cheap, and strictly weaker thing than the tier gate, and a
documentation page that calls a floor a "tier gate" is worse than one that does
not have a floor at all.

## What this cannot catch

Three things, and all three belong in the documentation of anything that claims
to enforce a tier.

**1. A test that runs but never touches the real dependency.** The machinery can
prove *"41 tests ran"*. Only an assertion **inside** the test proves *"41 tests
hit Postgres"*. Any claim that the tier gate "verifies the DB tier" means the
first thing, never the second. A gate whose documentation overstates it is worse
than no gate.

**2. A package filtered out of the run entirely.** The test that asserts the
tier ran lives *inside* the tier, so it cannot observe its own package's
absence. Identity's separate grep for its `--- PASS:` line is the right instinct
— and it also fails if the package is absent from the log. **Only the
inventory-vs-run set difference catches this.** Both are needed; neither is
sufficient.

**3. A repo disabling its own no-tests guard.** Playwright's guard self-disables
under `--shard`: a scale feature silently disarming a correctness feature.
**No policy rule may be enforced by a flag the checked repo controls.** The
`required-tier` input is a *demand* on the runner and nothing more; if a repo's
runner honours a flag that turns the demand off, the demand was never a demand.

## Who implements what

`kit` ships the **convention**: the declaration per language, the format, the
allowlist and its rules, the workflow demand, and the checks that a service
*declares* a tier and a gate variable.

`cafe gate` ships the **checker**: the per-language collector adapters, the
inventory-vs-run set difference, and the normalised result. It is runtime code
and it belongs beside the tool, not in a config-only repository — and two
packets writing one subsystem at once is a merge collision nobody needs.

The check in `tests/validate.sh` applies the unused-entry rule (rule 4) to the
**templates kit itself ships**, because that is the only inventory kit can see.
The same rule over a service's real run is `cafe gate`'s.
