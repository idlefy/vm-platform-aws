# SSH hardening + EC2 Instance Connect for ephemeral admin access
#
# Access model:
#   ubuntu — developer, static SSH key (AWS key pair), no sudo
#   admin  — devops/lead, EC2 Instance Connect only (ephemeral keys), full sudo

package 'ec2-instance-connect'

# Create admin user with no password, no static keys
group 'admin' do
  action :create
end

user 'admin' do
  gid 'admin'
  shell '/bin/bash'
  manage_home true
end

# Full sudo for admin — only reachable via EC2 Instance Connect
file '/etc/sudoers.d/admin' do
  content "admin ALL=(ALL) NOPASSWD:ALL\n"
  mode '0440'
end

# No static authorized_keys for admin — IC only
directory '/home/admin/.ssh' do
  owner 'admin'
  group 'admin'
  mode '0700'
end

file '/home/admin/.ssh/authorized_keys' do
  action :delete
end

file '/etc/ssh/sshd_config.d/hardening.conf' do
  content <<~SSHD
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    X11Forwarding no
    MaxAuthTries 5
    ClientAliveInterval 300
    ClientAliveCountMax 2
    AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f
    AuthorizedKeysCommandUser root
  SSHD
  mode '0644'
  notifies :restart, 'service[ssh]'
end

service 'ssh' do
  action [:enable, :start]
end
