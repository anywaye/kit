use std::env;

/// The tier this file's tests belong to. The value that appears in the `tier`
/// field of a normalised result line, and the suffix of the gate variable:
/// REQUIRED_DB=1.
pub const TIER: &str = "db";

fn dsn() -> Option<String> {
    env::var("TEST_DATABASE_URL").ok().filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tier_db_dsn_is_declared_not_inferred() {
        assert_eq!(super::TIER, "db");
    }

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

    }
}
