ARG POSTGRES_TAG=17
ARG PGVECTOR_TAG=17-0.8.6

FROM ghcr.io/pglayers/pgx-pgvector:${PGVECTOR_TAG} AS pgvector

FROM postgres:${POSTGRES_TAG}

COPY --from=pgvector / /
