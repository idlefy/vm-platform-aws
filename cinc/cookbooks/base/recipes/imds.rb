# Block IMDS for all users except root and ec2-instance-connect
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
# even though it RUNS at converge, which is why every guard below is a block.
#
# Every guard anchors on the full iptables-save rendering of its own rule
# (`-d 169.254.169.254/32 …`), so no rule can false-match another — and so
# the identical rules user_data now appends at first boot are recognised
# rather than duplicated.
#
# A missing user at converge logs :error and skips the EIC resource only —
# not a raise: base::imds runs fourth, and failing here would take sudoers,
# aws_access, falco and alloy down on every converge, over an allow that is
# only load-bearing pre-converge (post-converge sshd runs
# AuthorizedKeysCommand as root).

eic_uid_lookup = -> { shell_out('id -u ec2-instance-connect').stdout.strip }

execute 'iptables-imds-allow-root' do
  command 'iptables -I OUTPUT 1 -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT'
  not_if 'iptables-save | grep -qF -- "-d 169.254.169.254/32 -m owner --uid-owner 0 -j ACCEPT"'
  notifies :run, 'execute[save-iptables-rules]', :immediately
end

execute 'iptables-imds-allow-eic' do
  command lazy {
    "iptables -I OUTPUT 2 -d 169.254.169.254 -m owner --uid-owner #{eic_uid_lookup.call} -j ACCEPT"
  }
  only_if do
    uid = eic_uid_lookup.call
    if uid.empty?
      Chef::Log.error('base::imds: no ec2-instance-connect user at converge — ' \
                      'EIC IMDS allow skipped this run; EIC recovers on the next converge')
      false
    else
      rule = "-d 169.254.169.254/32 -m owner --uid-owner #{uid} -j ACCEPT"
      !shell_out("iptables-save | grep -qF -- '#{rule}'").exitstatus.zero?
    end
  end
  notifies :run, 'execute[save-iptables-rules]', :immediately
end

execute 'iptables-imds-deny-all' do
  command 'iptables -I OUTPUT 3 -d 169.254.169.254 -j DROP'
  not_if 'iptables-save | grep -qF -- "-d 169.254.169.254/32 -j DROP"'
  notifies :run, 'execute[save-iptables-rules]', :immediately
end

execute 'save-iptables-rules' do
  command 'mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4'
  action :nothing
end
