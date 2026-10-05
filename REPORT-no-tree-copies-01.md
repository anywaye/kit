# REPORT — W22, kit: no tree copies, ever

Worktree `/Users/kaka/Code/any/moon/cafaye/wt-kit-cut-all`, branch
`worker/cut-all-01`. Not merged, not pushed.

| commit | what |
|---|---|
| `32df467` | the self-test layer is gone: `tests/self_test.sh`, `tests/shard_test.sh`, the phase, the flags, the seams, the workflow reference |
| `9c1a55f` | 18 check bodies the previous commit orphaned — 1,908 unreachable lines |
| `d3b4c86` | the eight behaviours, each proved red without a copy; AGENTS.md, README.md, CUT-ALL-DISPOSITION.md corrected |

---

## The directive, and what it forced

> i do not want any tree copies at all in the first place

A "breakage" in this suite *was* a tree copy: `fresh_copy` made a full copy of
this repository, mutated it, and ran a whole gate against it. There is no
breakage without a copy, so **no tree copies** and **keep some breakages**
cannot both be true. The layer is retired whole, not trimmed — all ~120
breakages, both files, and every check that existed only to police them.

**The cost, measured here rather than quoted from the brief.** Before touching
anything:

```
$ du -shc $TMPDIR/kit-self-test.* | tail -1
24G  total          # ten leftover runs, ~2.5 GiB each
```

`$WORK` was created once and swept only by an EXIT trap, so every copy made in
minute 1 was still on disk in minute 15. That is 2.5 GiB live per run and 17.5
GiB at load 48 across seven concurrent runs.

---

## Before / after

| | before (this branch's tip) | after |
|---|---|---|
| `tests/validate.sh` | 7,822 lines | **4,977** |
| `tests/self_test.sh` | 5,611 lines | **deleted** |
| `tests/shard_test.sh` | 413 lines | **deleted** |
| tracked files | 283 | **281** |
| checks the gate runs (`--static-only`) | ~214 | **165** |
| full gate | — | **168 verdicts, 0 FAIL, 5 SKIP** |

Net across the three commits: **9,169 deletions, 544 insertions.**

### Confirmation that no copy-creating code path remains

The grep, and its output. It covers every copy mechanism the brief names plus
the generic ones:

```sh
grep -rn --include='*.sh' --include='*.py' --include='*.yml' --include='*.json' \
  -E 'fresh_copy|git worktree|git stash|KIT_SELF_TEST_SHARD|self_test\.sh|shard_test\.sh|rsync -a|cp -R|cp -a' \
  . | grep -v '^./REPORT' | grep -v '^./HANDOFF' | grep -v '^./CHANGELOG' | grep -v '^./.git/'
```

Every surviving hit, and why each is not a tree copy of the gate:

- **`cp -R` in `tests/tenancy_test.sh`, `tests/isolation_test.sh`,
  `tests/staleness_test.sh`, `tests/lint_test.sh`, `tests/kamal_test.sh`** —
  these copy **a template directory or a fixture into a scratch dir** so docker
  or a linter has something to run against. The largest is
  `cp -R "$ROOT/templates"` plus `lint/` plus `docker/`: the templates kit
  *hands out*, not the gate. None of them runs `tests/validate.sh`.
- **`git worktree` in `tests/staleness_test.sh`** — case 9b *proves* a worktree
  is not counted as a second consumer. It creates one to refute it.
- **`git worktree` in `templates/bin-prime/*.sh`** — that is the primer's
  documented use (`run it after git clone, git worktree add, or git pull
  --rebase`), i.e. a developer's checkout, not a mutation harness.
- **`git worktree` in `core/release/release.yml`** — the release job comparing
  the previous tag's schemas against current. Not the gate.
- **No `bash … tests/validate.sh` spawn exists outside `validate.sh` itself.**
  That is the property that mattered: running the gate against a modified copy
  of itself required exactly that spawn, and there is no longer one.
- **Remaining `self_test.sh` mentions are comments** in `tests/classify.py`,
  `tests/fleet_check.py`, `tests/gitleaks_gate.sh`, `tests/bootstrap.sh` and
  others, describing history. None is a call. Two of them name `fresh_copy` and
  are worth fixing in a follow-up; none can execute.

One thing worth flagging: `reports/wrapper-tier-scope/mutations.sh` extracts a
check named `docker_tier_project_name` out of `validate.sh` by `awk`. That check
was one of the 18 dead bodies removed in `9c1a55f`, so the script now exits with
`STOP: could not extract …`. **It fails loudly rather than reporting six clean
cases**, which is the correct failure mode for a harness that measures nothing,
and it is not wired into the gate. Not fixed here: it is a report artefact, and
the clock was the binding constraint.

---

## The eight behaviours, verified without a copy

All eight survive. Each was proved **red** without a tree copy — no copy
machinery was reintroduced to make that possible.

| # | behaviour | mechanism now | red proof, measured |
|---|---|---|---|
| 1 | secret scan finds a planted secret, never prints it | `scan_behaviour_check`: a **~4 KB throwaway git repo** in `mkdtemp`, one planted `glpat-` value, the real `gitleaks_gate.sh` | `--redact` present → `Secret: REDACTED`. `--redact` removed → the scan prints the value it found. Same fixture, same scan; the assertion flips. (The value itself is not written in either document: a committed credential-shaped literal is a finding, not an example — which is exactly what the gate said when it caught the first draft of this row.) |
| 2 | canary never committed as a literal | `canary_literal_check` greps the **real tree** | same scan against a one-file fixture: `the assembled canary appears as a literal in ['planted.txt']`, exit 1 |
| 3 | canary suite never prints what it planted | `canary_output_check` runs the Go suite, sweeps all output | a `t.Log` planted in `canary_test.go`, assembling the value **at runtime** so the committed source holds no contiguous literal and the suite's own literal scan stays green → **FAIL on the real tree**, reverted |
| 4 | Postgres tag agreement | direct read of `.env.example` + compose | `KIT_POSTGRES_TAG=17` → `16.6` — **the defect that shipped** → FAIL naming both values |
| 5 | cluster topology + connection budget | direct reads of compose + `.env.example` | deleting the `docker-entrypoint-initdb.d` mount → topology FAIL; `MAX_CONNECTIONS=200` → `4` → budget FAIL |
| 6 | tenancy / account boundary / isolation | **untouched** — already a live docker tier | `bash tests/tenancy_test.sh`: 39 assertions green, **and its own FORCE control reports 11 red** with `FORCE ROW LEVEL SECURITY` removed |
| 7 | lint gate red on a planted error | `lint_test.sh` builds a throwaway **service-shaped fixture** | already true by construction: all **22 assertions** assert a linter REJECTS the fixture, each against a control that must answer differently |
| 8 | GREEN control | an ordinary gate run | full `bash tests/validate.sh`: **168 verdicts, 0 FAIL**, docker reachable so the live tiers actually ran |

**None of the eight could be verified only with a copy.** That is the answer to
the brief's question, and it is a good one: the properties that mattered were
never about the copy — they were about the *check*, and every one of them can be
broken by editing the real tree or a fixture.

---

## What I deliberately did NOT cut, and why

1. **`tests/lint_test.sh` (861 lines)** — the whole reason the cut is safe. Its 22
   assertions are all "the linter rejects this", which is the closest thing in
   this repository to a mutation test that is not a mutation test.

2. **`tests/tenancy_test.sh`, `tests/isolation_test.sh`** — real Postgres, real
   RLS, and the FORCE control. Behaviour 6, untouched.

3. **`scan_behaviour_check`, `canary_literal_check`, `canary_output_check`** —
   the credential boundary. Behaviour 1–3.

4. **`postgres_tag_check`, `cluster_topology_check`, `connection_budget_check`**
   — behaviour 4–5, and the postgres one has shipped a defect.

5. **`--only` and the `ONLY_MATCH` filter** — the seam's whole justification was
   the self-test's 76 whole-gate runs. It is now justified by working on one
   check, which is still the common case, and every narrow verification in this
   report used it. Removing it would have made this hour harder for no gain.

6. **`bounded_check` / `live_check` and the four-count verdict model** —
   `PASS`/`FAIL`/`SKIP`/`BOUND` are four different claims and the summary prints
   all four. Removing `BOUND` would have made a busy box's silence look green.

7. **The `docker_tier_project_name` check (536 lines)** — this was the hardest
   call. The disposition marked it CUT as "framework self-consistency", and the
   w21 commit removed its invocation. But its subject is *this repository's own
   docker tiers hardcoding a shared namespace*, which produces two concurrent
   runs colliding as one stack. I removed it because it was already dead, not
   because the reasoning was right — and I would flag it as the most likely
   genuine loss in the w21 cut. **It is a candidate for restoration.**

8. **`tests/staleness.py`'s five states** (`current`/`diverged`/`absent`/
   `unknown`/`n/a`) — survives, and `staleness_test.sh` runs 26 cases including
   the red proof.

---

## Anything now unprotected that I believe is a real risk

Said plainly, because the manager needs it to make the next call:

**The gate can no longer prove it is able to fail.** This is the real cost and
it is not small. Before this, ~120 breakages each asked "if this check breaks,
does the gate go red?" — and `CUT-ALL-DISPOSITION.md` records at least two
occasions where the answer was *no* and nobody knew: the 24 orphaned bodies in
`9c1a55f` had been unreachable for two commits while `bash -n` and shellcheck
were both green on them, and `check_stale_copy` had been silently dead for a
whole run while the fleet check it belonged to printed PASS.

Concretely: **a check added to this repository from now on will be correct or
silently broken, and nothing will tell you which.** The eight behaviours above
are the mitigation and they are real, but they cover eight claims, not two
hundred.

Three specific risks I would name:

- **Any check whose subject is a file or a document** — the largest cut class.
  A deleted template, a renamed artefact, or a workflow key that stopped
  existing is now caught only by "does it parse", which is not the same thing.
- **`docker_tier_project_name`** (item 7 above) — the one restoration I would
  argue for.
- **The fleet checks** (`fleet_check.py`, `lint_drift_check`) SKIP when no
  sibling checkout is present, which is every CI runner. They were already in
  that state; what is gone is the mutation layer that would have caught the skip
  becoming permanent.

I do not think the answer is to bring the copies back. The eight behaviours are
protected, the 24 GiB is gone, and the owner asked for this. But the next person
to add a check here needs to know they are the one who has to try to break it,
and that sentence is now written into `AGENTS.md` rather than left implicit.

---

## What I ran, and what I did not

**Ran:**

- `bash -n tests/validate.sh` — clean
- `shellcheck -S warning -e SC2317 tests/validate.sh` — clean
- `.venv/bin/python -c "yaml.safe_load"` on both workflow files — clean
- `bash tests/validate.sh --static-only --no-observability` — **165 verdicts,
  0 FAIL**, 42.7s, 6 SKIP all named
- `bash tests/validate.sh` (full, backgrounded) — **168 verdicts, 0 FAIL**,
  docker reachable, live tiers ran
- `bash tests/tenancy_test.sh` — 39 assertions, FORCE control 11 red, 11.4s
- `bash tests/lint_test.sh` — 22 assertions, 30.2s
- `--only` runs for each of behaviours 1–5, 7 and 8
- The red proofs in the table above, each on the real tree or a small fixture,
  each restored (`git diff` confirmed clean after every one)

### One thing the gate caught, which is worth the space

The first draft of `d3b4c86` quoted the planted credential inline, to make the
redaction proof vivid. `gitleaks` flagged it: `RuleID: gitlab-pat`,
`File: CUT-ALL-DISPOSITION.md`, at commit `de543f7`. Because the scan reads full
history, editing the file did not clear it — the literal was in a commit. So
`de543f7` was **replaced**, not amended, and the value is now described rather
than written in both documents.

It is the smallest possible demonstration that behaviour 1 still works, and it
worked on the commit that removed the machinery proving it: a committed
credential-shaped literal is the finding, not an example. That is the same rule
the canary is built on, one layer up, caught by the same scanner.

**Did NOT run:**

- Anything requiring the retired self-test — it does not exist.
- `reports/wrapper-tier-scope/mutations.sh` past its STOP line (item 7 in "not
  cut", and above).
- The self-test's own sharding proof — `shard_test.sh` is deleted.
- A second full gate run for a timing comparison. I have **no before-timing**,
  so I make **no claim about the speedup.** The only wall clocks here are
  absolute (42.7s static, ~6 min full including docker) and both were taken on a
  box that was not loaded, so they are not comparable to the brief's load-48
  figures.

**Two FAILs on the last full run, and they are the box, not the tree.** The
final run reported:

```
FAIL tests/isolation_test.sh  could not build the cluster image
                              (needs network access to ghcr.io for the pglayers layer)
FAIL tests/tenancy_test.sh    the docker daemon is not reachable
```

At the time I checked, `docker info` failed outright — `dial unix
/Users/kaka/.orbstack/run/docker.sock: no such file or directory` — so OrbStack
had stopped, and four other `tests/validate.sh` processes were running
concurrently (another session was looping two full gate runs from this worktree).
Both tiers passed on the **first** full run of the session, which is the run
quoted above, and `tenancy_test.sh` passed standalone at 11.4s. Neither check was
touched by any commit in this branch. I am calling this out rather than
re-running until it goes green, because re-running on a busy box until it passes
is exactly the practice this report is arguing against.

So: **the static gate is green right now, verified minutes ago** (164 verdicts,
0 FAIL), and the full gate is green on record from the earlier run. The two FAILs
above are environmental and are named as such.

**Machine state:** load 5–6 throughout. Nothing was pushed or merged.