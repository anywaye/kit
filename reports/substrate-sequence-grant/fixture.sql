-- Fixture for `reports/substrate-sequence-grant/mutations.sh`. Run as the OWNER
-- role, into a database that has already had the substrate applied.
--
--   psql -U <service> -d <probe_db> -f fixture.sql
--
-- WHY THIS IS A FILE AND NOT A STRING INSIDE THE HARNESS. Two reasons and both
-- of them have already cost something.
--
--   1. It is SQL, so it belongs in a `.sql` file the way `literal-inserts.sql`
--      is. A fixture buried in a bash heredoc is SQL nobody can `psql -f`, and
--      this repository's rule is to parse what you hand out.
--   2. macOS bash is 3.2, and bash 3.2 mis-lexes a heredoc that lives inside a
--      command substitution when the heredoc body carries an ODD number of
--      apostrophes — `-- it's` in a comment is enough, and the whole script
--      fails to parse with a message pointing somewhere else entirely. Measured
--      on `/bin/bash` 3.2.57: the same heredoc at top level is fine, inside
--      `$( … )` it is not, and two apostrophes make it fine again. Nothing in a
--      hundred lines of a test harness should turn on the parity of its comment's
--      punctuation.
--
-- THE FOUR TABLES, AND EACH ONE IS HERE FOR A REASON.
--
--   t_serial      `bigserial` — the shape the defect was reported on.
--   t_identity    `generated always as identity` — the same defect one syntax
--                 away. `serial` writes an `a` (auto) dependency row in
--                 pg_depend and `identity` writes an `i` (internal) one, so a
--                 repair written against `bigserial` alone leaves this one
--                 locked out.
--   t_plain       `bigint primary key`, NO sequence. The negative control: most
--                 tables in any service have no serial column, so whatever walks
--                 the sequences has to be quiet on an empty result.
--   t_unrelated   `bigserial`, and NEVER passed to `protect_table`. It is the
--                 half of the negative control that a blanket
--                 `grant all on all sequences in schema public` fails: a grant
--                 wide enough to make the insert work on the protected tables and
--                 still hand the login role the sequence behind a table it has no
--                 business touching.

create table t_serial (
  id bigserial primary key,
  account_id uuid not null,
  label text not null
);

create table t_identity (
  id bigint generated always as identity primary key,
  account_id uuid not null,
  label text not null
);

create table t_plain (
  id bigint primary key,
  account_id uuid not null,
  label text not null
);

create table t_unrelated (
  id bigserial primary key,
  account_id uuid not null,
  label text not null
);

-- The probe. A plain plpgsql function, so it runs with the CALLER privileges and
-- not the owners: `security definer` would run it as `probe`, and every case in
-- the harness would pass on a substrate with no grants at all.
--
-- One row back: ok | id | sqlstate | message. The cases assert on the MESSAGE
-- and print the SQLSTATE beside it, because 42501 is what BOTH the policies and
-- the missing sequence grant raise — an assertion on the code alone cannot tell a
-- working boundary from a table nobody can write to. That is not hypothetical: a
-- probe in `courier` passed on a sequence denial until it also required the
-- message.
create or replace function probe_insert(p_table text, p_id bigint default null)
returns table(ok boolean, got_id bigint, sqlstate text, message text)
language plpgsql
as $p$
declare
  v_id bigint;
  v_state text;
  v_msg text;
begin
  perform cafaye.begin_account('00000000-0000-0000-0000-0000000000a1');
  if p_id is null then
    execute format('insert into %I (account_id, label) values ($1, $2) returning id', p_table)
      into v_id
      using '00000000-0000-0000-0000-0000000000a1'::uuid, 'probe';
  else
    execute format('insert into %I (id, account_id, label) values ($1, $2, $3) returning id', p_table)
      into v_id
      using p_id, '00000000-0000-0000-0000-0000000000a1'::uuid, 'probe';
  end if;
  return query select true, v_id, null::text, null::text;
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  return query select false, null::bigint, v_state, v_msg;
end
$p$;

grant execute on function probe_insert(text, bigint) to probe_app;