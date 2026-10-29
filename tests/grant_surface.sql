
\if :schema

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
