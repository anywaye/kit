# REPORT — roll-c5-appproject-reapply

**Packet:** the AppProject glob patch never lands on a warm box.
**Worktree:** `/Users/kaka/Code/any/moon/wt/roll-c5-appproject-reapply`, branch
`roll-c5-appproject-reapply`, cut from `48319cd` (master).
**Commits:** `b453cc5` (the fix) and `8333dc1` (the test). Two commits, one seam
each.
**Deliverable:** `install.sh` step 4 re-applies the AppProject on every run,
outside the operator's guard; `tests/substrate_test.sh` §26 proves it by
executing step 4 against a warm box, with the pre-fix installer as the red
control.

---

## 1. The defect

`install_argocd`'s guard answers **"is the operator installed"** — `kubectl get
deployment -n argocd argocd-repo-server` — and it wrapped the **whole step**,
including `kubectl apply -f appproject.yaml`:

```bash
if kit_substrate_guard argocd; then
  kit_substrate_out "      already installed, skipping"
  argocd_present=1
fi
if [ "$argocd_present" -eq 0 ]; then
  # core-install apply, and THEN:
  kubectl apply -f "$ARGOCD_MANIFEST_DIR/appproject.yaml"   # never reached warm
fi
```

So a box that ever got past step 4 skipped the project apply **forever**. The
live Contabo box is exactly that box, and it carried the pre-glob list while
master had already written the glob:

| | `sourceRepos` |
|---|---|
| **on the box** | `["https://grafana.github.io/helm-charts",`<br>`"https://prometheus-community.github.io/helm-charts",`<br>`"oci://ghcr.io/cafaye/charts"]` |
| **in master** | `["https://grafana.github.io/helm-charts",`<br>`"https://prometheus-community.github.io/helm-charts",`<br>`"oci://ghcr.io/cafaye/charts/*"]` |

The result is the on-box refusal the packet names:

```
Unknown: repo oci://ghcr.io/cafaye/charts/gateway is not permitted in project 'default'
```

on all four service Applications. `roll-c5-oci-repo` and `roll-c5-appproject-glob`
crossed: the older packet moved the Applications to per-chart paths, the newer
one fixed the project's pattern, and the shipped project on the box is the one
from **before** both. The only way to land the fixed file was to delete Argo CD.

**Why the existing suite was green over it.** §21 compares the project's *name*
with the Applications' *name* and then checks the *sets* of repoURL/pattern — and
both are correct in the tree. §25 compares step 4's **body** against the other
two operator steps. Neither reads *which side of a guard a line sits on*. A
correct file that is never applied is invisible to both, which is the shape of
the defect: it is about the **object**, not the file.

## 2. The guard decision

**The AppProject's apply moved out of the operator's `if`, below the grouped
wait, and is unguarded. The operator stays guarded.**

The reason, written at the code site in full:

> A guard that covers an operator install and a project file **conflates two
> lifetimes**, and this one did. `kit_substrate_guard argocd` answers "is the
> OPERATOR installed" — a question about four Deployments this repository did
> not write and has no reason to rewrite. The AppProject is the other kind of
> thing: a file THIS repository owns, shipped in `manifests/argocd/`, edited
> whenever the Applications' chart paths move, and least-privilege by
> deliberate decision. The operator's stability was suppressing the policy
> file's currency.

**The alternative was considered and rejected, with the reason at the site:** a
second guard keyed on the AppProject's own **existence** answers "present" on the
exact box holding the **wrong** project — green on the measured defect. A guard
keyed on the file's *bytes* is a diff against something already applied. A
112-line project file is too small to guard; what it needs is to be re-applied.

**And re-applying is already this installer's own convergence mechanism.** Step
6 (`install_applications`) carries no guard either: `kubectl apply` of an
unchanged object is one no-op API round trip, and the convergence is worth more
than the round trip. The AppProject is smaller than any one of the eight
Applications.

Three properties the move preserves, each asserted in the test:

- **Ordering** — the apply stays at step 4 rather than moving to step 6, because
  Argo's application-controller reconciles an Application only when its project
  exists. It sits **below** the grouped wait so the CRD (shipped inside
  core-install.yaml) is present, and **above** step 6.
- **The operator stays guarded** — a warm box re-applies no remote manifest, no
  namespace, no rollout. This is the half that stops the fix from being "unguard
  everything", and §26 asserts it in argv.
- **The step reports honestly** — a warm box did real work, so `STEP_SKIPPED` is
  cleared. Reporting `skipped` over an API round trip is the misleading number
  the timing ledger exists to refuse.

The DRY_RUN plan also changed, and honestly: the old line read
`… core-install.yaml and apply …/appproject.yaml` — two actions on one line, one
of which the guard could suppress. They are now two lines, because a plan that
promises a step will not keep is a promise.

## 3. The test — §26, twelve assertions

`tests/substrate_test.sh` §26 executes step 4 against a box that has Argo CD and
the stale project. That state is what no other section models.

The mock is the established file-backed shape, with the three pieces the brief
names:

- **`mock_get_appproject`** — the controller's own read
  (`kubectl -n argocd get appproject default -o jsonpath='{.spec.sourceRepos}'`),
  one entry per line, read from the **object** rather than from the file that was
  applied. That distinction is the defect: the file was right and the object was
  stale.
- **`warm_seed`** — the live box's state: Argo installed, the pre-glob project
  deployed. Re-run before every case, so a case cannot inherit the previous
  case's write.
- **`warm_kubectl`** — the warm box. Exactly the two calls step 4 makes against
  it, and **anything else is refused loudly** rather than answered with success:
  a mock that said yes to the remote core-install apply would have made the
  "operator stays guarded" assertion worthless.

The assertions, and what each one is for:

| # | assertion | why |
|---|---|---|
| 1 | fixture premise: the seeded project is the pre-glob list | a green case satisfied by a box that was never broken proves nothing |
| 2 | fixture premise: that list does **not** permit the Applications | same rule, the other direction |
| 3 | step 4 exits 0 on a warm box | the re-apply must not break the run |
| 4 | the apply is in argv | "the project was applied" is a command, not a return code |
| 5 | **the operator stays guarded** — no `core-install.yaml` in argv | the half that stops "unguard everything" |
| 6 | the object changes | a mock that ignored the write would be caught here |
| 7 | `run` green: the re-applied project permits every Application | §21's own glob-aware algorithm — the glob fix's semantics, not a second spelling |
| 8 | control fixture premise: the rebuilt pre-fix installer really does guard the apply | a transform that matched nothing would run the *fixed* installer as the control and go green |
| 9 | control: the pre-fix guard leaves the warm box carrying the stale project | the red control's own state |
| 10 | `run` red: the pre-fix guard refuses every Application | the packet's own defect, measured |
| 11 | a warm box **plans** the apply with every guard forced present | the DRY_RUN plan is the one output that records which side of a guard a line sits on, and §25 cannot read it |
| 12 | control: the pre-fix installer does **not** plan it | the red half of the plan check |

The pre-fix fixture is built by a python transform that puts the apply back
behind `if [ "$argocd_present" -eq 0 ]`, and its premise is asserted built before
it is run.

**And the red proof was measured against the real tree, not only against a
fixture.** The same transform was applied to `templates/substrate/install.sh`
itself, the suite was run, and the mutation went red on exactly the four
assertions that matter — printing the live box's own message:

```
FAIL a warm box re-applies the AppProject (the apply is in argv)
     step 4 ran: --kubeconfig=… get deployment -n argocd argocd-repo-server
FAIL a warm box leaves the pre-glob list behind (the object changes)
     the box still reads: https://grafana.github.io/helm-charts
     https://prometheus-community.github.io/helm-charts
     oci://ghcr.io/cafaye/charts
FAIL the re-applied AppProject permits every Application on a warm box
     courier.yaml: repoURL 'oci://ghcr.io/cafaye/charts/courier' is not permitted
     by any of ['https://grafana.github.io/helm-charts',
     'https://prometheus-community.github.io/helm-charts',
     'oci://ghcr.io/cafaye/charts']; gateway.yaml: …; identity.yaml: …; parlor.yaml: …
FAIL a warm box plans the AppProject apply even with every guard present
     the DRY_RUN plan never names appproject.yaml
```

`-- substrate_test: 277 passed, 4 failed` — and the pre-fix controls stayed
green, which is the correct asymmetry. `git checkout --` restored the tree;
`git status` is clean and the tree is at `8333dc1`.

**One debugging note worth keeping.** `warm_kubectl`'s write path is a *file*
and not a heredoc, because `declare -f` re-emits a function body **re-indented**
and a heredoc terminator that moves off column 0 swallows the rest of the
generated script. The first draft carried one and §26 failed with
`syntax error near unexpected token '||'` on line 57 of a generated script
nobody had written by hand. The comment at `WARM_PLANTER` records it.

## 4. Suite counts

- **Narrow gate — `bash tests/substrate_test.sh`:** `281 passed, 0 failed,
  0 skipped` (was 269 before this packet's twelve added runs). Exit 0.
- `bash -n templates/substrate/install.sh` — clean.
- `bash -n tests/substrate_test.sh` — clean.
- **`shellcheck -S warning`** on both files — **clean** (no findings at all).
- **Full gate — `bash tests/validate.sh --no-live`:** `PASS: every check
  passed.` Exit 0. `note: 9 check(s) skipped` — every one of them a
  `--no-live`/docker live-tier claim named by the flag — and `4 tier(s) ran under
  a time bound; none was reached`. The `templates/substrate` static phase inside
  it reports `substrate_test: 281 passed, 0 failed, 0 skipped`, so all twelve
  §26 assertions ran under the full gate too, not only under the narrow one.

## 5. What I deliberately did NOT do

- **No live `kubectl` on `contabo`.** This worktree's kubeconfig has no `contabo`
  context — its only context is the local `k3d-cafaye-local`, and there is no
  `/etc/rancher/k3s` here — so the read-only
  `kubectl get appproject … -o jsonpath='{.spec.sourceRepos}'` was **not**
  possible from this machine. The old and new `sourceRepos` above are quoted from
  the packet's own live measurement, and the *mechanism* is proven locally by
  executing the step against a box modelled on that measurement, plus the
  destructive red proof on the real tree. The evidence gap is named rather than
  papered over.
- **Did not change the `sourceRepos` value.** The glob is the contract from
  `roll-c5-appproject-glob`; the project follows the Applications' per-chart
  paths. This packet changes *when the file is applied*, never *what it says*.
- **Did not add a retry, a sleep, or a `|| true` on the re-apply.** One
  `kubectl apply`, and a failure in it aborts the install exactly as any other
  apply does.
- **Did not put a guard on the AppProject.** The rejected option, with its
  reason, is in §2 above.
- **Did not touch `.github/workflows/`**, another repository, or any other
  packet's seam. Two files changed plus the two docs the checklist requires
  (`README.md` step 4, `CHANGELOG.md`).
- **Did not merge and did not push.**
