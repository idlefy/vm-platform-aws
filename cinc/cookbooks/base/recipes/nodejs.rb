# Install Node.js 24 LTS from NodeSource
# System-wide /usr/bin/node — auto-updated via unattended-upgrades.
# Users get current LTS without nvm; npm install -g still requires sudo (denied).

execute 'nodesource-gpg-key' do
  command 'curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/nodesource.gpg --import && chmod 644 /usr/share/keyrings/nodesource.gpg'
  not_if { ::File.exist?('/usr/share/keyrings/nodesource.gpg') }
end

file '/etc/apt/sources.list.d/nodesource.list' do
  content "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main\n"
  mode '0644'
  notifies :run, 'execute[apt-update-nodesource]', :immediately
end

execute 'apt-update-nodesource' do
  command 'apt-get update -qq'
  action :nothing
end

package 'nodejs' do
  options '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
end
