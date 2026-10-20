# `templates/deploy/` — the one deployment the other eight copy

## What this is, and what it is not

**This is a production-shaped deployment that runs on a local Docker daemon.**

It is not a remote deployment. It is not deployed to production. It has no
domain, no TLS termination, no reverse proxy, no multi-host scheduler, and no
real credentials — this machine has none and this packet could not obtain any
without spending money or asking a human for access it will not get. Every
sentence in this repository that says "deployed" means *deployed to the local
Docker daemon on the machine it ran on*. The `tests/deploy_test.sh` proofs are
real: the containers really start, the health gate really goes red when the
database is stopped, the rollback really changes the image the service is
running. What is missing is a remote host, and only that.

Calling this "production" would be the single most likely way this packet
produces something dishonest, so it is stated in the first line of this file,
in the first line of `REPORT-kit-16-deploy`, and in the tool's own header
comment rather than being discovered on page nine.

### Why `courier` is the reference service

`courier` is Elixir/Phoenix. Its gate is green and declared in `gate.yml`
(535 tests at `35c6a27`). It already has the two things a reference deployment
needs and that no other service in the fleet has:

- a **release build** with its own start and migrate binaries, so the artifact
  a deploy ships is a self-contained image rather than a source tree; and
- a **readiness endpoint that really checks its database** — `GET /readyz` runs
  `SELECT 1` and answers 503 when Postgres is stopped, while `GET /healthz`
  answers 200 regardless. Most services in this fleet have nothing yet that
  could go red.

The argument for choosing it is not that it is the most representative service.
It is that a template shaped by the *best* story in the fleet is the one least
likely to mislead the other eight. A template written against the weakest story
would be a template that misfits eight of nine.

`caf` was considered and **rejected deliberately**. `caf` is the platform's own
resource-reclamation service, so a bug in its deploy path carries the authority
to destroy shared Docker state on a machine where other people and other
projects have containers running. Proving the pattern on the service least able
to survive a bad deploy would be a strange choice even if `caf` were otherwise
a good candidate.

## The shape

| File | What it is |
|------|------------|
| `compose.deploy.yml` | The distribution shape. A real, runnable file — every value is a compose substitution, not a placeholder. |
| `entrypoint.sh` | The secret gate. A POSIX `sh` script every service runs as its entrypoint. |
| `redact.py` | The log redactor. Every line the tool prints goes through it. |
| `reference/courier.deploy.yml` | The worked example, and the thing this packet actually ran. |

The tool is `templates/bin/deploy.sh`, next to `dev.sh` — the other script kit
hands out.

```
deploy up       --service courier --file <compose file> [--secrets-fd 3]
deploy verify   --service courier --file <compose file>
deploy rollback --service courier --file <compose file>
deploy status   --service courier --file <compose file>
deploy down     --service courier --file <compose file> [--purge]
```

`up` takes its credentials on an **inherited file descriptor** and refuses
every other input, including a path:

```sh
SERVICE_NAME=courier KIT_DEPLOY_IMAGE=cafaye-kit16/courier:35c6a27 \
  3< <(vault read -format=json ... | jq -r 'to_entries[]|"\(.key)=\(.value)"') \
  templates/bin/deploy.sh up --service courier \
    --file templates/deploy/reference/courier.deploy.yml --secrets-fd 3
```

## 1. Credentials

The platform's rule is absolute: never plaintext at rest, never logged, never
in a config file, never in a fixture, never in an error message. A deploy is
the most likely place in the system to break it, because deploy tooling prints
its own configuration for a living.

Four mechanisms, in the order they are consulted:

1. **Never in argv, never in the environment, never from a path.** `deploy`
   has no `--secrets-file`. Its only input is an inherited descriptor, because
   `ps` shows argv to every user on the machine and a shell keeps it forever.
2. **Never in the container's configuration.** Anything in a compose
   `environment:` block is printed verbatim by `docker inspect` and by
   `docker compose config`. The credentials are therefore not there. They are
   delivered into a **tmpfs** — RAM, per container, destroyed with the
   container — through the container's own **stdin**, or over the Docker API
   with `docker cp` for images that have no shell.
3. **The barrier.** The container starts and the application does **not**.
   `entrypoint.sh` waits for `/run/secrets/.loaded`, which the tool creates
   only after every claimed secret is in place, and exits non-zero if it never
   arrives. A service that boots without its database URL fails like a bad
   release; a service that waits and says "no secrets within 30s" is
   diagnosable.
4. **The redactor.** `redact.py` filters everything the tool prints —
   `docker inspect`, `docker compose config`, migration output, the health
   gate's own messages. It has two layers: the exact values it was given, and
   **shape**, because a filter that only knows its own inputs is defeated by
   anything it did not already hold. A JWT, a bearer token, an AWS key, a
   provider key, a GitHub token, a connection URL with a password, a PEM
   header, and any `*password*|*secret*|*token*|*api_key*` assignment are all
   masked by shape. The name survives (`[redacted:jwt]`) so the log still says
   *which kind* of credential was in play.

### What this does not buy, stated plainly

- A process **inside** the container can still read the credentials from
  `/run/secrets` and from `/proc`. A compromised application is compromised.
  The claim is that the credential never reaches an **artefact a human or a CI
  job can read** — a log, a config file, an image layer, `docker inspect`, the
  host disk.
- The files are mode `0444` rather than owned by the service account, because
  the deploy tool cannot resolve the service uid portably across nine language
  runtimes. `umask 077` creates them owner-only and they are then made
  readable. On a real target with a real secret provider this becomes
  `0400` owned by the service account, and the app reads the file rather than
  an exported variable — courier's `config/runtime.exs` reads
  `System.get_env/1` and would need a one-line change for that. **That change
  is courier's to make, not kit's, and it has not been made.**

## 2. Health checks that can go red

Every service in the deploy file declares a healthcheck, and `deploy up` does
not report success until Docker reports that container `healthy`. That is not
the same as a check that can fail, so `tests/deploy_test.sh` proves it can:

- `GET /readyz` returns 200 with the database up;
- the database is stopped, and `/readyz` is watched going **503**;
- the container healthcheck is watched going **unhealthy**;
- `deploy verify` is watched exiting **non-zero**;
- `GET /healthz` is watched staying **200** — liveness consults nothing,
  because a liveness probe that fails on a dependency turns a database blip
  into a crash-restart loop and destroys the evidence needed to diagnose it;
- the database comes back and all three go green again.

The same "prove it can go red" rule the rest of this project applies to its
own checks applies here, and a control that ships red without anyone saying so
is what this repository has already rejected once.

## 3. Rollback

Not a paragraph about how one might roll back.

- Every deploy records its image tag and digest in a **ledger** before the new
  container starts. The ledger holds image references and **no secrets and no
  configuration** — it answers exactly one question, "what was running before
  this".
- `deploy rollback` reads the previous entry and runs **the same deploy code
  path** with a different tag, including the same health gate. A rollback
  implemented as a second code path is a rollback that was never tested by the
  fact that deploys work.
- `deploy up` **rolls itself back** when the deploy cannot go green, so a failed
  deploy does not leave a broken version quietly replacing a working one. This
  is **executed, not asserted**: `tests/deploy_test.sh` §6b deploys a one-layer
  derivative of the good image with `/app/bin/migrate` removed — good and bad
  differ by exactly the thing under test, so a passing rollback could not pass
  by accident — and asserts a non-zero exit, that the deploy *said* it was
  rolling back, that it did not report a failed rollback, that the previous
  artifact's image reference is serving again unprompted, and that the ledger
  never recorded the broken artifact as a success.
- Measured on the reference: the container is `running` again and `/readyz`
  answers 200 **within the same `wait_healthy` deadline the deploy itself
  used** — in this packet's runs, single-digit seconds, because both artifacts
  are the same image and only the tag differs. The time is printed by the tool
  (`ROLLBACK: healthy on the previous artifact after Ns`) rather than asserted
  here, so a real measurement is never a stale number in a document.

## 4. Not touching state that is not ours

Every container, network and volume is named by the compose project, which
defaults to `kit-deploy-<service>`. `deploy down` is scoped to that project by
construction. **There is no `docker system prune`, no `docker volume prune` and
no unprefixed `docker rm` anywhere in the tool or its tests.** A machine with
other people's `searxng-*`, a `p07-*` stack, a `kit-stack-*` stack and the kamal
buildkit in it is the normal case here, not an edge case.

That is asserted **by execution rather than by reading the source**, which is the
only kind of assertion this project trusts. `tests/deploy_test.sh` §9 creates a
container and a volume that belong to nothing else, names them outside the
compose project, and asserts both **survive `down` and `down --purge`**. It goes
red if `cmd_down` grows a prune or an unprefixed `docker rm`. The same section
asserts that a plain `down` keeps the volume, that `--purge` removes it, and
that **`down` removes the ledger** — a ledger that outlives its stack points the
next rollback at an artifact whose database volume no longer exists.

## 5. Polyglot: where the nine languages genuinely differ

**This is the part a single template cannot do, so it is a table and not a
template.** Seven Dockerfiles ship in `docker/`; the facts below are read from
those files, and the two marked *verified* were measured by running the image.

| | Runtime image | App user | Shell in the image? | `curl`? | Health probe from inside | Start command | Migrations |
|---|---|---|---|---|---|---|---|
| **go** | `gcr.io/distroless/static-debian12:nonroot` | `nonroot:nonroot` (numeric) | **no** *(measured)* | no | exec-form only — see below | `/app/service` | none by default |
| **rust** | `gcr.io/distroless/static-debian12:nonroot` | `nonroot:nonroot` (numeric) | **no** *(measured)* | no | exec-form only — see below | `/app/service` | none by default |
| **ruby** | `ruby:<v>-slim` | `app` | yes | no *(measured — see (b))* | `ruby -rnet/http -e` | `bin/rails server -b 0.0.0.0` | `bin/rails db:migrate` |
| **python** | `python:<v>-slim` | `app` | yes | no *(measured on `python:3.13-slim`)* | `python -c 'import urllib.request…'` | `/app/.venv/bin/python -m app` | framework / Alembic |
| **node** | `node:<v>-slim` | `node` | yes | no *(measured — see (b))* | `node -e 'fetch(…)'` | `node dist/main.js` | varies (Prisma, Knex, TypeORM) |
| **bun** | `oven/bun:<v>-slim` | `bun` | yes | no *(measured — see (b))* | `bun -e 'await fetch(…)'` | `bun run src/index.ts` | varies |
| **elixir** | `elixir:<v>-otp-<otp>-slim` | `app` | yes | **not in kit's Dockerfile** | `curl` — courier's own Dockerfile installs it *(measured)* | `/app/bin/app start` | `/app/bin/migrate` |

"*(measured)*" means run against the real image on this machine, not read from a
tag name. One image was pulled and probed per distinct base — `gcr.io/distroless/
static-debian12:nonroot`, `python:3.13-slim` (the pin in `docker/Dockerfile.python`),
`postgres:17-alpine`, and courier's own release image. The other `-slim` rows
share `debian:<trixie>-slim` and are marked as inheriting that measurement rather
than as individually verified. Anything not measured is not claimed here.

### The three differences that actually bite

**(a) `distroless` has no shell, so the secret gate cannot be a shell script.**
`docker/Dockerfile.go` and `docker/Dockerfile.rust` are
`gcr.io/distroless/static`. `entrypoint.sh` is a shell script, so it cannot be
mounted into those images at all. The tool handles this by **asking the
container** rather than the operator: `container_has_shell` tries one `docker
exec`, and when there is no shell it switches transport to a tar streamed over
`docker cp`, which moves bytes over the Docker API instead of exec'ing
anything. The `.loaded` barrier becomes an extra tar member, so a distroless
service gets the identical guarantee.

*Measured, and the measurement is the interesting part.* A stock distroless
image contains no **process** at all — `docker run` on it fails with `no command
specified`, so a running container cannot even be made to test against without
adding a binary to it. A real go or rust service image is distroless *plus* a
static binary, so the probe image was `FROM
gcr.io/distroless/static-debian12:nonroot` with busybox copied in as a bare
`/busybox` — deliberately **not** as `/bin/sh`. That gives a running container
with a process, a tmpfs and no shell, which is the only combination that
exercises this path. Against it, using the tool's own functions verbatim:
`container_has_shell` correctly answered *no shell*; `tar_stream` produced a
one-member tar with mode `0444`; `docker cp -` delivered it into the tmpfs; the
`.loaded` member landed; `docker cp` back out read the value; and `/bin/sh` was
genuinely absent from the image rather than merely unwritable. The container's
`Config.Env` held no credential throughout. The probe image was removed
afterwards.

**(b) A `CMD-SHELL` compose healthcheck needs a shell, and a `curl` healthcheck
needs `curl`.** These are two different requirements and only one of them is
satisfied by the slim runtimes:

- **a shell: present.** *Measured on `python:3.13-slim` — `/bin/sh -> dash`.* The
  other three slim tags are the same `debian:<trixie>-slim` base, so
  `CMD-SHELL` works for ruby, python, node and bun.
- **`curl`: absent.** *Measured on `python:3.13-slim` — neither `curl` nor
  `wget` is installed.* So the healthcheck in `compose.deploy.yml` is written
  with `curl` **because courier's own Dockerfile installs it deliberately**
  *(measured: `/usr/bin/curl`, no `wget`, and `/bin/sh -> dash`)*, and the other
  eight must each use their own runtime's HTTP client or add the probe tool to
  their image.

The database is the worked example of getting this right by accident rather than
by design. `postgres:17-alpine` ships busybox, so it has `wget` — and no `curl`
*(both measured)* — which means an HTTP-shaped probe would be the wrong tool
there anyway: what a database has to answer is "do I accept connections", and
`pg_isready` is the one binary in that image that says so. For `go` and `rust`
there is no shell either, so the healthcheck must be exec-form:

```yaml
healthcheck:
  test: ["CMD", "/app/service", "healthcheck"]
```

which requires the service to implement a `healthcheck` subcommand that exits
non-zero when it is not ready. That is the honest answer for a distroless
service: **there is no way to probe it from inside without either a shell or a
subcommand the service itself provides.**

**(c) None of kit's seven Dockerfiles declares a `HEALTHCHECK`.** The health
signal in this packet comes from the compose file. A service that wants the
signal to survive being run without compose needs the `HEALTHCHECK` line added
to its own Dockerfile, and for `elixir` that means adding `curl` to the image
first.

### And the one that is genuinely per-service

Migrations. `bin/rails db:migrate`, `manage.py migrate`, `/app/bin/migrate`
(which runs `Courier.Release.migrate/0`), and **nothing at all** for a Go or
Rust service that owns no schema. It is a `kit.deploy/migrate` label on the
service rather than a rule in the tool, precisely because a rule here would be
wrong for at least four of the nine.

## Copying this to another service

1. Copy `templates/deploy/compose.deploy.yml` to the service repo.
2. Set `SERVICE_NAME` and `KIT_DEPLOY_IMAGE`; set `KIT_APP_CMD` to the
   service's start command.
3. List the service's secrets on a `kit.deploy/secrets` label. The tool
   **refuses the deploy** if a supplied secret is claimed by nobody — a secret
   nobody claims is almost always a typo, and its failure mode is a deploy
   that reports itself green and fails on the first real request.
4. Set `kit.deploy/migrate` if it has a schema, and `kit.deploy/probe-url` to
   a **readiness** endpoint that exercises a dependency rather than reporting
   that the process is up.
5. If the image has no shell, nothing else changes: the transport is detected.
   If the image has no `curl`, write the healthcheck in the runtime's own
   client.

## What this does not cover, and what a real target needs

- **A real secret provider.** `tmpfs` + stdin is the honest local mechanism.
  A real target wants Swarm secrets, ECS secrets, Kubernetes secrets or
  `sops`+`age`, all of which deliver a file the service account owns. The
  application should then read `/run/secrets/NAME` and never have the value in
  its environment at all.
- **A real scheduler.** `restart: unless-stopped` is Docker's, not an
  orchestrator's. One bad deploy takes out one container here; on a real
  target the blast radius is one replica.
- **Secret re-delivery on restart.** Because `/run/secrets` is a tmpfs, it is
  **empty again every time a container restarts**, so a restarted container
  comes back **blocked at the credential gate** rather than serving with no
  database URL. `deploy up` re-delivers on every invocation, which makes
  re-running a deploy a repair rather than a no-op. On a real target the
  orchestrator re-injects secrets on every start and none of this is manual —
  and that is exactly why the secret store cannot simply be a file on disk,
  where "it worked until it restarted" is the failure mode you would get.
- **`docker exec` does not inherit PID 1's environment.** Anything run inside a
  deployed container — a migration, a debug shell — has to load `/run/secrets`
  itself or it will see no credentials while the service is perfectly healthy.
  `deploy`'s `run_with_secrets` does this; anything else that execs in must too.
- **`docker kill` does not trigger `restart: unless-stopped`** on Docker 29.4.0
  / OrbStack (measured with a stock `alpine sleep 300`: `exited`,
  `RestartCount 0`). A genuine crash does restart it (also measured). So to
  exercise the policy, make the process exit on its own — kill PID 1 *from
  inside* the container.
- **TLS and a hostname.** `ports:` here is bound to `127.0.0.1`; a real target
  terminates TLS at a proxy and does not publish the port at all.
- **Image provenance.** The tool deploys a tag. It does not build, sign or
  verify an artifact — `docker build` is a separate step and the tag is the
  contract. There is no SBOM, no signature and no digest pinning here.
- **Zero-downtime.** There is one replica and `compose up -d` replaces it, so
  there is a gap between the old container stopping and the new one passing its
  gate. A real target runs overlapping releases and drains the old one.
