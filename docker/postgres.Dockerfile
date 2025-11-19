# Vanilla PostgreSQL image for jd-sql development and testing.
# Default to the latest stable major (17). Override as needed at build time.
ARG POSTGRES_MAJOR=17
FROM postgres:${POSTGRES_MAJOR}
ARG POSTGRES_MAJOR
ENV POSTGRES_MAJOR=${POSTGRES_MAJOR}

# To build with a different Postgres major, override at build time, e.g.:
#   POSTGRES_MAJOR=18 make docker-pg-build-vanilla
# or:
#   docker build --build-arg POSTGRES_MAJOR=18 -f docker/postgres.Dockerfile -t jd-sql-pg-vanilla:18 .
