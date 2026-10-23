# kit template — Ruby service image. Copy to docker/Dockerfile in the service repo.
#
#   docker build -f docker/Dockerfile --build-arg RUBY_VERSION=3.4.4 -t svc .
#
# STRICTNESS NOTES
#   - Two stages. The final stage is `ruby:*-slim`, not `ruby:*`: full Debian
#     ships a browser, a docs toolchain, and ~400 MB that a service never calls.
#   - The final stage runs non-root, as `app` (uid 10001), created with a fixed
#     numeric uid so the image is reproducible. A container running as root is a
#     container where a bug is a host compromise.
#   - `BUNDLE_PATH=/usr/local/bundle` keeps gems out of the app user's home so a
#     non-root runtime user can read them without chmod-ing the whole tree.
#   - `BUNDLE_WITHOUT=development:test` is the single most useful line in this
#     file: it keeps test-only gems (capybara, rspec-rails, rubocop) out of
#     production, so a test dependency can never be a production CVE.
#   - Bundle in the builder, run in the runtime stage. A `bundle install` at
#     runtime writes to the image filesystem on every boot; that is how a
#     read-only-rootfs deployment starts failing.
#   - THE ENTRYPOINT MIGRATES FIRST. `docker/entrypoint.sh` resolves this
#     repository's migration command, runs it against DATABASE_URL, and only then
#     `exec`s rails. A migration that fails refuses to start the service, which is
#     the point: it deletes the "service is healthy, schema is stale" cold-start
#     class that a bare `ENTRYPOINT ["bin/rails", "server", …]` leaves open.
#
#     Two things about Rails specifically, both learned from this fleet's own
#     `billing/bin/migrate`:
#
#       - `db:prepare`, not `db:migrate`: prepare creates the database when it is
#         absent and loads `db/schema.rb` when it is empty, which is what a fresh
#         replica is.
#       - REACH IT THROUGH `bundle exec`. `bin/rails` resolves `bundler/setup`
#         against the interpreter's own GEM_HOME, which is not always where
#         bundler installed the gems — billing measured
#         `Bundler::GemNotFound` from `bin/rails` on a machine where
#         `bundle exec rails` worked. So if your repo has a `bin/migrate` the
#         entrypoint finds it and your own file decides; if it does not, set
#         `KIT_MIGRATE_CMD='bundle exec rails db:prepare'` rather than relying on
#         the bare `./bin/rails db:prepare` fallback.
#
#     Set `KIT_MIGRATE=required` for a service that owns a schema, so a
#     misconfigured image fails loudly instead of serving the old one.
#   - `exec "$@"` inside that script, so after the migration rails replaces the
#     shell and is PID 1: SIGTERM still reaches it, and Puma still gets its
#     graceful shutdown.
ARG RUBY_VERSION=3.4

FROM ruby:${RUBY_VERSION}-slim AS build
ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=true
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

FROM ruby:${RUBY_VERSION}-slim AS runtime
ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=true \
    RAILS_ENV=production
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
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --create-home app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=app:app . /app
COPY --chown=app:app docker/entrypoint.sh /app/kit-entrypoint
USER app
EXPOSE 3000
ENTRYPOINT ["/bin/sh", "/app/kit-entrypoint", "bin/rails", "server", "-b", "0.0.0.0"]
