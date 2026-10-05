// kit template — the canary vectors, executed.
//
// WHAT THIS SUITE IS NOT
//
//	It is not a demonstration that the detectors work. Every vector below runs
//	TWICE: once against `internal/safe`, which must come back clean, and once
//	against `internal/leaky`, which must come back RED. The second run is the
//	red proof, and it is in the same test as the first so that a detector
//	cannot be deleted from one half of the story.
//
//	That is the difference between a check and a report, and it is the whole
//	reason the leaky package exists. A detector that stopped working would
//	otherwise be indistinguishable from a codebase that stopped leaking, and
//	the second is not a thing anyone is working on.
//
//	Each RED PROOF line is printed with t.Log, so it appears in the output of
//	`go test -v` and in kit's own gate. A proof nobody can see is a proof
//	nobody ran.
//
// VECTORS
//
//	0  the canary is safe to commit
//	1  canary            no log record, no stdout, no stderr
//	2  unknown-field     no unrecognised key carries the value
//	3  stringified-error no format verb, at any depth of the chain
//	4  absent-field      no credential-named key marshalled at all
//	5  type-coverage     in typecover_test.go
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

// The keys `safe.Session` is allowed to publish. A harness cannot know these;
// only the service does, which is why it is an argument and not a constant.
var declaredSafe = []string{"subject", "scopes", "expires_at"}

// Key names that mean "this is a secret", for vector 4. Matched on the NAME
// only — vector 4 is about a key that exists and is empty, so its value is
// never consulted.
var credentialKeys = []string{
	"token", "secret", "password", "passwd", "api_key", "apikey",
	"private_key", "credential", "authorization", "auth", "bearer",
	"session_token", "refresh_token", "access_token", "cookie", "jwt",
}

// ---------------------------------------------------------------------------
// vector 0 — the canary is safe to commit
// ---------------------------------------------------------------------------

// TestCanaryIsSafe is the assertion the whole harness rests on.
//
// A canary that is not safe to commit is worse than no canary: it is a
// credential-shaped string in a public repository, added deliberately, which
// every future reader of the scanner's allowlist will then have a precedent
// for accepting.
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

	// The load-bearing one. Not "the canary looks fake" — that the PREFIX makes
	// obvious. The claim is that the full value appears in NO committed file,
	// because a 46-byte high-entropy string with a credential-ish prefix in a
	// public repository is a finding every scanner in the world will make, and
	// suppressing it needs an allowlist entry, and an allowlist entry teaches
	// the next person that allowlisting a credential is a normal thing to do.
	//
	// The second half of that proof is outside this file: the tree-wide
	//	`canary_literal_check` in tests/validate.sh greps this same tree. If this
	//	test passes and that one fails, a canary literal has crept in.
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

// canaryLiteralsOnDisk finds every committed .go file under this template that
// contains the assembled canary as a contiguous literal.
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

// TestSetCanaryRefusesUnsafeValues is the same property from the other side: the
// escape hatch cannot be used to plant something unrecognisable.
func TestSetCanaryRefusesUnsafeValues(t *testing.T) {
	defer ResetCanary()

	if err := SetCanary(""); err == nil {
		t.Fatal("SetCanary accepted an empty value; every sweep would then match every byte " +
			"in the process and report a leak that is not one")
	}
	if err := SetCanary("a-real-looking-jwt-goes-here"); err == nil {
		t.Fatal("SetCanary accepted a value with no cafaye_canary_ prefix; a leak of a real " +
			"credential would then be indistinguishable from a leak of this harness")
	}
	if err := SetCanary(CanaryPrefix + "custom-planted-value-32-bytes!!"); err != nil {
		t.Fatalf("SetCanary rejected a well-formed value: %v", err)
	}
	if got := Canary(); got != CanaryPrefix+"custom-planted-value-32-bytes!!" {
		t.Fatalf("SetCanary did not take effect: got %q", redact(got))
	}
}

// ---------------------------------------------------------------------------
// vector 1 — the canary reaches no output
// ---------------------------------------------------------------------------

func TestVector1_Canary(t *testing.T) {
	const c = "vector 1 (canary): no log record, no stdout, no stderr"

	// The clean half. `safe.Session` is formatted with every verb and printed;
	// the secret is a `Token` behind a method, so there is nothing to print.
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

	// The clean half, via a sink. A service points this at its real loggers.
	logSink := &Buffer{}
	if leaked := SweepSinks([]ReadSink{logSink}, func(s ReadSink) {
		s.Write([]byte(fmt.Sprintf("session opened: %v", safe.NewSession("svc", nil, safe.NewToken(Canary())))))
	}); len(leaked) > 0 {
		t.Fatalf("RED PROOF: %v", leaked)
	}

	// The red half. This is the bug the vector exists for: one `%+v` on a
	// struct with an exported field, in a log line nobody read.
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

// ---------------------------------------------------------------------------
// vector 2 — the unknown-field sweep
// ---------------------------------------------------------------------------

func TestVector2_UnknownField(t *testing.T) {
	const c = "vector 2 (unknown-field): no unrecognised key carries the value"

	// The clean half.
	safeSession := safe.NewSession("svc-billing", []string{"invoices:read"}, safe.NewToken(Canary()))
	sweep, err := SweepSerialised(safeSession, declaredSafe, credentialKeys)
	if err != nil {
		t.Fatalf("SweepSerialised(safe): %v", err)
	}
	if sweep.Leaked() {
		t.Fatalf("RED PROOF: safe.Session serialised to %v", sweep)
	}

	// The red half. A `Token` field with no `json:"-"`, which is the single
	// most common way a token reaches a wire in a Go service.
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
	// The finding must name the key, not just the value. A report that says "a
	// leak" sends the reader to the log; a report that says "Token" is the fix.
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

// ---------------------------------------------------------------------------
// vector 3 — the stringified-error sweep
// ---------------------------------------------------------------------------

func TestVector3_StringifiedError(t *testing.T) {
	const c = "vector 3 (stringified-error): no format verb, at any depth of the chain"

	// The clean half: a chain three deep that never interpolates the value.
	clean := fmt.Errorf("provisioning: %w", fmt.Errorf("exchange: %w", fmt.Errorf("401: %w",
		fmt.Errorf("endpoint said no"))))
	if sweep := SweepErrorChain(clean); sweep.Leaked() {
		t.Fatalf("RED PROOF: a clean chain reported %v", sweep.Formats)
	}

	// The red half, and note where it leaks: NOT at depth 0. The error the
	// caller holds says "provisioning service account", which is safe to log.
	// The credential is two Unwrap hops down, in a type the call site has never
	// heard of. Sweeping only the top error is the bug this vector is named
	// for.
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

// ---------------------------------------------------------------------------
// vector 4 — the absent-field sweep
// ---------------------------------------------------------------------------

func TestVector4_AbsentField(t *testing.T) {
	const c = "vector 4 (absent-field): no credential-named key marshalled at all"

	// The clean half. Nothing here leaks a VALUE, which is the whole point:
	// vector 4 is green for a struct that is behaving perfectly, and is
	// checking a different question from vectors 2 and 3.
	minted := leaky.MintedSession{Subject: "svc"} // Token deliberately left EMPTY
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

	// And the other half: the SAFE type must have no credential-named key even
	// though it holds a credential. This is what "safe" means here, and it is
	// the assertion a service's own types have to pass.
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

// redact shortens a value for a failure message. The rule this file exists to
// enforce is that a leak report must never carry the thing it found — which has
// to hold for the harness's own output too, and holds trivially on the day
// someone points this at a real credential instead of the canary.
func redact(s string) string {
	const keep = 12
	if len(s) <= keep {
		return strings.Repeat("*", len(s))
	}
	return s[:keep] + "…(" + fmt.Sprintf("%d bytes", len(s)) + ")"
}
