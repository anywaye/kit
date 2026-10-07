# REPORT — kit m111 (platform-fast): proportional CI with a standalone publish proof

**Base:** `dee3358` (m111 Q1: path router + route proof, intact and preserved).
**Branch:** `kit-platform-fast`, in place in `/Users/kaka/Code/any/wt/kit-platform-fast`.
No new worktree, no merge, no push — the manager merges.

## What the packet is for

Full-gate-every-PR does not scale with fleet size, but a narrowed run
reported as a platform-test pass is the defect this packet exists to remove.
So kit's own CI now routes each pull request by changed paths
(`tests/route.sh`, pure bash) to exactly one proving job — `docs`, `tier`,
`publish`, or `full` — and the stable required check (`ci / gate`) passes
iff that job passed while printing which checks ran and which did not.
Narrowed runs are never reported as platform-test passes; pushes, schedules
and manual runs always take `full`, the unfiltered release proof.

## The recursion incident (this continuation's reason to exist)

The prior attempt's `tests/focused_publish.sh` called
`bash tests/validate.sh --only='chart publish'`. `tests/bootstrap.sh` holds
gate self-tests that invoke the gate, so the focused run re-entered the
gate: the manager observed ~624 nested `validate.sh --only=chart publish`
processes in ~8s — a real recursive process tree, SIGTERMed — and stopped
the worker before it could retry the same command.

The fix, landed here: the chart-publish proof now lives in ONE standalone
file, `tests/chart_publish_check.sh`, called by both the gate and the
focused script. Neither focused path invokes the gate in any form — no
full run, no `--only` — so the bootstrap self-tests are unreachable from a
focused run by construction, not by flag discipline.

## What landed

1. **Q1 (committed, `dee3358`, preserved untouched):** `tests/route.sh`
   (argv in, one `ROUTE=` line out; docs/tier/publish/full; empty, unknown,
   mixed-family and non-PR inputs fail closed to `full`) and
   `tests/route_test.sh` (19 synthetic cases in ~0.1s, including the guard
   that fails if the router ever names the gate in an executable line).
2. **This continuation (uncommitted until this report's commit):**
   - `tests/chart_publish_check.sh` (new): the gate's chart-publish
     assertions verbatim — the python block is byte-identical
     (md5 `2dc395c3404bb1fe6c54788f785f9b88` both sides) — with both red
     controls (drifted repoURL; `push` default flipped true), its own
     python resolution (gate venv, else system PyYAML, else loud exit 2),
     its own temp dir. Exit 0 = real tree green + both controls red;
     exit 1 = assertion or control failure; exit 2 = cannot measure.
   - `tests/validate.sh`: `check_chart_publish()` is now a 3-line delegate
     to that file. Call site and label unchanged, so PASS/FAIL meaning is
     preserved; 138 lines of duplicated-once logic removed from the gate.
   - `tests/focused_publish.sh` (rewritten): family YAML parse + the shared
     checker directly. No `validate.sh` invocation in any executable line
     (verified by grep; the gate is named only in comments and the NOT RUN
     disclosure printf, same as the pre-existing `focused_tier.sh`).
   - `tests/focused_tier.sh` (kept from prior attempt, verified): family
     syntax with the gate's own tools, loud skips, disclosure tail.
   - `.github/workflows/ci.yml`: route → one proving job → `gate` verdict.
     Reusable workflows untouched; `full` passes `language: none` plus
     `working-dir: .`, both documented inputs. Caller concurrency keeps the
     fleet spelling the reusable file's own comment requires.
   - `README.md` (platform/service boundary + routing table) and
     `CHANGELOG.md` (proportional-CI entry naming the shared checker).

## What was measured (bounded, standalone — the full gate was never run)

- `route_test.sh`: 19 passed, 0 failed.
- `chart_publish_check.sh` on the real tree: green, 4 service
  Applications compared, both red controls red — 0.26s.
- Independent external red proof (temp fixture, real tree untouched):
  drifted `identity.yaml` repoURL → exit 1 naming the seam.
- `focused_publish.sh`: green, 0.30s warm (target was <60s).
- `focused_tier.sh`: pass=8 fail=0 skip=3 (2 TS + skip-allowlist loud).
- `ci.yml` + `publish.yml` parse; `git diff --check` clean;
  `shellcheck -S warning` clean on all five scripts.

## What is NOT proven and not claimed

- Docs/tier/publish routes do not prove platform runtime. Only `full`
  (`bash tests/validate.sh`, no flags) is the release proof.
- The gate's `check_chart_publish` delegate was verified by reading (call
  site intact, syntax `bash -n` clean), not by executing it — executing any
  gate path was forbidden this continuation. The shared file it calls is
  proved above; the one-line delegation is the manager's gate to exercise.
- CI YAML was parsed, not run: the `route`/`gate` job logic, the
  `xargs -0 route.sh` classification step, and the `full` reusable call are
  correct by inspection. A PR exercising each route is still owed.

## Successor's first move

Run the full gate on the merged tree (`bash tests/validate.sh`, no flags,
bounded per worktree-log convention). If green, open one PR per route class
to watch each CI path execute. If the gate's chart-publish check disagrees
with the standalone proof, the delegation line is the suspect — the python
is proved identical, so suspect plumbing, not assertions.
