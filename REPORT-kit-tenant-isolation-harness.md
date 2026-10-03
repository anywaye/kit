# REPORT — `kit-tenant-isolation-harness`

**Branch:** `worker/kit-tenant-isolation-harness` (from `master` @ `c8d76df`)
**Commit:** `2bf0ff9`
**Budget:** one hour, spent about 1h45m — the overrun is in "what it cost to find out" below, and it is named rather than absorbed.

---

## 1. The tally, reported separately, because that is the whole point

```
PASS: mutations.sh — 1 control(s) green, 6 breakages planted and all 6 observed
      RED with the assertion they were written for named, each reverted and
      green again. 0 skipped.
```

**1 control. 6 breakages, all 6 observed red. 0 skipped, 0 environment skips,
0 unproven.**

The control, verbatim:

```
Running ExUnit with seed: 295767, max_cases: 16
......
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 6 passed
```

Six negative assertions against a real `postgres:17`, two accounts seeded
through courier's own `create/1`, 0.1 seconds.

## 2. Each breakage, with the literal receipt

Not "the harness covers unscoped lists". The line the suite actually printed.

| # | breakage | planted in | literal receipt | reverted |
|---|---|---|---|---|
| 1 | missing `WHERE` | `WebhookEndpoints.enabled/1` loses `endpoint.account_id == ^account_id`, keeps `endpoint.status == :enabled` | `1) test cross_tenant_enabled_list (Courier.KitTenantIsolationProbeTest)` | green again |
| 2 | missing bind parameter | `WebhookEndpoints.list/1` keeps the predicate and pins a **constant** instead of the caller's account | `1) test cross_tenant_list_own_row_visible (Courier.KitTenantIsolationProbeTest)` | green again |
| 3 | unscoped list | `WebhookEndpoints.page/3` — the query the HTTP index actually runs — loses its `where` | `1) test cross_tenant_list (Courier.KitTenantIsolationProbeTest)` | green again |
| 4 | unscoped update | `WebhookEndpointsController.update/2` resolves its row by id alone, bypassing the shared `fetch/2` | `1) test cross_tenant_update (Courier.KitTenantIsolationProbeTest)` | green again |
| 5 | unscoped delete | `WebhookEndpointsController.delete/2` resolves its row by id alone | `1) test cross_tenant_delete (Courier.KitTenantIsolationProbeTest)` | green again |
| 6 | IDOR on fetch-by-id | `Repo.get_by(WebhookEndpoint, id: id, account_id: account_id)` becomes `Repo.get(WebhookEndpoint, id)` | `2) test cross_tenant_fetch_by_id (Courier.KitTenantIsolationProbeTest)` | green again |

The recipe asserts **four** things per case, and the fourth is the one that makes
the first three mean something:

1. the mutation is in the file **by text** — `edit` refuses an anchor that no
   longer matches, and `grep -c` on the replacement proves the write landed;
2. the suite goes red **and names the assertion it was written for** — a red
   under a different name is reported as `WRONG FAILURE`, not as a pass;
3. the literal failure line is **kept**, not paraphrased;
4. **reverted, and green again** — the cost of the deletion, measured.

## 3. Three things the recipe found about itself, which are the interesting part

**Breakage 3 was aimed at the wrong function, and the recipe caught it.** The
first draft broke `WebhookEndpoints.list/1`. courier's controller does not call
`list/1` — it paginates through `page/3` — so unscoping `list/1` left
`test_cross_tenant_list` **green** and the recipe reported `WRONG FAILURE`
rather than a pass. **A breakage aimed at a function no entry point calls is a
breakage of a function, not of a surface**, and the only thing that noticed was a
recipe asserting on a named test rather than on an exit code.

**Breakage 6 is reported as `2)`, not `1)`, on purpose.** Dropping `account_id`
from `WebhookEndpoints.get/2` unscopes the controller's *shared* fetch, so
`update` and `delete` go red with it. The recipe prints the number the suite
printed. Filtering the output down to one name would have made the receipt look
tidier and made the finding wrong.

**Breakage 2 needed an assertion no denial test would have caught.** A predicate
bound to a constant reads as "zero rows". Every denial-only assertion is perfectly
happy with zero rows, so a suite built from denials alone would have reported
breakage 2 as green. That is what `cross_tenant_list_own_row_visible` is for, and
it is the same reason kit's own `tests/tenancy_test.sh` insists on **three denials
and one allowance**: the first denial is satisfied by a table with no policy at
all, which is the bug.

## 4. Why this is not a linter, stated as a property rather than as a virtue

A grep for `account_id` near a query is blind in exactly the cases above:

- **breakage 2** — the predicate is on the line, spelled correctly, and the value
  under it is not the caller's. Grep stops at the match.
- **breakages 4 and 5** — the entry point is not a query. `WebhookEndpoints.update/2`
  takes a struct, so the predicate that scoped it is four frames away at the
  controller's `fetch/2`, and a per-query lint sees a clean `Repo.update`.
- **breakage 6** — one word of the query is the entire authorization boundary, and
  the neighbouring line still mentions the account.

So the harness **runs** the service: a throwaway copy of the checkout
(`lib priv config test mix.exs mix.lock`; `deps` symlinked, `_build` local), a
real `postgres:17` container, **the service's own `mix ecto.migrate`** — not a
hand-written schema, because a harness that seeds a table it invented is measuring
its own DDL — two accounts seeded through courier's own `create/1`, and courier's
own context functions and Phoenix routes called as account A.

## 5. The claim, at the width it is actually proven

> **Cross-tenant isolation is proven for Elixir, on a service that scopes
> correctly. Five languages remain unproven.**

Not "the fleet is isolated". Not "cross-tenant isolation is covered". The
harness contains no Elixir, no Ecto and no knowledge of courier's tables: the
adapter contract is **five functions** (`tests/tenant_isolation/adapters/README.md`),
and the only language-specific part of the recipe is its six *anchors* — strings
of the service's own source. Go (identity, guard), Ruby, TypeScript, Python and
Rust are an adapter away and are not one today.

## 6. A change to `tests/validate.sh`, and why it was not optional

`docker_tier_project_name`'s `scripts` list was `os.listdir(tests_dir)` — the top
level only. The new harness lives in `tests/tenant_isolation/`, so it was in
neither `tiers` nor `uncovered`: the gate would have printed a tier count that did
not include it and said nothing about it at all. It brings a container up and
derives its container name and its host port from the session, so this is a check
whose scope was narrower than a reader would believe.

Now `os.walk`, and measured after the change:

```
PASS tests/  (no docker tier hardcodes a project, container, volume, image or host port name;
              every shared namespace is derived from the run)
       10 docker tier(s), 0 hardcoded container/volume/project/image name and 0 fixed host
       port; 0 script(s) under tests/ invoke docker without being a tier
```

Ten tiers where there were nine, and the new one is inside the rules rather than
beside them.

## 7. What the gate says, and what it does not

`bash tests/validate.sh --static-only --no-self-test --no-live --only='docker tier'`
→ **1 FAIL**, and it is not ours:

```
FAIL generated stack  (no repository commits the file caf dev generates)
  BLOCKING: cafaye-rb, cafaye-ts, docs, guard — caf.dev.compose.yaml is not ignored
```

That is a pre-existing fleet finding from the concurrently-landing
`worker/kit-fleet-generated-compose-01` work, in four other repositories, with
nothing in this diff touching it. **The full gate was not run to completion** —
`self_test` alone is *n* whole gates in sequence and is documented in `AGENTS.md`
as hitting its bound on a busy box, and this box has three other workers on it.
Run `bash tests/validate.sh` by hand before merging.

## 8. What is NOT done

- **Not wired into `validate.sh`'s phases.** It is a documented entry point
  (`bash reports/tenant-isolation-harness/mutations.sh`), not a gate phase. It
  needs the service checkout beside the repository, an Elixir toolchain and
  docker, and none of those are things a static phase can assume. §9 of the
  handoff says what the wiring should be and what it must not do.
- **Not a self-test recipe.** `tests/self_test.sh` breaks a copy of *this*
  repository and asserts *this* gate goes red. These six breakages edit another
  repository's query layer and assert an Elixir suite fails. One phase answering
  two questions is how the second one stops being checked.
- **Five languages unproven** (§5).
- **One service, one context.** Six surfaces out of courier's whole surface. A
  service that grows a seventh account-scoped entry point does not grow a seventh
  breakage automatically, and nothing here asserts that it should.

## 9. Reproducing it

```sh
# the whole packet, from a clean tree, against a courier checkout beside kit
KIT_SERVICE_REPO=/path/to/courier bash reports/tenant-isolation-harness/mutations.sh

# the harness alone: up, run one assertion, down. Export KIT_TENANT_SESSION so
# the three invocations share one database and one compilation.
export KIT_TENANT_SESSION=$$
bash tests/tenant_isolation/cross_tenant_harness.sh up
bash tests/tenant_isolation/cross_tenant_harness.sh run 'test cross_tenant_list '
bash tests/tenant_isolation/cross_tenant_harness.sh down
```

Runtime: **~2m20s** wall for the whole mutation pass on this box — one container,
one `mix compile` of the dependencies, thirteen suite runs at 0.1s each. The
container, the work directory and the build path are removed by `down` and by the
`EXIT` trap; the `postgres:17` image is deliberately left, because three other
workers share this daemon and pulling it again costs each of them the same two
minutes.