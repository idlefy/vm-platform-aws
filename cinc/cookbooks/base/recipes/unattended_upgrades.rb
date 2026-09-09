package 'unattended-upgrades'

file '/etc/apt/apt.conf.d/20auto-upgrades' do
  content <<~APT
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Unattended-Upgrade "1";
    APT::Periodic::AutocleanInterval "7";
  APT
  mode '0644'
end

# Override allowed origins to include -updates pocket (not just -security).
# VMs are restarted by Idlefy when users finish work, so kernel reboots aren't an issue.
#
# Origins-Pattern adds third-party repos so patches from these vendors install
# automatically.
#
# Note what Origins-Pattern actually matches: a bare `site=` entry covers EVERY
# pocket that site publishes, not just its security pocket. For the distro
# entries above the pocket is named explicitly, so those really are
# security+updates only; for the third-party entries below it is "whatever the
# vendor ships", feature releases included.
#
# Note also which site is NOT in the list: download.falco.org. base::falco pins
# Falco to an exact version, and leaving its repo out of Origins-Pattern means
# unattended-upgrades cannot reach the package at all. The blacklist entry below is
# therefore belt-and-braces rather than load-bearing today — it costs one line and
# it stops a future "let's get Falco's security patches automatically" edit from
# reintroducing the daily flap described below. The cost of that choice is real and
# is recorded in base::falco: Falco gets no automatic security updates here, and it
# runs as root with an eBPF probe attached.
#
# pkgs.tailscale.com IS in the list, and that is inconsistent with the paragraph
# above — deliberately, so record it rather than let a future reader "fix" one of
# the two. tailscaled also runs as root, and here the binary is additionally
# invocable by an unprivileged user through a path-matched sudoers rule, so the
# exposure is larger than Falco's, not smaller. It is accepted because Tailscale
# keeps CLI compatibility across releases and there is no version-locked config
# template to break — the two properties that make the Alloy and Falco pins
# necessary are both absent here. A `sha256:` digest in the sudoers command spec
# would turn silent grant-widening into a visible break; it was rejected because
# with auto-updates on it would break the grant on every release.
#
# Note also that this is not the only update channel for this package: tailscaled
# answers a control-plane c2n `/update` RPC that runs `tailscale update --yes` as
# root via systemd-run if the tailnet enables auto-update. That path bypasses
# Package-Blacklist entirely, so blacklisting here would not actually pin it.
#
# That is acceptable for the vendors listed — except one. base::alloy pins Alloy
# to an exact version because its config template is written against specific
# Alloy stages, so an overnight major bump here would restart alloy on a config
# it may no longer accept, and the failure is silent (green unit, no logs
# collected). Package-Blacklist below is the other half of that pin; removing
# either one makes the package flap daily, since unattended would raise the
# version at night and the converge would lower it in the morning.
#
# Both Grafana lines follow node['base']['loki']['enabled']. With shipping off
# base::alloy purges the package and deletes the apt source, so a blacklist
# entry would protect nothing and an Origins-Pattern line would declare a
# feature-upgrade channel for a repo this VM no longer has. Dropping one and
# keeping the other is the asymmetry the next reader would "fix" — keep them
# paired. Falco's blacklist entry is unconditional (Falco does not depend on
# Alloy), and Falco deliberately has no Origins-Pattern line — see the
# unattended-upgrades table in cinc/README.md.
#
# Four spaces, not eight: <<~ dedents by the smallest LINE-LEADING literal
# indent (4 in this heredoc) and leaves interpolated text alone, so these
# strings must already carry the post-dedent indent.
grafana_origin    = node['base']['loki']['enabled'] ? %(    "site=apt.grafana.com";\n) : ''
grafana_blacklist = node['base']['loki']['enabled'] ? %(    "alloy";\n) : ''

file '/etc/apt/apt.conf.d/52unattended-upgrades-overrides' do
  content <<~APT
    Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}:${distro_codename}-updates";
    };

    Unattended-Upgrade::Origins-Pattern {
        "origin=Docker";
        "site=deb.nodesource.com";
        "site=cli.github.com";
        "site=pkgs.k8s.io";
    #{grafana_origin}    "site=pkgs.tailscale.com";
    };

    Unattended-Upgrade::Package-Blacklist {
    #{grafana_blacklist}    "falco";
    };
  APT
  mode '0644'
end
