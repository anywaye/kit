# W3C traceparent — Go

Go's trace propagation, so a request that enters one anywaye service and
leaves it another still reads as **one** trace in a trace view rather than two
unrelated ones.

## Which of the two files do I use

| File | Use it when |
|------|-------------|
| `traceparent.go` | You need the header handling **on its own**: a queue consumer with no HTTP server, a webhook signer, a background task, or a test that asserts propagation without standing up an SDK. Stdlib only, no dependencies. |
| [`otelhttp.go.snippet`](./otelhttp.go.snippet) | You are serving Go's requests. The upstream OpenTelemetry SDK already implements all of this and also gives you spans, metrics and a trace UI. Versions are in [../pins.md](../pins.md); kit vendors nothing. |

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

```go
// Inbound, in your HTTP middleware.
hop := kitotel.ServerHopFrom(req.Header, kitotel.NewSpanID())

// Outbound, on your client.
req.Header = http.Header(hop.OutboundHeaders())
```

`ServerHopFrom` cannot fail — that is the design, not an omission. For a NATS
or queue consumer there is no `http.Header`, so pass the handful of headers you
received as a `map[string]string`; lookup is case-insensitive (§3.2.1).

`TraceParent` and `ServerHop` are plain structs with exported fields, so a
service that wants a field the template does not have adds it rather than
wrapping it — one more hop between a header and a log line is one more thing to
forget.

## The two exporter defects, measured in the fleet

**Read this before choosing an exporter option.** Both of these produce a
service that constructs spans, builds a valid exporter, opens a socket to the
collector, and records **nothing anywhere**. Neither throws. Neither logs. From
HyperDX the two are identical to a service that emits no telemetry at all, which
is the state the fleet measured on 2026-09-30 and why two services reached it
independently.

### 1. `WithEndpointURL` does NOT append `/v1/traces`

`otlptracehttp.WithEndpointURL` treats its argument as a **complete address**.
A pathless URL normalises to `/`. The SDK ships a test asserting exactly that —
`TestWithEndpointURLNoPathUsesRootPath` — and its documentation says the default
path is not appended.

That is a defensible reading of "endpoint URL", and it is the wrong reading of
what `<SERVICE>_OTEL_ENDPOINT` **means** in this fleet. The variable is a **base
URL**, and its shipped default (`http://otel-collector:4318`) is scheme, host
and port with no path:

```
otel-collector:4318  →  POST http://otel-collector:4318/            → 404, dropped
otel-collector:4318  →  POST http://otel-collector:4318/v1/traces   → recorded
```

The SDK's own **environment-variable** reader does the right thing — it applies
`path.Join(u.Path, DefaultTracesPath)` — so a service configured through
`OTEL_EXPORTER_OTLP_ENDPOINT` gets the signal path and a service that constructs
the URL itself does not. Both are the same fleet default; they disagree.

**Re-measured against the SDK the fleet actually runs (v1.46.0), with a receiver
shaped like the collector's** — 200 on `/v1/traces`, 404 elsewhere — so this is
not a claim about a version you do not deploy:

```
WithEndpointURL("http://127.0.0.1:PORT")            → POST /            → 404, dropped
WithEndpointURL("http://127.0.0.1:PORT/v1/traces")  → POST /v1/traces   → recorded
```

The mechanism is three lines in the shared `otlpconfig` package, and the comment
the SDK puts on them names the whole defect:

```go
cfg.Traces.URLPath = u.Path
if cfg.Traces.URLPath == "" {
    // For HTTP exporters, a URL without a path targets the root path. Set it
    // explicitly so the default signal path is not appended by cleanPath.
    // (URLPath is ignored by gRPC exporters.)
    cfg.Traces.URLPath = "/"
}
```

Read the parenthetical: **`URLPath` is ignored by gRPC exporters.** That is why
this defect is an OTLP/HTTP defect and the TLS one below is a gRPC defect, and
why choosing the other transport does not inherit the other's fix.

**The append lives in ENDPOINT NORMALISATION, not in a switch to
`WithEndpoint(host, port)` plus `WithURLPath`.** One place already normalises
every other spelling an operator will type — bare `host:port`, trailing slash,
base path behind a reverse proxy — and this is just the next rule it applies.
Use `path.Join`, the SDK's own rule, so `https://otlp.example.com/anywaye`
becomes `/anywaye/v1/traces`, byte-identical to what the SDK's own configuration
would produce.

**Make it IDEMPOTENT.** An operator who named `/v1/traces` in the variable is
left alone: `otel-collector:4318/v1/traces` is an address somebody chose, and a
normalisation layer that appended to it would be making that choice for them.
`path.Join` cleans the path but does not know `/v1/traces/v1/traces` was not
intended, so guard the append on a suffix check.

**Why 525 lines of tests never caught it.** Every observability test in the
affected service asserted against a `tracetest.SpanRecorder` — a recorder
installed *in place of* the exporter, which never builds a client and never
sends a byte. A suite that cannot see the wire cannot see a request to the
wrong URL. And the one test that looked at the endpoint asked the wrong
question: it asserted the constructor returns no error, which is not the same
claim as *a span arrives somewhere*. **At least one test in your service must
stand up a receiver and assert the bytes arrived.**

### 2. The exporter must NOT dial TLS at a plaintext collector

`otlptracegrpc` **defaults to TLS**. core's shipped default endpoint is
`http://otel-collector:4317` — the scheme is `http`, and the scheme is load-
bearing, not decoration.

Without `WithInsecure()`, the handshake never completes against a plaintext
collector. Confirmed before the fix, with `lsof` against a real OTLP receiver
listening on the configured port: the listener and nothing else, on every
command. The failure was swallowed by the error handler installed for
`noOp.warnings`, so the exporter exported nothing and said nothing about it.

Every test in that service's emitter package **passed** with the wrong setting,
because they injected an exporter. Which is why that repository grew four wire
tests that run against a real receiver, and why the note on them is *run them
once with the fix reverted to confirm they still bite*.

**Which option you hold decides whether you have this bug**, and this is worth
stating precisely because it decides how you read the rest of this file. The
same `otlpconfig` line that causes defect 1 also sets the transport:

```go
cfg.Traces.Insecure = u.Scheme != "https"
```

So:

- **`WithEndpointURL("http://otel-collector:4317")` is already plaintext.** The
  scheme is read and TLS is off. You do not need `WithInsecure()` and must not
  add it — `WithEndpointURL` is applied in option order, so a later
  `WithInsecure()` is harmless but a later `WithEndpoint()` silently wins over
  the URL entirely (both option sets say so in their own docs: *"If both this
  option and WithEndpointURL are used, the last used option will take
  precedence"*). Option order is a real footgun here and it is spelled out in
  the SDK rather than left to be discovered.
- **`WithEndpoint("otel-collector:4317")` is TLS unless you say otherwise.**
  `WithEndpoint` takes a bare `host:port` and has no scheme to read, so
  `Insecure` keeps its default of `false`. **This is the shape that shipped the
  bug**, and it is why a service reading the scheme must keep the scheme long
  enough to decide.

**Re-measured against v1.46.0, in both directions, because a one-directional
test cannot tell a scheme-aware exporter from one that is simply always
plaintext** — which is a different bug with the same symptom for a self-hoster.
Against a plaintext listener, reading the first bytes off the socket (a plaintext
gRPC client opens with the HTTP/2 preface `PRI * HTTP/2.0`; a TLS client opens
with a ClientHello record):

```
WithEndpointURL("http://127.0.0.1:PORT")   -> plaintext gRPC client, preface confirmed
WithEndpointURL("https://127.0.0.1:PORT")  -> TLS attempted, "authentication handshake failed"
```

The second line is the CONTROL. Without it, the first is satisfied by an exporter
that ignores the scheme entirely.

**The rule that covers both shapes: decide TLS from the SCHEME, before you strip
it.** Only `https` is secure. `http`, `grpc` and a bare `host:port` are all
plaintext — and the bare form must be plaintext, because it is what a
self-hoster writes when the collector is on the same host, and an operator who
writes no scheme is saying "the address", not "the encryption". Case-fold the
comparison, because a URL scheme is case-insensitive and a person typing
`HTTPS://` means exactly what they mean by `https://`. Getting this wrong in the
other direction is the silent failure.

### Both receivers are legitimate — pick by the port, not by taste

The shipped collector runs **both** OTLP receivers, and both are correct answers:

| | gRPC, `http://otel-collector:4317` | HTTP, `http://otel-collector:4318` |
|---|---|---|
| Go package | `otlptracegrpc` | `otlptracehttp` |
| Signal path | n/a — the protocol carries it | **`/v1/traces`, which you must append** |
| TLS default | **on** — needs `WithInsecure()` for the fleet default | follows the URL scheme |
| Toolkit default | **this one** — see below | the other one |

**gRPC on 4317 is the generator's default and the contract's `transport`
default**, so it is the answer with the fewest surprises. HTTP on 4318 is the
address most of the fleet's `<SERVICE>_OTEL_ENDPOINT` defaults are already
written against, and it is what the Elixir and Python SDKs this fleet ships
speak, so one port and one ingestion point can serve several languages.

Either is legitimate. The two things that are **not** legitimate are the two
defects above — and note that they attach to *different* exporters, so choosing
the other transport does not escape both: an HTTP exporter still needs the path
appended, and a gRPC exporter still needs plaintext stated. Neither is a
default you inherit correctly.

Choosing HTTP is **not** a way to keep gRPC out of your binary: the HTTP
exporter shares its configuration package with the gRPC one, so `grpc`,
`grpc-gateway`, `genproto` and `protobuf` are in the module graph either way.
The choice is about which port and which wire format.

### The third one, because it is the same shape

Neither the queue nor the retry is a free choice, and the SDK's defaults are
the opposite of this fleet's rule: `sending_queue: enabled` and
`retry_on_failure: enabled`. State both as **disabled**.

A retry loop against a dead collector is a goroutine waking on a timer for the
life of the process, invisible in every dashboard because nothing is being
recorded. A queue that accepts spans and holds them is a memory leak with a
telemetry-shaped trigger. Losing a span is strictly better than becoming a slow
service — and, per defect 1, with the queue off a misdirected request is dropped
silently rather than retried, which is why that defect survived a green suite.

**Do not add `WithDialOption(grpc.WithBlock())` to a CLI.** Without it the dial
is asynchronous: constructing an exporter starts no connection, blocks on
nothing, and fails nowhere. With it, a command that has no collector to talk to
waits out a context timeout before printing anything — in the one place core's
no-op contract says the cost must be `none`. A telemetry backend that makes the
binary slow to start is a telemetry backend that gets turned off.

## Spec sections implemented

Every one of these is asserted in `traceparent_test.go`:

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
GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test ./...

# One test:
go test -run TestKnownTraceparentIsContinued ./...
```

It is a normal Go test — no build tags, no separate runner, no `go mod download` (`GOPROXY=off` above proves it).

The suite needs **no dependencies and no network** — that is the point of the
codec. If it ever needs a `go mod download` or a `bundle install`, this
template has grown a dependency and kit has stopped being config-only.

Identifier generation uses `crypto/rand`, not `math/rand`: trace ids end up in logs and in traces that leave the process, and a predictable trace id is an invitation to correlate two users' requests by guessing.

## Turn it on in CI

Copy this directory into your service — `templates/otel/go/` — and call
kit's reusable workflow with `telemetry: 'true'`:

```yaml
    with:
      language: go
      telemetry: 'true'
```

That job is opt-in, so adopting kit never turns a green repo red. Once it is
on, this suite runs on every push and a broken codec is a red build rather than
a paragraph in a README.

## Reference

W3C Trace Context, W3C Recommendation 23 November 2021 —
<https://www.w3.org/TR/trace-context/>