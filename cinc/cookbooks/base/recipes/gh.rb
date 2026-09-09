# Install GitHub CLI from cli.github.com
# Used by Claude Code via Bash tool for PR/issue operations.

execute 'gh-gpg-key' do
  command 'curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg'
  not_if { ::File.exist?('/usr/share/keyrings/githubcli-archive-keyring.gpg') }
end

file '/etc/apt/sources.list.d/github-cli.list' do
  content "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n"
  mode '0644'
  notifies :run, 'execute[apt-update-gh]', :immediately
end

execute 'apt-update-gh' do
  command 'apt-get update -qq'
  action :nothing
end

package 'gh' do
  options '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
end
