# kit template — Go service image. Copy to docker/Dockerfile in the service repo.
#
#   docker build -f docker/Dockerfile --build-arg GO_VERSION=1.24.1 -t svc .
#
# STRICTNESS NOTES
#   - Two stages, always. The builder carries the Go toolchain and a writable
#     $GOPATH; the runtime does not. An image with a compiler in it is an image
#     with a supply chain in it.
#   - CGO_ENABLED=0 so the binary is static. That is what lets the final stage be
#     a runtime with no libc-managed dynamic anything in it. If you need cgo
#     (sqlite, DNS resolution), re-test before you ship it.
#   - The build context is the service root, so `COPY . .` sees go.mod. Set
#     working-dir in the CI caller if the module lives in a subdirectory.
#   - The final stage runs non-root, as a numeric uid/gid directive (65532:65532).
#     The base ships no unprivileged account, which is fine and is the point: a
#     numeric directive is enforced by the kernel and nothing in the image can
#     widen it, where a named user is a name the base may not have. A container
#     running as root is a container where a bug is a host compromise.
#     (This note deliberately does not QUOTE that directive. A comment that
#     repeats an instruction verbatim gives `tests/self_test.sh`'s `edit` — which
#     replaces the FIRST occurrence — a comment to mutate instead of the
#     instruction, and breakage 12 stayed green for exactly that reason.)
#
#   - THE RUNTIME BASE IS DEBIAN-SLIM AND NOT DISTROLESS, and that is a change
#     this file used to argue the other way. It is here because the image now
#     starts through `docker/entrypoint.sh`, which migrates before it serves,
#     and a script needs a shell.
#
#     The claim that motivated distroless was measured rather than assumed, and
#     the measurement went the way nobody expected. Neither distroless variant
#     carries a shell — not `static`, and not `base`:
#
#         $ docker run --rm --entrypoint /bin/sh gcr.io/distroless/base-debian12:nonroot -c 'echo hi'
#         exec: "/bin/sh": stat /bin/sh: no such file or directory
#         $ docker export $(docker create gcr.io/distroless/base-debian12:nonroot) | tar -tf - | grep '^bin/'
#         bin/                       # empty
#
#     So "there is no shell in this image, so a compromised process cannot curl
#     and pipe" and "the entrypoint migrates" cannot both be true. Migrating at
#     boot is the feature (it is what deletes the boot-against-a-stale-schema
#     class); the shell is its price. The price is stated here rather than
#     discovered.
#
#     IF YOU WANT DISTROLESS BACK, the honest way is not a trick: set
#     `ENV KIT_MIGRATE=off`, run migrations from a job (Kamal's `pre-deploy`
#     accessory), and change the final stage back to
#     `gcr.io/distroless/static-debian12:nonroot`. You are choosing
#     "migrate once, out of band" over "migrate at every boot", which is a
#     legitimate trade — just not the default, because an out-of-band migration
#     nobody wired up is the cold-start race this file exists to delete.
#
#   - WHERE THE MIGRATE COMMAND COMES FROM, and why it is not `bin/migrate`.
#     This image copies the compiled binary and nothing else, so the repo's
#     bash+psql `bin/migrate` is not in it — correctly, since there is no `psql`
#     either. A Go service that migrates at boot compiles its own static binary:
#
#         RUN go build -trimpath -ldflags="-s -w" -o /out/migrate ./cmd/${SERVICE_NAME}/migrate
#         COPY --from=build /out/migrate /app/migrate
#         ENV KIT_MIGRATE_CMD=/app/migrate
#
#     and `pgx` is already in the dependency tree, so nothing new is pulled in.
#     With no `KIT_MIGRATE_CMD` and no `KIT_MIGRATE=required`, the entrypoint
#     logs one line and serves — correct for a service that owns no schema, and
#     a lie for one that does, which is why `required` exists. Note that
#     `KIT_MIGRATE_ADVISORY_LOCK` needs `psql` and therefore is NOT available in
#     this image; the entrypoint refuses to start if you ask for it rather than
#     migrating unserialized.
#
#   - `exec "$@"` in the entrypoint, so after the migration the service replaces
#     the shell and is PID 1. SIGTERM still reaches the service.
ARG GO_VERSION=1.24
ARG RUNTIME_DEBIAN_VERSION=12

FROM golang:${GO_VERSION} AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOOS=linux
# go.mod/go.sum first: dependency layers cache until the manifests change.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG SERVICE_NAME=service
RUN go build -trimpath -ldflags="-s -w" -o /out/service ./cmd/${SERVICE_NAME}

FROM debian:${RUNTIME_DEBIAN_VERSION}-slim AS runtime
WORKDIR /app

# --- the provenance stamp (kit) ----------------------------------------------
# Five ARGs, one file, five labels. WHICH formats this could have been, and the
# grammar that decides what may be stamped at all, are in docker/provenance.sh
# — do not restate them here, copy the script and read its header.
#
# `LABEL ${VAR}` is deliberately NOT used: buildkit does not word-split an
# expansion in a LABEL, so `LABEL ${STAMP}` fails with "must have two arguments"
# (measured). One ARG cannot carry five labels, so there are five.
#
# The defaults are `unknown` rather than empty, and that is the point: an image
# built with no --build-arg still carries the KEYS, because a missing label is
# indistinguishable from an image built before this existed.
ARG KIT_PROVENANCE_SOURCE=unknown
ARG KIT_PROVENANCE_REVISION=unknown
ARG KIT_PROVENANCE_BUILT_AT=unknown
ARG KIT_PROVENANCE_SOURCE_DIRTY=unknown
ARG KIT_PROVENANCE_TEMPLATE_VERSION=unknown
COPY docker/provenance.sh /usr/local/lib/kit/provenance.sh
RUN chmod +x /usr/local/lib/kit/provenance.sh \
    && /usr/local/lib/kit/provenance.sh --write /app/kit-provenance.json
LABEL org.opencontainers.image.source="${KIT_PROVENANCE_SOURCE}" \
      org.opencontainers.image.revision="${KIT_PROVENANCE_REVISION}" \
      org.opencontainers.image.created="${KIT_PROVENANCE_BUILT_AT}" \
      com.anywaye.kit.source.dirty="${KIT_PROVENANCE_SOURCE_DIRTY}" \
      com.anywaye.kit.template.version="${KIT_PROVENANCE_TEMPLATE_VERSION}"
COPY --from=build /out/service /app/service
COPY docker/entrypoint.sh /app/kit-entrypoint
# Numeric, not a named user: this base ships no unprivileged account, and a
# container running as root is a container where a bug is a host compromise.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/app/kit-entrypoint", "/app/service"]

