# roll-c4-patchfile — `kubectl patch --patch-file=-` does not read stdin

**Branch:** `roll/c4-patchfile`, cut from current master. Two commits:

```
f733251 docs(changelog): the --patch-file=- defect, its /dev/stdin fix, and the mock retaught
a8db35d fix(substrate): read every `kubectl patch` from /dev/stdin, and teach the mock the real convention
```

## The defect, and why the suite was green over it

`kubectl` has **no `-` stdin convention for `--patch-file`**. It opens a file
literally named `-` and dies before the request is built, so the sibling
packet's step-8 username reconcile and step-11's two credential patches never
reached the API server on any box:

    error: unable to read patch file: open -: no such file or directory

`tests/substrate_test.sh` was green because **both** mocks modelled `-` as
stdin (`-) body="$(cat)"`). The witness and the subject disagreed, which is the
class of defect this packet is about.

## 1. The convention sweep

`grep` for `patch-file`, `/dev/stdin`, `-f -`, `--filename`, and `-o -` across
`templates/substrate/install.sh`:

| spelling | sites | verdict |
|---|---|---|
| `--patch-file=-` | 3 (step 8 line ~1327; step 11 lines ~2062, ~2065) | **NOT a kubectl convention — fixed** |
| `apply -f -` | 8 (lines 803, 1044, 1061, 1264, 1409, 1690, 1877, 1883) | **a real convention — left alone** |
| `--from-file=.dockerconfigjson=/dev/stdin` | 1 (step 5, line 1060) | the repo's existing convention — reused |
| `--filename` | 0 | — |
| `-o -` | 0 | — |

All three `--patch-file=-` sites became `--patch-file=/dev/stdin`, each with a
one-line reason at the code site. The remaining `--patch-file=-` strings in
`install.sh` and `substrate_test.sh` are **only in comments explaining why it is
wrong**, plus the mock's error case.

A lexical sweep of the whole repo found two other mentions, both prose:
`CHANGELOG.md` (corrected, see below) and
`REPORT-kit-w2p4-secret-input-surface.md` (a point-in-time record — left as
written; see "Did NOT do").

## 2. The mock, before and after, with the real error

Extracted `mock_kubectl` from `HEAD~1` and `HEAD` and drove the two spellings
against one store:

```
=== BEFORE (HEAD~1: the mock that was green over the defect) ===
  --patch-file=-          -> ACCEPTED (read '-' as stdin), stored=new
  --patch-file=/dev/stdin -> ACCEPTED, stored=new
=== AFTER (HEAD: the mock that models kubectl) ===
  --patch-file=-          -> REFUSED: error: unable to read patch file: open -: no such file or directory
  --patch-file=/dev/stdin -> ACCEPTED, stored=new
```

Both mocks were retaught: `mock_kubectl` (step 8) and `rollout_kubectl` (step
11). Each now reads `/dev/stdin` from the pipe and refuses `-` with the **exact
byte-for-byte** message above.

Live confirmation, local `kubectl v1.33.9` (the read error is client-side, so
this touches no object; run against a nonexistent Secret so even the second
invocation cannot write):

```
$ echo '{"metadata":{"annotations":{"probe":"1"}}}' | kubectl patch secret \
    __kit_probe_nonexistent__ -n default --type=merge --patch-file=-
error: unable to read patch file: open -: no such file or directory   # exit 1

$ echo '{"metadata":{"annotations":{"probe":"1"}}}' | kubectl patch secret \
    __kit_probe_nonexistent__ -n default --type=merge --patch-file=/dev/stdin
Error from server (NotFound): secrets "__kit_probe_nonexistent__" not found
```

The second line is the proof that `/dev/stdin` reads the body and builds the
request; the only failure is the deliberately nonexistent Secret. No Contabo
context is configured on this machine (`kubectl config get-contexts` shows only
`k3d-cafaye-local`), so the box's own measurement is quoted from the packet.

## 3. The red controls (five new cases, all green here and red on the defect)

- `the step-8 mock reads --patch-file=/dev/stdin and refuses - as kubectl does`
  — direct: one store, both spellings, asserts the exact error string and that
  `/dev/stdin` merged.
- `control: the - patch spelling the real kubectl refuses goes red` — reverts
  step 8's spelling in a fixture and runs `check_rerun_repairs_username`; the
  mock refuses, `set -e` aborts, the check goes red. The fixture asserts its own
  premise (`-` present, `/dev/stdin` absent) before it is used.
- `the step-11 mock reads --patch-file=/dev/stdin and refuses - as kubectl does`
  — the same direct check against `rollout_kubectl`, so the two mocks cannot
  diverge.
- `step 11 writes one minted value into both secrets through /dev/stdin` — the
  green half for the mint.
- `control: the - patch spelling aborts the mint, as it does on the box` — the
  same mint against the reverted fixture; it aborts on the mock's refusal.

Plus item 3 of the brief: `check_rerun_repairs_username` (already present from
the sibling) is green, asserting the existing Secret is pinned to the role's
spelling **before** the Cluster's guard runs (`control: a reconcile behind the
cluster guard never repairs a re-run` remains its red half). I added one
assertion to it: the repair must have **travelled** on a
`--patch-file=/dev/stdin` patch, read back from the mock's recorded argv — a
store that changed by some other route would pass the username check and still
not be the path the box ran.

## 4. Suite counts

- `tests/substrate_test.sh`: **210 passed, 0 failed, 0 skipped** (baseline on
  the branch was 205 — five new cases).
- `bash -n templates/substrate/install.sh`: clean.
- `shellcheck -S warning tests/substrate_test.sh templates/substrate/install.sh`:
  clean.
- Broader gate, `bash tests/validate.sh --no-observability`: **1 failure, and it
  is pre-existing and not mine** — `every run: body (no name is prefix-assigned
  and then read as a variable)` in `.github/workflows/image.reusable.yml`
  (`tags`), which exists unchanged at `HEAD~1` and is in a path the brief
  forbids touching. Every substrate static check passed, including `bash -n`,
  `shellcheck -S warning`, and `tests/substrate_test.sh` itself. 8 environment
  SKIPs (rustc absent, SQL parsed elsewhere, TypeScript needs a type-stripper).

## 5. What I deliberately did NOT do

- **Did not change `kubectl apply -f -`** — it is a real convention (step 6 and
  the pull secret use it).
- **No `|| true`, no fallback to `-p` on argv, no "try both".** The patch stays
  on the pipe; the set-e abort is what the box does.
- **Did not touch `.github/workflows/`** (or the other repo's pre-existing
  `image.reusable.yml` failure), and did not push, merge, or spawn an agent.
- **Did not rewrite `REPORT-kit-w2p4-secret-input-surface.md`.** It records that
  packet's state and says `--patch-file=-`; it is a point-in-time report, not a
  living spec. The living `CHANGELOG.md` clause was corrected (both are under
  `## Unreleased`, so the release never shipped the wrong spelling) and a new
  bullet added.
- **Did not add `--filename`/`-o -` handling** — neither appears anywhere.
- **Did not run the observability/live tiers** (`--no-observability`), which are
  unrelated to a shell spelling.
