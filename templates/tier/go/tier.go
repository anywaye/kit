// Package dbtest — tier declaration. Copy this file into the test package whose
// tests need a real database, then copy tier_db_test.go beside it.
//
// # WHY A DECLARATION AND NOT A CONVENTION WE INFER
//
// A tier has to be *declared in the test source* and read by the runner's own
// collector. The obvious alternative — grep the tree for a sentinel like
// `dbtest.Pool` — fails open, and open in the direction that costs you: a new
// test that reaches Postgres through a helper two files away, or through a
// fixture, does not match the sentinel, so its package never enters the
// required list, and the run is never required to contain it. The test is
// written, it is not gated, and nobody finds out.
//
// A declaration cannot fail open that way, because the author is the one who
// writes it. That is the whole reason this file exists.
//
// # THE CONST IS A NO-OP AT RUNTIME
//
// It costs nothing to compile in, nothing to run, and no test imports it. It is
// read by `go list` and by `cafe gate`, never by the suite.
//
// THE COLLECTOR THAT ALREADY READS THIS
//
//	go test -list '.*' ./...        # the full inventory, cacheable, and it
//	                                # includes tests behind a build tag only
//	                                # when the tag is passed
//	go test -tags tier_db -list '.*' ./...
//
// `-list` is designed to pair with a run and is served from the build cache, so
// the inventory and the run cost one compile between them. Pair it with
// -count=1 on the run itself; see templates/tier/README.md.
package dbtest

// Tier is the dependency class this package's tests need. It is the value that
// appears in the `tier` field of a normalised result line, and the suffix of the
// gate variable: REQUIRED_DB=1.
const Tier = "db"
