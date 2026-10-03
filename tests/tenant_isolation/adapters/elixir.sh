#!/usr/bin/env bash
#
# adapters/elixir.sh — the ONE implemented adapter of the cross-tenant harness.
#
# This file is the whole of kit's knowledge of Elixir. The harness beside it
# knows about databases, containers and assertions; it does not know what an
# ExUnit test is, what `mix` is, or what courier's tables are called. Five
# functions make up the contract, and `adapters/README.md` states it in full.
#
# WHY courier IS THE ONE
#
#   Elixir/courier is the only fleet service that already has all three of the
#   things this harness needs, and it has them for the same reasons the packet
#   names. It runs its migrations as its own role (so the RLS substrate and the
#   FORCE control are real), it has 19 existing cross-tenant negative tests to
#   lean on, and its scoping is hand-written `where account_id == ^account_id`
#   in a context module — which is precisely the code a refactor can drop one
#   clause from while the suite stays green.
#
# WHAT IS COPIED, AND WHY IT IS NOT THE CHECKOUT
#
#   `lib priv config test mix.exs mix.lock .formatter.exs`, and `deps` SYMLINKED
#   rather than copied. Everything above is small (≈2MB); `deps` and `_build` are
#   not, and copying them would turn seven cases into seven full rebuilds. The
#   checkout itself is never written to — the mutation cases break the COPY's
#   source and restore it, and courier's own working tree is not this
#   repository's to break.
#
# WHY THE COPY IS BUILT IN `test`
#
#   `MIX_ENV=test`, because that is the only environment courier configures a
#   repository against, and because `test/test_helper.exs` puts the Ecto SQL
#   Sandbox in manual mode. The Sandbox is what makes "seed two accounts" cheap:
#   each test seeds its own A and its own B inside one rolled-back transaction,
#   so six cases in six runs share one database with no cross-case state and no
#   truncate that could reach another run's cluster.
#
# WHY `mix test` RUNS THE WHOLE PROBE FILE AND NOT ONE TEST
#
#   Because a breakage frequently turns more than one assertion red — dropping
#   `account_id` from the shared fetch helper makes fetch, update and delete all
#   fail, and that is the honest answer rather than a filtered one. The recipe
#   asserts on the NAMED test; the output shows the reader the rest.

# SC2209 is disabled for this whole file, and the directive has to sit BEFORE the
# first command to be file-wide — a shellcheck directive placed after `set`
# applies to the next command only, which is how a "file-wide" disable silently
# disables nothing. `TIMEOUT_BIN` is assigned in the harness by `command -v`, so
# `shellcheck` cannot see from here that it holds a path rather than a string built
# by a command substitution. The adapter inherits the harness's binary rather
# than re-resolving it, because two resolvers is one more place to be wrong.
# shellcheck disable=SC2209

set -uo pipefail

adapter_language_tool() { printf 'mix'; }

adapter_prepare() {
  local src="$KIT_TENANT_SERVICE" dst="$KIT_TENANT_WORK/service"
  [ -d "$src/deps" ] || {
    printf '  %s has no deps/ directory. The harness does not fetch them: a check that\n' "$src" >&2
    printf '  reached the network would answer differently on a laptop and on CI.\n' >&2
    return 1
  }
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -R "$src/lib" "$src/priv" "$src/config" "$src/test" "$dst/" || return 1
  cp "$src/mix.exs" "$src/mix.lock" "$dst/" || return 1
  [ -f "$src/.formatter.exs" ] && cp "$src/.formatter.exs" "$dst/"
  ln -s "$src/deps" "$dst/deps"

  # Compiling the deps ONCE is the difference between this harness taking a
  # minute and taking seven. Bounded, and fatal on failure: a harness that
  # compiles nothing has no query layer to run.
  ( cd "$dst" && MIX_ENV=test "$TIMEOUT_BIN" 900 mix compile ) >"$KIT_TENANT_WORK/compile.log" 2>&1 || {
    printf '  mix compile failed; tail of the log:\n' >&2
    tail -20 "$KIT_TENANT_WORK/compile.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

adapter_migrate() {
  local dst="$KIT_TENANT_WORK/service"
  # The SERVICE's own migrations, against the harness's own database. Not a
  # hand-written schema: a harness that seeds a table it invented is measuring
  # its own DDL rather than the service's query layer.
  (
    cd "$dst" &&
      MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
        "$TIMEOUT_BIN" 300 mix ecto.create &&
      MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
        "$TIMEOUT_BIN" 300 mix ecto.migrate
  ) >"$KIT_TENANT_WORK/migrate.log" 2>&1 || {
    printf '  the service migrations failed; tail of the log:\n' >&2
    tail -25 "$KIT_TENANT_WORK/migrate.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

# The probe is COPIED in, not written here. It is a separate file with a
# `.exs` extension because kit's rule is "parse what you hand out": an Elixir
# file with a misleading extension is how `rack_middleware.rb.snippet` shipped
# syntax that was not Ruby.
adapter_install_probe() {
  local probe="$KIT_TENANT_ADAPTER_DIR/elixir/cross_tenant_probe_test.exs"
  [ -r "$probe" ] || {
    printf '  the negative suite is missing at %s\n' "$probe" >&2
    return 1
  }
  cp "$probe" "$KIT_TENANT_WORK/service/test/courier/kit_tenant_isolation_probe_test.exs" || return 1
  # Prove the file is collected before anything asserts on it. A probe that was
  # never collected would report six tests as "0 failures" and every breakage
  # would look like it stayed green — the class of failure this repository has
  # already paid for twice.
  adapter_run '__collect_probe__'
}

adapter_run() {
  local needle="${1:-}" dst="$KIT_TENANT_WORK/service"
  if [ "$needle" = "__collect_probe__" ]; then
    if ! (
      cd "$dst" && MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
        "$TIMEOUT_BIN" 300 mix test test/courier/kit_tenant_isolation_probe_test.exs
    ) >"$KIT_TENANT_WORK/probe.log" 2>&1; then
      printf '  the negative suite does not run against the unmodified service:\n' >&2
      tail -40 "$KIT_TENANT_WORK/probe.log" | sed 's/^/  /' >&2
      return 1
    fi
    cat "$KIT_TENANT_WORK/probe.log"
    return 0
  fi

  # NO banner above the runner's own output. The recipe keeps the LITERAL failure
  # line as its receipt by grepping the first line naming the needle, and a banner
  # carrying the needle is matched first — so the receipt was the banner. A
  # receipt that describes itself is not a receipt.
  # (`printf '--- …'` is also a bug on every POSIX printf: a format starting with
  # `-` is parsed as options and it prints a usage message instead.)
  (
    cd "$dst" && MIX_ENV=test COURIER_TEST_PG_PORT="$KIT_TENANT_PGPORT" \
      "$TIMEOUT_BIN" 300 mix test test/courier/kit_tenant_isolation_probe_test.exs
  ) 2>&1
  return $?
}