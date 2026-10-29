
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { newSpanId, newTraceId, parseTraceparent, serverHop } from "./traceparent.mjs";

function stripComments(source) {
}

const KNOWN_HEADER = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
const KNOWN_TRACE = "4bf92f3577b34da6a3ce929d0e0e4736";
const KNOWN_PARENT = "00f067aa0ba902b7";
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
  const hop = serverHop({ traceparent: `00-${KNOWN_TRACE}-${KNOWN_PARENT}-00` }, FIXED_SPAN);

  assert.equal(hop.sampled, false, "sampled flag must not be invented on an unsampled trace");
  assert.equal(hop.traceId, KNOWN_TRACE);
  assert.ok(hop.outboundHeaders.traceparent.endsWith("-00"));
});

test("second hop keeps the same trace-id", () => {
  const first = serverHop({ traceparent: KNOWN_HEADER }, "2222222222222222");
  const second = serverHop(first.outboundHeaders, "3333333333333333");

  assert.equal(second.traceId, KNOWN_TRACE, "trace broken across hops");
  assert.ok(second.continued, "a traceparent this service just emitted must parse on the way back in");
});

test("malformed traceparent starts a new trace", () => {
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
  const hop = serverHop({}, FIXED_SPAN);

  assert.equal(hop.continued, false);
  assert.equal(hop.traceId.length, 32);
  assert.notEqual(hop.traceId, "0".repeat(32));
  assert.equal(hop.sampled, false, "a trace this service started defaults to not-sampled (§3.2.2.5.1)");
});

test("tracestate is forwarded", () => {
  const hop = serverHop({ traceparent: KNOWN_HEADER, tracestate: "congo=t61rcWkgMzE" }, FIXED_SPAN);
  assert.equal(hop.outboundHeaders.tracestate, "congo=t61rcWkgMzE");
});

test("tracestate is truncated at whole entries", () => {
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
  const out = serverHop(
    { traceparent: KNOWN_HEADER, tracestate: `huge=${"y".repeat(200)},small=1` },
    FIXED_SPAN,
  ).outboundHeaders.tracestate;

  assert.ok(!out.includes("huge="), "an entry over 128 characters is removed first");
  assert.equal(out, "small=1");
});

test("tracestate without a valid traceparent is discarded", () => {
  for (const value of ["", "not-a-traceparent"]) {
    const hop = serverHop({ traceparent: value, tracestate: "congo=t61rcWkgMzE" }, FIXED_SPAN);
    assert.ok(
      !("tracestate" in hop.outboundHeaders),
      `tracestate must be discarded when traceparent is ${JSON.stringify(value)}`,
    );
  }
});

test("header names are case-insensitive and sent lowercase", () => {
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
  const hop = serverHop({ traceparent: `00-${KNOWN_TRACE}-${KNOWN_PARENT}-03` }, FIXED_SPAN);

  assert.equal(hop.sampled, true, "bit 0 set means sampled; reading flags as a number is the classic bug");
  assert.ok(
    hop.outboundHeaders.traceparent.endsWith("-01"),
    "reserved bits must be zeroed on the way out (§3.2.2.5.2)",
  );
});


test("inbound traceparent on a WHATWG Headers is CONTINUED, not restarted", () => {
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
  for (const [name, value] of Object.entries(BAD_HEADERS)) {
    const hop = serverHop(new Headers({ traceparent: value }), FIXED_SPAN);
    assert.notEqual(hop.traceId, KNOWN_TRACE, `malformed "${name}" must not be adopted`);
    assert.equal(hop.continued, false, `malformed "${name}" must start a new trace`);
    assert.equal(hop.spanId, FIXED_SPAN, `malformed "${name}" must still get this hop's span id`);
  }
});

test("the OTel default getter's shape CANNOT read a Headers — which is the whole defect", () => {
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
  const continued = defaultShape(carrier, "traceparent") === KNOWN_HEADER;
  assert.equal(continued, false, "the default shape continues nothing; a fresh trace id is the symptom");
});

test("hono.ts.snippet passes the explicit getter, and never hands extract a raw Headers", () => {
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

  assert.match(
    code,
    /propagation\.inject\([^;]*\{[^}]*set\s*\([^)]*\)[^}]*\}/s,
    "propagation.inject must receive a setter that writes into the Headers it will fetch with",
  );
});


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

  const basicVars = [
    ...code.matchAll(/=\s*new\s+BasicTracerProvider\s*\(/g),
  ].map((m) => m[0]);
  assert.ok(
    basicVars.length > 0,
    "the snippet must construct a BasicTracerProvider — with no provider there is " +
      "nothing to gate this against, and a snippet that quietly stopped building " +
      "one would satisfy every other assertion in this file",
  );

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
  assert.doesNotMatch(
    code,
    /setGlobalContextManager\s*\(\s*new\s+AsyncLocalStorageContextManager\s*\(\s*\)\s*\)/,
    "the UN-ENABLED context manager must never be installed — .enable() returns " +
      "the manager and its return value is what has to be passed",
  );

  assert.match(
    code,
    /import\s*\{[^}]*AsyncLocalStorageContextManager[^}]*\}\s*from\s*"@opentelemetry\/context-async-hooks"/,
    "AsyncLocalStorageContextManager must be imported from @opentelemetry/context-async-hooks",
  );
});

test("the SDK 2.x removals above are REAL removals, not a list of phantoms", () => {
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
