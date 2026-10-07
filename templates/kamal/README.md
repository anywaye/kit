# `templates/kamal/` — the deploy and backup configuration a service copies

> What this is, what it replaced, and the one question a reader will have about
> it ("do I need Ruby for this?") answered before they have to ask.

## The short version

kit does not ship a deployment tool. It ships **two configuration files**, the
shape `kamal` and `kamal-backup` expect, and one wrapper that does the two
things kamal-backup does not do.

| File | Copy to | What it is |
|------|---------|------------|
| `deploy.yml.erb` | `config/deploy.yml` | the Kamal config: service, registry, servers, proxy, accessories |
| `kamal-backup.yml.erb` | `config/kamal-backup.yml` | what to back up, where, how long to keep it |
| `drill.sh` | `bin/drill` | a restore drill that drops its scratch database and proves it restored rows |

`drill.sh` is deliberately the *only* executable in the set. Everything else is
configuration that a third-party tool reads.

## Why this replaced kit's own backup toolchain

kit-20 built a custom backup distribution — `templates/backup/` (a compose file,
a job script, a crontab), `templates/bin/backup.sh` (a hand-written restic
wrapper) and `docker/Dockerfile.backup` — 3,012 lines that reimplemented
the command surface `kamal-backup` already provides. It worked, and it was
wrong, because it was a second implementation of something that exists:

| what the custom toolchain did | what kamal-backup does |
|---|---|
| `pg_dump` piped into `restic backup` | `backup` |
| `schedule.crontab` | `backup.schedule: 1d`, with "last finished" state in a volume so a reboot does not trigger a full dump |
| retention flags by hand | `restic.retention` |
| `restic init` if absent | `restic.init_if_missing: true` |
| `templates/deploy/redact.py` wrapped around every command | `Redactor` inside the gem, applied to every command including the drill's check output |
| a hand-written restore path | `restore production`, `restore local` |
| a hand-written drill | `drill production` |
| a hand-written redacted report | `evidence` |

All of it is gone. `tests/validate.sh` asserts its **absence** — a check on a
path nobody should reference again — and self_test breakage 64 resurrects one
file to prove that check is load-bearing.

### And the two things that did NOT go, because the gem does not do them

**1. The scratch database outlives the drill.** `restore_to_scratch`
(`databases/base.rb:52-55`) validates the target and restores; it does not drop
it. The only `DROP SCHEMA` in the whole gem is `reset_current_schema`, which
runs on a restore into the **live** database. So `kamal-backup drill` leaves a
restored copy of your database sitting on the host, and the published runbook
for it makes cleanup a two-step manual procedure. A step an operator has to
remember after a failure is a step that does not happen after a failure.
`drill.sh` registers `trap cleanup EXIT INT TERM` **before** the scratch database
exists, and drops it with `WITH (FORCE)` — which is what makes it work, because a
drill that failed halfway leaves psql's own session attached and a plain
`DROP DATABASE` refuses with "database is being accessed by other users".

**2. A `SELECT count(*)` is not an assertion.** The gem decides the drill passed
or failed by the **exit status** of the `--check` command (`app.rb:307-325`, and
the CLI exits non-zero unless `result[:status] == 'ok'`). That contract is right,
and it puts the burden on the check to actually assert something. The check in
the reference runbook is:

    psql -tAc "SELECT count(*) FROM agents"

which exits 0 for 0 rows, for 4,000 rows, and for a table that exists because
`pg_restore` created it and copied nothing into it. A restore of an empty
database is reported as a successful drill. The count gets printed; nobody reads
it in a log aggregator.

`drill.sh` therefore generates a check whose exit status is the assertion:

    psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname=<scratch> <<'CAF_DRILL_SQL'
    DO $$
    DECLARE
    BEGIN
        IF (SELECT count(*) FROM "users") = 0 THEN
          RAISE EXCEPTION 'drill: table users is empty in <scratch>';
        END IF;
    END
    $$;
    CAF_DRILL_SQL

`ON_ERROR_STOP=1` makes psql exit non-zero on a script error, so `count(*) = 0`
becomes a failed drill. Name the tables that are content:

    bin/drill --table users --table documents

There is no default. A drill with no `--table` is a usage error rather than a
drill that quietly passes.

## The Ruby question, answered plainly

**A service image never needs Ruby. The operator's machine needs `kamal`, and
needs `kamal-backup` only if you want backups.**

Three separate things, and conflating them is how this question gets answered
wrongly:

1. **The service image.** Contains no Ruby. It is your language's runtime, your
   application, and nothing else. Nothing in this directory changes that.

2. **The backup accessory container.** The `ghcr.io/crmne/kamal-backup` image
   **ships its own Ruby** — it is a self-contained container, like every other
   Kamal accessory. This is why the `backup` block in `deploy.yml.erb` is an
   ordinary accessory: Kamal runs it the same way it runs postgres. The host
   never installs a gem for it.

3. **The operator's machine.** `kamal` is a Ruby gem and always has been; there
   is no non-Ruby Kamal, and pretending otherwise would be inventing a second
   deploy tool — the mistake this directory exists to end. So an operator
   deploying anything with Kamal has Ruby. That is not a requirement kit adds; it
   is a requirement Kamal has.

So for an Elixir, Go, Python, TypeScript or Rust service:

- **Deploying:** Ruby on the operator's machine. Unavoidable, and unchanged by
  anything here.
- **Backups:** Ruby on the operator's machine **and** a `kamal-backup` gem
  installed, because `kamal-backup drill` runs on the operator's side and drives
  the accessory over `kamal accessory exec`. If you do not want a Ruby gem
  locally, the scheduled backups still work on their own — the accessory's
  foreground scheduler loop is the only thing that takes snapshots, and it is a
  container. You lose the local `restore local` and `drill local` commands, not
  the backups.
- **Running the service:** no Ruby, ever.

`drill.sh` picks the binary the way kamal-backup itself does
(`KamalBridge#kamal_command`, lines 225-233): `bin/kamal` if the service
vendored it, `bundle exec kamal` if there is a Gemfile, `kamal` otherwise. So the
wrapper and the gem never disagree about which Kamal answered.

**The ERB is not an extra dependency.** Kamal evaluates `config/deploy.yml`
through `ERB.new(...).result` before parsing it, so ERB costs nothing to anyone
who already has Kamal. It is the same interpreter, not a second tool.

## The two files are ONE contract

`config/kamal-backup.yml` names secrets with `{ secret: NAME }`.
`kamal-backup validate` resolves those names out of the backup accessory's
environment, which it builds **from `config/deploy.yml` and nothing else**. So a
secret named in the backup config and missing from the accessory's `env.secret`
list is a valid YAML file that fails validation:

    ERROR (KamalBackup::ConfigurationError): RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required

Both files parse. Neither is internally inconsistent. The pair is wrong, and only
running the real tool finds it — which is why `tests/kamal_test.sh` does.

## Secrets

- **`config/deploy.yml` names secrets, never values.** Every credential is a
  string in `env.secret`. A rendered config is an ordinary file that gets
  committed, pasted into a ticket, and read over someone's shoulder; the only
  safe content for one is the name of the secret and where to find it.
- **`.kamal/secrets` is git-ignored** and holds the values. `kamal init` creates
  it; `kamal registry login --password-stdin` populates it.
- **The ERB refuses to render an empty required value.** `<%= ENV['X'] %>` with
  `X` unset renders an empty string, which YAML reads as a null list item and
  which surfaces three layers away as "cannot find a host". The templates raise
  and name the variable instead.
- **The drill's check carries no credential.** It is passed to kamal-backup as an
  argument, and arguments are visible to `ps`. The connection is taken from the
  accessory's own environment and split into `PG*` variables, which libpq reads
  from the environment — which is how kamal-backup itself passes `PGPASSWORD`
  (`CommandSpec.new(argv: %w[pg_dump ...], env: current_connection)`: in `env`,
  never in `argv`).

### The one honest limitation

At run time a Kamal secret **is** in the container's environment, and
`docker inspect` on the host will show it. That is a property of Kamal's model,
not of these templates, and it is weaker than the mechanism
`templates/deploy/entrypoint.sh` implements — tmpfs, delivered over stdin, never
in `Config.Env`. See `AGENTS.md` §"The custom deploy distribution is still
here"; the short version is that the two are
different tools for different jobs, and this packet did not delete the stronger
one.

## Retention

Stated explicitly rather than inherited:

    keep_last: 7, keep_daily: 7, keep_weekly: 4, keep_monthly: 6, keep_yearly: 2

kamal-backup 0.5.2's `DEFAULT_RETENTION` happens to be exactly these five
numbers, so leaving the block out would work today. It is written out anyway:
a retention policy that lives in a dependency's defaults is a retention policy
that changes on a version bump, and the diff at that moment is about the gem
rather than about the thing that decides how far back a restore can reach.

That is roughly 26 snapshots. **R2 has no object versioning and no Object
Lock** — a deleted object there is gone, and nothing here can bring it back. The
mitigation is bucket access control, not the retention policy.

## Adopting this

1. Copy `deploy.yml.erb` to `config/deploy.yml`, `kamal-backup.yml.erb` to
   `config/kamal-backup.yml`, and `drill.sh` to `bin/drill`. The drill is not
   optional: a backup that has never been proven to restore is not a backup,
   and `bin/drill` is the only thing that proves it.
2. `kamal init` (creates `.kamal/secrets`), then `kamal registry login
   --password-stdin`.
3. Export the five non-secret variables and render: `KIT_SERVICE`, `KIT_REGISTRY_ORG`,
   `KIT_REPO`, `KIT_WEB_HOST`, `KIT_APP_DOMAIN`. `KIT_REGISTRY` defaults to
   `ghcr.io`.
4. `kamal setup` — the accessories come up and the first deploy happens.
5. `bin/kamal accessory boot backup` and then take one by hand:
   `bin/kamal accessory exec -i --reuse backup kamal-backup backup`
6. **Drill it before you need to.** `bin/drill --table users` — into a scratch
   database, asserting rows, dropped afterwards.
7. `bin/kamal accessory exec -i --reuse backup kamal-backup evidence` for the
   redacted report. Keep it. It is the artefact that answers "are the backups
   actually working" without exposing a credential.

## Adapting per language

| | database adapter | notes |
|---|---|---|
| **go**, **rust** | `postgres` | no runtime migrations; nothing else changes |
| **ruby**, **python**, **node**, **bun**, **elixir** | `postgres` | migrations run from `.kamal/hooks/pre-deploy`, not a key in this file |

`deploy.yml.erb` is ONE file for all seven, deliberately: a per-language deploy
config is six files to keep correct, and the only thing that genuinely differs is
the migration command. Override it; do not fork the file.

**There is no `migrate:` key, and adding one is an error.** `migrate:` was
Kamal 1's way; Kamal 2.12.0 refuses the config outright with
`unknown key: migrate` — measured against courier's copy. Migrations run from a
hook, `.kamal/hooks/pre-deploy`, which is the service's own file to add and is
not a key in `deploy.yml` at all.
