package kitsecrets

import (
	"encoding/json"
	"fmt"
	"strings"
)

// SerialisedSweep is what vectors 2 and 4 found.
type SerialisedSweep struct {
	UnknownKeys []string
	CredentialKeys []string
	Carried []string
}

// Leaked reports whether anything at all was found, in either vector's terms.
func (s SerialisedSweep) Leaked() bool {
	return len(s.UnknownKeys) > 0 || len(s.Carried) > 0
}

// SweepSerialised marshals v and looks for the canary in it.
//
// declaredSafe is the set of keys the caller has decided are allowed to exist.
// It is a parameter rather than a constant because only the service knows which
// of its own keys are meant to be public, and a harness that guessed would be
// asserting against the wrong contract.
//
// credentialKeys is the set of key NAMES that mean "this is a secret". Only
// their names are consulted, never their values: vector 4 is about a key that
// exists and is empty.
func SweepSerialised(v any, declaredSafe, credentialKeys []string) (SerialisedSweep, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return SerialisedSweep{}, fmt.Errorf("kitsecrets: could not marshal the value under test: %w", err)
	}
	var tree any
	if err := json.Unmarshal(raw, &tree); err != nil {
		return SerialisedSweep{}, fmt.Errorf("kitsecrets: marshalled output is not valid JSON: %w", err)
	}

	safe := make(map[string]bool, len(declaredSafe))
	for _, k := range declaredSafe {
		safe[strings.ToLower(k)] = true
	}
	credential := make(map[string]bool, len(credentialKeys))
	for _, k := range credentialKeys {
		credential[strings.ToLower(k)] = true
	}

	out := SerialisedSweep{}
	needle := Canary()
	walkJSON("", tree, func(path, key, value string) {
		if key != "" && credential[strings.ToLower(key)] {
			out.CredentialKeys = append(out.CredentialKeys, path)
		}
		if value != "" && strings.Contains(value, needle) {
			out.Carried = append(out.Carried, path)
			if !safe[strings.ToLower(key)] {
				out.UnknownKeys = append(out.UnknownKeys, path)
			}
		}
	})
	return out, nil
}

func walkJSON(path string, node any, visit func(path, key, value string)) {
	const maxDepth = 32
	walk(path, node, "", 0, visit)
}

func walk(path string, node any, key string, depth int, visit func(string, string, string)) {
	if depth > maxDepthOfWalk {
		return
	}
	switch v := node.(type) {
	case map[string]any:
		keys := sortedKeys(v)
		for _, k := range keys {
			child := k
			if path != "" {
				child = path + "." + k
			}
			walk(child, v[k], k, depth+1, visit)
		}
		if len(keys) == 0 && key != "" {
			visit(path, key, "")
		}
	case []any:
		for i, item := range v {
			walk(fmt.Sprintf("%s[%d]", path, i), item, key, depth+1, visit)
		}
		if len(v) == 0 && key != "" {
			visit(path, key, "")
		}
	case string:
		visit(path, key, v)
	case float64, bool, nil:
	}
}

const maxDepthOfWalk = 32

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

// ErrorSweep is what vector 3 found: the formattings that printed the canary.
type ErrorSweep struct {
	Formats []string
	Depth int
}

// SweepErrorChain formats err every way a caller might, at every level of the
// chain, and reports which of them printed the canary.
//
// The chain, not just the top error, because the top error is almost never the
// one that leaks. The idiomatic Go error is a wrapper that adds context and
// delegates, so the credential is usually in a leaf that the caller never holds
// directly — which is precisely why `log.Error("exchange failed", err)` at the
// call site is safe and `fmt.Sprintf("%+v", err)` three frames down is not.
//
// A chain built with errors.Join is walked too, via the `Unwrap() []error`
// interface, because a joined error is a chain whose nodes each have branches
// and stopping at the first one is the same bug as stopping at the top.
func SweepErrorChain(err error) ErrorSweep {
	out := ErrorSweep{}
	if err == nil {
		return out
	}
	needle := Canary()

	var walk func(e error, depth int)
	walk = func(e error, depth int) {
		if e == nil {
			return
		}
		for _, tc := range []struct {
			verb string
			rend func(error) string
		}{
			{"%v", func(e error) string { return fmt.Sprintf("%v", e) }},
			{"%+v", func(e error) string { return fmt.Sprintf("%+v", e) }},
			{"%s", func(e error) string { return fmt.Sprintf("%s", e) }},
			{"%q", func(e error) string { return fmt.Sprintf("%q", e) }},
			{"Sprint", func(e error) string { return fmt.Sprint(e) }},
			{"Sprintf", func(e error) string { return fmt.Sprintf("%s", e) }},
			{"Error()", func(e error) string { return e.Error() }},
		} {
			if strings.Contains(tc.rend(e), needle) {
				out.Formats = append(out.Formats, fmt.Sprintf("%s at depth %d", tc.verb, depth))
				if depth > out.Depth {
					out.Depth = depth
				}
			}
		}

		switch u := e.(type) {
		case interface{ Unwrap() error }:
			walk(u.Unwrap(), depth+1)
		case interface{ Unwrap() []error }:
			joined := append([]error(nil), u.Unwrap()...)
			for i := 1; i < len(joined); i++ {
				for j := i; j > 0 && joined[j].Error() < joined[j-1].Error(); j-- {
					joined[j], joined[j-1] = joined[j-1], joined[j]
				}
			}
			for _, sub := range joined {
				walk(sub, depth+1)
			}
		}
	}
	walk(err, 0)
	return out
}

// Leaked reports whether any formatting printed the canary.
func (e ErrorSweep) Leaked() bool { return len(e.Formats) > 0 }

// ChainLength is how many errors are in the chain, for a report that wants to
// say "3 of 5 leaked" rather than only naming the ones that did.
func ChainLength(err error) int {
	n := 0
	var walk func(error)
	walk = func(e error) {
		if e == nil {
			return
		}
		n++
		switch u := e.(type) {
		case interface{ Unwrap() error }:
			walk(u.Unwrap())
		case interface{ Unwrap() []error }:
			for _, sub := range u.Unwrap() {
				walk(sub)
			}
		}
	}
	walk(err)
	return n
}
