# Template-repository targets. Tenant repositories have their own root Makefile
# with a different set (prepare / pin-check / bump-cookbook) — see the spec.

METADATA := cinc/cookbooks/base/metadata.rb
POLICYFILE  := cinc/policyfiles/dev-vm.rb
LOCKFILE    := cinc/policyfiles/dev-vm.lock.json

.PHONY: help release test-release-gate boundary-check test-boundary-check smoke pin-check test-pin-check test-skeleton-sync

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

test-release-gate: ## Test the release gate (no network, no AWS)
	@./test/test-release-gate.sh

# Cut a published cookbook tag.
#
# The checks run against the working tree; a tag names a commit. Nothing in git
# binds the two, so this target does: it refuses a dirty tree, prints the SHA it
# is about to tag before the gates run, and creates the tag on that SHA
# explicitly rather than on whatever HEAD becomes later.
#
# It also enforces the metadata/tag lockstep. Without it, decision 2 of the spec
# is a convention with no control, and a version that disagrees with its tag is
# exactly as invisible as the pinned-0.1.0 problem it replaces.
pin-check: ## Verify the committed lock matches the remote tag and the policyfile
	@POLICYFILE=$(POLICYFILE) LOCKFILE=$(LOCKFILE) ./scripts/pin-check.sh

test-pin-check: ## Test the pin gate (needs a local git remote only)
	@./test/test-pin-check.sh

test-skeleton-sync: ## Prove tenant-skeleton's script copies have not drifted
	@./test/test-skeleton-sync.sh

smoke: ## Gate the module interface against tenant-skeleton (needs no AWS)
	@./scripts/smoke.sh

boundary-check: ## Refuse a published module that reaches outside its own directory
	@./scripts/boundary-check.sh

test-boundary-check: ## Test the boundary guard (no network)
	@./test/test-boundary-check.sh

# Cut a published artifact tag.
#
# Two streams, and a tag cut through the wrong path certifies the wrong
# artifact with nothing to show for it:
#   base-X.Y.Z  the cookbook. Requires metadata.rb to say X.Y.Z, byte for byte.
#   vX.Y.Z      Terraform. Requires the boundary guard and the skeleton smoke
#               test, and does NOT look at metadata.rb.
#
# The commit binding applies to both. The gates run against the working tree
# while a tag names a commit, and nothing in git binds the two — so this target
# does: it refuses a dirty tree, refuses a HEAD that consumers cannot reach,
# prints the SHA before the gates run, and tags that SHA explicitly rather than
# whatever HEAD becomes later. The reachability check fetches first: a local
# `origin/main` is only as fresh as the last fetch, and a stale one certified a
# commit the remote no longer had (first external review, M3).
release: ## Gate and cut an artifact tag (usage: make release TAG=base-X.Y.Z | vX.Y.Z)
	@[ -n "$(TAG)" ] || { echo "usage: make release TAG=base-X.Y.Z (cookbook) | vX.Y.Z (terraform)"; exit 1; }
	@printf '%s\n' "$(TAG)" | grep -Eq '^(base-|v)[0-9]+\.[0-9]+\.[0-9]+$$' \
	  || { echo "refusing: '$(TAG)' is in neither stream."; \
	       echo "          base-X.Y.Z publishes the cookbook; vX.Y.Z publishes Terraform."; \
	       echo "          Both need all three version segments."; exit 1; }
	@git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null \
	  && { echo "refusing: tag $(TAG) already exists. Tags are immutable — use a new number."; exit 1; } || true
	@[ -z "$$(git status --porcelain)" ] \
	  || { echo "refusing: working tree is dirty. The gates would test files the tag will not contain."; \
	       git status --short; exit 1; }
	@up=$$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null) \
	  || { echo "refusing: this branch tracks no upstream, so the gate cannot tell whether"; \
	       echo "          the commit it is about to tag is reachable for consumers."; \
	       echo "          Set one: git branch --set-upstream-to=<remote>/<branch>"; exit 1; }; \
	 git fetch --quiet "$${up%%/*}" \
	   || { echo "refusing: could not fetch $${up%%/*} to check that HEAD is reachable for consumers."; exit 1; }; \
	 git merge-base --is-ancestor HEAD "$$up" \
	   || { echo "refusing: HEAD is not an ancestor of $$up."; \
	        echo "          Push and merge first, so the tagged commit is reachable for consumers."; exit 1; }; \
	 if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
	   echo "refusing: tag $(TAG) already exists on $${up%%/*} (the fetch brought it in). Tags are immutable — use a new number."; exit 1; fi
	@case "$(TAG)" in base-*) \
	  want=$$(printf '%s' "$(TAG)" | sed 's/^base-//'); \
	  have=$$(sed -n "s/^version[[:space:]]*'\\(.*\\)'.*/\\1/p" $(METADATA)); \
	  [ "$$want" = "$$have" ] \
	    || { echo "refusing: $(METADATA) says '$$have', tag says '$$want'."; \
	         echo "          These must match byte for byte — a tenant reads the version out of its lock."; exit 1; } ;; \
	esac
	@sha=$$(git rev-parse HEAD); \
	 echo "==> gating $$sha for $(TAG)"; \
	 case "$(TAG)" in \
	   base-*) $(MAKE) -C cinc lint \
	           && $(MAKE) -C cinc test \
	           && $(MAKE) -C cinc test-broker \
	           && $(MAKE) -C cinc test-loki-token ;; \
	   v*)     ./scripts/boundary-check.sh \
	           && ./test/test-skeleton-sync.sh \
	           && ./scripts/smoke.sh ;; \
	 esac \
	 && git tag "$(TAG)" "$$sha" \
	 && echo "✓ tagged $(TAG) at $$sha" \
	 && echo "  push it with: git push origin $(TAG)"
