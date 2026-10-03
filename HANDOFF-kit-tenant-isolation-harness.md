# HANDOFF — `kit-tenant-isolation-harness`

**Branch:** `worker/kit-tenant-isolation-harness` — committed, **not pushed**.
**Base:** `master` @ `c8d76df`.
**Report:** `REPORT-kit-tenant-isolation-harness.md`.
**Budget:** one hour; took about 1h45m. The overrun is item 6 and is named here
rather than absorbed.

---

## 1. Status: the packet's four "done means" items

| | |
|---|---|
| one control passing, output recorded | **yes** — 6 negative assertions, `Result: 6 passed`, 0.1s, real `postgres:17` |
| six breakages, each observed **red**, reverted, green again, literal failure line | **yes** — all six; the lines are quoted verbatim in the report §2 |
| tally reported separately | **yes** — `1 control(s) green, 6 breakages planted and all 6 observed RED … 0 skipped` |
| adapter contract documented for the other five languages | **yes** — `tests/tenant_isolation/adapters/README.md` |
| committed, not pushed | **yes** — `2bf0ff9` |

**The claim, at the width it is proven: cross-tenant isolation is proven for
Elixir, on a service that scopes correctly. Five languages remain unproven.**

## 2. What landed

```
tests/tenant_isolation/cross_tenant_harness.sh              the harness (language-neutral)
tests/tenant_isolation/adapters/elixir.sh                   the one adapter
tests/tenant_isolation/adapters/elixir/cross_tenant_probe_test.exs   the negative suite
tests/tenant_isolation/adapters/README.md                   THE ADAPTER CONTRACT
reports/tenant-isolation-harness/mutations.sh               the six breakages
reports/tenant-isolation-harness/BEFORE-*.ex, AFTER-*.ex    what is being broken
REPORT-kit-tenant-isolation-harness.md
CHANGELOG.md
tests/validate.sh                                           one line of scope widened, §4
```

`BEFORE-*.ex` and `AFTER-*.ex` are byte-identical by construction — every case
reverts before the next, and `diff -q` confirms it. They are committed so a
reviewer reads what is broken rather than reconstructing it.

## 3. Two facts a reviewer will want before reading the code

**Breakage 6 is reported as `2)`, not `1)`.** Dropping `account_id` from
`WebhookEndpoints.get/2` unscopes the controller's *shared* fetch, so update and
delete go red with it. The recipe prints the number the suite printed. A tidier
receipt would have been a wrong one.

**Breakage 3 was aimed at the wrong function and the recipe caught it.** The
first draft broke `list/1`; courier's controller paginates through `page/3`, so
`test_cross_tenant_list` stayed green and the recipe reported `WRONG FAILURE`
rather than a pass. **A breakage aimed at a function no entry point calls is a
breakage of a function, not of a surface.** Worth keeping as a rule: any future
adapter should expect this class of mistake in its own first draft.

## 4. The one change to `tests/validate.sh`, and what it is not

`docker_tier_project_name` listed scripts with `os.listdir(tests_dir)` — top level
only. The new harness is in a subdirectory, so it was in neither `tiers` nor
`uncovered`: the gate would have printed a tier count that excluded it and said
nothing. `os.walk` now. Measured after: **10 docker tiers, 0 hardcoded names, 0
fixed host ports, 0 uncovered.** The harness is inside the rules rather than
beside them.

Nothing else in `validate.sh` changed. In particular the harness is **not** wired
into a phase — item 5.

## 5. Not done, and what it would take

**(a) Not wired into `validate.sh`.** It is a documented entry point
(`bash reports/tenant-isolation-harness/mutations.sh`), not a gate phase.

What the wiring must be: an **observability/live-phase** call, next to
`tests/isolation_test.sh` and `tests/tenancy_test.sh` — those two already hold the
"a security property that nothing executes is worth nothing" claims, and this is
the third half of that sentence. It must **SKIP loudly** without docker, without
Elixir and without a service checkout, in the same tri-state those two do, and
those SKIPs must reach the summary line.

What it must **not** do: become a `tests/self_test.sh` recipe. `self_test.sh`
breaks a copy of *this* repository and asserts *this* gate goes red; these six
breakages edit another repository's query layer and assert an Elixir suite fails.
One phase answering two questions is how the second stops being checked. If you
wire it, wire it as its own phase call — and re-check `--only`'s exclusion count,
which is printed and is a contract.

**(b) Not a self-test recipe.** Same reason, above.

**(c) Five languages unproven.** The adapter contract is five functions:

| function | contract |
|---|---|
| `adapter_language_tool` | echo the one executable the harness must find, or the run exits 2 naming it |
| `adapter_prepare` | buildable copy under `$KIT_TENANT_WORK/service`; deps symlinked, never mutated; must not write into the checkout |
| `adapter_migrate` | **the service's own migrations**, against the harness's database |
| `adapter_install_probe` | copy the negative suite in and **prove it was collected** |
| `adapter_run <needle>` | run the suite, print output, exit the runner's status; exit 0 must mean every assertion passed |

Every adapter must reproduce **three denials and one allowance** (README §"The
assertion set"). The allowance is the arm a fleet writing only denials will forget,
and breakage 2 is the proof: a predicate bound to the wrong account reads as "zero
rows", which every denial-only assertion is perfectly happy with.

**(d) One service, one context.** Six surfaces. A service that grows a seventh
account-scoped entry point does not grow a seventh breakage automatically, and
nothing here asserts it should.

## 6. Where the hour went, and what to not repeat

Roughly: 20 minutes reading `tests/gate_self_test.sh`, `muse/tests/gate_self_test.sh`,
`core/harness/tests/db_isolation_self_test.sh`, `reports/wrapper-tier-scope/mutations.sh`
and courier's own controller test; 15 choosing courier's six surfaces; 45 writing
and debugging; 25 on three bugs that are each worth knowing:

1. **`bash -n` on a missing `)` inside `$(dirname "$(ls …)" 2>/dev/null`** — and
   then a second, worse one: bash 3.2 mis-parses a bare `(` inside a double-quoted
   string inside a command substitution and reports it as an unterminated `"` two
   lines later. Every needle in the recipe therefore carries a **trailing space**
   and no `(`. If you write a needle for a Python/Go/Rust runner, expect the same
   landmine.
2. **`printf '--- mix test …'`** — a format string starting with `-` is parsed as
   options by every POSIX `printf`, and it prints a usage message. It appeared
   once per run and read like a failed step.
3. **A harness a recipe must source cannot dispatch on its own argv.** The `case`
   ran on `.`, printed a usage message and exited 2, and the recipe reported a
   missing toolchain instead of the two lines that would have found it. It now
   guards on `[ "${BASH_SOURCE[0]}" = "$0" ]`.

Two more that cost a rerun rather than a bug: a `## shellcheck` comment line is
parsed as a **directive** and fails the parse, so no comment may begin with that
word; and a file-wide `# shellcheck disable=` must sit **before** the first
command or it disables nothing.

## 7. Gate state, for the merge

```sh
bash tests/validate.sh --static-only --no-self-test --no-live --only='docker tier'
```

→ **1 FAIL, and it is not this packet's:** `generated stack` reports
`cafaye-rb`, `cafaye-ts`, `docs` and `guard` for not ignoring
`caf.dev.compose.yaml`. That is the concurrently-landing
`worker/kit-fleet-generated-compose-01` work in four other repositories; nothing in
this diff touches it. The docker-tier check this packet did touch **passes**.

**The full gate was not run to completion.** `self_test` is *n* whole gates in
sequence and is documented in `AGENTS.md` as hitting its 90-minute bound on a busy
box — and this box had three other workers on it for the whole of this run. Run
`bash tests/validate.sh` by hand before merging, and read the `BOUND` verdict if
one appears rather than the exit status.

## 8. Teardown, and the box

Container and work directory are removed by `down` **and** by the `EXIT` trap in
the recipe. The `postgres:17` image is deliberately **not** removed: it is shared
with every other worker on this daemon and pulling it again costs each of them the
same two minutes. Nothing else was started and nothing else is running — verified
by `docker ps` after the final run.

`/tmp` was not used for the work directory; it is under `$TMPDIR`
(`/var/folders/…/T/kit-tenant-iso.$SESSION/`), removed on `down`.

## 9. No questions asked, and none needed

Nothing was blocked. `core`'s `account_scope_check.py` was **not** read, imported
or copied, and no code in this packet depends on it: the harness proves a
property by running the query layer, and a declaration's output format is not an
input to that. If the two are ever joined, it is core's side of the seam —
`account_scope.yml` naming the entry points, this harness proving them.