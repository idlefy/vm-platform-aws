# cinc/cookbooks/base/spec/recipes/no_ssm_agent_spec.rb
#
# base::no_ssm_agent removes the amazon-ssm-agent snap (law A1: no in-guest
# channel for Idlefy after launch). Included only by base::solo.
require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::no_ssm_agent' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  before do
    stub_command('snap list amazon-ssm-agent').and_return(true)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'purges the snap when it is installed' do
    expect(chef_run).to run_execute('remove-amazon-ssm-agent-snap')
      .with(command: 'snap remove --purge amazon-ssm-agent')
  end
end
