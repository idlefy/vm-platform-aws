# cinc/cookbooks/base/spec/recipes/share_helper_spec.rb
#
# base::share_helper installs /usr/local/sbin/idlefy-share and nothing else.
# The sudoers grant that makes it useful lives in base::sudoers (see
# sudoers_spec.rb); the script's own argument check is tested by
# cinc/test/test-idlefy-share.sh.
require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::share_helper' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'installs the helper root-owned and not writable by anyone else' do
    expect(chef_run).to create_cookbook_file('/usr/local/sbin/idlefy-share')
      .with(source: 'idlefy-share', owner: 'root', group: 'root', mode: '0755')
  end

  # `tailscale set --operator=ubuntu` would hand ubuntu the whole tailscaled
  # API without sudo — serve, funnel of a path, set — which is exactly what the
  # helper exists to narrow. Never configure it.
  it 'never makes ubuntu a tailscale operator' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      %i(command code content).any? do |prop|
        r.respond_to?(prop) && r.public_send(prop).to_s.include?('--operator')
      end
    end
    expect(offenders.map(&:to_s)).to eq([])
  end
end
