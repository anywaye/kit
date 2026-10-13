# REPORT — roll-c3-publish-seam

Branch `roll/c3-publish-seam`, worktree
`/Users/kaka/Code/any/moon/wt/roll-c3-publish-seam`, repo `cafaye/kit`. Three
commits, tree clean. Nothing pushed, nothing merged, nothing outside this
worktree touched.

## What was wrong, as measured

1. **`publish.reusable.yml` called its siblings with a repo-relative path that
   omitted `.github/workflows`** — `uses: ./image.reusable.yml` and
   `uses: ./chart.reusable.yml`. GitHub resolves a local reusable workflow
   from the repository root as `./.github/workflows/<file>`, so the reference
   cannot be resolved and the run is rejected at workflow-resolution time:
   `referenced_workflows: []`, no jobs, no check-runs, no log line — which is
   exactly what the four services' failed publish runs show. `actionlint`
   reported it on this tree (`could not read reusable workflow file for
   "./image.reusable.yml"`), walking the same path GitHub walks.
2. **The tag the charts pin was a tag nothing published.** Every service
   chart's `values.yaml` carries a literal `image.tag: "0.1.0"` beside
   `Chart.yaml`'s `appVersion: "0.1.0"` (gateway's `Chart.yaml` states the
   rule in prose: the pair "is what a release commits"), while
   `image.reusable.yml` published only `sha-<40>`, `<branch>`, `latest`. A box
   pulling the published chart asks ghcr for `:0.1.0` — created by nothing —
   and sits in `ImagePullBackOff` with no path from the symptom to the
   publish.

## What changed, and why

- **The two `uses:` paths are root-relative** (`./.github/workflows/
  image.reusable.yml`, `./.github/workflows/chart.reusable.yml`). The syntax
  is GitHub's own, verified against the "Reuse workflows" how-to, which lists
  `./.github/workflows/{filename}` and `$/.github/workflows/{filename}` for
  same-repository references. I kept `./` (the form the packet names, and the
  one that also works on GHES). Reason recorded at the code site.
- **The image tag is derived, not remembered.** A job whose whole body is
  `uses:` cannot carry steps, and the composer is the only party that knows
  `chart-dir`, so `publish.reusable.yml` grew a small `resolve` job that
  checks out and reads `appVersion` from `<chart-dir>/Chart.yaml` and hands it
  to the image job through `needs:` (a documented keyword on a `uses:` job).
  `image.reusable.yml` gained an `app-version` input (default empty) and one
  step appending `<image>:<appVersion>` to the metadata tag list. The shell
  logic was exercised locally: empty input passes the three original tags
  through unchanged; a set value appends exactly one line; a duplicate is
  deduped; the `GITHUB_OUTPUT` heredoc form carries the whole list.
  - No chart present: `resolve` exits 0 with an empty output, the image half
    runs, and the chart job refuses on its own exactly as it did before — an
    image-only service is not newly broken.
  - Chart present, no `appVersion`: the read fails by name. That is the
    invariant, not a soft note.
  - `sha-<40>` is untouched (asserted).
- **The template and README match the tree**: `templates/publish/publish.yml`
  names the fourth tag and the `chart-dir` override; README's publish row and
  adoption checklist state the appVersion rule (and no longer repeat the stale
  "delete the chart: job" advice, which a composed caller cannot do).
- **Fixed on the way, found by `actionlint`:** the image workflow's `digest`
  output was read from `steps.meta.outputs.digest` — an output
  docker/metadata-action has never produced — so it was empty for every
  caller. The digest is the build action's output; wired to
  `steps.build.outputs.digest` with the `id: build` the reference needs.
  `actionlint -oneline .github/workflows/*.yml` is now clean; it was NOT at
  HEAD (two pre-existing `digest` findings).
- **The proof:** `tests/publish_seam_check.sh` — one checker, called by the
  gate (`check_publish_seam`, beside `check_chart_publish`) and by
  `tests/focused_publish.sh` directly, the same single-source-of-truth rule
  `chart_publish_check.sh` states. It asserts (a) local `uses:` paths are
  root-relative and resolve, (b) caller/callee inputs agree in BOTH
  directions, (c) the image tag is the derived `needs.…outputs.app-version`
  and `sha-<40>` survives, (d) for every service Application a sibling chart
  found beside `$ROOT/..` agrees with it — chart `version` ==
  `targetRevision`, values `image.tag` == `appVersion`, never `latest` — and
  each found caller's `with:` only names declared inputs at a `chart-dir` that
  holds a `Chart.yaml`. Four red controls under the same checker: the
  unresolved path, a literal tag, a values tag the publish never produces, and
  the sha tag deleted. Every control's message was read, not just its exit
  code.

### The sibling ambiguity, decided on the record

`find_charts` asserts **every** sibling carrying the chart's name, never the
first. Measured here: the website repo (mid-rename — its `cafaye.yml` says
`name: website`, its `chart/Chart.yaml` says `name: parlor`) carried a
`parlor` chart from two worktrees at once, and a new `roll-c3-rename-identity`
worktree appeared beside `identity` during the run. All are asserted, all are
named in the notes. A service with no sibling (parlor's real repo, and all
four on a fresh clone) is NAMED in a note — not skipped silently — and the
in-repo assertions still run. CI stays green with no neighbours.

## The four callers: no edit required

Verified by reading each caller's `with:` block against the callee's declared
inputs, and by the new proof for the three siblings present (`identity`,
`gateway`, `courier-brk6`):

| service | caller passes | needed? | verdict |
|---|---|---|---|
| identity | `push: true` | yes | agrees |
| gateway | `push: true`, `chart-dir: charts/gateway/` | yes (its chart is at `charts/gateway/`) | agrees |
| courier | `push: true` (default `chart-dir: chart/` holds `Chart.yaml`) | yes | agrees |
| parlor | `push: true` | yes | agrees |

A caller passing an input the callee does not declare is a refusal at run
time — none does. The only OPTIONAL caller-side edit is syncing the
`templates/publish/publish.yml` header comment (I added a chart-dir paragraph);
it is comment-only, so nothing breaks if it is never copied over.

## The re-trigger story (no empty commits)

The four callers pin `cafaye/kit/.github/workflows/publish.reusable.yml@master`,
so the fix must be **on master first**: merge this branch and push. Then:

```sh
# find the failed runs (each is a run with no jobs — referenced_workflows: [])
gh run list --repo cafaye/identity --workflow publish.yml --status failure --limit 5
gh run list --repo cafaye/gateway  --workflow publish.yml --status failure --limit 5
gh run list --repo cafaye/courier  --workflow publish.yml --status failure --limit 5
gh run list --repo cafaye/parlor   --workflow publish.yml --status failure --limit 5

# re-run each: GitHub documents that re-running ALL jobs of a run re-resolves
# the reusable workflow from the specified reference — here, master at the
# current commit, i.e. the fixed file.
gh run rerun <run-id>
```

The honest caveat, verified against the "Reusing workflow configurations"
doc rather than assumed: a run rejected at workflow-resolution time has no
jobs, and if `gh run rerun <id>` refuses such a run ("you cannot rerun a
workflow that has no jobs" — check with `gh run view <id> --json jobs`), the
no-empty-commit path is to add `workflow_dispatch: { branches: [master] }` to
the caller (a permanent improvement, then `gh workflow run publish.yml --repo
cafaye/<svc> --ref master`). A fresh dispatch resolves kit at master exactly
like a rerun would. Prefer the rerun; it changes no file.

## Verification (narrow, as instructed)

- `bash tests/focused_publish.sh` — **green** (family syntax + chart publish
  check + new publish seam check; all six red controls went red).
- `actionlint -oneline .github/workflows/*.yml` — **clean** (was not, at
  HEAD: two pre-existing `digest` findings, now properly fixed).
- `yamllint -c lint/yamllint.yml` on every YAML I touched — clean.
- `shellcheck -S warning` on both scripts I touched — clean.
- `zizmor_gate.sh` with the sibling's zizmor: the finding set is **identical**
  to HEAD's (its self-repository audit prefers `$/…` over `./…`; both are
  documented, `./` is the GHES-compatible one, and the gate's red at HEAD is
  pre-existing — the gate's pinned zizmor predates that audit). My diff adds
  zero findings.
- The new shell logic was run for real, locally, in all five cases (no chart /
  appVersion present / chart without appVersion / tag append / tag dedupe /
  empty input passthrough).
- NOT run, per the brief: `tests/validate.sh`, `tests/substrate_test.sh`, any
  cluster or network operation. `validate.sh` was syntax-checked
  (`bash -n`) and edited in exactly two places (a wrapper and a `check`
  beside its chart-publish sibling).

## Deliberately not done

- No caller-side edit in the four service repos (they live outside kit and
  need no change).
- Not switching to `$/` — both spellings are in GitHub's how-to; the packet
  names `./`, and `$/` is GHEC-only.
- Not making `values.yaml`'s tag float or follow the workflow: the workflow
  follows the chart, never the reverse, and `latest` stays banned.
- Not adding a semver "release" input a human bumps in two places.
- Not reconciling the website/parlor chart-name disagreement — it is another
  repo's rename packet; the new check names it in its notes.

## Successor's first move, if any

Merge and push to master, then `gh run rerun` the four publishes and watch
for the `resolve` job's one-line summary ("chart appVersion 0.1.0") plus the
image job publishing four tags and the chart job pushing `:0.1.0`. If a rerun
is refused on a jobless run, the `workflow_dispatch` fallback is spelled out
above. Afterwards, `bash tests/validate.sh` is the manager's merge gate — this
packet never ran it.
