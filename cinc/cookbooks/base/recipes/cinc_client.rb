# Ensure cinc-client runs on schedule and at boot
# Re-reads EC2 tags (including PolicyName) each run

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
