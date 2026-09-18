# cinc/cookbooks/base/spec/recipes/shell_default_spec.rb
#
# /etc/zsh/zshenv is how zsh reaches the gated files under /etc/dev-vm that
# other recipes write. Ubuntu's /etc/zsh/zprofile does not source /etc/profile,
# so a drop-in with no line here is invisible to every zsh on the box — and
# zsh is the login shell base::shell_default sets. That failure is silent: the
# file is written, the converge is green, and the variable is simply not there.
require 'chefspec'
require_relative '../support/home_boundary'

# Every /etc/dev-vm/*.sh the cookbook writes, and the recipe that owns it.
DEV_VM_DROPINS = {
  '/etc/dev-vm/shell-env.sh' => 'base::aws_access',
  '/etc/dev-vm/docker-env.sh' => 'base::docker',
  '/etc/dev-vm/werf-env.sh' => 'base::werf',
}.freeze

describe 'base::shell_default' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  before do
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with('/var/lib/dev-vm-platform/.zsh-default-set').and_return(true)
    allow(::File).to receive(:exist?).with('/usr/bin/fdfind').and_return(true)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'takes ownership of the system zshenv root-owned' do
    expect(chef_run).to create_file('/etc/zsh/zshenv').with(owner: 'root', group: 'root', mode: '0644')
  end

  it 'puts ~/.local/bin on PATH for zsh, which reads neither /etc/profile nor ~/.profile' do
    expect(chef_run).to render_file('/etc/zsh/zshenv').with_content('$HOME/.local/bin')
  end

  DEV_VM_DROPINS.each do |path, owner|
    it "sources #{path}, written by #{owner}" do
      expect(chef_run).to render_file('/etc/zsh/zshenv').with_content("[ -r #{path} ] && . #{path}")
    end
  end
end
