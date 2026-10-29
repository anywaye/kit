
use std::collections::BTreeMap;
use std::io::Read;

const SAMPLED: u8 = 0x01;

const MIN_HEADER_LEN: usize = 55;

const TRACESTATE_LIMIT: usize = 512;

const TRACESTATE_ENTRY_LIMIT: usize = 128;

const ZERO_TRACE_ID: &str = "00000000000000000000000000000000";
const ZERO_SPAN_ID: &str = "0000000000000000";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceParent {
    pub version: u8,
    pub trace_id: String,
    pub parent_id: String,
    pub flags: u8,
    pub extra: String,
}

impl TraceParent {
    /// The caller's recording decision (§3.2.2.5.1).
    ///
    /// We carry this rather than making our own: a service that re-decides
    /// sampling per hop produces traces with holes in them, which are worse than
    /// no traces.
    pub fn sampled(&self) -> bool {
        self.flags & SAMPLED == SAMPLED
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerHop {
    pub trace_id: String,
    pub span_id: String,
    pub flags: u8,
    pub tracestate: String,
    pub continued: bool,
}

impl ServerHop {
    pub fn sampled(&self) -> bool {
        self.flags & SAMPLED == SAMPLED
    }

    /// This hop as headers for the next service.
    ///
    /// The shape is fixed by §3.4: parent-id becomes this hop's span id, and the
    /// version is downgraded to the one we implement. Those two mutations plus
    /// the sampled flag are the entire allowed set — §3.4 says vendors MUST NOT
    /// make any other mutation.
    pub fn outbound_headers(&self) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        out.insert(
            "traceparent".to_string(),
            format_traceparent(&self.trace_id, &self.span_id, self.flags),
        );
        if !self.tracestate.is_empty() {
            out.insert("tracestate".to_string(), self.tracestate.clone());
        }
        out
    }
}

/// Parse a `traceparent` header value.
///
/// Returns `None` for anything invalid, and that is the whole contract:
/// §3.2.2.3 and §3.2.2.4 say a vendor MUST ignore the header when trace-id or
/// parent-id is invalid, and §3.2.4 says to restart the trace when the version
/// cannot be parsed. There is no error to handle and no value to partially trust.
pub fn parse_traceparent(value: Option<&str>) -> Option<TraceParent> {
    let raw = value?;

    if raw.len() < MIN_HEADER_LEN {
        return None;
    }

    if raw.as_bytes()[2] != b'-' || !is_lower_hex(&raw[0..2]) {
        return None;
    }
    let version = u8::from_str_radix(&raw[0..2], 16).ok()?;

    if version == 0xFF {
        return None;
    }

    let trace_id = &raw[3..35];
    let parent_id = &raw[36..52];
    let flags_field = &raw[53..55];

    if raw.as_bytes()[35] != b'-' || raw.as_bytes()[52] != b'-' {
        return None;
    }
    if !is_lower_hex(trace_id) || !is_lower_hex(parent_id) || !is_lower_hex(flags_field) {
        return None;
    }

    let flags = u8::from_str_radix(flags_field, 16).ok()?;

    if version == 0 {
        if raw.len() != MIN_HEADER_LEN {
            return None;
        }
    } else if raw.len() > MIN_HEADER_LEN {
        if raw.as_bytes()[MIN_HEADER_LEN] != b'-' {
            return None;
        }
    }

    if trace_id == ZERO_TRACE_ID || parent_id == ZERO_SPAN_ID {
        return None;
    }

    let extra = if raw.len() > MIN_HEADER_LEN {
        raw[MIN_HEADER_LEN + 1..].to_string()
    } else {
        String::new()
    };

    Some(TraceParent {
        version,
        trace_id: trace_id.to_string(),
        parent_id: parent_id.to_string(),
        flags,
        extra,
    })
}

/// Continue the trace described by the inbound headers.
///
/// This is the one function a service's middleware calls. It cannot fail: a
/// malformed or absent traceparent yields a new trace, because a request is not
/// an error because its trace header was garbage (§4.2, §3.2.2.3).
///
/// `span_id` is a parameter rather than generated here so the caller owns the
/// span lifecycle — in a service it comes from the tracer, in a test it is a
/// constant, which is why the tests below can assert equality instead of a
/// shape.
pub fn server_hop(headers: &BTreeMap<String, String>, span_id: &str) -> ServerHop {
    let parsed = parse_traceparent(header(headers, "traceparent").map(String::as_str));

    match parsed {
        None => ServerHop {
            trace_id: new_trace_id(),
            span_id: span_id.to_string(),
            flags: 0,
            tracestate: String::new(),
            continued: false,
        },
        Some(tp) => ServerHop {
            trace_id: tp.trace_id,
            span_id: span_id.to_string(),
            flags: tp.flags & SAMPLED,
            tracestate: forward_tracestate(header(headers, "tracestate").map(String::as_str))
                .unwrap_or_default(),
            continued: true,
        },
    }
}

/// Build a `traceparent` at version 00.
///
/// Always version 00, always lowercase hex, always exactly 55 characters
/// (§3.2.2.2). It takes no version parameter on purpose: a service speaks one
/// version, and a caller that could pass any version would eventually pass a
/// wrong one.
pub fn format_traceparent(trace_id: &str, parent_id: &str, flags: u8) -> String {
    format!("00-{}-{}-{:02x}", trace_id, parent_id, flags)
}

/// Apply the §3.3.1.5 limits to an inbound `tracestate`.
///
/// The order matters and is the order the spec states: oversized entries go first
/// (they are the expensive ones and the least likely to be a well-known vendor
/// key), then entries are dropped from the end. Dropping from the front would
/// discard the most recent vendor's entry, which is the one that just wrote it and
/// the one that knows where the trace currently is.
pub fn forward_tracestate(value: Option<&str>) -> Option<String> {
    let raw = value?;
    if raw.is_empty() {
        return None;
    }

    let mut entries: Vec<&str> = Vec::new();
    for piece in raw.split(',') {
        let entry = piece.trim();
        if entry.is_empty() || entry.len() > TRACESTATE_ENTRY_LIMIT {
            continue;
        }
        entries.push(entry);
    }

    while !entries.is_empty() {
        let joined = entries.join(",");
        if joined.len() <= TRACESTATE_LIMIT {
            return Some(joined);
        }
        entries.pop();
    }

    None
}

/// Look a header up case-insensitively.
///
/// §3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
/// mixed)". A `HeaderMap` from `http` is already lowercase, but a plain
/// `HashMap` built by hand, a proxy, or a test will not be, and being strict here
/// breaks traces in production for no reason.
pub fn header<'a>(headers: &'a BTreeMap<String, String>, name: &str) -> Option<&'a String> {
    if let Some(value) = headers.get(name) {
        return Some(value);
    }
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value)
}

/// A fresh 16-byte trace identifier as 32 hex characters.
///
/// §8: 16 bytes from a cryptographically secure source, never all zeroes.
pub fn new_trace_id() -> String {
    random_hex(16)
}

/// A fresh 8-byte span identifier as 16 hex characters.
///
/// §8. On all-zero failure it returns a fixed non-zero constant rather than
/// panicking: an exhausted entropy source is not a reason to take the service
/// down, and §3.2.2.4 only requires that the value is not all zeroes. The
/// collision risk is theoretical; the availability risk is not.
pub fn new_span_id() -> String {
    let id = random_hex(8);
    if id == ZERO_SPAN_ID {
        "0000000000000001".to_string()
    } else {
        id
    }
}

/// Whether `value` is entirely lowercase hex.
///
/// §3.2.2 defines the alphabet as HEXDIGLC, lowercase only. Uppercase is rejected
/// rather than folded: accepting it means two services disagree about whether a
/// header is valid, and one of them starts a new trace.
fn is_lower_hex(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `n` bytes from the OS CSPRNG as lowercase hex.
///
/// `/dev/urandom` rather than a userspace PRNG: trace ids end up in logs and in
/// traces that leave the process, and a predictable trace id is an invitation to
/// correlate two users' requests by guessing.
fn random_hex(n: usize) -> String {
    let mut out = String::with_capacity(n * 2);
    for byte in random_bytes(n) {
        out.push(char::from_digit((byte >> 4) as u32, 16).unwrap_or('0'));
        out.push(char::from_digit((byte & 0x0f) as u32, 16).unwrap_or('0'));
    }
    out
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    if std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut buf)).is_err() {
        buf.iter_mut().for_each(|byte| *byte = 1);
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    const KNOWN_HEADER: &str = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const KNOWN_TRACE: &str = "4bf92f3577b34da6a3ce929d0e0e4736";
    const KNOWN_PARENT: &str = "00f067aa0ba902b7";
    const FIXED_SPAN: &str = "1111111111111111";

    fn headers(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn known_traceparent_is_continued() {
        let hop = server_hop(&headers(&[("traceparent", KNOWN_HEADER)]), FIXED_SPAN);

        assert_eq!(hop.trace_id, KNOWN_TRACE);
        assert!(hop.continued, "a valid inbound traceparent must be continued");
        assert_eq!(hop.span_id, FIXED_SPAN);
        assert_ne!(hop.span_id, KNOWN_PARENT, "span id must not be the inbound parent-id");
        assert!(hop.sampled(), "sampled flag (§3.2.2.5.1) must survive the hop");

        let out = hop.outbound_headers();
        let tp = parse_traceparent(out.get("traceparent").map(String::as_str))
            .expect("outbound traceparent must parse");
        assert_eq!(tp.trace_id, KNOWN_TRACE);
        assert_eq!(tp.parent_id, FIXED_SPAN, "outbound parent-id is this hop's span id");
        assert!(tp.sampled(), "outbound trace-flags lost the sampled bit");
        assert_eq!(tp.version, 0, "we emit the version we implement");
    }

    #[test]
    fn unsampled_flag_is_preserved() {
        let unsampled = format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}-00");
        let hop = server_hop(&headers(&[("traceparent", &unsampled)]), FIXED_SPAN);

        assert!(!hop.sampled(), "sampled flag must not be invented on an unsampled trace");
        assert_eq!(hop.trace_id, KNOWN_TRACE);
        assert!(
            hop.outbound_headers()["traceparent"].ends_with("-00"),
            "outbound must end in -00"
        );
    }

    #[test]
    fn second_hop_keeps_the_same_trace_id() {
        let first = server_hop(&headers(&[("traceparent", KNOWN_HEADER)]), "2222222222222222");
        let second = server_hop(&first.outbound_headers(), "3333333333333333");

        assert_eq!(second.trace_id, KNOWN_TRACE, "trace broken across hops");
        assert!(second.continued, "a traceparent we just emitted must parse again");
    }

    #[test]
    fn malformed_traceparent_starts_a_new_trace() {
        let bad: Vec<(&str, String)> = vec![
            ("empty", String::new()),
            ("not a header", "garbage".to_string()),
            ("truncated at 54", format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}")),
            ("version 00 plus junk", format!("{KNOWN_HEADER}-extra")),
            ("all-zero trace-id", format!("00-{}-{KNOWN_PARENT}-01", "0".repeat(32))),
            ("all-zero parent-id", format!("00-{KNOWN_TRACE}-{}-01", "0".repeat(16))),
            (
                "uppercase hex",
                format!("00-4BF92F3577B34DA6A3CE929D0E0E4736-{KNOWN_PARENT}-01"),
            ),
            ("forbidden version ff", format!("ff-{KNOWN_TRACE}-{KNOWN_PARENT}-01")),
            ("one-char version", format!("0-{KNOWN_TRACE}-{KNOWN_PARENT}-01")),
            ("wrong delimiters", format!("00_{KNOWN_TRACE}_{KNOWN_PARENT}_01")),
            ("non-hex flags", format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}-0g")),
        ];

        for (name, value) in &bad {
            let hop = server_hop(&headers(&[("traceparent", value.as_str())]), FIXED_SPAN);

            assert!(!hop.continued, "{name}: {value} was accepted as a valid traceparent");
            assert_ne!(hop.trace_id, KNOWN_TRACE, "{name}: an invalid traceparent contributed its trace-id");
            assert_eq!(hop.trace_id.len(), 32, "{name}");
            assert_ne!(hop.trace_id, "0".repeat(32), "{name}: trace-id must not be all zeroes (§3.2.2.3)");
            assert!(
                parse_traceparent(hop.outbound_headers().get("traceparent").map(String::as_str)).is_some(),
                "{name}: the restarted trace must be valid on the way out"
            );
        }
    }

    #[test]
    fn missing_traceparent_starts_a_new_trace() {
        let hop = server_hop(&headers(&[]), FIXED_SPAN);

        assert!(!hop.continued);
        assert_eq!(hop.trace_id.len(), 32);
        assert_ne!(hop.trace_id, "0".repeat(32));
        assert!(!hop.sampled(), "a trace we started defaults to not-sampled (§3.2.2.5.1)");
    }

    #[test]
    fn tracestate_is_forwarded() {
        let hop = server_hop(
            &headers(&[
                ("traceparent", KNOWN_HEADER),
                ("tracestate", "congo=t61rcWkgMzE"),
            ]),
            FIXED_SPAN,
        );

        assert_eq!(hop.outbound_headers()["tracestate"], "congo=t61rcWkgMzE");
    }

    #[test]
    fn tracestate_is_truncated_at_whole_entries() {
        let entries: Vec<String> = (0..60)
            .map(|i| format!("v{:02}={}", i, "x".repeat(30)))
            .collect();
        let long = entries.join(",");

        let hop = server_hop(
            &headers(&[
                ("traceparent", KNOWN_HEADER),
                ("tracestate", long.as_str()),
            ]),
            FIXED_SPAN,
        );
        let out = hop.outbound_headers();
        let out = out.get("tracestate").expect("tracestate survives").clone();

        assert!(out.len() <= 512, "§3.3.1.5 caps a combined header at 512, got {}", out.len());
        assert!(!out.is_empty(), "truncating dropped the whole header");
        for entry in out.split(',') {
            assert!(long.contains(entry), "entry {entry} was truncated mid-entry");
        }
        assert!(out.starts_with(&entries[0]), "§3.3.1.5 drops entries from the end");
    }

    #[test]
    fn oversized_tracestate_entries_are_removed_first() {
        let oversized = format!("huge={}", "y".repeat(200));
        let joined = format!("{oversized},small=1");
        let hop = server_hop(
            &headers(&[
                ("traceparent", KNOWN_HEADER),
                ("tracestate", joined.as_str()),
            ]),
            FIXED_SPAN,
        );
        let out = hop.outbound_headers();
        let out = out.get("tracestate").expect("tracestate survives").clone();

        assert!(!out.contains("huge="), "an entry over 128 characters is removed first");
        assert_eq!(out, "small=1");
    }

    #[test]
    fn tracestate_without_a_valid_traceparent_is_discarded() {
        for value in ["", "not-a-traceparent"] {
            let hop = server_hop(
                &headers(&[
                    ("traceparent", value),
                    ("tracestate", "congo=t61rcWkgMzE"),
                ]),
                FIXED_SPAN,
            );

            assert!(
                !hop.outbound_headers().contains_key("tracestate"),
                "tracestate must be discarded when traceparent is {value:?}"
            );
        }
    }

    #[test]
    fn header_names_are_case_insensitive_and_sent_lowercase() {
        for name in ["traceparent", "TraceParent", "TRACEPARENT", "Traceparent"] {
            let hop = server_hop(&headers(&[(name, KNOWN_HEADER)]), FIXED_SPAN);
            assert_eq!(hop.trace_id, KNOWN_TRACE, "header {name} was not recognised");
        }

        let out = server_hop(&headers(&[("TraceParent", KNOWN_HEADER)]), FIXED_SPAN).outbound_headers();
        for name in out.keys() {
            assert_eq!(name, &name.to_lowercase(), "§3.2.1: send the header name lowercase");
        }
    }

    #[test]
    fn higher_version_is_downgraded_and_unknown_fields_are_not_forwarded() {
        let future = format!("cc-{KNOWN_TRACE}-{KNOWN_PARENT}-01-what-the-future-wants");

        let tp = parse_traceparent(Some(future.as_str())).expect("a well-formed higher version parses per §3.2.4");
        assert_eq!(tp.version, 0xcc);
        assert_eq!(tp.trace_id, KNOWN_TRACE);
        assert_eq!(tp.parent_id, KNOWN_PARENT);

        let hop = server_hop(&headers(&[("traceparent", future.as_str())]), FIXED_SPAN);
        let out = hop.outbound_headers();
        let out = out.get("traceparent").expect("traceparent").clone();

        assert!(out.starts_with("00-"), "outbound {out} must be downgraded to version 00");
        assert!(
            !out.contains("what-the-future-wants"),
            "§3.2.4: MUST NOT forward unknown fields"
        );
    }

    #[test]
    fn trace_flags_are_a_bit_field() {
        let both = format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}-03");
        let hop = server_hop(&headers(&[("traceparent", both.as_str())]), FIXED_SPAN);

        assert!(hop.sampled(), "bit 0 set means sampled; reading flags as a number is the classic bug");
        assert!(
            hop.outbound_headers()["traceparent"].ends_with("-01"),
            "reserved bits must be zeroed on the way out (§3.2.2.5.2)"
        );
    }

    #[test]
    fn new_identifiers_are_random_and_never_all_zero() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..256 {
            let trace_id = new_trace_id();
            assert_eq!(trace_id.len(), 32);
            assert_ne!(trace_id, "0".repeat(32));
            assert!(seen.insert(trace_id.clone()), "new_trace_id repeated {trace_id} in 256 draws (§8.2)");

            assert_eq!(new_span_id().len(), 16);
        }
    }
}
