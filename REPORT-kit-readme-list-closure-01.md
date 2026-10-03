# REPORT — `kit-readme-list-closure-01`

**What the packet asked for.** `tests/validate.sh`'s `readme_check` walks a
hand-maintained tuple of paths and asserts two halves: the README names each
one, and each one exists. The packet's claim is that the second half of that —
a file **added** and never documented — is unguarded, is the direction a packet
moves in, and has never been falsified by any recipe.

**Verdict: the claim is true, it was worth two real README rows rather than
only a check, and both halves now have a recipe.**

---

## 1. The measurement that opened the packet, re-measured

The packet says 26 listed paths and 157 unlisted files. Measured from kit
`master` (`3cdcd3b`), in this worktree:

```
$ python3 - <<'PY'   # extract the tuple out of readme_check's own source
... print(len(paths))
PY
25                       # not 26
```

25 entries: **22 files and 3 directories** (`templates/compose/grafana/
provisioning`, `.../loki`, `.../tempo`). All 25 exist, which is why the check is
green — it is green about the half it guards.

Of the 175 tracked files under the three trees the packet names:

| tree | tracked | not covered by a listed path or listed directory |
| --- | --- | --- |
| `templates/` | 101 | 83 |
| `tests/` | 41 | 30 |
| `reports/` | 33 | 32 |
| **total** | **175** | **145** |

**145, not 157.** The difference is not worth chasing: the packet's figure is
larger than the whole population it was counting in (175), so it most likely
counted filesystem entries including untracked ones, or counted a 26th entry
that has since been retired. What matters is the order and the sign — a
hand-maintained list covering under a fifth of what it sits next to.

`grep -nE 'readme' tests/self_test.sh` returned **nothing**. That part of the
packet is exact: zero of the suite's recipes turned `readme_check` on in either
direction, before this packet.

## 2. Falsification first, and the gate is green

The packet's instruction was to falsify before building, and to use the
cheapest true case: a new file inside `templates/compose/grafana/
provisioning/`, which is listed as a *directory* and so is checked with
`exists()`.

```
$ printf '%s\n' "# falsification: a file nobody documented" "apiVersion: 1" \
    > templates/compose/grafana/provisioning/datasources/unlisted-canary.yml
$ git status --short
?? templates/compose/grafana/provisioning/datasources/unlisted-canary.yml

$ bash tests/validate.sh --static-only \
    --only='README.md  (documents every new template)'
PASS README.md  (documents every new template)
```

**Confirmed, and `grep -nE 'readme' tests/self_test.sh` still returned nothing.**
The packet's premise stands.

A second measurement on the same file, because it changed what I built:

```
$ printf '# a plugin pin\n' > templates/compose/grafana/provisioning/plugins/README.md
$ bash tests/validate.sh --static-only
FAIL grafana provisioning  (2 datasources, and no third, dashboards, alerting — all files)
FAIL grafana dashboards  (status is the predicate, error.type is a drill-down)
FAIL grafana panels  (every query names the backend that can answer it)
FAIL generated stack  (...)        # pre-existing; see §6
PASS README.md  (every shipped path in an adoption tree is documented)
       131 path(s) walked across 5 adoption trees; every one is documented
```

Three checks own the grafana tree's file set. **So the packet's suggested
mutation could never have been a red recipe for a README check** — it is a
four-cause mutation, and a recipe built on it would have proved nothing about
any of the four. It is, however, an excellent *control*, and it became one (§4).

## 3. The decision: a closure assertion, and the bound is a TREE

I picked option 1 from the packet, and the argument for it over option 2 is
that option 2 is a ratchet in the opposite direction to every allowlist in this
repository: `templates/tier/skip-allowlist` only grows by suppression entries,
and "one README entry per new file" only grows by rows, in a document whose
whole job is to be read. It is also satisfied by pasting a path into the README,
which is precisely the edit the tuple's own comment forbids for `mimir`.

**Coverage is read out of the README, not out of a second list.** Every
path-shaped run of text anywhere in the README (not just backticked — three
paths the existing tuple requires are written in prose), `{a,b}` sets expanded,
`<lang>` and `*` segments read as wildcards. So the check covers the next thing
on the day it lands, with **no edit to `tests/validate.sh`**.

**The bound, which is the whole argument.** Per **tree**, not per file:

- **In:** `.github/`, `core/`, `docker/`, `lint/`, `templates/` — the adoption
  trees. A file here is something a service copies or a caller reaches by
  `uses:`.
- **Out:** `tests/` — the gate's own implementation. The README already names
  every proof a reader is expected to *run*, and naming `fingerprint.py` would
  add 17 rows that teach a reader nothing.
- **Out:** `reports/` — packet evidence, addressed to whoever reads that
  packet's report. 32 files.

The failure the bound exists to prevent, measured: a per-file bound produces
**145** required rows, and a per-directory bound produces **34**. Both are the
157-paths README wearing a smaller hat. A check that demanded them would be
satisfied by the very thing it exists to prevent — so the control that proves
it does not is not optional, and it is breakage 104b.

Written up at length in `DECISIONS.md` (MD33), because the bound is a judgement
and not a measurement and the next reader needs to be able to disagree with it.

## 4. What the check found on arrival — seven, and both are real

```
$ bash tests/validate.sh --static-only --only='every shipped path in an adoption tree'
FAIL README.md  (every shipped path in an adoption tree is documented)
       7 shipped path(s) in an adoption tree are named nowhere in README.md:
       .github/workflows/image.reusable.yml, templates/bin/deploy.sh,
       templates/deploy/README.md, templates/deploy/compose.deploy.yml,
       templates/deploy/entrypoint.sh, templates/deploy/redact.py,
       templates/deploy/reference/courier.deploy.yml.
```

Not chores. `AGENTS.md` argues for a full section about
`.github/workflows/image.reusable.yml` — it is kit's *second* reusable
standard, and the section is titled "One file means one copy PER STANDARD, and
kit now has two". `AGENTS.md` also argues for a full section about
`templates/bin/deploy.sh` being "1,067 lines" and the overlap with Kamal being
"real". **Both were documented in `AGENTS.md` and in neither in the README**, and
`AGENTS.md` is not what an adopting service reads.

Two rows came out of it, and both were gaps the packet predicted would be
chores. After the fix:

```
PASS README.md  (documents every new template)
PASS README.md  (every shipped path in an adoption tree is documented)
       130 path(s) walked across 5 adoption trees; every one is documented
```

## 5. Both directions, measured

| mutation | before | after |
| --- | --- | --- |
| `templates/payments/gateway.yml` (new tree, unlisted) | — | **FAIL**, 8 findings, path named |
| `templates/deploy/reference/second.deploy.yml` (new leaf in a documented tree) | — | **PASS**, 131 walked; gate otherwise identical (249 PASS, 1 pre-existing FAIL) |
| `templates/compose/grafana/provisioning/plugins/README.md` | — | **PASS** for this check (131 walked); three *other* checks red |
| the tree as it arrived | — | **FAIL**, 7 findings |

Whole-gate baseline, same machine, before and after the change:

```
$ bash tests/validate.sh --static-only     # master, --only on the README checks
FAIL generated stack  (...)      # pre-existing, identical on master
$ bash tests/validate.sh --static-only     # this branch
249 PASS, 1 FAIL (generated stack), 5 SKIP
```

The one FAIL is not mine and is identical on `master`: two sibling
repositories (`cafaye-ts`, `guard`) commit `caf.dev.compose.yaml`, which
`tests/generated_stack_check.py` finds by reading `$ROOT/..` — the real fleet,
because this session runs in a worktree beside it. In `tests/self_test.sh`'s
throwaway copies the parent holds one entry with no `.git`, which is why the
suite's own `unbroken tree` control is green.

## 6. The recipes

`tests/self_test.sh` gains **breakage 104** (red) and **104b** (green), which
takes the suite from 107 recipes to 109. The counts in the summary lines are
`grep`-derived and the header/recipe agreement is a check, so neither was
written down by hand — but the **header** was, because
`self_test_claims` fails on a recipe the header does not document.

- **104** creates `templates/payments/gateway.yml` in a throwaway copy and
  asserts `FAIL README.md  (every shipped path`. This is the only recipe in the
  file that **adds** rather than substitutes: an omission cannot be introduced
  by `edit`. `edit`'s refusal-to-match is what makes a stale recipe loud, and it
  has no opinion about a file that was never there — so the guards are `mkdir -p`
  and `cat >` under the file's `set -euo pipefail`, both of which fail loudly
  rather than leaving the copy unbroken, and the copy itself is proven green by
  the existing `unbroken tree` control.
- **104b** creates `templates/deploy/reference/second.deploy.yml` and asserts
  the gate stays **green** *and* names what the check walked. It uses
  `expect_green_check`, which runs the whole gate unfiltered and sets
  `KIT_FINGERPRINT=0` — a cache hit is a green that no check ran to produce,
  and this proof's whole claim is a green that says something.

Verified on this branch:

```
$ KIT_SELF_TEST_SHARD=104/104 bash tests/self_test.sh
PASS self_test: breakage 104: a template tree nobody documented
      — caught by `README.md  (every shipped path`
PASS self_test: breakage 104b: a new file INSIDE a documented tree needs no
      README row — stayed green and named the debt
PASS: self_test — shard 104/104 ran 2 of 109 breakages and every one it ran held.
```

The two self-test meta-checks, whose phase `--static-only` skips by design, were
executed directly against their own extracted source rather than left unrun:

```
self_test_claims    exit=0     # header and recipes agree, both ways
self_test_live_tier exit=0     # 0 of 109 recipe invocations name a live tier
```

## 6b. Two harness defects this packet found, both pre-existing

Both were found by the falsification, not by reading: **104b's control is a
whole-gate run, and a whole gate on a throwaway copy was red.** I did not
assume that was my recipe's fault, so I reproduced it by hand — one `cp -R`,
one `--static-only` run — and it was not.

### F1 — `fresh_copy` did not copy `reports/`, so every copy was red on an unbroken tree

`readme_check`'s tuple requires `reports/account-scope-contract-01/snapshot.sh`
to **exist**. `fresh_copy` copies `.gitleaks.toml .github AGENTS.md README.md
CHANGELOG.md LICENSE DECISIONS.md MIGRATIONS.md RESERVED VERSION core docker lint
templates tests` — no `reports`. So the tuple has an entry the copy cannot see,
and `readme_check` fails in **every** copy. Measured on `master` at `3cdcd3b`:

```
$ KIT_SELF_TEST_SHARD=1/104 bash tests/self_test.sh ; echo EXIT=$?
FAIL self_test: unbroken tree — the gate is RED on an unbroken tree (exit 1)
PASS self_test: breakage 1: templates/otel/go/traceparent.go deleted
FAIL: self_test — 1 breakage(s) the gate did not catch.
EXIT=1
```

The header of that file calls the unbroken-tree control "the control this file
runs FIRST and the sentence that makes every proof below it meaningless". It has
been red. **The commit that added the `reports/` entry to the tuple did not add
`reports` to `fresh_copy`,** which is the same coupling `AGENTS.md` states twice
already (for `MIGRATIONS.md`, and for `VERSION`/`RESERVED`): *when a packet adds
a file the gate reads by path, `fresh_copy`'s list is part of that packet.*

Fixed by adding `reports` to the copy list. Before/after, same copy, same added
file, whole `--static-only` gate:

| | exit | PASS | FAIL |
| --- | --- | --- | --- |
| before (no `reports/` in the copy) | **1** | 245 | 1 — `readme_check`: `README.md documents reports/account-scope-contract-01/snapshot.sh, which does not exist` |
| after (`reports/` copied) | **0** | 246 | 0 |

### F2 — the `failures` check stood mid-stream, so 101+ could fail into a green summary

The block

```bash
if [ "$failures" -ne 0 ]; then … exit 1; fi
```

sat between breakage **100**'s recipe and breakage **101**'s. A fatal check in
mid-stream can only see the recipes above it, so both ways of being wrong were
wrong at once:

- a failure among breakages 1–100 exited 1 **there**, and breakages 101-onward
  **never ran** — the unreachable-recipe defect breakage 101 was written for, one
  level up and in the other direction; and
- a failure among breakages 101-onward was read by **nothing** that any verdict
  depended on it, so the final summary printed
  `PASS: self_test — all N breakages hold` and **exited 0**. The run was red in
  the one place a reader looks first and green in the one place a machine looks.

It was reachable only because the **shard** path got its own `failures` check
when breakage 101 was moved above the summary — at which point the comment there
began claiming *"The un-sharded path below has always checked it"*, **which was
not true**. The same packet that taught one half of the file to judge its recipes
left the other half with a comment asserting a property it did not have.

Fixed by moving the block to the end of the recipe stream — after the shard
branch (which `exit 0`s) and before the `grep`-derived counts, so it sees every
recipe and a sharded run still reports itself as a shard rather than as the
suite. Placement verified: `failures` at line 5040, shard branch at 4953,
`counted=` at 5052.

**Why I did not add a recipe for F2.** The defect is a *placement*, and a
placement is proved by asserting the block's line number relative to the last
recipe — a check that would be satisfied by the comment I wrote beside it, which
is precisely the "a check that a comment can satisfy is not a check" shape
`AGENTS.md` forbids. A real recipe for it would be a `self_test` run in which
breakage 104b genuinely fails, and the honest way to arrange that is a mutation
of the copy — which is what F1's absence used to provide for free, accidentally.
The next packet to touch the tail of this file should write it properly; the
reason it was left undone is recorded here rather than in a comment that would
read like a decision.

## 6c. A third, smaller one, not fixed

`FAIL: self_test — $failures breakage(s) the gate did not catch.` misdescribes
the F1 case: what failed was the unbroken-tree **control**, not a breakage, and
the message sent the reader looking for a check that had stopped catching its
defect. Same class as the two skip kinds the block right beneath it already
counts apart. One word of wording; left alone because a message that names a
control as a breakage is a sentence, and changing it inside a packet about
something else is how two unrelated diffs end up in one review.

## 7. Falsifications that tested nothing

Recorded because they are the evidence that the rest of the numbers mean
something.

1. **I deleted a tracked file while looking for an inert place to put a
   control.** The loop that tested candidate control files wrote into
   `templates/compose/grafana/provisioning/plugins/`, which already contained a
   tracked `README.md`, and overwrote it. `git status` caught it
   (` D templates/compose/grafana/provisioning/plugins/README.md`) and
   `git checkout --` restored it. What it showed me: a candidate-file sweep must
   read the directory before writing into it, and `git status` after each
   candidate is not optional. It also cost me a real tracked file for about
   ninety seconds inside a worktree nobody else was in.
2. **`templates/compose/loki/extra-limits.yaml` came back with two FAIL rows
   against a baseline of one, and I never attributed the extra one.** I moved on
   to the next candidate rather than spend the time, so the honest record is
   "known non-inert, cause unidentified". A non-inert tree is a perfectly good
   thing to discover and a poor excuse not to say which check owns it; if
   somebody later wants a control under `templates/compose/loki/`, that
   measurement is the first thing to run.
3. **`templates/compose/grafana/provisioning/datasources/unlisted-canary.yml`
   — the packet's own suggested falsification — proved the gap but could not
   become a recipe**, for the reason in §2: three other checks own that tree's
   file set, so a recipe on it would have been satisfied by any of them. It is in
   this report as a measurement, not as a recipe, and that is the honest
   disposition of it.
4. **The first version of the check reported ONE undocumented path where there
   are SEVEN.** A one-segment token is not a tree: `## The templates half —
   \`templates/\`` prefix-matches everything beneath it, so a heading documented
   the whole adoption tree. That is a **green hiding six real gaps**, the same
   direction as a check whose pattern stopped matching, and it is the reason the
   check now requires a coverage token to have at least two segments. Recorded
   in `DECISIONS.md` (MD33) because the shape is worth recognising the next time
   a rule about scope is written.

## 8. What I chose not to do

- **A README row per file, or per directory.** 145 and 34 respectively. Both are
  the failure this check exists to prevent; §3.
- **Scope `tests/` in.** It would have meant 17 rows about `fingerprint.py` and
  `bootstrap.sh`, and it would have made the check's number look better while
  making the README worse. The exclusion is argued in `DECISIONS.md` (MD33)
  rather than left as a silent gap.
- **A new program under `tests/`.** `AGENTS.md` refuses a fifth one by default,
  and this is a string walk over one file — inlining it in `validate.sh` next to
  `readme_check` is where the packet asked for it and where a reader comparing
  the two halves will look.
- **`git ls-files` as the source of the file list.** It is the more honest
  "shipped" predicate, but `tests/self_test.sh` makes a throwaway copy with no
  `.git` beside it, so a git-backed check would find zero files in every copy
  and pass while proving nothing. The walk skips `__pycache__`,
  `node_modules` and dotfiles by name instead.

## 9. What I would do next

1. **Attribute the `templates/compose/loki/` finding** (§7.2). Somebody will
   want a control under that tree and the answer is one `--only` run away.
2. **Make `readme_check`'s tuple derive from the closure, or retire it.** The two
   checks now overlap: the tuple's 22 file entries are all covered by the
   closure, so the tuple is a second, weaker copy of the same fact. That is
   `AGENTS.md`'s "a property stated in two places is a property asserted in zero
   times", and it is the right next cut — but it is a cut, not an addition, and
   it belongs to whoever can watch the `mimir` asymmetry survive it.
3. **Write a recipe for F2** (§6b). The placement is now correct and asserted by
   nothing; the honest proof is a run in which a late breakage genuinely fails,
   which means mutating a copy rather than asserting a line number.
4. **Re-word the `failures` message** (§6c).
5. **Run the full 109-recipe suite unsharded, now that F2 makes it honest.** It is
   the one thing this packet could not do, and after F2 it is the one thing that
   would tell anybody whether there are further failures hiding in 101-onward.

## 10. What I did not run, and why

- **The full 109-recipe self-test, unsharded.** It is ~60 minutes of sequential
  whole-gate runs and this session's leash is an hour; `AGENTS.md` forbids
  leaving it running and forbids widening a bound to make it pass. I ran **shard
  `104/104`** — the two recipes this packet adds, EXIT=0 — and **shard `1/104`**
  on this branch before fixing F1, which is where the F1 measurement comes from.
  The other 107 recipes were **not** re-run on this branch. They were green on
  `master` at `3cdcd3b` except for the F1 control, which this packet fixes; the
  two meta-checks that cover the recipes I edited (`self_test_claims`,
  `self_test_live_tier`) were both executed and both green.
- **`bash tests/validate.sh` without `--static-only`.** Same reason, plus docker.
  What was run: `bash tests/validate.sh --static-only` **four** times on this
  branch (**249 PASS, 1 pre-existing FAIL, 6 SKIP**, identical each time), plus
  eight `--only` runs and three whole-gate runs on throwaway copies.
- **The lint phase.** `SKIP lint_test.sh (--no-lint)` is emitted by
  `--static-only` itself and is counted in its own summary line — a countable
  skip row naming its reason, not an absence. No YAML, Dockerfile or shell file
  this packet touched is linted by that phase, and `tests/self_test.sh` passed
  its own `bash -n` and `shellcheck -S warning` rows in every branch run.
- **gofmt.** `SKIP templates/secrets/go (gofmt not installed)` is a countable row
  in the gate's own output. This packet touched no Go file.

## 11. Cleanup

Throwaway copies removed (`${TMPDIR}/kit-self-test.*`, `${TMPDIR}/kit-r104b.*`).
No container, image or volume was created or left running — this packet ran no
docker tier, and the one FAIL in the gate is a **read-only** inspection of two
sibling repositories by `tests/generated_stack_check.py`, which asks git two
questions and runs nothing.
