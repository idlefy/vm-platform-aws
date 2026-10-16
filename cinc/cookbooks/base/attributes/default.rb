# cinc/cookbooks/base/attributes/default.rb
#
# The only attributes this cookbook defaults. Everything else under
# node['base'] is tenant configuration and lives in the tenant's policyfile.
#
# Ship the systemd journal to Grafana Cloud Loki. false tears Alloy down on
# the next converge (base::alloy) and drops the Grafana lines from the
# unattended-upgrades overrides (base::unattended_upgrades). The Terraform
# twin is `log_shipping` in the tenant's vms/tenant.auto.tfvars; the two must
# agree, and `make preflight` in the tenant checks that they do. Design:
# docs/design/optional-log-shipping.md
default['base']['loki']['enabled'] = true

# The keys whose envelopes this fleet converges, one allowed_signers line each:
#   <principal> namespaces="dev-vm-policy-staging[,dev-vm-policy-production]" ssh-ed25519 <key>
# Deliberately empty: base::cinc_client refuses an empty set, so a tenant that
# forgot it fails its first converge instead of shipping a fleet that trusts
# nobody. The Terraform twin is `policy_signers` in vms/tenant.auto.tfvars;
# `make preflight` checks that they agree. Rotate by adding the new key in one
# revision and dropping the old one in a later revision signed by the new key.
# Design: docs/design/serverless-policy-delivery.md, "Trust".
default['base']['policy']['signers'] = []
