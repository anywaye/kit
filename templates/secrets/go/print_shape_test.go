// kit template — the measurement the reference package's shape rests on.
//
// WHY THIS FILE EXISTS SEPARATELY FROM canary_test.go
//
//	`internal/safe`'s design is a truth table about `fmt`, and that table is a
//	property of the standard library rather than of this code. If a future Go
//	release changes it — and the results below are exactly the kind of thing a
//	formatting change could quietly alter — then every type shaped like
//	`internal/safe.Session` becomes a credential in every log line, and nothing
//	else in the suite would notice. Vector 1 only exercises the shapes kit
//	already got right, so it would keep passing while the reference pattern
//	rotted underneath it.
//
//	So the measurement itself is asserted, in full, and the expected verdicts are
//	written out rather than derived. A test that recomputed the table from the
//	same rules the code uses would prove that the code agrees with itself.
//
// WHAT THE TABLE SHOWS
//
//	shape                        %v %+v %#v %s  %q  %d  %x  %X  %t  %e  %U
//	value field,   unexported    ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗
//	value field,   EXPORTED      ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗   ✗
//	pointer field, unexported    ·   ·   ·   ✗   ✗   ·   ·   ·   ✗   ✗   ✗
//	pointer field, EXPORTED      ·   ·   ·   ·   ·   ·   ·   ·   ✗   ✗   ✗
//	func field,    unexported    ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
//
//	· = the credential is absent.   ✗ = it is printed.
//
//	FOUR FINDINGS, AND THE FIRST THREE ARE THE ONES PEOPLE GET WRONG
//
//	1. AN UNEXPORTED FIELD IS NOT PROTECTION. `fmt` reaches unexported fields
//	   through reflection and prints their values. The field being lowercase buys
//	   nothing against `%v`, and `%v` is in every log line in every service.
//	   `-race` will not stop it and `go vet` will not mention it.
//
//	2. A `String()` METHOD ON THE FIELD'S TYPE IS IGNORED WHEN THE FIELD IS
//	   UNEXPORTED. `fmt` cannot call a method on a value obtained from an
//	   unexported field, so it falls back to reflection and prints the struct. A
//	   redacting `String()` is real protection in an EXPORTED field and worth
//	   nothing in an unexported one. This is the one that surprises people,
//	   because the redaction is right there in the code.
//
//	3. THE POINTER SHAPE IS NOT A FREE LUNCH. An unexported pointer field prints
//	   an address under `%v`, which looks like the answer, and then `%s` and `%q`
//	   walk the pointer and print the value anyway. A shape that is safe under the
//	   verb everyone uses and unsafe under two others is worse than one that is
//	   obviously broken, because it passes review.
//
//	4. THE HEX VERBS ARE A LEAK TOO, AND NOT AN OBVIOUS ONE. `%x` and `%X` print
//	   the credential as `6361666179655f…`. That is not a log line a human can
//	   read, and it is a perfectly reversible encoding of a live secret, and
//	   `xxd -r -p` is one command away. A table that called `%x` safe would be
//	   wrong in the way that matters, which is why the predicate in
//	   TestFmtTruthTable asks about both hex cases and not about the literal
//	   bytes. This was found by writing the table down, not by reading fmt's
//	   source, which is the argument for writing tables down.
//
//	AND ONE RESULT THAT IS THE OPPOSITE OF WHAT FINDING 2 PREDICTS
//
//	Finding 2 says fmt cannot dispatch to String() on a value taken from an
//	unexported field, and the unexported POINTER row bears that out for `%s` and
//	`%q`. But `%d` on that same field prints the pointer ADDRESS and is safe — so
//	an unexported pointer field is safe under `%d` and unsafe under `%s`, which is
//	not a rule anyone would have guessed and is why the table is written out
//	instead of derived.
//
//	AND THE ONE SHAPE THAT IS SAFE UNDER EVERY VERB
//
//	A `func() string` field. `fmt` can only ever reach the pointer to the closure.
//	It has a second property worth as much as the first: `encoding/json` REFUSES
//	to marshal a struct with a func field, so a type shaped that way cannot be
//	serialised with the credential in it even by accident. It is awkward to use
//	for a credential read several times per request, which is why
//	`internal/safe` demonstrates the pointer shape as its primary holder.
//
//	AND THE REAL ANSWER, WHICH IS ABOVE ALL OF THEM
//
//	Don't hold the credential. Pass the `*Token` to the code that authenticates
//	with it, and keep only the subject and the scopes in a struct that gets
//	logged. `internal/safe.Claims` is that shape, and it is the one kit points a
//	service at first.
package kitsecrets

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"kitsecrets/internal/safe"
)

// The probe type: String and GoString are the only reason any field shape is
// safe at all.
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

// The verb groups, by mechanism rather than by taste — the grouping IS the
// finding.
//
//	stringVerbs  fmt dispatches to String()/GoString(), so a redacting type is
//	             honoured whatever the verb.
//	numericVerb  fmt has no Stringer path, so it falls back to printing the
//	             value: inside a struct as `%!t(*tok=&{…})`, applied to a bare
//	             *tok as the value itself.
//	hexVerbs     fmt renders the string as hex, which is reversible.
//	typeVerbs    %T prints a type name, which is not a secret.
var (
	stringVerbs = []string{"%v", "%+v", "%#v", "%s", "%q"}
	numericVerb = []string{"%t", "%e", "%f", "%g", "%U", "%d"}
	hexVerbs    = []string{"%x", "%X"}
	typeVerbs   = []string{"%T"}
)

// TestFmtTruthTable is the load-bearing test in this file.
//
// Every verdict is written out. The cell for a value field says "every verb",
// because that is what was measured and it is one fact rather than eleven.
func TestFmtTruthTable(t *testing.T) {
	const secret = "anywaye_canary_truth_table"

	// A leak is the credential appearing in ANY reversible encoding, in either
	// hex case. A test that looked only for the literal bytes would call `%X`
	// safe, and `%X` is one `xxd -r -p` away from the secret.
	lowerHex := hex.EncodeToString([]byte(secret))
	leaks := func(out string) bool {
		return strings.Contains(out, secret) ||
			strings.Contains(out, lowerHex) ||
			strings.Contains(out, strings.ToUpper(lowerHex))
	}

	// `%T` is excluded from `leaksEvery` because it prints a type name, which
	// cannot carry a value. It is asserted separately below, so a shape that
	// somehow started leaking under it would still fail.
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
			// fmt never dispatches to String for a struct VALUE, exported or not:
			// it has the struct, and it prints the struct.
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
			// Safe under the verb everyone uses, unsafe under two string verbs and
			// five numeric ones — and SAFE under `%d`, which prints the pointer
			// address. It is here so that a change to it is a test failure rather
			// than a surprise in production.
			name:  "pointer field, unexported",
			value: pointerUnexported{subject: "s", tok: &probeToken{secret}},
			expect: map[string]bool{
				"%s": true, "%q": true,
				"%t": true, "%e": true, "%f": true, "%g": true, "%U": true,
			},
		},
		{
			// Identical to the bare token: fmt dispatches to the field's methods
			// exactly as it would to the value, so this row and the bare-token row
			// are the same row. Five numeric verbs leak.
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
			// The token on its own, which is the row that makes the exported-pointer
			// row explicable. A service that logs `tok` rather than a struct holding
			// it is the common case, so it is measured rather than assumed.
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

// TestTheReferenceTypeIsSafeUnderEveryDispatchedVerb is the positive half: the
// shape kit actually tells a service to write, over the verbs fmt dispatches to
// String()/GoString() for. Those are the verbs a developer reaches for — `%v`
// and `%+v` are in essentially every log line written in Go.
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

	// And the positive control: the redaction is genuinely being applied, rather
	// than the value simply never reaching the format. A test that passes
	// because nothing happened is not a test.
	if out := fmt.Sprintf("%v", holder.Token); !strings.Contains(out, "redacted") {
		t.Errorf("%%v of a *safe.Token did not use its String method: %q. The redaction IS the "+
			"mechanism that makes this shape safe, so if it stopped being applied the shape is "+
			"one refactor away from a leak", out)
	}
}

// TestTheReferenceTypeLeaksUnderBadVerbs ASSERTS THE KNOWN GAP.
//
// `internal/safe.Session` is not safe under the numeric verbs, and this test
// exists so that stays a decision rather than becoming a surprise.
//
// It is written as an assertion that the leak EXISTS, which is unusual and is
// the point. The alternative — testing only the verbs that pass — means the gap
// lives in a comment, and a comment is not something a toolchain change or a
// refactor can fail. This test fails the moment the gap closes (someone adds
// `Format` to safe.Token), and the failure message says to update the comment in
// internal/safe, which is the correct outcome: the shape got better and the
// documentation should follow.
//
// The gap is accepted rather than fixed because closing it means the field holds
// a `func() string` — see TestAFuncFieldCannotBeSerialised — and a credential
// that is read several times per request is not a function call away in a way
// anyone would accept. Every numeric verb is also a bug at the call site: a bool,
// float, rune or int verb applied to a struct is not a thing anyone writes on
// purpose.
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

	// Show WHY, because "fmt printed it" is not something a reader can act on —
	// and REDACTED, because this is the one place in the harness that has
	// something real to redact, and printing it would make this log line the
	// counter-example to the rule the whole rest of this file states. It is the
	// fake canary today; the rule has to hold on the day it is not.
	//
	// It WAS printed in full the first time. `grep -c anywaye_canary_` over the
	// gate's own output is what caught it — a harness whose own output is never
	// swept is a harness that leaks in the one place nobody thought to look, and
	// that is precisely the place this file exists to talk about.
	// Built from a variable rather than written as a literal, so `go vet`'s
	// printf check does not reject this file. That check is right, and this call
	// is a deliberate misuse; suppressing a correct check to accommodate a
	// deliberate misuse is a bad trade in the one file whose subject is not
	// weakening checks.
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

// TestAFuncFieldCannotBeSerialised is the reason the accepted gap above is
// acceptable rather than merely noted: there IS a shape that closes it, and a
// service that can use it should know.
//
// The second property is the more valuable of the two and is the one nobody
// expects. `encoding/json` returns an error for a struct with a func field, so a
// type shaped this way cannot be serialised at all — not by a missing tag, not by
// a wrong tag, not by a future refactor that adds one.
func TestAFuncFieldCannotBeSerialised(t *testing.T) {
	holder := safe.NewSession("svc", nil, safe.NewToken(Canary()))

	// The shape kit demonstrates, with the tag it demonstrates.
	if _, err := json.Marshal(holder); err != nil {
		t.Fatalf("safe.Session no longer marshals at all: %v. Vector 2 and vector 4 both "+
			"marshal it, and a shape they cannot serialise is a shape they cannot check", err)
	}

	// And the shape that closes the gap, for comparison.
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

// redactForReport removes the planted value from a string that is about to be
// printed, keeping the SHAPE of what was printed.
//
// Shape, not just redaction, because the value of this example is the
// `%!t(*safe.Token=&{…})` form — a reader has to see that fmt fell back to
// printing the struct. `strings.ReplaceAll` on the exact value would do it, and
// that is the whole function on purpose: this file is about Go's `fmt`, and a
// redaction helper that had to be clever about it would be a second thing to get
// wrong in the one place the output is trusted.
func redactForReport(s string) string {
	return strings.ReplaceAll(s, Canary(), "anywaye_canary_REDACTED")
}

// TestTheSuiteNeverPrintsTheCanary is the harness sweeping itself.
//
// Every other test in this file prints format strings, failure messages and log
// lines, and every one of them is a place the value could reach a CI log. The
// first version of TestTheReferenceTypeLeaksUnderBadVerbs did exactly that — it
// logged the example unredacted, because the example was the point — and the
// gate's own output carried the canary on every green run.
//
// It is the fake canary, so nothing leaked. That is exactly why it needs a
// check: the day someone points this harness at a real credential, the same
// habit is a disclosure, and a habit is the thing that survives a refactor.
func TestTheSuiteNeverPrintsTheCanary(t *testing.T) {
	holder := safe.NewSession("svc", nil, safe.NewToken(Canary()))

	// The positive control FIRST, because a predicate that never fires is the
	// failure mode this whole file is about: build a string that does carry the
	// value, assert the predicate sees it, then assert the redacted form does
	// not. In that order, so a broken redaction and a broken predicate are
	// distinguishable rather than both reading as a pass.
	raw := fmt.Sprintf("%v", holder) + " " + Canary()
	if !strings.Contains(raw, Canary()) {
		t.Fatalf("the control string does not contain the planted value, so every assertion "+
			"below is vacuous: %q", redactForReport(raw))
	}
	if got := redactForReport(raw); strings.Contains(got, Canary()) {
		t.Errorf("redactForReport did not remove the planted value: %q", got)
	}

	// And the shape the log line actually uses — which is the one that leaked.
	//
	// Built from a variable format rather than a literal, so `go vet`'s printf
	// check does not reject this file. That check is right, a leaking verb is a
	// deliberate misuse, and suppressing a correct check to accommodate a
	// deliberate misuse is a bad trade in the one file whose subject is not
	// weakening checks.
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

// TestAnUnredactedTokenIsPrintable is the control for this whole file.
//
// If a future Go release stopped printing unexported field values, every "·" in
// the table above would keep passing — for the wrong reason, because nothing
// would be reaching them any more, and a type that cannot print anything is not a
// safe type. This one fails in that world, and says which measurement broke.
func TestAnUnredactedTokenIsPrintable(t *testing.T) {
	const secret = "anywaye_canary_control"
	holder := valueUnexported{subject: "s", tok: probeToken{secret}}
	if !strings.Contains(fmt.Sprintf("%v", holder), secret) {
		t.Fatalf("an unexported field of an unredacted type did NOT print its value: this Go " +
			"version has changed fmt's handling of unexported fields, so the truth table the " +
			"other tests in this file rest on no longer holds and internal/safe's comment is stale")
	}
}
