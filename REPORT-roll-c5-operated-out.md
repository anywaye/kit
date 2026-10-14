# REPORT-roll-c5-operated-out.md

**Packet:** roll-c5-operated-out — the substrate carries what a customer RUNS.
**Worktrees:** kit in `moon/wt/roll-c5-operated-out` (branch `roll/c5-operated-out`),
gateway in `moon/wt/roll-c5-operated-out-gateway` (branch `roll/c5-operated-out`).
**Commits (kit):** `448014b` removal, `a43b99d` gate, plus the fixes commit and this report.
**Commits (gateway):** `ab29034` route change.

## 1. The boundary

Cafaye Box is where a customer sets up their box to run cafaye services from
the pantry; Box Pro is the paid layer on top. The substrate therefore carries
**the services a customer runs on their own machine** — identity, gateway,
courier, parlor, plus the observability three — and never the services Cafaye
operates, which the box reaches over HTTPS:

| service | who runs it | substrate? | reached at |
|---|---|---|---|
| identity, gateway, courier, parlor | customer, on their box | **yes** | in-cluster Services |
| alloy, grafana, prometheus | customer, on their box | yes | in-cluster |
| **pantry** — the operated registry | Cafaye | **no** | `https://pantry.cafaye.com` |
| **box** — the operated control plane | Cafaye | **no** | `box.svc.cafaye.com` (`KIT_SUBSTRATE_BOX_URL`) |
| **keyholder** — the registry's capability exchange | Cafaye | **no** | `registry.svc.cafaye.com` (`KIT_SUBSTRATE_REGISTRY_URL`) |

Three services, three reasons, each in its own repository — the next reader
finds the reason where they look (the licence, the manifest, the installer):

- **pantry** is proprietary by decision (OPS-D10, `0930a7a`): "the operated
  registry … it runs on Cafaye infrastructure. Nothing here may be run as a
  second, forked catalog."
- **box** is proprietary by decision (OPS-D2): "never part of … the Kit
  deployment substrate".
- **keyholder** is BSL-1.1, so a licence check *passes* it. Its exclusion is
  the flow argument: step 5 exchanges a capability at
  `KIT_SUBSTRATE_REGISTRY_URL`, and keyholder IS that exchange (its chart
  serves `host: registry.svc.cafaye.com`; its manifest requires box). A box
  running keyholder would exchange against itself — and would need its own
  GitHub App to mint installation tokens, exactly what the capability design
  exists to avoid. **A box talks to Cafaye's exchange.**

## 2. What came out (kit, `448014b`)

- `templates/substrate/manifests/applications/{pantry,box,keyholder}.yaml` —
  deleted. (box.yaml was still present on this branch; the box-out packet is
  a sibling, so this packet removes all three and merges cleanly either way.)
- `postgres-cluster.yaml` — the pantry block (roles, database, REVOKE/GRANT,
  limits, the five NOLOGIN RLS roles and three memberships) and the box
  block, plus both `managed.roles` pairs. Four services remain.
- `appproject.yaml` — the pantry/box/keyholder destinations gone; counts
  corrected (seven Applications); the reason written beside `destinations`.
- `install.sh` — role-secret loop, namespace loop, secret-existence loop,
  `REGISTRY_PULL_NAMESPACES`, all three `KIT_SUBSTRATE_DATABASES` refusal
  strings (`identity,gateway,courier,parlor`), the `pantry-secrets` block,
  the pantry migrate command/env cases, the inventory (`identity | courier`),
  the guard/launch loops, log lines. The pull-secret *object* is still
  written: no remaining Application references it, but the exchange path
  still needs the same-named object to fill — the comment says so.
- `local-cycle.sh` — default list is the manifest's set
  (`courier,gateway,identity,parlor`).
- `README.md` — service lists, the DBS export, the step-5 paragraph (the old
  11-of-14 measurement named artifacts that left; step 5 re-probes every
  run, so no count is restated), the ROUTE_TABLE paragraph (now: both
  entries name the operated origin, shipped by gateway's chart).

Not removed: any service's Dockerfile, chart, publish workflow or CI —
Cafaye operates all three and publishes them for its own infrastructure.

## 3. Gateway's routes (gateway, `ab29034`)

Both pantry entries name `https://pantry.cafaye.com` from the one
`ROUTE_TABLE` value in `charts/gateway/values.yaml` (plus the commented
example in `docker-compose.yml` and the `aud` assertion in
`pantry_shipped_table_test.go`). On the "one place" question: the chart
renders `.Values.env` verbatim into a ConfigMap (no `tpl`), so ROUTE_TABLE
itself is the one place — the runtime's own comment agrees a per-service
variable would be "N variables whose names encode a routing decision the
table states instead". The literal is a reference to the name
`cafaye/cafe` documents as `CAF_PANTRY_URL`
(`internal/resolve/pantry.go`, `internal/publish/publish.go`,
`internal/cli/resolve.go`), not a second copy; the values comment names
that authority. The chart needed no new value — this is reported rather
than forced. `go test ./internal/httpapi/` green.

## 4. How the check classifies a service's deployment role

`tests/substrate_test.sh` §28b checks the boundary three ways plus the route:

1. **Absence** — no Application file or `metadata.name` names an operated
   service; the Cluster (comments stripped) provisions no operated quoted
   identifier or `postgres-role-*` secret; `install.sh` (comments stripped)
   wires none. A comment explaining the removal cannot satisfy it.
2. **Licence** — every fleet Application's sibling LICENSE must permit a
   customer's box to run it: BSL-1.1 with Change Date + Change License
   passes; *either* proprietary operated sentence fails (box's "never part
   of … the Kit deployment substrate", pantry's "runs on Cafaye
   infrastructure … forked catalog"); anything else fails closed. Upstream
   charts skipped, absent checkouts noted (§11b precedent).
3. **Deployment role** — a fleet Application whose own `cafaye.yml`
   declares a load-bearing (`required`, default true) dependency on a
   licence-refused service is itself operated-side. The anchor set is
   *derived* from the sibling licences with the same classifier — no
   service name is typed in kit. This is the dimension keyholder needed:
   BSL passes (2), requiring box fails (3).
4. **Route** — the sibling gateway checkout's chart `ROUTE_TABLE` must name
   `https://pantry.cafaye.com` for both `/v1/pantry` and
   `/v1/pantry-writes`; any in-cluster baseUrl fails. Absent checkout is a
   note; a present one is graded.

No new marker was needed in either repository: keyholder's manifest already
declares `dependencies: [box, required: true]`, its chart already declares
`host: registry.svc.cafaye.com`, and the licences already carry both
operated sentences. The smallest honest addition was the §28b checks
themselves.

Merge-order note: kit's route check grades the gateway checkout beside it,
so it goes green once the gateway commit (`ab29034`) sits beside kit —
proven here against the gateway worktree (green), red on old-master
gateway (correct: that tree still ships the 503 shape), note on no
checkout. Merge gateway first, then kit.

## 5. The live 503

`GET https://api.cafaye.com/v1/pantry` at report time:

- **status 503**, body `{"type":"https://docs.cafaye.com/errors/unavailable",
  "title":"Service unavailable","status":503,
  "detail":"the service this request needs could not be reached", …}`.

That is gateway's own `unavailable` problem — the shape the brief calls
honest *once the deployed gateway dials the external origin*. The deployed
gateway still names the in-cluster address, so today's 503 is "nothing
answers `pantry:8080`"; after the route commit deploys it becomes "nothing
answers `https://pantry.cafaye.com`" — same status and body, different
cause, and the truthful one until Cafaye hosts the registry. The route was
not removed: no such route and registry-not-up are different facts.

## 6. Controls' verdicts

- Green, real tree: no operated Application/database/role/secret/migration;
  the four services and observability three unaffected —
  `bash tests/substrate_test.sh`: **381 passed, 1 failed, 0 skipped**.
  The one failure is the fleet-skew signal working as designed: the
  gateway checkout beside this worktree is still old master, so the route
  check reports `/v1/pantry names 'http://pantry:8080', want the operated
  origin` — red on the old tree, proven green against the gateway
  worktree (same check, same manifests, new chart: passes). Merge the
  gateway commit first and the kit gate is 382/382; on a fresh clone
  (no sibling checkout) the same check is a note, not a verdict.
- Green: gateway's ROUTE_TABLE names the operated origin for both routes
  (gateway's own gate + kit's check against the new tree).
- RED: master shape (operated Applications restored in a fixture) fails
  the absence check. RED: in-cluster ROUTE_TABLE fixture fails the route
  check. RED: BSL-but-operated (`ledger` requires licence-refused `box`)
  fails the deployment-role check — the dimension a licence-only check
  cannot see. RED: pantry/box/unclassifiable licences fail the licence
  check; a stale DBS naming box is refused; the migration inventory
  missing a shipped service fails.
- Independent (not a gate control): the live 503 above, status + body.
