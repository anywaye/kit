// kit template — W3C Trace Context propagation for a Hono/TypeScript service.
//
// Copy traceparent.mjs and traceparent.test.mjs into your service. For inbound
// requests, hono.ts.snippet wires this into middleware; keep the test suite
// either way.
//
// The upstream OTel SDK does this for you — see hono.ts.snippet for the
// versioned wiring. Use this file when you need the header handling on its own:
// a queue consumer, a webhook signer, or a test that asserts propagation without
// standing up an SDK.
//
// REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
// https://www.w3.org/TR/trace-context/
//
// IMPLEMENTED SECTIONS (every one is asserted in traceparent.test.mjs)
//   §3.2.1     header name: accept any case, send lowercase
//   §3.2.2.1   version is 2 hex chars; ff is forbidden
//   §3.2.2.2   version-format for version 00
//   §3.2.2.3   invalid trace-id -> ignore the traceparent (all zeroes forbidden)
//   §3.2.2.4   invalid parent-id -> ignore the traceparent (all zeroes forbidden)
//   §3.2.2.5   trace-flags is a bit field; mask on read
//   §3.2.2.5.1 the sampled flag is the only flag in version 00
//   §3.2.2.5.2 reserved flags MUST be set to zero on the wire
//   §3.2.4     higher version: parse positionally, re-emit at 00, drop unknowns
//   §3.3       a failed traceparent MUST NOT be rescued by a tracestate
//   §3.3.1.5   tracestate: propagate >=512 chars, truncate whole entries only
//   §4.2/§4.3  no traceparent -> new trace; invalid -> restart, never an error
//
// NO DEPENDENCIES. node:crypto, full stop — so this drops into any Hono service
// and the suite runs without `npm install`. Import it from TypeScript directly;
// there is nothing here that needs a build step.

import { randomBytes } from "node:crypto";

// Bit 0 of trace-flags (§3.2.2.5.1). It is a bit in a field, not the field's
// value: reading `flags === 1` instead of `(flags & 1) === 1` is the single
// most common trace-context bug, and it is why this is a named constant.
const SAMPLED = 0x01;

// A traceparent is exactly 55 characters: 2 version, 32 trace-id, 16 parent-id,
// 2 trace-flags, and 3 dashes (§3.2.2.2).
const MIN_HEADER_LEN = 55;

// §3.3.1.5: "Vendors SHOULD propagate at least 512 characters of a combined
// header." Bigger than this and we truncate whole entries.
const TRACESTATE_LIMIT = 512;

// §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
const TRACESTATE_ENTRY_LIMIT = 128;

const ZERO_TRACE_ID = "0".repeat(32);
const ZERO_SPAN_ID = "0".repeat(16);

const LOWER_HEX = /^[0-9a-f]+$/;

/**
 * A parsed `traceparent` header.
 *
 * @typedef {object} TraceParent
 * @property {number} version Raw version byte: zero for `00`, the only version we
 *   emit; a higher version is parsed (§3.2.4) and then downgraded.
 * @property {string} traceId 32 lowercase hex characters: the whole trace.
 * @property {string} parentId 16 lowercase hex characters: the caller's span.
 * @property {number} flags The full 8-bit field, as parsed.
 * @property {string} extra Everything after the flags field on a higher-version
 *   header, for logging only: §3.2.4 says vendors MUST NOT forward unknown
 *   fields, and `outboundHeaders` does not.
 */

/**
 * One service's continuation of a trace.
 *
 * `continued` is not a debug field: a span exporter needs to know whether this is
 * a root span in order to label it correctly.
 *
 * @typedef {object} ServerHop
 * @property {string} traceId
 * @property {string} spanId This hop's span; becomes the next hop's parent-id.
 * @property {number} flags The sampled bit, and nothing else.
 * @property {string} tracestate
 * @property {boolean} continued
 */

/**
 * Parse a `traceparent` header value.
 *
 * Returns null for anything invalid, and that is the whole contract: §3.2.2.3
 * and §3.2.2.4 say a vendor MUST ignore the header when trace-id or parent-id is
 * invalid, and §3.2.4 says to restart the trace when the version cannot be
 * parsed. There is no error to handle and no value to partially trust.
 *
 * @param {string | null | undefined} value
 * @returns {TraceParent | null}
 */
export function parseTraceparent(value) {
  if (typeof value !== "string" || value === "") return null;

  // A short header cannot hold the four fields, whatever the version (§3.2.4).
  if (value.length < MIN_HEADER_LEN) return null;

  // §3.2.4: "When the version prefix cannot be parsed (it's not 2 hex characters
  // followed by a dash), the implementation should restart the trace." Checked
  // before anything else, so a malformed version is never mistaken for a valid
  // one.
  if (value[2] !== "-" || !LOWER_HEX.test(value.slice(0, 2))) return null;

  const version = Number.parseInt(value.slice(0, 2), 16);
  // §3.2.2.1: "Version ff is invalid."
  if (version === 0xff) return null;

  const traceId = value.slice(3, 35);
  const parentId = value.slice(36, 52);
  const flagsField = value.slice(53, 55);

  // The three fixed positions, all three mandatory (§3.2.4).
  if (value[35] !== "-" || value[52] !== "-") return null;
  if (!LOWER_HEX.test(traceId) || !LOWER_HEX.test(parentId) || !LOWER_HEX.test(flagsField)) return null;

  if (version === 0) {
    // §3.2.2.2 defines version 00 as exactly these four fields. Trailing data
    // means the sender is not speaking version 00, and accepting it would be
    // inventing a format the spec does not define.
    if (value.length !== MIN_HEADER_LEN) return null;
  } else if (value.length > MIN_HEADER_LEN) {
    // §3.2.4: on a higher version the two flag characters are followed by either
    // the end of the header or a dash introducing an unknown field.
    if (value[MIN_HEADER_LEN] !== "-") return null;
  }

  // §3.2.2.3 and §3.2.2.4: all zeroes is an invalid value for both, and the
  // required response is to ignore the header.
  if (traceId === ZERO_TRACE_ID || parentId === ZERO_SPAN_ID) return null;

  const parsed = {
    version,
    traceId,
    parentId,
    flags: Number.parseInt(flagsField, 16),
    extra: value.slice(MIN_HEADER_LEN + 1),
  };

  // The caller's recording decision (§3.2.2.5.1). We carry this rather than
  // making our own: a service that re-decides sampling per hop produces traces
  // with holes in them, which are worse than no traces.
  Object.defineProperty(parsed, "sampled", {
    get: () => (parsed.flags & SAMPLED) === SAMPLED,
    enumerable: true,
  });

  return parsed;
}

/**
 * Continue the trace described by the inbound headers.
 *
 * This is the one function a service's middleware calls. It cannot fail: a
 * malformed or absent traceparent yields a new trace, because a request is not
 * an error because its trace header was garbage (§4.2, §3.2.2.3).
 *
 * `spanId` is a parameter rather than generated here so the caller owns the span
 * lifecycle — in a service it comes from the tracer, in a test it is a constant,
 * which is why the suite can assert equality instead of a shape.
 *
 * @param {Record<string, string>} headers
 * @param {string} spanId
 * @returns {ServerHop}
 */
export function serverHop(headers, spanId) {
  const parsed = parseTraceparent(header(headers, "traceparent"));

  return makeHop(
    parsed === null
      ? // §3.3: "If the vendor failed to parse traceparent, it MUST NOT attempt
        // to parse tracestate." §4.2 makes it explicit for the no-traceparent
        // case: a tracestate alone "is invalid and MUST be discarded".
        // Forwarding it would attach a vendor's state to an unrelated trace.
        { traceId: newTraceId(), spanId, flags: 0, tracestate: "", continued: false }
      : {
          traceId: parsed.traceId,
          spanId,
          // §3.2.2.5: a bit field, so mask on read rather than carry the bytes
          // through. §3.2.2.5.2 requires the reserved bits to be zero outbound.
          flags: parsed.flags & SAMPLED,
          tracestate: forwardTracestate(header(headers, "tracestate")) ?? "",
          continued: true,
        },
  );
}

/**
 * Build the hop object.
 *
 * A factory rather than a bare literal because `sampled` and `outboundHeaders`
 * are derived, and deriving them in one place is the point: a hand-written
 * `flags: 1` somewhere in a caller is how the sampled bit gets lost.
 *
 * @param {ServerHop} hop
 * @returns {ServerHop}
 */
function makeHop(hop) {
  Object.defineProperties(hop, {
    /** Whether the outbound trace-flags carry the sampled bit (§3.2.2.5.1). */
    sampled: { get: () => isSampled(hop), enumerable: true },
    /**
     * This hop as headers for the next service.
     *
     * A getter rather than a method so it reads the same as the other five
     * templates (`hop.outboundHeaders`), which is what keeps a cross-language
     * suite maintainable: one shape, six languages.
     *
     * The shape is fixed by §3.4: parent-id becomes this hop's span id, and the
     * version is downgraded to the one we implement. Those two mutations plus the
     * sampled flag are the entire allowed set.
     */
    outboundHeaders: { get: () => outboundHeaders(hop), enumerable: true },
  });
  return hop;
}

/**
 * Build a `traceparent` at version 00.
 *
 * Always version 00, always lowercase hex, always exactly 55 characters
 * (§3.2.2.2). It takes no version parameter on purpose: a service speaks one
 * version, and a caller that could pass any version would eventually pass a
 * wrong one.
 */
export function formatTraceparent(traceId, parentId, flags) {
  return `00-${traceId}-${parentId}-${(flags & 0xff).toString(16).padStart(2, "0")}`;
}

/**
 * Apply the §3.3.1.5 limits to an inbound `tracestate`.
 *
 * The order matters and is the order the spec states: oversized entries go first
 * (they are the expensive ones and the least likely to be a well-known vendor
 * key), then entries are dropped from the end. Dropping from the front would
 * discard the most recent vendor's entry, which is the one that just wrote it and
 * the one that knows where the trace currently is.
 *
 * @param {string | null | undefined} value
 * @returns {string | null}
 */
export function forwardTracestate(value) {
  if (typeof value !== "string" || value === "") return null;

  const entries = [];
  for (const raw of value.split(",")) {
    const entry = raw.trim();
    // §3.3.1.1: "Empty and whitespace-only list members are allowed."
    if (entry === "") continue;
    if (entry.length > TRACESTATE_ENTRY_LIMIT) continue;
    entries.push(entry);
  }

  // Pop from the end until the combined value fits (§3.3.1.5).
  while (entries.length > 0 && entries.join(",").length > TRACESTATE_LIMIT) {
    entries.pop();
  }

  return entries.length > 0 ? entries.join(",") : null;
}

/**
 * Look a header up case-insensitively.
 *
 * §3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
 * mixed)". Hono lowercases, but a test, a proxy, or a middleware that copies
 * raw keys will not, and being strict here breaks traces in production for no
 * reason.
 *
 * A WHATWG `Headers` IS ALSO ACCEPTED, and the reason is measured rather than
 * defensive. `Headers` keeps its entries in an internal list and exposes them
 * through `.get()`; `Object.entries(new Headers())` is `[]` and
 * `headers["traceparent"]` is `undefined`. So the property walk below returns
 * `null` for EVERY key on a `Headers`, and the caller starts a brand new trace
 * while every span it exports looks perfectly healthy. The same shape of bug is
 * in `@opentelemetry/api`'s default text-map getter, which is
 * `get(carrier, key) { return carrier[key] }` — see the `headersGetter` beside
 * this file in `hono.ts.snippet`, and the assertion in `traceparent.test.mjs`
 * that runs both shapes against a real `Headers`.
 *
 * The `.get` branch is therefore FIRST: an object carrying a callable `get` is
 * read through it, and only a carrier without one falls to the property walk.
 *
 * @param {Record<string, string> | { get(name: string): string | null }} headers
 * @param {string} name
 * @returns {string | null}
 */
export function header(headers, name) {
  if (typeof headers?.get === "function") return headers.get(name) ?? null;
  const direct = headers[name];
  if (direct !== undefined) return direct;
  const lowered = name.toLowerCase();
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === lowered) return value;
  }
  return null;
}

/**
 * A fresh 16-byte trace identifier as 32 hex characters.
 *
 * §8: 16 bytes from a cryptographically secure source, never all zeroes.
 */
export function newTraceId() {
  return randomBytes(16).toString("hex");
}

/**
 * A fresh 8-byte span identifier as 16 hex characters.
 *
 * §8. On all-zero failure it returns a fixed non-zero constant rather than
 * throwing: an exhausted entropy source is not a reason to take the service
 * down, and §3.2.2.4 only requires that the value is not all zeroes. The
 * collision risk is theoretical; the availability risk is not.
 */
export function newSpanId() {
  const spanId = randomBytes(8).toString("hex");
  return spanId === ZERO_SPAN_ID ? "0000000000000001" : spanId;
}

/** Whether the hop's outbound trace-flags carry the sampled bit (§3.2.2.5.1). */
export function isSampled(hop) {
  return (hop.flags & SAMPLED) === SAMPLED;
}

/**
 * This hop as headers for the next service.
 *
 * Reached as `hop.outboundHeaders` in normal use; exported as a standalone for
 * callers holding a plain hop object (a deserialized one, say).
 *
 * @param {ServerHop} hop
 * @returns {Record<string, string>}
 */
export function outboundHeaders(hop) {
  const out = {
    // §3.2.1: send lowercase. The name is part of the contract even though the
    // receiving side is required to be case-insensitive.
    traceparent: formatTraceparent(hop.traceId, hop.spanId, hop.flags),
  };
  if (hop.tracestate) out.tracestate = hop.tracestate;
  return out;
}
