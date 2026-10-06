# OTel dependency pins

Versions referenced by the `*.snippet` files. kit does **not** vendor any of
these and does not depend on any of them — the snippets are documentation you
copy, and the `traceparent.*` files beside them are stdlib-only so the
conformance suite runs with no network and no lockfile.

## Why a pins file at all

A version in a comment rots. A version in a file with a check on it does not.
This file exists so that:

1. Every snippet's `go get` / `bun add` / `bundle add` / `mix deps.get` /
   `pip install` / `cargo add` line states a **concrete** version, so a reader
   copying it gets something that resolves rather than a floating major that
   moved three minors ago.
2. `tests/validate.sh` asserts those lines still parse and still name all six
   languages, so deleting a snippet's install block fails the gate instead of
   quietly shipping a template that cannot be installed.

**And every row below is a version that was actually RESOLVED**, by a service in
this fleet, against the real registry or the real module proxy. That is a
stronger claim than "a version that sounds current" and it is the only one worth
making: see *Why these were checked rather than chosen* below.

## The versions

| Language | Packages | Version |
|----------|----------|---------|
| go | `go.opentelemetry.io/otel`, `.../sdk`, `.../trace` | 1.46.0 |
| go | `.../exporters/otlp/otlptrace`, `.../otlptracehttp`, `.../otlptracegrpc` | 1.46.0 |
| go | `.../otlpmetric`, `.../otlplog` | 1.46.0 / 0.11.0 |
| go | `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` | 0.63.0 |
| ruby | `opentelemetry-sdk` | 1.13.1 |
| ruby | `opentelemetry-exporter-otlp` | 0.37.0 |
| elixir | `:opentelemetry` | 1.7.0 |
| elixir | `:opentelemetry_exporter` | 1.11.0 |
| rust | `opentelemetry`, `opentelemetry_sdk`, `opentelemetry-otlp` | 0.27.0 |
| rust | `opentelemetry-semantic-conventions` | 0.27.0 |
| python | `opentelemetry-api`, `opentelemetry-sdk` | 1.44.0 |
| python | `opentelemetry-exporter-otlp` | 1.44.0 |
| python | `opentelemetry-instrumentation-fastapi` | 0.65b0 |
| node / bun | `@opentelemetry/api` | 1.9.1 |
| node / bun | `@opentelemetry/core`, `.../resources`, `.../sdk-trace-base` | 2.11.0 |
| node / bun | `@opentelemetry/context-async-hooks` | 2.11.0 |
| node / bun | `@opentelemetry/semantic-conventions` | 1.38.0 |
| node / bun | `@opentelemetry/sdk-trace-node` | 2.11.0 |
| node / bun | `@opentelemetry/exporter-trace-otlp-proto` | 0.222.0 |
| node / bun | `@opentelemetry/api-logs`, `.../sdk-logs`, `.../exporter-logs-otlp-proto` | 0.222.0 |

**Where each row's truth came from**, so a reader can go and re-derive it rather
than trust this table:

| Language | Read out of |
|----------|-------------|
| go | `identity/go.mod`, `gateway/go.mod`, `pantry/go.mod` — three independent services, all agreeing on 1.46.0 |
| ruby | `billing/Gemfile.lock` (resolved, not the `~>` floor) |
| elixir | `courier/mix.lock` |
| python | `muse/uv.lock` |
| node / bun | `parlor/package.json`, plus `sdk-trace-node@2.11.0`'s own
  `dependencies`, which pin `@opentelemetry/context-async-hooks` at `2.11.0`
  exactly |
| rust | no service in the fleet runs rust yet; the row is the crate's own published version and is **unverified against a real install** — see the caveat below |

## Why these were checked rather than chosen

The previous version of this table named a package set that **cannot be
installed**, and the reason it survived review is worth recording: every row
looked like a plausible version number, and none of them had been resolved.

Two rows named versions that **do not exist at all**:

| Row said | Registry says |
|---|---|
| `@opentelemetry/api@2.0.0` | **404.** There is no 2.x. The highest published 1.x is `1.9.1`. |
| `@opentelemetry/sdk-trace-node@0.57.0` | **404.** That package is at 2.x (`2.11.0`). |

And the rest were mutually contradictory in a way that only a resolution attempt
reveals. `@opentelemetry/sdk-trace-base` and every other SDK package in this
ecosystem declare:

```json
"peerDependencies": { "@opentelemetry/api": ">=1.3.0 <1.10.0" }
```

so `api@2.0.0` could never satisfy **any** of them. The table also paired
`sdk-trace-base@2.0.0` with `exporter-trace-otlp-proto@0.57.0`, and that
exporter depends on `sdk-trace-base@1.30.0` — contradicting the row above it. A
`bun install` of the old table resolves to a resolver error naming three
conflicts, not to a working tree.

**The failure mode this whole file is vulnerable to is `yarn add` succeeding on
one row and failing on the next**, which is why the assertion is *installed
truth*, not *a number that looked current*. See `HANDOFF-otel-01.md` §2.2 in
`parlor` for the same reconciliation reached independently, and
`HANDOFF-otel-01.md` §2.3 for the API removals that arrived with the 2.x line.

**The rust row is the one thing here that is not fleet-verified**, because no
service in the fleet is written in rust. It is stated as the crate's published
version and it has not been resolved by a real `cargo add`; treat it as the one
row to check first when the first rust service lands.

## These are placeholders, on purpose

Same rule as `templates/mise.toml`: **a service pins to the version it
deploys.** When you copy a snippet into your repo, raise these to the current
release in your language's own ecosystem and record the choice in your
`CHANGELOG.md`. A version that is right for every cafaye service is a version
that is right for none of them a year from now.

What is *not* a placeholder is the rule each version encodes:

- **`@opentelemetry/api` before `@opentelemetry/sdk-*`.** The api package is the
  version floor; an sdk newer than its api is a build that compiles and then
  fails to record spans at runtime. The bound is explicit and enforced by the
  SDK's own `peerDependencies` — the api is **1.9.1** while the sdk line is
  **2.11.0**, and those are not the same track. Reading that as a version skew
  to be corrected is the mistake; the 1.x/2.x split is the ecosystem's, and
  `1.9.1` is correct *because* it is inside `>=1.3.0 <1.10.0`.
- **`instrumentation-*` tracks the sdk minor.** A `0.65b0` instrumentation
  against a `1.53` sdk is a silently-uninstrumented app, not a build error.
- **Batch processors, never simple ones, in any production path.** One export
  per span makes the collector the bottleneck and drops spans on a slow
  network.
- **A 2.x SDK is not the 1.x SDK with a bigger number, and the removals are the
  reason this file is a table rather than a comment.** Four calls the 1.x docs
  teach do not work as taught on these versions, and **one of the four fails
  silently rather than loudly**, which is what earns it a row as much as the
  three loud ones do:

  | removed in 2.x | replacement | how it fails |
  |---|---|---|
  | `provider.addSpanProcessor(p)` | `spanProcessors: [p]` in the constructor | TypeError at boot — loud |
  | `provider.register({...})` | `trace.setGlobalTracerProvider`, `propagation.setGlobalPropagator`, `context.setGlobalContextManager` | TypeError at boot — loud |
  | `new BatchSpanProcessor({ exporter })` | `new BatchSpanProcessor(exporter)` | **silently**, on the first export |
  | `loggerProvider.addLogRecordProcessor(p)` | `processors: [p]` in the constructor | TypeError at boot — loud |

  The `BatchSpanProcessor` row is the one to read twice, because it is the only
  one that is not a compile error and because it is **not** symmetrical:
  `BatchLogRecordProcessor` in `sdk-logs@0.222.0` still takes an options object
  with an `exporter:` property. Read out of the published packages on
  2026-10-06, not from memory — see *What the gate checks* for how far the gate
  reaches on this.
- **A 1.x `register()` installed a context manager as a SIDE EFFECT, so dropping
  the call without replacing it is a defect nobody sees.** Without a global
  context manager `context.active()` is `ROOT_CONTEXT` for the life of the
  process, `context.with()` is a no-op that still runs its callback, and every
  span started under it is a **root** span: a fresh trace id, no parent, and a
  correctly-populated span in the trace view. That is
  `@opentelemetry/context-async-hooks`'s whole job, and it is a row here for
  that reason rather than because a snippet happened to import it.
- **Check that a version EXISTS before you write it down.** Every fiction in the
  previous table was plausible to type and wrong to install. `curl -o /dev/null
  -w '%{http_code}' https://registry.npmjs.org/<pkg>/<version>` answering `404`
  takes one second and is the whole test.

## What the gate checks

`tests/validate.sh` asserts, for every language directory:

- the `*.snippet` file exists (artifact presence),
- it contains at least one install line naming a version — a snippet with no
  `go get` / `bun add` etc. is a snippet nobody can install, and
- it never contains a floating `@latest` or a bare `^`/`~` with no version.

**And, for node specifically, `templates/otel/node/traceparent.test.mjs` asserts
that `hono.ts.snippet` calls none of the four APIs the table above lists as
removed.** It reads the snippet's source, strips comments first, and fails on
any of them — plus it requires the two globals and the context manager to be
present. That test is EXECUTED by `tests/validate.sh` in the static phase, so it
runs under both `--static-only` and `--language=node`.

**What that check can and cannot do, stated plainly:** it is a check on the
SNIPPET'S SOURCE SHAPE, not on the behaviour of an installed SDK. kit vendors no
OTel tree and installs nothing, so the strongest form of this assertion —
compile the snippet against the pinned versions and run it — is not available to
this repository without giving it a network dependency and a lockfile the next
paragraph explains is deliberate. What a source-shape check does buy is the
property that matters: every one of these four calls is a **spelling**, and a
spelling cannot come back by accident. A *new* removal in a later SDK release
will not be caught until a row is added here, which is the same one-row cost as
adding a row to the version table above.

**What the gate cannot check, stated plainly rather than implied:** it does not
resolve these versions against a registry or a module proxy, because that would
give kit a network dependency and a lockfile it deliberately does not have — and
because a gate that reached npm to decide whether a comment is right is a gate
that goes red when npm is down. The existence of each row is therefore a
**documented, dated, re-derivable claim** (the table above says where to re-derive
it), not a checked one. The gate catches a *deleted* install block and a
*floating* one; it cannot catch a *wrong* one. That gap is the honest state of
this file, and it is why every row names the repository it came from.

A vendored OTel tree would be caught by the existing "no third-party
dependency" check on `templates/otel/go/go.mod` and `templates/otel/node/`.