
begin;

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

create or replace function pg_temp.anywaye_as(p_role text)
returns void
language plpgsql
as $fn$
begin
  execute format('set local role %I', p_role);
end
$fn$;

create or replace function pg_temp.anywaye_alpha() returns uuid
language sql immutable as $fn$ select '11111111-1111-1111-1111-111111111111'::uuid $fn$;

create or replace function pg_temp.anywaye_beta() returns uuid
language sql immutable as $fn$ select '22222222-2222-2222-2222-222222222222'::uuid $fn$;

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

create temp table anywaye_probe_things (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  label text not null
) on commit drop;

insert into anywaye_probe_things (account_id, label) values
  (pg_temp.anywaye_alpha(), 'alpha-1'),
  (pg_temp.anywaye_alpha(), 'alpha-2'),
  (pg_temp.anywaye_beta(),  'beta-1');

create temp table anywaye_probe_unprotected (
  id int primary key,
  account_id uuid not null
) on commit drop;

select anywaye.protect_table('pg_temp.anywaye_probe_things');

create temp table anywaye_probe_credentials (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  token_digest text not null
) on commit drop;

insert into anywaye_probe_credentials (account_id, token_digest) values
  (pg_temp.anywaye_alpha(), 'probe_digest_alpha'),
  (pg_temp.anywaye_beta(),  'probe_digest_beta');

select anywaye.protect_credential_table('pg_temp.anywaye_probe_credentials', 'token_digest');

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

do $spine$
declare
  r text;
begin
  foreach r in array array['login', 'owner'] loop
    if r = 'login' then
      perform pg_temp.anywaye_as(current_user || '_app');
    else
      perform pg_temp.anywaye_as(current_user);
    end if;

    perform anywaye.begin_account(null);
    perform pg_temp.anywaye_assert(
      r || '/no-identity-reads-no-rows', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'a request with no account set must see nothing at all: not one tenant, not an error, and not a hint that the table has rows'
    );

    perform anywaye.begin_account(pg_temp.anywaye_beta());
    perform pg_temp.anywaye_assert(
      r || '/another-tenants-rows-read-as-none', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_alpha()),
      'a request carrying another tenant''s VALID identity must not read that tenant''s rows. This is the assertion an unenforced table fails, and the only one that does'
    );

    perform anywaye.begin_account(pg_temp.anywaye_alpha());
    perform pg_temp.anywaye_assert(
      r || '/own-rows-are-visible', '2',
      (select count(*)::text from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_alpha()),
      'a request carrying its own identity must read its own rows. Without this, "reads zero rows" is satisfied by a policy that denies everything'
    );

    perform pg_temp.anywaye_assert(
      r || '/own-identity-reads-only-its-own-rows', '2',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'an unqualified read as alpha must return alpha''s two rows and not beta''s third: this is what a listing endpoint issues'
    );

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

    perform anywaye.begin_account(null);
    perform anywaye.begin_credential(null);
    perform pg_temp.anywaye_assert(
      r || '/credential-no-context-reads-no-rows', '0',
      (select count(*)::text from pg_temp.anywaye_probe_credentials
        where token_digest = 'probe_digest_alpha'),
      'a request that has not opened a resolution must read no credential rows at all, by digest or otherwise. This is the state `identity` measured as zero rows and turned into a 401'
    );

    perform anywaye.begin_credential('probe_digest_alpha');
    perform pg_temp.anywaye_assert(
      r || '/credential-resolves-by-digest-with-no-account-identity', '1',
      (select count(*)::text from pg_temp.anywaye_probe_credentials
        where token_digest = 'probe_digest_alpha'),
      'a resolution by an unguessable digest must return its row with NO account identity set, because the account is what the query is for and cannot also be what it is scoped by. This is the assertion that does not exist anywhere else in this file'
    );

    perform pg_temp.anywaye_assert(
      r || '/credential-resolution-cannot-browse', '1',
      (select count(*)::text from pg_temp.anywaye_probe_credentials),
      'an UNQUALIFIED read inside a resolution session must return the one row whose digest was presented and not the whole table. Policies combine permissively, so a policy that merely permitted the select would return both rows here and hand the caller every credential in the database'
    );

    perform anywaye.begin_credential(null);
    perform anywaye.begin_credential('probe_digest_beta');
    perform pg_temp.anywaye_assert(
      r || '/credential-wrong-digest-resolves-nothing', '0',
      (select count(*)::text from pg_temp.anywaye_probe_credentials
        where token_digest = 'probe_digest_alpha'),
      'a resolution session presenting BETA''s digest must not read ALPHA''s credential. The resolution is scoped by the value the caller presented, not by the fact that a resolution happened'
    );

    perform pg_temp.anywaye_assert(
      r || '/credential-resolution-does-not-open-another-table', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'a resolution session must read ZERO rows from every other protected table. The mechanism is a policy on ONE named table; if resolving a credential also opened account_users or assets, it would be the ambient bypass this directory exists to prevent, wearing a credential-shaped name'
    );

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

select pg_temp.anywaye_assert(
  'credential/the-mechanism-is-auditable', 'anywaye_probe_credentials:token_digest',
  (select string_agg(table_name || ':' || digest_column, ',' order by table_name)
     from anywaye.credential_tables()),
  'anywaye.credential_tables() must name every table carrying a credential resolution path, and the column each one resolves by. It reads the POLICIES rather than a list, so it cannot be satisfied by a mechanism that records nothing; and it is the only audit this mechanism claims — the digest is transaction-local, so WHO resolved is not auditable here and is not claimed'
);

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

    perform anywaye.begin_account(null);
    perform anywaye.begin_user(null);
    perform pg_temp.anywaye_assert(
      r || '/membership-no-user-context-reads-no-rows', '0',
      (select count(*)::text from pg_temp.anywaye_probe_memberships
        where user_id = pg_temp.anywaye_member_one()),
      'a request that has named no user must read no membership rows at all, by user id or otherwise. This is the state `identity` was in for every caller, and the reason the product screen said "you are not a member of any account"'
    );

    perform anywaye.begin_user(pg_temp.anywaye_member_one());
    perform pg_temp.anywaye_assert(
      r || '/membership-discovers-accounts-with-no-account-identity', '2',
      (select count(*)::text from pg_temp.anywaye_probe_memberships
        where user_id = pg_temp.anywaye_member_one()),
      'a signed-in person must be able to find the accounts they belong to with NO account identity set, because they are not standing in an account yet — that is what makes them a caller rather than a tenant. This is the assertion that does not exist anywhere else in this file'
    );

    perform pg_temp.anywaye_assert(
      r || '/membership-discovery-cannot-browse', '2',
      (select count(*)::text from pg_temp.anywaye_probe_memberships),
      'an UNQUALIFIED read inside a discovery must return the two rows naming this caller and not the third, which names somebody else. Policies combine permissively, so a policy that merely permitted the select would return all three and hand a signed-in person every membership in the database'
    );

    perform anywaye.begin_user(pg_temp.anywaye_member_two());
    perform pg_temp.anywaye_assert(
      r || '/membership-another-user-resolves-nothing', '0',
      (select count(*)::text from pg_temp.anywaye_probe_memberships
        where user_id = pg_temp.anywaye_member_one()),
      'a caller named by MEMBER TWO must not read MEMBER ONE''s memberships. Discovery is scoped by the identity the caller was resolved to, not by the fact that a discovery happened — which is what a predicate of the form "a user context may select this table" would get wrong'
    );

    perform pg_temp.anywaye_assert(
      r || '/membership-discovery-does-not-open-another-table', '0',
      (select count(*)::text from pg_temp.anywaye_probe_things),
      'a discovery session must read ZERO rows from every other protected table. The mechanism is a policy on ONE named table; if naming the caller also opened `assets` or `api_keys`, it would be the ambient bypass this directory exists to prevent, wearing a membership-shaped name'
    );

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

select pg_temp.anywaye_assert(
  'membership/the-mechanism-is-auditable', 'anywaye_probe_memberships:user_id',
  (select string_agg(table_name || ':' || user_column, ',' order by table_name)
     from anywaye.membership_tables()),
  'anywaye.membership_tables() must name every table carrying a caller-discovery path, and the column each one discovers by. It reads the POLICIES rather than a list, so it cannot be satisfied by a mechanism that records nothing, and it is deliberately NOT anywaye.credential_tables(): the two exemptions are different claims, and one query answering both would report a membership table as resolvable by anybody who guesses a digest'
);

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

  perform anywaye.begin_account(pg_temp.anywaye_beta());
  perform pg_temp.anywaye_assert(
    'login/own-rows-survive-its-own-writes', 'beta-1',
    (select label::text from pg_temp.anywaye_probe_things where account_id = pg_temp.anywaye_beta()),
    'the denied writes must not have disturbed the caller''s own rows'
  );

  reset role;
end
$writes$;

do $role_half$
declare
  seen text;
begin
  perform pg_temp.anywaye_as(current_user || '_app');

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


select pg_temp.anywaye_assert(
  'sweep/names-an-unprotected-table', '1',
  (select count(*)::text from anywaye.unprotected_tables()
    where table_name = 'anywaye_probe_unprotected'),
  'anywaye.unprotected_tables() must actually report a table with an account_id column and no policies. If it does not, the assertion below is satisfied by a sweep that reports nothing at all'
);

select pg_temp.anywaye_assert(
  'sweep/every-account-scoped-table-is-protected', '1',
  (select count(*)::text from anywaye.unprotected_tables()),
  'every account-scoped table in every schema the substrate was applied in must be enabled, FORCED and carrying policies. Exactly one is expected to be reported: the control table this file created on purpose'
);

select pg_temp.anywaye_assert(
  'sweep/the-only-finding-is-the-control', 'anywaye_probe_unprotected:row level security is not enabled',
  (select string_agg(table_name || ':' || why, ',' order by table_schema, table_name)
     from anywaye.unprotected_tables()),
  'the sweep must name the control table and nothing else, with a reason. A sweep that reported a real table as well would mean this file''s own fixture was not protected'
);

select assertion, expected, actual, verdict, why
  from pg_temp.anywaye_probe_result
 order by assertion;