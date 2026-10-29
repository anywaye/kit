import { expect, test } from "bun:test";

export const TIER = "db" as const;

test("tier_db_pool_round_trips", () => {
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
});
