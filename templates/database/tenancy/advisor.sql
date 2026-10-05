-- kit template — the ACCOUNT boundary, graded by the DATABASE.
--
--     psql "$MIGRATIONS_DATABASE_URL" -f advisor.sql
--     select * from cafaye.advisor_findings();
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
-- vendor it, and this repository's rule is that nothing in `moon/refs/` is ever
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
--       `cafaye.current_account_id()` and `cafaye.current_credential_digest()`.
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

-- ---------------------------------------------------------------------------
-- THE SCOPE ARGUMENT, and the one thing to know before reading a row.
--
-- `p_schemas` filters by SCHEMA and nothing else. A NULL is the whole database
-- minus `pg_catalog`, `information_schema`, `pg_toast` and every `pg_%` schema,
-- which is the smallest exclusion that is not a list of other people's business:
-- the source excludes thirty named extension schemas, and every one of those is
-- a schema `pg_%` or `information_schema` already covers, or a schema some other
-- platform put its extensions in.
--
-- Extension-owned tables are excluded by `pg_depend.deptype = 'e'`, for the same
-- reason `substrate.sql`'s sweep excludes them and in the same words: pgvector
-- and friends ship their own tables with their own grants, and reporting a table
-- this substrate cannot protect trains the reader to ignore the report.
--
-- IT STANDS ALONE. Nothing here calls a `cafaye.*` function the substrate owns,
-- and that is deliberate rather than tidy. A checker that only exists where the
-- thing it checks has already been installed cannot find a service that has NOT
-- installed it — which is the service that needs it. So rule 5's recognition of a
-- substrate-written policy, which is the one place the substrate's own naming
-- convention appears, is inlined rather than delegated to
-- `cafaye.credential_tables()`. What is duplicated is the two PREDICATE SHAPES,
-- and the comment above each says which catalog it reads.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT FIND, because a rule that reads as a promise it cannot keep
-- is worse than no rule.
--
--   * That a policy's predicate is the RIGHT predicate. Rule 3 finds `true`;
--       nothing here can tell a policy that is subtly too wide from one that is
--       exactly right, because "right" is a property of the service's data model
--       and this function has never read it.
--
--   * That the service SETS the identity. `cafaye.begin_account/1` is one call in
--       one place. A service that never calls it reads zero rows, which is safe
--       and loud, and no rule in this file can tell it from a service whose
--       tables are empty.
--
--   * That the login role is not a MEMBER of the owner role, that the login role
--       holds no BYPASSRLS, and that the owner's FORCE is set. The last is
--       `relforcerowsecurity`, and this file has no rule for it on purpose:
--       `substrate.sql`'s sweep names it and `isolation.sql` asserts it by
--       RUNNING the denials as the owner, because a catalog reading can be
--       satisfied by a table nobody reads. One file claiming all three would
--       mean one file where a reader looks for the proof and finds a column.
--
--   * THAT ITS OWN ANSWER IS THE SAME FOR EVERY ROLE. Every rule here reads
--       `pg_get_expr`, which deparses a name unqualified whenever the READER's
--       `search_path` resolves it, so this function's findings are a function of
--       who runs it. Both spellings are accepted above, which is a mitigation and
--       not a fix: the shape `(cafaye\.)?` accepts is one narrow family, and a
--       third spelling would be missed rather than reported.
--       `substrate.sql`'s `credential_tables()` had the same defect in the worst
--       possible form — it reported NO credential table at all to the role whose
--       `"$user"` schema is `cafaye` — and it no longer does, because it resolves
--       the same facts from `pg_depend`. That function can do that here too and
--       does not: these rules are about what a predicate SAYS, and the predicate
--       `using (true)` is invisible in every dependency catalog. Closing this
--       properly means deciding what a rule claims when it cannot see the text,
--       which is a change to the RULES and not to a regexp — deliberately out of
--       scope here, and written down rather than left for a reader to infer.
--
--   * WHAT A VIEW PROJECTS. Rule 9 asks "does this view read a table that has
--       row level security", and it asks it of `pg_depend`, which records the
--       RELATION a rewrite rule reaches and not which columns it selects. So a
--       view over an account-scoped table that projects one non-account column
--       is reported exactly as loudly as one that projects the whole table. That
--       is the same trade rule 4's keyword half makes and it is kept for the
--       same reason: narrowing it means parsing `pg_get_viewdef`, and a rule
--       that reads view text has its misses where nobody is looking. The detail
--       names the tables, so the reader can make that judgement in one read.
--
--   * WHETHER THE OWNER IS ALSO THE CALLER. `pg_depend` says which relations a
--       view reaches; it does not say who could have read them directly. Rule 9
--       does not need that distinction, and the reason is this fleet's: the
--       owner of an account-scoped table IS a NOINHERIT LOGIN role that bypasses
--       its own policies unless the table is FORCE'd, so owner-is-the-caller and
--       owner-is-another-service are the same hole with a different blast
--       radius. The detail names the owner so a reader who wants the narrower
--       story has it.
--
--   * A FUNCTION BODY THAT THE CATALOG DOES NOT RECORD, and this is the one gap
--       in this file that was measured rather than reasoned about, so it is in
--       the first screen rather than in a rule's comment. Rule 4 follows a
--       policy's qualifier through a called function, and it can follow it only
--       as far as `pg_depend` goes. Measured on PostgreSQL 17.11
--       (`measure-advisor-pgproc.sql`): a `BEGIN ATOMIC` helper records
--       `pg_proc -> pg_class -> <the relation>` and rule 4 sees it; a helper
--       written `language sql` with a STRING body, and a `plpgsql` helper,
--       record NO relation at all -- the edge exists only in `prosrc`, as text.
--
--       So a `SECURITY DEFINER` helper written the ordinary way hides the table
--       it reads from this rule, and no rule in this file sees it. That is not a
--       missing regexp: catching it means matching table names in SQL TEXT,
--       which fires on a table named in a comment, on a string literal, and on a
--       table that has since been dropped -- a false-positive machine pointed at
--       the one rule an adopter trusts about who may edit what. Rule 6 still
--       fires on the helper ITSELF (`login_role_security_definer_executable`),
--       which is the honest position: something sees it, and this rule does not
--       claim to be the thing that does. A reader who needs the gap closed should
--       read `prosrc` by hand in review, not trust a scan to have done it for
--       them.

-- ---------------------------------------------------------------------------
-- rule 5's exemption, stated here because it is the only judgement in this file
-- and MD24 is the reason it exists.
--
-- MD24 gives every credential table FIVE policies: one per command from
-- `protect_table`, plus a `for select` from `protect_credential_table` whose
-- predicate is the digest the CALLER PRESENTED. So `(api_keys, alpha, SELECT)`
-- holds two permissive policies, and the source's rule reads that as a
-- performance defect. It is not a defect; it is the mechanism, and the two
-- predicates combine as
--
--     (account_id = the session's account) OR (token_digest = the digest presented)
--
-- which is exactly what MD24 says it means: your account's rows, or the one
-- credential row you named. Collapsing them into one policy would mean writing a
-- policy that ORs a digest, which is the shape `substrate.sql` argues against in
-- the comment above `protect_credential_table`.
--
-- So the rule stays at WARN and unsoftened, and the EXEMPTION is the rule's own
-- semantics rather than an allowlist of names:
--
--     a (table, role, command) group is exempt when EVERY policy in it was
--     written by the substrate.
--
-- It is an all-of condition and that is the whole design. An allowlist keyed on
-- policy NAMES (`%_cafaye_resolve`) is a ratchet: a service that renames a
-- policy gets a red it cannot fix, and a service that adds a THIRD permissive
-- policy next to the exempt two still passes. Under this exemption the substrate
-- writes FIVE policies on both of the suite's fixture tables — four from
-- `protect_table` plus the mechanism's own, all recognised, group exempt — and
-- the moment a service hand-writes a second permissive SELECT
-- on `api_keys`, the group is no longer all-of and the rule fires, naming the
-- hand-written one. That is the shape this file has to be able to reach, and the
-- fixture in `tests/tenancy_test.sh` reaches it.
--
-- There are now TWO fifth policies rather than one, and the second is the
-- membership discover policy `protect_membership_table` writes. That is the cost
-- of an all-of exemption stated honestly: every new substrate predicate has to be
-- taught to this rule, and the failure when it is not is a red against the
-- substrate's own fixture. The alternative — an allowlist of policy NAMES — has
-- the opposite failure, which is silent: a renamed policy stops being exempt and
-- nobody notices, or a hand-written policy borrows a substrate's name and is
-- exempt for ever. Recognising three FORMS is the cheaper of the two mistakes.

create or replace function cafaye.advisor_findings(
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
-- (1) THE SCOPE. An argument, not a list: see the block above.
scoped as (
  select n.nspname
  from pg_namespace n
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname !~ '^pg_'
    and (p_schemas is null or n.nspname = any (p_schemas))
),

-- (2) WHO IS AN API CALLER. Non-superuser, no BYPASSRLS, can log in, not a
--     `pg_%` role. `rolbypassrls` is excluded for the reason the source excludes
--     it: a role that bypasses policies is not subject to them, so "the policy
--     is wrong for this role" is a different finding and this is not it.
api_roles as (
  select r.oid, r.rolname
  from pg_roles r
  where r.rolcanlogin
    and not r.rolsuper
    and not r.rolbypassrls
    and r.rolname !~ '^pg_'
),

-- (3) EVERY POLICY IN SCOPE, with its expressions RENDERED.
--
--     `pg_get_expr` is a pretty-printer, not the text that was executed: the
--     substrate writes `(account_id = (select cafaye.current_account_id()))` and
--     the catalog gives back
--     `(account_id = ( SELECT cafaye.current_account_id() AS current_account_id))`
--     — its own capitalisation, spacing and generated alias. Every regexp below
--     is written against the RENDERED form, and a regexp written against the
--     executed form matches nothing here and looks for ever afterwards like a
--     rule that found nothing.
--
--     AND THE SCHEMA QUALIFICATION IN THAT OUTPUT IS NOT FIXED, which is a
--     measurement rather than a caveat. `pg_get_expr` drops the schema from a
--     name the READER can resolve, and what the reader can resolve is their
--     `search_path`. Measured on this kit, reading the same policy twice:
--
--         as role `alpha`   search_path = "$user", public   ($user = a schema
--                           named `alpha`, which does not exist)
--                             -> (account_id = ( SELECT cafaye.current_account_id() …))
--
--         as role `cafaye`  search_path = "$user", public   ($user = a schema
--                           named `cafaye`, which DOES exist)
--                             -> (account_id = ( SELECT current_account_id() …))
--
--     `"$user"` is the whole mechanism, and it means the cluster's own admin
--     role — the one named after the platform — reads the substrate's policies in
--     the short form.
--
--     So every regexp below accepts BOTH forms, and the comment says why rather
--     than leaving `(cafaye\.)?` looking like sloppiness. Requiring the qualified
--     form alone makes rule 5 report MD24's credential policy as a hand-written
--     one to exactly the reader least likely to know why, and makes rule 7
--     silently miss a bare call for the same reader. A rule that is blind under
--     one search_path is the defect this comment exists to prevent.
--
--     `substrate.sql`'s `credential_tables()` had exactly this defect and no
--     longer has it: it read a regexp over this text and returned NOTHING to the
--     `cafaye` role while returning everything to `alpha`, which is an audit
--     telling the cluster's own admin role that this database holds no credential
--     path. It now resolves the same two facts from `pg_depend` — OIDs rather
--     than spelling — and `tests/tenancy_test.sh` asserts all three roles get one
--     answer. THIS FILE STILL READS THE TEXT, because every rule here is about
--     what a predicate SAYS (`using (true)` is a predicate no dependency catalog
--     records as anything but a boolean), so `(cafaye\.)?` stays and the residual
--     limitation is listed under "what this does not find" rather than left for a
--     reader to infer.
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

-- (4) ONE ROW PER (POLICY, ROLE). `polroles = '{0}'` means PUBLIC and is
--     expanded to every API role, which is what makes a `to public` policy
--     group with each caller rather than sitting in a bucket of its own.
policy_roles as (
  select p.*, r.rolname
  from policies p
  join api_roles r
    on p.polroles @> array[r.oid]
    or p.polroles = array[0::oid]
),

-- (5) ONE ROW PER (POLICY, ROLE, COMMAND), with `for all` expanded to all four.
--     A `for all` policy plus a `for select` policy is therefore two rows in the
--     same (role, command) group, which is what trips rule 5.
--
--     `for all` is `polcmd = '*'` and it is expanded rather than left as its own
--     command, and the reason it has to be is that `for all` PLUS `for select` is
--     the shape MD24's fifth policy would take if it were a `for all`: expanding
--     it is what puts the two in the same group. The expansion is written out as
--     five cases rather than folded into one, so that `array['SELECT']` for `r`
--     and `array['SELECT','INSERT','UPDATE','DELETE']` for `*` cannot be confused
--     by a later edit that changes one of them.
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

-- (6) WHICH POLICIES THE SUBSTRATE WROTE, and it is three shapes:
--
--       the account predicate  `account_id = ( select cafaye.current_account_id()`
--       the credential predicate  `<column> = ( select cafaye.current_credential_digest()`
--       the membership predicate  `<column> = ( select cafaye.current_user_id()`
--
--     Inlined rather than delegated to `cafaye.credential_tables()` — see the
--     block above: an advisor that only exists where the substrate has been
--     installed cannot find the service that has not installed it. The second and
--     third shapes are checked against the FUNCTION FORM rather than against the
--     COLUMN, because the column is the adopter's choice and the form is the
--     substrate's. All three carry `(cafaye\.)?` for the `search_path` reason
--     recorded above.
--
--     THE THIRD ARM EXISTS BECAUSE THE EXEMPTION IS AN ALL-OF CONDITION, and that
--     is the mechanism by which a substrate function this file did not know about
--     becomes a finding against the substrate itself. When `protect_membership_table`
--     added `account_users`'s fifth policy, every group on that table stopped being
--     all-of and rule 5 reported the substrate's OWN policy as hand-written — on the
--     substrate's own fixture, in the suite whose subject is the substrate. The
--     arm is spelled as the third shape of the same test rather than as an
--     allowlist of policy names, so a service that hand-writes a policy whose
--     predicate merely MENTIONS `current_user_id` still trips the rule: the
--     recognition is of the form, not of the function name alone.
substrate_written as (
  select pc.*,
         (pc.qual ~* '^\s*\(?account_id = \(\s*select (cafaye\.)?current_account_id\(\)'
            or pc.qual ~* '^\s*\(?[a-z_][a-z0-9_$]* = \(\s*select (cafaye\.)?current_credential_digest\(\)'
            or pc.qual ~* '^\s*\(?[a-z_][a-z0-9_$]* = \(\s*select (cafaye\.)?current_user_id\(\)') as substrate_written
  from policy_cmds pc
),

-- (7) NORMALISED EXPRESSIONS, for rule 3. Whitespace and case removed, because
--     `USING ( TRUE )` and `USING (true)` are the same policy and a rule that
--     reads one of them is a rule with a typo in it.
--
--     This one is per POLICY, not per (policy, role, command), and it is built
--     from a different arm of the CTE chain for a specific reason: a `for all`
--     policy fires rule 3 four times otherwise, once per command it was expanded
--     into, and four identical findings for one bad policy is a report nobody
--     reads to the end. The source reports this rule once per policy too — its
--     `FOR ALL` expansion belongs to rule 5 and only to rule 5. So rule 3 gets a
--     per-policy view with its role list, and rule 5 keeps the expansion.
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

-- (7b) WHAT A POLICY'S EXPRESSION REACHES -- DIRECTLY, OR THROUGH A FUNCTION IT
--      CALLS. This is `view_reads`' walk, applied to rule 4's subject, and it is
--      the same shape for the reason `view_reads` gives for being transitive: a
--      second walk written a second way is a second thing to keep correct.
--
--      WHY IT EXISTS, IN ONE SENTENCE: `pg_depend` on a policy records the
--      FUNCTION a policy calls, never the relation inside that function's body,
--      so rule 4 goes silent on exactly the defect it exists for. Measured on
--      this kit (the query and its rows are in `measure-advisor-pgproc.sql`):
--
--        pg_policy -> pg_proc   (deptype 'n', the helper)     -- one hop, then
--        pg_policy -> pg_class  (deptype 'a', its own table)  -- nothing.
--
--      And the walk DOES NOT STOP AT `pg_proc`, because a function's own
--      dependencies are in the same catalog and the same join: a `BEGIN ATOMIC`
--      helper records `pg_proc -> pg_class -> <the relation>` and this walk
--      follows it. See the block above rule 4 for what that closes and, in the
--      file's own words, what it does not close.
--
--      THE SELF-REFERENCE EXCLUSION IS CARRIED INTO HOP 1 and nothing else.
--      `recordDependencyOnSingleRelExpr` deliberately does not record a
--      predicate's reference to its own table, so `using (account_id = ...)`
--      produces no row here and the substrate's own policies stay silent. The
--      exclusion is `not (pg_class and refobjid = polrelid)` rather than a
--      second join filter, because a hop-2 relation that happens to BE the
--      policy's own table is a different thing and is not excluded by accident.
--
--      HOP 2 IS ONLY TAKEN FROM A `pg_proc` REF. A relation reached in hop 1 is a
--      relation and nothing depends on relations from here: the rule asks what
--      the predicate READS, and a table's own dependencies are its indexes and
--      its toast table. Taking the hop from `pg_class` as well would drag every
--      index of every reached table into the walk and report them all.
--
--      `min(depth)` and `group by`, because `pg_depend` records one row per
--      (object, reference) and a policy that reaches a table twice -- or reaches
--      it both directly and through a helper -- records it twice. Measured on
--      this fixture, `view_reads` had exactly this: `{plain, plain}`, one
--      relation reported as two. The same aggregation is the same reason.
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
      -- `through_proc` is the function this edge was taken FROM, and it is what
      -- lets the finding say "reached through helper X" instead of only naming
      -- the table. It is carried rather than recovered by a second join, because
      -- recovering it means matching on `pg_depend` from the relation -- the
      -- REVERSE direction -- which would name every function that reads the
      -- table rather than every function the policy called to reach it.
      select r.policy_oid, d.refclassid, d.refobjid, r.depth + 1, r.ref_oid
      from reached r
      join pg_depend d
        on d.classid     = 'pg_proc'::regclass
       and d.objid       = r.ref_oid
       and d.refclassid = 'pg_class'::regclass
      -- The depth bound is `view_reads`' bound for `view_reads`' reason: a
      -- checker should not hang on a cycle, and a bound never reached costs
      -- nothing. `pg_depend` is finite, so this is belt and braces.
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

-- (8) EVERY VIEW IN SCOPE, THE TABLES IT REACHES, AND WHETHER IT IS AN INVOKER.
--     Resolved from `pg_depend` and NOT from `pg_get_viewdef`.
--
--     The catalog answer is available and it is the right one: Postgres records a
--     view's rewrite rule as depending on each relation the view reads, so
--     `pg_depend` with `classid = pg_rewrite` names the tables by OID. That is
--     the same mechanism rule 4's catalog half uses for a policy's expression,
--     and for the same reason — it survives renaming, it needs no parsing, and a
--     parse of view text is a parse whose misses are silent. `pg_get_viewdef`
--     would additionally have the `search_path` defect recorded three CTEs
--     above, which is a third way to answer this question that would be right
--     for one reader and wrong for another.
--
--     `security_invoker` is read from `reloptions` rather than inferred, and the
--     regexp accepts the three boolean spellings Postgres itself accepts. The
--     stored form is canonical (`security_invoker=true`), so this is a
--     mitigation for a future writer rather than a repair of a measured one —
--     stated as such so a reader does not go looking for the measurement.
--
--     `relkind = 'v'` and nothing else. A MATERIALIZED view is excluded
--     deliberately: it holds a COPY, refreshed by the owner, and RLS is not
--     enforced on reads from it at all — so a matview over an account-scoped
--     table is a much larger finding than this rule's, and reporting it as this
--     rule would be reporting the wrong hole. A FOREIGN table has no policies at
--     all, so `relkind = 'f'` never reaches the rule either.
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
    -- extension-owned views are excluded for the same reason tables are: a view
    -- this substrate cannot change is a finding that trains the reader to
    -- ignore the report.
    and not exists (select 1 from pg_depend ve
                     where ve.classid = 'pg_class'::regclass
                       and ve.objid = v.oid
                       and ve.deptype = 'e')
),

-- and the relations each of those views reaches, one row per (view, relation).
--
--     THE DEPENDENCY GRAPH IS WALKED TRANSITIVELY, and the reason is that a
--     view over a view is the SAME hole rather than a milder one. Postgres
--     evaluates the outer view with the outer view's owner's privileges, and the
--     inner view with the inner one's; there is no point in that chain where a
--     caller's policies come back into force. So `report_v` over
--     `account_summary` over `account_users` reads every account's rows exactly
--     as `account_summary` does, and a rule that stopped at the first hop would
--     report the inner view and stay silent about the one a caller actually
--     queries. Measured on this fixture: `nested_view` reads only `definer_view`
--     and no RLS'd table directly, and it reads every row `definer_view` reads.
--
--     `DISTINCT` in `view_reads` is not tidiness. `pg_depend` records one row
--     per (rewrite rule, reference), and a view that names a table twice in its
--     body records it twice here: measured, `{plain, plain}` — one relation,
--     reported as two.
--
--     The self-reference row (`refobjid = the view's own oid`, `deptype = 'i'`)
--     is dropped by the relkind filter rather than by an oid comparison,
--     because it is the only row in this join whose `refobjid` is the view
--     itself and the filter says so in the same word as everything else.
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
      -- The chain STOPS at an invoker view, and that is the whole meaning of the
      -- flag. A `security_invoker` view runs its own query as whoever called IT
      -- — which, reached from another view, is that view's owner — so policies
      -- come back into force at that hop. Walking past it would report a chain
      -- whose innermost link is already fixed.
      select r.view_oid, t.oid, r.depth + 1
      from reached r
      -- `mid` is read through the `views` CTE rather than `pg_class`, which is
      -- what makes this hop agree with the rule's OWN definition of an invoker.
      -- Writing the test a second time against `reloptions` is how the two
      -- disagree, and they did: an equality test against the literal string
      -- `security_invoker=true` misses `security_invoker = on`.
      --
      -- MEASURED, and this is not hypothetical. Postgres stores reloptions
      -- VERBATIM — it does not canonicalise the boolean — so all three spellings
      -- survive as written:
      --
      --     security_invoker = true   ->  {security_invoker=true}
      --     security_invoker = on     ->  {security_invoker=on}
      --     security_invoker = false  ->  {security_invoker=off}   (for `off`)
      --
      -- and `core`'s own fixture at
      -- `harness/tests/fixtures/tenancy/conforming/migrations/0002_rls.sql:89`
      -- writes `with (security_invoker = on)`. So the spelling that is idiomatic
      -- in this very fleet is the one an equality test does not match, and the
      -- walk would have carried on past a view whose policies are already in
      -- force — reporting a chain as broken that is not.
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
        -- `pg_depend` is finite and the chain stops at an invoker, but the depth
        -- bound is here anyway: a cycle is not something a checker should hang
        -- on, and a bound that is never reached costs nothing when it is not
        -- needed. 16 is three orders of magnitude above any view stack a human
        -- writes and one below the depth at which the walk is suspect anyway.
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

-- ===========================================================================
-- 1. `policy_exists_rls_disabled` — the rules read as if they are in place and
--    are not. The finding is the shape that reads correct in review: policies
--    exist, `relrowsecurity` is false, and every catalog a reader would consult
--    says the table is protected because it has policies.
-- ===========================================================================
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

-- ===========================================================================
-- 2. `rls_disabled_in_public` — the table the API can reach, with no RLS.
--
--    THE MAPPING, and it is the load-bearing adaptation of the whole file.
--    Supabase asks whether `anon` or `authenticated` holds SELECT and whether
--    the schema is in `pgrst.db_schemas`. kit has no PostgREST and no fixed
--    roles, so the question becomes: does ANY non-owner, non-superuser LOGIN
--    role hold SELECT on this table. That is the same question with the
--    platform's names filled in by the catalog's, and it is strictly the
--    generalisation: a role kit did not know about when the rule was written
--    is in scope, which a hard-coded pair of role names would miss.
--
--    `has_table_privilege` includes privileges held through PUBLIC and through
--    role membership, which is the correct answer to "can this caller read it"
--    and the wrong one to ask about a single grant — the grant is not the
--    capability, and a rule that read grants instead would miss every inherited
--    one.
-- ===========================================================================
rule_rls_disabled_in_public as (
  select 'rls_disabled_in_public'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security is not enabled on a table a non-owner login role can SELECT. Whatever this table holds is readable by every role that can reach the database, whatever the service intends.'::text as description,
         format('Table %I.%I has no row level security, and %s login role(s) can SELECT it: %s.',
                n.nspname, c.relname, count(*)::text,
                array_to_string(array_agg(distinct r.rolname order by r.rolname), ', '))::text as detail,
         format('If the table holds customer rows: ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY; and call cafaye.protect_table(''%I'') from its migration. If it holds none, revoke the grant that makes it reachable — the reachability is the finding, not the missing RLS.', n.nspname, c.relname, c.relname)::text as remediation,
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

-- ===========================================================================
-- 3. `rls_policy_always_true` — a permissive predicate that is always true.
--
--    `SELECT ... USING (true)` IS DELIBERATELY NOT FLAGGED, and the source is
--    right about why: a public read-only surface written `for select using
--    (true)` is a decision, not an accident. `UPDATE`, `DELETE` and `FOR ALL`
--    are different — a permissive write predicate that is always true lets a
--    caller write any row, which is the shape every "we'll tighten it later"
--    policy takes.
--
--    The NULL clause is half of it and is the half nobody writes: an INSERT has
--    no `using` (there is no existing row to filter) so a permissive INSERT with
--    a NULL `with check` permits every row anybody offers it. `normalize` is
--    what makes `USING ( TRUE )`, `USING (1=1)` and `USING ((true))` one
--    finding rather than three near-misses.
-- ===========================================================================
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
         format('Rewrite the qualifier so it names what the caller must hold: account_id = (select cafaye.current_account_id()) on an account-scoped table. cafaye.protect_table/2 writes that form; a hand-written `true` is the one predicate no caller can narrow.', polname)::text as remediation,
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

-- ===========================================================================
-- 4. `rls_references_user_metadata` — an authorization input the caller can
--    EDIT. This is the rule that changed most, and the change is the reason the
--    rule earns ERROR rather than being dropped along with the `auth` schema.
--
--    THE SOURCE'S RULE, IN ITS OWN TERMS: `auth.users.user_metadata` is editable
--    by the end user, so a policy that consults it consults something the user
--    controls. The source admits at `:821-822` that it cannot do better than a
--    string match: "False positives are possible, but it isn't practical to
--    string match."
--
--    THE HALF THAT IS PORTED VERBATIM, caveat and all. A policy mentioning
--    `user_metadata`, `raw_user_meta_data` or `app_metadata` is flagged whether
--    or not this fleet ever writes one, because the caveat is the point: this
--    half is a keyword search and says so.
--
--    THE HALF THAT IS NOT, and it is the reason this rule stays. Postgres records
--    a policy's dependencies: `pg_depend` holds a row per relation the policy
--    EXPRESSION reaches outside its own table. So "does this policy's predicate
--    read a table a caller can write" is a question about the catalog, not
--    about the text — and it is the shape of `user_metadata` exactly. A service
--    that keeps a `profile_flags` / `memberships` / `is_admin` table and writes
--    `using (exists (select 1 from profile_flags f where f.is_admin))` has built
--    its own `user_metadata`, and no keyword search finds it: the name is the
--    service's, the column is the service's, and the words `user_metadata` appear
--    nowhere. Supabase's rule could only ever report the half it could spell.
--
--    A column OF the policy's own table is not a hit, and that exclusion is not
--    cosmetic: `recordDependencyOnSingleRelExpr` deliberately does not record
--    self-references, so `using (account_id = ...)` produces no row here and the
--    substrate's own policies are silent.
--
--    THE FUNCTION HOP, and this part was MEASURED rather than designed.
--    `pg_depend` on a policy records a called FUNCTION and never the relation
--    inside that function's body, so a `SECURITY DEFINER` helper made this rule
--    go silent on exactly the defect it exists for. Three body kinds were created
--    against PostgreSQL 17.11 and their `pg_depend` dumped; the SQL and the rows
--    are `measure-advisor-pgproc.sql` and `measurement-pgproc.out` at the
--    repository root, and the three answers are three different rules:
--
--      language sql, STRING body (`as $$ … $$`)   NOT RECORDED. `pg_depend` on
--          the function carries ONE row, `refclassid = pg_namespace`. The
--          body->relation edge exists only in `prosrc`, as TEXT.
--
--      language plpgsql                          NOT RECORDED. `pg_depend`
--          carries `pg_language` and `pg_namespace`. Nothing else.
--
--      language sql, BEGIN ATOMIC body           RECORDED. `pg_proc ->
--          pg_class -> <the relation>`, `deptype = 'n'`, because PG14+ parses
--          that body at `CREATE FUNCTION` time.
--
--    SO THE HOP IS ONE JOIN, IT IS CORRECT, AND IT IS NOT THE WHOLE ANSWER. The
--    residual is the finding rather than a footnote: the shape a hand-written
--    helper actually takes is the FIRST row, and the catalog does not carry it.
--    Catching that shape means reading `prosrc` and matching table names in SQL
--    text, which is a different and worse rule -- a substring match fires on a
--    table name inside a COMMENT, and this file's own recorded lesson is that a
--    proof two checks could satisfy proves neither. So the hop ships and the scan
--    does not, and "what this does not find" says so in the first screen of this
--    file rather than leaving a reader to infer it from a rule's silence.
--
--    WHAT THE HOP COSTS, and this is a measurement rather than an assurance:
--    `current_account_id()` and `current_credential_digest()` are the only
--    functions the substrate's own policies call, neither reads a table, and
--    assertion 7 of `tests/tenancy_test.sh` requires ZERO ERROR and zero WARN on
--    the two tables the substrate wrote -- so a hop that lit up on them goes red
--    in the suite rather than shipping quietly.
-- ===========================================================================
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
         format('The identity has to arrive from somewhere the caller cannot write. cafaye.begin_account/1 carries it into a transaction-local GUC and cafaye.current_account_id() reads it; a flag table is a request, not an identity. If the qualifier reaches the table through a function, that function has to be SECURITY INVOKER: a SECURITY DEFINER helper runs with its owner''s privileges and with that owner''s exemption from these policies, which is a wider hole than the one this row is about. Deny the grant (REVOKE INSERT, UPDATE ON <that table> FROM <the login role>) and decide from the account instead.', n.nspname, c.relname)::text as remediation,
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
  -- the ported keyword half, caveat included
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

-- ===========================================================================
-- 5. `multiple_permissive_policies` — two or more PERMISSIVE policies on one
--    (table, role, command). They combine with OR, so the effective predicate is
--    the union of both, and every one of them is evaluated for every relevant
--    query.
--
--    AND THE EXEMPTION, which is the only judgement in this file: a group is
--    exempt when EVERY policy in it was written by the substrate. See the block
--    above for why, and for why an allowlist of policy names would be a ratchet
--    rather than an exemption. The all-of condition is what makes it safe: MD24's
--    fifth policy is exempt alongside the four, and a hand-written sixth is not.
-- ===========================================================================
rule_multiple_permissive as (
  select 'multiple_permissive_policies'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE', 'SECURITY']::text[] as categories,
         'More than one PERMISSIVE policy applies to this table, role and command. Permissive policies combine with OR rather than AND, so the effective predicate is the union of all of them and each is evaluated on every relevant query — which is both a cost at scale and a wider surface than either policy reads as on its own.'::text as description,
         format('Table %I.%I has %s permissive policies for role %s for command %s. All of them: %s. Not written by the substrate: %s.',
                nspname, relname, count(*)::text, rolname, cmd,
                array_to_string(array_agg(polname order by polname), ', '),
                array_to_string(array_agg(polname order by polname) filter (where not substrate_written), ', '))::text as detail,
         format('Keep one permissive policy per role per command, and fold the conditions into it with AND. cafaye.protect_table/2 writes exactly one per command; a second policy on the same (role, command) is the OR that makes the table wider than it reads.')::text as remediation,
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

-- ===========================================================================
-- 6. `login_role_security_definer_executable` — a SECURITY DEFINER function
--    the application login role can run. One rule, where the source has two:
--    `anon_…` and `authenticated_…` differ only in whether the caller signed in,
--    and in this substrate every caller is a role that can log in. The source's
--    distinction has no third state to fall into, and inventing one would be a
--    rule about a topology kit does not run.
--
--    A `SECURITY DEFINER` function runs with its OWNER's privileges and with the
--    owner's exemption from row-level security unless FORCE applies to it — so a
--    definer that is a table owner is an owner bypass behind a function
--    signature. `substrate.sql` writes none: every function it owns is an invoker,
--    which is why `pg_proc.prosecdef` is worth a rule here and finds nothing.
-- ===========================================================================
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
    -- The OWNER is deliberately NOT filtered for being a superuser or a BYPASSRLS
    -- role, and the reason is that filtering it would be filtering out the worst
    -- case: a SECURITY DEFINER function owned by a cluster superuser and callable
    -- by a login role is the most capable object in the database, and a rule that
    -- stays quiet about it because its owner is too powerful to be interesting has
    -- inverted the finding. The catalog schemas are already out of scope, so the
    -- functions this would otherwise reach are the platform's own.
    and owner.rolname !~ '^pg_'
  group by n.nspname, p.oid, p.proname, l.lanname, owner.rolname
),

-- ===========================================================================
-- 7b. `rls_policy_correlated_membership` — an `IN (SELECT …)` whose subquery
--     is CORRELATED to the policy's own row, so Postgres evaluates the membership
--     lookup once per candidate row instead of once per statement.
--
--    MEASURED, ON THIS KIT, BY `tests/rls_perf_test.sh` — and the number is the
--    packet's, re-measured rather than repeated. 200,000 rows, a membership table
--    of 200 rows indexed in BOTH directions, run as a `<service>_app` login with
--    `FORCE ROW LEVEL SECURITY` on every policy table, through
--    `cafaye.begin_account` / `cafaye.current_account_id()`:
--
--        correlated  `X in (select … where m.s = slow_doc.subject_account_id)`
--                    2000 ms, and the plan's own loop counter reads
--                    `loops=200000` on the membership scan.
--
--        inverted    `slow_doc.subject_account_id in (select … where m.c =
--                    (select cafaye.current_account_id()))`
--                    18 ms, and the loop counter reads `loops=1`.
--
--        i.e. 111x on this fixture, where the reference reports 450x on its own
--        data. THE NUMBER IS NOT THE CLAIM AND NEITHER IS THE RATIO: the ratio is
--        set by the membership table's size — a per-row probe of a 200-row table
--        is cheap per row and ruinous in aggregate — and by the row count. What
--        transfers is the direction and the mechanism, and the mechanism is what
--        this rule reads off the catalog.
--
--    WHY `protect_table` CANNOT EMIT THIS SHAPE, which is the finding that makes
--    the rule cheap rather than noisy. `protect_table` writes
--    `account_id = (select cafaye.current_account_id())` — a column comparison
--    against a function, with no membership table anywhere in the predicate. There
--    is no join to invert because there is no join. The slow shape is only
--    reachable by a service HAND-WRITING a policy, which is the same population
--    rule 3, 5 and 7 already watch.
--
--    WHAT IT MATCHES, EXACTLY, because a rule that matches correlation in general
--    matches the whole fleet and is a report nobody reads:
--
--      * An `in (select …)` or `= any (select …)` — and an `IN (SELECT …)`
--        subquery contains a reference to the POLICY'S OWN TABLE. Inside a
--        subquery, a reference to the outer relation IS the definition of
--        correlation, so this is not a heuristic about shape: it is the property.
--        The subquery text is EXTRACTED (`regexp_matches`) and the reference is
--        looked for inside it, because a regexp cannot see past its own closing
--        paren — and the self-reference sits inside one, so a single regexp over
--        the whole qualifier misses the very case it was written for. That is
--        measured, not assumed: the correlated predicate deparsed to
--        `…in(select m.caller_account from perf.member_of m where
--        (m.subject_account = slow_doc.subject_account_id))`, where the
--        self-reference is inside the nested `WHERE (…)` group.
--
--      * BOTH deparse spellings of the relation, for the `search_path` reason
--        recorded above: `slow_doc.subject_account_id` to a reader who cannot
--        resolve `perf`, and `perf.slow_doc.subject_account_id` to one who can.
--        Measured on this fixture, the reader's `search_path` decided which one
--        the catalog returned, so requiring the qualified form would make this
--        rule blind to exactly the reader least likely to know why.
--
--    WHAT IT DELIBERATELY DOES NOT MATCH, and the measurement is the reason:
--
--      * `exists (select 1 from link l where l.doc_id = doc.id and …)`. The
--        outer hop of that shape is correlated and CANNOT be inverted — `doc` has
--        no membership column of its own, so there is no row column to `IN`
--        against — and yet it measured 56 ms against the correlated form's 2000 ms,
--        because with the INNER hop inverted Postgres re-associates the `EXISTS`
--        into a semi-join and resolves the membership ONCE. The plan showed
--        `Filter: (ANY (id = (hashed SubPlan 4).col1))` over a nested loop with
--        `loops=4`. So the boundary is PER HOP, not per policy, and a rule that
--        fired on correlation in general would fire on the shape that is already
--        fast — which is how a performance rule gets switched off.
--
--      * A correlated subquery in any other position. `and other.x = doc.y`
--        outside the `IN` is not this rule, and neither is a hand-rolled
--        `join`-shaped `WITH CHECK`.
--
--    THE RESIDUAL LIMITS, in the file's usual place rather than left to be
--    inferred: this reads the deparsed TEXT, for the same reason every other rule
--    here does and for the same recorded cost (`(cafaye\.)?`-style blindness under
--    one `search_path`); the `([^()]|\([^()]*\))*` arity is ONE level of nesting
--    inside the `IN`, so a membership subquery nested two deep is missed rather
--    than misreported; and it cannot tell a membership check from any other
--    correlated lookup, because `doc.row` inside an `IN (SELECT …)` is the same
--    text either way. All three are false NEGATIVES, chosen over false positives
--    on purpose.
-- ===========================================================================
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
         format('Invert which side is correlated: put the membership in the subquery''s WHERE on the CALLER, and IN the row''s own column against the result — `using (account_id in (select m.account_id from <membership> m where m.user_id = (select cafaye.current_account_id())))`. That is only expressible when this table carries the membership column locally; where it does not, filter the INNER hop instead — measured on this kit, a correlated EXISTS with its inner hop inverted ran 56 ms against the correlated IN''s 2000 ms, because the planner re-associates it into a semi-join. If the column does not exist anywhere on the path, the shape is not fixable by a rewrite: index the correlated column.', polname)::text as remediation,
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

-- ===========================================================================
-- 7. `auth_rls_initplan` — an identity call that is not wrapped in
--    `(select …)`, so the planner evaluates it once per candidate ROW instead of
--    once per statement.
--
--    THE MEASUREMENT IS KIT'S OWN and it is in `tests/tenancy_test.sh`: five
--    rows, one query, five rows matched — the wrapped form calls the function
--    ONCE, the bare form FIVE times. This rule does not replace that
--    measurement, because a measurement is a measurement and a regexp is a
--    regexp. It CORROBORATES it: `substrate.sql` writes only the wrapped form, so
--    this rule must be silent on a substrate the measurement has just passed,
--    and if it is not, one of the two is wrong and the disagreement is the
--    finding.
--
--    The precondition is the source's and it is not optional: wrapping is only
--    correct when the call does not depend on row data. `account_id =
--    (select cafaye.current_account_id())` is the same value for every row, which
--    is what makes the InitPlan legal, and `protect_table` only ever writes that
--    form.
-- ===========================================================================
rule_initplan as (
  select 'auth_rls_initplan'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE']::text[] as categories,
         'A policy qualifier calls the identity function bare, so it is re-evaluated for every candidate row instead of once per statement. Measured on this kit: one call against five, on a five-row table. Correct and slow; invisible until the table is large, which is the worst moment to find it.'::text as description,
         format('Policy %I on %I.%I calls an identity function without the (select …) wrapper. Measured on this kit, the bare form called the function once per candidate row (5 rows, 5 calls) where the wrapped form called it once. %s',
                polname, nspname, relname,
                case
                  when qual ~ 'current_setting\(' then 'unwrapped: current_setting(...)'
                  when qual ~ 'current_account_id\(\)' then 'unwrapped: cafaye.current_account_id()'
                  when qual ~ 'current_credential_digest\(\)' then 'unwrapped: cafaye.current_credential_digest()'
                  else 'unwrapped identity call'
                end)::text as detail,
         format('Rewrite it as `(... = ( select cafaye.current_account_id()))`. Only do so when the call does not depend on the row — the InitPlan is correct precisely because it is uncorrelated, so a call that reads the row must stay bare. cafaye.protect_table/2 writes the wrapped form for every policy it creates.')::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'qual', qual, 'with_check', with_check) as metadata,
         format('auth_rls_initplan_%s_%s_%s', nspname, relname, polname)::text as cache_key
  from policies
  where relrowsecurity
    -- An InitPlan is exactly `(... ( SELECT f() …))`, so the discriminator is
    -- the parenthesised SELECT and not the word `select` somewhere nearby. It is
    -- matched CASE-INSENSITIVELY because the deparser capitalises the keyword
    -- while leaving the function name in lower case: `SELECT
    -- cafaye.current_account_id()` is what the catalog holds, and a lowercase
    -- `select` in the pattern turns this rule into one that fires on every
    -- wrapped policy in the fleet.
    --
    -- Both deparse forms are accepted, for the `search_path` reason recorded
    -- above: requiring the qualified spelling would make this rule blind to a
    -- genuinely bare call in exactly the session where the name dequalifies,
    -- which is the session of the cluster's own admin role.
    and (
      (qual ~* '(cafaye\.)?current_account_id\(\)'        and qual !~* '\(\s*select\s+(cafaye\.)?current_account_id\(\)')
      or (qual ~* '(cafaye\.)?current_credential_digest\(\)' and qual !~* '\(\s*select\s+(cafaye\.)?current_credential_digest\(\)')
      or (qual ~* 'current_setting\('                       and qual !~* '\(\s*select\s+current_setting\(')
      or (with_check ~* '(cafaye\.)?current_account_id\(\)'        and with_check !~* '\(\s*select\s+(cafaye\.)?current_account_id\(\)')
      or (with_check ~* '(cafaye\.)?current_credential_digest\(\)' and with_check !~* '\(\s*select\s+(cafaye\.)?current_credential_digest\(\)')
      or (with_check ~* 'current_setting\('                       and with_check !~* '\(\s*select\s+current_setting\(')
    )
),

-- ===========================================================================
-- 8. `rls_enabled_no_policy` — RLS on, no policy. INFO, not ERROR, and the
--    level is the finding: the table is UNREADABLE to every role, which is
--    fail-closed. It is reported because the boundary is then two-sided — a
--    service whose table reads as protected and whose table reads as empty is a
--    3am failure with no error anywhere, and the catalog is where that shows up
--    first.
-- ===========================================================================
rule_rls_no_policy as (
  select 'rls_enabled_no_policy'::text as name,
         'INFO'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security is enabled and no policy exists, so every role is denied every row. Nothing leaks; the table is simply unreadable, which is a fail-closed outage rather than a breach.'::text as description,
         format('Table %I.%I has row level security enabled and no policy. Every SELECT on it returns no rows, including from the owner.', n.nspname, c.relname)::text as detail,
         format('Create the policies (cafaye.protect_table(''%I'')) or drop row level security from the table if it was meant to be readable.', c.relname)::text as remediation,
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

-- ===========================================================================
-- 9. `security_definer_view` — a view that enforces its OWNER's row-level
--    security rather than the caller's.
--
--    THE HOLE, in one sentence. Postgres gives a view the privileges and the
--    row-level-security EXEMPTION of the role that created it, so a view over an
--    account-scoped table enforces the policies that apply to its owner — and a
--    policy that applies to the owner is not a policy at all, because the owner
--    bypasses its own policies unless the table is FORCE'd. Writing a view over
--    `account_users` is therefore a way to hand every caller who can reach it
--    every account's rows, and it reads in review as a SELECT.
--
--    WHY THIS FILE WAS THE ONLY PLACE THAT COULD CATCH IT, and why it is ERROR
--    here rather than WARN: kit's boundary is per-service NOINHERIT login roles
--    that OWN their tables, so "the owner is exempt from its own policies" is
--    not a corner case of the definer model — it is every table in the fleet.
--    The reference's rule is `security_definer_view` at its `lints.ts:604-614`,
--    level ERROR, category SECURITY, and what is ported here is the SHAPE: the
--    same nine columns, one union arm per rule, the same level vocabulary.
--
--    THE THREE NARROWINGS, each of which is the difference between a rule that
--    is trusted and a rule that is switched off:
--
--      * A view with `security_invoker = true` is NOT this finding, because such
--        a view runs its queries as the caller and therefore enforces the
--        CALLER's policies. That is the entire remedy, so reporting it would be
--        reporting the fix as the disease.
--
--      * A view that reads no table with row level security is NOT this finding.
--        There is no policy to bypass, and views over reference tables or a bare
--        `select 1` are most views in a real schema. This guard is what stops the
--        rule from becoming "every view in the database is an ERROR".
--
--      * A view no login role can SELECT is NOT this finding — `has_table_
--        privilege`, not a grant scan, for rule 2's reason: a grant is not the
--        capability, and a role that inherits SELECT reaches a view nobody
--        granted it to.
--
--    AND THE RESIDUAL LIMITS, listed here rather than left for a reader to infer:
--    it asks whether the view reads an RLS'd TABLE, not whether that table is in
--    another schema or on another cluster; and it does not resolve view TEXT, so
--    a view projecting one non-account column over an account-scoped table is
--    reported as loudly as one projecting the whole table. Both are in "what
--    this does not find", and the second is the same trade rule 4's keyword half
--    makes: narrowing it means parsing `pg_get_viewdef`, and a parse's misses are
--    silent.
--
--    THE VERSION FLOOR, because it changes what the rule MEANS rather than what
--    it matches. `security_invoker` arrived in Postgres 15. On 14 or older the
--    option does not exist, so `CREATE VIEW ... WITH (security_invoker = true)`
--    is refused and EVERY view in the database is a definer view — which means
--    this rule fires on every view over an RLS'd table, and every one of those
--    findings is TRUE. There is no flag to set and no way to silence one, so a
--    service on an old server sees an ERROR it cannot fix by remediation. That is
--    reported in the `remediation` column rather than in this comment, because a
--    reader who acts on the finding is the one who needs it:
--
--        When current_setting('server_version_num')::int < 150000 the remediation
--        names the version rather than printing an ALTER that would be refused.
--
--    This fleet's floor is PG15 (`templates/compose/postgres/Dockerfile`, and
--    MD21b's PG17), so on kit's own cluster the branch is unreachable — which is
--    exactly why it is written rather than left implicit. A checker that means
--    something different on two supported server versions is not a checker that
--    can be trusted on either.
-- ===========================================================================
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
         -- THE REMEDIATION IS VERSION-SENSITIVE, and it is branched rather than
         -- footnoted because a reader who acts on this column is the one who
         -- needs to know. `ALTER VIEW ... SET (security_invoker = true)` is
         -- refused outright below PG15, and on that server EVERY view is a
         -- definer view, so every finding this rule reports is true and none of
         -- them is fixable with the flag. Printing the ALTER there would hand
         -- out a remediation that cannot execute — which is the one thing a
         -- remediation column must never do.
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
                            -- DISTINCT in both, and not as tidiness: `pg_depend`
                            -- records one row per (rewrite rule, reference) and a
                            -- view that names a table twice in its body records it
                            -- twice here too. Measured, on this fixture:
                            -- `{"vf.plain","vf.plain"}` — one relation, reported
                            -- as two.
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
-- Ordered by the KEY rather than by the finding, so a run that gains and loses
-- findings produces a diff a reader can read. `cache_key` is the one column here
-- that does not change when a finding's prose does.
order by f.cache_key;
$advisor$;