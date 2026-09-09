# Tenant-repository targets.
#
# These live at the repo root rather than in cinc/ because pin-check covers both
# published artifacts: the cookbook pin in the policyfile, and every
# module ?ref= under vms/. cinc/Makefile calls it as `$(MAKE) -C .. pin-check`.

TEMPLATES := vms/tenant.auto.tfvars \
             vms/backend.hcl \
             infra/tenant.auto.tfvars \
             infra/backend.hcl \
             infra/ansible/group_vars/all/tenant.yml \
             cinc/.chef/knife.rb

.PHONY: help prepare pin-check bump-cookbook

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Mechanical: copy .example -> real, never overwrite. The setup wizard calls this
# and then substitutes values; a human may re-run it after adding a new template.
# Overwriting would eat a tenant's real backend config, which is untracked and
# therefore unrecoverable from git.
#
# cinc/.chef/admin.pem is deliberately NOT here: it is a credential fetched from
# the CINC server, and .gitignore already keeps it out of the repo.
# PLATFORM_TAG resolves the skeleton's pin placeholders. Omitted, prepare only
# materialises config and says what is left to do — which is what a re-run on an
# already-pinned tenant should do.
#
# There is deliberately no PLATFORM_SOURCE branch here. The spec suggested one so
# the upstream smoke test could invoke prepare non-interactively; the gate calls
# scripts/pin-to-worktree.sh directly instead. Routing it through prepare would
# make the gate depend on all six .example templates existing in the throwaway
# copy, and would materialise a tenant's config in a directory that is deleted
# seconds later — for a caller that wants only the pin resolved. A branch no
# caller takes is a branch no test covers.
# The placeholder check is scripts/placeholder-check.sh — one predicate, one
# spelling, three exit states (0 found / 1 none / 2 could-not-check, which
# refuses rather than reading as either). Its header records the two measured
# wrong spellings this replaced: a bare `grep -r vms/` (reads the .terraform
# module cache — warned on every pinned tenant) and `git grep` (tracked files
# only — silent on untracked trees and non-repos).
#
# It is called twice below, in its two modes, and they are not interchangeable:
# `--pins` names files resolve-pin.sh will rewrite, `--config` names the
# policyfile, which no script can fill in. Reporting them together would say a
# tenant is unpinned when it is only unconfigured.
#
# PLATFORM_TAG must come from the command line, not the environment: a stale
# `export PLATFORM_TAG` from an earlier session would otherwise turn the
# documented-safe bare `make prepare` into the pin-writing branch.
ifeq ($(origin PLATFORM_TAG),command line)
PREPARE_TAG := $(PLATFORM_TAG)
PREPARE_TAG_IGNORED :=
else
PREPARE_TAG :=
ifdef PLATFORM_TAG
PREPARE_TAG_IGNORED := yes
else
PREPARE_TAG_IGNORED :=
endif
endif
prepare: ## Materialise config, and resolve the platform pin (usage: make prepare PLATFORM_TAG=vX.Y.Z)
	@missing=0; \
	for f in $(TEMPLATES); do \
	  if [ ! -f "$$f.example" ]; then echo "missing template: $$f.example"; missing=1; fi; \
	done; \
	[ "$$missing" -eq 0 ] || { echo "refusing: templates above are absent"; exit 1; }
	@for f in $(TEMPLATES); do \
	  if [ -f "$$f" ]; then echo "  keep   $$f (already exists)"; \
	  else cp "$$f.example" "$$f" && echo "  create $$f" \
	    || { echo "failed: could not create $$f from $$f.example"; exit 1; }; fi; \
	done
	@if [ -n "$(PREPARE_TAG_IGNORED)" ]; then \
	  echo "⚠  ignoring PLATFORM_TAG from the environment — pass it on the command line:"; \
	  echo "   make prepare PLATFORM_TAG=vX.Y.Z"; \
	fi
	@if [ -n "$(PREPARE_TAG)" ]; then \
	  ./scripts/resolve-pin.sh "$(PREPARE_TAG)"; \
	else \
	  ./scripts/placeholder-check.sh >/dev/null; rc=$$?; \
	  if [ $$rc -eq 0 ]; then \
	    echo ""; \
	    echo "⚠  vms/ still carries pin placeholders."; \
	    echo "   Run: make prepare PLATFORM_TAG=vX.Y.Z"; \
	    echo "   Until then 'terraform init' cannot resolve either module."; \
	  elif [ $$rc -ge 2 ]; then \
	    echo "refusing: could not check vms/ for pin placeholders (rc=$$rc)"; exit 1; \
	  fi; \
	fi
	@./scripts/placeholder-check.sh --config >/dev/null; rc=$$?; \
	if [ $$rc -eq 0 ]; then \
	  echo ""; \
	  echo "⚠  cinc/policyfiles/dev-vm.rb still carries REPLACE_ME:"; \
	  echo "     cookbook tag             make bump-cookbook TAG=base-X.Y.Z"; \
	  echo "     loki url / username      the stack's \"Send Logs\" panel (or set enabled = false)"; \
	  echo "     traefik acme_email       the address Let's Encrypt registers"; \
	  echo "     traefik domain_root      the suffix of each VM's fqdn in vms/instances.auto.tfvars"; \
	  echo "                              (base::traefik composes <vm>.ec2.<region>.<domain_root>)"; \
	  echo "   Nothing checks the traefik pair at converge: left as they are, every VM"; \
	  echo "   asks Let's Encrypt for a certificate for a name that does not exist."; \
	elif [ $$rc -ge 2 ]; then \
	  echo "refusing: could not check the policyfile for REPLACE_ME (rc=$$rc)"; exit 1; \
	fi
	@echo "✓ prepare complete — edit the created files, then run 'make pin-check'"

POLICYFILE  := cinc/policyfiles/dev-vm.rb
LOCKFILE    := cinc/policyfiles/dev-vm.lock.json

# The logic is in scripts/pin-check.sh, not here. A recipe cannot hold the
# multi-line Python the lock comparison needs — make ends a recipe line at the
# newline, reads the next as a rule, and `missing separator` takes the whole
# Makefile down — and each recipe line is its own shell, so the PIN_CHECK=skip
# branch could not exit the target from inside one. Both were measured.
pin-check: ## Verify the committed lock matches the remote tag and the policyfile
	@POLICYFILE=$(POLICYFILE) LOCKFILE=$(LOCKFILE) ./scripts/pin-check.sh

# The only target that re-resolves. Everything else honours the lock, on purpose:
# `chef update` rewrites the lock silently, so leaving it on the push path means
# every push adopts whatever the tag currently points at.
#
# TAG is optional. Omitted, this re-locks at the current pin — which is what a
# tenant attribute edit (Loki url, Traefik domain) needs, and without it there
# would be no way to re-lock except editing the lock by hand.
bump-cookbook: ## Re-resolve the cookbook pin (usage: make bump-cookbook [TAG=base-X.Y.Z])
	@if [ -n "$(TAG)" ]; then \
	  case "$(TAG)" in base-*) ;; *) echo "refusing: '$(TAG)' is not a base- tag"; exit 1 ;; esac; \
	  git_url=$$(python3 -c "import json;print(json.load(open('$(LOCKFILE)'))['cookbook_locks']['base']['source_options'].get('git',''))" 2>/dev/null); \
	  [ -n "$$git_url" ] || git_url=$$(sed -n "s/^cookbook 'base'.*git: '\([^']*\)'.*/\1/p" "$(POLICYFILE)" | head -1); \
	  [ -n "$$git_url" ] || { echo "refusing: no git source in $(LOCKFILE) or $(POLICYFILE)."; \
	                          echo "          A fresh tenant has no lock yet, so the policyfile is the source —"; \
	                          echo "          check that its cookbook 'base' stanza is on one line and names git:."; exit 1; }; \
	  git ls-remote "$$git_url" "refs/tags/$(TAG)" 2>/dev/null | grep -q . \
	    || { echo "refusing: $(TAG) does not exist at $$git_url"; \
	         echo "          The policyfile has not been touched."; exit 1; }; \
	  grep -q "^cookbook 'base'.*tag: '" "$(POLICYFILE)" \
	    || { echo "refusing: no single-line \"cookbook 'base', … tag: '…'\" stanza in $(POLICYFILE)."; \
	         echo "          This target rewrites that one line. Without the guard the sed below"; \
	         echo "          matches nothing, chef update re-locks at the OLD tag, and the bump"; \
	         echo "          reports success having changed nothing."; exit 1; }; \
	  sed -i "/^cookbook 'base'/ s/tag: '[^']*'/tag: '$(TAG)'/" "$(POLICYFILE)"; \
	  echo "==> policyfile pinned to $(TAG)"; \
	fi
	@( cd $$(dirname $(POLICYFILE)) && FILTER_BRANCH_SQUELCH_WARNING=1 chef update "$$(basename $(POLICYFILE))" )
	@echo "✓ lock rewritten — review the diff, then commit both files"
	@git --no-pager diff --stat -- "$(POLICYFILE)" "$(LOCKFILE)" 2>/dev/null || true
