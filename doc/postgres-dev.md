PostgreSQL development containers
================================

This repository provides multiple Dockerfiles for spinning up PostgreSQL instances used in developing and testing the jd-sql SQL functions. While jd-sql targets SQL implementations beyond PostgreSQL, these containers are specifically for PostgreSQL development and testing.

- With plv8 built from source: docker/postgres-plv8.Dockerfile
- With plv8 using a prebuilt base image: docker/postgres-plv8-prebuilt.Dockerfile
  - Base image: sibedge/postgres-plv8 (built on bitnami/postgresql)
  - Caveats: bitnami has moved away from Debian-based images; updates may lag. As of 2025-11-18, PG 18 is beta (e.g., 18.0.0-beta.3).
- Vanilla Postgres, no plv8: docker/postgres.Dockerfile

All images let you override the Postgres major at build time via POSTGRES_MAJOR (or PREBUILT_PLV8_TAG for the prebuilt plv8 image).

Build
-----

- Default simple build (vanilla Postgres, defaults to 17):
  make docker-pg-build

- Build vanilla for a different major (e.g., 18):
  POSTGRES_MAJOR=18 make docker-pg-build

- Build plv8 from source (uses POSTGRES_MAJOR, plus optional PLV8_VERSION and PLV8_BRANCH):
  make docker-pg-build-plv8

- Build prebuilt plv8 image for a specific upstream tag (e.g., 18.0.0-beta.3):
  PREBUILT_PLV8_TAG=18.0.0-beta.3 make docker-pg-build-plv8-prebuilt

Images are tagged as:
- vanilla: jd-sql-pg-vanilla:<major> (e.g., jd-sql-pg-vanilla:17)
- plv8 (source): jd-sql-pg-plv8:<major> (e.g., jd-sql-pg-plv8:17)
- plv8 (prebuilt): jd-sql-pg-plv8-prebuilt:<tag> (e.g., jd-sql-pg-plv8-prebuilt:18 or :18.0.0-beta.3)

Run
---

- Single dev container name: jd-sql-pg-dev

- Start the dev container (defaults to vanilla image, port 5432):
  make docker-pg-run

- Run using a specific image (e.g., plv8 source-built for PG 18):
  PG_RUN_IMAGE=jd-sql-pg-plv8:18 make docker-pg-run

- Open a psql shell to the running container:
  make docker-pg-shell

- Stop and remove the container:
  make docker-pg-stop

Running jd-sql SQL tests
-----------------------

The repository includes an initial PL/pgSQL implementation of jd-sql for PostgreSQL and SQL tests you can run directly with psql (no plv8 required).

1) Start the Postgres container (vanilla by default) and open a shell:

  make docker-pg-run
  make docker-pg-shell

2) From the psql prompt, run the tests:

  \i spec/test/sql/jd_pg_plpgsql_test.sql

Alternatively, if the container is already running, you can execute the tests from your host:

  docker exec -i jd-sql-pg-dev psql -U postgres -f /workspace/spec/test/sql/jd_pg_plpgsql_test.sql

Note: When using the provided Dockerfiles, the repository is copied to /workspace inside the container as part of the build context. If you mount your project differently, adjust the path accordingly or open an interactive shell and run the tests with \i.

Initialization behavior
-----------------------

- On first cluster initialization, the plv8-based images run docker/plv8-init.sql inside the container to enable the plv8 extension in both the default database (postgres) and template1. This ensures CREATE EXTENSION plv8; is available by default for new databases created thereafter.
- Default credentials are for local development only: user postgres with password postgres.

How plv8 is provided
--------------------

Source-built plv8 image (docker/postgres-plv8.Dockerfile):
- Follows the official plv8 build container approach and builds plv8 from source against the selected Postgres base image.
- You can pass POSTGRES_MAJOR, PLV8_VERSION, and PLV8_BRANCH as build args.
- The build can be slow (20+ minutes on first run).

Prebuilt plv8 image (docker/postgres-plv8-prebuilt.Dockerfile):
- Uses sibedge/postgres-plv8 prebuilt image on top of bitnami/postgresql.
- Select the upstream tag via PREBUILT_PLV8_TAG (defaults to 18). Example: PREBUILT_PLV8_TAG=18.0.0-beta.3.
- Caveats: bitnami base changes and beta tags for PG 18 may affect stability and updates.

Advanced overrides (examples):

- Build for Postgres 16 with a specific plv8 version and branch:

  POSTGRES_MAJOR=16 PLV8_VERSION=3.2.4 PLV8_BRANCH=r3.2 make docker-pg-build-plv8

- Build prebuilt plv8 for PG 18 beta tag:

  PREBUILT_PLV8_TAG=18.0.0-beta.3 make docker-pg-build-plv8-prebuilt

If you previously relied on pre-built plv8 images, note that this flow does a source build inside the Docker build; network access to fetch plv8 sources is required.

Notes
-----

- If you switch major versions, rebuild the image with POSTGRES_MAJOR set appropriately.
- This container is for local development and testing only; do not use the default credentials in production.