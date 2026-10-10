# REPORT — no-licence-test (ops/no-licence-test)

**Packet:** remove kit's licence check from `tests/validate.sh` entirely.
**Policy:** WE DO NOT TEST LICENCES (user's, 2026-10-10). A licence is not behaviour; a test
asserting licence properties cannot fail for a reason a user would ever notice, and it rots
every time the grant legitimately changes. kit's gate has one and it must go.

**Status: ACCOMPLISHED.** One commit, `a4d47ae`, on `ops/no-licence-test` (not merged, not
pushed — the manager does that).

```
kit: WE DO NOT TEST LICENCES — the check goes, entire
 tests/validate.sh | 235 ------------------------------------------------------
 1 file changed, 235 deletions(-)
```

`git diff` is a **pure deletion**: every changed line is a `-`, there is not one `+`. The
other 5,451 lines of `validate.sh` are byte-for-byte unchanged.

## What was removed

The whole family, in one contiguous block, `tests/validate.sh` lines 1997–2231:

1. **The comment block** (lines 1997–2066, 70 lines) — "WHY THIS EXISTS", the four numbered
   assertions, the point-4 rationale, the `cafaye.yml`/schema paragraph.
2. **`license_check()`** (lines 2067–2229) — the function and its entire `"$PY" - "$ROOT" <<'PY'`
   heredoc: the MIT grant sentences, the proprietary refusal sentences, the cafaye copyright
   holder regex, the README `## License` section split, the AGPL separation assertion, the
   root-manifest `FIELDS` table, the gemspec glob, and the `AGREES` SPDX regex.
3. **The invocation** (line 2230):
   `check 'LICENSE  (MIT, and nothing in the tree can disagree with it)' license_check`
4. The blank line separating it from the next section, so the seam reads exactly as it did.

## What was kept

- **`$PY` stays.** It is used by ~25 other checks in this file (lines 357, 1134, 1147, 1174,
  1441, 1447, 1518, 2237→now 2002, 2746, …). Only the licence check used it; removing it
  would have broken every other Python-backed check. The brief's "any variable, PY helper,
  or comment block that exists ONLY to serve that check" is deliberately empty here — that
  helper is shared, and `grep` confirms it is.
- **Every other check.** No other check was touched, renamed, weakened, or reordered.
- **Nothing outside `tests/validate.sh`.** `LICENSE`, `README.md`, `cafaye.yml`,
  `AGENTS.md`, `CHANGELOG.md` are untouched, as instructed. Note `AGENTS.md`'s "The licence
  is MIT, and it lives in exactly one place" bullet and its "the check is stale against the
  grant" caveat now describe a check that no longer exists — that is prose drift in a file
  the brief told me not to touch, and it is named here rather than quietly edited. A
  successor who owns `AGENTS.md` should remove that bullet's second half.
- The seams are clean: `static: shellcheck -S warning` is followed directly by
  `static: templates/otel — every artifact is present`, exactly as before.

## Gate evidence — before vs after

Both runs are full, clean, bounded (`timeout 560 bash tests/validate.sh`), and serial (no
other worker's gate was running):

| | before (`bd25e22`) | after (`a4d47ae`) |
|---|---|---|
| exit code | **0** | **0** |
| PASS | 603 | **602** |
| FAIL | 0 | 0 |
| SKIP | 9 | 9 |
| phases/sections | 28 | **28** |

"Every check passed" / `PASS: every check passed.` / `note: 9 check(s) skipped — reported
above, never hidden.` / `note: 5 tier(s) ran under a time bound; none was reached.` — all
four identical.

**Exactly one check disappeared, by name.** A diff of the sorted `PASS <label>` lines
between the two runs has one removal and nothing else:

```
164d163
< PASS LICENSE  (MIT, and nothing in the tree can disagree with it)
```

The three remaining hunks are run-to-run noise, not differences in what ran:
`kit-failfast-84275` vs `kit-failfast-86238` (random project id), a two-port race reported
in the opposite order (15007 vs 15008), and `refused in 0s` vs `refused in 1s`.

The **section inventory is identical** — `comm` over the `== …` / `-- …` headers of both logs
reports no section present in one and absent from the other, 28 in each. So the gate did not
pass by silently running less: it ran one fewer check, and that one is the licence check.

`grep -c 'LICENSE  (MIT'` on the after-run: **0**. On the before-run: **1**.

Also verified locally: `bash -n tests/validate.sh` OK, and `shellcheck -S warning -e SC2317
tests/validate.sh` clean (the repo's own config applied to the edited file).

## The one thing I got wrong, recorded because it cost a gate

My first baseline run was launched **before** the edit and left running **while I edited the
file**. `bash` reads a script incrementally, so deleting 235 lines mid-execution moved the
byte offset out from under it and the run died at `line 5438: syntax error near unexpected
token '('` with a misleading `exit: 0`. That run is worthless and is preserved as
`/tmp/gate-no-licence-baseline.log` if anyone wants to see the failure mode. The numbers
above are both from runs started on a settled tree.

## Environment hazard: the worktree was deleted mid-run (twice)

At roughly the 30-minute mark, `/Users/kaka/Code/any/ops-wt/no-licence-test` **vanished** —
the parent `ops-wt/` still held sibling worktrees, so this was not `ops-wt/` being torn down;
something removed my specific directory while the after-gate was running. It then deleted
the whole `ops-wt/` tree a second time while I was writing this report.

Status after recovery:

- **The commits are intact.** `a4d47ae` lives in the shared object store of the main repo
  (`/Users/kaka/Code/any/moon/cafaye/kit`), because a `git worktree` shares objects with its
  parent. `git rev-parse ops/no-licence-test` → `a4d47ae3cef44…`. Nothing was lost.
- **The worktree was restored twice**, each time by `mkdir` + rewriting the `.git`
  indirection file to `/Users/kaka/Code/any/moon/cafaye/kit/.git/worktrees/no-licence-test`
  + `git reset --hard HEAD`. `git worktree repair` refuses ("not a valid path"), so the
  manual route is the one that works. `status --short --branch` reports `## ops/no-licence-test`
  with no changes.
- If the directory disappears again, the recovery is the three lines above, and the real
  deliverable — the commit on the branch — is unaffected either way.
- The worktree's only casualty was `brief.txt`, which was untracked and is the manager's
  file anyway.

## What is NOT done, and why it is fine

- No `CHANGELOG.md` entry — the brief forbade touching it, and the deletion has no
  user-visible behaviour. Flagging it so the merger adds the entry in the merge commit.
- No `AGENTS.md` correction (see above) — same reason, same recommendation.
- No new check was added to replace the old one, in any strength. That is the whole point of
  the packet, and the absence is deliberate rather than an omission.

## Successor's first move

There is nothing left to do in this packet; it is complete and committed. If you are picking
up the *adjacent* work:

1. `AGENTS.md`'s licence bullet (and its "stale against the grant" caveat) describes a
   check that no longer exists — that is the one piece of prose drift this deletion caused.
2. `git log tests/validate.sh` will show this check's full history: added asserting
   proprietary, re-pointed to MIT in `bd25e22`, deleted here. If the same "assert the
   agreement, not the presence of a file" instinct reappears as a new licence check
   somewhere else in the tree — a `rules.json` rule, a `tests/*.sh` helper, a schematic —
   it is the same defect and this commit is the precedent for deleting it.
3. Re-run `timeout 560 bash tests/validate.sh` if you want your own baseline; it is ~226 s
   and exits 0.
