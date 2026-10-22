# solo: the run list for a single developer's box — Idlefy's public image.
#
# A solo box has one developer and an AI agent that works as `ubuntu`. There
# is no fleet: no policy bucket, no signed envelope, no Loki, no operator. The
# image is converged once, during its build, and never again.
#
# Inclusion rule (law A1): nothing here may take instructions from Idlefy after
# launch. A recipe that installs a timer, an agent or a credential channel that
# reaches back to anyone stays out, however useful it is on the fleet.
# spec/recipes/solo_spec.rb holds the boundary.
#
# Left out, and why:
#   cinc_client   — the policy fetch timer and cinc-client: a converge after
#                   launch is exactly the instruction channel A1 forbids.
#   aws_access    — the aws-vm-credentials broker and its timer hand the box
#                   credentials from the fleet's role; a solo box has none.
#   traefik       — the fleet's public HTTPS front; a solo box opens no web
#                   ports (public_web_ports = []) and shares with idlefy-share.
#   falco         — runtime detection only means something with an operator
#                   reading the alerts; there is none on a solo box.
#   alloy         — ships the journal to the fleet's Loki; no Loki here
#                   (loki.enabled = false).
#   nvidia_docker — GPU container runtime is decided per image variant, not by
#                   this run list; the solo image is built for CPU instances.
#
# Order follows base::default for everything both run, then the three solo-only
# recipes: hardened_firstboot, share_helper, no_ssm_agent.
include_recipe 'base::packages'
include_recipe 'base::firewall'
include_recipe 'base::ssh'
include_recipe 'base::imds'
include_recipe 'base::sudoers'
include_recipe 'base::fail2ban'
include_recipe 'base::unattended_upgrades'
include_recipe 'base::chrony'
include_recipe 'base::sysctl'
include_recipe 'base::docker'
include_recipe 'base::werf'
include_recipe 'base::kubernetes'
include_recipe 'base::nodejs'
include_recipe 'base::claude_code'
include_recipe 'base::codex'
include_recipe 'base::gh'
include_recipe 'base::shell_default'
include_recipe 'base::yq'
include_recipe 'base::uv'
include_recipe 'base::tailscale'
include_recipe 'base::hardened_firstboot'
include_recipe 'base::share_helper'
include_recipe 'base::no_ssm_agent'
