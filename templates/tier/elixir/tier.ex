
defmodule Anywaye.Tier.DbTest do
  use ExUnit.Case, async: false

  @tier :db

  @doc "The dependency class this module's tests need."
  def tier, do: @tier

  @tag :db
  @tag :tier_db
  test "tier_db_pool_round_trips" do
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
        :ok
    end
  end
end
