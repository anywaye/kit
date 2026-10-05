// kit template — W3C Trace Context propagation for a Hono/TypeScript service.
//
// Copy traceparent.mjs and this file into your service, then run
// `node --test test/traceparent.test.mjs` (or whatever your test runner is
// wired to). The suite is the contract: it proves the template still continues a
// trace instead of quietly restarting it.
//
// REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
// https://www.w3.org/TR/trace-context/ — every rule asserted below cites the
// section that requires it.
//
// WHAT IT PROMISES
//   - A valid inbound traceparent is continued: same trace-id, sampled flag
//     preserved, parent-id replaced with this hop's span id (§3.4).
//   - A missing or malformed traceparent starts a new trace and never throws. A
//     request is not a 500 because its trace header was garbage.
//   - tracestate travels with the trace, capped at 512 characters and truncated
//     on whole-entry boundaries (§3.3.1.5).
//
// No dependencies: node:test, node:assert and node:crypto are all stdlib. The
// @opentelemetry/* packages are referenced by version in hono.ts.snippet, not
// imported here — kit has no dependencies and this suite must run without one.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { newSpanId, newTraceId, parseTraceparent, serverHop } from "./traceparent.mjs";

/**
 * Strip JS comments, so a check over a source file cannot be satisfied by prose.
 *
 * Both forms, and not just one: a `/* … *\/` block can hide a whole explanation
 * that names the very identifier the check looks for, and a `// …` line can hide
 * the call itself. Strings are not parsed — the snippet under test contains no
 * string literal with a `//` in it, and a hand-rolled string scanner here would be
 * a second parser to get wrong.
 */
function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^[ \t]*\/\/.*$/gm, "");
}

const KNOWN_HEADER = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
const KNOWN_TRACE = "4bf92f3577b34da6a3ce929d0e0e4736";
const KNOWN_PARENT = "00f067aa0ba902b7";
// Fixed so every assertion below is an equality, not a shape check.
const FIXED_SPAN = "1111111111111111";

const BAD_HEADERS = {
  empty: "",
  "not a header": "garbage",
  "truncated at 54": `00-${KNOWN_TRACE}-${KNOWN_PARENT}`,
  "version 00 plus junk": `${KNOWN_HEADER}-extra`,
  "all-zero trace-id": `00-${"0".repeat(32)}-${KNOWN_PARENT}-01`,
  "all-zero parent-id": `00-${KNOWN_TRACE}-${"0".repeat(16)}-01`,
  "uppercase hex": `00-4BF92F3577B34DA6A3CE929D0E0E4736-${KNOWN_PARENT}-01`,
  "forbidden version ff": `ff-${KNOWN_TRACE}-${KNOWN_PARENT}-01`,
  "one-char version": `0-${KNOWN_TRACE}-${KNOWN_PARENT}-01`,
  "wrong delimiters": `00_${KNOWN_TRACE}_${KNOWN_PARENT}_01`,
  "non-hex flags": `00-${KNOWN_TRACE}-${KNOWN_PARENT}-0g`,
};

test("known traceparent is continued", () => {
  // The headline promise: a known traceparent comes out the other side with its
  // trace identity intact and a fresh span id (§3.4).
  const hop = serverHop({ traceparent: KNOWN_HEADER }, FIXED_SPAN);

  assert.equal(hop.traceId, KNOWN_TRACE);
  assert.ok(hop.continued, "a valid inbound traceparent must be continued, not restarted");
  assert.equal(hop.spanId, FIXED_SPAN);
  assert.notEqual(hop.spanId, KNOWN_PARENT, "span id must not be the inbound parent-id");
  assert.equal(hop.sampled, true, "sampled flag (§3.2.2.5.1) must survive the hop");

  const out = hop.outboundHeaders;
  const parsed = parseTraceparent(out.traceparent);
  assert.ok(parsed, `outbound traceparent ${out.traceparent} did not parse`);
  assert.equal(parsed.traceId, KNOWN_TRACE);
  assert.equal(parsed.parentId, FIXED_SPAN, "outbound parent-id is this hop's span id");
  assert.ok(parsed.sampled, "outbound trace-flags lost the sampled bit");
  assert.equal(parsed.version, 0, "we emit the version we implement");
});

test("unsampled flag is preserved", () => {
  // §3.2.2.5.1: sampled is a recommendation, not a rule.
  const hop = serverHop({ traceparent: `00-${KNOWN_TRACE}-${KNOWN_PARENT}-00` }, FIXED_SPAN);

  assert.equal(hop.sampled, false, "sampled flag must not be invented on an unsampled trace");
  assert.equal(hop.traceId, KNOWN_TRACE);
  assert.ok(hop.outboundHeaders.traceparent.endsWith("-00"));
});

test("second hop keeps the same trace-id", () => {
  // Three services, one trace: hop N+1 keeps the trace-id hop N produced.
  const first = serverHop({ traceparent: KNOWN_HEADER }, "2222222222222222");
  const second = serverHop(first.outboundHeaders, "3333333333333333");

  assert.equal(second.traceId, KNOWN_TRACE, "trace broken across hops");
  assert.ok(second.continued, "a traceparent this service just emitted must parse on the way back in");
});

test("malformed traceparent starts a new trace", () => {
  // Every one of these is garbage a proxy, a client library, or an attacker will
  // eventually send: start a new trace, silently, without throwing.
  for (const [name, value] of Object.entries(BAD_HEADERS)) {
    const hop = serverHop({ traceparent: value }, FIXED_SPAN);

    assert.equal(hop.continued, false, `${name}: ${value} was accepted as a valid traceparent`);
    assert.notEqual(hop.traceId, KNOWN_TRACE, `${name}: an invalid traceparent contributed its trace-id`);
    assert.equal(hop.traceId.length, 32);
    assert.notEqual(hop.traceId, "0".repeat(32), `${name}: trace-id must not be all zeroes (§3.2.2.3)`);
    assert.ok(parseTraceparent(hop.outboundHeaders.traceparent), `${name}: the restarted trace must be valid`);
  }
});

test("missing traceparent starts a new trace", () => {
  // §4.2
  const hop = serverHop({}, FIXED_SPAN);

  assert.equal(hop.continued, false);
  assert.equal(hop.traceId.length, 32);
  assert.notEqual(hop.traceId, "0".repeat(32));
  assert.equal(hop.sampled, false, "a trace this service started defaults to not-sampled (§3.2.2.5.1)");
});

test("tracestate is forwarded", () => {
  // §3.3: tracestate is opaque to us and MUST travel with the trace.
  const hop = serverHop({ traceparent: KNOWN_HEADER, tracestate: "congo=t61rcWkgMzE" }, FIXED_SPAN);
  assert.equal(hop.outboundHeaders.tracestate, "congo=t61rcWkgMzE");
});

test("tracestate is truncated at whole entries", () => {
  // §3.3.1.5: propagate at least 512 characters, truncating whole entries.
  const entries = Array.from({ length: 60 }, (_, i) => `v${String(i).padStart(2, "0")}=${"x".repeat(30)}`);
  const long = entries.join(",");

  const out = serverHop({ traceparent: KNOWN_HEADER, tracestate: long }, FIXED_SPAN).outboundHeaders.tracestate;

  assert.ok(out.length <= 512, `tracestate is ${out.length} characters; §3.3.1.5 caps at 512`);
  assert.notEqual(out, "", "truncating dropped the whole header");
  for (const entry of out.split(",")) {
    assert.ok(long.includes(entry), `entry ${entry} was truncated mid-entry, which §3.3.1.5 forbids`);
  }
  assert.ok(out.startsWith(entries[0]), "§3.3.1.5 drops entries from the end");
});

test("oversized tracestate entries are removed first", () => {
  // §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
  const out = serverHop(
    { traceparent: KNOWN_HEADER, tracestate: `huge=${"y".repeat(200)},small=1` },
    FIXED_SPAN,
  ).outboundHeaders.tracestate;

  assert.ok(!out.includes("huge="), "an entry over 128 characters is removed first");
  assert.equal(out, "small=1");
});

test("tracestate without a valid traceparent is discarded", () => {
  // §3.3 and §4.2: forwarding it would attach vendor state to an unrelated trace.
  for (const value of ["", "not-a-traceparent"]) {
    const hop = serverHop({ traceparent: value, tracestate: "congo=t61rcWkgMzE" }, FIXED_SPAN);
    assert.ok(
      !("tracestate" in hop.outboundHeaders),
      `tracestate must be discarded when traceparent is ${JSON.stringify(value)}`,
    );
  }
});

test("header names are case-insensitive and sent lowercase", () => {
  // §3.2.1: accept the header name in any case, send it lowercase.
  for (const name of ["traceparent", "TraceParent", "TRACEPARENT", "Traceparent"]) {
    const hop = serverHop({ [name]: KNOWN_HEADER }, FIXED_SPAN);
    assert.equal(hop.traceId, KNOWN_TRACE, `header ${name} was not recognised`);
  }

  const out = serverHop({ TraceParent: KNOWN_HEADER }, FIXED_SPAN).outboundHeaders;
  for (const name of Object.keys(out)) {
    assert.equal(name, name.toLowerCase(), `§3.2.1: send ${name} lowercase`);
  }
});

test("higher version is downgraded and unknown fields are not forwarded", () => {
  // §3.2.4: parse positionally, then re-emit at version 00 without the unknown
  // fields.
  const future = `cc-${KNOWN_TRACE}-${KNOWN_PARENT}-01-what-the-future-wants`;

  const parsed = parseTraceparent(future);
  assert.ok(parsed, "a well-formed higher version must be parsed per §3.2.4");
  assert.equal(parsed.version, 0xcc);
  assert.equal(parsed.traceId, KNOWN_TRACE);
  assert.equal(parsed.parentId, KNOWN_PARENT);

  const out = serverHop({ traceparent: future }, FIXED_SPAN).outboundHeaders.traceparent;
  assert.ok(out.startsWith("00-"), `outbound ${out} must be downgraded to version 00`);
  assert.ok(!out.includes("what-the-future-wants"), "§3.2.4: MUST NOT forward unknown fields");
});

test("trace-flags are a bit field", () => {
  // §3.2.2.5: mask on read, rebuild on write; §3.2.2.5.2: reserved bits zero.
  const hop = serverHop({ traceparent: `00-${KNOWN_TRACE}-${KNOWN_PARENT}-03` }, FIXED_SPAN);

  assert.equal(hop.sampled, true, "bit 0 set means sampled; reading flags as a number is the classic bug");
  assert.ok(
    hop.outboundHeaders.traceparent.endsWith("-01"),
    "reserved bits must be zeroed on the way out (§3.2.2.5.2)",
  );
});

// ---------------------------------------------------------------------------
// THE CARRIER DEFECT CLASS — four assertions, and they are here because a
// comment did not stop it happening.
//
// A WHATWG `Headers` stores its entries in an internal list and exposes them
// through `.get()`. It has no own enumerable properties. So EVERY carrier read
// written as plain property access — `carrier[key]`, `Object.entries(carrier)` —
// returns nothing for every key on a `Headers`, and the caller quietly starts a
// new trace while exporting spans that look completely healthy. Nothing throws,
// nothing logs, and `service.name` is still right.
//
// This is not hypothetical: it is a shape that shipped in the fleet's own
// node template. `@opentelemetry/api`'s DEFAULT text-map getter is
// `get(carrier, key) { return carrier[key] }`, so
// `propagation.extract(ctx, request.headers)` returned the context unchanged for
// every request in every service that took it. The assertion that caught it is
// the trace-id one below — an assertion that "a span was exported" is blind to
// it by construction, because the span is exported. It is exported WRONGLY.
// ---------------------------------------------------------------------------

test("inbound traceparent on a WHATWG Headers is CONTINUED, not restarted", () => {
  // The headline promise, through the carrier a real Hono/Bun request hands you:
  // `c.req.raw.headers` is a `Headers`, never a plain object. Before
  // `header()` learned to read one, this returned a NEW trace id and reported
  // `continued: false` while passing every other assertion in this file.
  const inbound = new Headers({ traceparent: KNOWN_HEADER, tracestate: "vendor=1" });
  const hop = serverHop(inbound, FIXED_SPAN);

  assert.equal(
    hop.traceId,
    KNOWN_TRACE,
    "a Headers carrier must yield the INBOUND trace id; a fresh one means the carrier was never read",
  );
  assert.ok(hop.continued, "a valid inbound traceparent on a Headers must be continued");
  assert.equal(hop.spanId, FIXED_SPAN);
  assert.equal(hop.sampled, true, "the sampled flag must survive the hop (§3.2.2.5.1)");
  assert.equal(hop.outboundHeaders.traceparent, `00-${KNOWN_TRACE}-${FIXED_SPAN}-01`);
});

test("a malformed traceparent on a Headers starts a NEW trace and never throws", () => {
  // §3.2.2.3 and §4.2, on the carrier that made the good case fail. A request
  // is not a 4xx because its trace header was garbage.
  for (const [name, value] of Object.entries(BAD_HEADERS)) {
    const hop = serverHop(new Headers({ traceparent: value }), FIXED_SPAN);
    assert.notEqual(hop.traceId, KNOWN_TRACE, `malformed "${name}" must not be adopted`);
    assert.equal(hop.continued, false, `malformed "${name}" must start a new trace`);
    assert.equal(hop.spanId, FIXED_SPAN, `malformed "${name}" must still get this hop's span id`);
  }
});

test("the OTel default getter's shape CANNOT read a Headers — which is the whole defect", () => {
  // Executed rather than described, because the reason this defect survived a
  // whole wave of emission work is that it is invisible to every other kind of
  // check. Both shapes below are run against the SAME real `Headers`; only the
  // read differs.
  //
  // `defaultTextMapGetter.get` from @opentelemetry/api, transcribed verbatim:
  //
  //     get(carrier, key) { return carrier[key] }
  //
  // and the explicit getter the snippet now passes, verbatim:
  //
  //     get(carrier, key) { return carrier.get(key) ?? undefined }
  //
  // If the SDK ever changes its default so that it DOES read a Headers, the first
  // assertion here goes red and this comment is what a reader has to revisit.
  const carrier = new Headers({ traceparent: KNOWN_HEADER });
  const defaultShape = (c, key) => c[key];
  const explicitShape = (c, key) => c.get(key) ?? undefined;

  assert.equal(
    defaultShape(carrier, "traceparent"),
    undefined,
    "plain property access on a Headers is always undefined — if this passes, the SDK changed",
  );
  assert.equal(
    explicitShape(carrier, "traceparent"),
    KNOWN_HEADER,
    "the explicit getter is the only shape that reads a Headers",
  );
  // And the consequence, stated as the assertion it is: the default shape reads
  // nothing, so an extract built on it leaves the context unchanged and every
  // request becomes its own root span.
  const continued = defaultShape(carrier, "traceparent") === KNOWN_HEADER;
  assert.equal(continued, false, "the default shape continues nothing; a fresh trace id is the symptom");
});

test("hono.ts.snippet passes the explicit getter, and never hands extract a raw Headers", () => {
  // The SOURCE of the defect is this template, so the template asserts its own
  // shape. Read with comments STRIPPED: a check that a comment can satisfy is
  // not a check, and this file explains the getter in eleven comment lines
  // naming `headersGetter` — which is exactly how a naive grep would pass on the
  // broken snippet that shipped.
  const source = readFileSync(new URL("./hono.ts.snippet", import.meta.url), "utf8");
  const code = stripComments(source);

  const extracts = [...code.matchAll(/propagation\.extract\(([^;]*?)\);/gs)];
  assert.ok(extracts.length > 0, "the snippet must call propagation.extract at all");
  for (const call of extracts) {
    assert.match(
      call[1],
      /headersGetter/,
      "every propagation.extract must pass the explicit Headers getter: the default getter " +
        "cannot read a WHATWG Headers and inbound propagation fails silently",
    );
  }

  assert.match(
    code,
    /const\s+headersGetter[^=]*=\s*\{[^}]*get\s*\(/s,
    "the snippet must DEFINE a TextMapGetter that calls carrier.get()",
  );

  // The counterpart that was always right, asserted so nobody "fixes" it into
  // the broken form: inject's carrier is a real object literal with `set`.
  assert.match(
    code,
    /propagation\.inject\([^;]*\{[^}]*set\s*\([^)]*\)[^}]*\}/s,
    "propagation.inject must receive a setter that writes into the Headers it will fetch with",
  );
});

// ---------------------------------------------------------------------------
// The SDK 2.x API removals. THIS IS THE DEFECT CLASS, not one file's four calls.
//
// Why the list is a TABLE and not four assertions inline: a check that names four
// calls is a check that goes stale the moment the SDK removes a fifth, and it
// goes stale SILENTLY, because nothing in the tree notices that a row is missing.
// Adding a row here is the whole cost of covering a new removal.
//
// Every row was read out of the PUBLISHED packages on 2026-10-06, not from
// memory and not from the 1.x docs:
//
//   @opentelemetry/sdk-trace-base@2.11.0
//     BasicTracerProvider-shim.d.ts: `class BasicTracerProvider extends
//       TracerProvider`, declaring `constructor(config?: TracerConfig)` and
//       nothing else.
//     sdk-trace@2.11.0 TracerProvider.d.ts: `getTracer`, `forceFlush`,
//       `shutdown`. No `addSpanProcessor`, no `register`.
//     BatchSpanProcessor-shim.js: `constructor(exporter, config)` whose body is
//       `super({ exporter, ...config })`.
//
//   @opentelemetry/sdk-logs@0.222.0
//     LoggerProvider.d.ts: `getLogger`, `forceFlush`, `shutdown`. No
//       `addLogRecordProcessor`.
//     types.d.ts: `LoggerProviderOptions.processors?: LogRecordProcessor[]`.
//
//   @opentelemetry/sdk-trace-node@2.11.0
//     NodeTracerProvider.d.ts: `class NodeTracerProvider extends
//       BasicTracerProvider`, redeclaring `register`. So `register()` is NOT
//       removed from the ecosystem — it moved to a subclass, which is why the
//       assertion below is about the RECEIVER rather than the string.
//
// WHAT THIS CANNOT DO, stated here rather than left for a reader to assume: it
// checks the snippet's SOURCE SHAPE. kit vendors no OTel tree and installs
// nothing, so it cannot compile the snippet against the pinned versions or run
// it. That is a deliberate limit, not an oversight — pins.md's own argument is
// that a gate which reaches npm goes red when npm is down. What a source-shape
// check does buy is the property these four defects share: every one of them is
// a SPELLING, and a spelling cannot come back by accident.
// ---------------------------------------------------------------------------

/** [what is forbidden, why, what replaces it] — asserted against stripped source. */
const SDK_2_REMOVED_CALLS = [
  [
    /\.addSpanProcessor\s*\(/,
    "provider.addSpanProcessor()",
    "SDK 2.x removed it; processors go in the constructor as spanProcessors: [...]",
  ],
  [
    /\.addLogRecordProcessor\s*\(/,
    "loggerProvider.addLogRecordProcessor()",
    "SDK 2.x removed it; processors go in the constructor as processors: [...]",
  ],
  [
    /\bnew\s+BatchSpanProcessor\s*\(\s*\{/,
    "new BatchSpanProcessor({ exporter })",
    "the constructor is (exporter, config) — an options object becomes a _exporter " +
      "that is an OBJECT, and the processor fails on its first export instead of at boot",
  ],
];

test("hono.ts.snippet calls NO API that pins.md's versions removed", () => {
  const code = stripComments(
    readFileSync(new URL("./hono.ts.snippet", import.meta.url), "utf8"),
  );

  for (const [pattern, spelling, why] of SDK_2_REMOVED_CALLS) {
    assert.doesNotMatch(
      code,
      pattern,
      `${spelling} does not exist on the versions pins.md pins. ${why}`,
    );
  }
});

test("hono.ts.snippet installs the THREE globals explicitly, and a context manager", () => {
  const code = stripComments(
    readFileSync(new URL("./hono.ts.snippet", import.meta.url), "utf8"),
  );

  // `register()` is asserted on its RECEIVER, and the receiver is DERIVED from
  // the source rather than hardcoded: the snippet's provider variable is
  // whatever `new BasicTracerProvider(` is assigned to. `register()` is not
  // removed from the ecosystem — it moved to `NodeTracerProvider` — so a check
  // for the bare string `register(` would be wrong in both directions: blind to
  // the actual defect here, and red on a correct snippet that legitimately uses
  // the node provider.
  //
  // The other half of the same claim, and the one that makes the receiver
  // derivation worth anything: if the snippet builds a `BasicTracerProvider` at
  // all, that variable must never be the one `register()` is called on.
  const basicVars = [
    ...code.matchAll(/=\s*new\s+BasicTracerProvider\s*\(/g),
  ].map((m) => m[0]);
  assert.ok(
    basicVars.length > 0,
    "the snippet must construct a BasicTracerProvider — with no provider there is " +
      "nothing to gate this against, and a snippet that quietly stopped building " +
      "one would satisfy every other assertion in this file",
  );

  // The provider variable name, read out of `provider = new BasicTracerProvider(`
  // so the name is never written twice: renaming the variable cannot silently
  // move the check off it, which a hardcoded name would allow.
  const providerVars = [
    ...code.matchAll(/(\w+)\s*=\s*new\s+BasicTracerProvider\s*\(/g),
  ].map((m) => m[1]);
  for (const name of providerVars) {
    assert.doesNotMatch(
      code,
      new RegExp(`\\b${name}\\s*\\.\\s*register\\s*\\(`),
      `${name} is a BasicTracerProvider and SDK 2.x removed register() from the base ` +
        "provider — it is on NodeTracerProvider only. It is also what used to install " +
        "the CONTEXT MANAGER, so this one call was doing two load-bearing jobs and " +
        "removing it without the explicit setGlobalContextManager is a silent total " +
        "failure of context.with()",
    );
  }

  // The globals themselves, one assertion each, because each of them has a
  // distinct failure: no provider means no spans at all, no propagator means a
  // service that depends on a default it never wrote down, and no context
  // manager means `context.with()` is a no-op that still runs its callback.
  assert.match(
    code,
    /trace\.setGlobalTracerProvider\s*\(/,
    "the tracer provider must be set as a global — 1.x did this inside register()",
  );
  assert.match(
    code,
    /propagation\.setGlobalPropagator\s*\(\s*new\s+W3CTraceContextPropagator/,
    "the W3C propagator must be NAMED and installed, not left to the SDK default",
  );
  assert.match(
    code,
    /context\.setGlobalContextManager\s*\(\s*new\s+AsyncLocalStorageContextManager\s*\(\s*\)\s*\.enable\s*\(\s*\)/,
    "a context manager must be installed EXPLICITLY, and ENABLED: without one " +
      "context.active() is ROOT_CONTEXT for the life of the process, so every " +
      "context.with() in the request path runs its callback, every span is " +
      "exported with the right service.name, and no span has a parent",
  );
  // The half that is easy to drop: `.enable()` returns the manager. Passing the
  // un-enabled instance installs a manager whose `with` never establishes a
  // store, which is the same silent no-op one call deeper.
  assert.doesNotMatch(
    code,
    /setGlobalContextManager\s*\(\s*new\s+AsyncLocalStorageContextManager\s*\(\s*\)\s*\)/,
    "the UN-ENABLED context manager must never be installed — .enable() returns " +
      "the manager and its return value is what has to be passed",
  );

  // The import, because the assertion above is satisfiable by a comment… except
  // that comments are stripped. It is still worth having: the two assertions
  // could both be satisfied by an identifier nothing imports.
  assert.match(
    code,
    /import\s*\{[^}]*AsyncLocalStorageContextManager[^}]*\}\s*from\s*"@opentelemetry\/context-async-hooks"/,
    "AsyncLocalStorageContextManager must be imported from @opentelemetry/context-async-hooks",
  );
});

test("the SDK 2.x removals above are REAL removals, not a list of phantoms", () => {
  // THE CONTROL, and it is the half that makes the list above a check rather
  // than a wall of text. A list of forbidden spellings that nothing ever
  // matched would pass on any snippet at all, forever — the defect this
  // repository has already been bitten by, where a check reads green without
  // ever having read the thing it names. So each regex is run against a
  // transcription of the 1.x call and MUST match.
  //
  // Every pattern in SDK_2_REMOVED_CALLS is checked here to MATCH, so the
  // table cannot gain a regex that can never fire. If a regex is ever written
  // wrong, this goes red and the table goes red with it — which is the correct
  // direction: a typo in the forbidden list is a hole in the fence, and it is
  // worth finding.
  const PLANTED = [
    "provider.addSpanProcessor(new BatchSpanProcessor(e));",
    "loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(e));",
    "new BatchSpanProcessor({ exporter: new OTLPTraceExporter() });",
  ];
  assert.equal(
    PLANTED.length,
    SDK_2_REMOVED_CALLS.length,
    "every planted 1.x spelling must have a row in SDK_2_REMOVED_CALLS; a " +
      "removal with no row is a removal that can come back",
  );
  for (const line of PLANTED) {
    assert.ok(
      SDK_2_REMOVED_CALLS.some(([pattern]) => pattern.test(line)),
      `the planted 1.x call ${line} matched no row — SDK_2_REMOVED_CALLS has a ` +
        "pattern that cannot fire, so that row is decoration rather than a check",
    );
  }
});

test("new identifiers are random and never all zero", () => {
  // §8: 16 and 8 random bytes, never all zeroes, never repeated.
  const seen = new Set();
  for (let i = 0; i < 256; i += 1) {
    const traceId = newTraceId();
    assert.equal(traceId.length, 32);
    assert.notEqual(traceId, "0".repeat(32));
    assert.ok(!seen.has(traceId), `newTraceId repeated ${traceId} within 256 draws (§8.2)`);
    seen.add(traceId);

    assert.equal(newSpanId().length, 16);
  }
});
