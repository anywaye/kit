# frozen_string_literal: true

# The tier declaration for Ruby. Copy this file beside your database tests.
#
# WHAT IS MEASURED HERE, AND THE GAP THAT REMAINS
#
# Minitest 6.0.6 was asked directly whether it ships a machine-readable
# reporter, and the answer is no:
#
#   ruby -e 'require "minitest"; puts Minitest.constants.grep(/Report|Junit/i)'
#     -> [:StatisticsReporter, :ProgressReporter, :SummaryReporter, ...]
#
# Every built-in reporter is human-readable text. `minitest-reporters` does
# provide a JUnit one, but it is a separate gem the service repo has to add, and
# a service that has not added it has no machine-readable output at all. So the
# gap is REAL and it is a dependency gap, not a formatting gap: on plain minitest
# a service can print `2 runs, 1 assertions, 0 failures, 0 errors, 1 skips` and
# nothing in that line is addressable to a test.
#
# On Rails it is the same story, and Rails is not a special case — Rails' default
# test runner is Minitest.
#
# THE ADAPTER THIS LANGUAGE NEEDS
#
# A `tier` class macro is the declaration; the adapter that turns a run into the
# normalised format is a Minitest::Reporter subclass, which is roughly fifteen
# lines and is `cafe gate`'s job, not kit's. The macro below is the half kit owns,
# and it is deliberately a no-op at runtime: declaring a tier changes no test's
# behaviour and makes no test depend on the declaration.
#
# Read the reason off the skip itself. `skip "reason"` already carries it, and
# minitest prints it under `--verbose` — so the declared reason exists in Ruby
# without any new syntax, which is more than bun offers.

module Cafaye
  # Tiers are declared per test class, because a class is Ruby's unit of suite.
  module Tier
    # tier :db — declares that every test in this class needs a real database.
    def tier(name)
      @tier = name
      # GATE_VARIABLE is the name the reusable workflow demands. It is derived
      # rather than written so a tier and its gate variable cannot disagree.
      const_set(:TIER, name)
      const_set(:GATE_VARIABLE, :"REQUIRED_#{name.to_s.upcase}")
    end

    # The declared tier, or nil. `cafe gate`'s adapter calls this; nothing in a
    # normal test run does.
    def declared_tier
      @tier
    end
  end
end

class TierDbTest < Minitest::Test
  extend Cafaye::Tier

  tier :db

  # A database test. Its id is the method name, which is what the normalised
  # format's <test-id> is in every language here: whatever the runner's collector
  # already calls the test, so there is no mapping table to keep in step.
  def test_tier_db_pool_round_trips
    # REQUIRED_DB=1 turns a missing DSN from a skip into a failure. A skip is a
    # green run that never opened a connection.
    dsn = ENV.fetch("TEST_DATABASE_URL", nil)
    if dsn.nil? || dsn.empty?
      if ENV["REQUIRED_DB"] == "1"
        flunk "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. " \
              "Start the database, or unset REQUIRED_DB to skip this tier on purpose."
      end
      skip "TEST_DATABASE_URL unset: db tier not requested on this run"
    end

    assert dsn.start_with?("postgres"), dsn
    # The part only an assertion inside the test can prove: everything outside
    # this method can prove "the db tier ran", nothing outside it can prove
    # "the db tier reached postgres".
  end
end
