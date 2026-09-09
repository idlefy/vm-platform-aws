require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::traefik' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
      node.override['base']['traefik']['acme_email']  = 'admin@example.com'
      node.override['base']['traefik']['domain_root'] = 'example.com'
      node.automatic['hostname'] = 'devbox'
      node.automatic['ec2']['placement_availability_zone'] = 'eu-central-1a'
    end.converge(described_recipe)
  end

  before do
    stub_command(/getcap/).and_return(true)
    stub_command('command -v rootlesskit >/dev/null').and_return(true)
    stub_command(/docker network inspect web/).and_return(true)
    stub_command(/is-enabled traefik.service/).and_return(true)
    stub_command(/^test -d /).and_return(false)
    stub_command(/^test -e /).and_return(false)
    stub_command(/^cmp -s /).and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'creates the four directories as ubuntu' do
    expect(chef_run).to run_execute('ubuntu-traefik-dirs').with(user: 'ubuntu', group: 'ubuntu')
    cmd = chef_run.execute('ubuntu-traefik-dirs').command
    expect(cmd).to include('install -d -m 0755 /home/ubuntu/.config/traefik /home/ubuntu/.config/traefik/dynamic /home/ubuntu/.config/systemd/user')
    expect(cmd).to include('install -d -m 0700 /home/ubuntu/.local/share/traefik')
  end

  it 'generates the password as ubuntu without a chown' do
    r = chef_run.execute('generate-traefik-password')
    expect(r.user).to eq('ubuntu')
    expect(r.command).not_to include('chown')
    expect(r.command).to include('htpasswd -nbB -C 12 dev')
  end

  it 'stages the four rendered files root-owned' do
    %w(.config/traefik/traefik.yml .config/traefik/dynamic/auth.yml .config/systemd/user/traefik.service traefik-readme.md).each do |rel|
      expect(chef_run).to create_template("/usr/share/dev-vm/home/#{rel}").with(owner: 'root', group: 'root', mode: '0644')
    end
    expect(chef_run).to render_file('/usr/share/dev-vm/home/traefik-readme.md').with_content('devbox.ec2.eu-central-1.example.com')
  end

  it 'copies each rendered file as ubuntu and keeps the notifications' do
    %w(traefik-yml traefik-auth traefik-unit traefik-readme).each do |name|
      expect(chef_run).to run_execute("ubuntu-#{name}").with(user: 'ubuntu', group: 'ubuntu')
    end
    expect(chef_run.execute('ubuntu-traefik-yml')).to notify('execute[restart-traefik]').to(:run).delayed
    expect(chef_run.execute('ubuntu-traefik-unit')).to notify('execute[systemd-user-reload]').to(:run).immediately
    expect(chef_run.execute('ubuntu-traefik-unit')).to notify('execute[restart-traefik]').to(:run).delayed
    expect(chef_run.execute('ubuntu-traefik-auth')).not_to notify('execute[restart-traefik]')
  end
end
