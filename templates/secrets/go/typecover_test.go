package kitsecrets

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kitsecrets/internal/leaky"
	"kitsecrets/internal/safe"
)

func TestVector5_TypeCoverage(t *testing.T) {
	const c = "vector 5 (type-coverage): no credential-bearing type is printable or an error"

	findings, err := TypeCoverage([]string{filepath.Join("internal", "safe")})
	if err != nil {
		t.Fatalf("TypeCoverage(internal/safe): %v", err)
	}
	if len(findings) > 0 {
		var lines []string
		for _, f := range findings {
			lines = append(lines, f.String())
		}
		t.Fatalf("RED PROOF: the reference credential package is itself flagged, so the rule does "+
			"not describe the shape kit tells a service to write:\n  %s", strings.Join(lines, "\n  "))
	}

	findings, err = TypeCoverage([]string{filepath.Join("internal", "leaky")})
	if err != nil {
		t.Fatalf("TypeCoverage(internal/leaky): %v", err)
	}
	if len(findings) == 0 {
		t.Fatalf("vector 5 did not fire: %s declares String() while holding a Token and the "+
			"analyzer found nothing, so it is not reading the method declarations it claims to read",
			"PrintableSession")
	}

	var found *CoverageFinding
	for i := range findings {
		if findings[i].Type == "PrintableSession" && findings[i].Method == "String" {
			found = &findings[i]
		}
	}
	if found == nil {
		var lines []string
		for _, f := range findings {
			lines = append(lines, f.String())
		}
		t.Fatalf("vector 5 fired, but not on PrintableSession.String():\n  %s", strings.Join(lines, "\n  "))
	}
	if !strings.Contains(found.Pos, "leaky") || !strings.Contains(found.Pos, ":") {
		t.Fatalf("vector 5's finding has no usable position (%q); a report that cannot be "+
			"jumped to is a report nobody acts on", found.Pos)
	}

	if namesType(findings, "Token") {
		t.Fatalf("vector 5 flagged the secret type itself, not the holder. A Token with a " +
			"redacting String() is the shape a service SHOULD write.")
	}
	if namesType(findings, "Session") {
		t.Fatalf("vector 5 flagged leaky.Session, which is a holder with no String and no Error")
	}

	t.Logf("RED PROOF %s: fired on %q; a secret type with its own String() was correctly not flagged",
		c, found.String())
}

func namesType(findings []CoverageFinding, typeName string) bool {
	for _, f := range findings {
		if f.Type == typeName {
			return true
		}
	}
	return false
}

func TestTypeCoverageRefusesAnEmptyDirectory(t *testing.T) {
	empty := t.TempDir()
	if _, err := TypeCoverage([]string{empty}); err == nil {
		t.Fatalf("TypeCoverage over a directory with no .go files returned no error and no " +
			"findings. A coverage check over nothing is not a check, and a caller that cannot " +
			"tell that apart from a clean result will ship a credential type with a String() " +
			"method believing it was checked")
	} else if !strings.Contains(err.Error(), "no .go files") {
		t.Fatalf("TypeCoverage over an empty directory failed for the wrong reason: %v", err)
	}
}

func TestTypeCoverageUnwrapsContainers(t *testing.T) {
	_ = leaky.PrintableSession{Subject: "s", Token: leaky.Token{Value: "v"}}
	_ = safe.NewSession("s", nil, safe.NewToken("v"))

	for _, shape := range []string{"Token", "*Token", "[]Token", "map[string]Token"} {
		if !holdsSecretShape(t, shape) {
			t.Fatalf("the analyzer does not recognise %s as holding a credential, so a holder "+
				"whose secret is behind one of these shapes is invisible to vector 5", shape)
		}
	}
	if holdsSecretShape(t, "string") {
		t.Fatalf("the analyzer recognises a bare `string` field as holding a credential, which " +
			"would flag every struct in a service")
	}
}

func holdsSecretShape(t *testing.T, fieldType string) bool {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "shape.go")
	src := "package p\n\n" +
		"type Holder struct {\n\tField " + fieldType + "\n}\n\n" +
		"func (h Holder) String() string { return \"\" }\n"
	if err := os.WriteFile(path, []byte(src), 0o600); err != nil {
		t.Fatalf("could not write the fixture: %v", err)
	}
	findings, err := TypeCoverage([]string{dir})
	if err != nil {
		t.Fatalf("TypeCoverage(%s): %v", fieldType, err)
	}
	return len(findings) > 0
}
