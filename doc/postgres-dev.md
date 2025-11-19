PostgreSQL development containers
================================

This repository provides multiple Dockerfiles for spinning up PostgreSQL instances used in developing and testing the jd-pg SQL functions.

- With plv8 built from source (default PG 15): docker/postgres-plv8.Dockerfile
- With plv8 using a prebuilt base image: docker/postgres-plv8-prebuilt.Dockerfile
  - Base image: sibedge/postgres-plv8 (built on bitnami/postgresql)
  - Caveats: bitnami has moved away from Debian-based images; updates may lag. As of 2025-11-18, PG 18 is beta (e.g., 18.0.0-beta.3).
- Vanilla Postgres, no plv8 (default PG 18): docker/postgres.Dockerfile

Both images let you override the default Postgres major at build time.

Build
-----

- Build plv8 image from source (defaults to 15):

  make docker-pg-build-plv8

- Build plv8 image for a different Postgres version (e.g., 16):

  PG_CONTAINER_VERSION=16 make docker-pg-build-plv8

  Note: Backward compatible aliases exist and map to the -plv8 targets:

  - docker-pg-build → docker-pg-build-plv8
  - docker-pg-run → docker-pg-run-plv8
  - docker-pg-shell → docker-pg-shell-plv8
  - docker-pg-stop → docker-pg-stop-plv8
  You may still use POSTGRES_MAJOR=15 make docker-pg-build, but the -plv8 names are preferred. Legacy POSTGRES_MAJOR and POSTGRES_MAJOR_PLV8 map to PG_CONTAINER_VERSION for convenience.

- Build plv8 image using the prebuilt base (defaults to tag 18):

  make docker-pg-build-plv8-prebuilt

- Build prebuilt plv8 image for a specific tag (e.g., 18.0.0-beta.3):

  PREBUILT_PLV8_TAG=18.0.0-beta.3 make docker-pg-build-plv8-prebuilt

- Build vanilla image (defaults to 18):

  make docker-pg-build-vanilla

- Build vanilla for a different major (e.g., 17):

  POSTGRES_MAJOR_VANILLA=17 make docker-pg-build-vanilla

Images are tagged as:
- plv8: jd-pg-dev:<major> (e.g., jd-pg-dev:16)
- vanilla: jd-pg-vanilla:<major> (e.g., jd-pg-vanilla:18)

Run
---

- Start the plv8 container (port 5432):

  make docker-pg-run-plv8

- Open a psql shell to plv8 container:

  make docker-pg-shell-plv8

- Stop and remove plv8 container:

  make docker-pg-stop-plv8

- Start the prebuilt plv8 container (port 5442):

  make docker-pg-run-plv8-prebuilt

- Open a psql shell to prebuilt plv8 container:

  make docker-pg-shell-plv8-prebuilt

- Stop and remove prebuilt plv8 container:

  make docker-pg-stop-plv8-prebuilt

- Start the vanilla container (port 5433):

  make docker-pg-run-vanilla

- Open a psql shell to vanilla container:

  make docker-pg-shell-vanilla

- Stop and remove vanilla container:

  make docker-pg-stop-vanilla

Running jd-pg SQL tests
-----------------------

The repository includes an initial PL/pgSQL implementation of jd-pg and SQL tests you can run directly with psql (no plv8 required).

1) Start the vanilla Postgres container and open a shell:

  make docker-pg-run-vanilla
  make docker-pg-shell-vanilla

2) From the psql prompt, run the tests:

  \i spec/test/sql/jd_pg_plpgsql_test.sql

Alternatively, if the container is already running, you can execute the tests from your host:

  docker exec -i jd-pg-vanilla psql -U postgres -f /workspace/spec/test/sql/jd_pg_plpgsql_test.sql

Note: When using the provided Dockerfiles, the repository is copied to /workspace inside the container as part of the build context. If you mount your project differently, adjust the path accordingly or open an interactive shell and run the tests with \i.

Initialization behavior
-----------------------

- On first cluster initialization, the plv8-based images run docker/plv8-init.sql inside the container to enable the plv8 extension in both the default database (postgres) and template1. This ensures CREATE EXTENSION plv8; is available by default for new databases created thereafter.
- Default credentials are for local development only: user postgres with password postgres.

How plv8 is provided
--------------------

Source-built plv8 image (docker/postgres-plv8.Dockerfile):
- Follows the official plv8 build container approach and builds plv8 from source against the selected Postgres base image. Defaults: PostgreSQL 15 with plv8 v3.2.4.
- You can pass PG_CONTAINER_VERSION, PLV8_VERSION, and PLV8_BRANCH as build args.
- The build can be slow (20+ minutes on first run).

Prebuilt plv8 image (docker/postgres-plv8-prebuilt.Dockerfile):
- Uses sibedge/postgres-plv8 prebuilt image on top of bitnami/postgresql.
- Select the upstream tag via PREBUILT_PLV8_TAG (defaults to 18). Example: PREBUILT_PLV8_TAG=18.0.0-beta.3.
- Caveats: bitnami base changes and beta tags for PG 18 may affect stability and updates.

Advanced overrides (examples):

- Build for Postgres 16 with a specific plv8 version and branch:

  PG_CONTAINER_VERSION=16 PLV8_VERSION=3.2.4 PLV8_BRANCH=r3.2 make docker-pg-build-plv8

- Build prebuilt plv8 for PG 18 beta tag:

  PREBUILT_PLV8_TAG=18.0.0-beta.3 make docker-pg-build-plv8-prebuilt

If you previously relied on pre-built plv8 images, note that this flow does a source build inside the Docker build; network access to fetch plv8 sources is required.

Notes
-----

- If you switch major versions, rebuild the image with POSTGRES_MAJOR set appropriately.
- This container is for local development and testing only; do not use the default credentials in production.