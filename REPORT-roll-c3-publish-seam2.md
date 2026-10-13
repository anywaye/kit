# REPORT — roll-c3-publish-seam2

**Where:** worktree `…/moon/wt/roll-c3-publish-seam2`, branch
`roll/c3-publish-seam2`, repo `cafaye/kit`. Three commits, nothing pushed,
nothing merged, no other repo touched.

**What this packet is for.** The publish path resolved for the first time (the
previous packet fixed the root-relative `uses:` and the image-tag seam), and
two more steps — each of which had therefore never once succeeded anywhere in
the fleet — failed in identity's `publish` run. This packet fixes both, gives
each a proof with a red control, and records the decision on where the
provenance stamper lives.

---

## Defect 1 — the helm pin's verification used a flag Helm 4 removed

**What it was.** `chart.reusable.yml`'s `install helm (pinned)` step installs
helm **v4.3.0** through the upstream installer, then ran `helm version
--client` "to print the pin in the log". Helm 4 removed `--client` (the
client/server split died with Tiller). Measured:

```
helm installed into /usr/local/bin/helm
Error: unknown flag: --client
##[error]Process completed with exit code 1.
```

The verification step killed the chart job at its own last line, before it
packaged anything. The local helm on a developer's machine is **v3**, where
`--client` is valid — which is exactly why nothing local ever saw it.

**The fix.** The pin is now one `env.HELM_PIN` value used twice — to install
and to verify:

```sh
curl -fsSL …/get-helm-3 | bash -s -- --version "$HELM_PIN"
helm_version="$(helm version --template '{{.Version}}')"
if [ "$helm_version" != "$HELM_PIN" ]; then
  echo "chart: helm $helm_version is not the pinned $HELM_PIN — a different release resolved" >&2
  exit 1
fi
echo "chart: helm $helm_version (the pin)"
```

**The decision, and the source.** `--client` is gone in v4 but `--template`
survives: Helm 4.3.0's own `helm version` documentation lists the options as
`--short` and `--template` (plus `-h`) — fetched from `helm.sh/docs/helm/
helm_version/`, not assumed from the local v3. The check **can fail**: it
compares the installed version against the pin and exits non-zero naming both,
because a version printed for the log is a log line, not a verification.
Verified locally that the template form emits the version (`v3.22.0` here; v4
documents `.Version` identically).

## Defect 2 — the provenance stamper was read from the caller's checkout

**What it was.** `image.reusable.yml`'s `stamp provenance` step ran
`KIT_PROVENANCE_SOURCE_DIRTY=clean sh docker/provenance.sh --validate` **in the
caller's checkout**. `docker/provenance.sh` lives in **kit**; identity, gateway,
courier and parlor carry no `docker/` directory at all. Measured:

```
sh: 0: cannot open docker/provenance.sh: No such file
##[error]Process completed with exit code 2.
```

No image in the fleet has ever been published.

**The decision on the stamper's home — and why.** A new step fetches kit's
`docker/` tree into `$RUNNER_TEMP` with a sparse `git fetch`, pinned to

```
KIT_REF: ${{ job.workflow_sha }}
```

Three candidate shapes were on the table; the reasons are:

- **`actions/checkout` of `cafaye/kit` — rejected.** The action refuses a
  `path:` outside the workspace (its own `input-helper.ts` throws "Repository
  path … is not under …"), and a kit checkout *inside* the workspace would be a
  second git repository sitting in the **build context** — this job builds from
  `inputs.context`, defaulting to `.`, so its files would be swept into every
  `docker build`. `$RUNNER_TEMP` is per-job scratch, outside the context, and
  the `git fetch` shape is the one `ci.reusable.yml`'s own conformance fallback
  already uses for the same two reasons.
- **`curl` from `raw.githubusercontent.com` — rejected.** Same ref problem,
  and it adds a second fetch mechanism where the tree already has a proven one.
- **A vendored copy per caller with a drift guard — rejected.** Four-to-nine
  copies of a 33 KB script, each of which can drift from kit's, is the exact
  failure kit exists to prevent; and a caller with no `docker/` today would
  need one added.
- **An input like `ci.reusable.yml`'s `kit-lint-ref` — rejected in favour of
  `job.workflow_sha`.** The reviewer's instruction was to pin to the reusable
  workflow's own ref, never `master`. An input defaults to `master` and is a
  second pin a service must remember to raise; `job.workflow_sha` is the
  documented commit of the reusable workflow file **itself** ("the commit SHA
  of the workflow file that defines the current job", and for a reusable
  workflow that file is kit's, not the caller's), so a caller pinned to a SHA
  gets that SHA's stamper with no caller change. This is the one ref that
  cannot drift.

The step **refuses by name** if the script is absent (a missing-file error deep
in a job is today's failure mode), naming the path and the ref:

```sh
script="$kit_dir/docker/provenance.sh"
if [ ! -f "$script" ]; then
  echo "image: kit's provenance stamper is not at $script" >&2
  echo "image: fetched cafaye/kit@$KIT_REF (sparse '$KIT_SPARSE') with no docker/provenance.sh" >&2
  echo "image: the stamp cannot run without it; an unstamped image is worse than a refusal" >&2
  exit 1
fi
echo "KIT_PROVENANCE_SCRIPT=$script" >>"$GITHUB_ENV"
```

and the stamp step runs `$KIT_PROVENANCE_SCRIPT --validate`. **No secret**:
`cafaye/kit` is public, so the clone needs no token, and
`GIT_TERMINAL_PROMPT=0` makes a future private repo fail rather than hang.

**The mechanism was proven live**, not assumed:

```
$ git ls-remote https://github.com/cafaye/kit.git master
ffed1127a20650a7c3cdaf01864f9cc042160444
$ # git init; remote add; sparse-checkout set --no-cone docker;
$ # git fetch --depth 1 --filter=blob:none origin <sha>; checkout FETCH_HEAD
fetched-by-sha ok:    33147 bytes     # docker/provenance.sh
```

## The proof, and the red controls

`tests/publish_toolchain_check.sh` — standalone, called by **both**
`tests/focused_publish.sh` (the narrow gate) and `tests/validate.sh` (the full
one), so a PASS means the same thing in each. On the parsed workflows with
comments stripped:

- **H1** no `helm version` invocation carries a flag the pinned major lacks;
  the allowed set is Helm 4.3.0's `--template`/`--short`/`-h`, and `--client`
  is the regression it is aimed at;
- **H2** the install step compares the installed version against `env.HELM_PIN`
  in a test that exits non-zero;
- **H3** the pin is one value — `env.HELM_PIN` — with no `vN.N.N` literal beside
  it in the run body;
- **P1** no run body **in any workflow** invokes `docker/provenance.sh` through
  the caller-relative path;
- **P2** kit is fetched from `${{ job.workflow_sha }}` into `$RUNNER_TEMP`
  (never a `master` literal);
- **P3** the fetch guards the file with `[ ! -f … ]` and exits non-zero.

**Five red controls**, each a one-token edit in a copy of the real files, all
red under the same checker — and each verified red **for its own reason**, not
a coincidental failure:

| control | edit | goes red via |
|---|---|---|
| (a) | `helm version --template` → `helm version --client` | H1 |
| (b) | `!=` → `==` (a check that cannot fail) | H2 |
| (c) | `sh "$KIT_PROVENANCE_SCRIPT"` → `sh docker/provenance.sh` | P1 |
| (d) | `KIT_REF: ${{ job.workflow_sha }}` → `KIT_REF: master` | P2 |
| (e) | `if [ ! -f … ]` → `if [ -f … ]` (guard inverted) | P3 |

## The `job.workflow_sha` caveat, named rather than hidden

`job.workflow_sha`/`workflow_ref`/`workflow_repository` are documented GitHub
contexts, but **actionlint 1.7.12's `job` schema predates them**, so it reports
a false positive on the valid expression. `.github/actionlint.yaml` therefore
carries **one** reasoned ignore, scoped to `image.reusable.yml` and the single
message `property "workflow_sha" is not defined`. It is not a wildcard: a second
real finding in that file still fails the run. If actionlint's schema catches
up, delete the file — the workflow does not depend on it. (Also noted: the
properties are not available on GitHub Enterprise Server; these callers are on
github.com, and `ghcr.io` is already the registry.)

## Verification (narrow, as instructed)

- `bash tests/focused_publish.sh` — **green**: family syntax + chart-publish
  check + publish-seam check + workflow-timeouts check + the new toolchain
  check, with all red controls (4 + 3 + 5) red.
- `actionlint -oneline .github/workflows/*.yml` — **clean**.
- `shellcheck -S warning` on `tests/publish_toolchain_check.sh` and
  `tests/focused_publish.sh` — clean. (actionlint's own shellcheck pass also
  covers the `run:` bodies, and was clean.)
- `yamllint -c lint/yamllint.yml` on the three YAML files I touched — clean
  (`.venv` built in this worktree for the parser; `pyyaml` and `yamllint`
  installed there).
- The new shell logic was run for real: the helm `--template` form (`v3.22.0`
  locally); the stamper with the workflow's env shape (`exit 0`); the git fetch
  by **SHA** against the live public remote (`docker/provenance.sh`, 33147
  bytes).
- `bash -n tests/validate.sh` — clean; edited in exactly two places (the
  `check_publish_toolchain` wrapper beside `check_publish_seam`, and one `check`
  call).
- **NOT run**, per the brief: `tests/validate.sh`, any cluster operation, any
  docker stack.

## What the manager must do to re-trigger the publishes

1. Merge this branch to kit `master` (the callers resolve
   `cafaye/kit/.github/workflows/publish.reusable.yml@master`; nothing in a
   service repo changes).
2. Re-trigger each of the four services. The reliable path is a **fresh
   dispatch**, because a run that was refused at workflow-resolution has no
   jobs and `gh run rerun` refuses jobless runs:

   ```
   gh workflow run publish.yml --repo cafaye/identity --ref master
   gh workflow run publish.yml --repo cafaye/gateway  --ref master
   gh workflow run publish.yml --repo cafaye/courier  --ref master
   gh workflow run publish.yml --repo cafaye/parlor   --ref master
   ```

   (`workflow_dispatch` now exists on the callers; the previous packet added
   it.) For identity's run in particular, which *did* have jobs, `gh run rerun
   <id>` also resolves `@master` fresh and should work.
3. **Watch for**, in the image job: the new `kit (the provenance stamper)` step
   succeeding (it fetches kit at the workflow's own SHA), then `stamp
   provenance` running `$KIT_PROVENANCE_SCRIPT --validate` and emitting the four
   outputs; and in the chart job, `chart: helm v4.3.0 (the pin)`. Success is:
   the image publishes four tags (`sha-<40>`, branch, `latest`, chart
   `appVersion`) and the chart pushes `:0.1.0`. **Any red now names the piece**
   (the missing stamper path, or the mismatched helm version).

## Deliberately not done

- **No caller-side edit in the four service repos** — none is needed; the fix
  is entirely in kit.
- **No change to the chart/image `uses:`/`with:`/`secrets:` shape** the previous
  packet settled. The provenance fix needs no new input and adds no `with:` key.
- **No suppression beyond the one documented actionlint schema gap** — no
  `|| true`, no "skip the stamp when the script is absent". The stamp refuses.
- **Did not weaken any check** to reach green; every check added is paired with
  a red control that was seen red.
- Did not run the full gate or any cluster/docker operation, per the brief.

## Successor's first move, if any

Nothing is outstanding on this packet. If a rerun shows the helm version check
disagreeing with the pin, that is the installer resolving a different release —
the step now says so by name, and the fix is the `HELM_PIN` value. If the
stamper fetch fails, the failure names
`$RUNNER_TEMP/kit-provenance/docker/provenance.sh` and the ref it fetched.
After the fleet's publishes are green, `bash tests/validate.sh` is the manager's
merge gate — this packet never ran it.
