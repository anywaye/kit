# REPORT-kit-launch-harness-m186 — Kit owns the local launch harness

## What this packet is for

Make Kit the owner of the reusable local launch/integration harness for the
four-service product stack (identity, gateway, courier, parlor), so
`cafaye/website` remains only the Cafaye app derived from Parlor and the old
`cafaye/site` repo is no longer required to bring up or inspect the stack.
Derived from Site's `bin/launch` + `e2e/docker-compose.launch.yml`, which
are retired, not mirrored: no Site or Website repo was edited, and neither
is required for anything here.

## Ownership

Kit owns it, in a Kit-owned location that is neither a service template nor
a service copy:

- `launch/bin/launch` — the bring-up (checks, secrets, mint, two phases,
  status, down). Lives in Kit because a four-service harness cannot live in
  any one service's copied `bin/dev`; Kit's own `tests/*.sh` are the
  precedent for Kit-owned executable tooling.
- `launch/docker-compose.launch.yml` — the overlay (four services +
  mailpit, the database list, nothing Kit ships redeclared).
- `launch/README.md` — the contract: commands, layout, secrets, phases,
  and what is not proven.
- `tests/launch_test.sh` — the shape proof, wired into the gate's static
  phase beside `substrate_test.sh`.

## Files changed

| File | Change |
|------|--------|
| `launch/README.md` | new — ownership, commands, layout + overrides, secrets, phases, non-goals |
| `launch/docker-compose.launch.yml` | new — adapted overlay; build contexts parameterized as `${LAUNCH_*_DIR:-../../<svc>}`, project `kit-launch` |
| `launch/bin/launch` | new — adapted launcher; explicit sibling paths, stack defaults to this checkout, `KIT_STACK_DIR`/`LAUNCH_KIT_REF` overrides, `--check`/`status`/`down`/`up` |
| `launch/.env` | git-ignored (`.gitignore`), never committed |
| `tests/launch_test.sh` | new — 46 cases, hermetic, stubbed tools, no daemon |
| `tests/validate.sh` | new static-phase section + check for `launch_test.sh` |
| `README.md` | three artifact-table rows (launcher, overlay, test) |
| `CHANGELOG.md` | Unreleased/Added entry |

## Commands run and actual evidence

- `bash -n launch/bin/launch` — parses. `shellcheck -S warning
  launch/bin/launch` — clean (one SC2034 fixed by asserting the register
  response is non-empty rather than disabling the check).
- `bash tests/launch_test.sh` — **46 passed, 0 skipped, 0 failed**
  (log: `/tmp/launch-m185-test.log`). Every invariant carries a control
  that goes red under the same assertion the real tree passes; three
  test-side defects found by the first run were fixed in the test, not by
  weakening it (seam-secret patterns missing the YAML `" `, `export`
  word-splitting on `identity,courier`, comment-stripping for the
  substrate-free check — the last per Kit's own strip-comments lesson).
- Real `docker compose config` (v5.1.2) renders the overlay against this
  checkout's stack and carries all six launch services — client-side only,
  starts nothing, throwaway project `kit-launch-test`, throwaway directory.
- `bash -n tests/validate.sh` — parses after the wiring edit.
- **Not run, by instruction:** `./bin/prime`, the full Kit gate, any
  `docker compose up/down/build`, the installer, browser, or remote/deploy
  commands. Those belong to the manager on the merged tree.

## Semantics preserved from the old Site harness

Prerequisite/check mode; pin-shape rule (sha or `v<semver>`, never a
branch); stable local secrets with the courier token minted from identity's
API only after identity is ready (register → session → account → api-key,
signup-timestamp aged past `MinAge`); bounded readiness waits (60×2s poll,
no sleeps-as-guesses); start/status/down; the same four service identities
plus mailpit; the same ports, `:?` seam secrets, A3 single-key contract,
`KIT_POSTGRES_DATABASES: "identity,courier"` literal, and the one-shot
excluded from every wait set. Deliberate deviations: sibling paths are
explicit variables (no `../kit`+`../identity` hard-coding, no Website/Site
requirement); the stack is this checkout unless overridden (no fetch on the
default path); pin resolution calls `templates/bin/dev.sh live` instead of
Site's `bin/kit-dev` symlink.

## The customer installer is separate

`templates/substrate/install.sh` (k3s, Argo, CloudNativePG, ACME, GHCR)
remains the authoritative customer path and is untouched. This harness is
developer-only (loopback, generated dev secrets, named volumes) and
**proves nothing about k3s/Argo sync/ACME issuance/GHCR pulls/Cloudflare** —
`launch_test.sh` fails the tree if the harness ever claims otherwise, and
`launch/README.md` states the split in the same words.

## What remains (manager / successor)

1. **Full gate on the merged tree** — `./bin/prime` / `bash
   tests/validate.sh` including the new static check. This worktree ran only
   the focused test.
2. **Live bring-up proof on a disposable machine or VM** — with real sibling
   checkouts at `cafaye/{identity,gateway,courier,parlor}`, run
   `launch/bin/launch --check` then `launch/bin/launch`, verify the five
   URLs, sign in as the launch owner, read mail in mailpit, then
   `launch/bin/launch down` and re-up to confirm credential stability.
   Never against the protected `site-launch-*` stack.
3. **Retire Site's copy** — delete `cafaye/site/bin/launch` +
   `cafaye/site/e2e/docker-compose.launch.yml` (separate repo, separate
   review) once the live proof passes; confirm nothing else imports them.
4. No production, DNS, registry, or Cloudflare claim was made here, and
   none should be added to this harness.
