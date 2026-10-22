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

  context 'when the snap is installed' do
    before do
      stub_command('snap list amazon-ssm-agent').and_return(true)
    end

    it_behaves_like 'root never writes under /home/ubuntu'

    it 'waits for snapd seeding, then purges the snap' do
      expect(chef_run).to run_execute('remove-amazon-ssm-agent-snap')
        .with(command: 'snap wait system seed.loaded && snap remove --purge amazon-ssm-agent')
    end
  end

  context 'when the snap is absent' do
    before do
      stub_command('snap list amazon-ssm-agent').and_return(false)
    end

    it 'does nothing' do
      expect(chef_run).not_to run_execute('remove-amazon-ssm-agent-snap')
    end
  end
end
