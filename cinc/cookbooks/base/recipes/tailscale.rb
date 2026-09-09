# Tailscale on developer VMs.
#
# What this recipe does NOT do: grant anything. The one sudoers rule that lets a
# developer run `tailscale login` lives in base::sudoers, with every other
# privilege decision. Splitting it — creating the file here and deleting it there,
# as an earlier revision proposed — would delete and recreate it on every converge,
# because both recipes run in base::default. That is a permanent flap, a window
# every 30 minutes where the command does not work, and an idempotency test that
# fails by construction.
#
# The design record for this recipe is not published; the reasoning is in the
# comments below and in cinc/README.md, under Security model → Access model →
# Tailscale.
# The short version: a developer with no sudo runs one command and the VM joins the
# tailnet under that developer's own Okta identity — not a machine key, not a tag,
# not a shared auth key. `tailscale set --operator` is deliberately NOT used: it is
# full control of tailscaled, not a narrow grant, and with it `ubuntu` can enable
# Tailscale SSH and become root on its own machine. Measured, not assumed.
#
# Automatic apt updates are ON for this repo, which is a deliberate departure from
# how base::falco is treated — see base::unattended_upgrades for the reasoning and
# the acknowledged inconsistency.

# The codename drives BOTH the keyring URL and the .list line. Tailscale publishes
# a separate keyring per release, so a hardcoded `noble` here would break on the
# next AMI in the quiet way: apt-get update fails to verify, the package holds at
# whatever version is installed, and nothing else complains.
codename = node['lsb']['codename']

# remote_file, and NOT `execute curl` guarded on the file existing. That guard
# turned this into a one-shot install, and both of its failure modes end in the
# quiet way the comment above describes — apt cannot verify the repo, the package
# holds at whatever version is installed, and nothing complains:
#
#   - A truncated download poisons the VM permanently. `curl -f` removes the
#     output file on an HTTP error but NOT on a transport failure; measured with
#     `--limit-rate 100 --max-time 2` against the real URL, curl exits 28 and
#     leaves a 2,288-byte partial file. The `&& chmod` never runs, the converge
#     fails — and every converge after that skips the download, because the file
#     exists. `--remove-on-error` would close this one alone.
#   - A rotated signing key is never picked up, for the same reason. Tailscale
#     publishes per-release keyrings and has rotated before.
#
# remote_file fixes both: it downloads to a tempfile and renames, so a partial
# transfer never lands at the destination, and it re-checks every converge with
# a conditional GET (304 in the steady state), so a rotation arrives on its own.
#
# The cost is that a pkgs.tailscale.com outage now fails the converge on a VM
# that already has the key, where the old guard would have skipped. That is the
# right trade — a loud failure over a silently stale keyring — and it is small:
# the notify below already reaches the same host on any change.
remote_file '/usr/share/keyrings/tailscale-archive-keyring.gpg' do
  source "https://pkgs.tailscale.com/stable/ubuntu/#{codename}.noarmor.gpg"
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, 'execute[apt-update-tailscale]', :immediately
end

file '/etc/apt/sources.list.d/tailscale.list' do
  content 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] ' \
          "https://pkgs.tailscale.com/stable/ubuntu #{codename} main\n"
  mode '0644'
  notifies :run, 'execute[apt-update-tailscale]', :immediately
end

execute 'apt-update-tailscale' do
  command 'apt-get update -qq'
  action :nothing
end

package 'tailscale' do
  options '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
end

# Enabled and started, but NOT logged in. A fresh install has a 2-byte state file
# and reports "Logged out."; the node joins a tailnet only when a human completes
# the browser step. Nothing here contacts a control plane.
service 'tailscaled' do
  action [:enable, :start]
end
