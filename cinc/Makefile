POLICYFILES_DIR := policyfiles
COOKBOOKS_DIR   := cookbooks
KNIFE_CONFIG    := ./.chef/knife.rb

POLICYFILES := $(wildcard $(POLICYFILES_DIR)/*.rb)
LOCKFILES   := $(POLICYFILES:.rb=.lock.json)

.PHONY: help lint test test-broker test-loki-token preflight add-region install push promote clean node-delete ssh

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# --fail-level refactor, because the default is not a gate.
#
# cookstyle's Chef/Correctness/InvalidVersionMetadata rule — the one that
# catches a malformed metadata version, which `make release` now depends on
# being caught — is severity R, and cookstyle exits 0 on R. Measured:
# version '0.11.0.1' printed "1 offense detected" and this target still
# reported "✓ Lint passed". The tree is clean at this level today, so the
# flag costs nothing and stops the gate lying.
lint: ## Lint cookbooks with cookstyle
	@echo "==> Linting cookbooks..."
	cookstyle --fail-level refactor $(COOKBOOKS_DIR)/
	@echo "✓ Lint passed"

test: ## Run ChefSpec unit tests
	@echo "==> Running tests..."
	@for cb in $(COOKBOOKS_DIR)/*/; do \
		if [ -d "$$cb/spec" ]; then \
			echo "--- Testing $$(basename $$cb) ---"; \
			( cd "$$cb" && chef exec rspec --format documentation ) || exit 1; \
		fi; \
	done
	@echo "✓ Tests passed"

test-broker: ## Run the aws-vm-credentials broker test (stubs aws, no AWS account needed)
	@echo "==> Testing aws-vm-credentials..."
	@test/test-aws-vm-credentials.sh
	@echo "✓ Broker tests passed"

test-loki-token: ## Run the Loki token script test (stubs aws, no AWS account needed)
	@echo "==> Testing dev-vm-loki-token..."
	@test/test-loki-token.sh
	@echo "✓ Token script tests passed"

# `chef update`, NOT `chef install`. The base cookbook is a local path
# (policyfiles/dev-vm.rb uses `path: '../cookbooks/base'`), so its content changes
# in every cookbook commit. `chef install` honours an existing lockfile and prints
# "Installing cookbooks from lock" — it does NOT re-resolve, so `make push` would
# upload the cookbook content from the LAST resolve and silently drop the changes
# you just made. `chef update` re-resolves and rewrites the lockfile, which is why
# every cookbook commit in this repo's history also carries a new revision_id.
install: ## Re-resolve policyfiles and rewrite lockfiles
	@echo "==> Updating policyfiles..."
	@for pf in $(POLICYFILES); do \
		echo "--- Updating $$(basename $$pf) ---"; \
		chef update "$$pf"; \
	done
	@echo "✓ All policyfiles resolved"

# --- retired: tenant operations ---
#
# These deployed a fleet from this repository, which is what the fork model
# did. This repository publishes artifacts: there is no `vms/` root here (only
# `vms/modules/`), no `.chef/knife.rb`, and no CINC organisation, so preflight,
# add-region and ssh fail on a path that is not here. `promote` was worse than
# broken — it carries none of the gates the tenant Makefile grew (no pin-check,
# no preflight, no refusal when staging does not already carry the revision),
# so with a knife.rb present it would push straight to production ungated.
#
# The gated versions live in tenant-skeleton/cinc/Makefile and reach a tenant
# through `make prepare`. Run them from the tenant repository.
DEPLOY_TARGETS := preflight add-region push promote node-delete ssh

$(DEPLOY_TARGETS):
	@echo "'make $@' is a tenant operation and does not live in the platform repository."
	@echo ""
	@echo "This repo publishes the cookbook and the modules as tags; it deploys nothing."
	@echo "Run 'cd cinc && make $@' from a tenant repository — the gated version"
	@echo "is in tenant-skeleton/cinc/Makefile, which 'make prepare' materialises there."
	@exit 1

clean: ## Remove lockfiles
	rm -f $(LOCKFILES)
