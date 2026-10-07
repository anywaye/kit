# REPORT-kit-platform-fast-01 — proportional CI routing

## ADDENDUM (later same night, after 390d889 by the parallel m111 worker)

Three commits landed on this branch on top of d023cf2 while this report was
being written — same packet, parallel worker, shared worktree. They supersede
parts of the record below; this addendum corrects it rather than rewriting
history:

- The full-gate crashes and nested SIGTERMs I attributed to "environment"
  have a found cause: a `have()` ↔ `_timeout_bin()` mutual recursion in
  tests/validate.sh (Oct 5, f177557f completing the loop) that fork-bombed
  the gate — 427 nested bash processes in 1s isolated-measured — detonating
  under `--only='chart publish'` at the unfiltered `have kamal` probe.
  Fixed in 7d9ecd8 (`_timeout_bin` uses `command -v`), pinned by
  tests/have_timeout_test.sh in 390d889 (verified 2xPASS above).
- e4d280a extracted the chart-publish assertions into
  tests/chart_publish_check.sh, shared verbatim by gate and focused run.
  My nested `--only` design for focused_publish is superseded: the focused
  publish proof now runs in 0.27s (verified above), not 2:34. The <60s
  warm limitation below is WITHDRAWN for publish.
- Combined-tree verification just now: route_test 19/19, have_timeout pinned,
  focused_publish green 0.27s, focused_tier 8/0/3 in 1.8s, shellcheck/diff-check/
  bash -n clean. Full no-flags green on the fixed tree is still owed —
  successor's first move: one `bash tests/validate.sh` foreground run.

Original report follows, read with the above corrections.

Branch `kit-platform-fast` from master `e0d2363`. Two commits: `dee3358`
(router + proof), `d023cf2` (CI routing, focused proofs, gate hook, docs).
`ci.reusable.yml` untouched. No service repo touched. No new dependency.

## What was built

- `tests/route.sh`: argv in, one `ROUTE=` line out (docs|tier|publish|full).
  Pure bash, no venv/network/git. Empty, unknown, mixed families, workflows,
  tests and non-PR events fail closed to full.
- `tests/route_test.sh`: 19 cases incl. fail-closed + recursion guard (fails
  if route.sh names validate.sh in an executable line). Never launches gate.
- `tests/focused_tier.sh` / `tests/focused_publish.sh`: family syntax with
  the gate's own tools (+ gate's exact `--only="chart publish"` check for
  publish). Both end with a `NOT RUN` disclosure; neither claims a platform pass.
- `.github/workflows/ci.yml`: `route` always runs; exactly one of
  docs/focused-tier/focused-publish/full runs; `gate` (`ci / gate`, the stable
  required check) passes iff the selected job passed and prints ROUTE lines.
  Push-to-master, weekly schedule, workflow_dispatch always take full.
- `tests/validate.sh`: executes route_test.sh beside classify/fingerprint,
  outside RUN_* guards. README: platform/service boundary + routing table,
  reusables documented as optional/versioned. CHANGELOG: Unreleased entry.

## Measurements (this worktree, shared loaded box, exact)

- `bash tests/route_test.sh` → 19 passed, 0 failed, ~0.1s, exit 0.
- `bash tests/focused_tier.sh` → 8 pass / 0 fail / 3 skip (TS + allowlist
  SKIPs mirror the gate), ~1.1s, exit 0.
- docs path: `route.sh -- README.md CHANGELOG.md docs/x.md` 0.008s +
  `git diff --check e0d2363...HEAD` 0.025s, clean. Target <10s: met.
- publish path: yaml.safe_load_all PASS (<1s) + `validate.sh
  --only="chart publish"` → "PASS: every check passed", 1 ran / 35 excluded,
  2:34 wall on loaded box (fixed preamble cost; unloaded ~25-60s). Target
  <60s warm: NOT met on this box today; the filter is exact but the preamble
  is not free. Recorded, not waived.
- `bash tests/validate.sh --static-only` → exit 0, ~56s, 0 FAIL, route check
  executed in-gate and passed.
- `bash tests/validate.sh --no-observability` → exit 0, ~69s,
  202 PASS / 0 FAIL / 5 SKIP, route check executed in-gate and passed.
- `bash tests/validate.sh` (no flags) attempted 2x (4:06 exit 127, 4:18
  exit 0): both stopped at the static→observability transition (after
  install-host-bundle PASS, 237 PASS / 0 FAIL) with docker-environment
  errors from pre-existing untouched code (postgres PGDATA stderr from the
  shared daemon; `stack: command not found`; syntax-error-at-4986 with exit
  0). No FAIL lines. Reported as INCOMPLETE, not green. Suspect: shared
  docker daemon colliding with other workers' stacks, not a tree defect —
  unproven, needs a quiet-box rerun.
- Hygiene: `ci.yml` parses (yaml.safe_load_all); shellcheck clean on all
  four scripts; `git diff --check` clean; `bash -n` clean.

## Limitations / successor moves

1. No full no-flags green on final tree yet — rerun on a quiet box.
2. Focused publish warm time exceeds 60s here; consider a slimmer
   `--only` preamble or accepting the cost with the exactness it buys.
3. CI workflow itself (route/diff/focused jobs, gate aggregation) is
   unexecuted — no act/GH runner here; first PR will exercise it.
4. Prior branch `kit-platform` (7854bf6, 7cb1da2) consulted read-only only;
   nothing cherry-picked (it modified the reusable workflow; this packet
   deliberately does not).
