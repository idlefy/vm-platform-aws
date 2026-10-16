# Keep this VM converging, with no CINC server: cinc-client.timer runs
# dev-vm-policy-run, which fetches and verifies a signed envelope from the
# tenant's bucket and runs cinc-client in local mode. The EC2 tags (Name,
# PolicyName, PolicyGroup) are read once, by user_data at first boot, into
# /etc/dev-vm/policy.conf; nothing here reads them again, since re-reading
# would let anyone with ec2:CreateTags move a VM between policy groups.
# Design: docs/design/serverless-policy-delivery.md.

# A 1.x VM was built for a CINC server: it has a server-mode client.rb and no
# policy.conf, and converging this recipe there would point its unit at a
# launcher it does not have. Refuse before any resource runs.
unless ::File.exist?(DevVm::PolicySigners::CONF)
  raise "#{DevVm::PolicySigners::CONF} is missing: base 2.x converges only VMs built by the v2 module, " \
        'which deliver policy from S3. A VM built for a CINC server stays on base-1.x.'
end

# Refuse a signers set that would lock the fleet out, at compile time, before
# anything is written. See libraries/policy_signers.rb.
signers = node['base']['policy']['signers'].to_a
current_signers = ::File.exist?(DevVm::PolicySigners::SIGNERS) ? ::File.read(DevVm::PolicySigners::SIGNERS) : ''
DevVm::PolicySigners.validate!(
  signers,
  current: current_signers,
  signed_key: ENV['DEV_VM_POLICY_SIGNED_KEY'].to_s,
  group: ENV['DEV_VM_POLICY_GROUP'].to_s
)

file DevVm::PolicySigners::SIGNERS do
  content DevVm::PolicySigners.canonical(signers)
  owner 'root'
  group 'root'
  mode '0644'
end

# ---- the delivery script ------------------------------------------------------
# user_data installs dev-vm-policy-fetch at first boot; this keeps it current.
# The new version is staged beside the one in use, must pass --self-test
# against the shipped fixture, and only then replaces it — by mv, never an
# in-place write, because the running converge is a child of the old script
# and bash keeps reading the inode it opened. The old version stays as .prev
# for the launcher, which only user_data writes — but only if the launcher
# could run it. A version that is not executable or does not parse is the one
# .prev exists to replace: copying it there on repair (measured on a live VM,
# 2026-10-16) left the next failure with nothing to fall back to.
fetch    = '/usr/local/sbin/dev-vm-policy-fetch'
selftest = '/usr/share/dev-vm/policy-fetch-selftest'

directory '/usr/share/dev-vm' do
  owner 'root'
  group 'root'
  mode '0755'
end

remote_directory selftest do
  source 'policy-fetch-selftest'
  owner 'root'
  group 'root'
  mode '0700'
  files_owner 'root'
  files_group 'root'
  files_mode '0700'
  purge true
end

cookbook_file "#{fetch}.new" do
  source 'dev-vm-policy-fetch'
  owner 'root'
  group 'root'
  mode '0700'
end

execute 'install dev-vm-policy-fetch' do
  command "#{fetch}.new --self-test #{selftest} && " \
          "{ ! { [ -x #{fetch} ] && bash -n #{fetch}; } || cp -p #{fetch} #{fetch}.prev; } && " \
          "mv #{fetch}.new #{fetch}"
  not_if "cmp -s #{fetch}.new #{fetch}"
end

# ---- the CINC client ------------------------------------------------------------

# Pinned CINC client version for the whole fleet.
#
# Before this existed, the client version was decided once by the VM's user_data
# at first boot and never revisited, so a VM's client version was really its
# build date: one built in May ran 19.2.12 while a new one ran 19.3.14, and
# nothing could close the gap — `make promote` ships policy, not the client.
#
# Bumping these two values and pushing is now the only way the client moves.
# There is no auto-update path: CINC is not in any apt repo on the VM, and
# unattended-upgrades therefore cannot touch it.
#
# The sha256 is in the .deb.metadata.json sidecar next to the package. Bump both
# together — a mismatch makes the upgrade fail closed and the VM keeps the client
# it has.
#
# vms/modules/ec2/user_data.tf carries its own pin for the very first install on
# a brand-new VM. That one is the bootstrap floor; this one governs the fleet.
# They should normally match.
cinc_version = '19.3.14'
cinc_sha256  = 'c710cc8bf953fa56b7a4b0b726d9fcb9cb5bad2dc8caec4eaa439c4626f9aebf'

template '/usr/local/sbin/cinc-client-upgrade' do
  source 'cinc-client-upgrade.erb'
  variables(version: cinc_version, sha256: cinc_sha256)
  owner 'root'
  group 'root'
  mode '0700'
end

template '/etc/systemd/system/cinc-client.service' do
  source 'cinc-client.service.erb'
  mode '0644'
  notifies :run, 'execute[systemd-reload]'
end

template '/etc/systemd/system/cinc-client.timer' do
  source 'cinc-client.timer.erb'
  mode '0644'
  notifies :run, 'execute[systemd-reload]'
end

execute 'systemd-reload' do
  command 'systemctl daemon-reload'
  action :nothing
end

service 'cinc-client.timer' do
  action [:enable, :start]
end
