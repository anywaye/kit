# m44 — the honest gate profile, and the two written answers

**Branch:** `worker/kit-m44-gateprofile` · **Commit:** `1c69ae7` (profile) +
this report · **Run the profile is from:** preserved at
`/tmp/kit-m44-preserved/` (`before.tsv`, `before.log`, `before.exit`=0)

The honest top-20, the verdict counts (157 PASS / 0 FAIL / 5 SKIP), the
wall clock (493.30 s), and which of the old table's rows were artifacts are
all in **`PROFILE-gate-honest.md`**. This file carries the two written
answers the brief asks for, and the cut assessment.

## (a) Does kit's gate test any other repository?

**No. Confirmed with my own command, not the manager's grep.**

```
grep -rn '\.\./' tests/*.sh tests/*.py        # only 2 hits, both fixtures
grep -rn '\$ROOT/\.\.' tests/*.sh tests/*.py   # zero hits
grep -rn 'git clone\|git fetch\|git ls-remote' # file:// only — local
grep -rn 'curl \|wget '                        # localhost + GitHub releases
```

The two `../` hits are not repository references:

- `tests/provenance_test.sh:95` — `refuse source '../cafaye/identity'`.
  This is a **fixture string**: a relative-path *shape* the provenance
  stamper must refuse. The test asserts the stamper rejects it; it never
  reads that path.
- `tests/lint_test.sh:84` — a comment about `$TMPDIR` on macOS.

The `courier` references in `tests/deploy_test.sh` (`SERVICE_NAME=courier`,
`URL_CANARY="postgres://courier:…"`) are a **fixture service name** for
testing kit's own deploy script against a throwaway compose stack. The
deploy test builds its stack from `templates/deploy/reference/courier.deploy.yml`
— a file in kit's own tree — and never touches a sibling checkout.

Every `git clone`/`git fetch` in the gate is over `file://` against a bare
repository the gate itself builds from `$ROOT` (`fetch_test.sh:107`). Every
`curl` is either to `127.0.0.1` (a container the gate started) or to GitHub
releases (`bootstrap.sh`, fetching the pinned hadolint/zizmor binaries). No
`$ROOT/..` reference exists anywhere in `tests/`.

**The tree-copy layer that could have reached a sibling is gone** (`32df467`,
the owner's "no tree copies at all" decision). What remains is a gate whose
subject is exactly one repository: the one it is run from.

## (b) Is `tests/validate.sh` still needed?

**Yes. It is the only thing that exercises the substrate claims, and every
one of them is a claim no static check can make.** The docker/network tiers,
each with the substrate claim it alone proves:

| tier | the substrate claim only it proves |
| --- | --- |
| `no_telemetry_in_readiness.sh` | A service with the collector **killed** still serves, and `/readyz` goes 503 when its real dependency stops — telemetry is in nobody's readiness path. Only a running stack with a container killed can prove this. |
| `isolation_test.sh` | Service A cannot reach service B's database — the `REVOKE … FROM PUBLIC` boundary holds on a **real Postgres**. A parse check is green on a cluster with no isolation at all; the script's fourth assertion builds a control cluster without the revoke and requires it to let A in. |
| `onecluster_test.sh` | Two services share **one** postgres container, each with its own database and roles, and neither reaches the other's — through the developer's actual path (`bin/dev up`). The cluster tiers prove the property; this proves the path to it. |
| `tenancy_test.sh` | The account boundary holds with `FORCE ROW LEVEL SECURITY`, and the same proof **with FORCE removed goes red** on the owner half while the login half stays green. Only a real cluster with the substrate applied can show that asymmetry. |
| `fetch_test.sh` | A pinned kit ref fetches, a moving one is refused, and offline mode is real — a real subprocess talking to a real remote. A check that parsed `bin/dev` would pass on a script that fetches nothing. |
| `canary_test.sh` | A canary secret planted in ten leak shapes reaches **no exporter** — the redaction boundary holds against a real collector. Only a real collector with the canary planted can prove the secret didn't leave. |

The non-docker tiers carry the same weight: `provenance_test.sh` builds a
real image and proves the stamp it carries (and the eleven shapes it refuses);
`failfast_test.sh` proves a missing variable is refused **in seconds, by
name, with nothing started** — a wall-clock claim about a real `bin/dev up`;
`deploy_test.sh` proves the deploy distribution's `up`/`verify`/`rollback`/
`status`/`down` against a real compose stack.

**Recommendation: keep.** The gate is 493 s, and the profile shows why it
cannot be shrunk without dropping a claim: the top costs are the docker tiers
(200 s, substrate-backed), the parse region (99 s, already 4-way parallel and
spawn-latency-bound), and `lint_test` (31.6 s). None of these yields to a
cut that keeps every check id and every verdict. The flags already provide
the split a developer needs — `--no-observability` drops every docker tier
loudly, `--no-live` drops the three live tiers and keeps the two cluster
tiers — and a separate fast-default script would be a second entry point to
keep in step, which is the drift this repository exists to prevent. The
honest summary is that the gate is as fast as it can be while still being
the only proof of what it claims.

## The cut — assessed, not made

The brief's levers are overlap, then process start-up, then cache, with every
check id and every verdict preserved. Measured against the honest profile:

- **Overlap.** The parse region (99.2 s) and the shellcheck region (19.2 s)
  are already `check_par` regions at the 4-way cap. The remaining serial
  checks in the static phase are each under 0.1 s; parallelising them saves
  ~2 s across the run. The big single scripts (`lint_test`, `kamal_test`,
  the canary suite) are one `check` call each — overlapping them means
  restructuring the scripts, not the gate.
- **Process start-up.** The parse region's 99.2 s is spawn-latency-bound
  (its 55 `cpu` rows sum to ~9 s). Batching the spawns would change the
  check ids, which the brief forbids.
- **Cache.** `fetch_test` is already cached. Caching `lint_test` would
  skip it on a warm cache, but the preserved before-run was a cold miss, so
  the "after" measurement would need a second run to populate the cache
  first — and the saving is a cache hit, not a faster check.

**No cut was made.** The honest profile and the two written answers are the
deliverables; a cut that keeps every check and every verdict is not
available at this budget, and the brief names that a good outcome.

## Wall clock

| | wall clock | verdicts | how measured |
| --- | ---: | --- | --- |
| **before** | **493.30 s** | 157 PASS / 0 FAIL / 5 SKIP | the preserved run's `total` row |
| **after** | — | — | no cut was made, so there is no after-run to measure |

The before-run's rows tile the run exactly (phases + par = 493.278 s against
a 493.304 s total), so the 493.30 s is a measurement, not an estimate.
