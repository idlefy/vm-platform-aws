# cinc/cookbooks/base/spec/recipes/sudoers_spec.rb
#
# base::sudoers is where every privilege ubuntu keeps is decided. Two grants:
# `tailscale login` always, and `idlefy-share` only when
# node['base']['share_helper']['enabled'] (the solo profile).
require 'chefspec'

describe 'base::sudoers' do
  def converge(enabled)
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
      node.override['base']['share_helper']['enabled'] = enabled unless enabled.nil?
    end.converge(described_recipe)
  end

  before { stub_command(/.*/).and_return(false) }

  SHARE_GRANT = '/etc/sudoers.d/51-idlefy-share'.freeze
  LOGIN_GRANT = '/etc/sudoers.d/50-tailscale-login'.freeze

  context 'when the share helper is enabled' do
    let(:chef_run) { converge(true) }

    it 'writes the idlefy-share grant root-owned, 0440, checked by visudo' do
      expect(chef_run).to create_file(SHARE_GRANT).with(owner: 'root', group: 'root', mode: '0440')
      verifications = chef_run.file(SHARE_GRANT).verify.map { |v| v.instance_variable_get(:@command) }
      expect(verifications).to eq(['visudo -cf %{path}'])
    end

    it 'grants exactly the helper, with any arguments, and nothing else' do
      expect(chef_run).to render_file(SHARE_GRANT)
        .with_content("ubuntu ALL=(root) NOPASSWD: /usr/local/sbin/idlefy-share *\n")
    end

    # The user-scoped `Defaults:ubuntu !authenticate` lives in 50-tailscale-login
    # once; a second copy here would be harmless today and a trap the day one of
    # the two files is removed.
    it 'carries no Defaults line of its own' do
      expect(chef_run).to render_file(SHARE_GRANT).with_content { |c| expect(c).not_to include('Defaults') }
    end
  end

  context 'when the share helper is disabled (the default)' do
    let(:chef_run) { converge(nil) }

    it 'deletes the idlefy-share grant' do
      expect(chef_run).to delete_file(SHARE_GRANT)
    end

    it 'does not create it' do
      expect(chef_run).not_to create_file(SHARE_GRANT)
    end
  end

  [true, false].each do |enabled|
    context "with share_helper.enabled = #{enabled}" do
      let(:chef_run) { converge(enabled) }

      it 'leaves the tailscale login grant unchanged' do
        expect(chef_run).to render_file(LOGIN_GRANT)
          .with_content("Defaults:ubuntu !authenticate\nubuntu ALL=(root) NOPASSWD: /usr/bin/tailscale login\n")
      end

      it 'still deletes the cloud-init sudoers fragment' do
        expect(chef_run).to delete_file('/etc/sudoers.d/90-cloud-init-users')
      end
    end
  end
end
