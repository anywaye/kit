# CI backends

**A project writes a pipeline, kit runs it.** The pipeline is the project's
own — its gate, its build, its deploy — and it lives in the project at
`ci/pipeline.sh`. The backend is how that pipeline gets triggered and with
what environment, and it is chosen once, in `ci/backend`:

```
instabox
```

| backend | what it is | when it is the right one |
| --- | --- | --- |
| `github-actions` | GitHub Actions, via `.github/workflows/` calling kit's reusable workflows | the default; free minutes exist |
| `instabox` | a sandbox that polls the repo and runs the pipeline on new master | Actions minutes are gone, the run needs to reach a private network, or the machine matters |

## The contract

A project's `ci/pipeline.sh` must:

1. be executable (`chmod +x`), run from anywhere, and be idempotent — the
   backend runs it repeatedly;
2. read its inputs from the **environment the backend provides**, never from
   the backend's shape. The variables every backend provides:

   | variable | meaning |
   | --- | --- |
   | `WORKSPACE` | the directory holding `cafaye/<name>` checkouts |
   | `GH_TOKEN` | a token that can read the project's private sources |
   | `CI` | `1`, so a pipeline can skip interactivity |

3. anything else — a deploy host, a key, a bucket — the project declares and
   the backend materializes from its own secret store. The instabox backend
   reads `$HOME/.ci-env` (one `KEY=value` per line, written by provision);
   GitHub Actions reads repository secrets. A pipeline that reads
   `DEPLOY_HOST` works on both without knowing which.

## Switching backends

Change the one line in `ci/backend` and, for `github-actions`, ensure the
workflow files exist. The pipeline is unchanged; that is the point. A project
that wants a third backend (a self-hosted runner, a cron on a box) adds
`kit/backends/<name>/` and a line to the table above, and every other
project's pipeline keeps working.

## What kit owns vs what the project owns

| kit | the project |
| --- | --- |
| the poller, the provisioner, the backends' plumbing | `ci/backend` and `ci/pipeline.sh` |
| the secret-store mapping per backend | which secrets it needs, declared in its README |
| the switch, in one file | nothing about the runner's shape |

## One sandbox, many projects

The instabox backend's agent is a **sleep-loop**. It is worth saying why that
matters before any of the arithmetic below: a poller costs a process and ~3 MB
of resident memory and **zero CPU while it sleeps**. What costs real resources
is a **gate run**, and gates are bursty — one every few hours per project, a
few minutes each, and the poll phases of independent projects are not
synchronized. So the sandbox's capacity is not "how many pollers fit"; it is
"how many gate runs can overlap on 4 vCPU, 8 GB and 20 GB", and the pollers
themselves are free.

`backends/instabox/provision.sh` therefore takes a **list** of projects and
writes one agent per project — `~/ci-env.d/<project>.env`,
`~/ci/agents/<project>.sh`, its own log and pid — and a supervisor that starts
and restarts them all. The single-project form still works: the list has one
element. The measured machine and the measured capacity:

```
$ instabox usage
Sandboxes:     2 / 5
Sandbox size:  4 vCPU · 8 GB · 20 GB
```

| resource | a poller | a gate run | so a 4 vCPU / 8 GB / 20 GB sandbox carries |
| --- | --- | --- | --- |
| CPU | ~0 (sleeping) | 1–4 vCPU, in bursts | **4** overlapping gates before CPU is the wall |
| RAM | ~3 MB | 1 GB (Go), ~1 GB (Rails/Elixir), ~1.5 GB (Node `npm ci` + vitest) | 4 gates ≈ 4–5 GB, under 8 GB |
| disk | 0 | 2–3 GB per project (checkout + deps + images) | 4 projects ≈ 12 GB of 20 GB |
| pollers | 3 MB | — | 13 pollers ≈ 40 MB, under 1% of RAM |

**The planning number is N = 4 projects per sandbox, and N = 5 is the
ceiling.** CPU and disk set it, not memory: five concurrent gates fit in RAM
but the twenty-gigabyte disk is the first thing to run out. Five sandboxes ×
four projects = **twenty slots**, against **thirteen services** (plus `kit` and
`core`, which are specs and never publish) — the whole fleet fits on **four
sandboxes, with the fifth spare**. The cap itself is the plan's hard edge:
`instabox usage` reports `5` sandboxes maximum, so a fleet larger than twenty
projects needs a second sandbox only after the disk is measured, not before.

### The rollout table

`cafaye-build` already exists and already runs `docs`; `box-4c652a` is the
test-tier sandbox and is not a CI host. The first wave lands on `cafaye-build`,
and each following sandbox carries the next four. One project per line, and
the gate column is the fact a pipeline's MARKED 1 must carry — read from the
repository's own `.github/workflows/ci.yml`, never assumed.

| sandbox | projects | gate entrypoints |
| --- | --- | --- |
| `cafaye-build` (exists) | `docs`, `billing`, `courier`, `identity` | `./bin/prime` ×4 |
| `cafaye-release` (new) | `box`, `pantry`, `parlor`, `website` | `bin/ci`, then `./bin/prime` ×3 |
| `cafaye-libs` (new) | `gateway`, `cafe`, `core`, `muse` | `./bin/prime` ×4 |
| `cafaye-rest` (new) | `keyholder`, `darkroom`, `cafaye-ts` | `bin/gate`, then `./bin/prime` ×2 |
| *fifth slot* | spare, or the second wave of the three libraries (`cafaye-py`, `cafaye-rb`) | — |

`docs` is already on `cafaye-build` under the **single-project** provisioner.
Re-provisioning it with the multi-project form migrates it: the per-project
env inherits the old `~/.ci-env` (so `DEPLOY_HOST` survives), the supervisor
takes over the agent, and `ci/pipeline.sh` is not touched.

### The order a service adopts this in

1. **Copy the template.** `backends/instabox/pipeline.template.sh` →
   `ci/pipeline.sh`, `chmod +x`. Edit the three MARKED places — the gate
   command, any PATH entries, and the ship step — each of which says in its
   comment where in `.github/workflows/` to read the fact.
2. **Take the publish tool** if this repository ships a chart: copy kit's
   `templates/bin/publish.sh` to `bin/publish`, `chmod +x`. Do not reimplement
   the push; the tool derives the image digest, stamps the chart and refuses a
   malformed one.
3. **Write `instabox`** into `ci/backend`. Commit and push `master`.
4. **Provision.** On the operator's machine, logged into `instabox` and `gh`:
   `GH_TOKEN=… backends/instabox/provision.sh cafaye-build <project>`. A chart
   publisher is logged in once more —
   `cat token | bin/publish --sandbox --sandbox-name cafaye-build`.
5. **Watch one green run.** `instabox ssh <sandbox> -- tail -f
   ~/ci-logs/<project>.log` until `agent[<project>]: shipped <sha>` and the
   pipeline's own last line agree on what shipped. That is the whole
   verification; a green run on the sandbox is the point of the backend.

The `agent.sh` poller, the `supervisor.sh` restart loop and the per-project
binding are all kit's; a service writes only `ci/backend` and `ci/pipeline.sh`.
