package kitsecrets

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"kitsecrets/internal/safe"
)

type probeToken struct{ value string }

func (t *probeToken) String() string   { return "redacted" }
func (t *probeToken) GoString() string { return "redacted" }

type (
	valueUnexported struct {
		subject string
		tok     probeToken
	}
	pointerUnexported struct {
		subject string
		tok     *probeToken
	}
	pointerExported struct {
		Subject string
		Tok     *probeToken
	}
	valueExported struct {
		Subject string
		Tok     probeToken
	}
	funcUnexported struct {
		subject string
		tok     func() string
	}
)

var (
	stringVerbs = []string{"%v", "%+v", "%#v", "%s", "%q"}
	numericVerb = []string{"%t", "%e", "%f", "%g", "%U", "%d"}
	hexVerbs    = []string{"%x", "%X"}
	typeVerbs   = []string{"%T"}
)

func TestFmtTruthTable(t *testing.T) {
	const secret = "anywaye_canary_truth_table"

	lowerHex := hex.EncodeToString([]byte(secret))
	leaks := func(out string) bool {
		return strings.Contains(out, secret) ||
			strings.Contains(out, lowerHex) ||
			strings.Contains(out, strings.ToUpper(lowerHex))
	}

	leakVerbs := append([]string{}, stringVerbs...)
	leakVerbs = append(leakVerbs, numericVerb...)
	leakVerbs = append(leakVerbs, hexVerbs...)

	shapes := []struct {
		name       string
		value      any
		leaksEvery bool
		expect     map[string]bool
	}{
		{
			name:       "value field, unexported",
			value:      valueUnexported{subject: "s", tok: probeToken{secret}},
			leaksEvery: true,
		},
		{
			name:       "value field, EXPORTED",
			value:      valueExported{Subject: "s", Tok: probeToken{secret}},
			leaksEvery: true,
		},
		{
			name:  "pointer field, unexported",
			value: pointerUnexported{subject: "s", tok: &probeToken{secret}},
			expect: map[string]bool{
				"%s": true, "%q": true,
				"%t": true, "%e": true, "%f": true, "%g": true, "%U": true,
			},
		},
		{
			name:  "pointer field, EXPORTED",
			value: pointerExported{Subject: "s", Tok: &probeToken{secret}},
			expect: map[string]bool{
				"%t": true, "%e": true, "%f": true, "%g": true, "%U": true,
			},
		},
		{
			name:  "func field, unexported",
			value: funcUnexported{subject: "s", tok: func() string { return secret }},
		},
		{
			name:  "bare *probeToken",
			value: &probeToken{secret},
			expect: map[string]bool{
				"%d": true, "%t": true, "%e": true, "%f": true, "%g": true, "%U": true,
			},
		},
	}

	for _, shape := range shapes {
		for _, verb := range leakVerbs {
			out := fmt.Sprintf(verb, shape.value)
			gotLeak := leaks(out)
			wantLeak := shape.leaksEvery || shape.expect[verb]
			if gotLeak != wantLeak {
				verdict := "safe"
				if gotLeak {
					verdict = "LEAKS"
				}
				t.Errorf("%s under %s: %s, want the opposite — got %q.\n"+
					"  internal/safe is shaped on the strength of this table, so a change here "+
					"means the reference pattern is wrong and every type copied from it is a "+
					"credential in every log line.",
					shape.name, verb, verdict, out)
			}
		}
		for _, verb := range typeVerbs {
			if out := fmt.Sprintf(verb, shape.value); leaks(out) {
				t.Errorf("%s under %s leaked, and a type name cannot carry a value — this means "+
					"the probe is wrong, not the shape: %q", shape.name, verb, out)
			}
		}
	}
}

func TestTheReferenceTypeIsSafeUnderEveryDispatchedVerb(t *testing.T) {
	holder := safe.NewSession("svc", []string{"invoices:read"}, safe.NewToken(Canary()))

	for _, verb := range stringVerbs {
		if out := fmt.Sprintf(verb, holder); strings.Contains(out, Canary()) {
			t.Errorf("%s of safe.Session printed the canary: %q", verb, out)
		}
		if out := fmt.Sprintf(verb, holder.Token); strings.Contains(out, Canary()) {
			t.Errorf("%s of a *safe.Token printed the canary: %q", verb, out)
		}
	}
	for _, verb := range hexVerbs {
		if out := fmt.Sprintf(verb, holder); strings.Contains(out, hex.EncodeToString([]byte(Canary()))) {
			t.Errorf("%s of safe.Session printed the canary in hex — reversible with one "+
				"command, and a leak: %q", verb, out)
		}
	}

	if out := fmt.Sprintf("%v", holder.Token); !strings.Contains(out, "redacted") {
		t.Errorf("%%v of a *safe.Token did not use its String method: %q. The redaction IS the "+
			"mechanism that makes this shape safe, so if it stopped being applied the shape is "+
			"one refactor away from a leak", out)
	}
}

func TestTheReferenceTypeLeaksUnderBadVerbs(t *testing.T) {
	holder := safe.NewSession("svc", nil, safe.NewToken(Canary()))

	leaked := map[string]bool{}
	for _, verb := range numericVerb {
		if out := fmt.Sprintf(verb, holder); strings.Contains(out, Canary()) {
			leaked[verb] = true
		}
	}
	if len(leaked) == 0 {
		t.Fatalf("safe.Session no longer leaks the canary under any of %v.\n"+
			"The shape has got better. Update the package comment in internal/safe and the "+
			"residual-risk note above, and consider dropping the accepted gap.", numericVerb)
	}
	if len(leaked) == len(numericVerb) {
		t.Fatalf("safe.Session leaks under a verb fmt SHOULD be dispatching to String() for "+
			"(%v). That is a different bug from the accepted gap: it means the redaction stopped "+
			"being applied, and the shape is no longer safe under the verbs developers use. "+
			"Actually leaked under: %v", stringVerbs, leaked)
	}

	var shape string
	for _, verb := range numericVerb {
		if out := fmt.Sprintf(verb, holder); strings.Contains(out, Canary()) {
			shape = redactForReport(out)
			break
		}
	}
	t.Logf("known and accepted: %v of %d print the credential, because fmt has no Stringer "+
		"path for a numeric verb and falls back to the %%!verb(…&{...}) form with the value "+
		"inside the error text. Example (redacted): %q",
		leaked, len(numericVerb), shape)
}

func TestAFuncFieldCannotBeSerialised(t *testing.T) {
	holder := safe.NewSession("svc", nil, safe.NewToken(Canary()))

	if _, err := json.Marshal(holder); err != nil {
		t.Fatalf("safe.Session no longer marshals at all: %v. Vector 2 and vector 4 both "+
			"marshal it, and a shape they cannot serialise is a shape they cannot check", err)
	}

	guarded := struct {
		Subject string
		Tok     func() string
	}{Subject: "svc", Tok: func() string { return Canary() }}
	if _, err := json.Marshal(guarded); err == nil {
		t.Fatal("a struct with a func() string field marshalled successfully. This test exists to " +
			"pin the property that makes that shape the safe one, and if encoding/json has gained " +
			"the ability to skip func fields then the shape no longer prevents serialisation and " +
			"internal/safe's recommendation needs revisiting")
	}
}

func redactForReport(s string) string {
	return strings.ReplaceAll(s, Canary(), "anywaye_canary_REDACTED")
}

func TestTheSuiteNeverPrintsTheCanary(t *testing.T) {
	holder := safe.NewSession("svc", nil, safe.NewToken(Canary()))

	raw := fmt.Sprintf("%v", holder) + " " + Canary()
	if !strings.Contains(raw, Canary()) {
		t.Fatalf("the control string does not contain the planted value, so every assertion "+
			"below is vacuous: %q", redactForReport(raw))
	}
	if got := redactForReport(raw); strings.Contains(got, Canary()) {
		t.Errorf("redactForReport did not remove the planted value: %q", got)
	}

	var shape string
	for _, verb := range numericVerb {
		if out := fmt.Sprintf(verb, holder); strings.Contains(out, Canary()) {
			shape = redactForReport(out)
			break
		}
	}
	if shape == "" {
		t.Fatal("no leaking verb produced output, so the example the log line prints is empty")
	}
	if strings.Contains(shape, Canary()) {
		t.Errorf("the redacted example still contains the planted value: %q", shape)
	}
}

func TestAnUnredactedTokenIsPrintable(t *testing.T) {
	const secret = "anywaye_canary_control"
	holder := valueUnexported{subject: "s", tok: probeToken{secret}}
	if !strings.Contains(fmt.Sprintf("%v", holder), secret) {
		t.Fatalf("an unexported field of an unredacted type did NOT print its value: this Go " +
			"version has changed fmt's handling of unexported fields, so the truth table the " +
			"other tests in this file rest on no longer holds and internal/safe's comment is stale")
	}
}
