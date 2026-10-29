package kitsecrets

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"sync"
)

// CanaryPrefix is the first thing every canary value starts with.
//
// A prefix rather than a random value is what makes the canary safe to commit,
// to log by accident, and to paste into a bug report: nobody reading it can
// mistake it for a live credential, and a scanner that is pattern-matching on
// known provider formats will not recognise it as one.
const CanaryPrefix = "anywaye_canary_"

// CanaryBytes is how many bytes follow the prefix. 32 is the size of a
// hex-encoded 128-bit value, which is the shape most real credentials have and
// therefore the shape that exercises truncation, redaction and length-based
// heuristics in a logger.
const CanaryBytes = 32

const canaryBody = "notarealsecret"

var (
	canaryMu sync.RWMutex
	canary   = CanaryPrefix + strings.Repeat(canaryBody, 3)[:CanaryBytes]
)

// Canary returns the value currently planted.
func Canary() string {
	canaryMu.RLock()
	defer canaryMu.RUnlock()
	return canary
}

// SetCanary plants a different value for this run.
//
// It rejects a value that does not carry the prefix, and it rejects an empty
// one. A harness that swept for "" would report every byte in the process; a
// harness that swept for a value nobody planted would report nothing and pass.
// Both are worse than refusing to run, and both are one careless call site away.
func SetCanary(v string) error {
	if v == "" {
		return errors.New("kitsecrets: refusing to plant an empty canary; every sweep would match every byte")
	}
	if !strings.HasPrefix(v, CanaryPrefix) {
		return errors.New("kitsecrets: a planted canary must start with " + CanaryPrefix + ", or a leaked real credential would not be distinguishable from a leak of this harness")
	}
	canaryMu.Lock()
	defer canaryMu.Unlock()
	canary = v
	return nil
}

// ResetCanary restores the built-in value. Test-only, and named as such, so a
// production call site reads as the mistake it is.
func ResetCanary() { _ = SetCanary(CanaryPrefix + strings.Repeat(canaryBody, 3)[:CanaryBytes]) }

// Sink is anything a credential can be written to: a logger's writer, a buffer,
// a file. A service passes its own here; the harness cannot enumerate a
// process's loggers, and pretending otherwise is how a harness ends up
// asserting over three sinks out of nine.
type Sink interface {
	Write(p []byte) (int, error)
}

// Buffer is a Sink that keeps what it was given, which is what makes a sweep
// assertable. A service uses its real logger; this is what the tests point at the
// thing they are testing.
//
// It deliberately does NOT have a String method. A type that can be printed is a
// type that will be printed, and the argument this file makes about credentials
// is not one a fixture should quietly violate.
type Buffer struct{ b strings.Builder }

func (b *Buffer) Write(p []byte) (int, error) { return b.b.Write(p) }

// Contents returns everything written to the buffer.
func (b *Buffer) Contents() string { return b.b.String() }

// ProcessOutput is what a sweep of stdout and stderr found.
type ProcessOutput struct {
	Stdout string
	Stderr string
}

// Combined is the two streams as one string, for the assertion most callers
// actually want: "did the value appear anywhere a human or a log shipper can
// see".
func (o ProcessOutput) Combined() string { return o.Stdout + o.Stderr }

// SweepOutput is vector 1's detector: it runs fn with os.Stdout and os.Stderr
// replaced by pipes, and reports what was written to them.
//
// LIMITATION, and it is a real one: this replaces the two `os.File` variables,
// not the underlying file descriptors. A logger holding its own dup of fd 1, or
// anything writing through a C library, bypasses it. A service that has one of
// those should point vector 1 at a Sink as well — and should say so, because a
// sweep that silently covered less than it appears to is worse than no sweep.
func SweepOutput(fn func()) (ProcessOutput, error) {
	origOut, origErr := os.Stdout, os.Stderr
	outR, outW, err := os.Pipe()
	if err != nil {
		return ProcessOutput{}, err
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		_ = outR.Close()
		_ = outW.Close()
		return ProcessOutput{}, err
	}
	os.Stdout, os.Stderr = outW, errW

	outC := make(chan string, 1)
	errC := make(chan string, 1)
	go func() { outC <- readAll(outR) }()
	go func() { errC <- readAll(errR) }()

	func() {
		defer func() {
			_ = outW.Close()
			_ = errW.Close()
		}()
		fn()
	}()

	os.Stdout, os.Stderr = origOut, origErr
	return ProcessOutput{Stdout: <-outC, Stderr: <-errC}, nil
}

func readAll(f *os.File) string {
	var sb strings.Builder
	buf := make([]byte, 32*1024)
	for {
		n, err := f.Read(buf)
		sb.Write(buf[:n])
		if err != nil {
			break
		}
	}
	_ = f.Close()
	return sb.String()
}

// ReadSink is a Sink whose contents can be read back, which is what a sweep
// actually needs: a leak is a substring of what was written, so a sink you can
// only write to is a sink you cannot assert on.
type ReadSink interface {
	Sink
	Contents() string
}

// SweepSinks is vector 1's other half: everything written to the sinks a
// service names.
//
// fn is called once per sink with that sink installed as the process's
// log destination by the caller's own wiring, so a service that has five
// loggers sweeps five and not one. This function never returns the canary, and
// never returns any of the surrounding bytes: a report of a leak must not
// itself contain the thing it found. That holds for the fake canary, and it is
// the property that keeps holding on the day someone points this at a real
// credential.
func SweepSinks(sinks []ReadSink, fn func(ReadSink)) (leaked []string) {
	needle := Canary()
	for i, s := range sinks {
		fn(s)
		if strings.Contains(s.Contents(), needle) {
			leaked = append(leaked, "sink "+strconv.Itoa(i)+" received the canary")
		}
	}
	return leaked
}
