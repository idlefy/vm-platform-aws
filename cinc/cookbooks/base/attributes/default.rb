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

# The TCP ports base::firewall opens to the world on INPUT, on both iptables
# and ip6tables, one `iptables-allow-tcp-<port>` / `ip6tables-allow-tcp-<port>`
# resource each. [80, 443] is what the fleet has always opened, for Traefik.
# The solo Policyfile sets it to [], because its run_list has no Traefik and
# nothing else should be reachable from the internet but SSH — as an
# `override`: Chef unions arrays across default levels, so a Policyfile
# `default` of [] would leave [80, 443] in place. 22 is
# deliberately NOT in this list: SSH is opened unconditionally by its own
# resources, so no value here can lock admins out.
#
# Additive only: removing a port from this list does NOT close it on a VM that
# has already converged with it — base::firewall only ever appends accepts.
# Delete the rule by hand (iptables and ip6tables) and re-save rules.v4/v6.
default['base']['firewall']['public_web_ports'] = [80, 443]

# Install /usr/local/sbin/idlefy-share and grant it to ubuntu
# (/etc/sudoers.d/51-idlefy-share, `ubuntu ALL=(root) NOPASSWD:
# /usr/local/sbin/idlefy-share *`). That lets the developer — or the agent
# working as them — publish one 127.0.0.1 port to the internet through
# Tailscale Funnel. base::sudoers writes the grant when true and deletes it
# when false; base::share_helper installs the script and is included only by
# base::solo, which sets this to true.
#
# Must stay false on any policy that runs base::falco without a matching
# exclusion for `sudo idlefy-share`: the grant and the Falco exclusion are one
# change (AGENTS.md trap 7), and without it every share pages someone.
default['base']['share_helper']['enabled'] = false
