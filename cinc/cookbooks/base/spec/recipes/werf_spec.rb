# cinc/cookbooks/base/spec/recipes/werf_spec.rb
require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::werf' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  before do
    stub_command('test -d /home/ubuntu/.trdl/repositories/werf').and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'installs trdl as ubuntu' do
    expect(chef_run).to run_execute('install-werf').with(user: 'ubuntu', group: 'ubuntu')
  end

  # Also declared in base::aws_access and base::docker; Chef runs all three, so
  # the declarations must stay byte-identical.
  it 'declares /etc/dev-vm explicitly rather than inheriting another recipe mkdir' do
    expect(chef_run).to create_directory('/etc/dev-vm').with(owner: 'root', group: 'root', mode: '0755')
  end

  it 'writes the activation root-owned under /etc/dev-vm' do
    expect(chef_run).to create_file('/etc/dev-vm/werf-env.sh')
      .with(owner: 'root', group: 'root', mode: '0644')
  end

  it 'wires it into bash and sh login shells' do
    expect(chef_run).to create_file('/etc/profile.d/dev-vm-werf.sh')
      .with(owner: 'root', group: 'root', mode: '0644')
    expect(chef_run).to render_file('/etc/profile.d/dev-vm-werf.sh')
      .with_content('. /etc/dev-vm/werf-env.sh')
  end

  it 'activates werf through trdl' do
    expect(chef_run).to render_file('/etc/dev-vm/werf-env.sh')
      .with_content(%r{"\$HOME/bin/trdl" use werf "2" "stable"})
  end

  # /etc/profile.d sources this into bash and sh, so the zsh spelling it
  # started as ([[ ]], whence -p) would be a syntax error there.
  it 'stays POSIX so bash and sh can source it too' do
    content = chef_run.file('/etc/dev-vm/werf-env.sh').content
    expect(content).to_not include('[[')
    expect(content).to_not include('whence')
    expect(content).to include('command -v werf')
  end

  # root and admin have no ~/bin/trdl, so the stanza costs them one failed
  # test and touches nothing. This is what keeps a system-wide file per-user.
  it 'gates on the invoking user having trdl' do
    expect(chef_run).to render_file('/etc/dev-vm/werf-env.sh')
      .with_content('[ -x "$HOME/bin/trdl" ]')
  end

  it 'does not write into the developer home' do
    # The first shape of this fix was ~/.zshenv. It is not here on purpose —
    # see the recipe comment. This keeps it from coming back by accident.
    expect(chef_run).to_not create_file('/home/ubuntu/.zshenv')
    expect(chef_run).to_not create_cookbook_file('/usr/share/dev-vm/home/.zshenv')
  end
end
