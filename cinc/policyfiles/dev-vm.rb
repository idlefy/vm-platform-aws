name 'dev-vm'

run_list 'base::default'

cookbook 'base', path: '../cookbooks/base'

# Per-tenant attributes, with the values this repository's own tests and the
# `make smoke` gate run against. A tenant gets its own copy from
# tenant-skeleton/cinc/policyfiles/dev-vm.rb, where each of these is REPLACE_ME.
# Every value below is a placeholder: left as it is, the converge is green and
# the failure lands at the point where the value is finally used, far from here.

# Traefik: the address Let's Encrypt registers for expiry notices, and the DNS
# root the VM's published hostname sits under. The full name is composed in
# base::traefik as <hostname>.ec2.<region>.<domain_root>, which must match the
# fqdn vms/modules/ec2/dns.tf creates for each instance — ACME resolves that
# name publicly, so a mismatch fails issuance rather than merely looking wrong.
# In a tenant: set both. domain_root is the DNS suffix of the fqdn each VM gets
# in vms/instances.auto.tfvars, and nothing checks either value at converge.
default['base']['traefik']['acme_email']  = 'admin@example.com'
default['base']['traefik']['domain_root'] = 'example.com'

# The SSM parameter holding the Grafana Cloud Loki push token. base::alloy reads
# it on every converge; vms/ grants the VM's role permission to read this exact
# name.
#
# In a tenant: this must match `loki_ssm_parameter_name` in vms/tenant.auto.tfvars
# byte for byte, and a SecureString with this name must exist in EVERY region in
# `local.regions` — you create those by hand, so Terraform cannot tell you one is
# missing. A mismatch or an absent parameter plans clean, promotes clean, and
# surfaces as an AccessDenied on a VM days later. `cd cinc && make preflight`
# checks both sides against the live account; run it before promoting.
default['base']['loki']['ssm_parameter_name'] = '/developer-vms/observability/loki-token'

# Grafana Cloud Loki. The URL and the numeric user ID both come from the stack's
# "Send Logs" / "Details" panel; the token itself lives in SSM and never appears
# here or in Terraform state.
#
# Together with ssm_parameter_name these three attributes are the entire coupling
# to Grafana Cloud. Moving to another stack — or to a self-hosted Loki — is
# changing them and running `make push && make promote`. There is no code to
# touch.
#
# In a tenant: the host is per-stack (the number in logs-prod-NNN is not a
# constant), and the username is the stack's numeric user ID, not an e-mail
# address.
default['base']['loki']['url']      = 'https://logs-prod-000.grafana.net/loki/api/v1/push'
default['base']['loki']['username'] = '000000'
