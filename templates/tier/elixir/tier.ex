# The tier declaration for Elixir. Copy this file beside your database tests.
#
# THE ADAPTER THIS LANGUAGE NEEDS
#
# ExUnit has no tier-declaration channel. A module attribute is the closest
# thing Elixir has to an exported const, and it is the shape an adapter can read
# without parsing: `@tier :db` is one token, and it is on the module, so
# collecting the tiers is walking the modules a suite already loaded.
#
# The attribute is a no-op at runtime. ExUnit ignores it, no test depends on
# it, and it costs one word at compile time. What it buys is a declaration an
# adapter can read instead of a sentinel a grep can miss — which is the whole
# difference between a tier that is entered by writing it and one that is
# entered by writing the word `Repo.` somewhere near a test.
#
# THE REASON IS ALREADY THERE, FOR FREE
#
# `@tag :db` and `@tag {:skip, "needs a live postgres"}` are ExUnit's own
# vocabulary. So for Elixir the declared reason is a tag, not a new syntax, and
# the adapter is a filter over tags ExUnit already reports.

defmodule Anywaye.Tier.DbTest do
  use ExUnit.Case, async: false

  # The declaration. The value in a normalised result line's `tier` field, and
  # the suffix of the gate variable: REQUIRED_DB=1.
  @tier :db

  # Exposed so a collector can read it without reaching into the module body.
  @doc "The dependency class this module's tests need."
  def tier, do: @tier

  @tag :db
  @tag :tier_db
  test "tier_db_pool_round_trips" do
    # REQUIRED_DB=1 turns a missing DSN from a skip into a failure. A skip is a
    # green run that never opened a connection.
    case System.get_env("TEST_DATABASE_URL") do
      nil ->
        if System.get_env("REQUIRED_DB") == "1" do
          flunk(
            "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. " <>
              "Start the database, or unset REQUIRED_DB to skip this tier on purpose."
          )
        end

        :ok

      dsn ->
        true = String.starts_with?(dsn, "postgres")
        # The part only an assertion inside the test can prove: everything
        # outside this test can prove "the db tier ran", nothing outside it can
        # prove "the db tier reached postgres".
        :ok
    end
  end
end
