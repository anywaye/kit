# W3C traceparent — TypeScript (Hono, Node and Bun)

Hono's trace propagation, so a request that enters one cafaye service and
leaves it another still reads as **one** trace in a trace view rather than two
unrelated ones.

## Which of the two files do I use

| File | Use it when |
|------|-------------|
| `traceparent.mjs` | You need the header handling **on its own**: a queue consumer with no HTTP server, a webhook signer, a background task, or a test that asserts propagation without standing up an SDK. Stdlib only, no dependencies. |
| [`hono.ts.snippet`](./hono.ts.snippet) | You are serving Hono's requests. The upstream OpenTelemetry SDK already implements all of this and also gives you spans, metrics and a trace UI. Versions are in [../pins.md](../pins.md); kit vendors nothing. |

The snippet is the right answer for a new service. The codec exists for the
cases the SDK does not reach, and for a service that does not want an exporter
at all.

**Keep the suite either way.** If you use the snippet you are trusting the SDK
— and this suite is the test that a future SDK bump did not change what
propagates.

## The contract

- A valid inbound `traceparent` is **continued**: same trace-id, sampled flag
  preserved, parent-id replaced with this hop's span id (§3.4).
- A **missing or malformed** `traceparent` starts a new trace and never throws,
  never returns 4xx, never panics. A request is not an error because its trace
  header was garbage (§3.2.2.3, §4.2).
- `tracestate` travels with the trace, capped at 512 characters, truncated on
  whole-entry boundaries only (§3.3.1.5).
- A `traceparent` that fails to parse is **not** rescued by a `tracestate`
  alongside it (§3.3) — a tracestate alone is invalid and discarded (§4.2).
- Header names are matched case-insensitively and always sent lowercase (§3.2.1).

## Wiring it in

```ts
// Inbound, Hono middleware.
const hop = serverHop(c.req.raw.headers, newSpanId());
c.set("traceId", hop.traceId);

// Outbound, any fetch.
await fetch(url, { headers: outboundHeaders(hop) });
```

For more than a few calls prefer `tracedFetch` in `hono.ts.snippet`: it reads
the active context from the SDK, so there is no way to forget to pass the hop.
The codec is here for the cases that are not a request.

## Spec sections implemented

Every one of these is asserted in `traceparent.test.mjs`:

| Section | Rule |
|---------|------|
| §3.2.1 | header name accepted in any case, sent lowercase |
| §3.2.2.1 | version is 2 hex chars; `ff` forbidden |
| §3.2.2.2 | version-00 header format, exactly 55 characters |
| §3.2.2.3 | all-zero trace-id is invalid → ignore the header |
| §3.2.2.4 | all-zero parent-id is invalid → ignore the header |
| §3.2.2.5 | trace-flags is a bit field, masked on read |
| §3.2.2.5.1 | sampled is the only defined flag in version 00 |
| §3.2.2.5.2 | reserved flags MUST be zero on the wire |
| §3.2.4 | higher version: parse positionally, re-emit at 00, drop unknown fields |
| §3.3 | a failed traceparent MUST NOT be rescued by a tracestate |
| §3.3.1.5 | tracestate: ≥512 chars, truncate whole entries only |
| §4.2 / §4.3 | no traceparent → new trace; invalid → restart, never an error |

## Run the suite

```sh
node --test traceparent.test.mjs

# Bun runs the same file unchanged:
bun test traceparent.test.mjs
```

`node:test`, `node:assert` and `node:crypto` are all stdlib. Both runners pass on the same `.mjs` with no build step, which is why gateway and parlor (bun) and every node service share one implementation instead of two.

The suite needs **no dependencies and no network** — that is the point of the
codec. If it ever needs a `go mod download` or a `bundle install`, this
template has grown a dependency and kit has stopped being config-only.

Header lookup is case-insensitive because Hono lowercases but a `fetch` forward, a test double, or a hand-built `Headers` will not — and a codec that is strict here breaks traces in production for no reason.

Identifiers come from `crypto.getRandomValues`, the WebCrypto API both runtimes expose, rather than `Math.random`.

## Turn it on in CI

Copy this directory into your service — `templates/otel/node/` — and call
kit's reusable workflow with `telemetry: 'true'`:

```yaml
    with:
      language: node        # or `bun`: the suite runs unchanged on both
      telemetry: 'true'
```

That job is opt-in, so adopting kit never turns a green repo red. Once it is
on, this suite runs on every push and a broken codec is a red build rather than
a paragraph in a README.

## Reference

W3C Trace Context, W3C Recommendation 23 November 2021 —
<https://www.w3.org/TR/trace-context/>
