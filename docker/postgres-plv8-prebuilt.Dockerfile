# PostgreSQL with plv8 using a prebuilt base image.
# This uses sibedge/postgres-plv8 which is based on bitnami/postgresql.
# Caveats:
#  - Bitnami has moved away from Debian-based images; long-term updates are uncertain.
#  - As of 2025-11-18, Postgres 18 image is beta (e.g., 18.0.0-beta.3).
#
# Override PREBUILT_PLV8_TAG at build time to select a specific tag.
# Examples:
#   docker build -f docker/postgres-plv8-prebuilt.Dockerfile \
#     --build-arg PREBUILT_PLV8_TAG=18.0.0-beta.3 \
#     -t jd-sql-pg-dev-prebuilt:18 .

ARG PREBUILT_PLV8_TAG=18
FROM docker.io/sibedge/postgres-plv8:${PREBUILT_PLV8_TAG}

# Keep parity with other images: create log location and map stderr to a file path
USER root
RUN mkdir -p /var/log/postgres \
  && touch /var/log/postgres/log /var/log/postgres/log.csv \
  && chown -R 1001:0 /var/log/postgres || true

USER 1001
RUN ln -fs /dev/stderr /var/log/postgres/log || true
