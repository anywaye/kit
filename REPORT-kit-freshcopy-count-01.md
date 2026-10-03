# REPORT — kit-freshcopy-count-01

**Branch:** `worker/kit-fresh-copy-reports-01`
**Base the packet named:** `c5e4282`
**HEAD when I finished:** `8f97213` + my commit (see §7 — not what the packet expected)

## 1. The finding, in one paragraph

`c5e4282` fixed a real false red and got the causal chain right: `reports/` was
missing from `fresh_copy`'s closed entry list, `readme_check` asserts both halves
for every path it names, and every throwaway copy therefore ran a gate whose
README described a file the copy did not have. That stands and I have not
touched it. What was wrong is the **number** the commit attached to the claim —
`64 throwaway copies` — which appears in **three** places and is not a count of
anything at any commit in the history. There is no single correct number to put
in its place, because a run's copy count is a property of the machine and of how
far the run got. The claim has been rewritten number-free, and the measurement
that shows why is now in the comment.

## 2. The count, and the command that produced it

Method: instrument `fresh_copy` in a **throwaway copy** of the tree, run the
suite, read what it wrote. Nothing in the repository was instrumented and no
counter survives — §6 lists the five points and they exist only in the throwaway.

The suite's own file says this phase hits a **90-minute bound** on a busy box
(`AGENTS.md`, "A `BOUND` self_test is a gate to run BY HAND"). A run this packet
could afford inside its clock does not exist, so the child gate is replaced with
a stub. The stub replaces a **child process**, not control flow: the question is
which `$(fresh_copy …)` sites *execute*, and the stub cannot change that unless
some site's guard reads a gate verdict. That is not asserted — it is **measured
in both directions** below (`gate_green` / `gate_red` are identical).

```
$ bash count-copies.sh /Users/kaka/Code/any/moon/cafaye/wt-m39-kit-freshcopy-01
instrumentation verified in .../kit/tests/self_test.sh (5 points)
narrowed PATH verified: ruby, kamal and kamal-backup are unreachable

static invocation sites: 92
expect_red_check sites: 88

full_gate_green                    copies=92    distinct=92    recipes=108
full_gate_red                      copies=92    distinct=92    recipes=108
noruby_gate_green                  copies=79    distinct=79    recipes=99
noruby_gate_red                    copies=79    distinct=79    recipes=99
```

And the same walk with the suite's own `exit 1` **left in place**
(`count-copies-noguard.sh`, identical except for one deleted step):

```
full_gate_green                    copies=89    distinct=89    recipes=105
full_gate_red                      copies=89    distinct=89    recipes=105
noruby_gate_green                  copies=76    distinct=76    recipes=96
noruby_gate_red                    copies=76    distinct=76    recipes=96
```

**The matrix, and every cell of it is a real run:**

| toolchains on `PATH` | suite's own `exit 1` | copies a run makes |
| --- | --- | --- |
| ruby + kamal + kamal-backup | neutralised | **92** |
| all three unreachable | neutralised | **79** |
| ruby + kamal + kamal-backup | left in place | **89** |
| all three unreachable | left in place | **76** |

Four numbers. `64` is not reachable from any of them, and no combination of
them is 64 — it is below the floor.

## 3. Why there is no single number — three independent reasons

**(a) 13 of the 92 sites are behind `command -v` guards.** Measured, not read off
the source: `noruby_gate_*` drops exactly 13 (92 → 79), and the run prints the
four `SKIP` rows that say why.

```
SKIP self_test: breakage 23: the interpreter floor is defined but never consulted — ruby not installed
SKIP self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — ruby not installed
SKIP self_test: breakage 40: the toolchain floor is defined but never consulted — ruby not installed
SKIP self_test: breakages 78-82 — kamal or kamal-backup is not installed
```

3 under `command -v ruby` (breakages 23, 23b, 40) and 10 under
`command -v kamal && command -v kamal-backup` (78b–82, 84–87).

**(b) 3 more sit *after* the suite's own `exit 1`.** `breakages 101, 102, 103`
(`tests/self_test.sh:4865`, `:4891`, `:4931`) come after

```bash
if [ "$failures" -ne 0 ]; then
  ...
  exit 1
fi
```

so a run that failed or skipped anything never reaches them. That is the
89-vs-92 and the 76-vs-79 halves. This is the reason the count is not even stable
on one machine, and it is why "invocation sites" was never the same number as
"copies a run makes" — the packet's hypothesis, confirmed.

**(c) The gate's verdict does not matter.** `gate_green` and `gate_red` are
identical in all four rows. So the stub is not what produced the number, which is
the only thing a stubbed measurement had to prove about itself.

## 4. The static count, checked where the packet asked

```
$ for r in 81fffa6 9cddeee 3cdcd3b c5e4282 8f97213 master; do
    printf '%-10s sites=%-4s expect_red_check=%s\n' "$r" \
      "$(git show ${r}:tests/self_test.sh | grep -cE '\$\(fresh_copy ')" \
      "$(git show ${r}:tests/self_test.sh | grep -cE '^[[:space:]]*expect_red_check ')"
  done
81fffa6    sites=92   expect_red_check=88
9cddeee    sites=92   expect_red_check=88
3cdcd3b    sites=92   expect_red_check=88
c5e4282    sites=92   expect_red_check=88
8f97213    sites=92   expect_red_check=88
master     sites=92   expect_red_check=88
```

So the packet's measurement reproduces exactly: **92** sites, **88**
`expect_red_check`, at every commit. `88` is untouched in my diff — I only
re-measured it.

## 5. What I changed, and why no number was pinned

Three files' worth of homes turned out to be three, not two:

1. **`tests/self_test.sh`** — `fresh_copy`'s comment. `"every one of this
   suite's 64 throwaway copies"` → `"every throwaway copy this suite makes"`,
   plus a short paragraph giving the four measured numbers, the three reasons
   they differ, and the 92 that is the one number a reader can reproduce with
   `grep`.
2. **`CHANGELOG.md`** — **a third home the packet did not know about.** The
   `### Fixed` entry from `c5e4282` opens `"…so all 64 throwaway copies were
   trees…"`. The CHANGELOG is the most-read of the three, so leaving it would
   have preserved the defect in the place that matters most, and it would have
   left the exact shape the packet warns about: a wrong number in one place and
   a right one in another teaches the reader to trust the wrong one.
3. **The commit message of `c5e4282`** — see §7 for why this is a new commit
   rather than an amend.

**Why the number is gone rather than replaced by 92:** 92 is the *ceiling*, not
the answer. A reader who writes "this suite makes 92 copies" has written down a
number that is false on a machine without kamal and false in any run that fails
or skips something — which is most runs, since a red suite is the normal state
of a packet that is looking for red. `every copy this suite makes` is true on
every machine, in every run, forever, and it is the claim that was actually
being made. The numbers are recorded *beside* it as the reason, not *as* it.

## 6. Instrumentation — all five points, verbatim

Throwaway copy only (`mktemp -d`, discarded with the logs). Nothing was left in
the repository, and there is no counter in the tree.

```python
# 1. fresh_copy — the counter. Nothing else about the function changes.
'  local dst="$WORK/$copy_name/kit"\n'
'  local dst="$WORK/$copy_name/kit"\n'
'  printf \'%s\\t%s\\n\' "$$" "$copy_name" >>"${KIT_COPY_LOG:?unset}"\n'

# 2. kit_child_gate — the child gate becomes a verdict the caller chooses, so the
#    same walk can be run green and red.
'    KIT_PYTHON="$PY" KIT_NO_LIVE=1 bash tests/validate.sh "$@"\n'
'    exit "${KIT_STUB_EXIT:-0}"\n'

# 3. errexit off, so no stub-induced non-zero aborts the walk half way through.
'set -euo pipefail\n'  ->  'set -uo pipefail\nset +e\n'

# 4. the suite's own `exit 1` removed (the no-guard variant keeps it), because
#    three fresh_copy sites sit below it and leaving it under-reports by three.
'  exit 1\n'  ->  ''

# 5. the three helpers that spawn a child some other way, plus the one whose
#    assertion greps the child's output.
for fn in ("expect_red_script", "expect_green_script", "expect_red_lang",
           "expect_skip_check"):
    #   early return, inserted immediately after the `_shard_ran` increment
```

Two of these were **found broken by running them**, not by reading them, and both
are worth recording because each produced a plausible wrong number first:

- **Attempt 1 returned 21.** The stub was inserted after the first
  `_shard_ran=$((_shard_ran + 1))` *inside the function*, which is the one nested
  in the `_stale_edit` guard. The stub therefore sat inside an `if` that is false
  on a healthy run and never fired; the real helpers ran; the run aborted at
  breakage 23b on an unguarded `printf … | grep '^SKIP'` returning 1 under
  `pipefail`; and the suite stopped with 21 copies. A count from that run would
  have been confidently wrong. Fixed by anchoring on `\n  _shard_ran=…\n` (two
  spaces, so it cannot match the nested four-space line).
- **Attempt 2 returned 241, from 89 distinct names.** `tests/shard_test.sh`
  (breakages 94, 95) runs `tests/self_test.sh` as a child, so the log collected
  three nested full walks. Fixed by logging `$$` with every entry and counting
  only the top-level PID. **Without the PID the number would have been 241**,
  which is a much more convincing-looking wrong answer than 64.

Every instrumentation point is verified present in the file before the run
(`grep -q` on `KIT_COPY_LOG`, `KIT_STUB_EXIT`, `KIT_STUB_SCRIPTS`, `STUBBED`),
because a mutation that silently failed to apply produces a count that proves
nothing.

The counting script itself is **not committed**, deliberately: `AGENTS.md`
refuses a fifth carve-out program by name and says the paragraph is not a
precedent. The five edits above plus the four-run matrix are enough to
reconstruct it.

## 7. What I did not do, and one thing the packet did not anticipate

**I did not `git commit --amend`.** The packet's instruction assumed `c5e4282`
was HEAD. It was not, when I looked:

```
$ git reflog -3
8f97213 HEAD@{0}: commit: self_test 38: the needle is the label, and 81fffa6 renamed the check it named
c5e4282 HEAD@{1}: checkout: moving from worker/kit-fresh-copy-reports-01 to worker/kit-fresh-copy-reports-01
c5e4282 HEAD@{2}: commit: fresh_copy: `reports` is on the list, and 64 copies were red for a reason of their own
```

`8f97213` is a complete, unrelated commit (a stale `expect_red_check` needle in
breakage 38, from the `81fffa6` check rename) that landed on this branch at
02:11:20, during my run. It is not mine and I cannot tell from here whether it
is the previous run of this packet or another session's work, and the standing
contract says not to rewrite work I did not write and cannot identify.
Amending would have rewritten its parentage and its SHA.

So the correction is a **new commit whose message states that it supersedes the
`64` in `c5e4282`'s message.** A reader who greps this branch for
`64 throwaway copies` now finds three hits, all of them the correction or its
cross-reference, and no bare assertion. If the manager would rather have one
commit, this is a clean `rebase -i` squash: the two touch different hunks of
`tests/self_test.sh` (mine at line ~876, `8f97213` at ~3248).

`8f97213` does not change any count: it adds no `fresh_copy` site, and both
files still read 92 sites / 88 `expect_red_check` at `8f97213`.

### Three findings outside the packet — named, measured, not touched

1. **Four more unreproducible copy counts in the same file.** Same defect class,
   same file, all now measured:

   | line | claim | actual |
   | --- | --- | --- |
   | 821 | `DECISIONS.md` absence "fails that check sixty-odd times over" | 76–92 |
   | 836 | "every one of the ~107 throwaway copies" | 76–92 |
   | 956 | "the twenty-odd copies this script makes per gate run" | 76–92 |
   | 970 | "every one of the twenty-odd copies fails that check" | 76–92 |

   I left them because the packet scoped itself to "one number and its two
   homes" — but the honest position is that fixing `64` and leaving `107` four
   lines below it makes the file *less* coherent, not more. Each is a two-line
   edit with the same replacement. **This is the next packet, and it is a
   twenty-minute one.**

2. **`tests/self_test.sh:4173` — a SKIP row that under-names what it skipped.**
   The `kamal`/`kamal-backup` guard covers breakages **78b–82 and 84–87**, ten
   recipes. The row says `SKIP self_test: breakages 78-82`. Four recipes
   (84, 85, 86, 87 — the initdb mount, `.env.example` tenant, compose default
   tenant, harness tenant) are skipped and not named, which is a skip nobody can
   see by reading the report. This is the "a skip nobody can see is a silent
   pass" rule, in a row that exists to prevent it. Note the count is *not*
   derived — so it can be fixed by deriving it, the way this file derives its
   other counts.

3. **`c5e4282`'s message is stale about the `generated stack` debt.** It says
   "4 repositories hold a `cafaye.yml` and do not ignore
   `/caf.dev.compose.yaml`", measured at `2e75d34`. On this branch today the
   check reports **2 in frozen repositories, reported not counted** — the scope
   decision has moved. Same number-in-a-message failure mode, one layer up.

## 8. Verification

| | |
| --- | --- |
| `bash -n tests/self_test.sh` | OK |
| `shellcheck -S warning tests/self_test.sh` | OK |
| `grep -cE '^\s*expect_red_check '` | **88** — unchanged, as the packet requires |
| `grep -cE '\$\(fresh_copy '` | **92** — unchanged |
| `reports` still on `fresh_copy`'s list | yes, alphabetically among the directories |
| no structural change to `fresh_copy` | yes — one `printf` line added *inside its comment block* |
| recipes added | none |
| `bash tests/validate.sh --static-only` | **1 FAIL**, `generated stack` — **pre-existing, measured** |

The one FAIL, before and after, in the *same* worktree with the fleet beside it:

```
$ git stash push -q -- tests/self_test.sh      # my edit removed, nothing else
$ KIT_NO_LIVE=1 bash tests/validate.sh --static-only --only='generated stack'
FAIL generated stack  (no repository commits the file caf dev generates); 2 in frozen repositories, reported not counted
$ git stash pop -q
```

Identical with and without my change, and
`tests/generated_stack_check.py` never mentions `tests/self_test.sh` — it asks
git two questions about sibling repositories. **Not mine, not fixed, not
weakened.**

**Skipped and counted, because a skip nobody can see is a silent pass:**

```
SKIP templates/database/tenancy/{advisor,isolation,substrate}.sql  (needs a real Postgres)
SKIP templates/tier/{bun,node}/tier.test.ts  (node --check cannot read TypeScript)
SKIP lint_test.sh  (--no-lint)
note: --no-live: the observability live tier (canary, collector-killed, fetched stack)
       did NOT run. Three claims are UNEXERCISED by this run.
```

**Not run at all, and named:** the full `bash tests/validate.sh` including the
`self_test` phase (90-minute bound on this box), the observability live tier
(three docker stacks), `lint_test.sh`, and the four docker tiers. The packet
needed a *count*, and the count was obtained by instrumenting the harness rather
than by running the whole gate; the static phase above is what I could afford
and it is not the whole suite.

**Nothing left running by me:** this session ran no `docker` command at all, so
it created no container, image or volume. The machine does have pre-existing
ones (`kit-dbg*_pgdata` volumes, `searxng-*` and `buildx_*` containers) left by
other sessions — left untouched per the contract, and named here so a reader
does not attribute them to this packet. Every command carried a `timeout`
(600s per suite run, 300–960s per gate run). The throwaway trees and their logs
are under `/var/folders/.../kit-freshcopy-count.*` and are the only artefacts;
delete them freely.

## 9. What I would do next

1. The four sibling counts (§7.1) — one packet, twenty minutes, same replacement.
2. Derive the `78-82` SKIP row's range from the guarded recipes (§7.2) rather
   than writing it, so the next recipe added inside that `if` is named by
   construction.
3. Consider whether the three post-`exit 1` recipes should move *above* the
   guard. They are currently unreachable in any run with a failure, which means
   breakages 101–103 are unexercised precisely when the suite is telling you
   something — and this packet's own instrument had to neutralise the guard to
   see them.