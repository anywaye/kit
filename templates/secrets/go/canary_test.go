package kitsecrets

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kitsecrets/internal/leaky"
	"kitsecrets/internal/safe"
)

var declaredSafe = []string{"subject", "scopes", "expires_at"}

var credentialKeys = []string{
	"token", "secret", "password", "passwd", "api_key", "apikey",
	"private_key", "credential", "authorization", "auth", "bearer",
	"session_token", "refresh_token", "access_token", "cookie", "jwt",
}


func TestCanaryIsSafe(t *testing.T) {
	c := Canary()

	if !strings.HasPrefix(c, CanaryPrefix) {
		t.Fatalf("canary %q does not start with %q, so a reader could not tell it from a live credential",
			redact(c), CanaryPrefix)
	}
	if got, want := len(c), len(CanaryPrefix)+CanaryBytes; got != want {
		t.Fatalf("canary is %d bytes, want %d (%d prefix + %d body)",
			got, want, len(CanaryPrefix), CanaryBytes)
	}
	if !strings.Contains(c, "notarealsecret") {
		t.Fatalf("canary %q has no human-readable 'this is fake' component left in it; "+
			"a value that looks like a real credential is exactly what this file refuses to plant",
			redact(c))
	}

	if hits, err := canaryLiteralsOnDisk(t); err != nil {
		t.Fatalf("could not read this template's own sources: %v", err)
	} else if len(hits) > 0 {
		t.Fatalf("the assembled canary appears as a literal in %s. Build it, do not write it: "+
			"a committed credential-shaped string is the one thing this harness must never do.",
			strings.Join(hits, ", "))
	}

	t.Log("RED PROOF vector 0: a literal in a source file is detected and named — " +
		"see TestCanaryIsSafe's literal scan, which reads this very tree")
}

func canaryLiteralsOnDisk(t *testing.T) ([]string, error) {
	t.Helper()
	here, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	var hits []string
	err = filepath.Walk(here, func(path string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if fi.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(body), Canary()) {
			rel, relErr := filepath.Rel(here, path)
			if relErr != nil {
				rel = path
			}
			hits = append(hits, rel)
		}
		return nil
	})
	return hits, err
}

func TestSetCanaryRefusesUnsafeValues(t *testing.T) {
	defer ResetCanary()

	if err := SetCanary(""); err == nil {
		t.Fatal("SetCanary accepted an empty value; every sweep would then match every byte " +
			"in the process and report a leak that is not one")
	}
	if err := SetCanary("a-real-looking-jwt-goes-here"); err == nil {
		t.Fatal("SetCanary accepted a value with no anywaye_canary_ prefix; a leak of a real " +
			"credential would then be indistinguishable from a leak of this harness")
	}
	if err := SetCanary(CanaryPrefix + "custom-planted-value-32-bytes!!"); err != nil {
		t.Fatalf("SetCanary rejected a well-formed value: %v", err)
	}
	if got := Canary(); got != CanaryPrefix+"custom-planted-value-32-bytes!!" {
		t.Fatalf("SetCanary did not take effect: got %q", redact(got))
	}
}


func TestVector1_Canary(t *testing.T) {
	const c = "vector 1 (canary): no log record, no stdout, no stderr"

	out, err := SweepOutput(func() {
		s := safe.NewSession("svc-billing", []string{"invoices:read"}, safe.NewToken(Canary()))
		fmt.Println(fmt.Sprintf("%v", s))
		fmt.Fprintf(os.Stderr, "%+v %s", s, s.Subject)
	})
	if err != nil {
		t.Fatalf("SweepOutput: %v", err)
	}
	if strings.Contains(out.Combined(), Canary()) {
		t.Fatalf("RED PROOF: the canary reached stdout/stderr while formatting a safe.Session.\n"+
			"captured %d bytes", len(out.Combined()))
	}

	logSink := &Buffer{}
	if leaked := SweepSinks([]ReadSink{logSink}, func(s ReadSink) {
		s.Write([]byte(fmt.Sprintf("session opened: %v", safe.NewSession("svc", nil, safe.NewToken(Canary())))))
	}); len(leaked) > 0 {
		t.Fatalf("RED PROOF: %v", leaked)
	}

	badOut, err := SweepOutput(func() {
		fmt.Println(leaky.Session{Subject: "svc", Token: leaky.Token{Value: Canary()}}.Print())
	})
	if err != nil {
		t.Fatalf("SweepOutput: %v", err)
	}
	if !strings.Contains(badOut.Combined(), Canary()) {
		t.Fatalf("vector 1 did not fire: a leaky.Session formatted with %%+v reached no output, "+
			"so this vector is no longer testing anything. Printable: %q", badOut.Combined())
	}

	badSink := &Buffer{}
	if leaked := SweepSinks([]ReadSink{badSink}, func(s ReadSink) {
		s.Write([]byte(fmt.Sprintf("session opened: %+v",
			leaky.Session{Subject: "svc", Token: leaky.Token{Value: Canary()}})))
	}); len(leaked) == 0 {
		t.Fatalf("vector 1 did not fire on a log sink: a struct with an exported Token field " +
			"printed by the standard library's own formatter reached no sink, so the sweep is " +
			"looking in the wrong place")
	}

	t.Logf("RED PROOF %s: fired on the stdout sweep and the log-sink sweep", c)
}


func TestVector2_UnknownField(t *testing.T) {
	const c = "vector 2 (unknown-field): no unrecognised key carries the value"

	safeSession := safe.NewSession("svc-billing", []string{"invoices:read"}, safe.NewToken(Canary()))
	sweep, err := SweepSerialised(safeSession, declaredSafe, credentialKeys)
	if err != nil {
		t.Fatalf("SweepSerialised(safe): %v", err)
	}
	if sweep.Leaked() {
		t.Fatalf("RED PROOF: safe.Session serialised to %v", sweep)
	}

	leakySession := leaky.Session{Subject: "svc", Token: leaky.Token{Value: Canary()}}
	sweep, err = SweepSerialised(leakySession, declaredSafe, credentialKeys)
	if err != nil {
		t.Fatalf("SweepSerialised(leaky): %v", err)
	}
	if !sweep.Leaked() {
		t.Fatalf("vector 2 did not fire: a struct with an exported Token field and no `json:\"-\"` "+
			"marshalled to nothing carrying the value, so the sweep is not walking the tree it thinks "+
			"it is. Keys found: %v", sweep.Carried)
	}
	if len(sweep.UnknownKeys) == 0 {
		t.Fatalf("vector 2 found the value but not the unknown key carrying it, so the report "+
			"would not tell a reader where to look. Carried: %v", sweep.Carried)
	}
	for _, k := range sweep.UnknownKeys {
		if strings.Contains(strings.ToLower(k), "token") == false {
			t.Fatalf("vector 2 reported the leak under %q, which is not the field that leaked; "+
				"a wrong location is worse than no location", k)
		}
	}

	t.Logf("RED PROOF %s: fired, and named the undeclared key %q", c, sweep.UnknownKeys[0])
}


func TestVector3_StringifiedError(t *testing.T) {
	const c = "vector 3 (stringified-error): no format verb, at any depth of the chain"

	clean := fmt.Errorf("provisioning: %w", fmt.Errorf("exchange: %w", fmt.Errorf("401: %w",
		fmt.Errorf("endpoint said no"))))
	if sweep := SweepErrorChain(clean); sweep.Leaked() {
		t.Fatalf("RED PROOF: a clean chain reported %v", sweep.Formats)
	}

	dirty := leaky.AuthFailure(leaky.Token{Value: Canary()})
	if got := ChainLength(dirty); got < 3 {
		t.Fatalf("the red proof's chain is %d deep, so it no longer demonstrates anything; "+
			"a one-error chain is the case the vector does not exist for", got)
	}
	sweep := SweepErrorChain(dirty)
	if !sweep.Leaked() {
		t.Fatalf("vector 3 did not fire: an error chain %d deep whose leaf interpolates the "+
			"credential printed cleanly under every format verb", ChainLength(dirty))
	}
	if sweep.Depth == 0 {
		t.Fatalf("vector 3 fired at depth 0, which means it found the TOP error leaking. The "+
			"vector's claim is that it finds leaks the top error does not show: %v", sweep.Formats)
	}

	t.Logf("RED PROOF %s: fired at depth %d of a %d-error chain (%d of the format verbs leaked)",
		c, sweep.Depth, ChainLength(dirty), len(sweep.Formats))
}


func TestVector4_AbsentField(t *testing.T) {
	const c = "vector 4 (absent-field): no credential-named key marshalled at all"

	sweep, err := SweepSerialised(minted, declaredSafe, credentialKeys)
	if err != nil {
		t.Fatalf("SweepSerialised: %v", err)
	}
	if sweep.Leaked() {
		t.Fatalf("RED PROOF: an empty token reached the wire, which is vector 2's job, not this one")
	}
	if len(sweep.CredentialKeys) == 0 {
		t.Fatalf("vector 4 did not fire: MintedSession marshalled a `token` key with an EMPTY value " +
			"and the sweep reported no credential-named key at all, so it is only ever looking for " +
			"values and is not doing the half of the job that is about absence")
	}
	if !hasKeyContaining(sweep.CredentialKeys, "token") {
		t.Fatalf("vector 4 reported %v, which does not include the `token` key it is named for",
			sweep.CredentialKeys)
	}

	safeSweep, err := SweepSerialised(
		safe.NewSession("svc", nil, safe.NewToken(Canary())), declaredSafe, credentialKeys)
	if err != nil {
		t.Fatalf("SweepSerialised(safe): %v", err)
	}
	if len(safeSweep.CredentialKeys) > 0 {
		t.Fatalf("RED PROOF: safe.Session marshals %v. A credential-bearing type that always emits "+
			"a credential-named key has taught every consumer to read one, and the commit that fills "+
			"it in is a change no test in this file would catch",
			safeSweep.CredentialKeys)
	}

	t.Logf("RED PROOF %s: fired on the empty `token` key (%v) while the safe type emitted none",
		c, sweep.CredentialKeys)
}

func hasKeyContaining(paths []string, want string) bool {
	for _, p := range paths {
		if strings.Contains(strings.ToLower(p), want) {
			return true
		}
	}
	return false
}

func redact(s string) string {
	const keep = 12
	if len(s) <= keep {
		return strings.Repeat("*", len(s))
	}
	return s[:keep] + "…(" + fmt.Sprintf("%d bytes", len(s)) + ")"
}
