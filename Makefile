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

# Select the Postgres major version for all builds (vanilla and plv8 variants)
# Defaults to the latest stable major (update as needed)
POSTGRES_MAJOR ?= 17

# plv8 source build parameters
# See upstream README for details: https://github.com/plv8/plv8/blob/r3.2/platforms/Docker/README.md
PLV8_VERSION ?= 3.2.4
PLV8_BRANCH ?= r3.2

# Container name used for run and shell targets
PG_DEV_CONTAINER_NAME ?= jd-sql-pg-dev

# Image tags
PG_IMAGE_NAME_PLV8 ?= jd-sql-pg-plv8:$(POSTGRES_MAJOR)
PG_IMAGE_NAME_VANILLA ?= jd-sql-pg-vanilla:$(POSTGRES_MAJOR)

# Explicit PLV8 targets (preferred names)
.PHONY : docker-pg-build-plv8
docker-pg-build-plv8 :
	docker build \
		--build-arg PG_CONTAINER_VERSION=$(POSTGRES_MAJOR) \
		--build-arg PLV8_VERSION=$(PLV8_VERSION) \
		--build-arg PLV8_BRANCH=$(PLV8_BRANCH) \
		-f docker/postgres-plv8.Dockerfile \
		-t $(PG_IMAGE_NAME_PLV8) .

# Unified run/shell/stop targets (use a single dev container name)
.PHONY : docker-pg-run docker-pg-stop docker-pg-shell

# Image to run by default (vanilla). Override with: PG_RUN_IMAGE=jd-sql-pg-plv8:16 make docker-pg-run
PG_RUN_IMAGE ?= $(PG_IMAGE_NAME_VANILLA)

docker-pg-run :
	# Default credentials for local dev only
	docker run --name $(PG_DEV_CONTAINER_NAME) \
		-e POSTGRES_PASSWORD=postgres \
		-p 5432:5432 -d $(PG_RUN_IMAGE)

docker-pg-stop :
	- docker rm -f $(PG_DEV_CONTAINER_NAME)

docker-pg-shell :
	# Open a psql shell into the running container
	docker exec -it $(PG_DEV_CONTAINER_NAME) psql -U postgres

# Vanilla Postgres (no plv8)
.PHONY : docker-pg-build-vanilla
docker-pg-build-vanilla :
	docker build \
		--build-arg POSTGRES_MAJOR=$(POSTGRES_MAJOR) \
		-f docker/postgres.Dockerfile \
		-t $(PG_IMAGE_NAME_VANILLA) .

# Default simple build target: build vanilla
.PHONY : docker-pg-build
docker-pg-build: docker-pg-build-vanilla

# (Removed variant-specific run/shell/stop; use unified targets above)

# PLV8 prebuilt option via sibedge/postgres-plv8
# Defaults to tag "18" (bitnami base); override PREBUILT_PLV8_TAG to use a specific tag like 18.0.0-beta.3
PREBUILT_PLV8_TAG ?= 18
PG_IMAGE_NAME_PLV8_PREBUILT ?= jd-sql-pg-plv8-prebuilt:$(PREBUILT_PLV8_TAG)

.PHONY : docker-pg-build-plv8-prebuilt
docker-pg-build-plv8-prebuilt :
	docker build \
		--build-arg PREBUILT_PLV8_TAG=$(PREBUILT_PLV8_TAG) \
		-f docker/postgres-plv8-prebuilt.Dockerfile \
		-t $(PG_IMAGE_NAME_PLV8_PREBUILT) .

# To run the prebuilt image, use:
#   PG_RUN_IMAGE=$(PG_IMAGE_NAME_PLV8_PREBUILT) make docker-pg-run

# --- Upstream jd submodule helpers ---

.PHONY: jd-submodule-init jd-submodule-update jd-spec-test jd-spec-pull

# Initialize and update the josephburnett/jd git submodule.
# Usage (first time after clone): make jd-submodule-init
jd-submodule-init:
	@git submodule update --init --recursive
	@echo "Submodule status:"
	@git submodule status

# Pull latest upstream changes into the submodule's checked-out branch.
# This does not auto-commit in the parent repo; review and commit the
# submodule pointer change as desired.
jd-submodule-update:
	@echo "Updating external/jd from upstream..."
	@cd external/jd && git fetch --all --tags && git checkout $$(git rev-parse --abbrev-ref HEAD) && git pull --ff-only || true
	@git submodule status

# Convenience: checkout a specific ref (tag/branch/commit) inside submodule.
# Example: make jd-spec-pull REF=v2.2.0
REF ?=
jd-spec-pull:
	@if [ -z "$(REF)" ]; then \
	  echo "Set REF to a tag/branch/commit, e.g.: make jd-spec-pull REF=v2.2.0"; \
	  exit 2; \
	fi
	@cd external/jd && git fetch --all --tags && git checkout $(REF)
	@git submodule status

# Placeholder for running upstream jd spec tests via a wrapper that will be
# added to jd-sql. For now, just list available upstream spec cases and print
# guidance.
jd-spec-test:
	@echo "[jd-sql] Upstream jd spec test wrapper is not yet available."
	@echo "Listing upstream spec cases found in external/jd/spec/test/cases:"
	@ls -1 external/jd/spec/test/cases 2>/dev/null || echo "(No cases directory found; did you run 'make jd-submodule-init'?)"
	@echo
	@echo "Once the wrapper is added, this target will execute it against jd-sql."
	@echo "In the meantime you can explore specs under external/jd/spec/test."
