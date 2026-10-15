# REPORT roll-c5-kit-ci-toolchains — the three checks a runner fails and a laptop cannot

## The red, measured

kit's own gate red on CI, run **38658518489**, job `full / none` (the job that
runs `tests/validate.sh` with no flags). Three checks fail, and all three pass
on the maintainer's machine:

```
FAIL templates/substrate/install.sh  (shellcheck -S warning)
       ^-- SC2120 (warning): kit_substrate_intended_hosts references arguments, but none are ever passed.
FAIL tests/substrate_test.sh
       FAIL substrate_test: control: the three-key installer passes issuer-alone without complaint (the refusal discriminates)
              no three-key tree found (base=03a7f768d709648939a4dcedbb0fabb6a1a497eb)
FAIL tests/lint_test.sh
       SKIP lint_test: go: golangci-lint is not installed — the go lint proof did not run
       SKIP lint_test: ruby: rubocop is not installed — the rubocop proof did not run
       FAIL: lint_test — assertion(s) skipped for a missing toolchain.
```

Each is a different KIND of environment gap, and each is fixed at its own layer.

## 1. SC2120 — a shellcheck version gap, fixed in the script

`kit_substrate_intended_hosts` reads `"${1:-$MANIFEST_DIR}"`, and no caller in
`install.sh` ever passes an argument (the two in-file callers rely on the
default; only `tests/substrate_test.sh` passes one, in a sourced subshell
shellcheck does not see). ShellCheck **0.10.0** — the class the runner carries —
flags that as SC2120; **0.11.0**, the maintainer's version, stays silent, which
is why this was invisible locally. Reproduced with a downloaded 0.10.0 binary:

```
In templates/substrate/install.sh line 1384:
kit_substrate_intended_hosts() {
^-- SC2120 (warning): kit_substrate_intended_hosts references arguments, but none are ever passed.
```

Fix: the two in-file call sites now pass `"$MANIFEST_DIR"` — the value the
default computed — so the condition SC2120 describes is false under every
version. Both 0.10.0 and 0.11.0 are clean on the result, and `bash -n` passes.

(A first draft of the comment began `# shellcheck's SC2120 …`, which ShellCheck
parsed as a malformed *directive* and failed with SC1072/SC1073 — caught by
running 0.10.0 on the change, reworded to `SC2120 (ShellCheck)`.)

## 2. the three-key control — a history gap, fixed at the checkout

`tests/substrate_test.sh`'s red control derives its fixture from history:
`git log -S KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL` finds the commit that
wired the fourth key, and the fixture is that commit's PARENT. In a depth-1
checkout the `-S` search answers with the boundary commit itself — whose diff
IS the whole tree — and its parent does not exist. Reproduced exactly in a
depth-1 clone of this repository:

```
$ git clone --depth 1 file://…/kit /tmp/kitshallow && cd /tmp/kitshallow
$ git log --format=%H -S 'KIT_SUBSTRATE_IDENTITY_OIDC_LOGIN_UI_URL' -- templates/substrate/install.sh | tail -1
03a7f768d709648939a4dcedbb0fabb6a1a497eb      # the boundary commit, same as CI's message
$ git show 03a7f768^:templates/substrate/install.sh
PARENT UNAVAILABLE
```

Fix: the `none` job's checkout carries `fetch-depth: 0`, with the reason in the
comment. The depth is NOT bounded smaller on purpose — the control cannot say
how far back its commit is, and a number that works today is a red that fires
the day history grows past it. In the full-history tree the same commands find
base `3e87cce` and a parent fixture with zero `OIDC_LOGIN_UI_URL` occurrences,
which is what the control requires.

## 3. the lint proofs' toolchains — a runner gap, fixed in the job

`tests/lint_test.sh` FAILS rather than skips when a linter is absent ("A
skipped lint proof is not a proof"), and the gate bootstraps only its `.venv`
tools (PyYAML, yamllint, hadolint). The go and ruby proofs exec `golangci-lint`
and `rubocop` against kit's own configs; the runner had neither.

Fix: the `none` job gains `actions/setup-go@v7` (`stable`, the same fallback
the go job uses) and a step that installs **golangci-lint v2.14.0** — the same
pin the go job's lint step names, so the two cannot disagree about which
linters are enabled — and `rubocop`, then prints both versions so the log
records what ran.

## Controls

- shellcheck 0.10.0 on the changed installer: **clean**; 0.11.0: **clean**;
  `bash -n`: pass. `tests/workflow_timeouts_check.sh`: pass (the new step is
  inside the already-bounded `none` job; no new `uses:` job).
- The full-history fixture derivation: base found, parent fixture carries zero
  `OIDC_LOGIN_UI_URL` — the shape the control asserts.
- `tests/substrate_test.sh` on this branch: **403 passed, 0 failed, 0 skipped**
  (the first run after the call-site change caught one fixture that matches
  `compute_readiness` verbatim — `check_node_only_red` — red with "could not
  find compute_readiness to replace"; the fixture's `old` block now carries the
  new call form, same file, and the re-run is green).
- The lint toolchain step itself is only provable on the runner; its versions
  are pinned to the value the go job already pins, and the step prints
  `golangci-lint version` and `rubocop --version` so a future drift is visible
  in the log rather than inferred.

## What was not done

- The `ci (kit: go) / go` job of a SERVICE is untouched. identity's is
  structurally red on arrival for its own documented reasons (its `test` step
  needs a Postgres a reusable workflow cannot host), and its 5 lint findings
  are one of several reds there — a packet that can also carry that job green
  should take them, not this one.
- No version pin was added for rubocop: kit names none today, the proof's
  assertions are written with `--only` so a new cops banner cannot color them,
  and inventing a pin here would be a second home for a number nothing else
  reads.
