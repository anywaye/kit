package kitotel

import (
	"crypto/rand"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	sampledFlag = 0x01

	minHeaderLen = 55

	tracestateLimit = 512

	tracestateEntryLimit = 128

	zeroTraceID = "00000000000000000000000000000000"
	zeroSpanID  = "0000000000000000"
)

// TraceParent is a parsed `traceparent` header.
//
// Exported so a caller can inspect what it received without re-parsing, which
// is how a debug endpoint shows the inbound trace-id.
type TraceParent struct {
	Version int
	TraceID string
	ParentID string
	Flags int
	Extra string
}

// Sampled reports the caller's recording decision (§3.2.2.5.1). We carry this
// rather than making our own: a service that re-decides sampling per hop
// produces traces with holes in them, which are worse than no traces.
func (tp TraceParent) Sampled() bool { return tp.Flags&sampledFlag == sampledFlag }

// ServerHop is one service's continuation of a trace: what we tell our caller
// about the request we handled, and what we put on the wire to the next hop.
type ServerHop struct {
	TraceID string
	SpanID string
	Flags int
	Tracestate string
	Continued bool
}

// Sampled is the recording decision this hop forwards (§3.2.2.5.1).
func (h ServerHop) Sampled() bool { return h.Flags&sampledFlag == sampledFlag }

// ParseTraceparent parses a `traceparent` header value.
//
// Returns false for anything invalid, and that is the whole contract: §3.2.2.3
// and §3.2.2.4 say a vendor MUST ignore the header when trace-id or parent-id is
// invalid, and §3.2.4 says to restart the trace when the version cannot be
// parsed. There is no error to handle and no value to partially trust — an
// invalid header means "start a new trace", not "carry on with what parsed".
func ParseTraceparent(value string) (TraceParent, bool) {
	if len(value) < minHeaderLen {
		return TraceParent{}, false
	}
	if value[2] != '-' || !isLowerHex(value[0:2]) {
		return TraceParent{}, false
	}
	version, err := strconv.ParseInt(value[0:2], 16, 16)
	if err != nil {
		return TraceParent{}, false
	}
	if version == 0xFF {
		return TraceParent{}, false
	}

	traceID := value[3:35]
	parentID := value[36:52]
	flagsField := value[53:55]

	if value[35] != '-' || value[52] != '-' {
		return TraceParent{}, false
	}
	if !isLowerHex(traceID) || !isLowerHex(parentID) || !isLowerHex(flagsField) {
		return TraceParent{}, false
	}

	flags, err := strconv.ParseInt(flagsField, 16, 16)
	if err != nil {
		return TraceParent{}, false
	}

	if version == 0 {
		if len(value) != minHeaderLen {
			return TraceParent{}, false
		}
	} else if len(value) > minHeaderLen {
		if value[55] != '-' {
			return TraceParent{}, false
		}
	}

	if traceID == zeroTraceID || parentID == zeroSpanID {
		return TraceParent{}, false
	}

	return TraceParent{
		Version:  int(version),
		TraceID:  traceID,
		ParentID: parentID,
		Flags:    int(flags),
		Extra:    strings.TrimPrefix(value[minHeaderLen:], "-"),
	}, true
}

// ServerHopFrom continues the trace described by the inbound headers.
//
// This is the one function a service's inbound middleware calls. It cannot
// fail: a malformed or absent traceparent yields a new trace, because a request
// is not an error because its trace header was garbage (§4.2, §3.2.2.3).
//
// spanID is a parameter rather than generated here so that the caller owns the
// span lifecycle — in a real service it comes from the tracer, and in a test it
// is a constant, which is why traceparent_test.go can assert equality instead
// of a shape.
func ServerHopFrom(headers map[string]string, spanID string) ServerHop {
	tp, valid := ParseTraceparent(header(headers, "traceparent"))

	if !valid {
		return ServerHop{TraceID: NewTraceID(), SpanID: spanID, Flags: 0}
	}

	return ServerHop{
		TraceID: tp.TraceID,
		SpanID:  spanID,
		Flags:      tp.Flags & sampledFlag,
		Tracestate: forwardTracestate(header(headers, "tracestate")),
		Continued:  true,
	}
}

// OutboundHeaders renders this hop as headers for the next service.
//
// The shape is fixed by §3.4: parent-id becomes this hop's span id, and the
// version is downgraded to the one we implement. Those two mutations plus the
// sampled flag are the entire allowed set — §3.4 says vendors MUST NOT make any
// other mutation.
func (h ServerHop) OutboundHeaders() map[string]string {
	out := map[string]string{
		"traceparent": formatTraceparent(h.TraceID, h.SpanID, h.Flags),
	}
	if h.Tracestate != "" {
		out["tracestate"] = h.Tracestate
	}
	return out
}

func formatTraceparent(traceID, parentID string, flags int) string {
	var b strings.Builder
	b.Grow(minHeaderLen)
	b.WriteString("00-")
	b.WriteString(traceID)
	b.WriteByte('-')
	b.WriteString(parentID)
	b.WriteByte('-')
	b.WriteString(hex.EncodeToString([]byte{byte(flags & 0xFF)}))
	return b.String()
}

func forwardTracestate(value string) string {
	if value == "" {
		return ""
	}

	entries := make([]string, 0, 8)
	for _, raw := range strings.Split(value, ",") {
		entry := strings.TrimSpace(raw)
		if entry == "" {
			continue
		}
		if len(entry) > tracestateEntryLimit {
			continue
		}
		entries = append(entries, entry)
	}

	for len(entries) > 0 && len(strings.Join(entries, ",")) > tracestateLimit {
		entries = entries[:len(entries)-1]
	}

	return strings.Join(entries, ",")
}

func header(headers map[string]string, name string) string {
	if value, ok := headers[name]; ok {
		return value
	}
	for key, value := range headers {
		if strings.EqualFold(key, name) {
			return value
		}
	}
	return ""
}

func isLowerHex(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// NewTraceID returns a fresh 16-byte trace identifier as 32 hex characters.
//
// §8: 16 bytes from a cryptographically secure source, never all zeroes.
func NewTraceID() string { return randomHex(16) }

// NewSpanID returns a fresh 8-byte span identifier as 16 hex characters.
//
// §8. On all-zero failure it returns a fixed non-zero constant rather than
// panicking: an exhausted entropy source is not a reason to take the service
// down, and §3.2.2.4 only requires that the value is not all zeroes. The
// collision risk is theoretical; the availability risk is not.
func NewSpanID() string {
	id := randomHex(8)
	if id == zeroSpanID {
		return "0000000000000001"
	}
	return id
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
