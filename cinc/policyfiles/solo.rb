name 'solo'

run_list 'base::solo'

cookbook 'base', path: '../cookbooks/base'

# The policy for Idlefy's public image: one developer's box with an AI agent,
# no fleet. Converged exactly once, by bootstrap-solo during the Packer build of
# that image, and never again — no tenant fleet converges it, and nothing on a
# box built from it fetches a policy after launch (law A1, recipes/solo.rb).
# There is no tenant copy and nothing here is a placeholder.

# No journal shipping: there is no Loki behind a solo box. base::solo leaves
# base::alloy out, and this also drops the apt.grafana.com origin and the alloy
# blacklist line from base::unattended_upgrades.
default['base']['loki']['enabled'] = false

# Install the idlefy-share grant (/etc/sudoers.d/51-idlefy-share). Safe here
# only because base::solo has no base::falco to page on it — see the attribute's
# comment in attributes/default.rb before setting it anywhere else.
default['base']['share_helper']['enabled'] = true

# Nothing but SSH reachable from the internet: no Traefik on a solo box.
#
# `override`, not `default`. Chef unions arrays across every default level, so
# a Policyfile default of [] (role_default) merged with the cookbook's
# [80, 443] is still [80, 443] — measured with chef 19.3.14, and pinned by
# spec/recipes/solo_spec.rb. An override replaces the default outright.
override['base']['firewall']['public_web_ports'] = []
