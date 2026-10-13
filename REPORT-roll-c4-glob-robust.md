# roll-c4-glob-robust — a macOS-shipped substrate tree made the installer apply AppleDouble files

Branch `roll/c4-glob-robust`, worktree `wt/roll-c4-glob-robust`, repo `cafaye/kit`.
Commit: `fix(substrate): apply only the manifests we ship — a macOS AppleDouble
sidecar killed the install`.

## The defect, measured

`kubectl apply -f <dir>` does not read "the manifests"; it reads every regular
file the directory holds, **dotfiles included**. A macOS workstation that shipped
the substrate tree with the idiom an operator reaches for —

```sh
tar czf - . | ssh box 'tar xzf -'
```

— left AppleDouble sidecars beside every real file (`._identity.yaml` beside each
Application). Step 6 handed the sidecar to the API server and the install died on
the first one:

```
error parsing /var/lib/cafaye/substrate/manifests/applications/._identity.yaml:
error converting YAML to JSON: yaml: control characters are not allowed
```

`COPYFILE_DISABLE=1 tar --no-xattrs` reduces the sidecars but does not remove the
**class**: a Windows copy, an editor's `foo.yaml~` backup or a `.DS_Store` is the
same defect from another transport.

## The fix, per apply site

A new pair of helpers above `install_applications` in `templates/substrate/install.sh`:

- `kit_substrate_check_manifest_dir <dir>` — walks *every* entry (plain names,
  leading single dot, leading double dot), **ignores and names** `._*` AppleDouble
  debris through `kit_substrate_out`, and **refuses by name** anything else the
  directory holds.
- `kit_substrate_manifest_files <dir>` — runs the check, then sets the global
  `KIT_MANIFEST_FILES` to the intended `"$dir"/*.yaml` files (bash's `*` already
  skips a leading dot; the check makes that exclusion explicit), and refuses when
  the directory holds no manifest at all.

The filter is the **glob read from the directory**, not an enumerated allowlist —
there is no second filename list to drift from the directory.

| Apply site | Before | After |
|---|---|---|
| step 6 `install_applications` | `kubectl apply -f "$MANIFEST_DIR"` | `kit_substrate_manifest_files` + `apply -f <file>` for each resolved file |
| step 7 `install_cluster_issuers` | `sed … "$TLS_DIR"/*.yaml \| apply -f -` | `kit_substrate_manifest_files` then `sed … "${KIT_MANIFEST_FILES[@]}" \| apply -f -` |
| step 8 postgres Cluster | `apply -f "$DATA_DIR/postgres-cluster.yaml"` | applied by name (already deliberate) + `kit_substrate_check_manifest_dir "$DATA_DIR"` |
| step 9 Redis | `apply -f "$DATA_DIR/redis.yaml"` | applied by name + the directory check |
| step 10 NATS | `sed … "$DATA_DIR/nats.yaml" \| apply -f -` | applied by name + the directory check |

The reason — including the measured AppleDouble error — is written at the code
site (`install.sh` lines 991–1082), not just here.

## The two red controls

`tests/substrate_test.sh` §14. The mock kubectl's `apply` branch now **reads** what
`-f` names (a file, or every dotfile in a directory) and refuses a NUL-bearing file
with the exact error the box reported — so a control cannot pass on a mock that
never looked.

- **RED control #1 — a stray non-sidecar YAML is refused by name.** The tree holds
  `identity.yaml`, `._identity.yaml` and a stray `stray.yml`. The step must fail and
  the refusal must name `stray.yml` and *not* mention `control characters` (so the
  red is the stray-file check, not the sidecar). **Watched red:** removing the
  `unexpected` refusal (fixture mutated to `if false`) makes the step silently
  succeed and the control reports *"the step applied a directory holding a stray
  file"* — verified: `STRAY-TREE ec=0 → stray_refused FAIL-red`.
- **RED control #2 — the glob filter removed lets AppleDouble break the apply
  again.** A one-line `sed` changes the helper's loop to read every entry
  (`"$dir"/* "$dir"/.[!.]* "$dir"/..?*`), exactly the pre-fix directory apply. The
  step must now fail with the control-characters error. The control first asserts
  its own premise (`cmp` shows the mutation changed the file; the mutated loop is
  present). **Watched red:** this control passed only after the mock was made to
  really read the files — earlier, before that, it reported *"the sidecar was
  applied without breaking"* (the exact false-pass the mock exists to prevent).
  Mutating the *filter* the other way (`"$dir"/*.yaml "$dir"/._*`, admitting the
  sidecar) makes the **green** AppleDouble test go red — verified:
  `GOOD-TREE ec=1 → apple_double_ok FAIL-red`.

The green proof: a tree carrying `._identity.yaml` **and** `._gateway.yaml` beside
`identity.yaml`/`gateway.yaml` applies cleanly; only the two real manifests reach
kubectl; the sidecar is named in the output and never appears in the applied
bytes.

## Counts

- Before: `174 passed, 0 failed, 0 skipped`.
- After: **`179 passed, 0 failed, 0 skipped`** (+5: 2 premise checks, 3
  green/control checks).

## Transport note (the runbook half)

There is **no runbook in the repo that ships the tree** (the normal path is `curl
https://cafaye.com/box/install | sh`, served by `kit-install.mjs`; a checkout path
runs `install.sh` in place), so nothing contradicted the fix. The note was added
to `templates/substrate/README.md` § "Shipping the tree to a box from a macOS
workstation":

```sh
COPYFILE_DISABLE=1 tar --no-xattrs -czf - . | ssh box 'tar xzf -'
rsync -a --exclude '._*' --exclude '.DS_Store' ./ box:/var/lib/cafaye/substrate/
ditto -c -k --norsrc --noextattr . - | ssh box 'ditto -x -k --norsrc - /var/lib/cafaye/substrate'
```

`COPYFILE_DISABLE=1` stops BSD `tar` writing the sidecars; `--no-xattrs` drops
extended attributes; `ditto --norsrc --noextattr` and `rsync --exclude` are the
equivalents. The installer no longer depends on the operator getting this right,
but the note is the runbook half of the packet.

## What I deliberately did NOT do

- **No `kubectl apply -f dir --recursive`, and no glob that admits `._*`.** The
  filter is `*.yaml` plus an explicit AppleDouble exclusion and an
  unexpected-entries refusal.
- **No `|| true` around any apply.** The tests prove a failing apply kills the
  step (the mock wrapper makes it fatal, because a subshell on the left of `||`
  suppresses `set -e`).
- **No enumerated filename allowlist** for `applications/` (a list that drifts
  from the directory is its own bug). Only the extension and the AppleDouble
  class are conventions, and both are enforced.
- **`data/`'s single-file applies stay named-file applies** — they are deliberate
  by construction; the check added there is over the *directory*, so a stray file
  beside the named file is surfaced. I did not route them through
  `kit_substrate_manifest_files` (that would mean applying the directory).
- **`.yml` is not admitted.** Manifests are `*.yaml`; a `.yml` file is an
  unexpected entry and is refused by name (this is what makes red control #1 a
  *non-sidecar YAML* control).
- **I did not touch `validate.sh`, the cluster tiers, `.github/workflows/`, or any
  other repo**, and I did not run `validate.sh`. The narrow gate was
  `bash tests/substrate_test.sh`, `bash -n`, and `shellcheck -S warning` on both
  files (all clean).
- **One existing control was re-pointed, not weakened.** `check_apply_modes`'s
  "a local apply carrying the remote flags goes red" control used to `sed` the
  literal `apply -f "$MANIFEST_DIR"`, which no longer exists; it now grows the
  flags on the Cluster apply — another local `-f "$…"` apply. The rule it proves
  is unchanged.
