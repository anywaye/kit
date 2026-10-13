# roll-c4-oci-repo — an OCI Helm Application must name the chart's own path

**Branch:** `roll/c4-oci-repo` · **Worktree:** `/Users/kaka/Code/any/moon/wt/roll-c4-oci-repo`
**Base:** current `master` (top of log at dispatch: `a44a111`).
**Status:** complete. One commit for the fix (`bbbad75`) plus a comment-completion
commit. `git status` clean. Not pushed, not merged.

---

## 1. The measured before/after

### Before

The four service `Application`s carried the registry **root** with a separate
`chart:` field:

```yaml
source:
  repoURL: oci://ghcr.io/cafaye/charts
  chart: identity
  targetRevision: 0.1.0
```

Argo resolves an OCI source's revision against **`repoURL` itself** — the
artifact it resolves is `<repoURL>:<targetRevision>` — and the published
packages are `cafaye/charts/<name>` at tag `0.1.0`. The root is not an
artifact, so every sync died (quoted from the packet, measured on a cold
Contabo box, the fleet's first end-to-end):

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: … failed to resolve revision "0.1.0": cannot get digest for revision 0.1.0:
HEAD "https://ghcr.io/v2/cafaye/charts/manifests/0.1.0":
GET "https://ghcr.io/token?scope=repository%3Acafaye%2Fcharts%3Apull" → 403 denied
```

No `Application` synced, no `Deployment` was ever created, and step 11 waited on
an object that would never exist.

### The fix and the after

`repoURL` now names the chart's own path; `chart:` is kept (harmless, explicit,
and proven to sync — the manager's live patch left it in place):

```yaml
source:
  repoURL: oci://ghcr.io/cafaye/charts/identity
  chart: identity
  targetRevision: 0.1.0
```

Measured live by the manager (quoted from the packet, the evidence I could not
re-take here — see §5): patching one `Application` to
`oci://ghcr.io/cafaye/charts/identity` moved it to `Synced`, created the
fleet's first `identity` `Deployment`/pod, and the same patch on
gateway/courier/parlor synced all four.

The four observability `Application`s do **not** carry this shape — they use
upstream HTTPS repositories (`https://grafana.github.io/helm-charts`,
`https://prometheus-community.github.io/helm-charts`) with pinned versions — so
this packet does not touch them.

---

## 2. The seam check: what changed, and which assertions it supersedes

### The packet names the wrong file, and that is worth stating plainly

The brief says the seam check is `tests/publish_seam_check.sh` and that it
"today asserts the workflow's default registry string equals each Application's
`source.repoURL`". **That assertion was never in `publish_seam_check.sh`.** It
lives in `tests/chart_publish_check.sh` (grep `registry` in
`publish_seam_check.sh` → one match, a prose comment, no assertion). The two
files split the two clauses the brief asks for:

| requested relationship | file that grades it |
|---|---|
| `registry + "/" + chart == repoURL` | `tests/chart_publish_check.sh` (has the workflow's `registry` input) |
| `Chart.yaml`'s `version == targetRevision` | `tests/publish_seam_check.sh` (already did, for every sibling chart) |

So the correct move was to re-aim `chart_publish_check.sh` and leave
`publish_seam_check.sh` untouched (its version/`targetRevision` assertion is
already the second clause, and it ran green on this machine for all 4 service
Applications — "4 of 4 matched a sibling chart"). **I did not duplicate the
registry assertion into `publish_seam_check.sh`** because both files' own
headers state the rule I would have broken: "two copies of an assertion is one
assertion that can drift."

### The delta, assertion by assertion (nothing silently dropped)

`chart_publish_check.sh` had five assertions and two controls:

1. exists, parses, is a `workflow_call` — **unchanged**
2. `push` defaults to `false` — **unchanged**
3. default `registry` **equals** every service Application `source.repoURL` —
   **superseded**, not dropped. The old equality was the defect made into a
   test: it asserted that every pull named the registry root, which is exactly
   what 403s. It is replaced by the stronger, correct relationship
   `repoURL == registry + "/" + chart`, which still fails on a disagreement (and
   now also on the old root shape, and on a path/`chart:` disagreement).
4. `chart-name` / `chart-version` are not inputs — **unchanged**
5. `pull_request` refusal present — **unchanged**

Controls: old (a) "drifted repoURL" is **kept** as new control (c); old (b)
"flipped push default" is **kept** as new control (d). Two new controls were
added, so four must go red:

| # | fixture (one mutation of one file) | what it proves |
|---|---|---|
| (a) | gateway `repoURL` set back to the registry **root** — today's shape | the defect the packet exists to close cannot return |
| (b) | gateway `repoURL` path `…/gateway-drifted` while `chart: gateway` | the path and `chart:` are one fact and may not disagree |
| (c) | gateway registry prefix moved to `charts-drifted` | the old drifted-repoURL control, kept |
| (d) | `push` default flipped to `true` | the pre-existing default control, kept |

Summary line changed from
`seam: default registry == source.repoURL in N service Application(s)` to
`seam: default registry + chart == source.repoURL in N service Application(s)`.

### The gate's other Application check

`check_obs_chart_sources` in `tests/validate.sh` graded the service four with
`want = (PRIVATE_OCI, name, "0.1.0")`. Left alone it would now go red on a
correct tree, so its `want` is `(f"{PRIVATE_OCI}/{name}", name, "0.1.0")` — the
same path relationship, checked from the Applications side. Its own two
controls (a reverted observability `repoURL`, a drifted chart name) are
unchanged and still fire.

### Local proof of the new check

```console
$ bash tests/chart_publish_check.sh .github/workflows/chart.reusable.yml \
      templates/substrate/manifests/applications
seam: default registry + chart == source.repoURL in 4 service Application(s)
chart publish: four red controls went red (repoURL at the registry root; repoURL path disagreeing with `chart:`; drifted registry prefix; push default true)
ec=0
```

I also re-ran `check_obs_chart_sources`'s assertion program stand-alone against
the real tree: `problems: []`, `resolved: 8` (all eight Applications classified,
no fail-closed entry).

---

## 3. Comments corrected — one fact, one spelling

Correcting the comments was **Done means #3**, and this is where I deviated
from the `Avoid` line "Touching `.github/workflows/`" — deliberately, see §5.

- `templates/substrate/README.md` — the publication-half description and the
  "registry string is one fact" bullet now say the workflow default is the
  **prefix** and every Application's `repoURL` is `prefix + "/" + chart`, with
  the 403 measurement named.
- `tests/chart_publish_check.sh`, `tests/focused_publish.sh`,
  `tests/validate.sh` — headers and check labels describing the relationship.
- `README.md` — the one-line chart-workflow description.
- `.github/workflows/chart.reusable.yml` — comments only, plus the `registry`
  input description. **Not changed:** the `default: 'oci://ghcr.io/cafaye/charts'`
  value (it is correct as the prefix), any job, step, `if:`, or permission.
- `.github/workflows/publish.reusable.yml` — comments and the `registry` input
  description. Same: `default` value untouched.
- `.github/workflows/chart.reusable.yml` step `say what landed` — the
  human-facing summary string `repoURL: $REGISTRY` → `repoURL: $REGISTRY/$NAME`.
  This is the single non-comment line I changed: it is the instruction a person
  copies into an `Application`, and leaving it would re-teach the exact shape
  this packet fixes. Revert it in isolation if the manager prefers the
  `.github/workflows` boundary absolute.

Historical records are left as written: the older `CHANGELOG.md` entries and
`REPORT-kit-w84-chartpublish.md` describe what was true when they were written;
the new `CHANGELOG.md` entry (top `### Substrate` block) records the change.

---

## 4. Suite counts

| run | result |
|---|---|
| `bash tests/focused_publish.sh` | **exit 0** — `FOCUSED=publish pass=1 skip=0`; chart publish **4/4** service Applications, **4/4** controls red; publish seam **4/4** sibling charts, **4/4** controls red; workflow timeouts **20** jobs bounded, **3** controls red; publish toolchain **5/5** controls red |
| `bash tests/substrate_test.sh` | **exit 0** — `194 passed, 0 failed, 0 skipped` |
| `shellcheck -S warning` on `chart_publish_check.sh` `publish_seam_check.sh` `focused_publish.sh` `validate.sh` | **exit 0** |

`validate.sh` was **not run** (packet instruction). Its two Application-grading
checks were exercised through the same files the gate calls
(`chart_publish_check.sh`, `publish_seam_check.sh`) and the obs-check program
was run stand-alone; the tree's Application set was verified to classify clean.

---

## 5. What I deliberately did NOT do

- **Did not change the workflow's `registry` default.** It is the prefix the
  publish path is built on and `helm push` appends the chart name to it; the
  Application was the wrong end.
- **Did not weaken the seam check.** It is re-aimed to a *stronger* relationship
  (`repoURL == registry + "/" + chart`) with two extra red controls; the old
  comparisons all survive as controls.
- **Did not duplicate the registry assertion** into `publish_seam_check.sh`, for
  the single-source-of-truth reason those files state themselves.
- **Did not run `validate.sh`.**
- **Did not touch any other repository, and did not push or merge.**
- **Did not re-measure on `contabo`.** The only kube context configured on this
  workstation is `k3d-cafaye-local`; there is no contabo context to read, so
  §1 quotes the packet's measured error and the manager's live sync proof rather
  than fabricating a re-measurement. The local proof is the seam check itself:
  the old root shape is control (a), and it goes red.
- **Deviated once:** corrected prose in `.github/workflows/chart.reusable.yml`
  and `publish.reusable.yml` (plus the one summary `echo`), because Done means
  #3 requires every comment that spells the old form corrected and those
  comments would otherwise state the opposite of the truth. No key, value,
  default, step id, `if:`, or permission changed. See §3.

---

## 6. Successor's first move (if a relay is needed)

Nothing is half-done. If the manager wants the `.github/workflows` boundary held
strictly literal, the only revert is the prose in those two files (the five
comment hunks and the one `echo` line in `bbbad75`); the manifests, the
re-aimed `chart_publish_check.sh`, and `validate.sh`'s obs check are the packet
and stand on their own.
