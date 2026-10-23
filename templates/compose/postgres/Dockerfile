# kit template — the shared Postgres cluster image, with pgvector.
#
#   docker build -f templates/compose/postgres/Dockerfile \
#     --build-arg POSTGRES_TAG=17 --build-arg PGVECTOR_TAG=17-0.8.6 -t kit-postgres .
#
# WHY THIS IS A Dockerfile AT ALL, AND WHY IT LIVES HERE RATHER THAN IN `docker/`.
#
#   `docker/Dockerfile.{lang}` is the SERVICE image: one of the four artifacts
#   every adopting repository inherits, keyed on its declared `language`. This
#   file is not that. The cluster is shared, so it is identical for every
#   service in every language, and a file keyed on language is the wrong shape
#   for something that must not vary. It also travels with the FETCHED stack
#   rather than being copied, which is the second reason it is not in `docker/`.
#
# WHY IT IS NOT `postgres:17-alpine`, WHICH IS WHAT THE STACK USED TO PIN.
#
#   Measured, because this is the kind of decision that reads like a preference
#   and is in fact a hard constraint. pglayers publishes each extension as a
#   layer built from the PGDG **Debian** packages, so it is glibc-linked.
#   Copying it onto the alpine (musl) base produces an image that builds
#   cleanly — the COPY succeeds — and then fails at run time:
#
#     $ docker exec … psql -c 'CREATE EXTENSION vector;'
#     ERROR:  extension "vector" is not available
#     $ ldd /usr/lib/postgresql/17/lib/vector.so
#     Error loading shared library ld-linux-aarch64.so.1: No such file
#     Error relocating …/vector.so: palloc0: symbol not found
#
#   Two independent failures, either of which is fatal: the musl loader cannot
#   resolve a glibc binary, and alpine's PostgreSQL looks for extensions under
#   /usr/local/share/postgresql/extension while pglayers writes them to
#   /usr/share/postgresql/17/extension. On the Debian base the same image
#   reports pgvector 0.8.6 and answers a real query:
#
#     postgres:17  ->  CREATE EXTENSION vector;  ->  '[1,2,3]'::vector <=> '[1,2,4]'::vector < 1  ->  t
#     postgres:17-alpine -> never gets that far
#
#   So the cluster image is Debian-based. That is a real cost — the Debian base
#   is larger than alpine — and it is paid deliberately, because the alternative
#   is an image that claims pgvector and does not have it.
#
# WHY pglayers RATHER THAN A THIRD-PARTY POSTGRES IMAGE.
#
#   A prebuilt `pglayers-full` image would be one line instead of four, and it
#   carries all 80+ extensions. Two reasons not to. It REPLACES the official
#   `postgres` image with a community build, for every service, permanently —
#   a supply-chain decision taken for a dev-stack convenience. And a cluster
#   whose extensions are chosen by an operator is a cluster whose extensions can
#   be READ; "full" means 80 extensions loaded onto the cluster whether or not
#   any of them is used, and `max_worker_processes` raised to 64 to accommodate
#   them. Composing the layers from the official image keeps the base official
#   and the extension list to the one anywaye actually uses.
#
# PINNED, NOT FLOATING. `pgx-pgvector:17` is a moving tag. The versioned form
# is `pgx-pgvector:17-0.8.6` — note there is NO `v` prefix. pglayers' README
# still documents `17-v0.8.3`, and that tag exists but is a STALE build: the
# live series is `17-0.8.4`, `17-0.8.5`, `17-0.8.6`. Copying the README's
# example pins this cluster to a vector implementation nobody has patched.
ARG POSTGRES_TAG=17
ARG PGVECTOR_TAG=17-0.8.6

# THE EXTENSION LAYER, AS A NAMED STAGE, AND THE `AS` IS LOAD-BEARING.
#
# `COPY --from=ghcr.io/…:${PGVECTOR_TAG}` does not build:
#
#   failed to solve: variable expansion is not supported for --from, define a
#   new stage with FROM using ARG from global scope as a workaround
#
# BuildKit will not expand a variable in `COPY --from` when the source is an
# external image, and pglayers' own README example writes the tag literally —
# which would put the pin in two places and let them drift. Declaring the layer
# as a stage first gets both: the pin stays in the ARG, and `COPY --from` names
# a stage, where expansion is not attempted.
FROM ghcr.io/pglayers/pgx-pgvector:${PGVECTOR_TAG} AS pgvector

FROM postgres:${POSTGRES_TAG}

# One line per extension. No compilation, no apt, no build stage: the layer is a
# prebuilt `FROM scratch` image and this is an overlay onto the official one.
#
# pglayers is a community project, not a PostgreSQL project. It layers onto the
# OFFICIAL images, which is a different and weaker claim than being published by
# postgres.org, and the trade is recorded in DECISIONS.md rather than left
# implicit in a FROM line.
COPY --from=pgvector / /

# STRICTNESS NOTES
#   - pgvector needs NO shared_preload_libraries entry, which is why there is no
#     postgresql.conf edit here. pglayers' README lists the 24 extensions that
#     do need one (pg_cron, timescaledb, pgaudit, pg_stat_monitor, …) and
#     adding pg_cron means adding `pg_cron` to shared_preload_libraries as well
#     as the COPY. An extension that needs preloading and does not have it
#     starts cleanly and fails on first use, so the two edits must land together.
#   - `CREATE EXTENSION` still happens per database, by the admin role, at init
#     time — see templates/compose/postgres/initdb/10-cluster.sh. The image makes
#     the extension POSSIBLE; it does not create it, and it does not decide which
#     database gets it.
#   - This image runs its entrypoint as root and the entrypoint then drops to the
#     `postgres` uid via gosu, which is what the OFFICIAL image does and what
#     initdb requires: a fresh data directory has to be chowned before a
#     non-root user can write to it. That is why this file is the one Dockerfile
#     in kit without a `USER` instruction, and why it is not held to the
#     non-root rule the seven service images are.