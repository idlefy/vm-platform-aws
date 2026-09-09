# Claude Code CLI — per-user install for ubuntu, stable channel.
# Official installer is used (npm channel is deprecated by Anthropic).
# The statusline script and settings.json are staged by root under
# /usr/share/dev-vm/home and copied into ~/.claude/ by an execute running as
# ubuntu, once. After that the user owns them; CINC does not re-sync.

require 'json'

execute 'install-claude-code' do
  command 'curl -fsSL https://claude.ai/install.sh | bash -s stable'
  user 'ubuntu'
  environment 'HOME' => '/home/ubuntu'
  not_if 'test -x /home/ubuntu/.local/bin/claude', user: 'ubuntu'
end

# Root never writes under /home/ubuntu. Chef's directory provider follows a
# symlink the developer can plant there, and file/template check only the leaf
# — so root stages content under /usr/share/dev-vm/home and ubuntu copies it
# into place with its own privileges. See docs/design/first-external-review.md
# §1 and spec/support/home_boundary.rb, which fails any recipe that regresses.
staged = '/usr/share/dev-vm/home/.claude'

directory staged do
  owner 'root'
  group 'root'
  mode '0755'
  recursive true
end

cookbook_file "#{staged}/statusline-command.sh" do
  source 'claude-statusline.sh'
  owner 'root'
  group 'root'
  mode '0644'
end

file "#{staged}/settings.json" do
  content JSON.pretty_generate(
    statusLine: { type: 'command', command: 'sh /home/ubuntu/.claude/statusline-command.sh' }
  )
  owner 'root'
  group 'root'
  mode '0644'
end

execute 'ubuntu-claude-dir' do
  command 'install -d -m 0755 /home/ubuntu/.claude'
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -d /home/ubuntu/.claude', user: 'ubuntu'
end

# Both were create_if_missing before and stay create-once: after the first
# converge the developer owns them and CINC does not re-sync.
execute 'ubuntu-claude-statusline' do
  command "install -m 0755 #{staged}/statusline-command.sh /home/ubuntu/.claude/statusline-command.sh"
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -e /home/ubuntu/.claude/statusline-command.sh', user: 'ubuntu'
end

execute 'ubuntu-claude-settings' do
  command "install -m 0644 #{staged}/settings.json /home/ubuntu/.claude/settings.json"
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -e /home/ubuntu/.claude/settings.json', user: 'ubuntu'
end
