# cinc/cookbooks/base/spec/recipes/alloy_spec.rb
#
# base::alloy has two branches on node['base']['loki']['enabled']. Off must
# be a real teardown — a switch that only stops installing would leave Alloy
# shipping on its last token while reporting "off" — and on must refuse the
# skeleton's REPLACE_ME placeholders instead of rendering them into a URL.
require 'chefspec'
# Chef loads libraries/ itself at converge, but the stub below runs first and
# needs the constant. No redefinition warning results (measured 2026-09-05).
require_relative '../../libraries/imds'

describe 'base::alloy' do
  def runner(enabled: nil, url: 'https://logs.example.grafana.net/loki/api/v1/push', username: '12345',
             step_into: [])
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04', step_into: step_into) do |node|
      node.override['base']['loki']['enabled'] = enabled unless enabled.nil?
      node.override['base']['loki']['url']                = url unless url.nil?
      node.override['base']['loki']['username']           = username unless username.nil?
      node.override['base']['loki']['ssm_parameter_name'] = '/test/loki-token'
      # Takes the Ohai branch of the public-IP lookup so no IMDS shell_out runs.
      node.automatic['ec2']['public_ipv4'] = '203.0.113.5'
    end
  end

  before do
    # Not strictly required for a pass, but without it the suite curls
    # 169.254.169.254 and takes ~4 s instead of ~0.2 s.
    allow(DevVm::Imds).to receive(:region).and_return('eu-central-1')
  end

  context 'with log shipping disabled' do
    let(:chef_run) { runner(enabled: false).converge(described_recipe) }

    it 'stops and disables the service' do
      expect(chef_run).to stop_service('alloy')
      expect(chef_run).to disable_service('alloy')
    end

    it 'purges the package and removes the alloy account and group' do
      expect(chef_run).to purge_package('alloy')
      expect(chef_run).to remove_user('alloy')
      expect(chef_run).to remove_group('alloy')
    end

    it 'deletes the token directory, the WAL, the fetch script and the apt source' do
      expect(chef_run).to delete_directory('/etc/alloy').with(recursive: true)
      expect(chef_run).to delete_directory('/var/lib/alloy').with(recursive: true)
      expect(chef_run).to delete_file('/usr/local/sbin/dev-vm-loki-token')
      expect(chef_run).to delete_file('/etc/apt/sources.list.d/grafana.list')
      expect(chef_run).to delete_file('/etc/apt/keyrings/grafana.asc')
    end

    it 'declares none of the install-side resources' do
      expect(chef_run.find_resource(:template, '/etc/alloy/config.alloy')).to be_nil
      expect(chef_run.find_resource(:execute, 'dev-vm-loki-token')).to be_nil
      expect(chef_run.find_resource(:execute, 'alloy-gpg-key')).to be_nil
    end

    it 'does not notify anything (a notification to an undeclared resource aborts compile)' do
      chef_run.resource_collection.each do |r|
        expect(r.immediate_notifications + r.delayed_notifications).to be_empty, "#{r} notifies"
      end
    end

    it 'converges with url and username absent (the return precedes the guard)' do
      run = runner(enabled: false, url: nil, username: nil, step_into: ['ruby_block']).converge(described_recipe)
      expect(run).to purge_package('alloy')
    end
  end

  context 'with log shipping enabled and a configured tenant' do
    let(:chef_run) { runner(enabled: true).converge(described_recipe) }

    it 'installs the pinned package, renders the config and runs the service' do
      expect(chef_run).to install_package('alloy').with(version: '1.18.0-1')
      expect(chef_run).to create_template('/etc/alloy/config.alloy')
      expect(chef_run).to enable_service('alloy')
      expect(chef_run).to start_service('alloy')
    end

    it 'declares no teardown resources' do
      expect(chef_run.find_resource(:user, 'alloy')).to be_nil
      expect(chef_run).not_to purge_package('alloy')
    end

    it 'declares the placeholder guard as a converge-time resource' do
      expect(chef_run).to run_ruby_block('base::alloy: refuse placeholder loki attributes')
    end
  end

  context 'with no enabled override (cookbook default true)' do
    let(:chef_run) { runner.converge(described_recipe) }

    it 'ships — the default is true' do
      expect(chef_run).to install_package('alloy')
    end
  end

  context 'with log shipping enabled but the tenant attributes unset' do
    it 'refuses an empty url' do
      expect { runner(enabled: true, url: '', step_into: ['ruby_block']).converge(described_recipe) }
        .to raise_error(ArgumentError, /\['url'\] is ''/)
    end

    it 'refuses the skeleton placeholder' do
      expect { runner(enabled: true, username: 'REPLACE_ME', step_into: ['ruby_block']).converge(described_recipe) }
        .to raise_error(ArgumentError, /\['username'\] is 'REPLACE_ME'/)
    end
  end
end
