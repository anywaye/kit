
import { randomBytes } from "node:crypto";

const SAMPLED = 0x01;

const MIN_HEADER_LEN = 55;

const TRACESTATE_LIMIT = 512;

const TRACESTATE_ENTRY_LIMIT = 128;

const ZERO_TRACE_ID = "0".repeat(32);
const ZERO_SPAN_ID = "0".repeat(16);

const LOWER_HEX = /^[0-9a-f]+$/;



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

  if (value.length < MIN_HEADER_LEN) return null;

  if (value[2] !== "-" || !LOWER_HEX.test(value.slice(0, 2))) return null;

  const version = Number.parseInt(value.slice(0, 2), 16);
  if (version === 0xff) return null;

  const traceId = value.slice(3, 35);
  const parentId = value.slice(36, 52);
  const flagsField = value.slice(53, 55);

  if (value[35] !== "-" || value[52] !== "-") return null;
  if (!LOWER_HEX.test(traceId) || !LOWER_HEX.test(parentId) || !LOWER_HEX.test(flagsField)) return null;

  if (version === 0) {
    if (value.length !== MIN_HEADER_LEN) return null;
  } else if (value.length > MIN_HEADER_LEN) {
    if (value[MIN_HEADER_LEN] !== "-") return null;
  }

  if (traceId === ZERO_TRACE_ID || parentId === ZERO_SPAN_ID) return null;

  const parsed = {
    version,
    traceId,
    parentId,
    flags: Number.parseInt(flagsField, 16),
    extra: value.slice(MIN_HEADER_LEN + 1),
  };

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
        { traceId: newTraceId(), spanId, flags: 0, tracestate: "", continued: false }
      : {
          traceId: parsed.traceId,
          spanId,
          flags: parsed.flags & SAMPLED,
          tracestate: forwardTracestate(header(headers, "tracestate")) ?? "",
          continued: true,
        },
  );
}

function makeHop(hop) {
  Object.defineProperties(hop, {
    sampled: { get: () => isSampled(hop), enumerable: true },
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
    if (entry === "") continue;
    if (entry.length > TRACESTATE_ENTRY_LIMIT) continue;
    entries.push(entry);
  }

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
    traceparent: formatTraceparent(hop.traceId, hop.spanId, hop.flags),
  };
  if (hop.tracestate) out.tracestate = hop.tracestate;
  return out;
}
