# Rootless Docker CE for ubuntu user
# No sudo needed, no privilege escalation vector

ubuntu_uid = shell_out('id -u ubuntu').stdout.strip
runtime_dir = "/run/user/#{ubuntu_uid}"

# Prerequisites for rootless mode
package %w(ca-certificates curl gnupg uidmap dbus-user-session slirp4netns)

# Add Docker GPG key
execute 'docker-gpg-key' do
  command <<~SH
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  SH
  not_if { ::File.exist?('/usr/share/keyrings/docker-archive-keyring.gpg') }
end

# Add Docker apt repo
file '/etc/apt/sources.list.d/docker.list' do
  content "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu #{node['lsb']['codename']} stable\n"
  mode '0644'
  notifies :run, 'execute[apt-update-docker]', :immediately
end

execute 'apt-update-docker' do
  command 'apt-get update -qq'
  action :nothing
end

# Install Docker CE (needed for rootless install script) and Compose plugin
package %w(docker-ce docker-ce-cli containerd.io docker-compose-plugin)

# Disable system-wide Docker daemon — we use rootless only.
#
# docker.socket has to go first and explicitly. Leaving it enabled means systemd
# socket-activates the rootful daemon on any connection to /var/run/docker.sock,
# so "rootless only" holds only until something touches that path — and it also
# left the service resource below reporting a stop on every single converge,
# because the socket was active while the service was not. Rootless Docker talks
# to its own socket under XDG_RUNTIME_DIR and is unaffected.
service 'docker.socket' do
  action [:disable, :stop]
end

service 'docker' do
  action [:disable, :stop]
end

# Configure subordinate UID/GID ranges for ubuntu user
execute 'setup-subuid' do
  command 'usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ubuntu'
  not_if 'grep -q "^ubuntu:" /etc/subuid'
end

# Enable lingering so rootless Docker survives logout
execute 'enable-linger-ubuntu' do
  command 'loginctl enable-linger ubuntu'
  not_if 'ls /var/lib/systemd/linger/ubuntu 2>/dev/null'
end

# Install rootless Docker for ubuntu user
# Must use su -l to get proper uid/gid context for newuidmap
execute 'install-rootless-docker' do
  command "su -l ubuntu -c 'XDG_RUNTIME_DIR=#{runtime_dir} dockerd-rootless-setuptool.sh install --force'"
  not_if { ::File.exist?('/home/ubuntu/.config/systemd/user/docker.service') }
end

# Set DOCKER_HOST in ubuntu's profile
file '/home/ubuntu/.docker-env' do
  content <<~SH
    export DOCKER_HOST=unix://#{runtime_dir}/docker.sock
    export PATH=/usr/bin:$PATH
  SH
  owner 'ubuntu'
  group 'ubuntu'
  mode '0644'
end

execute 'add-docker-env-to-bashrc' do
  command 'echo \'[ -f ~/.docker-env ] && . ~/.docker-env\' >> /home/ubuntu/.bashrc'
  user 'ubuntu'
  not_if 'grep -q docker-env /home/ubuntu/.bashrc'
end

# DOCKER_HOST for BOTH shells. ~/.docker-env + the .bashrc line above predate
# zsh being the default login shell; zsh never reads .bashrc, so without this
# the shell developers actually get talks to the disabled rootful socket.
# System-side and root-owned on purpose: /etc/zsh/zshenv must not source a
# developer-writable file, and the house rule (aws_access.rb) is a gated file
# under /etc/dev-vm that the shells' system rc files source. No PATH line —
# it is not load-bearing for DOCKER_HOST, and re-prepending /usr/bin on every
# nested zsh would invert shell_default's ~/.local/bin-first ordering.
directory '/etc/dev-vm' do
  owner 'root'
  group 'root'
  mode '0755'
end

file '/etc/dev-vm/docker-env.sh' do
  content <<~SH
    # Managed by CINC base::docker — do not edit.
    # Sourced from /etc/profile.d/dev-vm-docker.sh and /etc/zsh/zshenv.
    _dev_vm_uid=${EUID:-$(id -u)}
    if [ "$_dev_vm_uid" = "#{ubuntu_uid}" ]; then
      export DOCKER_HOST=unix://#{runtime_dir}/docker.sock
    fi
    unset _dev_vm_uid
  SH
  owner 'root'
  group 'root'
  mode '0644'
end

file '/etc/profile.d/dev-vm-docker.sh' do
  content <<~SH
    # Managed by CINC base::docker — do not edit.
    [ -r /etc/dev-vm/docker-env.sh ] && . /etc/dev-vm/docker-env.sh
  SH
  owner 'root'
  group 'root'
  mode '0644'
end
