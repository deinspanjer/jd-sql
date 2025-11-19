# Vanilla PostgreSQL image for jd-pg development and testing.
# Default to the latest stable major (18). Override as needed at build time.
ARG POSTGRES_MAJOR=18
FROM postgres:${POSTGRES_MAJOR}
ARG POSTGRES_MAJOR
ENV POSTGRES_MAJOR=${POSTGRES_MAJOR}

# To build with a different Postgres major, override at build time, e.g.:
#   make docker-pg-build-vanilla POSTGRES_MAJOR_VANILLA=17
# or:
#   docker build --build-arg POSTGRES_MAJOR=17 -f docker/postgres.Dockerfile -t jd-pg-vanilla:17 .
