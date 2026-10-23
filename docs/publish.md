# Publishing without GitHub Actions

**One command publishes a service image + chart from any machine with docker.**
When GitHub Actions minutes are exhausted (measured 2026-10-15: `billing`
publish failed with “You have used 90% of the Actions minutes”), this is the
other path — and it produces the same bytes.

## Two paths, one registry

| when | how |
|---|---|
| Actions minutes exist | `templates/publish/publish.yml` → `anywaye/kit/.github/workflows/publish.reusable.yml@master` (`push: true`) |
| They do not, or you need to publish from a laptop / sandbox / other CI | `bin/publish` (or `templates/bin/publish.sh` copied as `bin/publish`) |

Both publish **two artifacts**:

* **Image** at `ghcr.io/anywaye/<service>:<tag>` (`tag` == `Chart.yaml` version, e.g. `0.1.0`) plus `sha-<git-sha>` — the tag the chart’s `values.yaml` pins (`image.tag`).
* **Chart** at `oci://ghcr.io/anywaye/charts/<chart>:<version>` — `helm package` then `helm push`. The OCI tag IS the chart’s `version`.

Argo CD’s `Application` pulls `oci://ghcr.io/anywaye/charts/<chart>` at
`targetRevision: <version>`. The version is never bumped by either path — the
chart’s **content** changes (the pinned `image.digest`) while the tag stays
`0.1.0`.

## The digest is derived, never typed

Both paths write the digest of the image they just pushed into the chart’s
`values.yaml` (`image.digest: "sha256:<64 hex>"`) **before** `helm package` — a
package is a tarball of the directory, so an edit after packaging pins nothing.
The digest comes from the push output (`docker push` or `docker buildx imagetools`),
is validated as `sha256:[0-9a-f]{64}`, and refused when malformed — exactly as
`chart.reusable.yml`’s “pin the image by digest” step does (replace-or-insert
under the `image:` block, one `digest:` line, `grep -c` check).

A digest cannot move; a tag can. The registry’s `ghcr.io/anywaye/gateway:0.1.0`
once held `sha256:c264…37165` while the node ran `sha256:8e60…e79b` for six hours
with Argo reporting `Synced` — the tag was overwritten, the Deployment was
textually identical, nothing rolled. A digest-pinned chart is a textual diff
Argo rolls.

## How to publish

### From any machine with docker + helm

```sh
# auth once, via stdin (never argv — a token in argv lands in history/logs)
echo "$GH_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
echo "$GH_TOKEN" | helm registry login ghcr.io -u USERNAME --password-stdin
echo "$GH_TOKEN" | gh auth login --with-token   # optional, for gh CLI

# dry-run prints every command, runs nothing
bin/publish --dry-run
bin/publish --dry-run --service-dir . --chart-dir chart

# real publish (service dir is build context, chart dir holds Chart.yaml)
bin/publish --service-dir . --chart-dir chart --image ghcr.io/anywaye/mygateway
# short form defaults: chart-dir=chart, image=ghcr.io/anywaye/<chart-name>, tag=Chart.yaml version
bin/publish --service-dir .

# multi-arch (workflow builds linux/amd64,linux/arm64)
# default is single-arch with a loud note naming the workflow default
bin/publish --platforms linux/amd64,linux/arm64
# single-arch requires no buildx; multi-arch refuses when buildx is absent
```

Flags: `--service-dir`, `--image`, `--chart-dir`, `--registry` (`oci://ghcr.io/anywaye/charts`),
`--tag` (default from Chart.yaml), `--git-ref` (default HEAD), `--platforms`, `--dry-run`.

Every network call is bounded (`timeout`/`gtimeout`): build 600s, push/package 300s.

### From an instabox sandbox (one command, idempotent, safe)

The manual precedent was a box named `anywaye-build`. This provisions or reuses
it, installs `helm v4.3.0` + `gh` if missing, and logs in — all idempotently
(a second run changes nothing and still works). Tokens via stdin, never argv,
never in logs.

```sh
# one command provisions the box (or reuses it), installs tools, prints ssh
bin/publish --sandbox --sandbox-name anywaye-build --dry-run
bin/publish --sandbox

# with a token piped — logs in inside the box, still via stdin
cat token.txt | bin/publish --sandbox

# then publish from inside
instabox ssh anywaye-build
bin/publish --service-dir .   # from inside the sandbox, with its docker+helm

# wrapper (same as --sandbox)
bin/publish-sandbox --help
cat token.txt | bin/publish-sandbox
```

The sandbox helper (`bin/publish-sandbox`, also `templates/bin/publish-sandbox.sh`)
is a thin wrapper around `bin/publish --sandbox`.

## The one manual step — visibility

GHCR packages are **private** by default, and no API call with a normal token
can flip visibility. A package created private needs its visibility flipped
**once**, in the browser. The publish script **reminds** (does not fail) with the
URL after a new package:

```
image: https://github.com/orgs/anywaye/packages/container/anywaye%2Fmyservice/settings
chart: https://github.com/orgs/anywaye/packages/container/anywaye%2Fcharts%2Fmyservice/settings

# also reachable as repo packages
https://github.com/anywaye/myservice/pkgs/container/myservice
https://github.com/anywaye/charts/pkgs/container/charts%2Fmyservice
```

Open it, set to **Public** (or Internal), done. Existing packages need no step.

## What the script checks

* `docker` + `helm` + `git` must exist — refused by name with install commands.
* Auth must exist — refused with `docker login ... --password-stdin` /
  `helm registry login ... --password-stdin` / `gh auth login --with-token`,
  never falls back to unauthenticated push.
* `Chart.yaml` must have `name:` and `version:` — refused by name.
* `values.yaml` must exist — refused; if it has no `image:` block it is
  packaged as committed with a Step Summary note (same as the workflow).
* Digest must be `sha256:[0-9a-f]{64}` — refused when malformed or with the
  wrong count of `digest:` lines.

## Fleet copy

```sh
cp kit/templates/bin/publish.sh myservice/bin/publish && chmod +x myservice/bin/publish
cp kit/templates/bin/publish-sandbox.sh myservice/bin/publish-sandbox && chmod +x myservice/bin/publish-sandbox
```

Keep them executable; `tests/validate.sh` checks `templates/bin/*` is executable
and `shellcheck -S warning` clean.

## Exact manager commands (from a clean machine)

```sh
git clone https://github.com/anywaye/kit.git
git clone https://github.com/anywaye/<service>.git
cat token.txt | docker login ghcr.io -u USERNAME --password-stdin
cat token.txt | helm registry login ghcr.io -u USERNAME --password-stdin
# service has Chart.yaml version 0.1.0, values.yaml with image: block, Dockerfile
kit/bin/publish --dry-run --service-dir ./<service>
kit/bin/publish --service-dir ./<service> --image ghcr.io/anywaye/<service>
# if image already exists anonymously and only chart needs pushing:
# kit/bin/publish still builds+pushes image to derive digest; chart digest matches.
# For a sandbox instead of local docker:
cat token.txt | kit/bin/publish --sandbox --sandbox-name anywaye-build
instabox ssh anywaye-build   # then kit/bin/publish --service-dir ./<service>
```
