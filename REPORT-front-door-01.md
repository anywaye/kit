# REPORT — the front door does not work (`curl … | bash`)

**Branch:** `fix/front-door` · **Worktree:** `/Users/kaka/Code/any/moon/wt/front-door`
**Packet:** the served install (`curl https://cafaye.com/box/install | bash`) cannot install a box.
**Repo(s) touched:** `kit` only. **Worktrees used:** `moon/wt/front-door` (kit). No other repository was opened or edited.

---

## What was wrong

`curl https://cafaye.com/box/install | bash` — the command the website's `/box`
page, `cafe box init` and every doc print — could not install a box. Reproduced
against the live test box on 2026-10-15.

Two failures, one cause in `templates/substrate/install.sh`:

```sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/manifests/applications"
```

Under a pipe `BASH_SOURCE[0]` is **unset**, and `set -u` makes
`${BASH_SOURCE[0]}` a fatal unbound variable (`bash: line 433: BASH_SOURCE[0]:
unbound variable`, run 2) — or, on a bash that leaves it empty, `dirname`
answers `.`, `SCRIPT_DIR` becomes the caller's CWD, and `MANIFEST_DIR` does not
exist (run 1, from `/root`). Either way the manifest directory is missing:

- `registry_derived_artifacts` loops over **zero** files;
- step 5's probe lists **zero** artifacts and concludes "at least one is
  private / none verified", reaching for the capability exchange and demanding
  `KIT_SUBSTRATE_BOX_ID` for a pull that needs no credential;
- steps 6+ have no manifests to apply, so the run is broken well past the
  refusal.

Nobody saw it because every cycle ran `bash /tmp/kit/templates/substrate/install.sh`
from a **git clone**, where `manifests/` is the script's own sibling. The served
form had never been exercised end to end.

## The fix, and which candidate

**Option 1 — the script self-bootstraps.** Chosen. The served script keeps its
own directory resolution, and when it has no sibling `manifests/` it fetches the
manifest set from kit's **public** repository into a temp dir and points the four
manifest directories at it.

Why this one:

- **It keeps ONE served artifact and the drift test intact.** `kit-install.mjs`
  still imports `install.sh` verbatim and `check_install_host` still proves the
  served bytes are the file's bytes (SHA-256). The manifest set is a *fetch*, not
  a second thing the Worker must serve and keep in sync.
- **Option 2 (a served manifest bundle)** needs a website change — the brief
  forbids making one and asks only that it be named. It also puts two artifacts
  under one front door and gives `check_install_host` a second body to keep equal.
- **Option 3 (the served script clones kit and execs the real installer)** changes
  what the drift test proves: it currently proves the served bytes ARE the
  installer, and a thin bootstrapper makes that "the served bytes are a
  bootstrapper", which is a weaker and different claim.

The fetch is a **tarball from `codeload.github.com/cafaye/kit`**, not `git clone`:
a fresh box is promised `curl` (already a hard preflight requirement) but is not
promised `git`. The archive's root directory is named after the ref, so the
resolver **finds** `*/templates/substrate/manifests` rather than assuming a
directory name. An `EXIT` trap removes only the fetched temp tree, never a
checkout's sibling `manifests/`.

### The pin

```sh
KIT_SUBSTRATE_MANIFESTS_REF="ecb2fc998186dd82c3ea6da5e3f2d9fd2cd24a8a"
```

A **40-character commit sha**, which is the fleet's other accepted spelling
(`bin/dev`'s `kit.ref`: "a 40-character commit sha, or a `v<semver>` tag"). Not
a `v<semver>` tag, and that is a measured fact rather than a preference:
**`cafaye/kit` has zero tags** (`git ls-remote --tags origin` is empty,
`git tag -l` is empty). A `v2.0.0` pin would 404 today and take the front door
down at acceptance. The sha is pinned like every version in the file, and
`tests/substrate_test.sh` asserts (a) it is a 40-hex sha, (b) it resolves to a
commit locally, and (c) the manifests at that commit equal the manifests on disk
— so a manifest change without a matching bump is a **red gate**, not a served
run that installs yesterday's tree. Both halves have red controls (a floating
ref; a commit whose manifests differ).

**The manager must know one thing about this pin:** it names `ecb2fc9`, which is
this branch's parent commit. It is fetchable only once it is an ancestor of the
pushed default branch. A normal merge or fast-forward preserves it; a **squash
or rebase would orphan it** and the front door would refuse. If the merge is a
squash, bump the pin to the squash commit in the same merge (the gate's
manifest-equality check will still pass, since this change does not touch
manifests).

### The failure mode that had to survive

**A manifest set that cannot be fetched is a REFUSAL that names the fetch, before
step 5.** `kit_substrate_resolve_manifests` runs in `main` before preflight; if
the fetch or the extraction fails it calls `kit_substrate_refuse` with the URL
and the ref in the message. It never limps on to a credential demand. The test
asserts the refusal does **not** name `KIT_SUBSTRATE_BOX_ID` and that no
`[5/13]` line was reached.

## What changed

| File | Change |
|---|---|
| `templates/substrate/install.sh` | `BASH_SOURCE` read with an explicit empty fallback; the four manifest dirs derived from a manifest *root*; `kit_substrate_resolve_manifests` / `_point_manifests_at` / `_cleanup_manifests` added; the pinned ref + URL; the resolver called once in `main` before preflight. |
| `tests/substrate_test.sh` | New §3b: the pin is exact and tied to the manifests (2 red controls); the `BASH_SOURCE` fallback is asserted in CODE with the pre-fix read as a red control; the piped form is run with the fetch stubbed **success** (plans all thirteen steps) and **failure** (refuses by name, before step 5). |
| `templates/substrate/README.md` | The served form fetches its manifests; the fetch/refusal and the pin documented; "what is proven" bullet added; one stale "ten steps" → thirteen. |
| `CHANGELOG.md` | `## Unreleased` / `### Substrate` entry. |

`set -u` was **not** weakened. The change is additive: everything a checkout did
before, it does still — the fetch is skipped and the sibling tree is used.

## Gates

`bash tests/substrate_test.sh` (narrow gate, **green** — the eight new checks are
the first eight lines after the pin checks):

```
-- substrate_test: the install is real, and the pins are exact
      PASS substrate_test: the served-manifests pin is an exact sha that tracks the manifests on disk
      PASS substrate_test: control: a floating manifest ref goes red under the same pin check
      PASS substrate_test: control: a pinned ref whose manifests differ goes red (the pin is a tie)
      PASS substrate_test: the served-script read of BASH_SOURCE carries an explicit empty fallback
      PASS substrate_test: control: the pre-fix BASH_SOURCE read goes red under the fallback check
      PASS substrate_test: control: the pre-fix shape crashes on BASH_SOURCE[0] under a pipe
      PASS substrate_test: a served install fetches the pinned manifests and plans all thirteen steps
      PASS substrate_test: a manifest set that cannot be fetched is refused by name, before step 5
      …
-- substrate_test: 424 passed, 0 failed, 0 skipped
PASS: 424 passed, 0 failed, 0 skipped
```

`bash tests/validate.sh --static-only` (green; full validate is the manager's at
merge):

```
-- static: templates/substrate — the install is real, and its pins are exact
PASS tests/substrate_test.sh  (install.sh parses, DRY_RUN runs, pins are exact, manifests parse, every CRD field is declared by the pinned operator CRD, no :latest, no inline secret, NATS broker + stream + local/substrate drift, remote-URL applies server-side with force-conflicts and local applies client-side)
       -- substrate_test: 424 passed, 0 failed, 0 skipped
       PASS: 424 passed, 0 failed, 0 skipped
…
PASS: every check passed.
note: 9 check(s) skipped — reported above, never hidden.
note: 1 tier(s) ran under a time bound; none was reached.
```

### One pre-existing red this packet had to clear

The **first** `--static-only` run of this worktree was **red**, on a check this
packet does not touch: `obs chart sources`. It failed closed on
`templates/substrate/manifests/applications/billing.yaml` —
`'billing' is neither a service chart nor a pinned observability chart` — because
`SERVICE_APPS` in `tests/validate.sh` still named the four launch services.
`billing.yaml` arrived in the branch's parent commit (`ecb2fc9`, "billing's
Application, and the three fixtures it broke by arriving"); this is a fourth
fixture that commit broke and did not extend. It is **not** caused by the
front-door fix.

The classification is not a judgement call: `billing.yaml` resolves to
`oci://ghcr.io/cafaye/charts/billing` / `billing` / `0.1.0` — the service-chart
triple exactly. It is fixed in its own commit
(`fix(validate): classify billing's Application as a service chart`) so a reader
can see it is not part of the front-door change. It **does not weaken** the
check — the fail-closed branch is unchanged and both red controls still go red —
and it is why the rule "if a check is wrong, fix the check and say so" exists.

## The manager's acceptance

Run the real front door on the test box, from a fresh state:

```sh
curl -fsSL https://cafaye.com/box/install | sudo bash
```

Two conditions ride on this fix being deployed:

1. **The served bytes must include this fix** — deploy the Worker so
   `cafaye.com/box/install` serves this `install.sh`.
2. **The pinned commit (`ecb2fc9…`) must be reachable on GitHub** — it is this
   branch's parent, so a normal merge/fast-forward preserves it; a squash would
   orphan it and the run would refuse (see "The pin" above).

If the fetch works, step 5 prints its per-artifact probe lines — `public:
cafaye/charts/… (anonymous fetch)` for the all-public set — **without** demanding
`KIT_SUBSTRATE_BOX_ID`; if the fetch cannot complete, the run refuses by name and
never reaches step 5.

