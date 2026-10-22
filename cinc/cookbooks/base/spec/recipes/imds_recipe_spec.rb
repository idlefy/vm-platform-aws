# cinc/cookbooks/base/spec/recipes/imds_recipe_spec.rb
require 'chefspec'

describe 'base::imds' do
  let(:chef_run) { ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe) }
  before { stub_command(/.*/).and_return(false) }

  it 'blocks the IPv6 IMDS endpoint for everyone but root and the EIC uid, and persists rules.v6' do
    expect(chef_run).to run_execute('ip6tables-imds-allow-root').with(command: 'ip6tables -I OUTPUT 1 -d fd00:ec2::254 -m owner --uid-owner 0 -j ACCEPT')
    expect(chef_run.execute('ip6tables-imds-allow-eic').command).to match(/\Aip6tables -I OUTPUT 2 -d fd00:ec2::254 -m owner --uid-owner \d* -j ACCEPT\z/)
    expect(chef_run).to run_execute('ip6tables-imds-deny-all').with(command: 'ip6tables -I OUTPUT 3 -d fd00:ec2::254 -j DROP')
    expect(chef_run.execute('ip6tables-imds-deny-all')).to notify('execute[save-ip6tables-rules]').to(:run).immediately
    expect(chef_run.execute('save-ip6tables-rules').command).to eq('mkdir -p /etc/iptables && ip6tables-save > /etc/iptables/rules.v6')
  end

  it 'keeps the v4 rules byte for byte' do
    expect(chef_run).to run_execute('iptables-imds-deny-all').with(command: 'iptables -I OUTPUT 3 -d 169.254.169.254 -j DROP')
  end
end
