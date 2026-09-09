# cinc/cookbooks/base/attributes/default.rb
#
# The only attribute this cookbook defaults. Everything else under
# node['base'] is tenant configuration and lives in the tenant's policyfile.
#
# Ship the systemd journal to Grafana Cloud Loki. false tears Alloy down on
# the next converge (base::alloy) and drops the Grafana lines from the
# unattended-upgrades overrides (base::unattended_upgrades). The Terraform
# twin is `log_shipping` in the tenant's vms/tenant.auto.tfvars; the two must
# agree, and `make preflight` in the tenant checks that they do. Design:
# docs/design/optional-log-shipping.md
default['base']['loki']['enabled'] = true
