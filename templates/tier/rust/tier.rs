// The tier declaration for Rust. Copy this file into your crate.
//
// WHY RUST IS THE MODEL, WITH ONE CORRECTION
//
// `#[ignore = "..."]` is a *documented, stable field of the attribute*, and its
// message is carried all the way to the test output. A tier, a reason, and a
// full inventory therefore all come from the standard library, with no parser
// and no kit-written convention to drift from the compiler.
//
// The correction is about the COLLECTOR, and it was measured rather than
// assumed, because the obvious recipe does not work on a stable toolchain:
//
//   cargo test -- --list --format json
//     -> error: The "json" format is only accepted on the nightly compiler
//        with -Z unstable-options
//
// Verified against rustc 1.95.0 (stable). So on stable there is no JSON
// inventory, and the JSON schema this table is usually quoted for is not
// available to the fleet today. The two stable commands below are what
// actually work, and between them they carry everything the JSON would have:
//
//   cargo test -- --list                  # INVENTORY: every test, ignored ones
//                                       #   INCLUDED. 3 tests listed above, all
//                                       #   of them, whether ignored or not.
//   cargo test -- --list --ignored        # the IGNORED subset. 1 test listed.
//   cargo test                            # a RUN prints the reason:
//                                       #   test tests::tier_db_needs_postgres
//                                       #     ... ignored, anywaye:tier=db reason=…
//
// `--list --include-ignored` is a trap and is called out here so nobody builds
// on it: it lists all 3 tests, exactly as `--list` does, so it reads like a
// filter and filters nothing. `--ignored` is the flag that actually filters.
//
// WHAT THE SET DIFF PROVES
//
//   inventory  = cargo test -- --list            (3 tests, ignored included)
//   gated out  = cargo test -- --list --ignored  (1 test)
//   ran        = the run's own list              (2 tests, the other 1 ignored)
//
// An absent test is invisible to JUnit and visible here, because the inventory
// is produced by the same compiler that produced the binary. That asymmetry is
// the whole reason this declaration is the one to copy.
use std::env;

/// The tier this file's tests belong to. The value that appears in the `tier`
/// field of a normalised result line, and the suffix of the gate variable:
/// REQUIRED_DB=1.
pub const TIER: &str = "db";

/// The pool handle, standing in for whatever your crate opens. A real service
/// substitutes its own; the tier contract does not change.
fn dsn() -> Option<String> {
    env::var("TEST_DATABASE_URL").ok().filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A database test. The `ignore` message IS the declaration: tier, then
    /// `reason=`, then why. It is read by the collector, printed by a run, and
    /// visible in review — three consumers, one string.
    ///
    /// Not ignored, because in a real crate the decision is: a test that needs
    /// Postgres carries the attribute so the default `cargo test` skips it, and
    /// the CI tier job runs it with `--ignored` and REQUIRED_DB=1. The variant
    /// below shows the attribute in use; this one is the shape a plain test
    /// takes when the crate has no build-level gating.
    #[test]
    fn tier_db_dsn_is_declared_not_inferred() {
        // The declaration is a no-op at runtime. It compiles, it imports
        // nothing, and no test depends on it. It exists to be read.
        assert_eq!(super::TIER, "db");
    }

    /// The attribute form, and the reason string is not decoration: it is the
    /// `reason` field of a normalised `skipped` line, and the thing the skip
    /// allowlist has to name.
    #[test]
    #[ignore = "anywaye:tier=db reason=needs a live postgres; CI runs this with --ignored and REQUIRED_DB=1"]
    fn tier_db_pool_round_trips() {
        let dsn = dsn().unwrap_or_else(|| {
            assert_eq!(
                env::var("REQUIRED_DB").ok().as_deref(),
                Some("1"),
                "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. \
                 Start the database, or unset REQUIRED_DB to skip this tier on purpose."
            );
            panic!("REQUIRED_DB=1 but there is no DSN to use");
        });
        assert!(dsn.starts_with("postgres"), "dsn: {dsn}");

        // The part only an assertion inside the test can prove. Everything
        // outside this function can prove "the db tier ran"; nothing outside it
        // can prove "the db tier reached postgres".
    }
}
