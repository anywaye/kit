-- kit template — the ACCOUNT boundary, graded by the DATABASE.
--
--     psql "$MIGRATIONS_DATABASE_URL" -f advisor.sql
--     select * from anywaye.advisor_findings();
--
-- WHAT THIS IS. Ten rules over one function, one output shape: every finding is
-- a row carrying `(name, level, facing, categories, description, detail,
-- remediation, metadata, cache_key)`. A gate reads the rows; nothing has to parse
-- anything.
--
-- WHY IT EXISTS BESIDE `substrate.sql` AND THE SIX DRIVERS. Those three grade
-- what the templates SAY: the substrate as text, the assertion set as names, and
-- the boundary as a set of denials RUN against the cluster. None of them can see
-- a policy whose predicate is `true`, because a permissive predicate returns rows
-- and a denial cannot tell "permitted by the predicate" from "permitted by
-- accident". Nor can a file scanner see that two permissive policies on the same
-- (table, role, command) combine with OR. This file grades the LIVE DATABASE, and
-- that is the only layer that can see either.
--
-- TEN RULES, numbered 1-9 plus a 7b, and the numbering is where the ORDER of
-- the findings is and not anything else. The shape is taken from Supabase's
-- database advisor (`pg-meta`'s `studio/advisor/lints.ts`), which is where the
-- row-per-rule union-all query and the nine-column output come from. NOTHING is
-- copied from it: it is MIT-licensed and its own rule is that an adopter must not
-- vendor it, and this repository's rule is that nothing in `reference/` is ever
-- copied in. Every query below was written against this fleet's catalogs, and
-- every one that had to differ says so at the point of the difference.
--
--   1. `policy_exists_rls_disabled`              ERROR   policies, no ENABLE
--   2. `rls_disabled_in_public`                   ERROR   no RLS on a table the API reaches
--   3. `rls_policy_always_true`                   WARN    a permissive predicate that is always true
--   4. `rls_references_user_metadata`             ERROR   an authorization input the caller can edit
--   5. `multiple_permissive_policies`             WARN    >1 permissive policy per (table, role, command)
--   6. `login_role_security_definer_executable`   WARN    SECURITY DEFINER the login role can run
--   7. `auth_rls_initplan`                        WARN    an identity call not wrapped for the InitPlan
--   7b. `rls_policy_correlated_membership`         WARN    an IN (SELECT) correlated to the policy's row
--   8. `rls_enabled_no_policy`                    INFO    RLS on, no policy: the table is unreadable
--   9. `security_definer_view`                    ERROR   a view that enforces its owner's RLS
--
--   TWO OF THOSE NUMBERS ARE NOT TWO RULES. Rule 6 is one rule here and two in
-- the source (`anon_…_security_definer_function_executable` and
-- `authenticated_…`), because the distinction the source draws between "nobody
-- signed in" and "somebody signed in" has no second state in a fleet with no
-- `anon`. And rule 9 was MISSING here for the whole life of this file while
-- being present, ERROR, and category SECURITY in the source: it is
-- `security_definer_view`, and in this fleet it is not a nice-to-have, because
-- the owner of an account-scoped table is itself a NOINHERIT LOGIN role that
-- bypasses its own policies unless the table is FORCE'd. A view that enforces
-- its owner's policies is therefore a hole with nothing watching it, and the
-- whole point of adding the rule is that the hole was real and no lint in this
-- fleet could see it. See the block above rule 9 for the whole argument.
--
--   Rule 8 is the source's `rls_enabled_no_policy`, which is kept because it is
-- the AVAILABILITY half of the boundary and costs one union arm: a table with
-- RLS enabled and no policy denies every row to every role, which is fail-closed
-- and therefore not a security hole, and is also how a migration fails at 3am
-- rather than in review. It is INFO, not ERROR, and the proof in
-- `tests/tenancy_test.sh` asserts zero ERROR/WARN rows precisely so that an INFO
-- here is visible without being a failure.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS MAPPED, AND WHAT WAS DROPPED. Every substitution is here, not in a
-- separate table, because a rule whose mapping lives somewhere else is a rule
-- whose mapping is out of date.
--
--   `anon` and `authenticated`  ->  ANY NON-OWNER LOGIN ROLE. Supabase has two
--       fixed roles fronting PostgREST, so its rules can name them. kit has
--       `<service>_app`: a per-service LOGIN that owns nothing, is not a
--       superuser, and is the role every request authenticates as. The
--       distinction the source draws between "anonymous" and "signed in"
--       collapses here, which is why rules 2 and 6 are one rule each rather than
--       two: there is no role in this substrate that is not a signed-in caller.
--       That is a real difference and it is a narrowing — a role that is not
--       LOGIN, or is a superuser, or holds BYPASSRLS, is outside both rules
--       exactly as it is outside the source's.
--
--   `pgrst.db_schemas`          ->  `p_schemas`, the argument. PostgREST declares
--       which schemas it exposes in a GUC; kit has no PostgREST, and the honest
--       equivalent is "the schemas this service actually uses", which is a
--       decision rather than a setting. So the scope is an ARGUMENT, and a NULL
--       means the whole database minus the catalog schemas. A caller that means
--       "everything" gets it, and a caller that means "my own tables" says so.
--
--   `auth.uid()`, `auth.jwt()`, `auth.role()`, `auth.email()`  ->
--       `anywaye.current_account_id()` and `anywaye.current_credential_digest()`.
--       These are the substrate's two documented identity seams. Rule 7 looks for
--       an unwrapped call to either, plus a bare `current_setting(`, which is
--       the third of the three the substrate exists to remove.
--
--   `auth.jwt() -> 'user_metadata'`  ->  rule 4, and it is the mapping that
--       changed most (see the block above that rule).
--
--   `pg_policies`  ->  `pg_policy` + `pg_get_expr()`. The source's rules 3 and 4
--       read Supabase's `pg_policies` view, which is a MATERIALIZED VIEW their
--       platform refreshes. Plain Postgres has no such view and no refresh job,
--       so both arms read `pg_policy` and render the expressions with
--       `pg_get_expr`. That is not a translation detail: a materialized view is
--       a cache, and a rule that reads a cache reports what the cache last saw.
--
--   DROPPED, with the reason: `facing` is `INTERNAL` on every row rather than
--       `EXTERNAL`. Supabase's value means "this finding is about the surface
--       PostgREST exposes"; kit exposes no such surface, and a constant column
--       that is always the same value is a column nobody reads.
--
--   DROPPED: the source's per-row `remediation` is a documentation URL. kit
--       ships no URL for a template it hands out, so `remediation` carries the
--       SQL that fixes the finding and the file that explains it. A remediation
--       a caller cannot execute without a second lookup is a second lookup.
--
--   DROPPED: the source's `cache_key` is an opaque string for their dashboard to
--       deduplicate with. Here it is the same string, and it is kept because it
--       is the one column that is stable across runs — so a gate can diff two
--       runs by it. It is not needed to read a finding and it is not decoration.



create or replace function anywaye.advisor_findings(
  p_schemas text[] default null
)
returns table (
  name        text,
  level       text,
  facing      text,
  categories  text[],
  description text,
  detail      text,
  remediation text,
  metadata    jsonb,
  cache_key   text
)
language sql
stable
as $advisor$
with
scoped as (
  select n.nspname
  from pg_namespace n
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname !~ '^pg_'
    and (p_schemas is null or n.nspname = any (p_schemas))
),

api_roles as (
  select r.oid, r.rolname
  from pg_roles r
  where r.rolcanlogin
    and not r.rolsuper
    and not r.rolbypassrls
    and r.rolname !~ '^pg_'
),

policies as (
  select n.nspname,
         c.relname,
         c.oid as reloid,
         p.oid as policy_oid,
         c.relrowsecurity,
         p.polname,
         p.polcmd,
         p.polpermissive,
         p.polroles,
         pg_get_expr(p.polqual, p.polrelid)          as qual,
         pg_get_expr(p.polwithcheck, p.polrelid)     as with_check
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and d.objid is null
),

policy_roles as (
  select p.*, r.rolname
  from policies p
  join api_roles r
    on p.polroles @> array[r.oid]
    or p.polroles = array[0::oid]
),

policy_cmds as (
  select pr.*, act.cmd
  from policy_roles pr
  cross join lateral unnest(
    case pr.polcmd
      when 'r' then array['SELECT']
      when 'a' then array['INSERT']
      when 'w' then array['UPDATE']
      when 'd' then array['DELETE']
      when '*' then array['SELECT', 'INSERT', 'UPDATE', 'DELETE']
      else array['ERROR']
    end
  ) as act(cmd)
),

substrate_written as (
  select pc.*,
         (pc.qual ~* '^\s*\(?account_id = \(\s*select (anywaye\.)?current_account_id\(\)'
            or pc.qual ~* '^\s*\(?[a-z_][a-z0-9_$]* = \(\s*select (anywaye\.)?current_credential_digest\(\)'
            or pc.qual ~* '^\s*\(?[a-z_][a-z0-9_$]* = \(\s*select (anywaye\.)?current_user_id\(\)') as substrate_written
  from policy_cmds pc
),

policy_once as (
  select p.*,
         (select coalesce(array_agg(distinct r.rolname order by r.rolname), array[]::text[])
            from api_roles r
           where p.polroles @> array[r.oid]
              or p.polroles = array[0::oid]) as roles
  from policies p
),
normalized as (
  select po.*,
         replace(replace(replace(lower(coalesce(po.qual, '')), ' ', ''), e'\n', ''), e'\t', '')          as n_qual,
         replace(replace(replace(lower(coalesce(po.with_check, '')), ' ', ''), e'\n', ''), e'\t', '') as n_check
  from policy_once po
),

policy_reaches as (
  with recursive reached(policy_oid, ref_class, ref_oid, depth, through_proc) as (
      select p.policy_oid, d.refclassid, d.refobjid, 1, null::oid
      from policies p
      join pg_depend d
        on d.classid     = 'pg_policy'::regclass
       and d.objid       = p.policy_oid
       and d.refclassid in ('pg_class'::regclass, 'pg_proc'::regclass)
       and not (d.refclassid = 'pg_class'::regclass and d.refobjid = p.reloid)
    union
      select r.policy_oid, d.refclassid, d.refobjid, r.depth + 1, r.ref_oid
      from reached r
      join pg_depend d
        on d.classid     = 'pg_proc'::regclass
       and d.objid       = r.ref_oid
       and d.refclassid = 'pg_class'::regclass
      where r.ref_class = 'pg_proc'::regclass
        and r.depth < 16
  )
  select policy_oid,
         ref_oid as dep_oid,
         min(depth) as depth,
         (array_agg(distinct through_proc) filter (where through_proc is not null))[1] as via_func
  from reached
  where ref_class = 'pg_class'::regclass
  group by policy_oid, ref_oid
),

views as (
  select v.oid as view_oid,
         n.nspname,
         v.relname,
         own.rolname as owner,
         v.reloptions,
         not exists (
           select 1
           from unnest(coalesce(v.reloptions, '{}'::text[])) as opt
           where opt ~* '^security_invoker\s*=\s*(true|on|1)$'
         ) as is_definer,
         exists (select 1 from unnest(coalesce(v.reloptions, '{}'::text[])) as opt
                 where opt ~* '^security_invoker\s*=\s*(false|off|0)$') as security_invoker_false
  from pg_class v
  join pg_namespace n on n.oid = v.relnamespace
  join scoped s on s.nspname = n.nspname
  join pg_roles own on own.oid = v.relowner
  where v.relkind = 'v'
    and not exists (select 1 from pg_depend ve
                     where ve.classid = 'pg_class'::regclass
                       and ve.objid = v.oid
                       and ve.deptype = 'e')
),

view_reads as (
  with recursive reached(view_oid, rel_oid, depth) as (
      select w.view_oid, t.oid, 1
      from views w
      join pg_rewrite rw on rw.ev_class = w.view_oid
      join pg_depend d
        on d.classid = 'pg_rewrite'::regclass
       and d.objid = rw.oid
       and d.refclassid = 'pg_class'::regclass
      join pg_class t on t.oid = d.refobjid
      where t.relkind in ('r', 'p', 'v', 'm')
        and t.oid <> w.view_oid
    union
      select r.view_oid, t.oid, r.depth + 1
      from reached r
      join views mid on mid.view_oid = r.rel_oid
      join pg_rewrite rw on rw.ev_class = r.rel_oid
      join pg_depend d
        on d.classid = 'pg_rewrite'::regclass
       and d.objid = rw.oid
       and d.refclassid = 'pg_class'::regclass
      join pg_class t on t.oid = d.refobjid
      where t.relkind in ('r', 'p', 'v', 'm')
        and t.oid <> r.view_oid
        and mid.is_definer
        and r.depth < 16
  )
  select distinct
         w.view_oid, w.nspname, w.relname, w.owner, w.is_definer,
         w.reloptions, w.security_invoker_false,
         t.oid as table_oid, tn.nspname as table_schema, t.relname as table_name,
         t.relkind in ('r', 'p') as is_table,
         t.relrowsecurity
  from views w
  join reached rr on rr.view_oid = w.view_oid
  join pg_class t on t.oid = rr.rel_oid
  join pg_namespace tn on tn.oid = t.relnamespace
),

rule_policies_rls_disabled as (
  select 'policy_exists_rls_disabled'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security policies exist on this table but row level security is not enabled on it. Every one of those policies is inert: Postgres reads the table as unrestricted, so the policies document an intent the server is not enforcing.'::text as description,
         format('Table %I.%I has %s policy/policies and `relrowsecurity` is false, so none of them applies. Policies: %s.',
                nspname, relname, count(*)::text, array_agg(polname order by polname))::text as detail,
         format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY; then run this advisor again. If the policies were meant to be inert, drop them: an inert policy is a comment that survives refactors.', nspname, relname)::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'table',
                            'policies', array_agg(polname order by polname)) as metadata,
         format('policy_exists_rls_disabled_%s_%s', nspname, relname)::text as cache_key
  from policies
  where not relrowsecurity
  group by nspname, relname
),

rule_rls_disabled_in_public as (
  select 'rls_disabled_in_public'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security is not enabled on a table a non-owner login role can SELECT. Whatever this table holds is readable by every role that can reach the database, whatever the service intends.'::text as description,
         format('Table %I.%I has no row level security, and %s login role(s) can SELECT it: %s.',
                n.nspname, c.relname, count(*)::text,
                array_to_string(array_agg(distinct r.rolname order by r.rolname), ', '))::text as detail,
         format('If the table holds customer rows: ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY; and call anywaye.protect_table(''%I'') from its migration. If it holds none, revoke the grant that makes it reachable — the reachability is the finding, not the missing RLS.', n.nspname, c.relname, c.relname)::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', c.relname, 'type', 'table',
                            'reachable_by', array_agg(distinct r.rolname order by r.rolname)) as metadata,
         format('rls_disabled_in_public_%s_%s', n.nspname, c.relname)::text as cache_key
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  join api_roles r on has_table_privilege(r.rolname, c.oid, 'SELECT')
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and not c.relrowsecurity
    and d.objid is null
  group by n.nspname, c.relname, c.oid
),

rule_policy_always_true as (
  select 'rls_policy_always_true'::text as name,
         'WARN'::text as level,
         array['SECURITY']::text[] as categories,
         'A permissive policy qualifier that is always true, or a NULL clause on a permissive write policy. A permissive policy that always passes is the table unprotected with the appearance of a policy: the table reads as governed and the server is permitting everything.'::text as description,
         format('Policy %I on %I.%I is %s for role(s) %s and its %s always passes, so the policy does not narrow anything.%s',
                polname, nspname, relname,
                case polcmd when 'r' then 'for SELECT' when 'a' then 'for INSERT'
                            when 'w' then 'for UPDATE' when 'd' then 'for DELETE'
                            else 'for ALL' end,
                coalesce(nullif(array_to_string(roles, ', '), ''), 'no login role (this policy binds none)'),
                case when perm_using and perm_check then 'USING and WITH CHECK'
                     when perm_using then 'USING'
                     else 'WITH CHECK' end,
                case when perm_using and perm_check then ' (both clauses)'
                     when perm_using then ' (the USING clause)'
                     else ' (the WITH CHECK clause is absent on a permissive write policy)' end)::text as detail,
         format('Rewrite the qualifier so it names what the caller must hold: account_id = (select anywaye.current_account_id()) on an account-scoped table. anywaye.protect_table/2 writes that form; a hand-written `true` is the one predicate no caller can narrow.', polname)::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'roles', roles,
                            'qual', qual, 'with_check', with_check) as metadata,
         format('rls_policy_always_true_%s_%s_%s', nspname, relname, polname)::text as cache_key
  from (
    select n.*,
           (polcmd in ('w', 'd', '*')
            and (n_qual in ('true', '(true)', '1=1', '(1=1)')
                 or (qual is null and polpermissive))) as perm_using,
           (n_check in ('true', '(true)', '1=1', '(1=1)')
            or (with_check is null and polpermissive and polcmd = 'a')
            or (with_check is null and polpermissive and polcmd in ('w', '*')
                and n_qual in ('true', '(true)', '1=1', '(1=1)'))) as perm_check
    from normalized n
  ) f
  where relrowsecurity
    and polpermissive
    and (perm_using or perm_check)
),

rule_references_user_metadata as (
  select 'rls_references_user_metadata'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'A policy takes an authorization input that the caller is able to edit. `user_metadata`-style claims are writable by the subject they describe, and a predicate that consults one decides access from something the caller controls. The catalog half of this rule reads pg_depend: a policy whose expression reaches outside its own table -- directly, or through a function it calls -- into a table a login role may INSERT into or UPDATE, is flagged whatever that table is called.'::text as description,
         format('Policy %I on %I.%I reads %s%s, and a login role holds INSERT/UPDATE on it. Whatever the policy decides from those rows, the caller can change. Rendered qualifier: %s',
                p.polname, n.nspname, c.relname,
                array_to_string(array_agg(distinct dep_ns.nspname || '.' || dep_c.relname), ', '),
                coalesce(' -- through function ' || array_to_string(
                           array_agg(distinct (select pr.proname from pg_proc pr where pr.oid = prr.via_func)), ', '), ''),
                coalesce(pg_get_expr(p.polqual, p.polrelid), '(none)'))::text as detail,
         format('The identity has to arrive from somewhere the caller cannot write. anywaye.begin_account/1 carries it into a transaction-local GUC and anywaye.current_account_id() reads it; a flag table is a request, not an identity. If the qualifier reaches the table through a function, that function has to be SECURITY INVOKER: a SECURITY DEFINER helper runs with its owner''s privileges and with that owner''s exemption from these policies, which is a wider hole than the one this row is about. Deny the grant (REVOKE INSERT, UPDATE ON <that table> FROM <the login role>) and decide from the account instead.', n.nspname, c.relname)::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', c.relname, 'type', 'policy',
                            'policy_name', p.polname,
                            'reads', array_agg(distinct dep_ns.nspname || '.' || dep_c.relname),
                            'via_functions', coalesce(
                              array_agg(distinct (select pr.proname from pg_proc pr where pr.oid = prr.via_func))
                              filter (where prr.via_func is not null), array[]::text[])) as metadata,
         format('rls_references_user_metadata_%s_%s_%s', n.nspname, c.relname, p.polname)::text as cache_key
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  join policy_reaches prr on prr.policy_oid = p.oid
  join pg_class dep_c on dep_c.oid = prr.dep_oid
  join pg_namespace dep_ns on dep_ns.oid = dep_c.relnamespace
  where c.relkind = 'r'
    and dep_c.relkind = 'r'
    and exists (
      select 1 from api_roles r
      where has_table_privilege(r.rolname, dep_c.oid, 'INSERT')
         or has_table_privilege(r.rolname, dep_c.oid, 'UPDATE')
    )
  group by p.oid, p.polname, n.nspname, c.relname, pg_get_expr(p.polqual, p.polrelid)
  union all
  select 'rls_references_user_metadata'::text,
         'ERROR'::text,
         array['SECURITY']::text[],
         'A policy names a user-metadata column in its qualifier or its WITH CHECK. This half of the rule is a keyword search, which is why the source that this one is ported from admits it produces false positives: a column merely NAMED user_metadata trips it whether or not the data in it is user-editable.'::text,
         format('Policy %I on %I.%I names a user-metadata column: %s', polname, nspname, relname,
                coalesce(qual, with_check))::text,
         format('Treat the column as caller-editable input and decide from the account. If the name is a false positive, the rule says so rather than assuming it: the qualifier is above, in full.')::text,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'match', 'keyword'),
         format('rls_references_user_metadata_keyword_%s_%s_%s', nspname, relname, polname)::text
  from policies
  where lower(coalesce(qual, '') || ' ' || coalesce(with_check, ''))
          ~ 'user_metadata|raw_user_meta_data|app_metadata'
),

rule_multiple_permissive as (
  select 'multiple_permissive_policies'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE', 'SECURITY']::text[] as categories,
         'More than one PERMISSIVE policy applies to this table, role and command. Permissive policies combine with OR rather than AND, so the effective predicate is the union of all of them and each is evaluated on every relevant query — which is both a cost at scale and a wider surface than either policy reads as on its own.'::text as description,
         format('Table %I.%I has %s permissive policies for role %s for command %s. All of them: %s. Not written by the substrate: %s.',
                nspname, relname, count(*)::text, rolname, cmd,
                array_to_string(array_agg(polname order by polname), ', '),
                array_to_string(array_agg(polname order by polname) filter (where not substrate_written), ', '))::text as detail,
         format('Keep one permissive policy per role per command, and fold the conditions into it with AND. anywaye.protect_table/2 writes exactly one per command; a second policy on the same (role, command) is the OR that makes the table wider than it reads.')::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'table',
                            'role', rolname, 'command', cmd,
                            'policies', array_agg(polname order by polname),
                            'hand_written', array_agg(polname order by polname) filter (where not substrate_written)) as metadata,
         format('multiple_permissive_policies_%s_%s_%s_%s', nspname, relname, rolname, cmd)::text as cache_key
  from substrate_written
  group by nspname, relname, rolname, cmd
  having count(*) > 1
     and bool_or(not substrate_written)
),

rule_security_definer as (
  select 'login_role_security_definer_executable'::text as name,
         'WARN'::text as level,
         array['SECURITY']::text[] as categories,
         'A SECURITY DEFINER function that a non-owner login role may EXECUTE. It runs with the privileges of whoever owns it, so the capability a caller gets is the owner''s and not the caller''s — and if the owner is a table owner, it is also that table''s FORCE exemption.'::text as description,
         format('Function %I.%I(%s) is SECURITY DEFINER, is owned by %s, and %s login role(s) may EXECUTE it: %s.',
                n.nspname, p.proname,
                pg_get_function_identity_arguments(p.oid), owner.rolname,
                count(*)::text,
                array_to_string(array_agg(distinct r.rolname order by r.rolname), ', '))::text as detail,
         format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM the login roles, or declare it SECURITY INVOKER so it can only do what the caller can already do. A definer function is a privilege escalation with an argument list.', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', p.proname,
                            'arguments', pg_get_function_identity_arguments(p.oid),
                            'language', l.lanname, 'owner', owner.rolname, 'security_definer', true,
                            'executable_by', array_agg(distinct r.rolname order by r.rolname)) as metadata,
         format('login_role_security_definer_executable_%s_%s_%s', n.nspname, p.proname,
                pg_get_function_identity_arguments(p.oid))::text as cache_key
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join scoped s on s.nspname = n.nspname
  join pg_language l on l.oid = p.prolang
  join pg_roles owner on owner.oid = p.proowner
  join api_roles r on has_function_privilege(r.rolname, p.oid, 'EXECUTE')
  where p.prosecdef
    and owner.rolname !~ '^pg_'
  group by n.nspname, p.oid, p.proname, l.lanname, owner.rolname
),

rule_correlated_membership as (
  select 'rls_policy_correlated_membership'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE']::text[] as categories,
         'A policy qualifier puts an IN (SELECT …) around a subquery that references the policy''s own table, so the membership check is CORRELATED: Postgres re-evaluates it once per candidate row rather than once per statement. Measured on this kit (tests/rls_perf_test.sh): 2000 ms with the loop counter at one evaluation per candidate row, against 18 ms and a single evaluation for the same predicate with the join direction inverted — 111x, on a fixture whose membership table was indexed in both directions. Correct and slow, and invisible until the table is large.'::text as description,
         format('Policy %I on %I.%I has a correlated IN (%s%s%s). The subquery reads the policy''s own row, so it runs once per candidate row. Rendered qualifier: %s',
                polname, nspname, relname,
                case when qual_hit then 'USING' else 'WITH CHECK' end,
                case when qual_hit and check_hit then ' and WITH CHECK' else '' end,
                '',
                coalesce(qual, with_check))::text as detail,
         format('Invert which side is correlated: put the membership in the subquery''s WHERE on the CALLER, and IN the row''s own column against the result — `using (account_id in (select m.account_id from <membership> m where m.user_id = (select anywaye.current_account_id())))`. That is only expressible when this table carries the membership column locally; where it does not, filter the INNER hop instead — measured on this kit, a correlated EXISTS with its inner hop inverted ran 56 ms against the correlated IN''s 2000 ms, because the planner re-associates it into a semi-join. If the column does not exist anywhere on the path, the shape is not fixable by a rewrite: index the correlated column.', polname)::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'qual', qual, 'with_check', with_check,
                            'measured_ratio', '111x on tests/rls_perf_test.sh') as metadata,
         format('rls_policy_correlated_membership_%s_%s_%s', nspname, relname, polname)::text as cache_key
  from (
    select po.*,
           coalesce(
             exists (select 1
                       from regexp_matches(po.n_qual, '(in|=\s*any)\(([^()]|\([^()]*\))*\)', 'g') m
                      where (m[2] ~ ('(^|[^a-z0-9_$])' || po.relname || '\.')
                          or m[2] ~ ('(^|[^a-z0-9_$])' || po.nspname || '\.' || po.relname || '\.'))), false) as qual_hit,
           coalesce(
             exists (select 1
                       from regexp_matches(po.n_check, '(in|=\s*any)\(([^()]|\([^()]*\))*\)', 'g') m
                      where (m[2] ~ ('(^|[^a-z0-9_$])' || po.relname || '\.')
                          or m[2] ~ ('(^|[^a-z0-9_$])' || po.nspname || '\.' || po.relname || '\.'))), false) as check_hit
    from normalized po
  ) f
  where relrowsecurity
    and (qual_hit or check_hit)
),

rule_initplan as (
  select 'auth_rls_initplan'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE']::text[] as categories,
         'A policy qualifier calls the identity function bare, so it is re-evaluated for every candidate row instead of once per statement. Measured on this kit: one call against five, on a five-row table. Correct and slow; invisible until the table is large, which is the worst moment to find it.'::text as description,
         format('Policy %I on %I.%I calls an identity function without the (select …) wrapper. Measured on this kit, the bare form called the function once per candidate row (5 rows, 5 calls) where the wrapped form called it once. %s',
                polname, nspname, relname,
                case
                  when qual ~ 'current_setting\(' then 'unwrapped: current_setting(...)'
                  when qual ~ 'current_account_id\(\)' then 'unwrapped: anywaye.current_account_id()'
                  when qual ~ 'current_credential_digest\(\)' then 'unwrapped: anywaye.current_credential_digest()'
                  else 'unwrapped identity call'
                end)::text as detail,
         format('Rewrite it as `(... = ( select anywaye.current_account_id()))`. Only do so when the call does not depend on the row — the InitPlan is correct precisely because it is uncorrelated, so a call that reads the row must stay bare. anywaye.protect_table/2 writes the wrapped form for every policy it creates.')::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'qual', qual, 'with_check', with_check) as metadata,
         format('auth_rls_initplan_%s_%s_%s', nspname, relname, polname)::text as cache_key
  from policies
  where relrowsecurity
    and (
      (qual ~* '(anywaye\.)?current_account_id\(\)'        and qual !~* '\(\s*select\s+(anywaye\.)?current_account_id\(\)')
      or (qual ~* '(anywaye\.)?current_credential_digest\(\)' and qual !~* '\(\s*select\s+(anywaye\.)?current_credential_digest\(\)')
      or (qual ~* 'current_setting\('                       and qual !~* '\(\s*select\s+current_setting\(')
      or (with_check ~* '(anywaye\.)?current_account_id\(\)'        and with_check !~* '\(\s*select\s+(anywaye\.)?current_account_id\(\)')
      or (with_check ~* '(anywaye\.)?current_credential_digest\(\)' and with_check !~* '\(\s*select\s+(anywaye\.)?current_credential_digest\(\)')
      or (with_check ~* 'current_setting\('                       and with_check !~* '\(\s*select\s+current_setting\(')
    )
),

rule_rls_no_policy as (
  select 'rls_enabled_no_policy'::text as name,
         'INFO'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security is enabled and no policy exists, so every role is denied every row. Nothing leaks; the table is simply unreadable, which is a fail-closed outage rather than a breach.'::text as description,
         format('Table %I.%I has row level security enabled and no policy. Every SELECT on it returns no rows, including from the owner.', n.nspname, c.relname)::text as detail,
         format('Create the policies (anywaye.protect_table(''%I'')) or drop row level security from the table if it was meant to be readable.', c.relname)::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', c.relname, 'type', 'table') as metadata,
         format('rls_enabled_no_policy_%s_%s', n.nspname, c.relname)::text as cache_key
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and c.relrowsecurity
    and d.objid is null
    and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
),

rule_security_definer_view as (
  select 'security_definer_view'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'A view reads a table that has row level security, and the view is not `security_invoker`, so its queries run with the privileges of the role that owns the VIEW rather than the role that is asking. Row-level security is then evaluated against the owner, and the owner is exempt from its own policies unless the table is FORCE''d. Every policy on the underlying table is silently bypassed for anyone who can SELECT the view.'::text as description,
         format('View %I.%I (owner %s) reads %s table(s) with row level security: %s. Of %s relation(s) it reads, the rest are: %s. It is not `security_invoker` (%s). %s login role(s) can SELECT it: %s.',
                nspname, relname, owner,
                count(*) filter (where relrowsecurity),
                coalesce(string_agg(distinct table_schema || '.' || table_name, ', ') filter (where relrowsecurity), '(none)'),
                count(*)::text,
                coalesce(string_agg(distinct table_schema || '.' || table_name, ', ') filter (where not relrowsecurity), '(none)'),
                case when reloptions is null or reloptions = '{}' then 'it carries no reloptions at all'
                     else 'its reloptions are ' || array_to_string(reloptions, ', ') end,
                (select count(*)::text
                   from api_roles r
                  where has_table_privilege(r.rolname, min(view_reads.view_oid), 'SELECT')),
                coalesce((select string_agg(r.rolname, ', ' order by r.rolname)
                            from api_roles r
                           where has_table_privilege(r.rolname, min(view_reads.view_oid), 'SELECT')),
                         '(none — no login role can SELECT this view)'))::text as detail,
         case when current_setting('server_version_num')::int < 150000
              then format('This server is Postgres %s, which predates `security_invoker` (added in 15), so there is no flag that makes a view enforce the caller''s policies and this finding cannot be cleared by an ALTER. It is reported anyway, because on this version the bypass is real and unavoidable. The remedy is to stop exposing the view: GRANT SELECT on %s to the roles that need it and read the table directly, or drop the view.',
                          current_setting('server_version'),
                          coalesce(string_agg(distinct table_schema || '.' || table_name, ', ') filter (where relrowsecurity), '(none)'))
              else format('ALTER VIEW %I.%I SET (security_invoker = true); then run this advisor again. That makes the view run its queries as the caller, so the policies on %s apply to the caller rather than to the owner.',
                          nspname, relname,
                          coalesce(string_agg(distinct table_schema || '.' || table_name, ', ') filter (where relrowsecurity), '(none)'))
         end::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'view',
                            'owner', owner,
                            'security_invoker', false,
                            'reloptions', coalesce(reloptions, array[]::text[]),
                            'rls_relations', (select coalesce(array_agg(distinct vr2.table_schema || '.' || vr2.table_name
                                                    order by vr2.table_schema || '.' || vr2.table_name),
                                                   array[]::text[])
                                                from view_reads vr2
                                               where vr2.view_oid = min(view_reads.view_oid)
                                                 and vr2.relrowsecurity),
                            'all_relations', array_agg(distinct table_schema || '.' || table_name
                                                       order by table_schema || '.' || table_name)) as metadata,
         format('security_definer_view_%s_%s', nspname, relname)::text as cache_key
  from view_reads
  where is_definer
    and not security_invoker_false
  group by nspname, relname, owner, is_definer, reloptions
  having count(*) filter (where relrowsecurity) > 0
     and exists (select 1 from api_roles r
                  where has_table_privilege(r.rolname, min(view_reads.view_oid), 'SELECT'))
)

select f.name,
       f.level,
       'INTERNAL'::text as facing,
       f.categories,
       f.description,
       f.detail,
       f.remediation,
       f.metadata,
       f.cache_key
from (
  select * from rule_policies_rls_disabled
  union all select * from rule_rls_disabled_in_public
  union all select * from rule_policy_always_true
  union all select * from rule_references_user_metadata
  union all select * from rule_multiple_permissive
  union all select * from rule_security_definer
  union all select * from rule_initplan
  union all select * from rule_correlated_membership
  union all select * from rule_rls_no_policy
  union all select * from rule_security_definer_view
) f
order by f.cache_key;
$advisor$;