-- THE PRIVILEGE SURFACE, in the form a diff can read.
--
-- Run by tests/grant_surface_test.sh, and by nothing else. It writes every fact
-- about the cluster's privilege model that kit's isolation contract depends on,
-- deterministically ordered, so the whole surface can be held in a golden file
-- and any drift is a byte difference rather than a review nobody performed.
--
-- WHY THIS EXISTS. `templates/compose/postgres/initdb/10-cluster.sh` provisions
-- the privilege model — two roles per service, CONNECT revoked from PUBLIC,
-- role-level timeouts and connection limits — and until this file nothing in the
-- fleet compared a RUNNING cluster against what that script promises. Two
-- instances were found by hand: two services' connection pools were logging in
-- as the OWNER role instead of `<service>_app` (so the account boundary those
-- services had adopted was one privilege away from meaningless), and Postgres
-- exempts a table's owner from its own row-level-security policies, so an owner
-- login reads every account's rows even with FORCE ROW LEVEL SECURITY in place.
-- Neither failure changes a file, so no static check could see either; both are
-- visible in `pg_roles` and `pg_auth_members` on a live cluster, which is what
-- this query reads.
--
-- HOW IT RUNS, and why one file covers two scopes. The cluster-wide facts
-- (roles, their settings, memberships, per-database CONNECT) are answers a
-- superuser gets from any database, so they are read ONCE, against the admin
-- database. Schema privileges are per-database state: `pg_namespace` is a
-- database-local catalog, and Postgres has no cluster-wide view of it, so the
-- `public` ACL is read once PER DATABASE, on a connection to that database.
-- `:schema` selects which half to emit (0 = cluster-wide, 1 = schema), and
-- `grant_surface_test.sh` runs cluster mode once and schema mode once per
-- non-template database, in `pg_database` order. The output is byte-identical
-- between two runs against the same cluster; the test asserts that rather than
-- assuming it.
--
-- WHAT IS COVERED, and every item is load-bearing:
--
--   roles          rolsuper, rolcreatedb, rolcreaterole, rolbypassrls,
--                  rolcanlogin, rolinherit, rolconnlimit, rolreplication for
--                  every role the cluster provisions. `rolbypassrls` is the one
--                  supabase's golden `roles.out` records and kit's contract had
--                  no equivalent for: a role that owns its tables bypasses RLS
--                  unless every table says FORCE, and BYPASSRLS walks past the
--                  policies AND the FORCE.
--   settings       statement_timeout and idle_in_transaction_session_timeout
--                  from pg_db_role_setting, as name/value pairs. These are the
--                  shared-cluster backstops the init script sets per role; a
--                  cluster where they silently stopped being set is the
--                  forgotten-BEGIN failure the settings exist to bound.
--   memberships    pg_auth_members, as (member, granted role, admin_option,
--                  inherit_option, set_option). The DIRECTION is the point:
--                  `<service>` is a member of `<service>_app` (the owner can
--                  become something weaker, which is how the proofs impersonate
--                  the app role), and the reverse membership — the app role as
--                  a member of the owner — is the one grant that hands the
--                  application every privilege the owner has. Both directions
--                  are printed, so the forbidden one is a visible absence and
--                  an added grant is a visible line.
--   CONNECT        pg_database.datacl, exploded to one row per (database,
--                  grantee, privilege). This is the isolation boundary: the
--                  init script's `REVOKE ALL ON DATABASE ... FROM PUBLIC` is
--                  the entire mechanism, and `PUBLIC|CONNECT` appearing here is
--                  the fleet-wide failure it exists to prevent.
--   public schema  pg_namespace.nspacl for `public` in every database, exploded
--                  the same way. PG15 removed the default CREATE grant, and the
--                  init script re-states the revoke rather than inheriting the
--                  version's behaviour — this records which of those two facts
--                  the cluster is actually running on.
--
-- WHAT IS DELIBERATELY EXCLUDED, and why each exclusion is the deterministic
-- choice rather than a hiding place:
--
--   * OIDs. Every join here resolves OIDs to names (or, for schema grants, to
--     the stable `pg_database_owner` pseudo-role); a golden file holding OIDs
--     would change on every fresh cluster and prove nothing.
--   * Passwords. `pg_authid.rolpassword` is the only place they live and this
--     file does not read it. (Isolation is by privilege and never by secret,
--     so the golden can be a public artifact.)
--   * `rolvaliduntil`, and everything else timestamped. Nothing in this file
--     reads a clock.
--   * `grantor`. Who ran the GRANT is a fact about the operator's session; what
--     was granted is the contract, and the two differ without the contract
--     having moved.
--   * `pg_*` roles as ROLE ROWS. The predefined roles' set grows between
--     Postgres versions (supabase's roles.sql excludes three of them by name
--     for the same reason), so including them would turn a Postgres image bump
--     into a golden-file failure that says nothing about the fleet. They are
--     NOT excluded as grantees: `pg_database_owner` holds CREATE on `public`
--     and that fact is part of the surface.
--
-- THE DEFAULT-ACL COALESCE, and why it is the difference between a check and a
-- decoration. `datacl` and `nspacl` are NULL when nobody has ever changed the
-- ACL, and NULL means "the server's default applies" — which for a database is
-- owner + PUBLIC. `aclexplode(NULL)` yields ZERO ROWS, so the obvious query
-- would print an empty CONNECT section for a cluster whose revoke never ran —
-- the exact defect the section exists to catch, reported as silence. So both
-- ACLs are read through `coalesce(acl, acldefault(...))`: Postgres's own
-- definition of what NULL means is materialized and exploded. Measured on the
-- shipped image: a database created outside the init script's sweep reports
-- `PUBLIC|CONNECT` and `PUBLIC|TEMPORARY` here, not nothing.
--
-- WHAT WOULD MAKE THIS FILE WRONG RATHER THAN RED. A new database created
-- between the test's database-list read and its per-database pass would change
-- the output under it — the test provisions its own fresh cluster and reads the
-- list from the cluster it is dumping, and the determinism assertion it runs
-- first (two dumps, byte-compared) is what makes that failure loud instead of
-- flaky.

\if :schema

-- The per-database half. `:db` is the database this psql is connected to, and
-- it is interpolated into the banner by the test rather than read from
-- `current_database()` so the banner and the rows under it cannot disagree.
\echo == schema public: :db ==
select current_database()                                 as database,
       coalesce(r.rolname, 'PUBLIC')                       as grantee,
       a.privilege_type
  from pg_namespace n
  cross join lateral aclexplode(
    coalesce(n.nspacl, acldefault('n', n.nspowner))) a
  left join pg_roles r on r.oid = a.grantee
 where n.nspname = 'public'
 order by 1, 2, 3;

\else

-- The cluster-wide half, read once against the admin database.
\echo == roles: pg_roles, predefined pg_* rows excluded ==
select rolname,
       rolsuper,
       rolcreatedb,
       rolcreaterole,
       rolbypassrls,
       rolcanlogin,
       rolinherit,
       rolconnlimit,
       rolreplication
  from pg_roles
 where rolname not like 'pg\_%'
 order by rolname;

-- One row per setting, not one row per setconfig array. The array's order is
-- insertion order (measurable but an implementation detail); the name/value
-- rows are sorted, which is the ordering that survives an unrelated ALTER.
\echo == role settings: pg_db_role_setting ==
select r.rolname                                                       as role,
       coalesce(d.datname, '(cluster-wide)')                           as database,
       split_part(s.setting, '=', 1)                                   as setting,
       substring(s.setting from position('=' in s.setting) + 1)        as value
  from pg_db_role_setting drs
  join pg_roles r on r.oid = drs.setrole
  left join pg_database d on d.oid = drs.setdatabase
  cross join lateral unnest(drs.setconfig) as s(setting)
 where r.rolname not like 'pg\_%'
 order by 1, 2, 3, 4;

\echo == memberships: pg_auth_members ==
select m.rolname  as member,
       g.rolname  as granted_role,
       am.admin_option,
       am.inherit_option,
       am.set_option
  from pg_auth_members am
  join pg_roles m on m.oid = am.member
  join pg_roles g on g.oid = am.roleid
 where m.rolname not like 'pg\_%'
   and g.rolname not like 'pg\_%'
 order by 1, 2;

\echo == database connect surface: pg_database.datacl ==
select d.datname                     as database,
       coalesce(r.rolname, 'PUBLIC') as grantee,
       a.privilege_type
  from pg_database d
  cross join lateral aclexplode(
    coalesce(d.datacl, acldefault('d', d.datdba))) a
  left join pg_roles r on r.oid = a.grantee
 where not d.datistemplate
 order by 1, 2, 3;

\endif
