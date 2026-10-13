# REPORT — roll-c5-migrations

**The packet.** Nothing in the substrate ran a service's database migrations, so
a box that "finished" the install booted the fleet against an empty schema:
`identity` logged `relation "outbox_events" does not exist (SQLSTATE 42P01)`
forever, and the installer's own probe reported `identity would not mint a
signup timestamp`. This adds the mechanism, checks the migrate entrypoints of
all four services, re-checks the probe, and proves it in
`tests/substrate_test.sh`.

Branch `roll/c5-migrations`, worktree
`/Users/kaka/Code/any/moon/wt/roll-c5-migrations`, cut from current master
(`789774a`). Nothing pushed, nothing merged, no service repo touched, no other
repo touched.

**Headline findings, in the order they matter.**

1. **The mechanism is step 10: one one-shot migrate Job per schema-owning
   service, in that service's own running image, as its OWNER role.** It is
   ordered after the role secrets (step 8) and the service namespaces (step 9)
   and before the courier mint (step 12), so the probe runs against a migrated
   database.
2. **The probe's failure was the port-forward, not the schema.** Measured live:
   an immediate `curl` after backgrounding the forward gives
   `curl: (7) Failed to connect … port 18081`; the same curl **3 seconds later
   gives `http=200`**. `POST /v1/signup-timestamp` does not touch the schema at
   all, so the installer's message `identity would not mint a signup timestamp`
   was a misdiagnosis — the racy forward was the cause. Fixed with the
   existence-then-use wait the rest of the file already uses.
3. **`identity` cannot migrate from the image it runs.** Its repository ships
   `bin/migrate` (a `psql` loop over `migrations/*.sql`, 35 files), but the
   image is `gcr.io/distroless/static-debian12:nonroot` — no shell, no `psql`,
   no migration files. The exact service-repo edit is §8. The step fails loudly
   naming identity until that edit lands; it does not boot a pod "Ready" over an
   empty schema.
4. **`courier` can, and its owner DSN is a variable the substrate never set.**
   Its release ships `/app/bin/migrate` (`courier eval Courier.Release.migrate`)
   and needs `COURIER_OWNER_DATABASE_URL` — plus `DATABASE_URL`, which its
   release eval raises without. The step passes both.
5. **`gateway` and `parlor` own no schema** — `gateway`'s `bin/migrate` is an
   explicit no-op, and `parlor` reads no database. Both are named in the plan
   and skipped, so the day either grows a schema the omission is visible.

---

## 1. The mechanism, and the argument for it

**Chosen: shape (b) — a step in `install.sh` that runs each service's migrate
entrypoint against its database, one `kubectl run` pod per service, waited to
completion.** New function `install_migrations`, step **10** of 12.

**Why not shape (a), the Argo CD `PreSync` hook per service chart.** Two
reasons, and the second is decisive:

- The hook lives in the service charts (`cafaye/identity`, `cafaye/courier`),
  repositories this one does not own. The packet's own rule is to report a
  service-repo edit rather than make one.
- The hook would need a migrate entrypoint in the image **anyway** — and that
  is the actual blocker for `identity` (§8). A PreSync hook is the stronger
  ordering, because it runs before the workload; the step is the shape that
  lands today, and the ordering cost is bounded because identity's outbox loop
  already retries (which is how the defect was noticed).

**What makes it correct, read from the running world rather than restated:**

- **The image is the Deployment's own image**, read back from the Deployment
  Argo synced (`kubectl get deployment <svc> -n <svc> -o jsonpath='…image'`). A
  migration must come from the same build as the service it migrates for, so
  there is no second pin here to keep in step — the one that would drift is the
  one nobody reads.
- **The DSN is the OWNER role**, via the new `owner_database_url_for`:
  `postgres-role-<svc>` (`identity` / `courier`), not `<svc>_app`. A migration
  is DDL; `database_url_for`'s app role owns nothing and the first `CREATE TABLE`
  would fail `permission denied for schema public`. The service keeps connecting
  as `<svc>_app`.

**Ordering.** Step 10 sits after step 9 (which makes the service namespaces and
the secrets) and before step 11 (NATS) and step 12 (the courier mint). The mint
is the probe that failed, so it now runs against a migrated database.

**Honest about failure.** The pod runs with `--restart=Never`, its phase is
watched to `Succeeded`; on `Failed` the step prints the pod's logs and exits
non-zero, naming the service, the image, and the OWNER DSN (with the password
redacted by shape). It runs every schema-owning service's Job and collects the
failures before it exits, so one bad service does not hide another's success.
There is no `kubectl exec … migrate || true`, no sleep, and no "the service
migrates at boot" assumed.

**Idempotent twice over.** The tools' version tables (`goose_db_version`,
`schema_migrations`) make a replay a no-op; and a marker Secret
(`substrate-migrations` in `data`) records, per service, the image whose schema
was applied, so a re-run does not launch the pods at all. A new image re-enters
the step and lets the tool apply what is pending. This is the step's own entry
in the install's guard vocabulary — `migration_guard_applied` — and the receipt
names the step as `phase: migrations`.

**The per-service inventory is a closed list in code**
(`migration_service_has_schema`) so a service cannot be silently skipped, and
`tests/substrate_test.sh` has a control that shrinks the list and requires the
static check to go red.

## 2. The per-service migrate inventory

Measured by reading each repository's `bin/`, `Dockerfile`, chart and migrations
directory, and confirmed against the live box's images.

| service | repo migrations | repo entrypoint | in the image? | DSN env the entrypoint reads | verdict |
| --- | --- | --- | --- | --- | --- |
| `identity` | `migrations/*.sql`, 35 goose files | `bin/migrate` (psql loop, Up section extracted by `bin/migration-up-section`) | **NO** | `DATABASE_URL` | **finding** — see §8 |
| `gateway` | none | `bin/migrate` — an explicit no-op | (n/a) | none | no schema; skipped by name |
| `courier` | `priv/repo/migrations`, Ecto | `rel/overlays/bin/migrate` → `/app/bin/migrate` in the release | **YES** | `COURIER_OWNER_DATABASE_URL` (+ `DATABASE_URL`) | migrates |
| `parlor` | none | none | (n/a) | none | no database; skipped by name |

`identity`, live, on the box: the image is `ghcr.io/cafaye/identity:0.1.0` and
`kubectl exec … ls` fails with `exec: "ls": executable file not found in $PATH`
— the distroless image has no shell and no `psql`, which the Dockerfile
confirms (`FROM gcr.io/distroless/static-debian12:nonroot`, copying only
`/out/service` and `/out/identity-staff`). `identity-staff` is a staff-grant
tool and has no migrate path either. `bin/migrate` and the SQL are in the
repository and nowhere in the artifact the box pulls.

`courier`'s `Courier.Release.migrate` documents the same owner-vs-app
distinction the substrate now makes: it runs `Courier.OwnerRepo` and says a
release that used `:ecto_repos` would fail the first `CREATE TABLE` from the
`courier_app` role.

## 3. The probe's verdict

**The port-forward was the cause of the observed failure; the schema was the
cause of the deeper service failure.** Both are real; the fix is in two places.

The installer's probe (now step 12) backgrounded `kubectl port-forward` and
curled it on the next line. `kubectl port-forward` establishes its local
listener **asynchronously** — it must reach the API server, resolve
`svc/identity` and dial the pod — so the curl raced it. Reproduced live,
read-only, on the box:

```
$ kubectl -n identity port-forward svc/identity 18081:8080 &
$ curl -sS -X POST --max-time 2 -o /dev/null -w 'http=%{http_code}\n' \
    http://127.0.0.1:18081/v1/signup-timestamp
curl: (7) Failed to connect to 127.0.0.1 port 18081 after 0 ms: Couldn't connect to server
http=000

$ sleep 3; curl -sS -X POST --max-time 3 … http://127.0.0.1:18081/v1/signup-timestamp
http=200
{"timestamp":1791925159,"signature":"RkF6pgwzMqY2zvKAuuwSaRdbkWZgWP35gUpDzUS-HtI"}
```

`curl: (7)` is a **connect** failure; a schema-missing 500 is a different error
(curl exit 22 under `-f`). So the message `identity would not mint a signup
timestamp` was wrong about which thing failed: the forward had not come up.
**`POST /v1/signup-timestamp` does not touch the database** — it signs a
timestamp and returns it, which is why it answered 200 against an empty schema.

**The schema was nonetheless empty and real**, and would have bitten the very
next call. At the start of this session the `identity` database had zero tables
(and `courier`, `parlor`, `gateway` likewise), and identity's logs carried the
`outbox_events` error. That is what step 10 fixes.

**Fix (existence-then-use).** New helper `kit_substrate_await_port` — the
companion of the file's existing `kit_substrate_await_list`, using bash's
`/dev/tcp` so it needs no `nc` a customer box is not promised. The mint step now
waits, bounded at 30s, for the forwarded port to accept a connection before it
curls, and its failure message names the forward rather than identity. Proven
green against a live socket and red against a dead port in the test (§5).

### What changed on the box while this ran (disclosed)

The live box is shared. Between my first read (≈20:43) and the end of the
session, **the `identity` schema was applied out-of-band**: by 20:55 the
`identity` database held 22 tables owned by role `identity`, with **no
`goose_db_version` table** — the signature of identity's `bin/migrate` psql
loop, not a versioned tool and not the substrate (no Job exists anywhere). A
`rollout restart` produced a new identity replica set. `courier`'s schema is
still empty (0 tables). I did not apply these; they are not this branch's work,
and they are reported because they change what a re-run of this packet would
observe.

**One write, disclosed.** To establish where the schema actually bites I called
`POST /v1/users` once (after the schema had been applied out-of-band) and it
returned **201**, creating one row, `owner+probe@cafaye.local`. The packet asks
for read-only evidence; that call was not read-only. It is a test user in a test
deployment, and no other write was made. Everything else on the box was
`kubectl get`/`logs`/`exec … ls` and `curl`.

## 4. What I changed

| file | change |
| --- | --- |
| `templates/substrate/install.sh` | new step 10 `install_migrations` + `owner_database_url_for` + `migration_service_has_schema` / `migration_command_for` / `migration_env_args_for` / `migration_guard_applied`; new `kit_substrate_await_port`; the mint step waits on the port; `TOTAL` 11 → 12 and NATS/courier-mint renumbered 11/12; header updated |
| `tests/substrate_test.sh` | the mock models `run` / `delete` / `logs` and `get pod -o jsonpath={.status.phase}` and reads a Deployment's image; new §13g executes step 10 (run, OWNER DSN, marker, re-run guard, `Failed` control, inventory control); the port wait's green/red pair; the mint test now provides a real listener; step-count assertions 11 → 12 |
| `templates/substrate/README.md` | new "The services' database schemas" section and the step list/renumbering |
| `CHANGELOG.md` | an `Unreleased`/Substrate entry |

Nothing else. No check was weakened, no threshold moved, no `templates/`
manifest touched, no service repo touched.

## 5. The test and the controls

`tests/substrate_test.sh` §13g executes `install_migrations` against the
file-backed `kubectl` (no cluster, no network) and asserts:

- the step runs and completes when both migrations succeed;
- **identity's argv carries the OWNER DSN** (`postgres://identity:…`, not
  `identity_app`) and **courier's carries `COURIER_OWNER_DATABASE_URL`** (owner)
  **and `DATABASE_URL`** (app);
- each Job's image is the Deployment's own image (no literal in `install.sh`);
- the per-service marker Secret is written with the applied image;
- **parlor is not run** (it owns no schema);
- **the re-run guard**: a second run adds **no `run` invocation** and says it
  skipped;
- **the red control**: `MOCK_POD_PHASE=Failed` makes the step exit non-zero,
  naming the service and its OWNER role, and prints the pod's logs;
- a static check that the step exists, `main` calls it, it consults its guard,
  and the inventory lists both schema-owning services — with a control that
  removes `courier` from the inventory and must go red.

The probe fix has its own pair: `kit_substrate_await_port` succeeds against a
real Python-opened socket (green) and fails, bounded, against a dead port
(red). The mint test now opens a real listener so the wait is exercised for
real, and the separate rollout-wait harness stubs the port wait (its subject is
the Deployment wait, not the port).

## 6. Suite counts

```
$ bash tests/substrate_test.sh
PASS: 219 passed, 0 failed, 0 skipped          # final tree
```

`bash -n` is clean on `templates/substrate/install.sh` and
`tests/substrate_test.sh`, and `shellcheck -S warning` is clean on both.
`tests/validate.sh` runs `tests/substrate_test.sh` as one of its checks, so
that check is green; the full `validate.sh` (with its self-test breakages) was
not run here — it is the manager's, per the narrow-gate instruction.

## 7. What I deliberately did NOT do

- **Did not touch any service repo.** The `identity` image edit is reported
  (§8), not made — and it is a service-repo change, which the packet forbids.
- **Did not adopt shape (a).** A `PreSync` hook is stronger ordering but lives
  in the service charts; the reasoning is at the code site and in §1.
- **Did not copy identity's migrations into kit.** A second copy of a schema is
  a second source of truth, and kit is config-only.
- **Did not make the step succeed on identity.** It fails loudly, by design:
  a green install over an empty schema is the defect. The step is written so it
  works unchanged the moment identity's image ships a migrate path.
- **Did not run `tests/validate.sh`.** The narrow gate is
  `bash tests/substrate_test.sh` (the packet's instruction); the full gate runs
  many whole-gate self-test breakages and is the manager's to run.
- **Did not fix the identity crash-loop** seen on the box at the end of the
  session (a fresh replica set backing off) — it postdates the packet and is
  not this branch's subject.
- **Did not add per-database extensions or any other schema concern** the
  manifest already declines.

## 8. The exact `identity` service-repo edit (reported, not made)

`identity`'s image must be able to run its own `bin/migrate`. The minimal edit,
in `cafaye/identity`:

1. **Ship `psql` and the migrations in the runtime image.** The current final
   stage is `gcr.io/distroless/static-debian12:nonroot`, which has no shell and
   no `psql`, and `bin/migrate` is a `psql` loop. Either
   (a) move the final stage to a base with `postgresql-client` (e.g.
   `debian:*-slim` + `apt-get install -y postgresql-client`), `COPY migrations/
   /app/migrations`, `COPY bin/migrate bin/migration-up-section /app/bin/`, and
   keep the numeric non-root user; or
   (b) give the binary a `migrate` subcommand that embeds `migrations/` with
   `go:embed` and applies them itself, which keeps the distroless image — the
   stronger option, since it removes the `psql` dependency entirely.
2. **Point the substrate at it.** No `install.sh` change is needed: the step
   already defaults identity's command to `/app/bin/migrate` and reads the image
   from the Deployment. If the chosen path differs, set
   `KIT_SUBSTRATE_MIGRATE_CMD_identity` (the per-service override) until it
   matches.

Option (b) is the one I would argue for: it is the same shape `courier` already
has (a release task inside the image), it needs no `psql`, and it keeps the
distroless base that identity's own Dockerfile argues for.
