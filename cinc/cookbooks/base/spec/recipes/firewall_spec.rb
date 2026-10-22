# cinc/cookbooks/base/spec/recipes/firewall_spec.rb
require 'chefspec'

describe 'base::firewall' do
  def converge(ports = nil)
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
      node.override['base']['firewall']['public_web_ports'] = ports unless ports.nil?
    end.converge(described_recipe)
  end
  before { stub_command(/.*/).and_return(false) }

  context 'with the default attribute (the fleet)' do
    let(:chef_run) { converge }
    it 'keeps 80 and 443 open on both families' do
      expect(chef_run).to run_execute('iptables-allow-tcp-80').with(command: 'iptables -A INPUT -p tcp --dport 80 -j ACCEPT')
      expect(chef_run).to run_execute('iptables-allow-tcp-443')
      expect(chef_run).to run_execute('ip6tables-allow-tcp-80').with(command: 'ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT')
      expect(chef_run).to run_execute('ip6tables-allow-tcp-443')
    end
  end

  context 'with public_web_ports = [] (solo)' do
    let(:chef_run) { converge([]) }
    it 'opens no port but 22 (and the DHCPv6 client port, link-local only)' do
      executes = chef_run.resource_collection.all_resources.select { |r| r.declared_type.to_s == 'execute' }
      dports = executes.map { |r| r.command.to_s }.select { |c| c.include?('--dport') }
      expect(dports).to contain_exactly(
        'iptables -A INPUT -p tcp --dport 22 -j ACCEPT',
        'ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT',
        'ip6tables -A INPUT -p udp -s fe80::/10 --sport 547 --dport 546 -j ACCEPT'
      )
    end
  end

  it 'mirrors the v4 policy on ip6tables and accepts ICMPv6' do
    chef_run = converge
    expect(chef_run).to run_execute('ip6tables-default-drop-input').with(command: 'ip6tables -P INPUT DROP')
    expect(chef_run).to run_execute('ip6tables-default-accept-output').with(command: 'ip6tables -P OUTPUT ACCEPT')
    expect(chef_run).to run_execute('ip6tables-allow-established').with(command: 'ip6tables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT')
    expect(chef_run).to run_execute('ip6tables-allow-loopback').with(command: 'ip6tables -I INPUT 2 -i lo -j ACCEPT')
    expect(chef_run).to run_execute('ip6tables-allow-icmpv6').with(command: 'ip6tables -A INPUT -p ipv6-icmp -j ACCEPT')
    expect(chef_run).to run_execute('ip6tables-allow-dhcpv6').with(command: 'ip6tables -A INPUT -p udp -s fe80::/10 --sport 547 --dport 546 -j ACCEPT')
    expect(chef_run).to run_execute('ip6tables-allow-tailscale').with(command: 'ip6tables -A INPUT -i tailscale0 -j ACCEPT')
    expect(chef_run).to run_execute('ip6tables-allow-ssh').with(command: 'ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT')
    expect(chef_run.execute('ip6tables-allow-ssh')).to notify('execute[save-ip6tables]').to(:run).delayed
    expect(chef_run.execute('save-ip6tables').command).to eq('mkdir -p /etc/iptables && ip6tables-save > /etc/iptables/rules.v6')
  end
end
