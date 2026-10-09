# W2-P5 — headless installer mode, with a secret-free stdout

**Status: accomplished.** `bash tests/substrate_test.sh` — 110 passed, 0
failed, 0 skipped (was 90 at HEAD, 73 before W2-P4). `shellcheck -S warning`
clean on both files. The full gate was run for real, in the background, on the
finished tree; see **Verification**.

Worktree `kit-w2p5`, branch `agents-first/w2p5`, five commits, nothing pushed
and nothing merged.

---

## What the packet is for

`caf box apply --phase N` has to be able to drive an install whose only human
touchpoint is "fill in this form on the box". Two things make that possible,
and neither is the interesting half on its own:

- **A headless mode** (`--headless`, or `HEADLESS=1`) whose stdout is a stream
  of JSONL progress events — one object per line, and nothing else.
- **An install-receipt file** naming the phase, the next step, the input needed
  and where the human goes, rewritten at every state change so a crashed
  install leaves one pointing at where it stopped.

The receipt's shape follows the run/steps/events model in
`moon/refs/cleo-agentic/internal/platform/postgres/state_store.go` (phase,
status, step index against a total, an updated-at) — W5-P4's resumable install
is its consumer, and `caf box apply --phase N` reads it to know where to
resume.

## The property, and why it is a parse rather than a run

The claim is **"headless stdout is progress-only"**. A run of the happy path
proves nothing about a code path the run never reached, so the tripwire is a
parse of every `echo` and `printf` in `install.sh` — the `SECRET RECORD` test's
own idiom, extended to the new mode. It is section 14 of
`tests/substrate_test.sh` (`check_headless_stdout`), and it enforces two rules:

1. A statement that writes to the **process stdout** must live inside one of
   the two writers.
2. Nothing that can reach stdout — **nor any emitter call site** — may expand
   a variable that holds secret material.

Rule 2 is what makes rule 1 worth having. A channel only two functions write
to is still a channel a `$PASSWORD` could be poured into, and `kit_substrate_emit
progress "redeemed ${REGISTRY_DOCKERCONFIGJSON}"` satisfies rule 1 completely.

### The two writers

| | headless | interactive |
|---|---|---|
| `kit_substrate_emit` | stdout, one JSONL object per line | stdout, the exact old text |
| `kit_substrate_out` | **stderr** | stdout, the exact old text |

The split is the whole property. Interactive output is **byte-identical** —
verified by diffing the same `DRY_RUN=1` run before and after the conversion —
because the human channel simply moves to stderr in headless mode, so the
operator and `caf box logs` still read it while stdout stays machine-parseable.

Twenty-five `echo` lines were routed through `kit_substrate_out`, plus `main`'s
closing summary. A `printf … | kubectl apply -f -` is a **pipe, not a stdout
write**, and it is exempted: that is the good path — the credential travels
into kubectl, never into a terminal.

### Three exemptions, all closed lists, and why

- **Continuation lines are joined before the parse.** The pipe into
  `kubectl apply -f -` sits on the line *after* the `printf`, so a line-based
  read flags the one statement in the file whose output most needs to stay off
  a terminal. This was the check's first version and it was wrong.
- **`SECRET_VARS` is a list of names, not a `*SECRET*` pattern.** A glob would
  also match `secret_name` — a Kubernetes object's *name*, which is not a
  value — and `secret_base`. A check that fires on correct work teaches its
  reader to ignore it.
- **`database_url_for` and `oidc_key_id_for` are excused from rule 1** because
  their stdout is a command substitution at every call site. The check
  **asserts that**, so calling one bare goes red — the exemption cannot be
  widened by adding a name to it.

## The live half

A static parse cannot see a value that only exists at runtime, which is
exactly what every generated key occupies. So the headless path also *runs*,
the way section 13's cases do: the installer sourced with `main` stripped,
`kubectl` mocked to files. It asserts stdout parses line by line as JSON, that
the detail lines are on stderr and **not** on stdout, and that none of the
values the run *holds* reach stdout — the generated `SIGNUP_SIGNING_KEY`, MFA
key, `SECRET_KEY_BASE`, box key, relay token, role passwords, redis password,
the operator's relay password, and the `DATABASE_URL`s those passwords sit
inside. That last pair is the interesting one: a value the installer *builds*.

## Five controls, each proven able to go red

A bare `echo` restored in step 7 · a secret-shaped variable through
`kit_substrate_out` · the same through `kit_substrate_emit` · a piped secret
moved onto the process stdout · a receipt with no `human` destination · a
second receipt recorded as `"running"` · a refusal event with a null
`human` · a refusal event with no fix hint on stderr.

The `"running"` control is the one that matters most: a refusal recorded as
running is an install the agent believes is still in progress, which is the
failure direction a reader would not think to check.

## What was found while writing it — four real defects

1. **`${memory_kb}` in preflight.** The variable is `mem_kb`. Under `set -u`
   this is a fatal, introduced by the refusal conversion this packet keeps.
   Caught by `shellcheck -S warning`, not by any test — no test runs
   preflight, because it needs root and Linux.
2. **`main` called its steps as `CURRENT_PHASE="nats"; install_nats`**, which
   broke `check_nats_install`'s `^  install_nats$`. **Fixed in `install.sh`,
   not in the check** — `main` now puts the phase on its own line. A check
   relaxed to accommodate a tidy compound is a check that has stopped
   measuring.
3. **`kit_substrate_refuse` dropped the fix hint.** It printed only
   `error: <message>` and silently lost the
   `export KIT_SUBSTRATE_…` line that tells an operator how to unblock. The
   existing refusal checks stayed green throughout — the *variable name*
   appears in the message, which is what they grep for. The only thing that
   caught it was a new assertion about the hint itself. This is the same
   failure mode as the pipe-shaped "the gate went red, but NOT via …" lesson,
   one layer down: **a check satisfied by something other than the thing it
   names.**
4. **The headless refusal run killed the harness.** The installer is
   *expected* to exit non-zero there, and under `set -e` a bare failing
   command takes `substrate_test.sh` down before the status is read — the
   suite died at exit 1 with its summary line unprinted. Fixed with the
   `|| ec=$?` shape the `run` helper has documented for years.

## What is NOT proven here

- **Nothing runs on a real box.** No k3s, no cluster, no registry redemption,
  no mint. The substrate README says so in the same words, and it is still
  true: `DRY_RUN=1`, the mocked-kubectl cases and the source parses are what
  this machine can see.
- **The receipt's `next` field names the step the run is about to take**, not
  the one after it. That is a defensible reading of "next step" for a receipt
  rewritten at every step start, but it is a reading, and a consumer that
  wants "the step after the current one" has to know that. Named here rather
  than papered over.
- **`caf box apply --phase N` does not exist yet** (W2-P6). The flag accepted
  here is `--headless`; the phase-selector seam the receipt implies is W5-P4's
  consumer's problem, not this packet's, and no phase-selector flag was
  invented for it.
- **The `install.start` event's `step` is `0`**, because no step has started
  when the install opens. A consumer should read `phase` for that.
- **The JSON is built with `jq -Rs`/`printf`, not a schema.** There is no
  `install-receipt.schema.json` in kit, so the receipt's shape is enforced by
  the test's field check and by nothing else. If this becomes a contract
  another repo depends on, it wants the schema.
- **The gate's 9 skips and 5 time bounds are on record in the log below**, and
  they are skips about the environment, not about this packet's claims.

## What a successor should know

- `install.sh` now has **exactly two stdout writers**. If you add a third, the
  check goes red, and the correct response is to route through
  `kit_substrate_out` rather than to add a name to an exemption — the
  exemptions are closed lists and each one was argued for.
- Adding a **new secret-bearing variable** means adding it to `SECRET_VARS` in
  the *same commit*. The list is the contract; an absent name is a hole the
  check cannot see through.
- The `SECRET RECORD` tripwire is **unchanged** — not weakened, not extended to
  cover headless, not touched.

---

## Verification

- `bash tests/substrate_test.sh` — **110 passed, 0 failed, 0 skipped**
  (90 at the branch point; the 20 new ones are section 14).
- `shellcheck -S warning templates/substrate/install.sh tests/substrate_test.sh`
  — **clean**.
- `bash -n templates/substrate/install.sh` — clean.
- Interactive output is **byte-identical**: the same `DRY_RUN=1` run before
  and after the conversion produces the same bytes; the only difference is
  where they go in headless mode.
- `bash tests/validate.sh` — run alone, in the background, keyed to this
  worktree (`/tmp/gate-kit-w2p5.log`, exit code in `/tmp/gate-kit-w2p5.exit`).
  **GREEN on the final commit `3167ca4`**: exit code **`0`**,
  `PASS: every check passed.`, **598 PASS rows, zero real FAIL rows** (the two
  lines containing "FAIL" are text *inside* PASS labels), and
  `substrate_test: 110 passed, 0 failed, 0 skipped`.
  `note: 9 check(s) skipped — reported above, never hidden.`
  `note: 5 tier(s) ran under a time bound; none was reached.`
  Two earlier runs are on record as well: an earlier green on the mid-edit
  tree, and the two `set -e` failures the harness itself hit while section 14
  was being written (both fixed, both described above). So this packet has
  been seen green, and seen red in its own harness.
