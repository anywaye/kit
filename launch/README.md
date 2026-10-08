# The launch harness — Kit's developer-only four-service stack

> Kit owns this. `cafaye/website` does not carry launcher code, and the old
> `cafaye/site` launcher this is derived from is retired, not mirrored.

## What this is

A **developer-only** local bring-up for the four product services —
identity, gateway, courier, parlor — built from source checkouts on the
developer's machine, on Kit's pinned compose stack, with an SMTP sink
(mailpit) a person can read.

```
launch/
├── README.md                    # this file
├── docker-compose.launch.yml    # the overlay: four services + mailpit, nothing else
└── bin/launch                   # the bring-up: checks, secrets, mint, two phases, down
```

`docker-compose.launch.yml` is an **override** on Kit's stack, in exactly the
shape every service's own `docker-compose.yml` is: Kit ships the
infrastructure (one Postgres cluster, NATS with JetStream, Redis, the OTel
collector), and this file adds only what the launch needs — the four
services' images, ports and environment, the database list, and mailpit.
It redeclares nothing Kit ships. `bin/launch` layers it over the stack:

```
docker compose --project-directory launch/ \
  -f <kit>/templates/compose/docker-compose.yml \
  -f launch/docker-compose.launch.yml up -d --wait
```

## Commands

Run from anywhere inside the Kit checkout:

| Task | Command |
|------|---------|
| Bring the stack up | `launch/bin/launch` |
| Prerequisites only | `launch/bin/launch --check` |
| What is running | `launch/bin/launch status` |
| Stop, delete volumes (`.env` survives) | `launch/bin/launch down` |

## Repository layout

The four services are built from source, so their checkouts must exist.
Defaults assume the fleet layout — every service beside the Kit checkout:

```
cafaye/
├── kit/         # this repository
├── identity/
├── gateway/
├── courier/
└── parlor/      # the customer-stack app. NOT website: website is the
                 # Cafaye app derived from Parlor and is never built here.
```

Neither Website nor Site is required or consulted. Any layout works by
overriding the directories explicitly:

```
LAUNCH_IDENTITY_DIR=/path/to/identity LAUNCH_PARLOR_DIR=/path/to/parlor \
  launch/bin/launch
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `LAUNCH_IDENTITY_DIR` | `<kit>/../identity` | identity checkout (build context) |
| `LAUNCH_GATEWAY_DIR` | `<kit>/../gateway` | gateway checkout (build context) |
| `LAUNCH_COURIER_DIR` | `<kit>/../courier` | courier checkout (build context) |
| `LAUNCH_PARLOR_DIR` | `<kit>/../parlor` | parlor checkout (build context, the front door) |
| `KIT_STACK_DIR` | the Kit checkout itself | the stack to compose from |
| `LAUNCH_KIT_REF` | unset | when set, resolve this pin through `templates/bin/dev.sh live` instead |

The Kit stack defaults to **the checkout this file lives in** — no fetch, no
cache, no pin to keep in step when the harness itself changes. `LAUNCH_KIT_REF`
is the escape hatch for running the harness against a different Kit ref; it
is validated with the same pin-shape rule `bin/dev` enforces (40-char sha or
`v<semver>`, never a branch) and resolved by Kit's own `live` command, never
by a second copy of the resolution.

## Secrets

Generated into `launch/.env` (git-ignored, never committed), stable across a
teardown: `SIGNUP_SIGNING_KEY`, `MFA_ENCRYPTION_KEY`,
`COURIER_SECRET_BOX_KEY`, `COURIER_ERROR_RELAY_TOKEN`, `APP_BASE_URL`.
`COURIER_TOKEN` starts as a random placeholder so phase 1 boots, and is
**minted from identity's own API** after identity is ready, then rewritten —
the one value in the file that is replaced rather than kept. The OIDC signing
key is generated per run and exported, never written down.

## The two phases

The bring-up is two-phase because the courier key does not exist until
identity is up to mint it, and identity will not boot without the key:

1. `postgres + identity` up, bounded readiness poll on `/readyz`,
   identity's migrations from the host, mint the courier key (register →
   session → account → api-key, with the signup-timestamp pair aged past
   `signup.MinAge`).
2. `nats` up, the `cafaye` JetStream stream created by Kit's one-shot
   (`compose run --rm nats-stream-init`, bounded, required), then the full
   long-running set — explicitly named, never a blanket wait that would
   re-enlist the completed one-shot — plus courier's migrations inside its
   own container.

## What this is not

- **Not the customer installer.** `templates/substrate/install.sh` is the
  real installer (k3s, Argo, CloudNativePG, ACME, GHCR) and nothing here
  validates that path. This harness proves a developer can run the four
  services locally; it proves nothing about k3s, Argo sync, ACME issuance,
  GHCR pulls, or Cloudflare.
- **Not production.** Volumes are named, passwords are generated dev
  secrets, nothing leaves the loopback.
- **Not observed end-to-end by Kit's gate.** `tests/launch_test.sh` proves
  the harness's shape — layout validation, pin behavior, command
  construction, teardown safety, compose/schema invariants — with stubbed
  tools and no Docker daemon. Actually bringing the stack up needs the four
  sibling checkouts and is proven by a person or a disposable VM, never by
  this repository's gate.
