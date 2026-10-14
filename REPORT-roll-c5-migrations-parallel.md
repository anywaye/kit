# Report: roll-c5-migrations-parallel

**Cold measurement:** step 10 (migrations) 25.000 s of a 219.46 s cold install — the fourth-largest cost centre after Postgres bootstrap (72.26 s), NATS (36.63 s) and the pull-secret (11.81 s). It is the only one that is not operator-bound: the Jobs are installer-created and each paid a fresh image pull/scheduling wait.

## Independence proof — no ordering constraint exists

Identity and courier each own a **separate database and OWNER role**, provisioned as distinct `CREATE DATABASE … OWNER …` statements in the same cluster:

- `templates/substrate/manifests/data/postgres-cluster.yaml` — `CREATE DATABASE "identity" OWNER "identity"` (line ~154) vs `CREATE DATABASE "courier" OWNER "courier"` (line ~178), each with `REVOKE ALL ON DATABASE … FROM PUBLIC` and `GRANT CONNECT` to both `svc` and `svc_app`, connection limits and timeouts per role. `spec.managed.roles` holds eight entries (`identity`, `identity_app`, `gateway`, `gateway_app`, `courier`, `courier_app`, `parlor`, `parlor_app`) with the asymmetric `inRoles: [svc_app]` membership.
- Local equivalent `templates/compose/postgres/initdb/10-cluster.sh` — same per-service `CREATE ROLE`, `CREATE ROLE …_app`, `CREATE DATABASE … OWNER …`, `REVOKE/GRANT`, `ALTER ROLE` blocks, swept by a per-database boundary loop.

The REVOKE boundary is **per-database**, so the two migrators touch disjoint catalogues and cannot see each other's rows. No migration reads the other service's schema; `migration_service_has_schema` in `templates/substrate/install.sh` lists exactly `identity | courier` as schema owners, and their `migration_env_args_for` connect via distinct DSNs (`DATABASE_URL` for identity, `COURIER_OWNER_DATABASE_URL` + `DATABASE_URL` for courier via `owner_database_url_for`). Gateway (`bin/migrate` no-op) and parlor (no database, front end) are explicitly documented as no-schema and skipped.

Therefore both Jobs are **independent by construction**. No waves needed; the whole independent set runs in one wave. If a future service's migration depends on another's schema it must be placed in a later wave, not in this launch set — the code's independence note states this as the single-wave invariant.

## Change

`templates/substrate/install.sh:install_migrations` — split the sequential `run → wait → run → wait` loop into two phases:

1. **Launch all** independent Jobs together: delete leftover `kit-migrate-<svc>` pod, `kubectl run … --restart=Never --image=$image` with the service's OWNER DSN and migrate entrypoint, collect `launched=("$svc:$image")`. No polling interleaved.
2. **Wait for the set** in launch order, each with the same `tries=36, sleep 5` (≈180 s) per-Job bound as before. `Succeeded` deletes the pod and marks `applied`; `Failed` (or timeout) collects `failed+=("$svc")` with per-Job `service:`, redacted `dsn:` (OWNER), `image:`, left pod, and `logs` following — identical to the before shape.

Failure still fails the install (`exit 1` naming `failed[*]`), a Job that never Completes still times out on today's bound, and the marker `substrate-migrations` in `data` records only the succeeded images (delete-then-create). Timing instrumentation (`log_step` / `step.done` with `seconds`) and headless JSONL per-Job outcomes are unchanged — the measurement ledger is the point of the packet.

`templates/substrate/README.md` — updated step 10 and the "The services' database schemas" section to name the disjoint-OWNER-databases source, the single-wave grouped launch/wait, per-Job failure/timeout guarantees, and the future-wave rule.

## Controls

All inserted in `tests/substrate_test.sh` §13h, using the same mock harness (`mock_kubectl` file-backed store).

| check | tree | want | verdict |
|---|---|---|---|
| applies grouped — last `run kit-migrate-*` before first `get pod kit-migrate-*` phase poll | real tree (two Jobs launched, then waited) | PASS | ✅ PASS |
| a failing Job still fails the install, naming the Job and OWNER DSN, printing pod logs | real tree, `MOCK_POD_PHASE=Failed` | PASS | ✅ PASS |
| a Job that never Completes still times out on today's bound (36 polls) | real tree, `Pending` forever, `sleep` no-op | PASS | ✅ PASS |
| step's `seconds` still reported per-step | real tree, `HEADLESS=1 DRY_RUN=1` JSONL `phase":"migrations"` `step.done` `seconds:` | PASS | ✅ PASS |
| **RED** — sequential (master) shape fails the grouped check | synthetic `run get run get` argv | RED | ✅ RED |
| **RED** — dependent Job launched in first wave fails ordering | synthetic fixture with `# courier depends on identity` but still `launched+=("$svc:$image")` grouped | RED | ✅ RED |

All 329 substrate checks pass (previously 327; the two new greens plus two reds, accounting for merged sections). `bash tests/validate.sh` passes (exit 0, 1 skipped tier unrelated).

## Cost claim

This packet addresses the **structural** cost — the per-Job image pull/scheduling wait that is paid once per Job in sequence. Parallel grouping makes the cold-install cost `max(Job)` rather than `sum(Job)`. On the cold measurement that is the 25 s window narrowing toward one Job's time; the exact saving is read off the next cold cycle's `step.done` `seconds` for `migrations`, not assumed here.

## Risks not taken

- No shared-database parallelization — the REVOKE boundary proves separation; a service that later shares a database would be ordered.
- No weaker wait — the 36-try/5-s per-Job poll is copied verbatim into the wait phase.
- No timing removal — `step.start`/`step.done` with `seconds` stays, and the `steps` array on `install.done` stays.
- No migration SQL change — scheduling only.
