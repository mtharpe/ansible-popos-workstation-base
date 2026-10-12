# Variables
IMAGE_NAME := custom-popos-ansible
DOCKERFILE := molecule/default/Dockerfile
ANSIBLE_HOME := $(CURDIR)/.ansible
XDG_CACHE_HOME := $(CURDIR)/.cache
MOLECULE_ENV := ANSIBLE_HOME="$(ANSIBLE_HOME)" XDG_CACHE_HOME="$(XDG_CACHE_HOME)"
MOLECULE_GLOB_PODMAN := molecule/default/molecule.yml
MOLECULE_GLOB_DOCKER := molecule/docker/molecule.yml

.PHONY: lint test-cosmic all build reset test test-podman test-docker syntax-podman syntax-docker idempotence-podman idempotence-docker check-podman-deps check-docker-deps clean

# Static checks: yamllint, ansible-lint, playbook syntax, shellcheck, and the
# repo's shell-level tests.
lint:
	yamllint .
	ansible-lint .
	ansible-playbook --syntax-check setup_workstation.yml
	shellcheck run.sh scripts/*.sh tests/*.sh
	tests/vm-test-dryrun.sh
	tests/no-ubuntu-leftovers.sh

# Default target
all: build reset test clean

# Build the Podman image
build:
	@echo "🔨 Building Podman image from $(DOCKERFILE)..."
	podman build -f $(DOCKERFILE) -t $(IMAGE_NAME)
	@echo "✅ Image $(IMAGE_NAME) built successfully."

# Reset Molecule
reset:
	@echo "♻️ Resetting Molecule state..."
	$(MOLECULE_ENV) molecule reset || echo "⚠️ Molecule reset failed or not needed."

# Run Molecule tests
test: check-podman-deps
	@echo "🚀 Running Molecule tests (podman/default)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule test -s default
	@echo "✅ Molecule tests completed successfully."

# Run Molecule tests for the cosmic role (docker driver, linux/amd64)
test-cosmic: check-docker-deps
	@echo "🚀 Running Molecule tests (docker/cosmic)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="molecule/cosmic/molecule.yml" molecule test -s cosmic
	@echo "✅ Molecule cosmic tests completed successfully."

# Run Molecule tests explicitly on podman scenario
test-podman: check-podman-deps
	@echo "🚀 Running Molecule tests..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule test -s default
	@echo "✅ Molecule podman tests completed successfully."

# Run Molecule tests explicitly on docker scenario
test-docker: check-docker-deps
	@echo "🚀 Running Molecule tests..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_DOCKER)" molecule test -s docker
	@echo "✅ Molecule tests completed successfully."

# Run Molecule syntax check explicitly on podman scenario
syntax-podman: check-podman-deps
	@echo "🔍 Running Molecule syntax check (podman/default)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule syntax -s default
	@echo "✅ Molecule podman syntax check completed successfully."

# Run Molecule syntax check explicitly on docker scenario
syntax-docker: check-docker-deps
	@echo "🔍 Running Molecule syntax check (docker)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_DOCKER)" molecule syntax -s docker
	@echo "✅ Molecule docker syntax check completed successfully."

# Verify idempotence: create + converge once, then converge again expecting no changes
idempotence-podman: check-podman-deps
	@echo "🔁 Running Molecule idempotence check (podman/default)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule create -s default
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule converge -s default
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule idempotence -s default
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_PODMAN)" molecule destroy -s default
	@echo "✅ Idempotence verified."

idempotence-docker: check-docker-deps
	@echo "🔁 Running Molecule idempotence check (docker)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_DOCKER)" molecule create -s docker
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_DOCKER)" molecule converge -s docker
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_DOCKER)" molecule idempotence -s docker
	$(MOLECULE_ENV) MOLECULE_GLOB="$(MOLECULE_GLOB_DOCKER)" molecule destroy -s docker
	@echo "✅ Idempotence verified."

# Preflight checks for podman-based Molecule scenario
check-podman-deps:
	@command -v podman >/dev/null 2>&1 || { \
		echo "❌ Missing podman binary."; \
		echo "   Install with: brew install podman"; \
		exit 1; \
	}
	@molecule drivers 2>/dev/null | grep -qw podman || { \
		echo "❌ Missing molecule-podman driver plugin."; \
		echo "   Install with: python3 -m pip install molecule-podman"; \
		exit 1; \
	}

# Preflight checks for docker-based Molecule scenario
check-docker-deps:
	@command -v docker >/dev/null 2>&1 || { \
		echo "❌ Missing docker CLI."; \
		echo "   Install Docker Desktop or docker engine."; \
		exit 1; \
	}
	@molecule drivers 2>/dev/null | grep -qw docker || { \
		echo "❌ Missing molecule-docker driver plugin."; \
		echo "   Install with: python3 -m pip install molecule-docker"; \
		exit 1; \
	}

# Cleanup: Remove the custom Podman image
clean:
	@echo "🧹 Cleaning up Podman image $(IMAGE_NAME)..."
	@if podman images | grep -q $(IMAGE_NAME); then \
		podman rmi $(IMAGE_NAME) || echo "⚠️ Failed to remove image $(IMAGE_NAME), continuing..."; \
		echo "🗑️ Image $(IMAGE_NAME) removed."; \
	else \
		echo "ℹ️ Image $(IMAGE_NAME) not found, skipping removal."; \
	fi
	@echo "🎉 Cleanup complete."
