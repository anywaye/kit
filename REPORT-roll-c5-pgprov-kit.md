# REPORT roll-c5-pgprov-kit — kit's own CI provisions the tenancy tenants with the real init script

Branch `roll/c5-pgprov-kit` (worktree `wt/roll-c5-pgprov-kit`), two commits on top of `4888454`:

- `7e45411` (previous attempt, kept for direction): `services.postgres` + provisioning step in the `none` job.
- `fefcc63` (this attempt): replaced the step's hand-rolled SQL with the template itself.

## 1. Provisioning shape

The `none` job keeps `services.postgres: postgres:17-alpine` (default superuser untouched, fleet
convention) and a `provision tenancy substrate (alpha, beta)` step that runs
`templates/compose/postgres/initdb/10-cluster.sh` **unmodified** against the service, with
`KIT_POSTGRES_DATABASES=alpha,beta`, `POSTGRES_USER/DB/PASSWORD=postgres`, `PGHOST=localhost`,
`PGPORT=5432`, `PGPASSWORD=postgres`. The template is the source of truth; the workflow only names
which tenants to make. A topology verify follows (each database exists, each `_app` role is a
non-superuser LOGIN, `alpha` can `SET ROLE alpha_app`), mirroring assertion 0 of
`tests/tenancy_test.sh`. RLS untouched: FORCE stays per table in `substrate.sql`.

Why not the hand-rolled SQL: the previous copy omitted `GRANT <svc>_app TO <svc>` — the asymmetric
membership every language driver (`SET ROLE`) and tenancy assertion 0 requires — so a proof against
that service failed at topology before reaching RLS. A copy also drifts the day the template changes
(limits, timeouts, the sweep); invoking the file cannot drift.

## 2. Matrix decision (at the code site, `none` job header)

`full -> language: none` is **kept**. Kit is the one repo shipping `tests/validate.sh`, so `none` is
meaningful here and only here — it is kit gating itself, the release proof. The guard's refusal was
read first (the file exists at this path, so the entry runs the gate, not the refusal). A service
repo with no gate of its own must pass a real language.

## 3. Local runs (scratch Postgres, `postgres:17-alpine` on port 15599, `docker rm` after)

Provisioning (exact step body, only the port adapted):

```
[cluster] provisioning alpha
[cluster] provisioning beta
NOTICE:  boundary applied: alpha reachable only by its own role and postgres
NOTICE:  boundary applied: beta reachable only by its own role and postgres
NOTICE:  boundary applied: postgres reachable only by its own role and postgres
[cluster] done: 2 service database(s), an owner and a non-owner login role each, PUBLIC holds CONNECT on none of them
```

Step verify block: `alpha db: 1`, `alpha_app login non-superuser: 1`, `beta db: 1`,
`beta_app login non-superuser: 1`, `alpha can SET ROLE alpha_app` — all green.

The packet's error line, now as the boundary working (not the failure):

```
psql: error: connection to server at "localhost" (::1), port 15599 failed: FATAL:  permission denied for database "beta"
DETAIL:  User does not have CONNECT privilege.
```

`substrate.sql` installed as `alpha` on `alpha`; `isolation.sql`: **54 assertions, 0 fail**.
FORCE-removed control (same mutation `tenancy_test.sh` uses, explanation paragraph intact):
**16 red, every one `owner/…`, 0 `login/` red** — then the real substrate restored. RLS unweakened.

## 4. Gate and lint

- `actionlint -oneline .github/workflows/*.yml`: clean. Edited file has no line over 120 cols.
- `bash tests/validate.sh` (full, no flags, log `/tmp/gate-roll-c5-pgprov-kit.log`): every docker tier
  PASS — `isolation_test.sh`, `tenancy_test.sh` (with FORCE control), `onecluster_test.sh`,
  `failfast_test.sh`, `no_telemetry_in_readiness.sh` — and the lint phase PASS with linters executed.
  It needs sibling checkouts beside the worktree for the fleet sweeps; they were present
  (`wt/` holds identity, parlor charts, etc. — see the publish-seam notes in the log).
- 8 skips, all named and environmental (3 SQL-by-design, 2 TS-parser, 3 rustc-absent).
- **1 FAIL, pre-existing and not mine**: `every run: body` flags
  `image.reusable.yml :: jobs/build/steps/6` (`tags` prefix-assigned then read). This branch predates
  master's `b535158`, which fixed exactly that step ("no longer splits a quoted assignment across
  lines"); the file is untouched by this packet. Left red and reported, not weakened, not scope-crept.

## 5. Deliberately NOT done

- No `GRANT`/password shortcut around the boundary; roles carry the service password (isolation is by
  privilege, never by secret, per the script's own comment).
- No second copy of provisioning logic anywhere; no new workflow input; no change to `ci.yml`.
- No cherry-pick of `b535158` (another packet's fix; the red is documented above for the successor).
- No push, no merge. Successor's first move: rebase onto master when the substrate series lands, then
  the gate should be fully green.
