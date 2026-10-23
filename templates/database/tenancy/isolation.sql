-- kit template — the assertion set that proves an account boundary.
--
--     psql "$MIGRATIONS_DATABASE_URL" -f isolation.sql
--
-- ONE FILE, SIX LANGUAGES. This is the whole assertion set, and it is one file
-- because the assertions are about POSTGRES rather than about a language: the
-- denial a request meets is a denial Postgres returns. Each language's driver
-- (`templates/database/<lang>/tenancy_test.*`) runs this script and then asserts,
-- BY NAME, that every row below came back and that every verdict is `pass`. A
-- driver that stops naming them goes red, which is what makes six thin drivers
-- safe rather than six copies to keep in step.
--
-- THE SHAPE IS THREE DENIALS AND ONE ALLOWANCE, and it is three rather than one
-- because one proves nothing:
--
--   no identity                                   reads zero rows
--   ANOTHER tenant's VALID identity, on its rows  reads zero rows
--   its OWN identity                              reads its own rows, and not the other's
--
-- The first is satisfied by a table with no policy at all — which is the bug — and
-- the last is satisfied by a policy that permits everything. Only the three
-- together are the property, and each is run against BOTH roles: the login role
-- the application authenticates as, and the owner the service's migrations run as.
--
-- WHY THE OWNER IS IN THERE. Postgres exempts a table's OWNER from its own
-- policies unless `ALTER TABLE ... FORCE ROW LEVEL SECURITY` says otherwise, and
-- every service in this fleet runs its migrations as its own role — so the owner
-- IS the role that builds these tables, and the role a developer has open in
-- `psql`. Without FORCE every denial above passes for the login role and the
-- owner reads everything. Measured on this kit, a protected three-row table, read
-- as the owner with another tenant's identity:
--
--     with FORCE      1 row    (its own)
--     without FORCE   3 rows   (every tenant's)
--
-- `FORCE` is not in Supabase's row-level-security guide, no lint in this fleet
-- checks for it, and a table with policies, `relrowsecurity = true` and no FORCE
-- looks completely correct in review. That is why the owner half exists, and why
-- it is the half that cannot be satisfied by a policy which is merely present.
--
-- TWO CONTROLS, because a green answer from a check that cannot see its own
-- defect is worse than no answer at all:
--
--   `sweep/names-an-unprotected-table`      `anywaye.unprotected_tables()` really
--                                            does report a table with an
--                                            `account_id` column and no policies.
--                                            Without it, the sweep's empty result
--                                            is satisfied by a sweep that reports
--                                            nothing.
--                                            The control lives in `pg_temp`, which
--                                            is why the sweep's scope includes this
--                                            session's temporary schema: a control
--                                            outside the thing it controls is not a
--                                            control.
--   `policies/written-for-the-init-plan`    every policy qualifier is a subquery,
--                                            not a bare call. Measured on this
--                                            kit, five rows, one query: the
--                                            wrapped form calls once, the bare
--                                            form five times.
--
-- HOW TO RUN IT, AND WHAT IT LEAVES BEHIND.
--
--   Run it as a role that may `SET ROLE`: the owner. kit's cluster grants
--   `<service>_app` TO `<service>` for exactly this, and impersonating a strictly
--   weaker role cannot widen anything.
--
--   It opens a transaction and does NOT close it. Two things need one: the
--   identity is transaction-local (so a caller in autocommit reads zero rows and
--   every case would pass for the wrong reason), and `SET LOCAL ROLE` is refused
--   outside a transaction block. Every object it creates is TEMPORARY, so it
--   disappears with the session whether the session commits or rolls back — there
--   is nothing here that can outlive the connection, and no cleanup step to
--   forget. Roll back when you are done.
--
-- The output is one table. `verdict` is `pass` or `fail`; `expected` and `actual`
-- are text so a driver's comparison is a string equality in all six languages;
-- and `why` says what the assertion is FOR, so a red row is diagnosable from the
-- report alone rather than by opening this file.

begin;

-- ---------------------------------------------------------------------------
-- Preflight. A substrate that is not installed, or a service that has no login
-- role, is a loud failure here rather than a table of red rows that all say the
-- same thing for different reasons.
-- ---------------------------------------------------------------------------
do $preflight$
begin
  if to_regprocedure('anywaye.protect_table(regclass,text)') is null then
    raise exception 'the tenancy substrate is not installed in this database.'
      using errcode = 'undefined_function',
            hint = 'Apply templates/database/tenancy/substrate.sql first.';
  end if;
  if not exists (select 1 from pg_roles where rolname = current_user || '_app' and rolcanlogin) then
    raise exception 'this database has no %_app LOGIN role, so there is no login role to prove anything about.', current_user
      using errcode = 'undefined_object',
            hint = 'kit''s cluster provisions <service> and <service>_app. A service added to KIT_POSTGRES_DATABASES after the volume was created does not get one, because the init script only runs on a fresh volume: recreate the volume, or apply bin/dev db grant.';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------------
-- Three helpers, all in `pg_temp` so a run leaves nothing in the database.
-- ---------------------------------------------------------------------------

-- The comparison is text equality and nothing else. A tolerant comparison here
-- would make every driver inherit the tolerance, and there is no version of
-- "close enough" that means "another tenant's rows are still hidden".
--
-- `security definer`, owned by the invoking role, because half of these
-- assertions run AS the login role and the result table belongs to the session
-- that started the proof. A SECURITY INVOKER helper would be writing a table it
-- has no privilege on for most of this file's cases, and the failure would be
-- `permission denied for table anywaye_probe_result` rather than an assertion.
-- It is not a privilege escalation: a `pg_temp` function cannot outlive the
-- session, and its owner is the role that created it.
create or replace function pg_temp.anywaye_assert(
  p_assertion text, p_expected text, p_actual text, p_why text
) returns void
language plpgsql
security definer
as $fn$
declare
  seen text := coalesce(p_actual, '<null>');
begin
  insert into pg_temp.anywaye_probe_result (assertion, expected, actual, verdict, why)
  values (p_assertion, p_expected, seen,
          case when seen = p_expected then 'pass' else 'fail' end, p_why);
end
$fn$;
alter function pg_temp.anywaye_assert(text, text, text, text) owner to current_user;

-- For the three shapes that RAISE rather than return nothing. Everything else in
-- this file is an empty result, because core's D33 says a cross-tenant access
-- must be indistinguishable from nonexistence and a `403` is an enumeration
-- oracle. These three are not cross-tenant reads: one writes into another
-- account, and two switch the boundary off. All three are refused by a privilege
-- check, where an error is the correct answer and leaks nothing.
--
-- IT RETURNS THE SQLSTATE INSTEAD OF RECORDING, and that is load-bearing rather
-- than a style choice. It has to be called AS the login role — a SECURITY DEFINER
-- wrapper would run the statement as the owner, and the whole point of
-- `login-role/cannot-disable-row-level-security` is that the owner CAN do it. A
-- recorder built the obvious way therefore succeeds at disabling the boundary,
-- records "no error", and leaves the table unprotected for every assertion after
-- it. That is not hypothetical: it is what the first version of this file did,
-- and it reported three failures whose only common cause was its own harness.
--
-- So the caller sets the role (outside any exception block, see `anywaye_as`),
-- calls this, resets the role, and records the answer as the session role — which
-- is the one role with privilege on the result table.
create or replace function pg_temp.anywaye_observed(p_sql text)
returns text
language plpgsql
as $fn$
begin
  begin
    execute p_sql;
    return 'no error';
  exception
    when others then
      return sqlstate;
  end;
end
$fn$;

-- `SET LOCAL ROLE`, issued OUTSIDE every exception block below, and that is
-- load-bearing rather than tidy. Every `exception` clause opens a subtransaction,
-- and a role change made inside one is discarded when that subtransaction ends —
-- so a `set role` inside an exception handler is silently undone by the very
-- handler that caught the error, and every assertion after it runs as the wrong
-- role and passes for the wrong reason. This function has no exception block of
-- its own for that reason, and neither does anything that calls it.
create or replace function pg_temp.anywaye_as(p_role text)
returns void
language plpgsql
as $fn$
begin
  execute format('set local role %I', p_role);
end
$fn$;

-- The two tenants, as constants rather than generated, so every expected count
-- below is readable and a red row can be diagnosed by eye.
create or replace function pg_temp.anywaye_alpha() returns uuid
language sql immutable as $fn$ select '11111111-1111-1111-1111-111111111111'::uuid $fn$;

create or replace function pg_temp.anywaye_beta() returns uuid
language sql immutable as $fn$ select '22222222-2222-2222-2222-222222222222'::uuid $fn$;

-- Two MEMBERS, as constants for the same reason the two tenants are. They are
-- not tenants — a person belongs to accounts rather than being one — and the
-- distinction is load-bearing in the block below: the assertions there are about
-- a query that must read across the account boundary, not inside it.
create or replace function pg_temp.anywaye_member_one() returns uuid
language sql immutable as $fn$ select 'aaaaaaaa-1111-1111-1111-111111111111'::uuid $fn$;

create or replace function pg_temp.anywaye_member_two() returns uuid
language sql immutable as $fn$ select 'bbbbbbbb-2222-2222-2222-222222222222'::uuid $fn$;

create temp table pg_temp.anywaye_probe_result (
  assertion text primary key,
  expected text not null,
  actual text not null,
  verdict text not null,
  why text not null
) on commit drop;

-- ---------------------------------------------------------------------------
-- The fixture. TEMPORARY, so it cannot outlive the session, and created in
-- `pg_temp` so it never appears in the service's real schema. Two tables: one
-- protected, one deliberately not.
-- ---------------------------------------------------------------------------
create temp table anywaye_probe_things (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  label text not null
) on commit drop;

insert into anywaye_probe_things (account_id, label) values
  (pg_temp.anywaye_alpha(), 'alpha-1'),
  (pg_temp.anywaye_alpha(), 'alpha-2'),
  (pg_temp.anywaye_beta(),  'beta-1');

-- The control table. An `account_id` column and NO policies: the state a service
-- reaches by adding a column to a new table and forgetting the substrate. It
-- exists for the sweep's positive control and for nothing else.
create temp table anywaye_probe_unprotected (
  id int primary key,
  account_id uuid not null
) on commit drop;

select anywaye.protect_table('pg_temp.anywaye_probe_things');

-- The CREDENTIAL fixture. A second account-scoped table whose access path is
-- "find the row by a value you present and learn the account from it" — the
-- shape that made `identity`'s scoped tokens resolve to nothing under 00016,
-- measured and pinned in REPORT-identity-isolation-02 §3 and in
-- `TestTenancyACredentialLookupHasNoIdentityToRunUnder`.
--
-- TWO ROWS, ONE PER TENANT, WITH TWO DISTINCT DIGESTS, and that is the fixture
-- doing the work. A credential table with one row cannot show that a resolution
-- session is narrowed to the row it presented rather than to the table, because
-- "the table" and "that row" are the same set here — and that distinction is the
-- entire mechanism. See `credential/resolution-cannot-browse`.
--
-- The digests are constants rather than generated, like the tenant ids, so every
-- expected count below is readable and a red row can be diagnosed by eye.
create temp table anywaye_probe_credentials (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  token_digest text not null
) on commit drop;

insert into anywaye_probe_credentials (account_id, token_digest) values
  (pg_temp.anywaye_alpha(), 'probe_digest_alpha'),
  (pg_temp.anywaye_beta(),  'probe_digest_beta');

select anywaye.protect_credential_table('pg_temp.anywaye_probe_credentials', 'token_digest');

-- The MEMBERSHIP fixture. The third access path, and the one this directory
-- could not previously express at all.
--
-- The credential fixture is a table whose account is DISCOVERED from a value the
-- caller presents. This one is a table that MAPS persons to accounts, and its
-- subject is the caller rather than any row: "which accounts is this person in"
-- is the first query a product issues after a sign-in, and it runs before any
-- account exists to stand in. Under `protect_table` alone that query returns
-- nothing, the policy is present, and nothing anywhere reports a denial — so the
-- defect is a green suite and an empty product screen. Measured on a real
-- `account_users` under identity's 00016: the membership row was present and
-- `GET /v1/accounts` answered `[]`.
--
-- THREE ROWS ACROSS TWO TENANTS AND TWO MEMBERS, and the spread is the one that
-- does the work. One membership each would let `membership-discovery-cannot-
-- browse` be satisfied by a policy reading the whole table, because "my
-- memberships" and "the table" would be the same set. So MEMBER ONE is in BOTH
-- accounts — so an unqualified read has two correct rows to return where the
-- table holds three — while MEMBER TWO is only in beta, which is what makes the
-- mirror assertion below fail for the right reason. The roles are consistent with
-- that spread: MEMBER ONE owns alpha and is a member of beta, MEMBER TWO owns
-- beta, and the two roles for MEMBER ONE are not a contradiction because they are
-- in DIFFERENT accounts.
create temp table anywaye_probe_memberships (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  user_id uuid not null,
  role text not null
) on commit drop;

insert into anywaye_probe_memberships (account_id, user_id, role) values
  (pg_temp.anywaye_alpha(), pg_temp.anywaye_member_one(), 'owner'),
  (pg_temp.anywaye_beta(),  pg_temp.anywaye_member_one(), 'member'),
  (pg_temp.anywaye_beta(),  pg_temp.anywaye_member_two(), 'owner');

select anywaye.protect_membership_table('pg_temp.anywaye_probe_memberships', 'user_id');

-- ===========================================================================
-- THE SPINE. Three denials and one allowance, per role.
-- ===========================================================================
do $spine$
declare
  r text;
begin
  foreach r in array array['login', 'owner'] loop
    -- `login` is the role the application authenticates as and owns nothing.
    -- `owner` is the role this script's migrations run as, which is the role
    -- FORCE is about. Both must be denied.
    if r = 'login' then
      perform pg_temp.anywaye_as(current_user || '_app');
    else
      perform pg_temp.anywaye_as(current_user);
    end if;

    -- (1) NO IDENTITY READS ZERO ROWS.
    perform anywaye.begin_account(null);
    perform pg_temp.anywaye_assert(
      r || '/no-identity-reads-no-rows', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'a request with no account set must see nothing at all: not one tenant, not an error, and not a hint that the table has rows'
    );

    -- (2) ANOTHER TENANT'S VALID IDENTITY, ON THAT TENANT'S OWN ROWS, READS ZERO.
    perform anywaye.begin_account(pg_temp.anywaye_beta());
    perform pg_temp.anywaye_assert(
      r || '/another-tenants-rows-read-as-none', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_alpha()),
      'a request carrying another tenant''s VALID identity must not read that tenant''s rows. This is the assertion an unenforced table fails, and the only one that does'
    );

    -- (3) ITS OWN IDENTITY READS ITS OWN ROWS. The allowance, and the half that
    -- stops the two above from being satisfied by a table nobody can read.
    perform anywaye.begin_account(pg_temp.anywaye_alpha());
    perform pg_temp.anywaye_assert(
      r || '/own-rows-are-visible', '2',
      (select count(*)::text from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_alpha()),
      'a request carrying its own identity must read its own rows. Without this, "reads zero rows" is satisfied by a policy that denies everything'
    );

    -- (4) AND ONLY ITS OWN. The count of an UNQUALIFIED read, which is the shape
    -- a listing endpoint issues, and which stops assertion 3 from being satisfied
    -- by a policy that permits everything.
    perform pg_temp.anywaye_assert(
      r || '/own-identity-reads-only-its-own-rows', '2',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'an unqualified read as alpha must return alpha''s two rows and not beta''s third: this is what a listing endpoint issues'
    );

    -- (5) THE MIRROR OF 4, because one direction could be an accident: a policy
    -- mis-scoped so that alpha happens to see everything and beta happens to see
    -- nothing is still one broken direction.
    perform anywaye.begin_account(pg_temp.anywaye_beta());
    perform pg_temp.anywaye_assert(
      r || '/another-identity-reads-only-its-own-rows', '1',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'an unqualified read as beta must return beta''s single row: the other direction of assertion 4'
    );

    reset role;
  end loop;
end
$spine$;

-- ===========================================================================
-- THE CREDENTIAL HALF. The same dual-role shape, over the one table whose
-- access path is "find the row by a value you present and learn the account from
-- it".
--
-- WHY THIS BLOCK EXISTS AT ALL, since the spine above already proves isolation
-- and nothing here relaxes it. There is a query whose subject the RLS context
-- cannot know: the account is WHAT THE QUERY IS FOR, so it cannot also be what
-- the query is scoped BY. Measured against a real protected `api_keys` table, a
-- request presenting a scoped token reads ZERO rows and authenticates as 401
-- "not found" — the quietest possible failure, and one a green suite cannot see.
--
-- So the mechanism is `anywaye.protect_credential_table`: a fifth policy,
-- `for select`, whose qualifier is the digest the CALLER PRESENTED. Its honest
-- semantics, and every row below is one clause of it:
--
--     A resolution session may read exactly the credential row whose digest it
--     presented, and nothing else in the database.
--
-- SIX ASSERTIONS PER ROLE, and the two that matter are the ones a permissive
-- implementation fails. `resolution-cannot-browse` is satisfied by nothing except
-- a policy carrying the digest predicate: an implementation whose policy said
-- "a credential session may select this table" would return BOTH rows here and
-- hand the caller a table-wide SELECT to browse every key with.
-- `resolution-does-not-open-another-table` is satisfied by nothing except a
-- mechanism scoped to the one table: a bypass role or a table-wide predicate
-- would return probe_things' rows from inside the resolution session, which is
-- precisely the "quietly becomes a general bypass" defect this whole directory
-- exists to prevent.
-- ===========================================================================
do $credential$
declare
  r text;
  seen text;
begin
  foreach r in array array['login', 'owner'] loop
    if r = 'login' then
      perform pg_temp.anywaye_as(current_user || '_app');
    else
      perform pg_temp.anywaye_as(current_user);
    end if;

    -- (1) NO RESOLUTION CONTEXT READS NOTHING. The fail-closed default, and the
    --     row a substrate without the mechanism satisfies — which is the whole
    --     reason the next six exist.
    perform anywaye.begin_account(null);
    perform anywaye.begin_credential(null);
    perform pg_temp.anywaye_assert(
      r || '/credential-no-context-reads-no-rows', '0',
      (select count(*)::text from pg_temp.anywaye_probe_credentials
        where token_digest = 'probe_digest_alpha'),
      'a request that has not opened a resolution must read no credential rows at all, by digest or otherwise. This is the state `identity` measured as zero rows and turned into a 401'
    );

    -- (2) A RESOLUTION BY DIGEST, WITH NO ACCOUNT IDENTITY. The packet's finding,
    --     proven, and the account is explicitly NULL throughout: this is the state
    --     a request presenting a scoped token is actually in.
    perform anywaye.begin_credential('probe_digest_alpha');
    perform pg_temp.anywaye_assert(
      r || '/credential-resolves-by-digest-with-no-account-identity', '1',
      (select count(*)::text from pg_temp.anywaye_probe_credentials
        where token_digest = 'probe_digest_alpha'),
      'a resolution by an unguessable digest must return its row with NO account identity set, because the account is what the query is for and cannot also be what it is scoped by. This is the assertion that does not exist anywhere else in this file'
    );

    -- (3) AND IT CANNOT BROWSE. The clause that makes the mechanism a resolution
    --     rather than a bypass, and the only one of the six that a policy saying
    --     "a credential session may select this table" would fail. Two fixture rows
    --     on purpose: with one, this assertion is satisfied by a table-wide SELECT.
    perform pg_temp.anywaye_assert(
      r || '/credential-resolution-cannot-browse', '1',
      (select count(*)::text from pg_temp.anywaye_probe_credentials),
      'an UNQUALIFIED read inside a resolution session must return the one row whose digest was presented and not the whole table. Policies combine permissively, so a policy that merely permitted the select would return both rows here and hand the caller every credential in the database'
    );

    -- (4) A DIGEST YOU DID NOT PRESENT RESOLVES NOTHING. The mirror of 3, because
    --     one direction can be an accident: a context that leaked the whole table
    --     would also pass a check that only looked at the row you asked for.
    perform anywaye.begin_credential(null);
    perform anywaye.begin_credential('probe_digest_beta');
    perform pg_temp.anywaye_assert(
      r || '/credential-wrong-digest-resolves-nothing', '0',
      (select count(*)::text from pg_temp.anywaye_probe_credentials
        where token_digest = 'probe_digest_alpha'),
      'a resolution session presenting BETA''s digest must not read ALPHA''s credential. The resolution is scoped by the value the caller presented, not by the fact that a resolution happened'
    );

    -- (5) IT DOES NOT OPEN ANOTHER TABLE. The other half of "not a general
    --     bypass", and the assertion a BYPASSRLS role or a table-wide predicate
    --     fails while every other row in this block passes.
    perform pg_temp.anywaye_assert(
      r || '/credential-resolution-does-not-open-another-table', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'a resolution session must read ZERO rows from every other protected table. The mechanism is a policy on ONE named table; if resolving a credential also opened account_users or assets, it would be the ambient bypass this directory exists to prevent, wearing a credential-shaped name'
    );

    -- (6) IT CANNOT WRITE. The resolve policy is `for select` and nothing else, so
    --     a resolution session meets the ordinary write policies, whose `with
    --     check` still demands an account identity. Measured as 42501 by
    --     `anywaye_observed` rather than asserted as a shape: "the mechanism has no
    --     write half" is a claim about a catalog, and the catalog is not the only
    --     way to be wrong.
    --
    --     `anywaye_observed` is SECURITY INVOKER, so the statement runs as
    --     whatever role this loop iteration is already set to — which is the only
    --     way to measure this: a SECURITY DEFINER recorder would run it as the
    --     owner, and the owner half would be reported as the login half's answer.
    --
    --     Run last in the loop, so the row this makes cannot perturb a count that
    --     has not been taken yet. Under FORCE it makes none: the insert is refused.
    seen := pg_temp.anywaye_observed(
      'insert into pg_temp.anywaye_probe_credentials (account_id, token_digest) values ('''
      || pg_temp.anywaye_alpha()::text || ''', ''probe_digest_minted'')');
    perform pg_temp.anywaye_assert(
      r || '/credential-cannot-write-in-a-resolution-context', '42501', seen,
      'a resolution session must be unable to MINT a credential. The resolve policy is `for select` and no write counterpart exists, so the insert meets the ordinary `with check` and a NULL identity is refused. A mechanism that could write while resolving is how a lookup becomes a factory'
    );

    reset role;
  end loop;
end
$credential$;

-- The AUDIT, once, as the session's own role: which tables in this database can
-- be read with no account, and by which column. A resolution path whose scope is
-- only knowable by reading the source is an ambient path with a good name.
--
-- The expected value names the credential fixture AND ITS COLUMN, and the
-- aggregate is over the whole database — so an implementation that reported
-- nothing, or that also reported the non-credential fixture, fails here.
select pg_temp.anywaye_assert(
  'credential/the-mechanism-is-auditable', 'anywaye_probe_credentials:token_digest',
  (select string_agg(table_name || ':' || digest_column, ',' order by table_name)
     from anywaye.credential_tables()),
  'anywaye.credential_tables() must name every table carrying a credential resolution path, and the column each one resolves by. It reads the POLICIES rather than a list, so it cannot be satisfied by a mechanism that records nothing; and it is the only audit this mechanism claims — the digest is transaction-local, so WHO resolved is not auditable here and is not claimed'
);

-- The resolve policy is written like every other policy in this file, and neither
-- property is visible in what it returns.
select pg_temp.anywaye_assert(
  'credential/resolve-policy-names-the-roles', '0',
  (select count(*)::text
     from pg_policy p
    where p.polrelid = 'pg_temp.anywaye_probe_credentials'::regclass
      and p.polname = 'anywaye_probe_credentials_anywaye_resolve'
      and (p.polroles = '{0}'::oid[]
           or not (p.polroles @> ARRAY[
                 (select oid from pg_roles where rolname = current_user || '_app')::oid,
                 (select oid from pg_roles where rolname = current_user)::oid
               ]::oid[]))),
  'the credential resolve policy must name the login role and the owner explicitly, exactly as the four account policies do. A policy left at the default is TO PUBLIC, which evaluates it for every role on the cluster'
);

select pg_temp.anywaye_assert(
  'credential/resolve-policy-is-written-for-the-init-plan', '0',
  (select count(*)::text
     from pg_policy p
    where p.polrelid = 'pg_temp.anywaye_probe_credentials'::regclass
      and p.polname = 'anywaye_probe_credentials_anywaye_resolve'
      and strpos(
            replace(replace(replace(
              lower(coalesce(pg_get_expr(p.polqual, p.polrelid), '')),
              ' ', ''), E'\n', ''), E'\t', ''),
            '(select') = 0),
  'the credential resolve policy must wrap the digest call in (select …) like every other policy here, for the reason the account policies do: one evaluation per statement against one per candidate row'
);

-- ===========================================================================
-- THE MEMBERSHIP HALF. The same dual-role shape, over the one table whose subject
-- is the CALLER rather than a row.
--
-- WHY THIS BLOCK EXISTS, and it is the opposite reason from the credential half.
-- `protect_credential_table` opens a path that would otherwise be closed and
-- had to be closed. `protect_membership_table` does not open anything the
-- substrate permitted: before it, `protect_membership_table`'s table was closed
-- CORRECTLY, and "which accounts am I in" had no way to be asked. Nothing denied
-- it, so no denial was ever reported. The three scopes are not three versions of
-- one mechanism; they are three answers to three different questions, and only
-- two of them are denials.
--
-- Its honest semantics, and every row below is one clause of it:
--
--     A caller may read exactly the membership rows naming them, with no account
--     identity, and nothing else in the database.
--
-- SIX ASSERTIONS PER ROLE, mirroring the credential block deliberately: the same
-- loop, the same order, the same fail-closed first row. Two are the ones a
-- permissive implementation fails. `discovery-cannot-browse` is satisfied by
-- nothing except a policy carrying the user predicate — one that merely
-- permitted the select would return THREE rows where two are correct, and hand a
-- signed-in person the membership table of the whole fleet. And
-- `discovery-cannot-write` is the half that keeps this from being an
-- authorisation: knowing WHICH accounts you are in is not the ability to change
-- who is in them.
-- ===========================================================================
do $membership$
declare
  r text;
  seen text;
begin
  foreach r in array array['login', 'owner'] loop
    if r = 'login' then
      perform pg_temp.anywaye_as(current_user || '_app');
    else
      perform pg_temp.anywaye_as(current_user);
    end if;

    -- (1) NO CALLER CONTEXT READS NOTHING. The fail-closed default, and what a
    --     substrate with `protect_table` alone already satisfies — which is why
    --     the defect this block exists for produced no red anywhere.
    perform anywaye.begin_account(null);
    perform anywaye.begin_user(null);
    perform pg_temp.anywaye_assert(
      r || '/membership-no-user-context-reads-no-rows', '0',
      (select count(*)::text from pg_temp.anywaye_probe_memberships
        where user_id = pg_temp.anywaye_member_one()),
      'a request that has named no user must read no membership rows at all, by user id or otherwise. This is the state `identity` was in for every caller, and the reason the product screen said "you are not a member of any account"'
    );

    -- (2) A DISCOVERY, WITH NO ACCOUNT IDENTITY. The assertion that does not
    --     exist anywhere else in this file, and the one whose absence is the
    --     whole bug: the account is what this query is FOR, so it cannot also be
    --     what the query is scoped by.
    perform anywaye.begin_user(pg_temp.anywaye_member_one());
    perform pg_temp.anywaye_assert(
      r || '/membership-discovers-accounts-with-no-account-identity', '2',
      (select count(*)::text from pg_temp.anywaye_probe_memberships
        where user_id = pg_temp.anywaye_member_one()),
      'a signed-in person must be able to find the accounts they belong to with NO account identity set, because they are not standing in an account yet — that is what makes them a caller rather than a tenant. This is the assertion that does not exist anywhere else in this file'
    );

    -- (3) AND IT CANNOT BROWSE. The clause that makes the mechanism a discovery
    --     rather than a bypass. Member one is in TWO accounts on purpose: with
    --     one membership each, "my rows" and "the table" would be the same set
    --     and this assertion would be satisfied by a table-wide SELECT.
    perform pg_temp.anywaye_assert(
      r || '/membership-discovery-cannot-browse', '2',
      (select count(*)::text from pg_temp.anywaye_probe_memberships),
      'an UNQUALIFIED read inside a discovery must return the two rows naming this caller and not the third, which names somebody else. Policies combine permissively, so a policy that merely permitted the select would return all three and hand a signed-in person every membership in the database'
    );

    -- (4) SOMEBODY ELSE'S MEMBERSHIPS RESOLVE NOTHING. The mirror of 3, because
    --     one direction can be an accident: a context that leaked the whole table
    --     would also pass a check that only looked at the rows you asked for.
    perform anywaye.begin_user(pg_temp.anywaye_member_two());
    perform pg_temp.anywaye_assert(
      r || '/membership-another-user-resolves-nothing', '0',
      (select count(*)::text from pg_temp.anywaye_probe_memberships
        where user_id = pg_temp.anywaye_member_one()),
      'a caller named by MEMBER TWO must not read MEMBER ONE''s memberships. Discovery is scoped by the identity the caller was resolved to, not by the fact that a discovery happened — which is what a predicate of the form "a user context may select this table" would get wrong'
    );

    -- (5) IT DOES NOT OPEN ANOTHER TABLE. The other half of "not a general
    --     bypass", and the assertion a BYPASSRLS role or a table-wide predicate
    --     fails while every other row in this block passes.
    perform pg_temp.anywaye_assert(
      r || '/membership-discovery-does-not-open-another-table', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'a discovery session must read ZERO rows from every other protected table. The mechanism is a policy on ONE named table; if naming the caller also opened `assets` or `api_keys`, it would be the ambient bypass this directory exists to prevent, wearing a membership-shaped name'
    );

    -- (6) AND IT STILL CANNOT WRITE. The half that keeps discovery from being
    --     authorisation. The discover policy is `for select` and no write
    --     counterpart exists, so an insert still meets the ordinary `with
    --     check` — and the account identity is null here on purpose, because the
    --     failure this guards against is a service that begins a transaction,
    --     names the user to get its accounts list, and then assumes the table is
    --     open.
    --
    --     Measured as 42501 by `anywaye_observed` rather than asserted as a
    --     shape, for the reason the credential half's row 6 gives. Run last in
    --     the loop so the row it makes cannot perturb a count not yet taken.
    seen := pg_temp.anywaye_observed(
      'insert into pg_temp.anywaye_probe_memberships (account_id, user_id, role) values ('''
      || pg_temp.anywaye_alpha()::text || ''', '''
      || pg_temp.anywaye_member_one()::text || ''', ''owner'')');
    perform pg_temp.anywaye_assert(
      r || '/membership-discovery-cannot-write', '42501', seen,
      'naming yourself must not let you add yourself to an account. The discover policy is `for select` with no write counterpart, so the insert meets the ordinary `with check` and a NULL account identity is refused. Being able to see which accounts you are in is not the ability to change who is in them'
    );

    reset role;
  end loop;
end
$membership$;

-- The AUDIT, once, as the session's own role: which tables in this database can
-- be read with no account because of WHO IS ASKING, and by which column. A
-- discovery path whose scope is only knowable by reading the source is an ambient
-- path with a good name — and there are now two exemptions, so one query could no
-- longer answer "can anything here be read without an account".
select pg_temp.anywaye_assert(
  'membership/the-mechanism-is-auditable', 'anywaye_probe_memberships:user_id',
  (select string_agg(table_name || ':' || user_column, ',' order by table_name)
     from anywaye.membership_tables()),
  'anywaye.membership_tables() must name every table carrying a caller-discovery path, and the column each one discovers by. It reads the POLICIES rather than a list, so it cannot be satisfied by a mechanism that records nothing, and it is deliberately NOT anywaye.credential_tables(): the two exemptions are different claims, and one query answering both would report a membership table as resolvable by anybody who guesses a digest'
);

-- The discover policy is written like every other policy in this file, and neither
-- property is visible in what it returns.
select pg_temp.anywaye_assert(
  'membership/discover-policy-names-the-roles', '0',
  (select count(*)::text
     from pg_policy p
    where p.polrelid = 'pg_temp.anywaye_probe_memberships'::regclass
      and p.polname = 'anywaye_probe_memberships_anywaye_members'
      and (p.polroles = '{0}'::oid[]
           or not (p.polroles @> ARRAY[
                 (select oid from pg_roles where rolname = current_user || '_app')::oid,
                 (select oid from pg_roles where rolname = current_user)::oid
               ]::oid[]))),
  'the membership discover policy must name the login role and the owner explicitly, exactly as the four account policies and the credential resolve policy do. A policy left at the default is TO PUBLIC, which evaluates it for every role on the cluster'
);

select pg_temp.anywaye_assert(
  'membership/discover-policy-is-written-for-the-init-plan', '0',
  (select count(*)::text
     from pg_policy p
    where p.polrelid = 'pg_temp.anywaye_probe_memberships'::regclass
      and p.polname = 'anywaye_probe_memberships_anywaye_members'
      and strpos(
            replace(replace(replace(
              lower(coalesce(pg_get_expr(p.polqual, p.polrelid), '')),
              ' ', ''), E'\n', ''), E'\t', ''),
            '(select') = 0),
  'the membership discover policy must wrap the user call in (select …) like every other policy here, for the reason the account policies do: one evaluation per statement against one per candidate row'
);

-- ===========================================================================
-- THE WRITE SIDE. A `using` clause filters the row out and matches nothing; it
-- does not raise. "Matched zero rows" is only a proof once the row it targeted
-- is shown to be intact, so every denied write is paired with a read of that row.
-- Pairing them is the difference between an assertion and a typo.
--
-- The pairing read runs as ALPHA, not as the role that made the attempt. That is
-- not a detail: the attempt is made as beta, and beta cannot see alpha's rows at
-- all, so a read from beta returns NULL for a row that is present and correct.
-- Reading the row back as its owner is also the shape the claim has: "the denied
-- write changed nothing" is only observable by somebody who can see the row.
-- ===========================================================================
do $writes$
declare
  updated integer;
  deleted integer;
begin
  perform pg_temp.anywaye_as(current_user || '_app');
  perform anywaye.begin_account(pg_temp.anywaye_beta());

  update pg_temp.anywaye_probe_things set label = 'stolen'
    where account_id = pg_temp.anywaye_alpha();
  get diagnostics updated = row_count;
  perform pg_temp.anywaye_assert(
    'login/update-of-another-tenants-row-affects-no-rows', '0', updated::text,
    'an UPDATE aimed at another account''s rows must match nothing. It does not raise — that is the shape of a `using` denial — so the row count is the only thing that says it was refused'
  );

  delete from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_alpha();
  get diagnostics deleted = row_count;
  perform pg_temp.anywaye_assert(
    'login/delete-of-another-tenants-row-affects-no-rows', '0', deleted::text,
    'a DELETE aimed at another account''s rows must match nothing'
  );

  reset role;
  perform anywaye.begin_account(pg_temp.anywaye_alpha());

  perform pg_temp.anywaye_assert(
    'login/denied-writes-left-the-other-tenants-rows-intact', 'alpha-1,alpha-2',
    (select string_agg(label, ',' order by label)::text
       from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_alpha()),
    'both denied writes must have left the other account''s rows exactly as they were. Read back as alpha, because the role that made the attempt cannot see the rows it was aiming at'
  );

  -- ...and the attempter's own rows are still its own, which is what stops the
  -- pair above from being satisfied by a policy that refuses every write.
  perform anywaye.begin_account(pg_temp.anywaye_beta());
  perform pg_temp.anywaye_assert(
    'login/own-rows-survive-its-own-writes', 'beta-1',
    (select label::text from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_beta()),
    'the denied writes must not have disturbed the caller''s own rows'
  );

  reset role;
end
$writes$;

-- ===========================================================================
-- THE ROLE HALF. A login role that OWNS an account-scoped table can switch that
-- table's policies off, and no amount of FORCE stops it: FORCE is about the owner
-- being SUBJECT to policies, not about the owner being unable to REMOVE them.
--
-- Nothing in the catalogs reports the second thing. `relforcerowsecurity` says
-- the owner is subject to the policies; it says nothing about whether the owner
-- can delete them. So the property is asserted by ATTEMPTING it, as the login
-- role, and reading the answer off the server.
--
-- The third case here is the only cross-tenant WRITE that raises rather than
-- matching nothing: an INSERT has no existing row to filter, so its policy
-- carries only `with check`, and a mismatch is a privilege failure. 42501 is
-- `insufficient_privilege`, which is the code Postgres uses for `with check`. It
-- leaks nothing — it says the INSERT was refused, not that the account exists.
-- ===========================================================================
do $role_half$
declare
  seen text;
begin
  perform pg_temp.anywaye_as(current_user || '_app');

  -- An INSERT naming ANOTHER account. This is the write-side twin of the read
  -- denial, and the only cross-tenant write in this file that can raise.
  seen := pg_temp.anywaye_observed(format(
    'insert into pg_temp.anywaye_probe_things (account_id, label) values (%L, %L)',
    pg_temp.anywaye_alpha()::text, 'intruder'));
  reset role;
  perform pg_temp.anywaye_assert(
    'login/insert-into-another-tenants-account-is-refused', '42501', seen,
    'an INSERT naming another account must be refused outright. There is no `using` on an INSERT, so `with check` is the whole boundary, and this is the only cross-tenant write that can raise rather than match nothing');

  perform pg_temp.anywaye_as(current_user || '_app');
  seen := pg_temp.anywaye_observed(
    'alter table pg_temp.anywaye_probe_things disable row level security');
  reset role;
  perform pg_temp.anywaye_assert(
    'login-role/cannot-disable-row-level-security', '42501', seen,
    'the login role must be REFUSED the ability to switch the boundary off. No catalog can report this, and it is the whole reason the login role owns nothing: a role that could disable RLS would need no privilege at all to become unbounded');

  perform pg_temp.anywaye_as(current_user || '_app');
  seen := pg_temp.anywaye_observed(
    'drop policy anywaye_probe_things_anywaye_select on pg_temp.anywaye_probe_things');
  reset role;
  perform pg_temp.anywaye_assert(
    'login-role/cannot-drop-a-policy', '42501', seen,
    'the login role must be REFUSED the ability to remove a policy. A role that could drop a policy needs no privilege at all to become unbounded, and there is no FORCE against it');
end
$role_half$;

select pg_temp.anywaye_assert(
  'login-role/is-not-the-table-owner', 'true',
  (select (pg_get_userbyid(c.relowner) <> current_user || '_app')::text
     from pg_class c where c.oid = 'pg_temp.anywaye_probe_things'::regclass),
  'the login role must not own the table. The two refusals above are the only thing standing between it and every account''s rows, and FORCE does not provide them'
);

-- ...and its positive counterpart, because "every insert is refused" is also a
-- state that passes a denial test. Run last, so the INSERT it makes is the one
-- row the count below is looking for.
do $insert_ok$
begin
  perform pg_temp.anywaye_as(current_user || '_app');
  perform anywaye.begin_account(pg_temp.anywaye_beta());
  insert into pg_temp.anywaye_probe_things (account_id, label)
  values (pg_temp.anywaye_beta(), 'beta-2');
  perform pg_temp.anywaye_assert(
    'login/insert-into-its-own-account-is-allowed', '1',
    (select count(*)::text from pg_temp.anywaye_probe_things where label = 'beta-2'),
    'an INSERT into the caller''s own account must succeed. Without this, the refusal above is satisfied by a policy that refuses every write, which is a state a service reaches by accident when a `with check` is written against the wrong column');
  reset role;
end
$insert_ok$;

-- ===========================================================================
-- THE POLICY SHAPE. Two properties no denial above can see, because both are
-- about how the policies are WRITTEN rather than about what they return.
-- ===========================================================================

-- Supabase's guide's first rule, and the one everybody skips: name the roles in
-- the policy. An unnamed policy is `TO PUBLIC`, which means it is evaluated for
-- every role on the cluster including the nine other services'.
select pg_temp.anywaye_assert(
  'policies/name-the-roles', '0',
  (select count(*)::text
     from pg_policy p
    where p.polrelid = 'pg_temp.anywaye_probe_things'::regclass
      and (p.polroles = '{0}'::oid[]
           or not (p.polroles @> ARRAY[
                 (select oid from pg_roles where rolname = current_user || '_app')::oid,
                 (select oid from pg_roles where rolname = current_user)::oid
               ]::oid[]))),
  'every policy must name the login role and the owner explicitly. A policy left at the default is TO PUBLIC, which evaluates it for every role on the cluster'
);

-- THE `(select ...)` WRAPPING, asserted structurally because it cannot be
-- asserted by a denial: a bare call and a wrapped call return exactly the same
-- rows. The measured difference is in how many times the function runs — 1 versus
-- 5 on five rows, re-measured on every run of tests/tenancy_test.sh.
--
-- The rendering is normalised the way Supabase's own permissive-policy lint
-- normalises it (strip spaces, newlines and tabs, lowercase) because `pg_get_expr`
-- is a pretty-printer and its output is not a stable string.
select pg_temp.anywaye_assert(
  'policies/written-for-the-init-plan', '0',
  (select count(*)::text
     from pg_policy p
    where p.polrelid = 'pg_temp.anywaye_probe_things'::regclass
      and strpos(
            replace(replace(replace(
              lower(coalesce(pg_get_expr(p.polqual, p.polrelid), '')
                     || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')),
              ' ', ''), E'\n', ''), E'\t', ''),
            '(select') = 0),
  'every policy qualifier must wrap the identity call in (select …). A bare call is re-evaluated per candidate row and a subquery is hoisted into an InitPlan and evaluated once per statement: measured on this kit, one call against five on a five-row table'
);

-- ===========================================================================
-- THE SWEEP, AND ITS CONTROL.
-- ===========================================================================

-- The control. Without it, an empty sweep is satisfied by a sweep that reports
-- nothing, which is the same shape as an isolation test that only asserts "no
-- identity reads zero rows".
select pg_temp.anywaye_assert(
  'sweep/names-an-unprotected-table', '1',
  (select count(*)::text from anywaye.unprotected_tables()
    where table_name = 'anywaye_probe_unprotected'),
  'anywaye.unprotected_tables() must actually report a table with an account_id column and no policies. If it does not, the assertion below is satisfied by a sweep that reports nothing at all'
);

-- The sweep itself, over the schemas THE SUBSTRATE OWNS: every schema holding a
-- table `anywaye.protect_table` protected, plus the `anywaye` schema and this
-- session's temporary one. This is the assertion that keeps a service honest as
-- it grows: a table added next month with an account_id column and no policies,
-- IN A SCHEMA THE SERVICE ALREADY USES, is named here on the next run.
--
-- NOT the whole database, and the difference is measured rather than argued.
-- identity's test helper builds a private fixture schema per test by cloning
-- tables with `LIKE … INCLUDING ALL`, and `LIKE` does not copy row-level
-- security — so every fixture carries an `account_id` column and no policies, and
-- a whole-database sweep named all of them: a correct database, a red proof, and
-- a count that moved with how many neighbouring tests were mid-flight (5 on one
-- run, 21 on the next). The scope is the substrate's own, because the property
-- this asserts is about the tables the SERVICE INSTALLED. See the block above
-- `anywaye.unprotected_tables()` in substrate.sql for why the scope is derived
-- from the catalog rather than recorded in a table this file's adopters would
-- have had to migrate first.
select pg_temp.anywaye_assert(
  'sweep/every-account-scoped-table-is-protected', '1',
  (select count(*)::text from anywaye.unprotected_tables()),
  'every account-scoped table in every schema the substrate was applied in must be enabled, FORCED and carrying policies. Exactly one is expected to be reported: the control table this file created on purpose'
);

-- `with order by` rather than trusting the sweep's own `order by` to survive the
-- trip. The expected value below is a string, and a string built from an
-- unordered aggregate is a red on a correct database whenever the planner is in
-- a different mood — which is the same class of defect as an assertion whose
-- tolerance hides another tenant's rows.
select pg_temp.anywaye_assert(
  'sweep/the-only-finding-is-the-control', 'anywaye_probe_unprotected:row level security is not enabled',
  (select string_agg(table_name || ':' || why, ',' order by table_schema, table_name)
     from anywaye.unprotected_tables()),
  'the sweep must name the control table and nothing else, with a reason. A sweep that reported a real table as well would mean this file''s own fixture was not protected'
);

-- ---------------------------------------------------------------------------
-- The result. `on commit drop` on the table above means a session that commits
-- takes it with it; this file leaves the transaction open so a caller can read
-- these rows first.
-- ---------------------------------------------------------------------------
select assertion, expected, actual, verdict, why
  from pg_temp.anywaye_probe_result
 order by assertion;