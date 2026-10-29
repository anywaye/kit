\set ON_ERROR_STOP on
\timing off
drop schema if exists m cascade;
create schema m;

create table m.flags (id int primary key, is_admin boolean not null default false);
insert into m.flags values (1, false), (2, true);
create table m.doc   (id int primary key, account_id int not null);
create table m.ctrl  (id int primary key, account_id int not null);

create role login_app login;
grant usage on schema m to login_app;
grant select, insert, update on m.flags to login_app;
grant select on m.doc, m.ctrl to login_app;

create function m.can_read() returns boolean
  language sql stable security definer
  set search_path = m, pg_temp
as $$ select exists (select 1 from m.flags f where f.is_admin) $$;

alter table m.doc enable row level security;
create policy doc_via_helper on m.doc for select to login_app using (m.can_read());

alter table m.ctrl enable row level security;
create policy ctrl_direct on m.ctrl for select to login_app
  using (exists (select 1 from m.flags f where f.is_admin));

\echo '=== Q1: pg_depend rows for the POLICY objects (classid pg_policy) ==='
select d.classid::regclass as classid, d.objid,
       d.objsubid, d.refclassid::regclass as refclassid, d.refobjid, d.deptype
from pg_depend d
where d.classid = 'pg_policy'::regclass
order by d.objid, d.refclassid, d.refobjid;

\echo '=== Q2: pg_depend rows for the FUNCTION (classid pg_proc) ==='
select d.classid::regclass as classid, d.objid, d.objsubid,
       d.refclassid::regclass as refclassid, d.refobjid, d.deptype,
       c.relname as referenced_relation
from pg_depend d
left join pg_class c on d.refclassid = 'pg_class'::regclass and c.oid = d.refobjid
where d.classid = 'pg_proc'::regclass and d.objid = 'm.can_read()'::regprocedure
order by d.refclassid, d.refobjid;

\echo '=== Q3: does pg_depend ANYWHERE name m.flags from something owned by the function? ==='
select d.classid::regclass as classid, d.objid, d.refclassid::regclass as refclassid,
       d.refobjid, d.deptype
from pg_depend d
where d.refobjid = 'm.flags'::regclass
order by 1,2;

\echo '=== Q4: the whole pg_depend tree reachable from the policy, transitively ==='
with recursive edges as (
  select 'pg_policy'::regclass as classid, p.oid as objid,
         d.refclassid, d.refobjid, 1 as depth
  from pg_policy p
  join pg_depend d on d.classid = 'pg_policy'::regclass and d.objid = p.oid
  where p.polname = 'doc_via_helper'
  union all
  select e.classid, e.objid, d.refclassid, d.refobjid, e.depth + 1
  from edges e
  join pg_depend d on d.classid = e.refclassid and d.objid = e.objid
  where e.depth < 8
)
select e.depth, e.classid::regclass as from_class, e.objid,
       e.refclassid::regclass as to_class, e.refobjid, e.deptype,
       coalesce((select relname from pg_class where oid = e.refobjid), '(not a relation)') as ref_name
from edges e order by e.depth, 5, 6;

\echo '=== Q5: prosrc — where the body->relation edge actually lives ==='
select p.proname, p.prosecdef, p.prosrc from pg_proc p where p.oid = 'm.can_read()'::regprocedure;

\echo '=== Q6: any OTHER catalog carrying the function body? ==='
select 'pg_depend' as catalog, count(*)::text as rows
from pg_depend d where d.refobjid = 'm.flags'::regclass
union all
select 'pg_rewrite', count(*)::text from pg_rewrite where ev_class = 'm.can_read()'::regprocedure
union all
select 'pg_attrdef', count(*)::text from pg_attrdef d
  join pg_class c on c.oid = d.adrelid where 'm.can_read()'::regprocedure::text = c.relname
union all
select 'pg_shdepend', count(*)::text from pg_shdepend s
  join pg_proc p on p.oid = s.objid
  join pg_class c on c.oid = s.refobjid
  where p.oid = 'm.can_read()'::regprocedure and c.relname = 'flags';

\echo '=== Q7: the SAME relation reached DIRECTLY — what rule 4 sees today ==='
select p.polname,
       exists (select 1 from pg_depend d
                where d.classid = 'pg_policy'::regclass and d.objid = p.oid
                  and d.refclassid = 'pg_class'::regclass
                  and d.refobjid = 'm.flags'::regclass) as rule4_catalog_half_fires
from pg_policy p where p.polname in ('ctrl_direct', 'doc_via_helper') order by 1;