name            'base'
maintainer      'Idlefy'
maintainer_email 'hello@idlefy.com'
license         'Apache-2.0'
description     'Base configuration for all VMs: firewall, SSH hardening, IMDS block, fail2ban, unattended upgrades, NTP, sysctl, rootless Docker, scoped AWS credentials, journal shipping to Loki, Falco runtime detection, dev tooling'

# This version tracks the `base-X.Y.Z` git tag that publishes the cookbook, and
# `make release` refuses to cut a tag whose suffix does not match it byte for
# byte. A frozen version would make every tenant on every tag report the same
# one out of its lock, so the bump is part of every cookbook change.
version         '1.1.0'

supports 'ubuntu', '>= 24.04'
