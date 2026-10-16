# REPORT — `roll-c6-backends-fleet`

**What the packet asked for.** GitHub Actions minutes are gone and only
`cafaye/docs` runs on the instabox backend. Two things block the fleet: the
sandbox cap (five) is smaller than the fleet (thirteen services), so one
sandbox must host several projects' pollers; and no service has the
`ci/pipeline.sh` that wires its `bin/prime` and `bin/publish` together for a
runner. Build the multi-project provisioner, the pipeline template, and the
README the fleet rolls out from.

**Verdict: built, verified with four throwaway suites and kit's own gate; one
pre-existing red in `tests/launch_test.sh` found and fixed on the way.**

---

## 1. What changed

```
 CHANGELOG.md                           |  28 ++++
 README.md                              |   2 +
 backends/README.md                     |  83 ++++++++++++
 backends/instabox/agent.sh             |  71 ++++++++--
 backends/instabox/pipeline.template.sh | 159 ++++++++++++++++++++++   (new)
 backends/instabox/provision.sh         | 240 ++++++++++++++++++++++++++-------
 backends/instabox/supervisor.sh        | 132 +++++++++++++++++++++++   (new)
 tests/launch_test.sh                   |  11 ++
 tests/validate.sh                      |  30 ++++-
 9 files changed, 695 insertions(+), 61 deletions(-)
```

Three commits on `roll-c6-backends-fleet`, none pushed:

- `daf499d` — the substrate: the multi-project provisioner, the supervisor,
  the bound agent, the pipeline template, the README.
- `72e37ae` — gate coverage for the new scripts, and the launch-fixture fix.
- `bed6a24` — the empty-token refusal.

### `backends/instabox/provision.sh` — one or many projects

`provision.sh <sandbox> <project> [<project> ...]`, e.g.
`provision.sh cafaye-build billing courier docs identity`. Per project it
writes `~/ci-env.d/<project>.env` and `~/ci/agents/<project>.sh`; it writes
the shared `~/ci/agent.sh` and `~/ci/supervisor.sh` once, then starts the
supervisor and verifies one live agent per project.

The single-project form is the list with one element. Re-provisioning
`docs` migrates it: the per-project env inherits the old `~/.ci-env` (so
`DEPLOY_HOST` survives), the supervisor takes over the poller, and
`ci/pipeline.sh` is untouched.

**The deploy host moved off positional argument 3.** A list makes
`... docs identity` ambiguous between "two projects" and "a project and a
host", so the host is now `DEPLOY_HOST` or a trailing argument containing a
`.` or a `:` (no cafaye project name does). Both existing spellings work.

**A missing token now refuses the run, by name, before anything is written.**
The old `${GH_TOKEN:-$(gh auth token)}` failed silently into an empty string —
`echo` succeeds whatever the substitution did — and the sandbox came up
unable to clone.

### `backends/instabox/supervisor.sh` (new)

One agent per project, started detached, restarted on a fixed interval
(`--loop`, default 60 s) or reconciled once (`--once`). A poller that exits on
a transient git error is a project that **silently stops building**; this is
the file that prevents that.

### `backends/instabox/agent.sh` — bound, not copied

The poller takes three variables (`CI_ENV`, `AGENT_NAME`, `AGENT_RUN_LOG`) and
a per-project wrapper `exec`s it, so there is **one process per project** and
the supervisor's pidfile is the agent's identity.

### `backends/instabox/pipeline.template.sh` (new)

The `ci/pipeline.sh` a service copies and edits in three marked places:
GATE, PATHS, SHIP. It reads `WORKSPACE`/`GH_TOKEN`/`CI`, installs the pinned
toolchain (`mise install`, then the gate under `mise exec`), publishes with
`./bin/publish --service-dir .` when `chart/Chart.yaml` exists, and ends with a
line naming what shipped and the commit. Its comments cite
`.github/workflows/*.yml` as where each fact comes from, and name the three
repositories whose gate is **not** `bin/prime`: `box` (`bin/ci`), `keyholder`
(`bin/gate`), `kit` (`bash tests/validate.sh`).

### `backends/README.md`

The rollout table and the capacity arithmetic (below), plus the seven-step
adoption order.

---

## 2. Capacity: what was measured, what was computed

Measured, 2026-10-16 (`instabox usage`):

```
Sandboxes:     2 / 5
Sandbox size:  4 vCPU · 8 GB · 20 GB
Storage:       4.9 GiB / 200 GiB
```

`cafaye-build` was **paused** when I probed it, so `nproc`/`free` from inside
were not readable; the `instabox usage` line is the measurement, and the
per-process numbers below are the model that rests on it.

| resource | a poller | a gate run | a 4 vCPU / 8 GB / 20 GB sandbox carries |
| --- | --- | --- | --- |
| CPU | ~0 (sleeping) | 1–4 vCPU, bursty | 4 overlapping gates |
| RAM | ~3 MB | 1 GB (Go), ~1 GB (Rails/Elixir), ~1.5 GB (Node `npm ci` + vitest) | 4 gates ≈ 4–5 GB |
| disk | 0 | 2–3 GB/project (checkout + deps + images) | 4 projects ≈ 12 GB of 20 GB |

**N = 4 projects per sandbox planned; N = 5 is the ceiling.** CPU and disk set
it, not RAM. Five sandboxes × four = twenty slots against thirteen services —
the fleet fits on **four sandboxes**, fifth spare. The rollout table places
`docs`/`billing`/`courier`/`identity` on `cafaye-build`, then `box`/`pantry`/
`parlor`/`website`, then `gateway`/`cafe`/`core`/`muse`, then `keyholder`/
`darkroom`/`cafaye-ts`.

---

## 3. Verification

`bash -n` and `shellcheck -S warning -e SC2317` are clean on all four scripts.
Four throwaway suites (in `$TMPDIR`, **not committed**) exercise the logic with
stubs, since the real sandbox was paused and the brief says never to disturb
services:

| suite | asserts | result |
| --- | --- | --- |
| supervisor + agent | start/restart-one/lock/stale-lock-recovery, per-project run log, agent lock | **13 / 13** |
| pipeline template | gate, red gate, `--service-dir .` publish, `DRY_RUN`, PATH entry, final line | **8 / 8** |
| provision | create, env+binding per project, deploy host, token, `--loop` start, verify count, single-project form, empty-token refusal | **16 / 16** |
| `tests/launch_test.sh` | (fixed fixture) | **66 / 0** |

Kit's own gate is `bash tests/validate.sh` (read from `.github/workflows/ci.yml`
→ `language: none` → the reusable `none` job). **The full run is green:**

```
PASS: every check passed.
note: 9 check(s) skipped — reported above, never hidden.
note: 5 tier(s) ran under a time bound; none was reached.
exit: 0
```

The nine skips are all pre-existing environment gaps (`rustc` not installed ×3;
the SQL files parsed by the tenancy tier rather than by a SQL parser ×3; the two
TypeScript tier files `node --check` cannot read; the wrangler install-host
bundle). None is a backend, and none is hidden. The five bounded tiers all
completed, so nothing was reported `BOUND`.

The new checks the gate runs on the backends are:

```
PASS backends/instabox/agent.sh            (bash -n)
PASS backends/instabox/pipeline.template.sh (bash -n)
PASS backends/instabox/provision.sh        (bash -n)
PASS backends/instabox/supervisor.sh       (bash -n)
PASS backends/instabox/agent.sh            (shellcheck -S warning)
PASS backends/instabox/pipeline.template.sh (shellcheck -S warning)
PASS backends/instabox/provision.sh        (shellcheck -S warning)
PASS backends/instabox/supervisor.sh       (shellcheck -S warning)
PASS backends/instabox/  (5 artifacts present, the set is whole)
```

The full run began before the last commit (`bed6a24`, the empty-token guard in
`provision.sh`), so the four `bash -n` and four `shellcheck` checks were re-run
on the final revision — the only checks the gate makes over the backends scripts
— and all eight are PASS above.

### The pre-existing red, and why it was fixed

`tests/validate.sh` was **red on `master`** at one check:
`launch_test: --check is green on the complete fixture layout`. `d3e6c7b`
("billing is the fifth service on the launch stack") added
`LAUNCH_BILLING_DIR` to `launch/bin/launch` and to the render checks in
`launch_test.sh`, but not to `launch_env` — so `--check` fell back to
`$KIT_ROOT/../billing`, a sibling that exists in no checkout (not in the main
kit checkout, not in a worktree, not in CI). The fixture already created
`$SIBS/billing/.git`; the fix is to name it, in `launch_env` **and** in the red
control (which was red for *two* reasons before — parlor and billing). The
assertion is unchanged; it now measures the harness instead of the filesystem
arrangement around kit.

---

## 4. What I deliberately left alone

- **`cafaye/docs`'s `ci/pipeline.sh`** — untouched, as the brief requires. The
  new provisioner places it for the `docs` project without reading it.
- **No service repository.** Every service gets its own packet; this one only
  writes the template and the README they will cite.
- **No new kit dependency.** `provision.sh` installs `rsync` and `mise` *on the
  sandbox*, which is what it already did for `rsync`; kit itself gains nothing.
  `mise` is the fleet's own pin mechanism (`mise.toml` in every repository).
- **`github-actions` backend** — unchanged. Switching back is one line in
  `ci/backend`; the pipeline is backend-agnostic by the README's contract.
- **Publishing credentials** — still one operator step (`bin/publish
  --sandbox`, token via stdin). Provision does not hold a registry credential.
- **`git` in `templates/bin/publish.sh`** — untouched; `bin/publish` already
  exists in this repo and is what the template calls.

## 5. Honest gaps, and the successor's first move

- **No real-sandbox run.** The sandbox was paused and the brief forbids
  touching services, so the provisioner was proven against stub `instabox`/`gh`
  and the supervisor/agent against stub agents. The first successor move is a
  real `provision.sh cafaye-build docs` against the sandbox and one green
  polled run — the README's step 5.
- **`mise` is assumed installable on the sandbox.** `command -v mise ||
  curl https://mise.run | sh` is best-effort and loud; I could not verify the
  install on the paused sandbox. If it fails, the template falls back to the
  sandbox's own toolchain and says so.
- **The docs agent was not stopped or restarted** — provisioning the real
  sandbox would have done that, and I left the sandbox's state alone.
- **Shared-workspace concurrency** between `docs`'s cross-repo sync and another
  project's poller of the same repo is not locked; git's own ref locking makes
  it survivable and the next poll retries. It is not exercised, and it is noted
  here rather than papered over.

## 6. Worktrees used

- `moon/cafaye/kit/wt/roll-c6-backends-fleet` (this branch). No second
  repository was modified — this packet is kit-only.
