# cinc/cookbooks/base/spec/recipes/claude_code_spec.rb
require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::claude_code' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  before do
    stub_command('test -x /home/ubuntu/.local/bin/claude').and_return(true)
    stub_command('test -d /home/ubuntu/.claude').and_return(false)
    stub_command('test -e /home/ubuntu/.claude/statusline-command.sh').and_return(false)
    stub_command('test -e /home/ubuntu/.claude/settings.json').and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'declares the staging root, the new trust anchor, explicitly' do
    expect(chef_run).to create_directory('/usr/share/dev-vm/home').with(owner: 'root', group: 'root', mode: '0755')
  end

  it 'stages the two files root-owned and world-readable under /usr/share/dev-vm/home' do
    expect(chef_run).to create_directory('/usr/share/dev-vm/home/.claude').with(owner: 'root', group: 'root', mode: '0755', recursive: true)
    expect(chef_run).to create_cookbook_file('/usr/share/dev-vm/home/.claude/statusline-command.sh').with(owner: 'root', mode: '0644')
    expect(chef_run).to create_file('/usr/share/dev-vm/home/.claude/settings.json').with(owner: 'root', mode: '0644')
  end

  it 'creates the directory and copies both files as ubuntu, once' do
    expect(chef_run).to run_execute('ubuntu-claude-dir').with(user: 'ubuntu', group: 'ubuntu', command: 'install -d -m 0755 /home/ubuntu/.claude')
    expect(chef_run).to run_execute('ubuntu-claude-statusline').with(user: 'ubuntu', command: 'install -m 0755 /usr/share/dev-vm/home/.claude/statusline-command.sh /home/ubuntu/.claude/statusline-command.sh')
    expect(chef_run).to run_execute('ubuntu-claude-settings').with(user: 'ubuntu', command: 'install -m 0644 /usr/share/dev-vm/home/.claude/settings.json /home/ubuntu/.claude/settings.json')
  end

  it 'renders the settings that point at the statusline script in the home directory' do
    expect(chef_run).to render_file('/usr/share/dev-vm/home/.claude/settings.json').with_content('sh /home/ubuntu/.claude/statusline-command.sh')
  end
end
