# cinc/cookbooks/base/spec/recipes/firewall_spec.rb
require 'chefspec'
require 'open3'
require 'tmpdir'

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

  # A converge that dies midway must never leave v6 at INPUT DROP with none of
  # its accepts in place: the policies come after the last accept.
  it 'sets the ip6tables default policies only after every v6 accept' do
    names = converge.resource_collection.all_resources.map(&:name)
    accepts = names.each_index.select { |i| names[i].start_with?('ip6tables-allow-') }
    expect(accepts).not_to be_empty
    %w(ip6tables-default-drop-input ip6tables-default-accept-output).each do |policy|
      expect(names.index(policy)).to be > accepts.max
    end
    expect(names.index('ip6tables-default-drop-input')).to be < names.index('save-ip6tables')
  end

  # Each port guard runs for real against a fake iptables/ip6tables that prints
  # a given rule set. The old guards (`dport 22.*ACCEPT`) were satisfied by a
  # 2222 rule, so 22 was silently never opened; same for 80 vs 8080.
  context 'port guards match the whole --dport N -j ACCEPT token' do
    let(:chef_run) { converge }

    def guard_holds?(resource_name, rules)
      guard = chef_run.execute(resource_name).not_if.first.command
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'rules'), rules)
        %w(iptables ip6tables iptables-save ip6tables-save).each do |bin|
          path = File.join(dir, bin)
          File.write(path, "#!/bin/sh\ncat '#{dir}/rules'\n")
          File.chmod(0o755, path)
        end
        _out, status = Open3.capture2e({ 'PATH' => "#{dir}:/usr/bin:/bin" }, '/bin/sh', '-c', guard)
        status.success?
      end
    end

    lookalikes = <<~RULES
      -P INPUT DROP
      -A INPUT -p tcp -m tcp --dport 2222 -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 8080 -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 4443 -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 1443 -j ACCEPT
    RULES

    { 22 => 'ssh', 80 => 'tcp-80', 443 => 'tcp-443' }.each do |port, suffix|
      %w(iptables ip6tables).each do |family|
        name = "#{family}-allow-#{suffix}"

        it "#{name}: a look-alike port does not suppress it" do
          expect(guard_holds?(name, lookalikes)).to be(false)
        end

        it "#{name}: its own rule does" do
          expect(guard_holds?(name, lookalikes + "-A INPUT -p tcp -m tcp --dport #{port} -j ACCEPT\n")).to be(true)
        end
      end
    end
  end
end
