# REPORT — kit-report-only-unreachable-01

**Branch** `worker/kit-report-only-unreachable-01`, off `master` at `f367137`.
**Worktree** `wt-m39-kit-report-only-01`. **Not pushed, not merged** — push is
not mine.

**Short version.** The packet's *symptom* was real and is fixed. Its *mechanism*
was stale: `--only` was already reverted in `0399c23`, and breakage 59 was
failing for a different reason — an unrelated check reporting `FAIL` because the
fleet it was pointed at had no `core` beside it. One `return` in
`tests/account_scope_fleet_check.py` was reporting a machine condition in the
gate's FAIL vocabulary. Breakage 59 is green, and it is green for the right
reason: the falsification direction (the same stale copy in an **adopting**
service) is still red.

---

## 1. Before: what master actually does

`bash tests/self_test.sh` un-sharded does not finish here (§7), so the before was
taken with the suite's own shard key, `KIT_SELF_TEST_SHARD=59/104`, which runs
breakage 59 and nothing else. Same recipe, same fixture, same mutation.

```
$ KIT_SELF_TEST_SHARD=59/104 bash tests/self_test.sh
-- self_test: a gate that cannot fail is not a gate
FAIL self_test: breakage 59: an UNADOPTED service copies the stack — green, and
  named — the gate went RED (exit 1), so the ceiling is not in force
       … 25 indented lines the recipe prints, elided here …
       FAIL in-scope repositories  (every one declares its account-scoped surface)
             COULD NOT RUN: no account-scope checker at
               <fixture>/core/harness/account_scope_check.py. The instrument this
               gate exists to run is not on disk, so nothing below verified
               anything and this exit is 2, not 0.
       FAIL: 1 check(s) failed.
FAIL: self_test — shard 59/104 ran 1 of 109 breakages and 1 of them did NOT hold.
EXIT=1
```

The 25 elided lines are the gate's own findings, all `PASS` — printed because the
recipe prints the last 20 lines matching `^(FAIL|  -|       )`. The one `FAIL`
among them is the whole story.

**The packet's quoted failure does not occur on master.** It is the state
`0399c23` (`fix(kit): revert --only on expect_green_check — it broke breakage
59`) left behind; `HANDOFF-kit-gate-speed.md` records the revert and, in §"The
next worker's first move", says *"Do not make `--only` reach `report`-based
verdicts … Measured and declined twice now."* `expect_green_check` at `f367137`
is deliberately unfiltered (`tests/self_test.sh:1556`, "DELIBERATELY NOT
FILTERED").

So the packet's premise is wrong in its third half and right in its first two.
Per the brief I am saying so rather than building on it. **The class it named is
still real and I measured it (§5) — it is just not what is breaking 59.**

---

## 2. Mechanism, confirmed in four parts

**(a) The verdict 59 wants is emitted by a `report`, not a `check`** — true, and
still true. `tests/validate.sh:6091`:

```sh
report PASS "fleet  (adopting repositories clean; $fleet_debt — adoption debt, …)"
```

`report()` (`tests/validate.sh:410`) has no `--only` filter: it prints and counts
every verdict unconditionally. The filtering emitters are `check`,
`check_par`, `report_par` and `bounded_check`.

**(b) `--only` matching nothing is a FAIL, and that rule is right** — true.
`tests/validate.sh:13116`, and the run in §5 reproduces it verbatim.

**(c) The converse, which the brief asked for: the filter works on a label a
`check` emits.** Measured:

```
$ KIT_FLEET=<scratch fleet> bash tests/validate.sh --static-only \
      '--only=in-scope repositories'
PASS in-scope repositories  (every one declares its account-scoped surface)
```

Selected exactly one check and ran it. (a)–(c) all hold; they just no longer
describe breakage 59's failure.

**(d) The half that actually fires.** `tests/validate.sh:6624` runs the
account-scope runner whenever `KIT_FLEET` is set, **with no probe**:

```sh
if [ -n "${KIT_FLEET:-}" ]; then
  check 'in-scope repositories  (every one declares its account-scoped surface)' \
    "$PY" "$ROOT/tests/account_scope_fleet_check.py" --repos-dir "$KIT_FLEET"
```

Breakage 59 points `KIT_FLEET` at a fixture fleet. A fixture fleet is a
directory of service repositories and nothing else
(`tests/self_test.sh:2091 fixture_fleet`) — no `core`. So the runner's
instrument branch fires, returns **2**, and `check` maps 2 to **FAIL**.

Three lines below, the runner's sibling branch for a missing fleet *directory*
returns **`EXIT_CONFIG` (78)**, which `check` maps to **SKIP**:

```sh
if not os.path.isdir(repos_dir):
    print(f"COULD NOT RUN: no fleet at {repos_dir}. Set --repos-dir, or KIT_FLEET.")
    return EXIT_CONFIG
```

Two adjacent conditions, both statements about the machine and neither about
kit's tree, reported in two different vocabularies. `EXIT_CONFIG`'s own
docstring (`tests/account_scope_fleet_check.py:145`) says the FAIL is the
mistake it exists to prevent:

> `kit`'s SKIP_EXIT (sysexits.h EX_CONFIG), so a missing fleet is a SKIP in
> `tests/validate.sh` rather than a FAIL that blames the tree for the machine.

And `tests/validate.sh`'s own `account_scope_fleet_root` (line 6596) *agrees*,
and is never consulted on this path — it probes for the **instrument** precisely
so that pointing at something which is not a fleet does not report "no
repository checked":

> Testing for the INSTRUMENT rather than for the directory is the same instinct as
> the `gate.yml` probe above: pointing at something that is not a fleet reports
> "no repository checked" — technically true and useless.

---

## 3. What I changed

**`316cdab` — a missing instrument is a SKIP, not a FAIL.**
`tests/account_scope_fleet_check.py`: the instrument-absent branch returns
`EXIT_CONFIG` instead of `EXIT_COULD_NOT_RUN`.

**`14f7179` — the "no fleet at `<dir>`" sentence was dead code.** The instrument
test ran *before* the fleet-existence test, so a `--repos-dir` that is not a
directory failed `isfile` on anything joined to it, returned, and never reached
the branch that names the variable to set. Swapping the two makes both reachable.

Nothing else moved. Four of the seven `EXIT_COULD_NOT_RUN` branches left are about kit's **own**
vendored table disagreeing with itself, which *is* a tree defect, and they still
FAIL — correctly.

---

## 4. Before / after, measured

Every command below was bounded by `timeout`. Full logs:
`logs/measurement-*` naming is in §9.

### 4a. The runner, same scratch fleet, before and after

```
$ .venv/bin/python tests/account_scope_fleet_check.py --repos-dir <fleet with no core>
before   … this exit is 2, not 0.      EXIT=2
after    … this exit is 78, not 0.     EXIT=78
```

Both non-zero: a direct invocation still does not report success.

### 4b. The gate, same scratch fleet, before and after

```
$ KIT_FLEET=<fleet> bash tests/validate.sh --static-only '--only=in-scope repositories'
before   FAIL in-scope repositories  (every one declares its account-scoped surface)
         FAIL: 1 check(s) failed.                                       exit 1
after    SKIP in-scope repositories  (every one declares its account-scoped surface)
         PASS: every check passed.                                     exit 0
```

Both trees were the same worktree; "before" was taken with the change stashed
(`git stash`) on the spot, so the two runs are minutes apart on the same machine.

### 4c. The real fleet is unchanged — the fix does not weaken anything

```
$ .venv/bin/python tests/account_scope_fleet_check.py --repos-dir …/cafaye
TALLY: 9 in-scope repositories checked — 9 match their recorded state exactly, 0 do not.
PASS account-scope-fleet: every in-scope repository reports exactly what
  account_scope_fleet_ratchet.yml records, in both directions.          exit 0
```

When the instrument *is* present neither branch fires, so the reorder cannot move
a verdict; the order swap is also inside the region where both branches return
the same code. Measured anyway, because "cannot" is a claim.

### 4d. The dead branch, before and after

```
$ … --repos-dir $TMP/definitely-not-here
before   COULD NOT RUN: no account-scope checker at
           $TMP/definitely-not-here/core/harness/account_scope_check.py. …   exit 78
after    COULD NOT RUN: no fleet at $TMP/definitely-not-here.
           Set --repos-dir, or KIT_FLEET.                                   exit 78

$ … --repos-dir <a real directory with no core>
after    COULD NOT RUN: no account-scope checker at <dir>/core/harness/…    exit 78
```

`grep -n 'no fleet at' tests/account_scope_fleet_check.py` matched exactly one
line on the tree the second commit starts from — a sentence nothing could print.

---

## 5. The class: how many recipes share the structural cause

Derived, not written down. Both numbers come from two real gate runs on this
worktree:

| run | command | verdicts printed |
|---|---|---|
| unfiltered | `bash tests/validate.sh --static-only` (2m08s) | **256** |
| no-match filter | `bash tests/validate.sh --static-only --only=ZZZ_NO_SUCH_LABEL_XYZ` (10.4s) | **46** |

Of the unfiltered run's own 256 labels, **43** are printed by the no-match
filter too, and those are by construction the ones **no `--only` needle can
select**: 256 − 43 = **213 selectable**. (The no-match run prints 46, not 43:
three of its rows — `shellcheck (not installed)`,
`templates/secrets/go  (gofmt not installed …)` and
`tests/staleness_test.sh  (excluded by --only)` — are rows the unfiltered run
does not produce, because they describe the filter rather than the tree.)

`tests/self_test.sh` has 98 recipes whose needle is a literal string (a further
10 pass a `$variable`, which this corpus cannot resolve and which I therefore
did not measure). Against the 213 selectable labels:

| recipes | needle names | measured |
|---|---|---|
| **5** | a verdict emitted only by bare `report` — 3, 11, 75, 80, 81 | **dead filter** |
| 1 | a SKIP's *verdict text*, not a label — 23b | different cause, already documented at `tests/self_test.sh:1796` |
| 2 | a label in the telemetry phase, which `--static-only` disables — 23, 40 | **not measurable from this corpus** |

So: **5 recipes of 98 confirmed, 1 of a known second cause, 2 unmeasured.**
I am not claiming 8; the corpus cannot see the telemetry phase and a confident
8 would be wrong.

Breakage 80's needle, run by hand — this is the whole shape in two lines:

```
$ bash tests/validate.sh --static-only '--only=templates/kamal/  (4 artifacts present'
PASS templates/kamal/  (4 artifacts present, the set is whole)
FAIL: --only='templates/kamal/  (4 artifacts present' selected NO check out of the suite.
       101 check(s) were excluded. …
```

The verdict was emitted *despite* the filter excluding everything, and the gate
said "selected NO check out of the suite" in the same breath. `expect_red_check`
asks only whether `FAIL <label>` appears, so **these five recipes are not false
greens** — the check under test really ran and really went red — but they are
not isolated, and the gate's loudest warning is sitting unexamined in their
child's output. Fixing that would mean giving `report()` the filter, which
`HANDOFF-kit-gate-speed.md` records as measured and declined twice; I did not
re-open it, and I agree with the handoff's reasoning rather than the packet's
"Option A is principled" framing.

### 5a. A second, adjacent accounting defect, found on the way

Same two runs. `ONLY_SKIPPED` is the number the gate prints as "check(s) were
excluded":

```
       101 check(s) were excluded. The filter is a typo, or the
```

256 labels in the unfiltered run, 46 of which survive any filter ⇒ **210 were
excluded, and 109 of them were excluded without being counted.** The count is
of *filter decisions reached*, presented as *exclusions*: tiers guarded by a
bare `if [ -z "$ONLY_MATCH" ]` (e.g. `tests/validate.sh:1936, 2216`) return
before any label exists, so nothing increments. A reader who takes "101
excluded" as the size of the skipped set is off by more than half. Not fixed
here — the honest fix needs each tier to know how many verdicts it holds, which
is a different packet.

---

## 6. The round trip: breakage 59 green **and** red for the right reason

A green 59 proves nothing until it has been seen red. Both halves, on the same
branch, bounded by `timeout 900`:

```
$ KIT_SELF_TEST_SHARD=59/104 bash tests/self_test.sh
PASS self_test: breakage 59: an UNADOPTED service copies the stack — green, and
  named — stayed green and named the debt
PASS: self_test — shard 59/104 ran 1 of 109 breakages and every one it ran held.   exit 0

$ KIT_SELF_TEST_SHARD=60/104 bash tests/self_test.sh
PASS self_test: breakage 60: the same copy in an ADOPTING service is a hard FAIL —
  caught by `fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)`
PASS: self_test — shard 60/104 ran 1 of 109 breakages and every one it ran held.   exit 0
```

**59 and 60 are the same mutation in opposite fixtures.** 59: `alpha` has no
`kit.ref` → the ceiling stays GREEN and names the debt. 60: `alpha` has written
`kit.ref` → the identical stale copy is a hard FAIL, caught by the named check.
If 59 were passing because it stopped running anything, 60 could not be red. It
is red.

**Repeated.** Two further `59/104` runs, after the first:

```
$ KIT_SELF_TEST_SHARD=59/104 bash tests/self_test.sh
REPEAT 1: PASS … stayed green and named the debt
          PASS: self_test — shard 59/104 ran 1 of 109 breakages and every one it ran held.
REPEAT 2: PASS … stayed green and named the debt
          PASS: self_test — shard 59/104 ran 1 of 109 breakages and every one it ran held.
```

Three green runs of breakage 59 on this branch, zero red. What `--only` cannot
do to this recipe, the shard key does not either: it selects a *recipe*, and
59's child gate still runs the whole `--static-only` suite un-filtered with
`KIT_FINGERPRINT=0` — so this is not a narrowed proof smuggled past the filter.
Each run cost ~4 min on a quiet box and ~13 min under load 15–24 with three
workers on it, which is the honest reason no unsharded suite finished.

---

## 7. What I did NOT run, named and counted

- **No single un-sharded `bash tests/self_test.sh` completed.** Started at
  04:02 on unmodified `master`, it reached **breakage 31 — 35 recipes evaluated,
  0 `FAIL self_test`, 0 `SKIP self_test`** — in 75 minutes under a box carrying
  two other workers' load (load average 6.5–11). Projected ~3 h. I stopped it at
  Q4 and **disclose a contamination**: `fresh_copy` copies `$ROOT` per recipe, so
  recipes after breakage 31 copied a working tree I had since edited. Only the
  breakage-1…31 span is clean evidence, and that span is on `master`.
- **So: 35 of 109 recipes verified un-sharded. The other 74 were not.** Coverage
  was taken with `KIT_SELF_TEST_SHARD=i/104`, which runs one recipe each. That is
  *sharded* coverage, and a shard summary is not the sentence the un-sharded run
  prints.
- **Not measured:** whether any of the 5 dead-filter recipes (3, 11, 75, 80, 81)
  would pass on an **unmutated** fixture. Each is ~4 min; that is the check that
  would upgrade "not a false green, but not isolated" to a proof, and it is the
  first thing the next packet should run.
- **Not measured:** breakages 23 and 40's needles against a **telemetry**-enabled
  corpus, which `--static-only` cannot provide.
- **`generated stack` is RED on this machine and I did not touch it.** A full
  `--static-only` gate run here reports `FAIL generated stack …; 2 in frozen
  repositories, reported not counted` — two live repositories under
  `…/cafaye` have `caf.dev.compose.yaml` committed. `pantry` and `courier` have
  workers in them right now. Reported, not fixed; it is another packet's area
  (`REPORT-fleet-generated-compose-01.md` exists).

---

## 8. Out of packet, named and specific

1. **`tests/validate.sh:1936` and `:2216`** guard whole tiers with
   `if [ -z "$ONLY_MATCH" ] && have shellcheck` / `have gofmt` and return without
   counting. That is the 109-uncounted-exclusions finding in §5a.
2. **`check_verbose` (`tests/validate.sh:521`) has no `--only` filter at all** —
   not the verdict filter the other four have, and not the pre-spawn skip either.
   Its single caller is `tests/validate.sh:11712`, inside a loop. Under any
   filter it runs its command and prints its verdict. It is the one emitter that
   is wrong in **both** directions, which is why threading a filter into
   `report()` cannot be done as a one-line change the way the packet's Option A
   suggests.
3. **3 of the 7 remaining `EXIT_COULD_NOT_RUN` branches** — lines **821**
   ("named no repository as in scope"), **828** ("`--only=` names no
   repository") and **853** ("there is no checkout at `<repo>`") — are fleet-side conditions — "named no repository as in
   scope", "`--only=` names no repository", "there is no checkout at `<repo>`" —
   reported in the FAIL vocabulary for the same reason this one was. I left them:
   each is arguable, and changing them blind is how a machine problem becomes a
   hidden one. 853 in particular reads like the branch this packet fixed did.
4. **`_shard_claimed_total` (`tests/self_test.sh:799`) is assigned and never
   read.** Dead variable, in the file whose whole subject is counts that can lie.

## 9. Log index

Committed under `logs/` in this worktree, copied from `$TMPDIR` — every one is a
real capture, none reconstructed by hand.

| file | what |
|---|---|
| `measurement-unmodified-shard59.log` | **before**: `59/104` on `master` content — breakage 59 RED, `exit 1` |
| `measurement-unmodified-shard59-verbose.log` | the same run with the recipe's `tail -20` raised to 400 in a throwaway copy, so the real `FAIL in-scope repositories` is visible instead of scrolled off |
| `measurement-fixed-shard59-and-60.log` | **after**: `59/104` PASS, and `60/104` PASS (the falsification) |
| `measurement-fixed-shard59-repeat.log` | two further `59/104` runs, minutes apart |
| `measurement-gate-before-after-in-scope.txt` | §4b — gate `exit 1` -> `exit 0`, same worktree, same scratch fleet |
| `measurement-unfiltered-corpus-256-labels.txt` | the `--static-only` run's verdict rows — the 256-label corpus |
| `measurement-nomatch-filter-corpus-46-labels.txt` | the `--only=ZZZ_NO_SUCH_LABEL_XYZ` run's rows — the 46 that survive any filter |
| `measurement-unfilterable-corpus.txt` | the analysis of both corpora against all 98 literal needles, with the recipe list |

### 9a. A collision with another session, disclosed

Taking the §4b "before" a second time, with the tree already committed, I ran
`git stash -q` — which had **nothing to stash** (my two commits were already in)
and therefore created no entry — and then `git stash pop -q`, which popped
**another session's** `stash@{0}` (recorded from `master` at `4a037f3`) into my
worktree. It conflicted; `git` kept the entry and left `UU tests/self_test.sh`
and `UU tests/validate.sh` in my index.

Consequences, checked rather than assumed:

- **My worktree**: repaired with `git reset --hard HEAD` in *my* worktree only.
  Both commits intact, the fix present, nothing of mine lost.
- **Their stash**: still in `git stash list`, untouched —
  `git stash show --stat stash@{0}` still reads
  `tests/self_test.sh | 197 +++---` / `tests/validate.sh | 146 +---`,
  `21 insertions(+), 322 deletions(-)`, none of it mine.
- **Their worktree** (`/Users/kaka/Code/any/moon/cafaye/kit`): `git status
  --short` empty, HEAD still `f367137`, and no conflict markers in any tracked
  file in the repository.

Nothing of theirs was lost, modified, or pushed. Recorded here because it
happened, not because it left a mess.

## 10. The trade, recorded

**Rejected: make `--only` reach `report`-emitted verdicts** (the packet's Option
A). It would make those five recipes isolate their check, at the cost of threading
a filter into 96 `report` call sites in a 12,900-line gate and changing which
lines print under a filter — measured and declined twice already, in
`HANDOFF-kit-gate-speed.md`. The measurement in §5 says the class is **five
recipes**, not "101+": the blast radius does not justify the change, and I would
rather hand the next packet a number than a refactor.

**Rejected: weaken the `--only` no-match rule** (the brief's implicit third
option). It is the entire safety net under the filter, and the failure this
packet chased was *caused* by it doing its job.

**Taken: fix the vocabulary, at the chokepoint that owns it.** The runner already
declared `EXIT_CONFIG` for exactly this and used it three lines away; the
instrument branch was the odd one out. That is a one-word change with a measured
before and after, and it makes the false accusation stop.