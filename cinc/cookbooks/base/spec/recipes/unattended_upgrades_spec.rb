# cinc/cookbooks/base/spec/recipes/unattended_upgrades_spec.rb
#
# The Alloy pin is two halves: `package 'alloy' version` in alloy.rb and the
# Package-Blacklist entry here. With shipping disabled there is no package to
# protect, so both Grafana lines follow node['base']['loki']['enabled'] and
# Falco's stay put. This spec pins that pairing.
require 'chefspec'

describe 'base::unattended_upgrades' do
  let(:overrides) { '/etc/apt/apt.conf.d/52unattended-upgrades-overrides' }

  def converge(enabled)
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
      node.override['base']['loki']['enabled'] = enabled
    end.converge(described_recipe)
  end

  context 'with log shipping enabled (the default)' do
    let(:chef_run) { converge(true) }

    it 'blacklists alloy and allows the Grafana origin' do
      expect(chef_run).to render_file(overrides).with_content(/^\s*"alloy";$/)
      expect(chef_run).to render_file(overrides).with_content(/^\s*"site=apt\.grafana\.com";$/)
    end

    it 'still blacklists falco' do
      expect(chef_run).to render_file(overrides).with_content(/^\s*"falco";$/)
    end
  end

  context 'with log shipping disabled' do
    let(:chef_run) { converge(false) }

    it 'still renders the overrides file' do
      # not_to render_file(...).with_content also passes when the file is never
      # rendered at all; this example keeps the two below honest.
      expect(chef_run).to render_file(overrides)
    end

    it 'renders neither Grafana line' do
      expect(chef_run).not_to render_file(overrides).with_content(/"alloy";/)
      expect(chef_run).not_to render_file(overrides).with_content(/apt\.grafana\.com/)
    end

    it 'still blacklists falco' do
      expect(chef_run).to render_file(overrides).with_content(/^\s*"falco";$/)
    end
  end
end
