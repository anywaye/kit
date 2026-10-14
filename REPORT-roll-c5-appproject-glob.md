# REPORT — roll-c5-appproject-glob

**Packet:** the AppProject and the Applications disagree, one packet later.
**Worktree:** `/Users/kaka/Code/any/moon/wt/roll-c5-appproject-glob`, branch
`roll-c5-appproject-glob`. **Commit:** `6c5221b` (one commit; the packet is one
seam).
**Deliverable:** `oci://ghcr.io/cafaye/charts/*` in
`templates/substrate/manifests/argocd/appproject.yaml`, plus a new §21 check in
`tests/substrate_test.sh` over the two sets of YAML, with red and green controls.

---

## 1. What was actually wrong

A sibling packet, `roll-c5-oci-repo` (merged), moved every Application's OCI
`source.repoURL` from the registry **root** to its own chart's **path** — Argo
resolves an OCI source's revision against the full path — so the eight
Applications now name `oci://ghcr.io/cafaye/charts/gateway`, `…/courier`,
`…/identity`, `…/parlor`.

`manifests/argocd/appproject.yaml` was written **before** that change and still
listed the bare root:

```yaml
  sourceRepos:
    - https://grafana.github.io/helm-charts
    - https://prometheus-community.github.io/helm-charts
    - oci://ghcr.io/cafaye/charts     # <- the ROOT; the Applications name PATHS
```

Argo then refused every Application:

```
application repo oci://ghcr.io/cafaye/charts/gateway is not permitted in project 'default'
```

**The §21 check that existed could not see this.** It compares the project
*name* the Applications carry with the shipped project's *name* — and both are
`default`. It is green on the exact box that is broken. The disagreement is
between a *different pair of fields*: the project's `sourceRepos` and the
Applications' `source.repoURL`. That is the seam this packet closes.

## 2. The pattern decision, and the Argo-version evidence

**Decision: `oci://ghcr.io/cafaye/charts/*` — a glob, not four enumerated chart
names, and not a bare `*`.**

A glob because a fifth service must not require an edit to this file. An
enumeration of the four shipped charts would be a *second list* to keep in step
with `manifests/applications/`, and the packets that keep moving the OCI paths
are exactly where a second list drifts — which is the defect this packet exists
to fix. Not a bare `*` because that is the maximal project the AppProject's own
comment refuses to be.

**Does Argo's `sourceRepos` support globs? Yes — verified from the pinned tag's
source, not from documentation.** `install.sh` pins `ARGOCD_VERSION="v3.5.4"`.
In that tag:

- `pkg/apis/application/v1alpha1/app_project_types.go` — `IsSourcePermitted`
  normalises **both** the source and each `sourceRepos` entry through
  `git.NormalizeGitURL`, then calls `globMatch(normalized, srcNormalized, true,
  '/')`. `globMatch` is:

  ```go
  func globMatch(pattern string, val string, allowNegation bool, separators ...rune) bool {
      if allowNegation && isDenyPattern(pattern) {
          return !glob.Match(pattern[1:], val, separators...)
      }
      if pattern == "*" {
          return true
      }
      return glob.Match(pattern, val, separators...)
  }
  ```

- `util/glob/glob.go` — `Match` compiles the pattern with `github.com/gobwas/glob`
  and the supplied separators. **`/` is the separator**, so a `*` matches a run
  of characters that contains no `/`.
- `util/git/git.go` — `NormalizeGitURL` lower-cases and trims a trailing
  `.git`, then round-trips through `net/url`. It does not touch a `*`.

**Measured, against gobwas/glob v0.2.3 — the library that tag imports** (a
throwaway module compiled with `glob.Compile(pattern, '/')`):

```
pattern: oci://ghcr.io/cafaye/charts/*   (separator '/')
  oci://ghcr.io/cafaye/charts/gateway   matches
  oci://ghcr.io/cafaye/charts/courier   matches
  oci://ghcr.io/cafaye/charts/identity  matches
  oci://ghcr.io/cafaye/charts/a/b       does NOT  (a '*' cannot cross a '/')
  oci://ghcr.io/cafaye/other/gateway    does NOT
  oci://ghcr.io/evil/charts/gateway     does NOT
```

and, measured separately with a copy of the tag's own `NormalizeGitURL`:

```
oci://ghcr.io/cafaye/charts/*            -> "oci://ghcr.io/cafaye/charts/*"
OCI://GHCR.IO/CAFAYE/CHARTS/Gateway      -> "oci://ghcr.io/cafaye/charts/gateway"
```

So the wildcard survives normalisation, the pattern matches each per-chart path,
and it does **not** become a `*`: it is anchored behind
`oci://ghcr.io/cafaye/charts/`, and the separator stops a match a level up
(`…/other`, `…/a/b`) or in another registry (`…/evil`).

The reason is written at the code site — a "WHY A GLOB AND NOT FOUR NAMES — AND
WHY IT IS NOT A `*`" block and a "THE EVIDENCE, FROM THE PINNED ARGO" block in
`appproject.yaml`, and a one-line restatement in `install.sh`'s step-4 comment
beside the `kubectl apply`. Nothing but a comment changed in `install.sh`.

## 3. The check, and the controls

New **§21** check `check_appproject_permits(apps_dir, project_path)` in
`tests/substrate_test.sh`. It is a static read of the two sets of YAML and it
**mirrors the pinned Argo's algorithm** so it measures what the controller
measures:

- `normalize()` — lower-case, trim a trailing `.git` (`NormalizeGitURL`).
- `glob_to_regex()` — gobwas/glob with `/` as the separator: `*` → `[^/]*`,
  `?` → `[^/]`, `[...]` a class, everything else literal.
- `glob_match()` — including Argo's bare-`*` shortcut.
- `permitted()` — the exact `IsSourcePermitted` loop, `!` deny patterns and all.

Every Application's `source.repoURL` must be permitted by at least one
`sourceRepos` pattern; the check exits non-zero and names the offending file and
URL otherwise.

Five runs:

| run | tree | must be |
| --- | --- | --- |
| grant | the real manifests + real project | **green** |
| red control 1 | real Applications + **pre-fix bare-root** project | **red** |
| red control 2 | an Application naming `oci://ghcr.io/evil/charts/courier` | **red** |
| red control 3 | an Application naming `…/charts/nested/identity` | **red** |
| green control | real project + a **fifth** chart `…/charts/pantry` | **green** |

Red control 1 is the packet's own defect — the historical pair — so the check is
proven able to see the exact state the box was in. Red control 3 pins the
separator: if the check were a prefix test, `…/charts/nested/identity` would
pass and the "it is not a `*`" claim would be unproven. The green control pins
the opposite direction: the pattern, not an enumeration — a check that only knew
the four shipped names could not be told from one that knows the glob.

Each control's fixture is asserted **built** before it is run (a `grep`/list-item
guard), because a control whose `sed` silently matched nothing is a control that
proves nothing. That guard caught its own first bug: the bare-root fixture was
built with a whole-file `sed`, and the comment block above the list *names* the
glob, so the built-fixture guard grepped the explanation and reported the
fixture unbuilt. The `sed` and the guard now target the **list item**
(`^    - oci://…/charts/\*$`), not a substring of the file.

## 4. Suite counts

- **Narrow gate — `bash tests/substrate_test.sh`:** `269 passed, 0 failed,
  0 skipped` (was 264 before this packet's five added runs; the first run before
  the fixture fix was `268 passed, 1 failed` on the bad control guard, then
  green).
- **Full gate — `bash tests/validate.sh --no-live`:** `PASS: every check
  passed`, exit 0, with `9 check(s) skipped` (all `--no-live`/docker live-tier
  claims, each printed as a `SKIP` naming the flag) and `4 tier(s) ran under a
  time bound; none was reached`. The `templates/substrate` static phase inside
  it reports `substrate_test: 269 passed, 0 failed, 0 skipped` — the same five
  new runs.
- `bash -n templates/substrate/install.sh` — clean.
- `bash -n tests/substrate_test.sh` — clean.
- `python -c 'yaml.safe_load(appproject.yaml)'` — parses, `sourceRepos ==
  ['https://grafana.github.io/helm-charts',
   'https://prometheus-community.github.io/helm-charts',
   'oci://ghcr.io/cafaye/charts/*']`.

## 5. What I deliberately did NOT do

- **No live `kubectl` on `contabo`.** This worktree's kubeconfig has no
  `contabo` context (its only context is the local `k3d-cafaye-local`), so no
  live box evidence was gathered; the refusal line is quoted from the packet and
  the *mechanism* is proven from the pinned Argo's source and the two local
  controls instead.
- **No enumeration of the four chart names.** The packet allows it if globs do
  not work; they do, so the list stays a pattern and a fifth service needs no
  edit here. A test that fails when an Application names a chart the list lacks
  is therefore not needed — but the green control proves a fifth chart is
  permitted, which is the property an enumeration could not have.
- **Did not touch the two upstream Helm repo entries.** They are exact and the
  four observability Applications match them exactly.
- **Did not widen `destinations` or add a `clusterResourceWhitelist`.** The
  Applications' namespaces and the charts' resource scopes are unchanged; only
  the OCI source drifted.
- **Did not remove the bare root from the comment history** — the comment now
  explains why the root is *not* the right entry, which is the reason a reader
  would otherwise relitigate.
- **Did not push, merge, or touch any other repository.**
