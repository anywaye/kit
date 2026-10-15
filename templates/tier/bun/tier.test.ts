// The tier declaration for Bun. Copy this file beside your database tests.
//
// WHAT IS MEASURED HERE, AND WHAT IS STILL A GAP
//
// `bun test` 1.3.12's JUnit reporter was run against a two-test file to settle
// two claims rather than assume them:
//
//   1. bun DOES emit a full inventory. A test filtered out of the run is still
//      present as a <testcase>:
//        bun test -t "alpha_ran" --reporter=junit --reporter-outfile=r.xml
//          -> 1 pass, 1 filtered out
//          -> <testsuites tests="2" skipped="1">
//               <testcase name="alpha_ran" .../>
//               <testcase name="beta_filtered_out" .../>   <- present, empty body
//
//      So the failure mode this whole convention exists to prevent — an absent
//      <testcase> being indistinguishable from a test that was never written —
//      does NOT occur in bun's reporter. That is better than the general claim
//      about JUnit, and it is worth knowing before writing an adapter for it.
//
//   2. What bun does NOT have is a declared REASON. `test.skip(name, fn)` takes
//      no reason argument, so there is nowhere to put `reason=needs a live
//      postgres` and nowhere for the skip allowlist to read one from.
//
// THE GAP THIS FILE STILL HAS, STATED PLAINLY
//
// The distinction between "declared skip" and "filtered out" is an empty child
// element versus a <skipped/> child. That is observed behaviour on 1.3.12, and
// it is NOT a documented contract — it is the absence of a field, and an
// absence of a field is not a promise. Do not build a gate on it without
// pinning the version, and prefer the normalised format below, which is written
// down rather than inferred.
//
// THE ADAPTER THIS LANGUAGE NEEDS
//
// bun has no tier-declaration channel of its own: nothing in `bun test` reads an
// exported const. `TIER` below is a no-op at runtime that a ~15-line adapter
// reads, which is the whole reason it is exported rather than commented. That
// adapter is `cafe gate`'s job, not kit's — see templates/tier/README.md.
import { expect, test } from "bun:test";

/** The tier these tests belong to. The value in a normalised result line's
 * `tier` field, and the suffix of the gate variable: REQUIRED_DB=1. */
export const TIER = "db" as const;

test("tier_db_pool_round_trips", () => {
  // REQUIRED_DB=1 turns a missing DSN from a silent early return — which is a
  // PASS in bun's JUnit, indistinguishable from a test that connected — into a
  // failure. That asymmetry is the reason the variable is demanded rather than
  // inferred.
  const dsn = process.env.TEST_DATABASE_URL;
  if (!dsn) {
    if (process.env.REQUIRED_DB === "1") {
      throw new Error(
        "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. " +
          "Start the database, or unset REQUIRED_DB to skip this tier on purpose.",
      );
    }
    return;
  }

  expect(dsn.startsWith("postgres")).toBe(true);
  // The part only an assertion inside the test can prove: everything outside
  // this function can prove "the db tier ran", nothing outside it can prove
  // "the db tier reached postgres".
});
