# REPORT — the `caf` → `cafe` command-name sweep

Branch `fix/caf-name-sweep`, worktree `/Users/kaka/Code/any/moon/wt/fix-caf-name-sweep`.
Base `15fd587`. Two commits, tree clean, `bash tests/validate.sh` green.

## The result

47 stale `caf <verb>` command references across 15 living files, all replaced
with `cafe <verb>`. Zero remain. Two commits:

| commit | files | replacements |
| --- | --- | --- |
| `c746d96` substrate: the installer and its parser test say `cafe box` | 2 | 22 |
| `04d6c91` cli name: the remaining 25 | 13 | 25 |

### Per-file counts

| file | n | verbs |
| --- | --- | --- |
| `templates/substrate/install.sh` | 17 | `cafe box` |
| `templates/substrate/README.md` | 6 | `cafe box` ×4, `cafe gen chart` ×2 |
| `tests/fingerprint.py` | 4 | `cafe lock` |
| `templates/tier/README.md` | 4 | `cafe gate` |
| `templates/tier/ruby/tier.rb` | 2 | `cafe gate` |
| `tests/substrate_test.sh` | 5 | `cafe box` |
| `tests/fingerprint_test.sh` | 1 | `cafe lock` |
| `templates/tier/go/tier.go` | 1 | `cafe gate` |
| `templates/tier/bun/tier.test.ts` | 1 | `cafe gate` |
| `templates/publish/publish.yml` | 1 | `cafe gen chart` |
| `templates/database/go/tenancy_test.go.snippet` | 1 | `cafe gate` |
| `.github/workflows/publish.reusable.yml` | 1 | `cafe gen chart` |
| `.github/workflows/chart.reusable.yml` | 1 | `cafe gen chart` |
| `cafaye.yml` | 1 | `cafe dev` |
| `AGENTS.md` | 1 | `cafe gate` |

## The 91, reconciled

The brief's narrow grep found 91 hits. Measured against the pre-sweep tree it
splits exactly:

- **47** in living files — all swept.
- **44** in history and the ledger, left as written: `CHANGELOG.md` (11),
  `REPORT-*` (32), `HANDOFF-kit-fingerprint-01.md` (1).

`91 = 47 + 44`, and that only balances because it was counted rather than
assumed.

**The narrow grep's coverage was complete, and my first commit message said
otherwise.** Draft 1 of `04d6c91` claimed the narrow pattern "misses four verbs"
(`caf gate`, `caf lock`, `caf gen chart`, `caf dev`). It does not: its
`` `caf `` alternative catches all of them, because every one of those 25
references is backtick-quoted. Verified by running the narrow grep against the
pre-sweep backups of all 15 files: 47 matching lines, and this sweep touched
exactly 47. The commit message was amended to say the measured thing instead.

## The near-miss, which was not the grep

The real risk was **my own filter**, and it is the finding worth keeping:
`grep -rn "caf …" | grep -v cafaye` does not remove matches that contain
`cafaye`. It removes every line whose *filename* is `cafaye.yml`, because
`grep -rn` puts the filename in the line. That silently dropped an entire
file — both of its command references — out of every inventory built with it,
and an inventory built with a filter that quietly discards a whole file is
worse than no inventory.

Two references survived only because `cafaye.yml` was re-read individually
afterwards, which is how `cafaye.yml:55` (`caf dev`) was caught and
`cafaye.yml:6` was read rather than pattern-matched.

**A filter named after the thing you must not touch is not a safe filter.**

## What was deliberately NOT touched, and why

Six references survive, each one `caf` as the **repository name** or a path,
not as the CLI:

| location | text | why it stays |
| --- | --- | --- |
| `tests/classify.py:38` | `caf \`go:embed\`s it into a struct` | the repo's Go source |
| `templates/deploy/reference/courier.deploy.yml:22` | `caf is the platform's own reclamation service` | the repo, as a noun |
| `templates/deploy/reference/courier.deploy.yml:26` | `even if caf were a good candidate` | ditto |
| `templates/otel/go/otelhttp.go.snippet:236` | `the bug caf shipped` | the repo's bug |
| `core/vendir/vendir.yml.caf:4,29` | `caf today vendors core's manifest schema` | the repo, and a filename |
| `core/README.md:30` | the vendir table's undeclared row | the repo |
| `AGENTS.md:1121` | `` `caf` ships the checker `` | the repo |

Two files carried **both kinds on one line** and were edited surgically rather
than by pattern:

- `cafaye.yml:55` — "would tell `caf dev` to start something, **and `caf` has**
  nothing to run here". The first is the command; the second is the repository.
- `AGENTS.md:1125` — the command; `AGENTS.md:1121`, two lines up, is the repo.

A bulk `s/caf /cafe /` on either line would have renamed a repository.

### The judgement call: `cafaye.yml:6`, left whole

```
#   cd ../caf && go run ./cmd/caf contract lint ../kit/cafaye.yml
```

This looks like a seventh verb under a loose grep. It is not one: `./cmd/caf`
is a **Go package path** and `contract lint` is its subcommand, so the binary is
built by `go run` and nobody types `caf contract` anywhere.

Reinforcing that: `README.md:1344` lists a sibling worktree named **`cafe`**
(`billing cafe core courier …`) while `core/vendir/vendir.yml.caf` still carries
`caf` and its own banner says the rename is blocked. The repository's directory
name is mid-flight, and `cd ../caf` is a path into a repository whose layout is
not this packet's to decide. Left exactly as written and recorded here so the
next reader does not re-derive it.

Verified untouched at the end of the sweep: this is the only remaining
`caf `-plus-path form in any living file.

## Docs and history

`CHANGELOG.md`, every `REPORT-*` and every `HANDOFF-*` were **not modified** —
verified with `git diff --name-only` restricted to those paths, which is empty.
Where a doc quotes the old name as the historical record of a packet, it stays.

**One deliberate deviation from `AGENTS.md`'s pre-commit checklist:** it asks
for a `CHANGELOG.md` entry. The brief says the ledger's own entries are not
mine to edit and to add nothing else, so no entry was added. This is named
rather than done quietly — the manager may want one.

## The gate

`bash tests/validate.sh` with no flags — which is what kit's own CI runs for
this change: `tests/route.sh` classifies it `ROUTE=full` (it touches
`templates/`, `tests/` and `.github/`), and `full` calls `ci.reusable.yml` with
`language: none`, i.e. the full release proof.

```
PASS: every check passed.
note: 8 check(s) skipped — reported above, never hidden.
note: 5 tier(s) ran under a time bound; none was reached.
```
**221 PASS, 0 FAIL, 8 SKIP, exit 0.**

Kits's own gate file is `.github/workflows/ci.yml`; there is no `gate.yml`.
Docker, mise, `go`, `ruby`, `node`, `shellcheck`, `golangci-lint` and `.venv`
were all present, so nothing was skipped for want of a tool. All 8 skips are
environmental and pre-existing, none caused by this sweep:

- 3 × SQL, deferred to `tests/tenancy_test.sh` against a real Postgres
- 2 × `.ts`, `node --check` cannot read TypeScript
- 3 × `.rs`, `rustc` not installed

Every file this sweep touched was parsed or executed by the run that passed:
`install.sh` (shellcheck + the substrate suite), `tier.rb` (ruby parse),
`tier.go` (gofmt), the three YAMLs and both workflows (yamllint + zizmor),
`cafaye.yml`, `AGENTS.md` markdown, and the two Python files (classifier and
fingerprint, both *executed* in their own phase).

Narrow iteration during Q1: `bash tests/substrate_test.sh` → 403 passed, 0
failed, 0 skipped, exit 0.

## Red proofs

**Positive — and the only guard that exists.** Reverting one replacement,
`cafe box enroll` back to `caf box enroll` at `install.sh:2330`, makes
`tests/substrate_test.sh`'s `master_refusal_pins` go red:

```
FAIL substrate_test: control: the exchange alone still demands a capability before seeing any artifact
       the refusal does not carry the capability line
       error: KIT_SUBSTRATE_REGISTRY_CAPABILITY is not a minted capability
         export KIT_SUBSTRATE_REGISTRY_CAPABILITY='<cap_… from caf box enroll>'
```
`401 passed, 1 failed`, exit 1. This is the one place a rename crossing two
files is guarded: the test asserts install.sh's exact capability line, so a
sweep that reached `install.sh` and not `substrate_test.sh` — or neither — is
caught. Both files moved together in one commit for that reason.

**Negative — and it is honest.** Reverting one non-paired replacement
(`cafe gate` → `caf gate` at `templates/tier/README.md:61`) and running
`bash tests/validate.sh --static-only`:

```
PASS: every check passed.
216 PASS, 0 FAIL, 9 SKIP, exit 0
```

And grepping the whole log for the CLI name: **0 checks mention it.**

**So for 46 of the 47 replacements, nothing in kit's gate catches a stale
`caf <verb>`.** There is no check anywhere in `tests/` or `.github/` that
grades the CLI name; `master_refusal_pins` is the only guard and it covers one
string. This is stated plainly because a packet that claims otherwise would be
the "check that never went red" that `AGENTS.md` keeps warning about. The
sweep is correct by inspection, not by proof, for those 46.

If the fleet wants this defect to be impossible rather than merely absent, the
cheap version is a check that greps kit's living files for `\bcaf (box|gate|
lock|gen|dev|deploy|login|publish|new)\b` and fails on a hit that is not on an
allowlist of the seven repository-name locations. That check would have made
this packet self-proving. It was **not** added, because the brief said add
nothing else.

## Environment

Worktrees used: only `/Users/kaka/Code/any/moon/wt/fix-caf-name-sweep`. No
other repository was touched, no sub-agent was used, and nothing was merged or
pushed — the manager merges and pushes, which is what publishes kit's charts.
