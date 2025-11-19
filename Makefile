.PHONY : push-github
push-github : check-env
	git diff --exit-code
	git tag v$(JD_SQL_VERSION) --force
	git push origin v$(JD_SQL_VERSION)

.PHONY : release-notes
release-notes : check-env
	@echo
	@git log --oneline --no-decorate v$(JD_SQL_PREVIOUS_VERSION)..v$(JD_SQL_VERSION)

.PHONY : check-dirty
check-dirty : tidy
	git diff --quiet --exit-code

.PHONY : check-env
check-env :
ifndef JD_SQL_VERSION
	$(error Set JD_SQL_VERSION)
endif
ifndef JD_SQL_PREVIOUS_VERSION
	$(error Set JD_SQL_PREVIOUS_VERSION for release notes)
endif

# --- PostgreSQL dev/test containers ---

# plv8 build container defaults
# The plv8 Dockerfile is based on the official plv8 build container approach.
# It builds plv8 from source against the selected Postgres container version.
# Tested defaults (from upstream): PostgreSQL 15 + plv8 v3.2.4
PG_CONTAINER_VERSION ?= 15

# Backward compatibility: allow callers to keep using POSTGRES_MAJOR[_PLV8]
# If provided, map it to PG_CONTAINER_VERSION.
ifdef POSTGRES_MAJOR_PLV8
PG_CONTAINER_VERSION := $(POSTGRES_MAJOR_PLV8)
endif
ifdef POSTGRES_MAJOR
PG_CONTAINER_VERSION := $(POSTGRES_MAJOR)
endif

# plv8 source build parameters
# See upstream README for details: https://github.com/plv8/plv8/blob/r3.2/platforms/Docker/README.md
PLV8_VERSION ?= 3.2.4
PLV8_BRANCH ?= r3.2

# Vanilla image defaults to latest stable major.
POSTGRES_MAJOR_VANILLA ?= 18

# Image tags
PG_IMAGE_NAME_PLV8 ?= jd-pg-dev:$(PG_CONTAINER_VERSION)
PG_IMAGE_NAME ?= $(PG_IMAGE_NAME_PLV8) # backward-compat alias
PG_IMAGE_NAME_VANILLA ?= jd-pg-vanilla:$(POSTGRES_MAJOR_VANILLA)

# Explicit PLV8 targets (preferred names)
.PHONY : docker-pg-build-plv8
docker-pg-build-plv8 :
	docker build \
		--build-arg PG_CONTAINER_VERSION=$(PG_CONTAINER_VERSION) \
		--build-arg PLV8_VERSION=$(PLV8_VERSION) \
		--build-arg PLV8_BRANCH=$(PLV8_BRANCH) \
		-f docker/postgres-plv8.Dockerfile \
		-t $(PG_IMAGE_NAME_PLV8) .

.PHONY : docker-pg-run-plv8
docker-pg-run-plv8 :
	# Default credentials for local dev only
	docker run --name jd-pg \
		-e POSTGRES_PASSWORD=postgres \
		-p 5432:5432 -d $(PG_IMAGE_NAME_PLV8)

.PHONY : docker-pg-stop-plv8
docker-pg-stop-plv8 :
	- docker rm -f jd-pg

.PHONY : docker-pg-shell-plv8
docker-pg-shell-plv8 :
	# Open a psql shell into the running container
	docker exec -it jd-pg psql -U postgres

	# Backward-compatibility aliases (legacy target names)
.PHONY : docker-pg-build docker-pg-run docker-pg-stop docker-pg-shell
docker-pg-build: docker-pg-build-plv8
docker-pg-run: docker-pg-run-plv8
docker-pg-stop: docker-pg-stop-plv8
docker-pg-shell: docker-pg-shell-plv8

# Vanilla Postgres (no plv8)
.PHONY : docker-pg-build-vanilla
docker-pg-build-vanilla :
	docker build \
		--build-arg POSTGRES_MAJOR=$(POSTGRES_MAJOR_VANILLA) \
		-f docker/postgres.Dockerfile \
		-t $(PG_IMAGE_NAME_VANILLA) .

.PHONY : docker-pg-run-vanilla
docker-pg-run-vanilla :
	# Default credentials for local dev only
	docker run --name jd-pg-vanilla \
		-e POSTGRES_PASSWORD=postgres \
		-p 5433:5432 -d $(PG_IMAGE_NAME_VANILLA)

.PHONY : docker-pg-stop-vanilla
docker-pg-stop-vanilla :
	- docker rm -f jd-pg-vanilla

.PHONY : docker-pg-shell-vanilla
docker-pg-shell-vanilla :
	# Open a psql shell into the running container
	docker exec -it jd-pg-vanilla psql -U postgres

# PLV8 prebuilt option via sibedge/postgres-plv8
# Defaults to tag "18" (bitnami base); override PREBUILT_PLV8_TAG to use a specific tag like 18.0.0-beta.3
PREBUILT_PLV8_TAG ?= 18
PG_IMAGE_NAME_PLV8_PREBUILT ?= jd-pg-dev-prebuilt:$(PREBUILT_PLV8_TAG)

.PHONY : docker-pg-build-plv8-prebuilt
docker-pg-build-plv8-prebuilt :
	docker build \
		--build-arg PREBUILT_PLV8_TAG=$(PREBUILT_PLV8_TAG) \
		-f docker/postgres-plv8-prebuilt.Dockerfile \
		-t $(PG_IMAGE_NAME_PLV8_PREBUILT) .

.PHONY : docker-pg-run-plv8-prebuilt
docker-pg-run-plv8-prebuilt :
	# Default credentials for local dev only
	docker run --name jd-pg-prebuilt \
		-e POSTGRES_PASSWORD=postgres \
		-p 5442:5432 -d $(PG_IMAGE_NAME_PLV8_PREBUILT)

.PHONY : docker-pg-stop-plv8-prebuilt
docker-pg-stop-plv8-prebuilt :
	- docker rm -f jd-pg-prebuilt

.PHONY : docker-pg-shell-plv8-prebuilt
docker-pg-shell-plv8-prebuilt :
	# Open a psql shell into the running container
	docker exec -it jd-pg-prebuilt psql -U postgres
