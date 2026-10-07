# REPORT — kit-w84-chartpublish: the chart publish path

**Base commit:** `0b9f14c` (Merge worker/kit-w83-clusterissuer — the kit master
this branch was cut from). **Branch:** `worker/kit-w84-chartpublish`.
**Shape shipped:** the composed shape — `chart.reusable.yml` **and**
`publish.reusable.yml` **and** the caller template `templates/publish/publish.yml`.
No fallback was needed.

## What the packet is for

`DEPLOYMENT.md`'s deploy loop is pull-based: a commit changes a chart, Argo makes
the box agree. The consume end landed (eight Argo `Application`s in
`templates/substrate/manifests/applications/`, every one pulling
`oci://ghcr.io/cafaye/charts` at `targetRevision: 0.1.0`). The publish end did
not: nothing in the fleet ever ran `helm push` or `helm package`, so every
`Application` pointed at a registry nothing wrote to — and the failure is
silent. Argo reports no error; it just never finds the artifact. This packet
writes the publish end, as kit-owned CI contract, and proves the
publish/consume seam in kit's own gate.

## What landed

1. **`.github/workflows/chart.reusable.yml`** — a `workflow_call` reusable
   workflow, modelled on `image.reusable.yml`, that packages a chart directory
   and pushes it to a Helm OCI registry:
   - `push` is an input **defaulting to false** — publishing is opt-in at the
     call site; a reusable workflow that publishes by default is one every
     caller publishes from by accident.
   - `registry` defaults to `oci://ghcr.io/cafaye/charts` — the exact string
     every `Application` carries as `source.repoURL`. An input, because a
     self-hoster may point at their own registry; the default is the fleet's.
   - `chart-dir` defaults to `chart/`, where `caf gen chart` writes.
   - The chart's **name and version are read from `Chart.yaml`, never inputs**,
     and the step refuses loudly when either is empty. The OCI tag of a Helm
     chart IS its `version`, so the push tag and the pull `targetRevision` are
     one fact written twice; an input is a string a service copies into its own
     repo, and a copied string drifts from the chart it names.
   - Login is `helm registry login` with the workflow's own `GITHUB_TOKEN` —
     no PAT, no `secrets:` entry, nothing to rotate. `packages: write` is
     declared in the job and **granted by the caller**, exactly as the image
     workflow documents it.
   - helm is pinned — `v4.3.0` via the upstream script's own `--version`
     mechanism, never `@latest`.
   - The job **refuses to publish from a `pull_request`** before the install,
     the read and the package: a fork's token is read-only, and publishing from
     a PR is a registry write by untrusted code. Refusing before the attempt
     beats failing after it with a 401 that reads like a wrong password.
   - The chart the repo declares is the chart that is pushed — `version` and
     `appVersion` are never rewritten from git, and no `latest` tag is added.
   - A step summary prints the full OCI reference and the tag, because a log
     line is the only place a person can copy it from.

   **One measured correction** (found by the earlier attempt on this branch,
   kept): `helm push` APPENDS the chart's own name and version to whatever
   remote it is given. Measured against a local registry,
   `helm push probe-0.1.0.tgz oci://localhost:5555/charts` reports
   `Pushed: localhost:5555/charts/probe:0.1.0`, while the same package pushed
   at `oci://localhost:5555/charts/probe` reports
   `Pushed: localhost:5555/charts/probe/probe:0.1.0` — a chart no
   `helm pull oci://…/charts/probe` will ever find. So the push target is the
   registry, and the name read from `Chart.yaml` appears only in the reference
   the log prints.

2. **`.github/workflows/publish.reusable.yml`** — the composition: one
   `workflow_call` calling both `image.reusable.yml` and `chart.reusable.yml`,
   with the caller's single `push` threaded through, so a service's
   `publish.yml` is one `uses:` and the decision "what does a push publish" is
   made once, in kit. It declares the full `contents: read` + `packages: write`
   set at top level so the nested jobs keep `packages: write` through two
   levels of `workflow_call` (GitHub's rule for a chain of reusable workflows:
   permissions can only be maintained or reduced, never elevated), and its
   `concurrency.group` is `kit-`-namespaced per the fleet rule.

3. **`templates/publish/publish.yml`** — the caller a service copies to
   `.github/workflows/publish.yml`: `on: push: branches: [master]`,
   `permissions: contents: read` + `packages: write`, a `concurrency` group
   that does **not** begin with `kit-` (a colliding group is a job refused
   before it starts — no check-run, no log line) with
   `cancel-in-progress: true`, and one
   `uses: cafaye/kit/.github/workflows/publish.reusable.yml@master` with
   `push: true`.

4. **`check_chart_publish` in `tests/validate.sh`** — wired into the static
   phase beside the substrate check. Over the real files it asserts:
   `chart.reusable.yml` exists, parses, and is a `workflow_call`; its `push`
   input defaults to false; its default `registry` equals the
   `source.repoURL` of **every** `Application` in
   `templates/substrate/manifests/applications/` (the seam itself — both ends
   live in this repository, which is the whole reason the proof belongs here);
   the chart name and version are not inputs; and the `pull_request` refusal is
   present, read with comments stripped first because a check a comment can
   satisfy is not a check. The assertions live in one python program written
   to a temp file, so the real run and both controls run the same code.
   `templates/publish/*` joins the artifact-parses loop, so the caller
   template is parsed by `yaml_ok` like every other handed-out file.

5. **README, substrate README, CHANGELOG** — the README table gains the two
   workflows and the caller template, and the adoption checklist now points at
   the composed caller; the substrate README states the publication half
   plainly (which workflow publishes, where the caller template lives, that
   the OCI tag is the chart's `version`, that the `Application`'s
   `targetRevision` must equal it); the CHANGELOG records that the loop's
   publish end now exists and what remains.

## Red-first proof (re-measured on this tree, 2026-10-07)

The check was proven red before green, twice, under the same assertions the
real tree passes. Commands run from the worktree root:

```
bash tests/validate.sh --only="chart publish"     # green, with the seam proof
```

green output:

```
PASS chart publish  (workflow_call, push defaults false, registry == every Application repoURL, name/version not inputs, pull_request refused)
              seam: default registry == source.repoURL in 8 Application(s)
```

Control (a) — the seam control: one Application's `repoURL` drifted to
`oci://ghcr.io/cafaye/charts-drifted` (the publish end and the consume end
disagreeing is the defect the check exists to catch):

```
FAIL chart publish  (workflow_call, push defaults false, registry == every Application repoURL, name/version not inputs, pull_request refused)
              chart publish: …/templates/substrate/manifests/applications/gateway.yaml: source.repoURL is 'oci://ghcr.io/cafaye/charts-drifted' but the workflow's default registry is 'oci://ghcr.io/cafaye/charts' — the publish/consume seam
```

Control (b) — the default control: `push`'s default flipped to `true`:

```
FAIL chart publish  (workflow_call, push defaults false, registry == every Application repoURL, name/version not inputs, pull_request refused)
              chart publish: `push` default is True, not false
```

Both fixtures were restored (`git diff` clean after each), and the check
passes green on the restored tree. A control that does not go red is a failure
of the test itself; both go red.

## Final gate

```
bash tests/validate.sh
```

Exit code **0**. Counts: **182 PASS, 0 FAIL, 5 SKIP** (the 5 skips are the
reported environment kind — shellcheck/node/hadolint-class toolchains absent
on this machine — never hidden). 5 tiers ran under a time bound; none was
reached. The chart check passed in the full run with the seam proof:

```
PASS chart publish  (workflow_call, push defaults false, registry == every Application repoURL, name/version not inputs, pull_request refused)
              seam: default registry == source.repoURL in 8 Application(s)
```

## What remains (per-service adoption, one packet per repo)

- **gateway** — copy `templates/publish/publish.yml` to
  `.github/workflows/publish.yml`. gateway's chart is hand-written and
  committed; it is the reference chart.
- **courier**, **parlor** — run `caf gen chart`, commit `chart/`, then copy
  the caller. (parlor's chart must turn the Ingress on for `app.cafaye.com` —
  DEPLOYMENT.md's exposed-set rule.)
- **identity** — migrate its `.github/workflows/publish.yml` from calling
  `image.reusable.yml` directly to the composed `publish.reusable.yml`; run
  `caf gen chart` and commit `chart/`.
- The charts for identity, courier and parlor do not exist yet; until they do,
  `targetRevision: 0.1.0` is a promise, not a published artifact.

## Notes

- **A stale README sentence fixed.** The `image.reusable.yml` table row
  claimed `REUSABLE_WORKFLOWS` in `tests/validate.sh` is the list of what a
  caller may reach and that the gate fails on an undeclared `workflow_call`.
  That mechanism was cut with the self-test layer in w21 (ce12131, deliberate —
  "the check-level cut stands and is banked here") and has not been replaced.
  The row, which this packet already extends, now tells the truth: every
  workflow file is parsed by the gate's artifact loop and linted by zizmor;
  the enumeration is gone.
- The two commits already on this branch when this attempt started
  (`1b93920`, `5b16287`) were kept as correct after review; this attempt added
  the CHANGELOG entry, the README accuracy fix, the re-measured red-first
  proof, and the full gate run.
