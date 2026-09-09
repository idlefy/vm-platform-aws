# Claude Code CLI — per-user install for ubuntu, stable channel.
# Official installer is used (npm channel is deprecated by Anthropic).
# ~/.claude/ directory, statusline script, and settings.json are created
# only on first converge (action :create_if_missing). After that the user
# owns them; CINC does not re-sync.

require 'json'

execute 'install-claude-code' do
  command 'curl -fsSL https://claude.ai/install.sh | bash -s stable'
  user 'ubuntu'
  environment 'HOME' => '/home/ubuntu'
  not_if 'test -x /home/ubuntu/.local/bin/claude', user: 'ubuntu'
end

directory '/home/ubuntu/.claude' do
  owner 'ubuntu'
  group 'ubuntu'
  mode '0755'
end

cookbook_file '/home/ubuntu/.claude/statusline-command.sh' do
  source 'claude-statusline.sh'
  owner 'ubuntu'
  group 'ubuntu'
  mode '0755'
  action :create_if_missing
end

file '/home/ubuntu/.claude/settings.json' do
  content JSON.pretty_generate(
    statusLine: { type: 'command', command: 'sh /home/ubuntu/.claude/statusline-command.sh' }
  )
  owner 'ubuntu'
  group 'ubuntu'
  mode '0644'
  action :create_if_missing
end
