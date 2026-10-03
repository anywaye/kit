#!/usr/bin/env bash
#
# adapters/go.sh — the SECOND implemented adapter of the cross-tenant harness:
# Go, against `identity`.
#
# This file is the whole of kit's knowledge of Go and of identity. The harness
# beside it knows about databases, containers and assertions; it does not know
# what `go test` is, what a pgxpool is, or what an account's tables are called.
# Five functions make up the contract and `adapters/README.md` states it in full.
#
# WHY identity IS THE SECOND
#
#   It is the fleet's Go service, it is in MVP scope, and it already carries the
#   strongest cross-tenant evidence in the fleet: internal/tenancy/isolation.sql,
#   scope.go, tenancy_test.go, scope_test.go, credential_lookup_test.go and
#   migrations/00016_account_isolation.sql — seven measured cross-tenant negative
#   tests in its own audit, the most of any service. So it is the right second
#   subject: if the adapter is wrong, identity is the service least likely to hide
#   it.
#
# WHERE THE PREDICATE LIVES, AND WHY THAT MOVES THE ANCHORS
#
#   In courier the predicate is `where account_id == ^account_id` in a context
#   query, two of whose six breakages are one-word edits in a controller. In
#   identity there is no context module and no controller doing the scoping: the
#   statement IS the boundary. `internal/accounts/store.go` spells
#   `WHERE account_id = $1` in five functions, and a refactor that drops one is
#   invisible to a grep, to `go vet`, to golangci-lint, and to identity's own
#   suite — which asserts the SUBSTRATE and never asserts these clauses. That is
#   why `reports/tenant-adapter-go-01/mutations.sh` has its own anchors and does
#   not reuse the Elixir recipe's.
#
# THE CONNECTION IS A SUPERUSER, AND IT IS DELIBERATE — READ THIS BEFORE CHANGING IT
#
#   identity runs with `FORCE ROW LEVEL SECURITY` and a `identity_app` login role,
#   and `tests/tenancy_test.sh` proves that substrate in six languages already.
#   This harness is the other half: it proves the APPLICATION's scoping.
#
#   Postgres exempts a SUPERUSER from row-level security unconditionally, whatever
#   the FORCE says. So the DSN below connects as `postgres`, and that is the
#   mechanism that makes every denial in the probe attributable to identity's own
#   `WHERE account_id = $1` rather than to the substrate. Connect as `identity` or
#   `identity_app` instead and all six breakages would stay green on a tree with
#   every predicate removed — the vacuous green this repository has a written rule
#   about. The probe asserts the exemption still holds
#   (`TestTheSubstrateIsNotWhatHoldsThisLine`), so a change to this DSN goes red
#   rather than quietly turning the suite into a second measurement of RLS.
#
#   The claim this adapter can make is therefore the narrow one: identity's
#   statements are scoped. It is not "identity is safe in production".
#
# WHAT IS COPIED, AND WHY IT IS NOT THE CHECKOUT
#
#   Everything except `.git`, and the module cache is SHARED rather than copied:
#   `go build` resolves from `$GOMODCACHE`, which is on the machine rather than in
#   the service. Copying it would be copying hundreds of megabytes to measure
#   nothing. The checkout itself is never written to — the mutation cases break the
#   COPY's source and restore it, and identity's working tree is not this
#   repository's to break.
#
# WHY THE COMPILE IS IN `adapter_prepare` AND IS FATAL
#
#   `go build ./...` over the copy. Bounded, and fatal on failure: a harness that
#   compiled nothing has no query layer to run, and the Go toolchain's failure mode
#   is to compile a subset that still imports the broken package, so this is
#   `build ./...` over the module rather than a targeted package.
#
# SC2209 is disabled for this whole file, and the directive has to sit BEFORE the
# first command to be file-wide — a shellcheck directive placed after `set` applies
# to the next command only, which is how a "file-wide" disable silently disables
# nothing. `TIMEOUT_BIN` is assigned in the harness by `command -v`, so `shellcheck`
# cannot see from here that it holds a path rather than a string built by a command
# substitution. The adapter inherits the harness's binary rather than re-resolving
# it, because two resolvers is one more place to be wrong.
# shellcheck disable=SC2209

set -uo pipefail

adapter_language_tool() { printf 'go'; }

# Where the probe is copied to INSIDE the service copy, and the package it lands
# in. A directory of its own rather than `internal/accounts`, because the probe
# calls several stores and adding a test file to a package under mutation would
# mean a mutation's recompile also has to satisfy the probe.
PROBE_PKG_DIR="internal/kitprobe"
PROBE_SRC_NAME="cross_tenant_probe_test.go"

# go_probe — the one environment every `go test` in this adapter runs with.
#
# `TEST_DATABASE_URL` rather than a name of this adapter's own: it is the variable
# identity's own database tier already documents (`internal/mfa`'s
# TestTheDatabaseTierActuallyRan fails rather than skipping when it is unset), so
# the probe reads the same one identity's own suites do.
go_probe() {
  printf 'postgres://postgres:postgres@127.0.0.1:%s/postgres?sslmode=disable' \
    "$KIT_TENANT_PGPORT"
}

# harness_project_name — the container the harness started, derived from the
# work directory it left behind.
#
# `cross_tenant_harness.sh` names its container `kit-tenant-iso-$SESSION` and its
# work directory `kit-tenant-iso.$SESSION`. Nothing outside that file knows the
# session except the recipe that exported it, and the adapter contract names five
# readable variables and the session is not one of them — so the name is read out
# of the one variable the contract does grant.
harness_project_name() {
  local base="${KIT_TENANT_WORK##*/}"
  case "$base" in
    kit-tenant-iso.*)
      [ -n "${base#kit-tenant-iso.}" ] || return 1
      printf 'kit-tenant-iso-%s' "${base#kit-tenant-iso.}"
      ;;
    *)
      return 1
      ;;
  esac
}

adapter_prepare() {
  local src="$KIT_TENANT_SERVICE" dst="$KIT_TENANT_WORK/service"
  [ -f "$src/go.mod" ] || {
    printf '  %s has no go.mod, so it is not the Go service this adapter was written\n' "$src" >&2
    printf '  for. Point KIT_SERVICE_REPO at identity.\n' >&2
    return 1
  }
  rm -rf "$dst"
  mkdir -p "$dst" || return 1
  # `.git` is the only exclusion, and it is excluded by name rather than by a
  # find: a copy that carried identity's git history would let a mutation recipe
  # `git checkout` the file it just broke and revert six cases silently.
  ( cd "$src" && tar -cf - --exclude='./.git' . ) | ( cd "$dst" && tar -xf - ) || return 1
  [ -f "$dst/go.mod" ] || {
    printf '  the copy of %s arrived without a go.mod.\n' "$src" >&2
    return 1
  }

  # Compiling ONCE is the difference between this harness taking a minute and
  # taking thirteen. Bounded, and fatal on failure.
  ( cd "$dst" && "$TIMEOUT_BIN" 600 go build ./... ) >"$KIT_TENANT_WORK/build.log" 2>&1 || {
    printf '  go build failed; tail of the log:\n' >&2
    tail -20 "$KIT_TENANT_WORK/build.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

adapter_migrate() {
  local dst="$KIT_TENANT_WORK/service"

  # FINDING, AND IT IS A GOOD ONE: identity's migrations need a LOGIN ROLE THAT
  # DOES NOT YET EXIST, and they derive its name from the role that is running
  # them. `migrations/00016_account_isolation.sql` calls
  # `cafaye.protect_table('account_users')` with one argument, and that function
  # computes `login_role := coalesce(p_login_role, current_user || '_app')` and
  # then RAISES unless such a role already exists and can log in:
  #
  #     ERROR: cafaye.protect_table(account_users, postgres_app):
  #            postgres_app is not a LOGIN role on this cluster.
  #
  # The hint the migration ships with says what provides it: "kit's cluster
  # provisions <service> and <service>_app". So the substrate this migration
  # installs is DEPENDENT ON infrastructure outside the migration, and a harness
  # that brings up a bare `postgres:17` has to provide it or 00016 cannot apply.
  #
  # It is provided BELOW, as a ROLE and nothing else — no table, no policy, no
  # column. That is not the "hand-written schema" the adapter contract forbids:
  # the contract forbids inventing DDL and then measuring the harness's own, and
  # a LOGIN role is not a schema, is what kit's own cluster init script
  # provisions, and is exactly what the migration's own error message asks for.
  #
  # The name is derived by the DATABASE, with the same expression `protect_table`
  # itself uses, rather than written down here. An adapter that hardcoded
  # `identity_app` would be a second statement of a fact the migration already
  # states, and the two would be free to disagree.
  #
  # It runs through the harness's OWN container rather than a local `psql`: the
  # harness has already died unless docker is present, and a postgres:17 image
  # carries psql, so this adds no toolchain dependency to a machine that has one.
  #
  # The container name is DERIVED from $KIT_TENANT_WORK — the harness builds the
  # work directory as `kit-tenant-iso.$SESSION` and the container as
  # `kit-tenant-iso-$SESSION`, and those two differ by exactly that separator —
  # because the adapter contract lets an adapter read $KIT_TENANT_WORK and not
  # the session. The transformation is CHECKED rather than assumed: a work
  # directory not shaped the way the harness names it returns rather than running
  # `docker exec` against a name this file invented.
  local project
  project="$(harness_project_name)" || {
    printf '  cannot derive the harness container name from KIT_TENANT_WORK=%s.\n' \
      "$KIT_TENANT_WORK" >&2
    return 1
  }

  if ! "$TIMEOUT_BIN" 60 docker exec "$project" psql -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -q \
    -c "do \$\$ begin
            if not exists (select 1 from pg_roles
                             where rolname = current_user || '_app' and rolcanlogin) then
              execute format('create role %I login', current_user || '_app');
            end if;
          end \$\$;" >"$KIT_TENANT_WORK/role.log" 2>&1; then
    printf '  the login role cafaye.protect_table needs could not be provisioned:\n' >&2
    sed 's/^/  /' "$KIT_TENANT_WORK/role.log" >&2
    return 1
  fi

  # The SERVICE's own migrations, against the harness's own database, applied with
  # the tool identity's own migrations/README.md names. Not a hand-written schema:
  # a harness that seeds a table it invented is measuring its own DDL rather than
  # the service's query layer.
  #
  # `postgres` is a superuser and that is load-bearing here for the same reason the
  # DSN is: migrations/00016 creates the `cafaye` schema, the login role's grants
  # and every policy, and it installs `FORCE ROW LEVEL SECURITY` on the tables it
  # protects. As the superuser, the exemption from RLS applies to those policies
  # too — which is exactly the point the header above makes.
  (
    cd "$dst" &&
      "$TIMEOUT_BIN" 300 goose -dir migrations postgres "$(go_probe)" up
  ) >"$KIT_TENANT_WORK/migrate.log" 2>&1 || {
    printf '  identity'"'"'s own migrations failed; tail of the log:\n' >&2
    tail -25 "$KIT_TENANT_WORK/migrate.log" | sed 's/^/  /' >&2
    return 1
  }
  return 0
}

# The probe is COPIED in, not written here, and it lands in a `.go` file with a
# `.go` extension because kit's rule is "parse what you hand out": a Go file with
# a misleading extension is how `rack_middleware.rb.snippet` shipped syntax that
# was not Ruby.
adapter_install_probe() {
  local probe="$KIT_TENANT_ADAPTER_DIR/go/$PROBE_SRC_NAME"
  local dst="$KIT_TENANT_WORK/service/$PROBE_PKG_DIR"
  [ -r "$probe" ] || {
    printf '  the negative suite is missing at %s\n' "$probe" >&2
    return 1
  }
  mkdir -p "$dst" || return 1
  cp "$probe" "$dst/$PROBE_SRC_NAME" || return 1
  # Prove the file is COLLECTED before anything asserts on it. A probe that was
  # never collected reports seven tests as "0 failures" and every breakage looks
  # like it stayed green — the class of failure this repository has already paid
  # for twice. `go test -list` is the Go equivalent of the ExUnit collection the
  # Elixir adapter gets, and a list that comes back empty is a HARD failure here
  # rather than a zero.
  adapter_run '__collect_probe__'
}

# `go test -run` takes an UNANCHORED REGEX, so a needle that is a prefix of
# another test's name selects that test too. The probe's names are therefore
# written so that none is a prefix of any other, which is what lets the recipe
# pass a bare test name as its needle and get exactly one test. This is stated
# here because the property lives in the probe file and the coupling does not.
adapter_run() {
  local needle="${1:-}" dst="$KIT_TENANT_WORK/service"

  if [ "$needle" = "__collect_probe__" ]; then
    local listed
    if ! listed="$( cd "$dst" && TEST_DATABASE_URL="$(go_probe)" \
        "$TIMEOUT_BIN" 300 go test -list '.' "./$PROBE_PKG_DIR/" 2>&1 )"; then
      printf '  go test -list could not enumerate the probe. It does not compile, or\n' >&2
      printf '  the package is not where it was copied. Full output:\n' >&2
      printf '%s\n' "$listed" | tail -25 | sed 's/^/  /' >&2
      return 1
    fi
    # The count is of NAMES, not of lines: `go test -list` also prints `ok <pkg>`
    # and a build line, so a line count would report two "tests" on a package that
    # collected nothing.
    local n
    n="$(printf '%s\n' "$listed" | grep -c -E '^Test' || true)"
    if [ "${n:-0}" -lt 1 ]; then
      printf '  the negative suite was NOT COLLECTED. `go test -list` returned:\n' >&2
      printf '%s\n' "$listed" | sed 's/^/  /' >&2
      printf '  A probe that was never collected reports 0 failures and every breakage\n' >&2
      printf '  looks green. Refusing to continue.\n' >&2
      return 1
    fi
    printf '%s\n' "$listed"
    printf 'collected %s test(s) in %s\n' "$n" "$PROBE_PKG_DIR"
    return 0
  fi

  # `__all__` runs the whole suite. The recipe's control uses it, so the base
  # phase is one process that seeds once and runs every assertion, which is what
  # makes "the allowance control ran before any mutation" a fact rather than a
  # hope.
  local filter='.'
  [ "$needle" != "__all__" ] && filter="$needle"
  [ -n "$needle" ] || filter='.'

  local out code
  out="$(
    cd "$dst" && TEST_DATABASE_URL="$(go_probe)" \
      "$TIMEOUT_BIN" 600 go test -count=1 -v -run "$filter" "./$PROBE_PKG_DIR/" 2>&1
  )"
  code=$?
  printf '%s\n' "$out"

  # THE VACUOUS-GREEN GUARD. `go test -run` that matches nothing prints `ok` and
  # EXITS 0, so a needle which has stopped matching — a renamed test, a recipe
  # typo — reports a pass for a probe that ran no assertion at all. A `=== RUN`
  # line is emitted by the runner for every test it actually started, so counting
  # them is a measurement taken from the runner's own output rather than from a
  # list this adapter maintains about the probe.
  local ran
  ran="$(printf '%s\n' "$out" | grep -c -E '^=== RUN' || true)"
  if [ "${ran:-0}" -lt 1 ]; then
    printf 'adapter_run: THE RUN MEASURED NOTHING. `go test -run %s` started 0 tests and\n' \
      "$filter" >&2
    printf '  still exited %s, which is the vacuous green this harness exists to\n' "$code" >&2
    printf '  remove. Refusing to report it as a pass.\n' >&2
    return 1
  fi
  printf 'ran %s test(s)\n' "$ran" >&2
  return "$code"
}