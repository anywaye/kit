# HANDOFF — `image.reusable.yml`'s `stamp provenance` step has never run

Branch `worker/provenance-built-at-01`, in
`/Users/kaka/Code/any/moon/cafaye/wt-kit-provenance`. Not merged, not pushed.

**One-line summary:** `built_at` was written as a PREFIX ASSIGNMENT, so the
`echo` that read it back read a name the shell had never been given, and under
`set -euo pipefail` that is `unbound variable` and exit 1 on every run. It is
now a plain assignment plus an `export`. A new gate check asserts the whole
class.

---

## 1. Root cause

`KIT_PROVENANCE_BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` was written as a
**prefix assignment** — the first word(s) of a command line rather than a
statement of its own:

```yaml
KIT_PROVENANCE_BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  KIT_PROVENANCE_SOURCE_DIRTY=clean \
  sh docker/provenance.sh --validate
{
  echo "source=$KIT_PROVENANCE_SOURCE"
  …
  echo "built_at=$KIT_PROVENANCE_BUILT_AT"        # ← this line
  …
} >>"$GITHUB_OUTPUT"
```

In POSIX shell, `VAR=value cmd` sets `VAR` **in the environment of `cmd` only**.
It does not create a shell variable, and it does not survive the command. So the
`echo` two lines down expanded a variable that had never been assigned in the
shell, and because every step in this tree opens with `set -euo pipefail`, `-u`
turns an unset read into a fatal rather than an empty string:

```
…/a3e65930-7651-49d2-a649-bbe3b13d36da.sh: line 8: KIT_PROVENANCE_BUILT_AT: unbound variable
```

The four sibling fields were unaffected because they arrive through the step's
`env:` block, which GitHub populates in the shell's real environment.
`built_at` was the **only** field created inside the `run:` body and the **only**
one created as a prefix assignment — which is exactly why it was the only one
that broke, why nothing in review suggested a fault, and why the failure was
identical on all 179 runs rather than intermittent.

The consequence: `cafaye/site`'s `publish` job has never been green, so
`ghcr.io/cafaye/site` — the image `config/deploy.yml` names — **has never
existed**.

## 2. Reproduction, before the fix

Extracted the step's `run:` body **verbatim** from master's own blob via
`yaml.safe_load` (not by hand, so there is no transcription step), and ran it
under `bash` with the step's `env:` block populated:

```sh
env -i PATH="$PATH" GITHUB_OUTPUT="$S/out" \
  KIT_PROVENANCE_SOURCE=cafaye/kit \
  KIT_PROVENANCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
  KIT_PROVENANCE_TEMPLATE_VERSION=v1.2.3 \
  bash "$S/run_body.sh"
```

Output, on the unmodified file:

```
run_body.sh: line 8: KIT_PROVENANCE_BUILT_AT: unbound variable
EXIT=1
```

Two things worth recording about that reproduction. It is **line 8** of the
extracted body — the same line number CI reports — and `GITHUB_OUTPUT` contained
only `source=` and `revision=`, i.e. the step died partway through writing its
four outputs, having already run the stamper successfully. So the stamper was
never the broken half.

## 3. Verification, after the fix

**3a. The same body, same runner, same env — the real `docker/provenance.sh`:**

```
EXIT=0
$ cat $GITHUB_OUTPUT
source=cafaye/site
revision=0123456789abcdef0123456789abcdef01234567
built_at=2026-10-05T08:55:02Z
template_version=v1.2.3
```

Four `key=value` lines. **The brief said "five"; there are four, and there were
always meant to be four** — `source_dirty` is deliberately not an output,
because `image.reusable.yml`'s `build-args:` passes it as a literal `clean`
rather than round-tripping it through an output. Nothing was lost in the fix.

**3b. `docker` IS available on this machine**, so the brief's step 3 ran for
real. `sh docker/provenance.sh --validate` with all five fields: **exit 0**.
`--args`: exit 0 and five correctly-formed `--build-arg` lines. `--write`: exit 0
and the five-field JSON.

**3c. The proof that `export` is load-bearing, on two real images.** This is the
part worth arguing for, because a green `--validate` proves nothing: `validate()`
maps an unset field to `unknown` and **accepts** it, so the stamper exits 0
whether or not the field arrived. A check asserting only "the step exits 0"
would be green on the broken file.

So: two builds of the real `docker/Dockerfile.go`, byte-identical inputs, the
only difference being whether `export KIT_PROVENANCE_BUILT_AT` is present.

```
1. WITH the export — the shell variable reads:    2026-10-05T08:55:02Z
2. WITHOUT the export — the shell variable reads: 2026-10-05T08:55:02Z
   ^ IDENTICAL. A check asserting only that the echo line works would be
     GREEN on both, so it proves nothing about the stamper.

3. What each hands to --args:
   WITH the export:    KIT_PROVENANCE_BUILT_AT=2026-10-05T08:55:02Z
   WITHOUT the export: KIT_PROVENANCE_BUILT_AT=unknown

4. The two images:
   with export  org.opencontainers.image.created = 2026-10-05T08:55:02Z
   no export    org.opencontainers.image.created = unknown
```

Note step 2: without the export the shell variable still reads correctly, so the
`echo` line would produce a plausible-looking `built_at=` — and the image would
still say `unknown`. That is the failure mode a shape-only check would miss, and
it is why the export is there and why it is load-bearing.

There is also a **negative control** in that pair: the pre-fix shape, with a
deliberately malformed timestamp, still reached the stamper and was refused by
name (`refusing to stamp built_at=yesterday afternoon`, exit 2). That is the
half of the old code that worked, and it is why the stamper was not changed.

## 4. Same-class audit — every `run:` body in `.github/workflows/`

Swept both workflows for the whole bug class: backslash continuations joined
into logical lines, every `NAME=` at a command-word position classified as
prefix or plain, every `$NAME` / `${NAME}` read checked for a bare read after
it. The classifier distinguishes `VAR=value` **alone on a line** (a plain
assignment — reading it back is correct) from `VAR=value cmd`.

**Three prefix-assignment sites exist in the tree. One was the bug. Two are
correct, and I am explaining why rather than leaving them to the next reader:**

| site | verdict | why |
|---|---|---|
| `image.reusable.yml` `stamp provenance` — `KIT_PROVENANCE_BUILT_AT` | **the bug** | read bare on line 8 under `set -u`. **Fixed.** |
| `image.reusable.yml` `stamp provenance` — `KIT_PROVENANCE_SOURCE_DIRTY` | **safe, deliberately left as-is** | never read bare in the block. `provenance.sh` is its only consumer and the command did receive it. Its consumer is `sh docker/provenance.sh`, which reads its own environment. |
| `ci.reusable.yml` `conformance suite`, go arm — `GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test "$dir/..."` | **safe, left as-is** | three prefix assignments to `go test`, none read back anywhere in the block or the job. These are exactly what a prefix assignment is *for*: they exist to reach one command's environment. |

The 20 plain assignments in the tree (`log=`, `name=`, `dir=`,
`GIT_TERMINAL_PROMPT=`, `KIT_TREE_DIR=`, `image=`, …) are all the correct shape
and all read back their own values; none is in this class.

**The other two fields the step sets via `env:`** — `KIT_PROVENANCE_SOURCE` and
`KIT_PROVENANCE_TEMPLATE_VERSION` — were checked for the downstream case the
brief asked about: neither is expected as a prefix assignment anywhere. They are
read by `provenance.sh` from its own environment (inherited from the step's
`env:`), and consumed afterwards as `steps.provenance.outputs.*` build-args.
`KIT_PROVENANCE_TEMPLATE_VERSION` is read bare on the `echo` line and is correct,
because `env:` populates the shell environment — measured in §2/§3, where it
appears in a green run. `KIT_PROVENANCE_SOURCE_DIRTY` is the one field never
handled by `env:` and the one now passed as a literal `clean` in `build-args:`;
that is pre-existing and deliberate, and out of scope here.

## 5. The gate, and the new check that would have caught it

Nothing in kit's gate could see this. `yaml.safe_load` on a workflow parses the
**document**; a `run:` body is a string inside it, and everything that makes a
step work or fail is decided by the shell that runs it. So the static phase was
satisfied by the workflow that had been failing 179 commits running — the same
lesson as `lint/` behind a parse check, one layer up.

`run_body_env_check` in `tests/validate.sh` asks the question that is decidable
from the text: **is there a name this block creates for a command and then reads
back as a variable?** It is deliberately a shape check rather than a real run —
executing every `run:` body needs the runner's services, the checked-out tree and
each action's inputs, and a check that needs all three to reach a verdict is a
check that silently stops running.

It knows the difference rather than relying on the author to remember it:

- **comments are stripped before the body is read.** The fix's own comment quotes
  the broken shape, verbatim, including `echo "built_at=$KIT_PROVENANCE_BUILT_AT"`.
  A check a comment can satisfy is not a check; a check a comment can
  **falsify** is worse, and this one would have been falsified by its own
  documentation.
- a prefix assignment **never read back** in the same block is left alone, so
  `source_dirty` and the three `go test` names stay correct code.
- `export VAR=v` is a **plain** assignment (it creates a shell variable), so
  reading it back is fine and is not a finding.
- a read that is the value of a **later** reassignment is not a bare read.

**Proof the check can go red, and its control.** Against master's own blob, in a
throwaway fixture (never a copy of this tree), the check goes red and names the
variable, both line numbers and the shape:

```
.github/workflows/image.reusable.yml :: jobs/build/steps/6: KIT_PROVENANCE_BUILT_AT is
set as a PREFIX assignment on line 2 … and read as a shell variable on line 8 …
EXIT=1
```

Six further fixtures, one property each — three that must go red (single-line;
three names on one command; a `case` arm ending in `;;`) and three that must stay
**green** (`export`; a later reassignment before the read; a prefix assignment
nothing reads back), plus a fixture whose only content is the bug **named in a
comment**, which stays green. So the check is known to fire *and* known not to
fire on correct code; a fixture two checks could satisfy would prove neither.

## 6. Pre-existing gate failures

**None.** The brief anticipated environment-dependent failures on this machine.
There were none to separate out.

- **Baseline**, unmodified `master` (`HEAD` tree == `master` tree, verified):
  `GATE_EXIT=0`, `PASS: every check passed.`
- **After the change**: `GATE_EXIT=0`, `PASS: every check passed.`

Identical in both runs:

- `note: 5 check(s) skipped` — 3× `templates/database/tenancy/*.sql` (SQL, parsed
  by `tests/tenancy_test.sh` against a real Postgres) and 2×
  `templates/tier/{bun,node}/tier.test.ts` (stock `node --check` cannot read
  TypeScript). Both are **named, counted skips**, not silent passes.
- `note: 4 tier(s) ran under a time bound; none was reached.` — no `BOUND`
  verdict was recorded.
- `FAIL` rows: **0** in both runs.

`yamllint -c lint/yamllint.yml` is clean on the changed workflow and
`shellcheck -S warning` is clean on the changed `tests/validate.sh`.

## 7. `docker/provenance.sh` was NOT modified

Confirmed: `git diff --stat` touches four files, and `docker/provenance.sh` is
not among them.

It should not have been. `validate()` reads `${KIT_PROVENANCE_BUILT_AT:-}` and
maps an absent field to `unknown`, which is **correct** — a developer's local
`docker build` must not be refused for not knowing its own commit. Measured
above (§3, negative control): the pre-fix prefix assignment *did* hand the
timestamp to the stamper, which accepted it. The stamper was never the broken
half; the workflow's shell was. Editing the stamper to work around this would
have meant loosening a redaction surface to accommodate a caller's typo — the
exact inversion of what the file's closed grammar is for.

## 8. Where this lands

The fix is in `kit`, so it reaches `site` only once it is on `kit`'s `master`:
`site/.github/workflows/publish.yml:75` calls
`cafaye/kit/.github/workflows/image.reusable.yml@master`. **Until this is merged
to `kit`'s master, `site`'s `publish` job keeps failing identically and
`ghcr.io/cafaye/site` still does not exist.** The first `publish` run after the
merge is the real proof, and it is the first run that job has ever had.

## 9. Files changed

| file | what |
|---|---|
| `.github/workflows/image.reusable.yml` | the fix: plain assignment + `export`; `source_dirty` stays a prefix assignment, with the reasoning in a comment |
| `tests/validate.sh` | new `run_body_env_check`, for the whole class |
| `CHANGELOG.md` | `### Fixed` entries for both |
| `README.md` | the static-phase bullet list gains the rule |

## 10. What a reviewer should be sceptical of

- **The check is a shape check, and I have said so.** It will not catch a `run:`
  body that is *semantically* wrong in a way that is not this bug. It catches
  exactly this class, and it is proven to fire and to stay quiet on correct code.
- **Nobody has ever seen `image.reusable.yml` produce an image.** This change
  makes the step executable; whether the *rest* of that job is correct is
  untested by anything in this repository, because the job has never run to
  completion. The first real `publish` run may find something else, and that
  would not be a defect in this fix.
- **`--validate` exiting 0 is not evidence the field arrived**, and no assertion
  anywhere in kit currently treats it as such. §3c is the only thing here that
  does measure it, and it measures it by planting a wrong value and reading the
  resulting label off a real image.
