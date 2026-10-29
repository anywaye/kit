package leaky

import (
	"errors"
	"fmt"
)

// Token is a secret type by name, which is all vector 5's rule needs. It
// deliberately has a String method: a secret type is allowed one, because a
// secret type is not credential-bearing. The rule is about holders.
type Token struct {
	Value string
}

// Session leaks in two of the five vectors, and it is the most common real
// defect there is: a struct field someone added without a json tag.
type Session struct {
	Subject string `json:"subject"`
}

// Print returns the session the way a careless log line would.
func (s Session) Print() string { return fmt.Sprintf("%+v", s) }

// MintedSession always marshals a `token` key. Nothing here is set, and the key
// is in the output anyway.
type MintedSession struct {
	Subject string `json:"subject"`
	Token   string `json:"token"`
}

// PrintableSession is vector 5's subject: a credential-bearing type that
// declares a String method, which is a value with no control over how it is
// printed.
type PrintableSession struct {
	Subject string
	Token   Token
}

func (s PrintableSession) String() string {
	return fmt.Sprintf("session(subject=%s, token=%s)", s.Subject, s.Token.Value)
}

// AuthError is vector 3's subject. Two things are wrong with it and both matter:
// the message interpolates the credential, and it is wrapped, so the outer
// error is the one a caller has and the inner one is the one that prints the
// secret.
type AuthError struct {
	Op    string
	Token Token
	Cause error
}

func (e *AuthError) Error() string {
	return fmt.Sprintf("%s failed: rejected credential %s", e.Op, e.Token.Value)
}

func (e *AuthError) Unwrap() error { return e.Cause }

// AuthFailure builds the full chain an edge returns, so the test walks a real
// chain rather than a single error standing in for one.
func AuthFailure(token Token) error {
	cause := errors.New("401 from the token endpoint")
	authErr := &AuthError{Op: "exchange", Token: token, Cause: cause}
	return fmt.Errorf("provisioning service account: %w", authErr)
}
