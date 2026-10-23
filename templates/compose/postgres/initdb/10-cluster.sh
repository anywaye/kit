#!/usr/bin/env bash
#
# One Postgres CLUSTER. One DATABASE per service. TWO ROLES per service: an owner,
# and a login role that owns nothing.
#
# This is the whole of kit's isolation contract, and database-per-service is
# why the cluster is shared rather than one-per-service: the DATABASE is the
# boundary. Two services that each own a database cannot read each other's
# rows, because `REVOKE ALL ON DATABASE ... FROM PUBLIC` below means role
# `courier` is refused at the door of database `billing` before a single query is
# parsed.
#
# WHY A ROLE PER SERVICE AND NOT A SHARED ROLE. A shared role can CONNECT to
# every database in the cluster, so "cannot read another service's data" becomes
# a GRANT somebody has to remember to withhold. One role per service makes the
# refusal structural: there is no second credential to leak and no grant to get
# right, because the ONLY role holding CONNECT on `billing` is `billing`'s.
#
# WHY TWO, AND WHY ONE OF THEM LOGS IN. This is the account boundary inside one
# service's own database, and `templates/database/tenancy/` is what enforces it.
# The only part of that which belongs here is the roles, because Postgres exempts
# a table's OWNER from its own row-level-security policies and the owner of these
# tables is the role the service's migrations run as — which, before this line
# existed, was also the role the application logged in as. A login role that owns
# its tables can `ALTER TABLE ... DISABLE ROW LEVEL SECURITY` and can `DROP
# POLICY`, so a service's account policies were one privilege away from meaning
# nothing, and nothing about them would have said so.
#
#   <service>       the OWNER. LOGIN, owns the database and every table, runs
#                   migrations. UNCHANGED: adopting the tenancy templates does not
#                   change how a service builds its schema.
#   <service>_app   the LOGIN the application uses. Owns nothing. Granted DML per
#                   account-scoped table by `anywaye.protect_table`, and nothing
#                   else: no ownership, no DDL, no ability to alter a policy.
#
# `FORCE ROW LEVEL SECURITY` is the other half and it is deliberately NOT done
# here, because it is a property of a table rather than of a cluster, and doing it
# cluster-wide would enable it on tables that have no policies yet — a table whose
# only privilege is then its owner's becomes unreadable by everybody, mid-migration.
# `templates/database/tenancy/substrate.sql` does it per table, and
# `isolation.sql` asserts it by running the denials AS THE OWNER, which is the
# only way to assert it that a policy merely being present cannot satisfy.
#
# WHY THE REVOKE IS HERE AND NOT LEFT TO THE OPERATOR. Postgres grants CONNECT
# on every database to PUBLIC by default, including ones created after this
# script runs. A cluster provisioned without these lines therefore has, by
# default, NO isolation: every role in the fleet can open every database. It
# fails open and silently, and the symptom is a cross-service query that works
# in development and is a report in production.
#
# It is also per-database and per-run. An operator who adds a database by hand
# gets Postgres's default rather than this contract, which is why
# `templates/bin/dev.sh`'s `db grant` prints the exact statements for one new
# database instead of assuming they happened.
#
# WHY THE REVOKE IS HERE AND NOT LEFT TO THE OPERATOR. Postgres grants CONNECT
# on every database to PUBLIC by default, including ones created after this
# script runs. A cluster provisioned without these lines therefore has, by
# default, NO isolation: every role in the fleet can open every database. It
# fails open and silently, and the symptom is a cross-service query that works
# in development and is a report in production.
#
# It is also per-database and per-run. An operator who adds a database by hand
# gets Postgres's default rather than this contract, which is why
# `templates/bin/dev.sh`'s `db grant` prints the exact statements for one new
# database instead of assuming they happened.
#
# WHAT IS NOT HERE. Credentials are not. Every role below takes
# `$POSTGRES_PASSWORD`, because this runs on a developer's machine and a shared
# development password is the point. Isolation is by PRIVILEGE and never by
# secret, which is exactly why the proof in `tests/isolation_test.sh` can
# demonstrate the boundary while knowing every password in the cluster. In
# production the roles carry distinct passwords from the deployment secret
# store, and nothing about the boundary below changes.

set -euo pipefail

# The C locale, for this script only, and it is load-bearing rather than
# hygienic.
#
# Shell bracket ranges — `[a-z]`, `[!a-z0-9_]` — are COLLATION-DEPENDENT, and
# `require_identifier` below is built entirely out of them. Under `en_US.UTF-8`,
# which is the default on the machine this fleet is developed on, collation is
# case-insensitive at the primary level, so `[a-z]` matches `B` and `[!a-z]` does
# NOT match it. Measured, same pattern, two locales:
#
#   $ LC_ALL=C          bash -c 'case Billing in [!a-z_]*) echo REFUSE;; *) echo ACCEPT;; esac'
#   REFUSE
#   $ LC_ALL=en_US.UTF-8 bash -c '…'
#   ACCEPT
#
# So on a developer Mac the identifier rule was enforcing roughly half of what
# its own message claims. `Billing`, `BILLING` and `cafayé` were all accepted
# while the error string said `must match [a-z_][a-z0-9_]*`.
#
# That is not injection — the characters that would break out of an unquoted
# identifier (quotes, semicolons) still sort outside `[a-z]` and are still
# refused under either locale. It is worse than that, quietly: Postgres folds
# unquoted identifiers to lower case, so `KIT_POSTGRES_DATABASES=Billing` and
# `…=billing` name the SAME database. Two services differing only in case would
# share one database and one role — which is precisely the harm
# `require_identifier`'s own message says it exists to prevent, arriving by the
# one route that produces a legal-looking name.
#
# `LC_ALL=C` is set rather than the pattern being rewritten with `[[:lower:]]`
# because the locale also governs `tr`, `sort` and `printf %q` further down, and
# a provisioning script that compares strings differently depending on whose
# laptop ran it is not deterministic in any sense that matters. Exported, so the
# `psql` calls inherit it too.
export LC_ALL=C

# Fail by name, and before anything is created.
#
# The Postgres documentation points at mrts/docker-postgresql-multiple-databases
# for this shape. kit does not vendor that repository and does adopt its
# instinct, because its failure mode is why this paragraph exists: an unset
# variable leaves you with one database and a stack that looks perfectly fine. A
# service whose migrations then run against a database that was never created
# fails much later and much less legibly.
: "${KIT_POSTGRES_DATABASES:?KIT_POSTGRES_DATABASES is unset. Name the services, comma-separated. A service with no entry has no database, and its migrations fail against a database that was never created.}"

statement_timeout_ms="${KIT_POSTGRES_STATEMENT_TIMEOUT_MS:-15000}"
idle_in_transaction_ms="${KIT_POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT_MS:-30000}"
role_connection_limit="${KIT_POSTGRES_ROLE_CONNECTIONS:-10}"
extensions="${KIT_POSTGRES_EXTENSIONS:-}"

note() { printf '  [cluster] %s\n' "$1"; }

# The one validator. Both a service name and an extension name are pasted
# unquoted into an identifier below, and both come from a service's own `.env`,
# so neither may be trusted to be a bare identifier. An unvalidated name either
# errors several statements away from the mistake or — the version worth
# preventing — builds one identifier out of two tokens.
require_identifier() {
  case "$2" in
    "" | [!a-z_]* | *[!a-z0-9_]*)
      note "REFUSING '$2' as $1: must match [a-z_][a-z0-9_]*. Silently mangling an identifier here is how one service ends up owning another's database."
      exit 1
      ;;
  esac
}

# psql against the admin database. `ON_ERROR_STOP=1` is not decoration: without
# it psql logs the error, carries on, and still exits 0. Every statement in this
# file is load-bearing, and a load-bearing statement whose failure is ignored is
# how a cluster comes up holding two of nine databases and reports itself
# healthy.
admin() {
  psql --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set=ON_ERROR_STOP=1 "$@"
}

IFS=',' read -r -a entries <<<"$KIT_POSTGRES_DATABASES"
provisioned=0

for entry in "${entries[@]}"; do
  # A comma-separated list in a `.env` file is very often written with a space
  # after the comma, and trailing whitespace is not a syntax error anybody
  # should have to notice — so the entry is trimmed, not policed.
  #
  # WHITESPACE *INSIDE* an entry is a different thing and is refused rather than
  # trimmed, and this is the second half of `require_identifier`'s promise. That
  # function already rejects a name containing a space or a capital, but the
  # `tr` below used to run first and DELETE the space, so the two names arrived at
  # the validator already fused into one valid-looking identifier:
  #
  #     KIT_POSTGRES_DATABASES=billing neighbour     # space, no comma
  #       [cluster] provisioning billingneighbour
  #       [cluster] done: 1 service database(s), one role each, PUBLIC holds CONNECT on none of them
  #
  # That is the exact failure the validator's own comment names — "builds one
  # identifier out of two tokens" — reached by the only route that produces a
  # *legal* identifier, which is why no other check in this file could see it. The
  # stack reports success, one service's database does not exist, and the second
  # service's migrations fail against a database nobody created. On a fleet whose
  # whole plan is "one cluster, a database and a role per service", the
  # multi-tenant path failing on the SECOND tenant is the worst place it could
  # fail: the single-tenant case, which is every case anyone had run, is green.
  #
  # So the trim is split in two: outer whitespace goes, inner whitespace is an
  # error naming the entry and the separator that was probably meant.
  trimmed="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$trimmed" ] || continue

  case "$trimmed" in
    *[[:space:]]*)
      note "REFUSING '$trimmed' as a service name: it holds whitespace, which reads as two names with no comma between them."
      note "  KIT_POSTGRES_DATABASES is COMMA-separated: 'billing,courier', not 'billing courier'."
      note "  A space after a comma is fine; a space instead of one fuses the names into the single database '$trimmed', and this stack reported itself healthy while doing it."
      exit 1
      ;;
  esac

  service="$trimmed"
  require_identifier service "$service"
  # The login role. A separate name rather than a flag, because it is derived from
  # the service name and deriving it means there is no way for the two to disagree:
  # a service that wanted an app role under a different name would need an
  # override, and an override is a second thing to configure per service.
  app_role="${service}_app"
  require_identifier login-role "$app_role"
  note "provisioning $service"

  # ONE STATEMENT PER psql CALL for the two below, and this is measured rather
  # than stylistic.
  #
  # Read from a heredoc, psql sends consecutive statements as a single simple
  # query, which the server wraps in an implicit transaction — and
  # `CREATE DATABASE` refuses inside one:
  #
  #   ERROR:  CREATE DATABASE cannot run inside a transaction block
  #
  # with `ON_ERROR_STOP=1` on. So the obvious shape — one psql call per service
  # holding `CREATE ROLE` and `CREATE DATABASE` together — provisions the ROLE
  # and then dies, and because this script runs during initdb the whole cluster
  # refuses to start. `CREATE INDEX CONCURRENTLY` and `VACUUM` fail the same
  # way; the rule is that these two cannot share a batch.
  admin --set=svc="$service" --set=pw="$POSTGRES_PASSWORD" <<'SQL' >/dev/null
CREATE ROLE :"svc" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'pw';
SQL

  # THE LOGIN ROLE, and the `GRANT` that makes the whole thing possible.
  #
  # It is created here, with everything else, because `templates/database/README.md`
  # already says a role is created in exactly one place and this is that place. It
  # has no privilege beyond CONNECT on its own database; `anywaye.protect_table`
  # grants the DML, per table, in the service's own migrations.
  #
  # `GRANT "…"_app TO "…"` is the membership that lets the OWNER impersonate the
  # weaker role, which is what `templates/database/tenancy/isolation.sql` and
  # `tests/isolation_test.sh` both do to prove the boundary from the outside. The
  # DIRECTION is the whole point and it is asymmetric by design:
  #
  #   owner -> app     allowed, and it is a strict weakening: the owner can become
  #                    something that can do less. This is how a proof is written.
  #   app -> owner     FORBIDDEN, and it is what the design is for. The reverse
  #                    membership would hand the application every privilege the
  #                    owner has, which is every privilege on every table.
  #
  # A service that is told "your login role cannot disable RLS on your own tables"
  # has to be able to be believed, and that belief is only as good as the absence
  # of this membership in the other direction. `tenancy.yml`'s declarations and the
  # adoption packet check it; nothing in this script can, because a service may
  # legitimately grant it.
  admin --set=app="$app_role" --set=svc="$service" --set=pw="$POSTGRES_PASSWORD" <<'SQL' >/dev/null
CREATE ROLE :"app" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'pw';
GRANT :"app" TO :"svc";
SQL

  # The database, OWNED by that role. Ownership is what makes the schema grants
  # below unnecessary rather than merely repeated: from PG15 the `public` schema
  # belongs to `pg_database_owner`, the database owner is implicitly a member of
  # it, and so the owning role keeps CREATE on `public` with no GRANT anywhere.
  # That is why this cluster's PostgreSQL floor is 15.
  admin --set=svc="$service" <<'SQL' >/dev/null
CREATE DATABASE :"svc" OWNER :"svc";
SQL

  # THE BOUNDARY, plus blast radius. Each statement is load-bearing:
  #
  #   REVOKE ALL ON DATABASE  PUBLIC holds CONNECT by default. Withdrawing it
  #                         is the entire mechanism; the rest is bookkeeping.
  #   GRANT CONNECT, TEMPORARY gives the one role that belongs back in. A
  #                         database nobody may enter is a tombstone, not a
  #                         service.
  #   ALTER ROLE ... CONNECTION LIMIT
  #                         caps one service's share, so a pool that grows
  #                         without bound exhausts its own service instead of
  #                         refusing connections for the other eight.
  #   statement_timeout        a runaway query in one service stops itself
  #                           rather than occupying shared resources until the
  #                           cluster is unusable.
  #   idle_in_transaction_session_timeout
  #                           the shared-cluster killer. One forgotten BEGIN
  #                           holds a snapshot open, which blocks VACUUM
  #                           cluster-wide and grows every table on the box. On
  #                           one database per machine this is one service's
  #                           problem; on one cluster it is nine services'.
  #
  # The app role gets CONNECT and the same two timeouts, and deliberately NOT a
  # CONNECTION LIMIT. `templates/database/README.md` states that the per-role limit
  # is a service's SHARE of the cluster's connection budget, and the budget is nine
  # services' worth rather than eighteen roles' worth — a service that has adopted
  # the tenancy templates opens its connections as `<service>_app`, so the limit has
  # to be reachable from there. A service that has not adopted them connects as
  # `<service>` and is bounded exactly as before, which is the point: adding this
  # role changes nothing at all for a service that does not use it.
  admin --set=svc="$service" --set=app="$app_role" --set=conn_limit="$role_connection_limit" \
    --set=stmt_ms="$statement_timeout_ms" --set=idle_ms="$idle_in_transaction_ms" <<'SQL' >/dev/null
REVOKE ALL ON DATABASE :"svc" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"svc" TO :"svc";
GRANT CONNECT, TEMPORARY ON DATABASE :"svc" TO :"app";
ALTER ROLE :"svc" CONNECTION LIMIT :conn_limit;
ALTER ROLE :"svc" SET statement_timeout = :'stmt_ms';
ALTER ROLE :"svc" SET idle_in_transaction_session_timeout = :'idle_ms';
ALTER ROLE :"app" SET statement_timeout = :'stmt_ms';
ALTER ROLE :"app" SET idle_in_transaction_session_timeout = :'idle_ms';
SQL

  # PG15 REMOVED the default `CREATE` grant on the `public` schema, so a role
  # that is not the database owner cannot create objects in somebody else's
  # database any more. That is the change that makes database-per-service an
  # actual boundary rather than a naming convention, and it is asserted here
  # rather than inherited: this statement is already the PG15+ default, so on a
  # supported floor it changes nothing, and its value is that the contract is
  # stated in the cluster rather than assumed from a version's behaviour.
  #
  # No GRANT CREATE for the owner, because `pg_database_owner` already carries
  # it. Granting it a second way would be a second fact to keep true, and the
  # first one is a documented property of the server rather than of this file.
  psql --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$service" \
    --set=ON_ERROR_STOP=1 <<'SQL' >/dev/null
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

  # Extensions, created BY THE ADMIN ROLE, and that is a finding rather than a
  # shortcut.
  #
  # The obvious design — `SET ROLE <service>; CREATE EXTENSION` — cannot work,
  # and the reason is worth recording because it corrects a reasonable
  # assumption. pgvector's control file is not marked `trusted` (PG13+), so
  # `CREATE EXTENSION` by a non-superuser is refused with:
  #
  #   ERROR:  permission denied to create extension "vector"
  #   HINT:  Must be superuser to create this extension.
  #
  # Checked against pglayers' layer and against upstream pgvector v0.8.6, whose
  # `vector.control` is byte-identical — this is pgvector's own classification,
  # not something pglayers drops.
  #
  # So extension availability is a CLUSTER decision, made once by the operator,
  # rather than something a service installs for itself. That is the right shape
  # for a shared cluster anyway: the extension's binaries are in the image and
  # therefore available to every service regardless, so the only thing a
  # per-service grant would have governed is who gets to pay the disk cost.
  if [ -n "$extensions" ]; then
    IFS=',' read -r -a ext_list <<<"$extensions"
    for raw_ext in "${ext_list[@]}"; do
      ext="$(printf '%s' "$raw_ext" | tr -d '[:space:]')"
      [ -n "$ext" ] || continue
      require_identifier extension "$ext"
      note "$service: CREATE EXTENSION IF NOT EXISTS $ext"
      # Own psql call for the same reason as CREATE DATABASE: `SET ROLE` and
      # `CREATE EXTENSION` in one batch put both statements in a single
      # transaction, and the extension's privilege check then runs before the
      # role change is visible — measured, and it fails with the misleading
      # "must be superuser" above even though the superuser was doing it.
      psql --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$service" \
        --set=ON_ERROR_STOP=1 --set=ext="$ext" <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS :"ext";
SQL
    done
  fi

  provisioned=$((provisioned + 1))
done

if [ "$provisioned" -eq 0 ]; then
  note "REFUSING to finish with zero databases. An empty KIT_POSTGRES_DATABASES brings up a cluster that satisfies every statement in this script and isolates nothing."
  exit 1
fi

# THE CONTRACT, ENFORCED OVER EVERY DATABASE RATHER THAN A LIST OF THEM.
#
# This block replaces a list, and the reason is that the list was not the whole
# truth. The official image creates TWO databases before any init script is
# sourced — the one named by `POSTGRES_DB`, and a stock `postgres` maintenance
# database that nothing here had touched. So the cluster came up with
# `has_database_privilege('public','postgres','CONNECT') = true` while this
# script printed "PUBLIC holds CONNECT on none of them". A closing sentence that
# is wrong is worse than no closing sentence, because it is the one a reader
# trusts.
#
# Sweeping every non-template database makes the invariant hold BY CONSTRUCTION
# rather than by a list somebody has to remember to extend, and `postgres` is
# covered because it is a database rather than because it was named.
#
# A DO block rather than a shell loop because this needs `pg_database`, which a
# REVOKE cannot be made conditional against from bash without a separate
# existence test per database — and the per-database existence test is exactly
# where this went wrong first: psql does NOT interpolate `:'vars'` in a
# `--command` string (measured: "syntax error at or near \":\""), so the test
# failed, and because it sat inside an `if [ -n "$(…)" ]` its failure was
# SWALLOWED. The script then carried on, skipped the revoke, and exited 0
# reporting a boundary it had not applied. `set -e` does not reach inside a
# command substitution used as an `if` condition; only an explicit check does.
#
# Which is the general shape of the lesson rather than a detail of this line: a
# load-bearing statement whose failure is ignored is how a cluster comes up
# holding three of nine databases and reports itself healthy. Hence one call,
# no `if`, and `ON_ERROR_STOP` doing the work.
#
# ...and the body below carries NO COMMENTS AT ALL, which is the third way this
# same block went wrong and the reason for the rule rather than the fix:
#
#   - a `#` line is not a SQL comment. Inside a DO block it is a syntax error
#     ("syntax error at or near …").
#   - the dollar-quote TAG appears inside the body. Writing that tag in a
#     comment inside a dollar-quoted block ENDS the block at that point
#     ("syntax error at or near \"span\""), because a dollar-quoted string is
#     closed by its own tag wherever that appears — comments do not shield it.
#   - psql does not interpolate `:'vars'` inside a dollar-quoted body, so the
#     admin role cannot be passed in that way either ("syntax error at or near
#     \":\""). Hence `current_user`, which is that role already.
#
# All three failed loudly, which is the behaviour this block is supposed to
# have: the cluster refused to start rather than coming up without a boundary.
# The earlier version of this block did the opposite — see above. Explanation
# lives in this comment, where it cannot be parsed.
admin <<'SQL'
DO $caf$
DECLARE
  d record;
BEGIN
  FOR d IN SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname
  LOOP
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', d.datname);
    EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', d.datname, current_user);
    RAISE NOTICE 'boundary applied: % reachable only by its own role and %', d.datname, current_user;
  END LOOP;
END
$caf$;
SQL

note "done: $provisioned service database(s), an owner and a non-owner login role each, PUBLIC holds CONNECT on none of them"