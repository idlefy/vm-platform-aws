# Block IMDS — `169.254.169.254` and `fd00:ec2::254`; not reachable by
# `ubuntu` or its containers. Only root and ec2-instance-connect pass.
# root: cinc-client, user_data bootstrap, SSM parameter access
# ec2-instance-connect: fetches ephemeral SSH keys from IMDS for admin access
# Must run AFTER firewall (installs iptables-persistent) and ssh (installs
# ec2-instance-connect).
#
# The EIC uid is resolved at CONVERGE time (lazy command + block guards), not
# compile time: base::ssh installs ec2-instance-connect as a converge-time
# package resource, so a compile-time shell_out on a fresh image ran before
# the user existed, returned '', and the empty uid degenerated the old string
# guard into one that matched the ROOT rule — silently skipping the EIC
# ACCEPT while the DROP still landed, locking admins out of Instance Connect
# until the next converge. A plain string guard interpolates at compile time
# even though it RUNS at converge, which is why the EIC guard is a block and
# the DROP's position is computed lazily.
#
# Every guard is `-C OUTPUT` with the same rule arguments as its own insert:
# it holds only when that exact rule is in the filter table's OUTPUT chain.
# The old guards grepped all of `iptables-save`, so the same text in another
# chain or table (a FORWARD DROP, a nat OUTPUT rule) skipped the real OUTPUT
# rule. `-C` also recognises the identical rules user_data appends at first
# boot (it checks them the same way), so they are not duplicated.
#
# The DROP goes right after the last owner-allow present, not at a fixed
# position: see libraries/imds_firewall.rb. On a normal host that is
# position 3, the command the fleet has always run.
#
# The v6 endpoint `fd00:ec2::254` (Nitro instances with the IPv6 IMDS
# endpoint enabled) gets the same three rules on ip6tables, with the same
# lazy command and block guards for the EIC uid. Without them, wherever
# that endpoint is enabled, the v4 block is bypassed by asking over v6.
#
# A missing user at converge logs :error and skips the EIC resource only —
# not a raise: base::imds runs fourth, and failing here would take sudoers,
# aws_access, falco and alloy down on every converge, over an allow that is
# only load-bearing pre-converge (post-converge sshd runs
# AuthorizedKeysCommand as root). The DROP still lands, after the root allow.

eic_uid_lookup = -> { shell_out('id -u ec2-instance-connect').stdout.strip }

{
  'iptables' => { addr: '169.254.169.254', prefix: 32, save: 'save-iptables-rules', file: 'rules.v4', tag: 'EIC IMDS allow' },
  'ip6tables' => { addr: 'fd00:ec2::254', prefix: 128, save: 'save-ip6tables-rules', file: 'rules.v6', tag: 'EIC IMDS v6 allow' },
}.each do |bin, f|
  addr = f[:addr]

  execute "#{bin}-imds-allow-root" do
    command "#{bin} -I OUTPUT 1 -d #{addr} -m owner --uid-owner 0 -j ACCEPT"
    not_if "#{bin} -C OUTPUT -d #{addr} -m owner --uid-owner 0 -j ACCEPT"
    notifies :run, "execute[#{f[:save]}]", :immediately
  end

  execute "#{bin}-imds-allow-eic" do
    command lazy {
      "#{bin} -I OUTPUT 2 -d #{addr} -m owner --uid-owner #{eic_uid_lookup.call} -j ACCEPT"
    }
    only_if do
      uid = eic_uid_lookup.call
      if uid.empty?
        Chef::Log.error("base::imds: no ec2-instance-connect user at converge — #{f[:tag]} " \
                        'skipped this run; EIC recovers on the next converge')
        false
      else
        !shell_out(bin, '-C', 'OUTPUT', '-d', addr, '-m', 'owner', '--uid-owner', uid, '-j', 'ACCEPT').exitstatus.zero?
      end
    end
    notifies :run, "execute[#{f[:save]}]", :immediately
  end

  execute "#{bin}-imds-deny-all" do
    command lazy { DevVm::ImdsFirewall.drop_command(bin, addr, f[:prefix]) }
    not_if "#{bin} -C OUTPUT -d #{addr} -j DROP"
    notifies :run, "execute[#{f[:save]}]", :immediately
  end

  execute f[:save] do
    command "mkdir -p /etc/iptables && #{bin}-save > /etc/iptables/#{f[:file]}"
    action :nothing
  end
end
