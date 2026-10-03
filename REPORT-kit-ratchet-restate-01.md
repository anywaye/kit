# REPORT — kit-ratchet-restate-01

**Branch:** `worker/kit-ratchet-restate-01` · **Base:** `9cddeee` · **Commits:** `d4fa6b2`,
`a4211fe`, this report · **Never pushed.**

The packet's subject is two rows of `tests/account_scope_fleet_ratchet.yml`. Core's D46
moved both, so the record was red on arrival, and **`pantry` had got better** — which is
the half of the property nobody tests.

## 1. The measurement, and where every number came from

No number in the record came from the brief, from the row that was there, or from a
report. All of them came out of this, run in this worktree:

```
$ .venv/bin/python tests/account_scope_fleet_check.py --baseline
RECORD: …/tests/account_scope_fleet_ratchet.yml (9 row(s): 0 missing) — NOT APPLIED (--baseline)

repo       exit  scoped not-scp stale undcl fails warns blind  state
identity      0      17      25     0     0     0     3     0  OK
courier       0       9      10     0     0     0     3     0  OK
guard         0       1       6     0     0     0     6     0  OK
site          0       0       6     0     0     0     1     0  OK
parlor        0       0       6     0     0     0     1     0  OK
pantry        0       0       6     0     0     0     9     1  OK
caf           1       0       0     0     0     1     0     0  FAIL
kit           1       0       0     0     0     1     0     0  FAIL
core          1       0       0     0     0     1     0     0  FAIL
EXIT=1
```

**The three `FAIL` rows there are the record not being applied**, which is what
`--baseline` means; `caf`, `kit` and `core` are the `exempt:` rows and their
`declaration-missing` is forgiven by rule 4.

A bare `python3` crashes here with `ModuleNotFoundError: No module named 'yaml'` and
exits 1, exactly as the brief warned. **A crash is not a pass** — every number above
came from `.venv/bin/python`, and the exit 1 in that block is the checker's verdict on
three exempt repositories, not an interpreter failure.

The per-warning ids were re-derived from core's own JSON rather than read off the
summary table, because the table prints `core`'s warning count and the runner adds one
finding of its own on top:

```
$ python -c "…core/harness/account_scope_check.py --json <repo>…"
pantry    exit 0  counts {account-scoped: 0, failures: 0, not-account-scoped: 6,
                          stale: 0, undeclared: 0, warnings: 9}
          warn account-scope.contradiction-unreadable        6
          warn account-scope.nothing-scoped                  1
          warn account-scope.registration-path-unreadable    1
          warn account-scope.surface-unreadable              1
identity  exit 0  counts {account-scoped: 17, failures: 0, not-account-scoped: 25,
                          stale: 0, undeclared: 0, warnings: 3}
          warn account-scope.contradiction-unreadable        1
          warn account-scope.surface-unreadable              2
```

`6 + 1 + 1 + 1 = 9` and `1 + 2 = 3`, so the recorded `counts.warnings` is `core`'s
number and the recorded `warnings:` map is the run's, `core`'s plus
`fleet.blind.unreadable-rows`. Both directions have to agree or the row is red.

## 2. `pantry`'s `condition:` did not merely arrive — it was wrong about core

The brief says the condition has been discharged. It has, in the sense that the red it
was waiting on is gone. **The end it named is not going to arrive**, and that is a
measurable fact rather than an opinion:

| | said | measured |
| --- | --- | --- |
| the end | "core's chi recogniser reads a leading concatenation term" | `core/harness/account_scope_check.py:488` still requires `\(` followed by `"` |
| who wrote it down | `pantry/DECISIONS.md` D34 §3, attributed to **core** | D34 is **pantry's** decision, and it is still `— OPEN` |
| what core did | — | D46 lists "match on the literal tail" as its **first rejected alternative**, and its `Recommendation` says resolving identifier values "does **not** close `pantry`'s, because `options.BaseURL` has no value in any tree" |

So core declined pantry's recommended option rather than deferring it, and the old
condition named a fix core has now written down as one it will not do. Its one factual
claim was also wrong in a way that mattered: it cited **core's** `DECISIONS.md` D34,
which is about pending event types in `fleet.yml`, not about a route recogniser.

**So `pantry` still tolerates something, and the row keeps a `condition:` because the
loader refuses one without.** `fleet.blind.surface-blind` is still a **failure**:
`account_scope.yml` sets `surface.minimum: 0` while naming `internal/api/api.gen.go`,
which exists, so the declaration asserts in writing that the checker sees none of its
surface.

**The nine recorded warnings are not a tolerance.** `load_record` demands a `condition:`
when `(failures or blind)` is non-empty and for nothing else. A warning a row is obliged
to write down is the record doing its job. The row says this explicitly, because the
brief's question — is `surface-unreadable` a warning or a tolerance — is exactly the
question that sentence answers, and a reader who guessed wrong would either delete a
failure's justification or add a `condition:` to a row that needs none.

The new end is a fact a reader can watch rather than a packet that may or may not land:

> **THIS ROW ENDS when `account-scope.surface-unreadable` reports a NON-ZERO READ count
> for `internal/api/api.gen.go`.** Today it says "0 of the 6 registration(s) in
> `surface.sources` were read", and that zero is the whole of `surface.minimum: 0`.

There are two ways to it and both are outside this repository: `oapi-codegen` emits the
paths as literals, or `pantry` mounts them from a hand-written file and names that file
in `surface.sources`. Editing `api.gen.go` is **not** one of them — it is generated and
comes back on every `go generate`.

## 3. `identity`'s note now says what the surface IS

The old note named `social-login-callback` and pointed at a fix as the explanation. The
route is still not verified and the explanation is now different, so the note was
rewritten rather than re-pointed. Measured, from the two findings verbatim:

- `internal/httpapi/oauth.go` lines **161, 162** — `socialLoginPrefix+"/{provider}"` and
  `socialLoginPrefix+"/{provider}/callback"`. `socialLoginPrefix` is a `const`,
  `"/v1/auth/oauth"` at `oauth.go:90`.
- `internal/httpapi/oidc.go` lines **142, 143** — `oidc.PathLogin+"/{"+oidcRequestParam+"}"`,
  `Get` and `Post`.
- Both say **41 of the 45** registrations in `surface.sources` were read. That is the
  coverage number the row could not state before, and it is why `undeclared: 0` on this
  repository is decidable at all.

`social-login-callback` stays `contradiction-unreadable`, and **that is not core being
inconsistent** — it is the half of D46 that is not a fix. A path the checker cannot
**evaluate** cannot be **matched** to a declared row either, so `oauth.go:162` is now
named as a mount and the row is still unverified. The same honest answer, one step
further from silent.

`identity` carries no `condition:`: nothing about it is a failure and nothing about it is
tolerated. Two of its three warnings are new, one of them twice over.

## 4. The other seven rows are byte-identical

`git diff --stat` is `tests/account_scope_fleet_ratchet.yml | 104 +++---`, `1 file
changed`. The hunk covers `identity`'s row and `pantry`'s row, the section comment above
`pantry` (it no longer says "red on purpose" — the checker exits 0, and the one failure
left is this runner's own), and the header's measurement line. `courier`, `guard`,
`site`, `parlor`, `caf`, `kit` and `core` are untouched, and the runner agrees:
**`TALLY: 9 in-scope repositories checked — 9 match their recorded state exactly, 0 do
not.`**

The header now carries **two** dates rather than one, because seven rows were measured
on 2026-10-03 and two on 2026-10-04, and a record that says otherwise is a record whose
date is a claim nobody measured.

## 5. Falsification, run here, both undone

Two mutations, **one thing each**, in the direction that is easy to leave untested. Both
were reverted with `git checkout --` and the tree hash is identical before and after
(`aa0547dd84468fa7135bd57f2e756fbbec429540`).

**F1 — the row must SHRINK.** Deleted the single line
`account-scope.surface-unreadable: 1` from `pantry`'s `warnings:`, i.e. acted as though
core's improvement never happened. This is the direction a suppression list cannot see:

```
pantry: FAIL
    WARN account-scope.surface-unreadable
        internal/api/api.gen.go mounts 6 registration(s) — Get — whose path this
        checker cannot evaluate … 0 of the 6 registration(s) in surface.sources were read
    FAIL fleet.blind.surface-blind
        the declaration sets `surface.minimum: 0` while naming 1 source file(s) that exist
    records account-scope.surface-unreadable (warn) x0 and the run found it x1
TALLY: 9 in-scope repositories checked — 8 match their recorded state exactly, 1 do not.
FAIL account-scope-fleet: pantry FAIL
EXIT=1
```

**F2 — a repository with NO ROW is red.** Removed `pantry`'s whole row, which is the
move the brief explicitly forbids and the reason the row is rewritten rather than
deleted:

```
RECORD: …/tests/account_scope_fleet_ratchet.yml (8 row(s): 1 missing)
pantry: UNRECORDED
FAIL account-scope-fleet: pantry UNRECORDED
EXIT=1
```

Restored, the runner is green again with `EXIT=0` and `git status --porcelain` is empty.

## 6. `tests/validate.sh` — TWO FAILURES, BOTH PRE-EXISTING, NEITHER IN THIS DIFF

The full gate ran to completion with no timeout narrowed. It exits **1** on two checks,
and **neither is in the three files this packet touched** (`CHANGELOG.md`, `README.md`,
`tests/account_scope_fleet_ratchet.yml`). Both were isolated and both reproduce on
`HEAD~2`, which is the merge of the packet that created this record.

```
FAIL: 2 check(s) failed.
note: 5 check(s) skipped (reported above).
GATE_EXIT=1
```

This packet's own checks are green in the real run:

```
PASS in-scope repositories  (every one declares its account-scoped surface)
PASS account-scope wiring  (the gate runs the runner, and the runner has a record)
PASS README.md  (documents every new template)
```

The five skips are the documented ones — three `.sql` templates parsed by
`tests/tenancy_test.sh` against a real Postgres, two TypeScript tier tests needing a
type-stripping parser — and are unrelated to this packet.

### 6.1 `generated stack` — 4 findings in four SIBLING repositories

```
BLOCKING: 4 finding(s) — every one of them fails this gate:
  - cafaye-rb: caf.dev.compose.yaml is not ignored …
  - cafaye-ts: caf.dev.compose.yaml is not ignored …
  - docs:      caf.dev.compose.yaml is not ignored …
  - guard:     caf.dev.compose.yaml is not ignored …
FROZEN-FINDINGS: 2 (darkroom, muse) … reported and not counted.
```

`tests/generated_stack_check.py` asks **git** two questions of every repository under the
fleet root that has a `cafaye.yml` (`check-ignore` and `ls-files`). It reads no file this
packet touched, and **kit is not among its findings** — so nothing here is fixable from
this worktree, and this brief forbids editing `guard` and `docs` in any case.

### 6.2 `self_test` — 5 recipes uncaught, ONE pre-existing cause, reproduced on `HEAD~2`

```
FAIL: self_test — 5 breakage(s) the gate did not catch.
    self_test: unbroken tree — the gate is RED on an unbroken tree (exit 1)
    self_test: breakage 23b: … the gate exited 1, so the skip was not clean
    self_test: breakage 31b: … the gate is RED on an unbroken tree (exit 1)
    self_test: breakage 38: … the gate went red, but NOT via `tests/classify.py + tests/staleness.py`
    self_test: breakage 59: … the gate went RED (exit 1), so the ceiling is not in force
```

Four of the five are the suite's **green-expecting** controls and the fifth is a
**needle** assertion, which is the signature of a copy that is red for a reason no
breakage introduced. The cause, found by rebuilding a copy the way `fresh_copy` builds
one and running the static phase:

```
FAIL README.md  (documents every new template)
       README.md documents reports/account-scope-contract-01/snapshot.sh, which does not exist
EXIT=1
```

`fresh_copy`'s entry list is `.gitleaks.toml .github AGENTS.md README.md CHANGELOG.md
LICENSE DECISIONS.md MIGRATIONS.md RESERVED VERSION core docker lint templates tests`.
**`reports/` is not on it**, and `9cddeee`'s packet added a README reference into
`reports/account-scope-contract-01/`. So every one of the ~105 copies carries a README
naming a file the copy does not have, that one check fails in every copy, and the
green-expecting proofs plus the needle assertion all report it as their own failure.

Proven pre-existing, not inferred — the same copy built from the parent commit:

```
$ git archive HEAD~2 … ; bash tests/validate.sh --static-only --only="README.md"
FAIL README.md  (documents every new template)
       README.md documents reports/account-scope-contract-01/snapshot.sh, which does not exist
FAIL: 1 check(s) failed.
EXIT=1
```

`git show HEAD~2:README.md` carries that reference on its own line 412, and my diff
touches three files, none of them `reports/`.

**The fix is one entry** — add `reports` to `fresh_copy`'s list — and `fresh_copy`'s own
comment states the rule this violates: *"when a packet adds a file the gate reads by
path, `fresh_copy`'s list is part of that packet. A new check is not done until a
throwaway copy can see the thing the check reads."* **It is not applied here.** Two
reasons. The packet's subject is two data rows, and editing the harness that proves all
105 of them inside a two-row packet is a change of a different kind that would need its
own full-suite re-verification and its own argument in a commit message. And it would not
make the gate green anyway: `generated stack` names four repositories this brief forbids
me to edit, so `tests/validate.sh` **cannot** exit 0 on this machine for this packet
whatever is done here. Reporting it with the reproduction costs the next packet one
command.

## 7. What is still unproven

- **`pantry`'s new end has not been observed to fire**, because it cannot fire today.
  `surface-unreadable` reports 0 read and the condition waits on a non-zero. It is
  written as an observable in `core`'s own warning rather than as a packet, so it does
  not depend on anyone remembering it.
- **`pantry/DECISIONS.md:1079` carries an unresolved merge-conflict marker**,
  `||||||| 2f3b623`, with no `=======` and no `>>>>>>>`. `pantry` is a read-only subject
  here. Reported, not touched.
- **The full gate was not green**, so this packet's claim is the three PASSes in §6 plus
  the runner's own `9 of 9`, not "the gate is green". The two failures are isolated,
  reproduced on the parent commit, and outside this diff.