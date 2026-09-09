POLICYFILES_DIR := policyfiles
KNIFE_CONFIG    := ./.chef/knife.rb

POLICYFILES := $(wildcard $(POLICYFILES_DIR)/*.rb)
LOCKFILES   := $(POLICYFILES:.rb=.lock.json)

.PHONY: help preflight add-region push promote clean node-delete ssh

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# Unlike the test-* targets above, this one talks to AWS and to Loki. It checks
# the things `terraform plan` structurally cannot: per-region secrets Terraform
# never manages, and external policy ARNs nothing resolves. Read-only — it
# ingests nothing and creates nothing.
preflight: ## Check per-region secrets, Loki auth and policy ARNs (needs AWS; read-only)
	@../scripts/preflight.sh

# Writes HCL only — creates nothing in AWS and never applies. Interactive.
add-region: ## Wire a new AWS region into vms/ (usage: make add-region REGION=eu-west-1)
	@../scripts/add-region.sh $(REGION)

# pin-check first, then `chef install` — NOT `chef update`.
#
# chef update re-resolves and rewrites the lock. On the push path that means
# every push adopts whatever the pinned tag currently points at, silently, and
# the recorded SHA protects nothing. chef install honours the lock, so what is
# pushed is what was reviewed and committed.
#
# The gate is what makes install safe: chef install is equally silent about a
# policyfile that has been edited past its lock, and the policyfile is where all
# tenant configuration lives. See `make -C .. pin-check`.
push: ## Push policies to staging (pin-check + install from lock + push)
	@$(MAKE) -C .. pin-check
	@echo ""
	@echo "⚠  Pushing to STAGING policy group"
	@echo "   Policies will NOT affect production VMs until promoted."
	@echo ""
	@for pf in $(POLICYFILES); do \
		name=$$(basename "$$pf" .rb); \
		echo "--- Materialising $$name from its lock ---"; \
		( cd $(POLICYFILES_DIR) && FILTER_BRANCH_SQUELCH_WARNING=1 chef install "$$(basename $$pf)" ) \
		  || { echo "chef install failed for $$name — not pushing"; exit 1; }; \
		echo "--- Pushing $$name -> staging ---"; \
		chef push staging "$$pf" -c $(KNIFE_CONFIG) \
		  || { echo "chef push failed for $$name"; exit 1; }; \
	done
	@echo ""
	@echo "✓ Policies pushed to staging"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Test on a staging VM (set policy_group=staging in client.rb)"
	@echo "  2. Run: make promote"
# The gate is mechanical, not procedural. "Never promote without push plus
# staging verification", and "run preflight before a promote that touches
# deployed config", were rules an operator could simply not follow:
# nothing stopped a policyfile edit, a skipped `make push`, and a promote of
# content staging never carried. So promote now refuses unless the staging
# policy group already names the revision_id in the committed lock.
#
# It does NOT prove a VM converged — no command can — so the confirmation prompt
# stays, and the text below says what the check did and did not establish.
promote: ## Promote staging policies to production (preflight + staging revision + confirmation)
	@if [ "$(PREFLIGHT)" = "skip" ]; then \
	  echo "⚠  skipping preflight (PREFLIGHT=skip)"; \
	  echo "   Nothing verifies that the secrets this revision needs exist in every"; \
	  echo "   region, or that the Loki token still authenticates. A converge can"; \
	  echo "   then come up green and ship no logs."; \
	else $(MAKE) preflight; fi
	@$(MAKE) -C .. pin-check
	@for pf in $(POLICYFILES); do \
		name=$$(basename "$$pf" .rb); \
		lock="$${pf%.rb}.lock.json"; \
		want=$$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['revision_id'])" "$$lock") \
		  || { echo "refusing: cannot read revision_id from $$lock"; exit 1; }; \
		have=$$(knife raw /policy_groups/staging -c $(KNIFE_CONFIG) 2>/dev/null \
		         | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['policies'].get('$$name',{}).get('revision_id',''))") \
		  || { echo "refusing: could not read the staging policy group from the CINC server"; exit 1; }; \
		[ "$$want" = "$$have" ] \
		  || { echo "refusing: staging does not carry the revision this tree would promote."; \
		       echo "  lock     $$want"; \
		       echo "  staging  $${have:-<no such policy in staging>}"; \
		       echo "  Run 'make push' and verify a staging VM converges before promoting."; exit 1; }; \
		echo "  ok   staging carries $$name at $$want"; \
	done
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  WARNING: This will push policies to ALL production VMs    ║"
	@echo "║  Changes will apply on next cinc-client run (~30 min)      ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "Staging carries this revision. That is not the same as a staging VM"
	@echo "having converged on it — confirm you have run one before answering."
	@echo ""
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted."; exit 1)
	@for pf in $(POLICYFILES); do \
		name=$$(basename "$$pf" .rb); \
		echo "--- Pushing $$name -> production ---"; \
		chef push production "$$pf" -c $(KNIFE_CONFIG) \
		  || { echo "chef push failed for $$name — production is now partially promoted"; exit 1; }; \
	done
	@echo ""
	@echo "✓ Policies promoted to production"

node-delete: ## Delete a node from CINC (usage: make node-delete NODE=test_vm)
	@[ -n "$(NODE)" ] || (echo "Usage: make node-delete NODE=<name>"; exit 1)
	@echo "Deleting node: $(NODE)"
	@echo ""
	-knife node delete $(NODE) -y -c $(KNIFE_CONFIG)
	-knife client delete $(NODE) -y -c $(KNIFE_CONFIG)
	@echo ""
	@echo "✓ Node $(NODE) cleaned up"

# `USER` is exported by every login shell and make imports the environment as
# variables, so `$(or $(USER),admin)` resolved to the operator's own login name
# and the documented `admin` default never applied — EC2 Instance Connect then
# failed on a user the VM does not have. Only a USER= given on the command line
# counts; $(origin) is what tells the two apart.
CLI_USER := $(if $(filter command line,$(origin USER)),$(USER))

ssh: ## SSH to VM via EC2 Instance Connect (usage: make ssh INSTANCE=i-xxx [USER=admin] [REGION=eu-central-1])
	@[ -n "$(INSTANCE)" ] || (echo "Usage: make ssh INSTANCE=<instance-id> [USER=admin] [REGION=<region>]"; exit 1)
	$(eval SSH_USER := $(or $(CLI_USER),admin))
	$(eval SSH_KEY := $(or $(KEY),~/.ssh/id_ed25519))
	@set -eu; \
	profile=$$(cd ../vms && echo 'var.aws_profile' | terraform console 2>/dev/null | tail -1 | tr -d '"'); \
	[ -n "$$profile" ] || { echo "could not read var.aws_profile from ../vms — is it initialised?"; exit 1; }; \
	export AWS_PROFILE="$$profile"; \
	region='$(REGION)'; \
	if [ -z "$$region" ]; then \
	  region=$$(cd ../vms && terraform output -json regions 2>/dev/null \
	    | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((r for r,o in d.items() if '$(INSTANCE)' in o['instance_ids'].values()),''))"); \
	fi; \
	[ -n "$$region" ] || { echo "$(INSTANCE) is in no region's instance_ids — pass REGION=<region> explicitly"; exit 1; }; \
	echo "Pushing ephemeral key for $(SSH_USER)@$(INSTANCE) (profile=$$profile region=$$region)..."; \
	aws ec2-instance-connect send-ssh-public-key --region "$$region" \
		--instance-id $(INSTANCE) \
		--instance-os-user $(SSH_USER) \
		--ssh-public-key file://$(SSH_KEY).pub >/dev/null; \
	echo "Connecting (key valid for 60s)..."; \
	IP=$$(aws ec2 describe-instances --region "$$region" --instance-ids $(INSTANCE) \
	      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$IP

clean: ## Remove lockfiles
	rm -f $(LOCKFILES)
