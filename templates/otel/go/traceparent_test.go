package kitotel

import (
	"strings"
	"testing"
)

const (
	knownHeader  = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	knownTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	knownParent  = "00f067aa0ba902b7"
	fixedSpanID = "1111111111111111"
)

func headers(pairs ...string) map[string]string {
	h := make(map[string]string, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		h[pairs[i]] = pairs[i+1]
	}
	return h
}

func TestKnownTraceparentIsContinued(t *testing.T) {
	hop := ServerHopFrom(headers("traceparent", knownHeader), fixedSpanID)

	if hop.TraceID != knownTraceID {
		t.Fatalf("trace-id changed: got %q, want %q", hop.TraceID, knownTraceID)
	}
	if !hop.Continued {
		t.Fatal("a valid inbound traceparent must be continued, not restarted")
	}
	if hop.SpanID != fixedSpanID {
		t.Fatalf("span id = %q, want %q", hop.SpanID, fixedSpanID)
	}
	if hop.SpanID == knownParent {
		t.Fatal("span id must not be the inbound parent-id: that is not a new span")
	}
	if !hop.Sampled() {
		t.Fatal("sampled flag (§3.2.2.5.1) must survive the hop")
	}

	out := hop.OutboundHeaders()
	tp, ok := ParseTraceparent(out["traceparent"])
	if !ok {
		t.Fatalf("outbound traceparent %q did not parse", out["traceparent"])
	}
	if tp.TraceID != knownTraceID {
		t.Fatalf("outbound trace-id = %q, want %q", tp.TraceID, knownTraceID)
	}
	if tp.ParentID != fixedSpanID {
		t.Fatalf("outbound parent-id = %q, want this hop's span id %q", tp.ParentID, fixedSpanID)
	}
	if !tp.Sampled() {
		t.Fatal("outbound trace-flags lost the sampled bit")
	}
	if tp.Version != 0 {
		t.Fatalf("outbound version = %d, want 00 — we emit the version we implement", tp.Version)
	}
}

func TestUnsampledFlagIsPreserved(t *testing.T) {
	unsampled := "00-" + knownTraceID + "-" + knownParent + "-00"
	hop := ServerHopFrom(headers("traceparent", unsampled), fixedSpanID)

	if hop.Sampled() {
		t.Fatal("sampled flag must not be invented on an unsampled trace")
	}
	if hop.TraceID != knownTraceID {
		t.Fatalf("trace-id = %q, want %q", hop.TraceID, knownTraceID)
	}
	out := hop.OutboundHeaders()
	if !strings.HasSuffix(out["traceparent"], "-00") {
		t.Fatalf("outbound traceparent %q must end in -00", out["traceparent"])
	}
}

func TestSecondHopKeepsTheSameTraceID(t *testing.T) {
	first := ServerHopFrom(headers("traceparent", knownHeader), "2222222222222222")
	secondHop := ServerHopFrom(first.OutboundHeaders(), "3333333333333333")

	if secondHop.TraceID != knownTraceID {
		t.Fatalf("trace broken across hops: %q -> %q", first.TraceID, secondHop.TraceID)
	}
	if !secondHop.Continued {
		t.Fatal("a traceparent this service just emitted must parse on the way back in")
	}
}

func TestMalformedTraceparentStartsANewTrace(t *testing.T) {
	bad := map[string]string{
		"empty":                "",
		"not a header":         "garbage",
		"truncated at 54":      "00-" + knownTraceID + "-" + knownParent,
		"version 00 plus junk": knownHeader + "-extra",
		"all-zero trace-id":    "00-00000000000000000000000000000000-" + knownParent + "-01",
		"all-zero parent-id":   "00-" + knownTraceID + "-0000000000000000-01",
		"uppercase hex":        "00-4BF92F3577B34DA6A3CE929D0E0E4736-" + knownParent + "-01",
		"forbidden version ff": "ff-" + knownTraceID + "-" + knownParent + "-01",
		"one-char version":     "0-" + knownTraceID + "-" + knownParent + "-01",
		"wrong delimiters":     "00_" + knownTraceID + "_" + knownParent + "_01",
		"non-hex flags":        "00-" + knownTraceID + "-" + knownParent + "-0g",
	}

	for name, value := range bad {
		t.Run(name, func(t *testing.T) {
			hop := ServerHopFrom(headers("traceparent", value), fixedSpanID)

			if hop.Continued {
				t.Fatalf("%q was accepted as a valid traceparent", value)
			}
			if hop.TraceID == knownTraceID {
				t.Fatal("an invalid traceparent must not contribute its trace-id")
			}
			if len(hop.TraceID) != 32 {
				t.Fatalf("restarted trace-id %q is not 32 hex characters", hop.TraceID)
			}
			if hop.TraceID == strings.Repeat("0", 32) {
				t.Fatal("restarted trace-id must not be all zeroes (§3.2.2.3)")
			}
			if _, ok := ParseTraceparent(hop.OutboundHeaders()["traceparent"]); !ok {
				t.Fatal("the restarted trace must be valid on the way out")
			}
		})
	}
}

func TestMissingTraceparentStartsANewTrace(t *testing.T) {
	hop := ServerHopFrom(map[string]string{}, fixedSpanID)

	if hop.Continued {
		t.Fatal("no inbound traceparent means a new trace (§4.2)")
	}
	if len(hop.TraceID) != 32 || hop.TraceID == strings.Repeat("0", 32) {
		t.Fatalf("new trace-id %q is not a usable 32-hex identifier", hop.TraceID)
	}
	if hop.Sampled() {
		t.Fatal("a trace this service started must default to not-sampled")
	}
}

func TestTracestateIsForwarded(t *testing.T) {
	hop := ServerHopFrom(headers(
		"traceparent", knownHeader,
		"tracestate", "congo=t61rcWkgMzE",
	), fixedSpanID)

	if got := hop.OutboundHeaders()["tracestate"]; got != "congo=t61rcWkgMzE" {
		t.Fatalf("tracestate = %q, want it forwarded unchanged", got)
	}
}

func TestTracestateIsTruncatedAtWholeEntries(t *testing.T) {
	var entries []string
	for i := 0; i < 60; i++ {
		key := "v" + string(rune('a'+i/26)) + string(rune('a'+i%26))
		entries = append(entries, key+"="+strings.Repeat("x", 30))
	}
	long := strings.Join(entries, ",")

	hop := ServerHopFrom(headers(
		"traceparent", knownHeader,
		"tracestate", long,
	), fixedSpanID)

	out := hop.OutboundHeaders()["tracestate"]
	if len(out) > 512 {
		t.Fatalf("tracestate is %d characters; §3.3.1.5 caps a combined header at 512", len(out))
	}
	if out == "" {
		t.Fatal("truncating dropped the whole header")
	}
	for _, entry := range strings.Split(out, ",") {
		if !strings.Contains(long, entry) {
			t.Fatalf("entry %q was truncated mid-entry, which §3.3.1.5 forbids", entry)
		}
	}
	if !strings.HasPrefix(out, entries[0]) {
		t.Fatalf("truncation removed the first entry %q; §3.3.1.5 drops from the end", entries[0])
	}
}

func TestOversizedTracestateEntriesAreRemovedFirst(t *testing.T) {
	oversized := "huge=" + strings.Repeat("y", 200)
	hop := ServerHopFrom(headers(
		"traceparent", knownHeader,
		"tracestate", oversized+",small=1",
	), fixedSpanID)

	out := hop.OutboundHeaders()["tracestate"]
	if strings.Contains(out, "huge=") {
		t.Fatalf("an entry over 128 characters should be removed first, got %q", out)
	}
	if out != "small=1" {
		t.Fatalf("tracestate = %q, want the surviving entry %q", out, "small=1")
	}
}

func TestTracestateWithoutAValidTraceparentIsDiscarded(t *testing.T) {
	for name, tp := range map[string]string{
		"no traceparent":  "",
		"bad traceparent": "not-a-traceparent",
	} {
		t.Run(name, func(t *testing.T) {
			hop := ServerHopFrom(headers(
				"traceparent", tp,
				"tracestate", "congo=t61rcWkgMzE",
			), fixedSpanID)

			if got, ok := hop.OutboundHeaders()["tracestate"]; ok {
				t.Fatalf("tracestate %q must be discarded with no valid traceparent", got)
			}
		})
	}
}

func TestHeaderNamesAreCaseInsensitiveAndSentLowercase(t *testing.T) {
	for _, name := range []string{"traceparent", "TraceParent", "TRACEPARENT", "Traceparent"} {
		hop := ServerHopFrom(headers(name, knownHeader), fixedSpanID)
		if hop.TraceID != knownTraceID {
			t.Fatalf("header %q was not recognised (trace-id %q)", name, hop.TraceID)
		}
	}

	out := ServerHopFrom(headers("TraceParent", knownHeader), fixedSpanID).OutboundHeaders()
	for name := range out {
		if name != strings.ToLower(name) {
			t.Fatalf("outbound header %q is not lowercase; §3.2.1 says vendors SHOULD send lowercase", name)
		}
	}
}

func TestHigherVersionIsDowngradedAndUnknownFieldsAreNotForwarded(t *testing.T) {
	future := "cc-" + knownTraceID + "-" + knownParent + "-01-what-the-future-wants"

	tp, ok := ParseTraceparent(future)
	if !ok {
		t.Fatalf("a well-formed higher version %q must be parsed per §3.2.4", future)
	}
	if tp.Version != 0xcc {
		t.Fatalf("version = %#x, want 0xcc", tp.Version)
	}
	if tp.TraceID != knownTraceID || tp.ParentID != knownParent {
		t.Fatalf("§3.2.4 requires trace-id and parent-id to be parsed positionally, got %q/%q",
			tp.TraceID, tp.ParentID)
	}

	hop := ServerHopFrom(headers("traceparent", future), fixedSpanID)
	out := hop.OutboundHeaders()["traceparent"]
	if !strings.HasPrefix(out, "00-") {
		t.Fatalf("outbound %q must be downgraded to version 00", out)
	}
	if strings.Contains(out, "what-the-future-wants") {
		t.Fatalf("unknown fields were forwarded in %q; §3.2.4 says MUST NOT", out)
	}
}

func TestTraceFlagsAreABitField(t *testing.T) {
	both := "00-" + knownTraceID + "-" + knownParent + "-03"

	hop := ServerHopFrom(headers("traceparent", both), fixedSpanID)
	if !hop.Sampled() {
		t.Fatal("bit 0 set means sampled; reading flags as a number is the classic bug")
	}
	out := hop.OutboundHeaders()["traceparent"]
	if !strings.HasSuffix(out, "-01") {
		t.Fatalf("outbound trace-flags must be rebuilt as 01 with reserved bits zeroed, got %q", out)
	}
}

func TestNewIdentifiersAreRandomAndNeverAllZero(t *testing.T) {
	seen := make(map[string]bool, 256)
	for i := 0; i < 256; i++ {
		id := NewTraceID()
		if len(id) != 32 || id == strings.Repeat("0", 32) {
			t.Fatalf("NewTraceID() = %q", id)
		}
		if seen[id] {
			t.Fatalf("NewTraceID() repeated %q in 256 draws (§8.2)", id)
		}
		seen[id] = true

		span := NewSpanID()
		if len(span) != 16 || span == strings.Repeat("0", 16) {
			t.Fatalf("NewSpanID() = %q", span)
		}
	}
}
