# REPORT-kit-m162-live-stack-api.md

## m162 — Kit service-owned live Compose path for staged launchers

### 1. What the packet is for

Site's staged `bin/launch` calls `templates/bin/dev.sh stack`, then
composes using the **shared cache** directly. Kit's `up` path snapshots
the resolved tree into service-owned `.kit/live/<ref>` and composes from
there, but `stack` is intentionally read-only and `up` also starts
containers, runs the preflight, migrates and seeds. A launcher that only
wants to *stage* therefore had no Kit-owned command that produces the
snapshot without the side effects — the proven Kit/Site integration seam
this packet closes, from Kit's side only. Site is not changed here.

### 2. What was built

A new `bin/dev live` command in `templates/bin/dev.sh`:

- Runs the existing `resolve_stack` (the same five-source resolution
  `stack` and `up` share: `KIT_STACK_DIR` → cache → live snapshot →
  vendored → fetch). No duplicated fetch/cache logic.
- Runs the existing `sync_live_stack "$(stack_ref)" "$STACK_DIR"` (the
  same content-addressed snapshot `up` writes: ref recorded in
  `.kit-stack-ref`, bytes compared before any write, corrupt generations
  kept aside as `.stale`). No duplicated snapshot logic.
- Prints the machine-readable `resolved: .kit/live/<ref>` line (plus
  `ref: <ref>`), parseable with `^resolved: ` exactly as Site already
  parses `stack`'s output. The path is **always** the service-owned
  `.kit/live/<ref>`, never the cache.
- Deliberately renders **no** `compose config`: `stack` prints the merged
  config for a human; a launcher parses one line and composes itself, so
  config output would be noise on the line it reads.
- `stack` is untouched and stays read-only (creates nothing). `live` is
  the only command besides `up` that writes the snapshot, and unlike `up`
  it starts no containers, runs no preflight, migrates nothing, seeds
  nothing.

Dispatch: `live) live_cmd ;;` in `main()`, beside `stack) stack_cmd ;;`,
following the existing one-function-per-command convention. Header usage
block documents the command and its contract.

Docs: `README.md` command list gains the `bin/dev live` entry;
`CHANGELOG.md` `## Unreleased` gains the m162 entry. No other docs name
`bin/dev` subcommands (`templates/AGENTS.md` describes the stack model,
not the command list; `DECISIONS.md` untouched).

### 3. Exact command output (fixture run, local `file://` remote, cold cache)

First run:

```
== resolving kit
   fetching kit@dad08d07b5e504d8f68462617b72afecdfd90114 from file:///…/kit-remote.git (first run only)
   stack: /…/cache/dad08d07b5e504d8f68462617b72afecdfd90114 (fetched)
   live stack: .kit/live/dad08d07b5e504d8f68462617b72afecdfd90114 (snapshotted from kit@dad08d07b5e504d8f68462617b72afecdfd90114)
resolved: .kit/live/dad08d07b5e504d8f68462617b72afecdfd90114
ref: dad08d07b5e504d8f68462617b72afecdfd90114
exit=0
```

Second run (idempotent):

```
== resolving kit
   stack: /…/cache/dad08d07… (cache)
   live stack: .kit/live/dad08d07… (unchanged — the snapshot already is this ref)
resolved: .kit/live/dad08d07b5e504d8f68462617b72afecdfd90114
ref: dad08d07b5e504d8f68462617b72afecdfd90114
exit=0
```

Snapshot checksum stable across both runs (`66587993 2523`), and
`.kit-stack-ref` records the pinned sha. `bin/dev stack` on a fresh
fixture creates no `.kit/live` (verified: `ls .kit/live` → no such
file or directory, exit 0 on `stack`).

### 4. Verification

`timeout 110 bash tests/fetch_test.sh` — **full suite green, 14.1s, no
docker.** All pre-existing sections (1–10, incl. m157 §10) pass
untouched, plus six new m162 assertions in §11:

- `m162: bin/dev stack creates no .kit/live (read-only)`
- `m162: bin/dev live prints resolved: .kit/live/<ref>`
- `m162: the live snapshot contents match the pinned source`
- `m162: the live snapshot records the pinned ref`
- `m162: a repeated bin/dev live is idempotent (unchanged, bytes identical)`
- `m162: exactly one machine-readable resolved: line for callers to parse`

`bash -n` clean on both edited shell files. Full `tests/validate.sh`
**not** run, per the packet (manager runs the gate after merge).

### 5. Commits (this worktree, not pushed)

- `f89722b` m162 Q1: `bin/dev live` implementation + dispatch + header docs
- `6a66b5c` m162 Q2: `tests/fetch_test.sh` §11 (six assertions)
- Q3 (pending at report time): README entry, CHANGELOG entry, this report

### 6. Remaining caveats

1. **`live` resolves through the network on a cold cache**, like every
   other command: if neither cache, live snapshot, vendored copy nor
   `KIT_STACK_DIR` holds the pinned ref, it fetches. A launcher on a
   machine with no network and no snapshot gets the standard loud refusal
   (the offline message naming `KIT_STACK_DIR` / `.kit/stack` /
   `KIT_STACK_HOME`), not a snapshot. That is the existing
   `resolve_stack` contract, not a new failure mode — but a staged
   launcher that assumed `live` is always local will discover otherwise
   on a fresh machine.
2. **The `resolved:` path is relative** (`.kit/live/<ref>`, as
   `live_dir_for` prints), resolved against the service root where
   `bin/dev` runs (`--project-directory .`). A caller that `cd`s
   elsewhere between parsing and composing will resolve it wrongly.
   `stack`'s `resolved:` line has the same property in reverse (absolute
   cache path), so this matches existing caller behavior rather than
   introducing a new one — but it is worth one line in Site's launcher
   when it adopts this.
3. **No `compose config` validation in `live`.** `stack` renders the
   merged config (when the service has an override file) so a developer
   sees breakage early; `live` skips it to keep the machine-readable line
   clean. A broken service override is therefore found at the launcher's
   own compose call, not here. Deliberate (see §2), recorded so nobody
   "fixes" it by adding config output to stdout.
4. **Site adoption is out of scope and not done.** The launcher change
   (`stack` → `live`, compose from the printed directory) belongs to a
   Site packet. Until then this command is proven but uncalled.
5. **Full gate not run.** `tests/validate.sh` (static checks incl. any
   README/tree-agreement assertions, plus docker tiers) is the manager's
   merge step. The static risk is small (README gained three comment
   lines; no gate greps the command list today), but it is unmeasured.
