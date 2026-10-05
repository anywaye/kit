# HANDOFF — cut-all-01

Branch `worker/cut-all-01`. Base `78d84b5`. Nothing merged, nothing pushed.
Read `REPORT-cut-all-01.md` first; this file is only the work that remains.

State of the tree: `tests/validate.sh` is cut and committed (93 → 25 checks,
13,779 → 7,836 lines, `bash -n` and `shellcheck -S warning` clean, one filtered
gate run green). `tests/self_test.sh` is untouched.

## 0. Read this before touching `tests/self_test.sh`

`ce12131` — a commit on this branch by the repository owner, made while this
worker was mid-edit — says:

> recover(w21): the validate.sh cut, 5912 deletions, uncommitted at redirect
>
> The worker was mid-cut on validate.sh when the owner redirected: no tree
> copies at all. That retires the whole self-test layer, not just most of it, so
> the breakage work had not started. The check-level cut stands and is banked
> here.

If that redirect still stands, **step 1 below is not 110 cuts — it is deleting
the layer**, and step 3 changes shape with it. This worker was never given the
redirect and did not act on it either way; the file is still there. Confirm
before spending a quarter on a 110-recipe edit.

## 1. Cut `tests/self_test.sh` (120 breakages → 10 + 1 green control)

The KEEP list is in `CUT-ALL-DISPOSITION.md` and in `REPORT-cut-all-01.md`; the
brief's version is eight items. Mapped onto the recipes that exist today:

| keep | recipes |
|---|---|
| the secret scan finds a planted secret and never prints it | 41, 42, 43, 44 |
| the canary is never committed as a literal | 50 |
| the canary suite never prints the value it planted | **no recipe exists** — write one against `canary_output_check` |
| the Postgres tag agreement | 68 |
| the cluster topology | 70 |
| the account boundary | 90 |
| the lint gate is a gate | 27, 28 |
| the GREEN control | **write one**: a clean throwaway copy must come back green |

Ten recipes kept, one to write, one green control to write; 109 to delete.

Two things to delete with them, or `bash -n` and the counts will lie:
`copy_version` / `bump` (only the four version recipes used them),
`_shard_claims` and the `--shard` argument parsing (`shard_test.sh` is cut).

The header (lines 1-623) documents ~120 breakages and must be rewritten to the
ten. The three checks in `validate.sh` that policed this file
(`self_test_live_tier`, `self_test_claims`, `self_test_no_version_literal`) are
already cut, so nothing enforces the header — which is exactly the point of this
packet, but it means the header must be right by hand.

## 2. Prove each surviving check still goes red

Not optional. This is what makes the cut safe rather than merely fast, and it
was not done. For each of the 25 checks in `REPORT-cut-all-01.md`, reintroduce
its defect in a throwaway copy and confirm the named check reports `FAIL`:

```sh
cp -R /Users/kaka/Code/any/moon/cafaye/wt-kit-cut-all /tmp/kit-proof
# edit the one thing, then:
bash /tmp/kit-proof/tests/validate.sh "--only=<the check's label>" --no-self-test
```

Read the `FAIL <label>` line, not the exit status: an exit 1 can also be a
bootstrap failure, and this repository has been bitten by that twice.

The four that are cheapest and highest-value, in order: `postgres tag` (a `.env`
value), `the canary is never committed as a literal`, `the lint gate is a gate`
(`continue-on-error` on a lint step), and `FORCE ROW LEVEL SECURITY` removed
from the tenancy substrate.

## 3. Measure, then write the numbers into the report

`REPORT-cut-all-01.md` has "wall clock: not measured" and a "did not run" list.
Both are the manager's first question. On a quiet box:

```sh
time bash tests/validate.sh --no-self-test        # after the self-test cut
```

## 4. The documents are now wrong

`AGENTS.md`, `README.md`, `CHANGELOG.md` and `DECISIONS.md` describe the old
gate: its phase list, its check count, its `tests/` tree, the licence and README
checks, the tier/stability machinery, and the "n breakages" self-test. None of
that is true of this tree. Cut the prose that describes a cut check; do not
rewrite it to describe the new gate, which is the trap this packet exists to
avoid.

Add a `CHANGELOG.md` entry for this packet under `## Unreleased`.

## 5. Optional, and not started

`tests/canary_test.sh`, `stack_live_test.sh`, `shard_test.sh`, `deploy_test.sh`,
`kamal_test.sh`, `rls_perf_test.sh` and the four fleet `*_check.py` programs are
still on disk and no longer referenced by the gate. Delete the ones the owner
wants gone — but note that `canary_test.sh` is the only proof that a canary
secret reaches no exporter, and `deploy_test.sh` is the only proof the redactor
catches a JWT by shape.

## Do not

- add a mutation-testing tool, a coverage gate, or any check to compensate for
  what was deleted. Adding weight back is the failure mode of this packet.
- add a sleep, a retry, or a loosened assertion to make something green.
- keep something for being old, or for being the only detector.