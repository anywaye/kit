# REPORT-kit-license-check-m172 — the `license_check` the prose already described

## Partial-work note

The worktree held no partial work from the previous attempt: `git status`
clean, `HEAD` equal to local `master` (`9a17ded`, the m168 landing), no
stash entries. Nothing to keep or discard; the packet was built fresh from
that base. (The "uncommitted partial work" the budget note warned about did
not survive — presumably committed or swept when the endpoint failed.)

## What this packet did

REPORT-kit-license-m168 §"Pre-existing discrepancy" recorded that
`README.md` and `AGENTS.md` describe a gate `license_check` that "reads the
grant" and "walks every root manifest", while no such check existed under
`tests/` or `.github/`. This packet implements it, against the proprietary
sentences rather than MIT's. No prose change was needed: both paragraphs
were written grant-generically ("reads the grant by the proprietary
sentences … rather than by an identifier string", "requires them to agree"),
and the new check satisfies them as written.

## Changed files

- `tests/validate.sh` — `license_check()` plus its `check` line, in the
  static phase between the shellcheck block and the otel-artifact section
  (kit-19's old position, adapted). Label:
  `LICENSE  (Cafaye proprietary, and nothing in the tree can disagree with it)`.
  Four assertions: (1) `LICENSE` contains `All rights reserved`,
  `proprietary property of Cafaye`, `separate written Cafaye agreement`
  (sentences, not the bare word `Proprietary`); refuses MIT's `Permission is
  hereby granted, free of charge`; (2) names a `Copyright (c) YYYY Cafaye`
  holder; (3) README's own `## License` section states the proprietary
  grant, names Cafaye, links `](LICENSE)`, and still names AGPL (the
  backends distinction — whole-file search would be satisfied by the exact
  conflation the section split prevents); (4) every root manifest that can
  carry a licence field (`package.json`, `Cargo.toml`, `pyproject.toml`,
  `composer.json`, `setup.cfg`, `bower.json`, `*.gemspec`) must agree —
  agreement is `Proprietary`/`UNLICENSED`/`SEE LICENSE ...` since
  proprietary has no single SPDX token. No field is not a disagreement;
  `templates/` out of scope by design. Prints its measurement on PASS
  (manifest count), per `check`'s contract.
- `CHANGELOG.md` — entry under `## Unreleased` / `### Added`.
- `REPORT-kit-license-check-m172.md` (this file).

## Focused checks and results

- `bash tests/validate.sh --only='Cafaye proprietary'` → `PASS LICENSE
  (Cafaye proprietary, …)` with the measurement line
  (`0 root manifest(s) inspected … kit has none …`). Green control.
- Red proofs, each a one-line edit plus `git checkout`/delete restore
  (no tree copies):
  - root `package.json` with `"license": "MIT"` → `FAIL` naming the check
    (the breakage-62 direction: compliance tooling reads the manifest).
  - `LICENSE` with `All rights reserved` edited out → `FAIL` naming the
    missing sentence.
  - MIT permission sentence appended to `LICENSE` → `FAIL` (dual-grant
    refusal). `LICENSE` restored byte-identical (`cmp` clean).
  - root `package.json` with `"license": "UNLICENSED"` → `PASS`
    (agreement, not a ban — the check is a rule, not a ratchet).
- `bash -n tests/validate.sh` → clean; `shellcheck -S warning -e SC2317
  tests/validate.sh` → clean (the gate shellchecks this file itself).
- `KIT_PARALLEL_CHECKS=1 bash tests/validate.sh --static-only` → exit 0,
  202 PASS, 0 FAIL, 9 reported SKIP (lint phase off via `--static-only`
  plus environment skips), 1 tier under a time bound, none reached. The
  first attempt at this run was SIGTERM-killed with no output at load
  ~12 on a 92%-full disk; the serial rerun is the same suite, not a
  weaker one — an unevaluated run is an environment verdict, not a tree
  verdict, and it is reported here rather than hidden.
- `git diff --check` → clean (verified at commit time).

## Deliberately NOT run / done

- Full gate (observability docker tiers, lint execution): out of scope for
  a static-phase gate change on a loaded box; `--static-only` exercises
  every check this packet could affect. Docker, prime, chart/image builds,
  releases: untouched. The full merged-tree Kit gate remains outstanding
  and is the manager's evidence, not this packet's: the numbers above are
  the worker's static-only evidence only.
- No README/AGENTS prose edit: verified both already describe exactly this
  check. No `RESERVED`, `VERSION`, or tier change: nothing retired, nothing
  versioned.
- CUT-ALL-DISPOSITION.md's CUT rows for breakages 61/62 left as history:
  they record what the cut-all packet removed, not what this one adds.
