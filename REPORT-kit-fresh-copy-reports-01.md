# REPORT — kit-fresh-copy-reports-01

`fresh_copy` in `tests/self_test.sh` did not copy `reports/`, so every one of this
suite's throwaway copies was a tree whose `README.md` documented a file the copy did
not have. One entry, plus a second defect found while measuring it.

---

## 1. The mechanism, in one sentence

`readme_check` asserts **both** halves for every path it names — that `README.md`
mentions it, and that `os.path.exists` says it is there — and
`reports/account-scope-contract-01/snapshot.sh` is on that list; `fresh_copy`'s entry
list is explicit and closed, so a directory the gate reaches one member deep was not
on it.

`tests/validate.sh:9119-9133`:

```python
    "tests/account_scope_fleet_check.py",
    "tests/account_scope_fleet_ratchet.yml",
    "tests/account_scope_fleet_scope.yml",
    "reports/account-scope-contract-01/snapshot.sh",
):
    if path not in readme:
        problems.append(f"README.md never mentions {path}")
    if not os.path.exists(os.path.join(root, path)):
        problems.append(f"README.md documents {path}, which does not exist")
```

`tests/self_test.sh` before the change, the list at the bottom of `fresh_copy`:

```bash
  for entry in .gitleaks.toml .github AGENTS.md README.md CHANGELOG.md LICENSE \
    DECISIONS.md MIGRATIONS.md RESERVED VERSION core docker lint templates tests; do
```

**A correction to the brief's history, measured rather than repeated.** The brief
says `9cddeee` added the README line and `3cdcd3b` added the `prove-*` material.
Neither is what happened:

```
$ git log --oneline --diff-filter=A -- reports/account-scope-contract-01/snapshot.sh
81fffa6 account-scope contract: a fleet runner that is RED on arrival, on purpose

$ git log --oneline -S 'reports/account-scope-contract-01/snapshot.sh' -- README.md tests/validate.sh
81fffa6 account-scope contract: a fleet runner that is RED on arrival, on purpose

$ git diff --name-status 3cdcd3b^1 3cdcd3b -- reports
(no output)
```

The file, the `README.md` line and the `readme_check` list entry **all landed in one
commit**, `81fffa6`, which `9cddeee` merged. There is no `prove-*` file under
`reports/account-scope-contract-01/` in this tree. So this was never a two-commit
split and never a half-finished packet: the packet did three of the four things a path
the gate reads by path requires, in one diff, on a tree whose own gate was green
throughout. That is a stronger statement than the brief's, and it is the one the
comment in `fresh_copy` now makes — no review of that packet's diff could have found
it, and the only witness is a green `unbroken tree`.

**Three couplings, not one.** `81fffa6` reached into this harness three separate ways,
and all three are in this report because all three were found by running the suite
rather than by reading it:

| # | what `81fffa6` did | what it broke | where |
| --- | --- | --- | --- |
| 1 | added a path under `reports/` to `readme_check`'s list | every copy red on `README.md` | §2, §3 |
| 2 | renamed the carve-out check's **label** | breakage 38's needle unreachable | §4a |
| 3 | added a check that reads a fleet | breakage 59's synthetic fleet cannot satisfy it | §4b |

---

## 2. Before / after, on two copies of the SAME tree

Two copies were built by hand, from the same bytes of the same tree, differing **only**
in whether `reports/` was present — built the way `fresh_copy` builds one (the entry
list above, `chmod +x "$dst"/tests/*.sh`, `KIT_GITLEAKS` resolved to kit's fetched
binary). Then `validate.sh --static-only` in each.

| tree | exit | `FAIL` rows | the row |
| --- | --- | --- | --- |
| `fresh_copy` at `HEAD~1`, no `reports/` | **1** | **1** | `README.md  (documents every new template)` |
| same tree + `reports/` | **0** | **0** | — |

Before, verbatim:

```
FAIL README.md  (documents every new template)
       README.md documents reports/account-scope-contract-01/snapshot.sh, which does not exist
PASS LICENSE  (MIT, and nothing in the tree can disagree with it)
```

After:

```
PASS README.md  (documents every new template)
```

and the tail:

```
       human or CI runs sets this flag; it exists for the throwaway gates in
       tests/self_test.sh, none of which asserts anything about those three.
PASS: every check passed.
note: 11 check(s) skipped — reported above, never hidden.
note: 2 tier(s) ran under a time bound; none was reached.
```

**The pre-existing failure is invisible in a copy, which is worth recording.**
`generated stack` reports on the fleet, and a copy has no fleet beside it:

```
SKIP generated stack  (no cafaye repository on this machine - set KIT_FLEET=<dir>)
SKIP fleet adoption  (no cafaye repository on this machine — set KIT_FLEET=<dir>)
SKIP adopting repositories  (no fleet beside this one — set KIT_FLEET)
```

So the one `FAIL` the after-copy removed is the whole of the difference, and a
`fresh_copy` run can never have been reporting on `generated stack` at all.

---

## 3. The two directions, and why the loud one is not the dangerous one

**The false red** is the legible half. `expect_green 'unbroken tree'` runs first and
prints `the gate is RED on an unbroken tree` — the sentence that makes every proof
below it meaningless — and the green-expecting proofs (23b, 31b, 59) go red with it.

**The silent half** is the reason this needed doing rather than shrugging at. Counted
on this tree:

| helper | invocations | reaches the README check? |
| --- | --- | --- |
| `expect_red_check` | 88 | **no** — it appends `--only=<label>` to every child that does not already carry one |
| `expect_red_lang` / `expect_red_script` | 14 | no — one language's suite, or one named script |
| `expect_green_script` (78b) | 1 | no — it runs `tests/kamal_test.sh` |
| `expect_green` (unbroken tree, 31b) | 2 | **yes** |
| `expect_skip_check` (23b) | 1 | **yes** |
| `expect_green_check` (59) | 1 | **yes** — deliberately unfiltered |
| `expect_red` | **1** | **yes** — and it asserts the gate's exit status and nothing else |

The single plain `expect_red` in the file is **breakage 1**, and `the gate went red`
is satisfied by a copy that is red for any reason at all. One recipe is not a number
anybody would act on. It is the **shape** that matters: the direction of travel is one
recipe per packet that adds an unfiltered assertion, and the day the count is large
the suite reports `every proof held` while a growing share of the proofs proved
nothing — the exact inverse of the false red, and the harder of the two to notice,
because a suite that always goes red is at least reporting something true.

---

## 4. Uncaught breakages, before and after

`bash tests/self_test.sh`, full suite, `timeout 9000`, no timeout reached. Three
complete runs, one per state of the tree. **Tallies and verdicts kept apart** — the
`FAIL` column is a tally of recipes that did not hold, and it is not a claim about the
tree.

| run | harness | evaluated | `PASS` | `FAIL` — the gate did not catch | exit |
| --- | --- | --- | --- | --- | --- |
| **BEFORE** | `HEAD~1`'s `self_test.sh` | 105 | 100 | **5** — unbroken tree, 23b, 31b, 38, 59 | 1 |
| **AFTER** | `reports` on the list (`c5e4282`) | 105 | 103 | **2** — 38, 59 | 1 |
| **FINAL** | + the needle on 38 (`8f97213`) | 105 | 104 | **1** — 59 | 1 |

BEFORE, the five:

```
FAIL self_test: unbroken tree — the gate is RED on an unbroken tree (exit 1)
FAIL self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — the gate exited 1, so the skip was not clean
FAIL self_test: breakage 31b: a service config that MATCHES kit is not a failure — the gate is RED on an unbroken tree (exit 1)
FAIL self_test: breakage 38: one of the two programs gains a third-party import — the gate went red, but NOT via `tests/classify.py + tests/staleness.py`
FAIL self_test: breakage 59: an UNADOPTED service copies the stack — green, and named — the gate went RED (exit 1), so the ceiling is not in force
FAIL: self_test — 5 breakage(s) the gate did not catch.
```

AFTER, the two:

```
FAIL self_test: breakage 38: one of the two programs gains a third-party import — the gate went red, but NOT via `tests/classify.py + tests/staleness.py`
FAIL self_test: breakage 59: an UNADOPTED service copies the stack — green, and named — the gate went RED (exit 1), so the ceiling is not in force
FAIL: self_test — 2 breakage(s) the gate did not catch.
```

FINAL, the one, and the four that are green beside it:

```
PASS self_test: unbroken tree — the gate is green on an unbroken tree
PASS self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — reported as `templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)`
PASS self_test: breakage 31b: a service config that MATCHES kit is not a failure — the gate is green on an unbroken tree
PASS self_test: breakage 38: one of the two programs gains a third-party import — caught by `the carve-out programs`
FAIL self_test: breakage 59: an UNADOPTED service copies the stack — green, and named — the gate went RED (exit 1), so the ceiling is not in force
FAIL: self_test — 1 breakage(s) the gate did not catch.
```

**Both remaining failures are `81fffa6`'s as well, and neither is a consequence of the
missing `reports/`.** Both were red before this packet touched anything, and both are
harness↔tree couplings the same commit left behind.

### 4a. Breakage 38 — the needle names a label the check no longer emits. FIXED.

`81fffa6` added a fourth carve-out program and, in the same hunk, renamed the check
that owns all four:

```
$ git show 81fffa6 -- tests/validate.sh | grep -E '^[-+].*(classify\.py \+ tests/staleness|the carve-out programs)'
-  check 'tests/classify.py + tests/staleness.py  (stdlib only; the carve-out, enforced)' \
+  check 'the carve-out programs  (stdlib plus PyYAML; enforced, and AGENTS.md agrees)' \

$ grep -c 'tests/classify\.py + tests/staleness\.py' tests/validate.sh
0
```

`expect_red_check` matches `FAIL $want` **and** passes `$want` to `--only`, and `--only`
is a substring match on a check's label (`tests/validate.sh:451-454`). A label that no
longer exists does not weaken the proof, it deletes it — and silently, in the worst
direction available, because `--only` matching nothing is **itself a fail**, which is
a non-zero exit, which is all `the gate went red` asks for. Only the `FAIL $want` half
noticed.

Measured in a copy, with the recipe's own mutation, both spellings:

```
$ bash tests/validate.sh '--only=tests/classify.py + tests/staleness.py' --static-only
FAIL: --only='tests/classify.py + tests/staleness.py' selected NO check out of the suite.
exit 1                       # needle unreachable, always

$ # same copy, mutation applied, corrected needle
$ bash tests/validate.sh '--only=the carve-out programs' --static-only
FAIL the carve-out programs  (stdlib plus PyYAML; enforced, and AGENTS.md agrees)
note: FILTERED run -- 1 check(s) ran, 96 excluded by --only='the carve-out programs'.
FAIL: 1 check(s) failed.
exit 1                       # red, and red for the RIGHT reason

$ # same copy, mutation reverted — the control
$ bash tests/validate.sh '--only=the carve-out programs' --static-only
note: FILTERED run -- 1 check(s) ran, 96 excluded by --only='the carve-out programs'.
PASS: every check passed.
exit 0
```

Fixed in `8f97213`, and confirmed in the FINAL run: `caught by \`the carve-out
programs\``. This is the **only proof in the repository that kit gains no dependency**,
and a dead needle is indistinguishable from a satisfied assertion from the outside.
AGENTS.md's rule — *the needle is the label, and a label a self-test asserts is a
contract* — has now been paid for here five times; 71, 75, 76 and 77 were the first
four, and AGENTS.md records each.

### 4b. Breakage 59 — a new fleet-reading check the synthetic fleet cannot satisfy. **LEFT ALONE, ON PURPOSE.**

`expect_green_check` runs a whole unfiltered gate with `KIT_FLEET` pointed at
`fixture_fleet`'s two-repository synthetic fleet (`alpha`, `beta`), and
`in-scope repositories  (every one declares its account-scoped surface)` then asks for
`$KIT_FLEET/core/harness/account_scope_check.py`. Reproduced by hand:

```
FAIL in-scope repositories  (every one declares its account-scoped surface)
       COULD NOT RUN: no account-scope checker at …/fixtures/ceiling-unadopted/core/harness/account_scope_check.py.
```

and it is **not** a one-liner to fix. Adding a stub `core` is not enough — the runner
reads the vendored scope table, which puts nine repositories in the MVP and fails on
the first one a two-repository fixture does not have:

```
$ python3 tests/account_scope_fleet_check.py --repos-dir <fixture with a stub core>
COULD NOT RUN: identity is in the scope decision and there is no checkout at …/identity.
               A repository that cannot be read is not a repository that passed.
SCOPE-READ: tests/account_scope_fleet_scope.yml (vendored — no MVP-SCOPE.md beside the fleet)
            puts 9 repositories in the MVP: identity, courier, guard, site, parlor,
            pantry, caf, kit, core
SCOPE-FINGERPRINT: 9fec5592376e521dd4c34adfeab238b8cd64f243fbe9a618a6d556ab91a434a9
INSTRUMENT: …/core/harness/account_scope_check.py
RECORD: tests/account_scope_fleet_ratchet.yml (9 row(s): 0 missing)
EXIT=2
```

So the fix is **a nine-repository fixture fleet that core's real checker can run
against a matching ratchet record** — a decision about how this suite represents the
account-scope contract at all, shared by the nine recipes that use `fixture_fleet`
(52, 53, 54, 55, 58, 59, 60, 75, 83). That is a different packet from one that adds a
directory to a copy list, and the brief is explicit that a nameable remaining failure
should be named rather than chased. **Left as it is.**

The asymmetry is worth writing down for whoever picks it up, because it is where the
next packet should start. `validate.sh:6596-6611` already has the right instinct for
the *discovery* path —

```bash
      if [ -f "$cand/core/harness/account_scope_check.py" ] \
         && [ -n "$(find "$cand" -maxdepth 2 -name account_scope.yml … )" ]; then
```

— and the comment says why: *"testing for the INSTRUMENT rather than for the directory
is the same instinct as the `gate.yml` probe above: pointing at something that is not a
fleet reports 'no repository checked' — technically true and useless"*. The `KIT_FLEET`
branch at `validate.sh:6624-6626` has no such probe and runs the runner
unconditionally. **59 is red because that branch treats a caller-supplied path as a
fleet on the strength of being a path.**

---

## 5. What still fails on the real tree, and why it is not mine

`bash tests/validate.sh --static-only`, run from inside
`/Users/kaka/Code/any/moon/cafaye/` so the fleet beside the repository is found.

On `HEAD~1`, before the change:

```
FAIL generated stack  (no repository commits the file caf dev generates); 2 in frozen repositories, reported not counted
FAIL: 1 check(s) failed.
exit 1
```

On `HEAD`, after the change — **the same single row, and nothing else**:

```
FAIL generated stack  (no repository commits the file caf dev generates); 2 in frozen repositories, reported not counted
FAIL: 1 check(s) failed.
note: 6 check(s) skipped (reported above).
bash tests/validate.sh --static-only  48.66s user 36.48s system 69% cpu 2:01.78 total
exit 1
```

`--static-only` is the phase set that includes `readme_check`, the classifier, the
staleness reporter, the secrets tier, the shellcheck pass and every fleet check; it
excludes the three docker live tiers, the lint tier and the self-test phase, and §4 is
where the last of those is reported.

It is pre-existing, and measured rather than asserted:

* `tests/generated_stack_check.py` exists at `2e75d34`, and `2e75d34` is an ancestor of
  `81fffa6` — the account-scope packet:

```
$ git cat-file -e 2e75d34:tests/generated_stack_check.py && \
  git merge-base --is-ancestor 2e75d34 81fffa6 && echo yes
yes
```

* the four repositories it names had their `.gitignore` files last touched on
  **2026-09-30**, three days before the account-scope packet:

```
cafaye-rb  2026-09-30
cafaye-ts  2026-09-30
docs       2026-09-30
guard      2026-09-30
```

* and none of the six ignores the file today:

```
cafaye-rb  NOT ignored
cafaye-ts  NOT ignored
docs       NOT ignored
guard      NOT ignored
darkroom   NOT ignored        (frozen by MVP-SCOPE.md, reported not counted)
muse       NOT ignored        (frozen by MVP-SCOPE.md, reported not counted)
```

The debt is four `.gitignore` files in four other repositories, which this brief
forbids me to touch. **Not fixed, and the fix is not mine to make.**

---

## 6. Why 59 is the only one left, and what it would take

Not a summary — the argument, because "I fixed two of five" is not a claim anybody
should act on.

* The four that this packet turned green are green **in the FINAL run itself**, quoted
  in §4: the unbroken-tree control, 23b, 31b and 38. 38's row names the check that
  caught it, `the carve-out programs`, which is the assertion doing its job in the
  direction that matters — the named check, not merely a red gate.
* 59 is red for a cause that has nothing to do with `reports/` or with the needle:
  `in-scope repositories  (every one declares its account-scoped surface)` cannot find
  its instrument in a two-repository fixture, and refuses to report "no repository
  checked" as a pass. §4b has the reproduction, the exit code, and the nine
  repositories the vendored scope table demands.
* It was red in the BEFORE run too, for the same reason, alongside the README red. So
  the count went 5 → 2 → 1 by removing four reds and adding none.

**The pre-`9cddeee` count was 0 and this packet does not get back to it.** Both
survivors are `81ffda6`'s — `81fffa6`'s, to be exact — both are named above with a
reproduction each, and the one left is a decision about a nine-repository fixture
rather than a typo. That is the honest place to stop, and it is the brief's own
instruction: a nameable remaining failure gets named, not chased.

**A fourth and fifth row of evidence, because two runs of this were destroyed** (§7).
The unsharded FINAL run is complete and quoted. A four-way sharded run
(`KIT_SELF_TEST_SHARD=i/4`) also completed all four shards, and shard 2 — the shard
breakage 38 belongs to, `(38-1) % 4 + 1 = 2` — reported `PASS: self_test — shard 2/4
ran 28 of 107 breakages and every one it ran held`. Its other three shards are **not**
evidence: the tree was deleted underneath them, and the two rows that prove it
(`breakage 43` and `breakage 44`) **passed in both intact unsharded runs** with the
same harness and the same mutations.

---

## 7. What this machine did to the measurements, and what that costs the report

Three sessions share this box, and it is a 16GB one. Everything below is environment
and none of it is evidence about the tree — but it changes which numbers in §4 are
measured and which are assembled, so it is written down rather than smoothed over.

1. **The worktree was deleted twice, mid-run, by another session.**
   `wt-m39-kit-freshcopy-01` and `wt-reg-identity-down-05` both vanished while this
   packet was running, and the branch went with them. The first kill presented as a
   crash — `tests/self_test.sh: line 2999: everything.: command not found`, `exit 127`
   — because bash was reading a script being unlinked from under itself. Both commits
   survived as git objects; `git cat-file -t` confirmed them and the ref and worktree
   were rebuilt on top.
2. **A full run was SIGKILLed** by the OOM killer, at 16GB with two other full
   `self_test` runs and two other new worktrees on the box at the same time. The FINAL
   run was therefore taken from a private `git clone --no-local` of `kit` at
   `8f97213`, outside the fleet root, so that a third party's worktree churn could not
   reach it again.
3. **A four-way sharded run completed and is still not evidence for three of its four
   shards** (§6).

What that means for a reader, stated as categories:

* **Measured, complete, unsharded, from the worktree:** BEFORE (5 uncaught) and AFTER
  (2 uncaught). Both finished, both printed their own summary line, both are quoted in
  full.
* **Measured, complete, unsharded, from the private clone:** FINAL (1 uncaught), quoted
  in §4.
* **Measured, complete, sharded:** shard 2/4 only — 28 of 107 breakages, all held.
* **Measured, by hand, both directions, on a purpose-built copy:** everything in §2,
  §4a and §4b. These are the load-bearing claims and **none of them depends on a full
  suite run** — the `reports` half is a whole `validate.sh --static-only` in a
  `fresh_copy`-shaped tree with and without the directory, and the 38 half is a whole
  gate run three times with the mutation present, absent, and under the old needle.
* **Not claimed:** that the suite is green. It is not, and it will not be until 59 is
  dealt with on purpose.

The private clone is legitimate for the self-test phase and for nothing else, and the
reason is structural rather than convenient: **`fresh_copy` puts every copy in
`$TMPDIR`, with no fleet beside it and no `.git`**, so the suite's measurements cannot
see the fleet or the repository history either way. Every `--static-only` run in §2
and §5 was made from inside the fleet root, which is the only place the fleet is
visible — and §5's run is the one that can see `generated stack` at all.

---

## 8. Two things noticed, neither of them changed

* **`tests/self_test.sh`'s header says `105 labelled invocations, 103 distinct breakage
  numbers`; the tree now has 107 and 105.** Measured:

```
declared (every helper invocation):      108
  of which carry a 'breakage N:' label:  107
  of which are controls (no label):        1   <- expect_green 'unbroken tree'
distinct breakage numbers:               105   <- 78 and 79 are each proven twice
fresh_copy call sites (code):             64
```

  `validate.sh` counts its own label from the recipes (`_st_breakages=$(grep -cE …)`)
  and therefore prints the right number; the comment is the stale copy. Pre-existing
  drift, not introduced here, and the fix is a number in a comment no check reads.
  Left.

* **A red self_test stops before three of its recipes, and never says so.** The
  `failures -ne 0` early exit sits at `tests/self_test.sh:4806`; breakages **101, 102
  and 103** are at lines 4837, 4865 and 4910 — below it. So every run in §4 evaluated
  **105 of the 108** declared invocations, and the suite's own *every recipe was
  EVALUATED* guard (which compares `_shard_ran` with `declared`) is itself below that
  exit and unreachable on a red run. The run does report `FAIL` and names the count, so
  it is honest rather than silent — but **the number in §4 is a count over 105 recipes,
  not 108**, and a reader who wants the last three evaluated has to make the suite green
  first. Pre-existing and out of scope: moving the three above the early exit would
  change what a red run reports, which is a decision about the suite rather than about
  this packet.

---

## 9. Reproducing this, from a clean checkout

```sh
# 1. the entry list is the whole fix
grep -n 'lint reports \\' tests/self_test.sh

# 2. the copy, built the way fresh_copy builds one, with and without reports/
#    (entry list as above, plus chmod +x "$dst"/tests/*.sh, plus KIT_GITLEAKS)
bash tests/validate.sh --static-only        # in each; §2

# 3. the real tree, from INSIDE the fleet root — a worktree in /tmp reports green
#    because it finds no fleet, which is the false PASS this packet's manager hit
cd /Users/kaka/Code/any/moon/cafaye/wt-m39-kit-freshcopy-01
bash tests/validate.sh --static-only        # §5: one FAIL, generated stack

# 4. the suite
bash tests/self_test.sh                     # §4; ~29 min, give it a timeout
```

## 10. Commits

| commit | what |
| --- | --- |
| `c5e4282` | `reports` on `fresh_copy`'s list, with the comment; `CHANGELOG.md` under `### Fixed` |
| `8f97213` | breakage 38's needle, from a label that no longer exists to the one that does |
| `b27efd9` | this report |

Two commits rather than one, on purpose: they are independent, and either can be
reverted without the other. Reverting `8f97213` alone puts the suite back to 2
uncaught; reverting `c5e4282` alone puts it back to 5 **and** re-arms the silent half
in §3, where 88 recipes would again be filtered away from a copy that is red for a
reason of its own.