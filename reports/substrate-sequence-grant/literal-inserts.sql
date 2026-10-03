-- Literal INSERTs as the LOGIN role, run by `mutations.sh` in this directory.
--
--   psql -U <service>_app -d <db> -f literal-inserts.sql
--
-- WHY THIS IS A FILE AND NOT A FUNCTION CALL. The whole finding is the shape of
-- what a service sees: one ordinary `INSERT` in a transaction, refused with a
-- message that names a sequence it has never heard of. A probe that wrapped the
-- INSERT in a `DO` block to capture a SQLSTATE would report the same verdict and
-- would not be the statement anybody runs, and this repository's own recorded
-- lesson is that a witness which is not the real statement proves something
-- adjacent. So the statements below are the statements, and the output saved
-- beside this file is what `psql` printed.
--
-- `ON_ERROR_STOP` is OFF, deliberately, and every INSERT is in its own
-- transaction. One failed statement would otherwise abort the script and hide
-- every later case, which is how a four-case comparison becomes a one-case
-- comparison that nobody noticed.
--
-- Each INSERT omits the id column, so the database has to fetch it from the
-- sequence — which is the operation the grant in question exists for. `returning
-- id` is in each one because "the row lands" and "the row lands with the id the
-- sequence produced" are different claims, and only the second one proves the
-- sequence was actually used rather than bypassed.

\set ON_ERROR_STOP off

\echo '--- t_serial — bigserial ---'
begin;
select cafaye.begin_account('00000000-0000-0000-0000-0000000000a1');
insert into t_serial (account_id, label)
values ('00000000-0000-0000-0000-0000000000a1', 'literal')
returning id;
commit;

\echo '--- t_identity — generated always as identity ---'
begin;
select cafaye.begin_account('00000000-0000-0000-0000-0000000000a1');
insert into t_identity (account_id, label)
values ('00000000-0000-0000-0000-0000000000a1', 'literal')
returning id;
commit;

\echo '--- t_plain — bigint primary key, NO sequence ---'
-- id 4242 rather than 1: the harness's own negative-control case has already
-- inserted id 1 by the time this file runs, and a fixed low id would turn the
-- control's evidence into a primary-key collision.
begin;
select cafaye.begin_account('00000000-0000-0000-0000-0000000000a1');
insert into t_plain (id, account_id, label)
values (4242, '00000000-0000-0000-0000-0000000000a1', 'literal')
returning id;
commit;

\echo '--- t_unrelated — bigserial, NEVER protected ---'
-- Expected to be refused, and for a different reason than t_serial was: this is
-- `permission denied for TABLE`, which is the substrate's `revoke … from public`
-- doing its job. It is in this file because the difference between the two
-- refusals is the whole finding — the table grant was always there, the sequence
-- grant was not.
begin;
select cafaye.begin_account('00000000-0000-0000-0000-0000000000a1');
insert into t_unrelated (account_id, label)
values ('00000000-0000-0000-0000-0000000000a1', 'literal')
returning id;
commit;