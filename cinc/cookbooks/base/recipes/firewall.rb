# Firewall rules via iptables (not ufw — conflicts with iptables-persistent used by imds.rb)
# Default: deny incoming, allow outgoing, allow SSH

package 'iptables-persistent' do
  options '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
end

# Remove ufw if present (conflicts with iptables-persistent)
package 'ufw' do
  action :purge
end

# Clean up leftover ufw chains from iptables
execute 'flush-ufw-chains' do
  command <<~SH
    for chain in $(iptables -L -n 2>/dev/null | grep '^Chain ufw-' | awk '{print $2}'); do
      iptables -F "$chain" 2>/dev/null
    done
    for chain in $(iptables -L -n 2>/dev/null | grep '^Chain ufw-' | awk '{print $2}'); do
      iptables -D INPUT -j "$chain" 2>/dev/null
      iptables -D FORWARD -j "$chain" 2>/dev/null
      iptables -D OUTPUT -j "$chain" 2>/dev/null
      iptables -X "$chain" 2>/dev/null
    done
    true
  SH
  only_if 'iptables -L -n 2>/dev/null | grep -q "Chain ufw-"'
  notifies :run, 'execute[save-iptables]', :delayed
end

# Default policy: drop incoming, allow outgoing
execute 'iptables-default-drop-input' do
  command 'iptables -P INPUT DROP'
  not_if 'iptables -S | grep -q "\\-P INPUT DROP"'
  notifies :run, 'execute[save-iptables]', :delayed
end

execute 'iptables-default-accept-output' do
  command 'iptables -P OUTPUT ACCEPT'
  not_if 'iptables -S | grep -q "\\-P OUTPUT ACCEPT"'
  notifies :run, 'execute[save-iptables]', :delayed
end

# Allow established/related connections
#
# The guard matches against the rendered rule, which is
#   -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
# Note the ordering: the chain name comes FIRST. Both guards here used to be
# written as "state RELATED,ESTABLISHED.*INPUT.*ACCEPT", requiring the match
# before the chain, so they never matched — and because the command is
# `iptables -I` (insert, not append-if-absent), every converge added another
# copy. Two rules per 30-minute run, growing without bound. Keep the guard
# anchored to the real `iptables -S` output, and re-check it against a converged
# VM if you touch the command.
execute 'iptables-allow-established' do
  command 'iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT'
  not_if "iptables -S INPUT | grep -q -- '--state RELATED,ESTABLISHED -j ACCEPT'"
  notifies :run, 'execute[save-iptables]', :delayed
end

# Allow loopback
execute 'iptables-allow-loopback' do
  command 'iptables -I INPUT 2 -i lo -j ACCEPT'
  not_if "iptables -S INPUT | grep -q -- '-i lo -j ACCEPT'"
  notifies :run, 'execute[save-iptables]', :delayed
end

# Clean up the duplicates the two broken guards above already left behind.
# Fixing the guards stops the growth but does not shrink a VM that has been
# converging every 30 minutes since it was built, so this collapses each rule
# back to a single copy. It is a no-op once that has happened, which is why it
# stays in the recipe rather than being run by hand on each VM.
execute 'iptables-dedupe-input' do
  command <<~SH
    set -e
    for rule in '-m state --state RELATED,ESTABLISHED -j ACCEPT' '-i lo -j ACCEPT'; do
      while [ "$(iptables -S INPUT | grep -c -- "$rule")" -gt 1 ]; do
        iptables -D INPUT $rule
      done
    done
  SH
  only_if <<~SH
    [ "$(iptables -S INPUT | grep -c -- '--state RELATED,ESTABLISHED -j ACCEPT')" -gt 1 ] || \
    [ "$(iptables -S INPUT | grep -c -- '-i lo -j ACCEPT')" -gt 1 ]
  SH
  notifies :run, 'execute[save-iptables]', :delayed
end

# Allow inbound on the tailnet interface — OUR rule, not tailscaled's.
#
# tailscaled already inserts `-A INPUT -j ts-input` first, and ts-input carries an
# unconditional `-i tailscale0 -j ACCEPT`. So why duplicate it? Because those
# chains do not survive a mid-life `netfilter-persistent reload`, and the reload
# leaves `-P INPUT DROP` standing.
#
# Measured on a live VM 2026-08-12, tailscaled up and logged in:
#   before reload: -P INPUT DROP / -A INPUT -j ts-input / ts-input exists
#   after  reload: -P INPUT DROP / no ts-input jump / no ts-input chain
# and tailscaled did NOT restore them within 90s, despite NetfilterMode: 2.
# /etc/iptables/rules.v4 holds zero ts-* lines, because base::firewall's
# save-iptables runs before tailscaled ever creates them — so the restore has
# nothing to put back. Only a tailscaled restart or a reboot repairs it.
#
# The failure is silent from the VM: outbound-initiated flows keep working
# through the ESTABLISHED,RELATED rule above, so `tailscale status` and
# `tailscale ping` both look healthy while inbound tailnet connections are being
# dropped. The trigger is not exotic — the iptables-persistent postinst runs a
# reload on upgrade, and unattended-upgrades is on.
#
# An earlier revision of the design assumed the restore re-created ts-* and
# called the staleness cosmetic. That was wrong in the direction that matters,
# and only a mid-life reload shows it; a reboot test does not, because tailscaled
# rebuilds its chains at startup.
#
# This rule is ours, so it lands in rules.v4 and survives the restore. It grants
# exactly what ts-input already grants — intra-tailnet traffic is a trusted DMZ,
# per the design — and it matches nothing at all when the interface is absent.
execute 'iptables-allow-tailscale' do
  command 'iptables -A INPUT -i tailscale0 -j ACCEPT'
  not_if "iptables -S INPUT | grep -q -- '-i tailscale0 -j ACCEPT'"
  notifies :run, 'execute[save-iptables]', :delayed
end

# Allow SSH (port 22)
execute 'iptables-allow-ssh' do
  command 'iptables -A INPUT -p tcp --dport 22 -j ACCEPT'
  not_if 'iptables-save | grep -q "dport 22.*ACCEPT"'
  notifies :run, 'execute[save-iptables]', :delayed
end

# Allow HTTP (port 80)
execute 'iptables-allow-http' do
  command 'iptables -A INPUT -p tcp --dport 80 -j ACCEPT'
  not_if 'iptables-save | grep -q "dport 80.*ACCEPT"'
  notifies :run, 'execute[save-iptables]', :delayed
end

# Allow HTTPS (port 443)
execute 'iptables-allow-https' do
  command 'iptables -A INPUT -p tcp --dport 443 -j ACCEPT'
  not_if 'iptables-save | grep -q "dport 443.*ACCEPT"'
  notifies :run, 'execute[save-iptables]', :delayed
end

execute 'save-iptables' do
  command 'mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4'
  action :nothing
end
