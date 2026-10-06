# HANDOFF — kit-node-sdk2-01

Packet: `/tmp/wave3/kit-node-sdk2-01.md`. Worktree
`kit-wt-nodefix`, branch `worker/kit-node-sdk2-01`. Committed in the worktree,
not pushed. Two commits: `d905728` (the fix and the gate) and `6df1fb6` (the
check's label).

## Done and verified

- **`hono.ts.snippet` calls none of the four APIs `pins.md`'s versions removed.**
  `spanProcessors: [...]` and `processors: [...]` in the two constructors,
  `trace.setGlobalTracerProvider` + `propagation.setGlobalPropagator` +
  `context.setGlobalContextManager(new AsyncLocalStorageContextManager().enable())`
  in their place. Every claim read out of the published `.d.ts`/`.js` on
  2026-10-06, quoted in the test file's header — see *Evidence* below.
- **The context manager is installed explicitly**, so the `context.with()` in the
  request path means something. This was the expensive defect.
- **`pins.md` gained one row**, `@opentelemetry/context-async-hooks` 2.11.0.
  Evidence: `200` from
  `registry.npmjs.org/@opentelemetry/context-async-hooks/2.11.0`, and
  `sdk-trace-node@2.11.0`'s published `dependencies` pin it at exactly `2.11.0`.
  No row lost. `sdk-trace-node` is removed from the **snippet's install block**
  (its `register()` was the only reason for it) but stays as a `pins.md` row,
  because `pins.md` is a table of the versions the fleet pins, and a service that
  wants the node provider still needs the number.
- **The class is gated**: three new tests in `traceparent.test.mjs`, plus a
  fourth that proves the forbidden list is not a list of phantoms.
- **`README.md`, `templates/otel/node/README.md`, `CHANGELOG.md`** updated.

## The gates

Both were run in the worktree:

```
bash tests/validate.sh --language=node     # EXIT=0  PASS: every check passed.
                                           # note: 5 check(s) skipped
                                           # note: 4 tier(s) ran under a time bound; none was reached.
bash tests/validate.sh --static-only       # EXIT=0  PASS: every check passed.
                                           # note: 6 check(s) skipped
                                           # note: 1 tier(s) ran under a time bound; none was reached.
```

Both run sequentially, on this tree, with **nothing edited while either was in
flight** — see the caution below, which is not hypothetical. Zero `FAIL` rows in
either, and all three `otel/node` rows green in both:

```
PASS templates/otel/node  (3 artifacts present)
PASS otel/node/hono.ts.snippet  (parses as .ts)
PASS templates/otel/node  (the traceparent suite, executed — inbound trace id asserted, and no SDK-2-removed call in the snippet)
```

The two checks this change touches are also runnable on their own, which is what
to reach for while working rather than paying for a whole gate:

```
node --test templates/otel/node/traceparent.test.mjs    # pass 20, fail 0
node --experimental-strip-types --check <copy>.ts       # clean
```

### Do not edit `tests/validate.sh` while the gate is running

One `--language=node` run of this packet died with

```
tests/validate.sh: line 4168: plates/secrets/go && … : No such file or directory
tests/validate.sh: line 4170: local: can only be used in a function
EXIT=1
```

having passed every row up to that point, and the tree was clean. **That exit 1
was self-inflicted**: a label rename inside `validate.sh` was committed while
that run was executing the file, and **bash re-reads a running script by byte
offset** — `plates/secrets/go` is a fragment of `templates/secrets/go`, and
`local:` came from a line the edit split in two. `bash -n` was clean and both
lines are ordinary statements inside a function.

It is recorded because the shape is misleading in the worst way: a gate that
reports a shell syntax error it did not have looks exactly like a tree defect,
and the plausible reaction is to go looking for one in `validate.sh`. The rule
the run teaches is narrow and mechanical: **finish the run before you commit an
edit to the gate, or run the gate from a copy.**

## Evidence: what the pinned versions actually declare

Every one of these is read out of the published package, not from the 1.x docs:

| claim | where it was read |
|---|---|
| `BasicTracerProvider` exists, `extends TracerProvider`, declares only a constructor | `sdk-trace-base@2.11.0 build/src/BasicTracerProvider-shim.d.ts` |
| no `addSpanProcessor`, no `register` | `sdk-trace@2.11.0 build/src/TracerProvider.d.ts` — `getTracer`, `forceFlush`, `shutdown`, and that is the whole class |
| `BatchSpanProcessor(exporter, config)` | `sdk-trace-base@2.11.0 build/src/BatchSpanProcessor-shim.js` — `constructor(exporter, config) { … super({ exporter, ...config }) }` |
| processors are a constructor array | `sdk-trace@2.11.0 build/src/types.d.ts:31` — `spanProcessors?: SpanProcessor[]` |
| `LoggerProvider` has no `addLogRecordProcessor` | `sdk-logs@0.222.0 build/src/LoggerProvider.d.ts` — `getLogger`, `forceFlush`, `shutdown` |
| logs processors option is `processors` | `sdk-logs@0.222.0 build/src/types.d.ts:67` — `processors?: LogRecordProcessor[]` |
| `BatchLogRecordProcessor` STILL takes an options object | `sdk-logs@0.222.0 build/src/types.d.ts:103` — `interface BatchLogRecordProcessorOptions { exporter: LogRecordExporter; … }` |
| `register()` is not removed from the ecosystem, it MOVED | `sdk-trace-node@2.11.0 build/src/NodeTracerProvider.d.ts` — `class NodeTracerProvider extends BasicTracerProvider`, redeclaring `register` |

**One correction to the packet, and it is load-bearing.** The packet said the
logs processor was "the same removal" as the traces one. It is not:
`BatchSpanRecordProcessor` at 0.222.0 takes `{ exporter }`, while
`BatchSpanProcessor` at 2.11.0 takes the exporter positionally. Reading the two
as symmetric is how the snippet ended up with a positional exporter on one side
and an options object on the other being treated as an inconsistency rather than
as what it is. The snippet now keeps the asymmetry and comments it, because the
next reader's instinct will be to "tidy" it.

`@opentelemetry/context-async-hooks@2.11.0` exports both
`AsyncHooksContextManager` and `AsyncLocalStorageContextManager`
(`build/src/index.d.ts`); the latter is what the snippet installs.

## Planted-failure evidence

All six planted defects, reverted after each. `templates/otel/node/traceparent.test.mjs`
only — nothing else was touched.

| # | planted | red |
|---|---|---|
| 1 | `provider.addSpanProcessor(new BatchSpanProcessor(e))` | `not ok 17 — hono.ts.snippet calls NO API that pins.md's versions removed` / `provider.addSpanProcessor() does not exist on the versions pins.md pins. SDK 2.x removed it; processors go in the constructor as spanProcessors: [...]` |
| 2 | `new BatchSpanProcessor({ exporter: … })` | same test / `the constructor is (exporter, config) — an options object becomes a _exporter that is an OBJECT, and the processor fails on its first export instead of at boot` |
| 3 | `loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(e))` | same test / `loggerProvider.addLogRecordProcessor() does not exist on the versions pins.md pins. SDK 2.x removed it; processors go in the constructor as processors: [...]` |
| 4 | `provider.register({ propagator: new W3CTraceContextPropagator() })` | `not ok 18` / `provider is a BasicTracerProvider and SDK 2.x removed register() from the base provider — it is on NodeTracerProvider only. It is also what used to install the CONTEXT MANAGER…` |
| 5 | `…ContextManager()` un-enabled | `not ok 18` / `a context manager must be installed EXPLICITLY, and ENABLED: without one context.active() is ROOT_CONTEXT…` |
| 6 | the `setGlobalContextManager` line deleted | `not ok 18`, same finding |

Plus two on the check itself:

| # | planted | red |
|---|---|---|
| A | a typo in one `SDK_2_REMOVED_CALLS` regex (`addLogRecordProcessorXXX`) | `not ok 19 — the SDK 2.x removals above are REAL removals, not a list of phantoms` / `the planted 1.x call … matched no row — SDK_2_REMOVED_CALLS has a pattern that cannot fire, so that row is decoration rather than a check` |
| B | a **comment** naming `provider.addSpanProcessor(` in the snippet | **green** (20/20) — and that is the point: it proves `stripComments` runs before the fence, so prose about a removed call cannot satisfy the check. A green control that is green for the right reason. |

Revert after all eight: `pass 20  fail 0`.

## Decisions that were not forced

1. **`BasicTracerProvider` + explicit globals, not `NodeTracerProvider` +
   `register({ contextManager })`.** The latter is one line shorter and would keep
   the `sdk-trace-node` row live in the snippet. Rejected because it makes the
   context manager an argument of a call whose name says nothing about it — the
   defect this packet exists to remove is precisely that the context manager was
   installed by a side effect nobody was looking at. `parlor` reached the same
   reading independently; a template that matches the one service in the fleet
   that has already been bitten is worth more than a line count.
2. **`@opentelemetry/sdk-trace-node` dropped from the snippet's install block.**
   Rejected alternative: leaving it, on the grounds that a row in `pins.md`
   ought to appear in some snippet. It is now used by nobody in this tree, and
   `bun add`-ing a package for `register()` — which the snippet must not call —
   teaches the wrong thing. The `pins.md` **row** stays, and the snippet says why.
3. **The gate went into `traceparent.test.mjs`, not into `validate.sh`.** The
   suite already reads the snippet with `stripComments` for the `Headers` getter,
   it already runs in the static phase under both flag spellings, and a shell
   check would have been a second reader of the same file with a weaker comment
   stripper. That last part is the deciding one: kit's own rule is that a check a
   comment can satisfy is not a check, and a `grep` in `validate.sh` could not
   satisfy that rule without reimplementing the stripper.
4. **The forbidden list is a table, and a fourth test runs a planted call against
   every pattern.** Rejected alternative: four inline assertions, which is what
   the packet literally described. It would have been a check that goes stale
   silently when a fifth removal lands, and — worse — a typo in one regex would
   have been invisible forever. `stack_live_test.sh`'s own header is the warning:
   a control that cannot fail is not a control.
5. **`register()`'s receiver is DERIVED from the snippet, not hardcoded.** The
   packet asked for a check on "a provider that is not a `NodeTracerProvider`".
   A whitelist of receiver *names* would be satisfiable by renaming the variable,
   so the test finds `(\w+)\s*=\s*new\s+BasicTracerProvider\s*\(` and forbids
   `.register()` on whatever it found. A separate assertion requires a
   `BasicTracerProvider` to exist at all, so a snippet that quietly stopped
   building one cannot pass the rest of the file vacuously.
6. **`CHANGELOG.md` entries are long.** The file's existing entries are, and the
   short form of this one would have lost the distinction between the four
   failures — three loud, one silent — which is the part a reader needs.

## What I deliberately did NOT do

- **`traceparent.mjs` is untouched, and it should be.** The packet asked whether
  the snippet's `context.with` reasoning and that module's codec still agree.
  They do, and the agreement is a *negative* one worth recording: the codec is
  stdlib-only by design and has no ambient context at all, so there is nothing in
  it to drift. `serverHop(headers, spanId)` takes the span id as a **parameter**,
  which is exactly why its no-context-manager failure is *visible* — a missing
  context is a wrong argument at the call site. That is the opposite of the
  snippet's failure mode and the codec's design already avoids it. No change.
- **No sibling repository was edited.** `parlor`, `site`, `core` — read only.
- **No `templates/otel/<other lang>/` snippet was touched.** Four other languages
  have their own provider-construction APIs and their own removal histories. I
  did not read them and I am not claiming anything about them; see findings.
- **No repo-wide audit, no reformat, no unrelated doc cleanup.** I noticed
  things (below) and left them.
- **Did not add a check to `validate.sh` that reaches npm.** pins.md's own
  argument is that a gate which resolves versions goes red when npm is down, and
  I agree with it. Consequence, stated rather than hidden: **this check is a
  source-shape check.** It proves the four *spellings* are absent; it cannot
  prove the code behaves. What it buys is that these four defects are spellings,
  and a spelling cannot come back by accident. A NEW removal in a later SDK
  release will not be caught until a row is added to `SDK_2_REMOVED_CALLS` —
  which is one row, and the table exists so that it is one row and not a
  redesign.
- **Did not touch `templates/otel/go/`, ruby, elixir, python or rust**, and did
  not verify their snippets against their pins. Out of scope and unverified.
- **Did not rename the `traceparent.mjs` module or restructure the node
  directory**, though `hono.ts.snippet` and the codec now overlap in what they
  claim. The overlap predates this packet.

## Sibling findings — packets, not fixes

1. **`parlor/HANDOFF-otel-01.md` §2.3 is now partly stale and is quoted by
   kit's own prose.** It says `provider.register({ propagator })` → "removed" and
   suggests `trace.setGlobalTracerProvider` + `propagation.setGlobalPropagator`.
   That is correct but **incomplete**, and the incompleteness is exactly the trap:
   those two lines alone install **no context manager**, which is the expensive
   half. It also does not mention `BatchLogRecordProcessor` at all. It is
   `parlor`'s file — I did not edit it — but any sibling that cited it will
   reproduce this defect.
2. **`core/schemas/telemetry/otel-endpoint.schema.json` carries no OTel version**,
   so kit's `pins.md` and a service's `package.json` cannot be checked against
   each other at all. That is the gap that let a snippet and its own pins file
   disagree for as long as they did, and it is a bigger fix than a template patch.
   Raised by `parlor` §2.2 and confirmed by reading this packet's own evidence.
3. **`templates/otel/go|rb|ex|py|rs` snippets have not been read against their
   pinned versions.** This packet found four wrong calls in ONE language's
   snippet; the same "written against 1.x, pins say 2.x" reasoning applies to
   `addSpanProcessor` analogues on the Java/Ruby/Python SDK lines and I have not
   checked a single one. Recommend a packet that reads each snippet's provider
   construction against its own published package, the same way this one did.
4. **`template/otel/node/README.md` says identifiers come from
   `crypto.getRandomValues`.** They come from `node:crypto`'s `randomBytes`
   (`traceparent.mjs:33`). Pre-existing, one line, unrelated to this packet —
   left alone rather than swept.
5. **`templates/otel/node/README.md` recommends `telemetry: 'true'` as the way to
   run the suite in CI**, while the suite has in fact been executed by
   `validate.sh`'s static phase since an earlier packet. The advice is not wrong
   (a service that adopts it does not get kit's own gate), but a reader may
   conclude kit does not run it, which is the belief that cost this snippet its
   whole history of unexecuted assertions. Not changed — it is `README.md`'s call.

## Currently-failing command

**None.** Both gate spellings pass with the exit code observed directly
(§ *The gates*), zero `FAIL` rows, and the worktree clean. Nothing is failing,
skipped past, or unverified in this packet.

## The successor's first move

1. Nothing must be re-verified. The remaining work is not this packet's:
   extend `SDK_2_REMOVED_CALLS` on the next OTel bump, and read the other five
   languages' snippets against their own pins (findings 1 and 3).
2. **Extend `SDK_2_REMOVED_CALLS` the next time an OTel release is bumped.** That
   table is the only place a new removal gets covered, and a missing row is
   invisible by construction. It is the same "an entry matching nothing is a
   failure" rule kit applies to the tier skip allowlist, and it is deliberately
   the same *shape* of maintenance.
3. If you want the check to be stronger than source shape, the only honest route
   is finding 2: put a version in `core`'s schema so a service's
   `package.json` and kit's `pins.md` can be compared. That is a cross-repo
   change and needs its own packet.