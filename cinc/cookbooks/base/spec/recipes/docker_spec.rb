# cinc/cookbooks/base/spec/recipes/docker_spec.rb
require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::docker' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  before do
    # Every string guard in the recipe. ChefSpec raises on an unstubbed one.
    stub_command('grep -q "^ubuntu:" /etc/subuid').and_return(true)
    stub_command('ls /var/lib/systemd/linger/ubuntu 2>/dev/null').and_return(true)
    stub_command('grep -q docker-env /home/ubuntu/.bashrc').and_return(true)
    stub_command(%r{cmp -s /usr/share/dev-vm/home/.docker-env /home/ubuntu/.docker-env}).and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'stages .docker-env root-owned and copies it as ubuntu when it differs' do
    expect(chef_run).to create_file('/usr/share/dev-vm/home/.docker-env').with(owner: 'root', group: 'root', mode: '0644')
    expect(chef_run).to render_file('/usr/share/dev-vm/home/.docker-env').with_content('export DOCKER_HOST=unix://')
    expect(chef_run).to run_execute('ubuntu-docker-env').with(user: 'ubuntu', group: 'ubuntu', command: 'install -m 0644 /usr/share/dev-vm/home/.docker-env /home/ubuntu/.docker-env')
  end
end
