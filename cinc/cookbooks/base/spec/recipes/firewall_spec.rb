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

  # Each guard runs for real against a fake iptables/ip6tables: `-C` succeeds
  # only for an exact argument list in `checks` (as the kernel matches a rule,
  # not its text), while `-S` and `*-save` print `rendered`, the real `-S`
  # rendering. The old guards (`dport 22.*ACCEPT`) were satisfied by a 2222
  # rule, and the `--dport N -j ACCEPT` substring guards by a UDP or a
  # source-restricted rule for N: each silently skipped the real TCP accept.
  def guard_holds?(chef_run, resource_name, checks, rendered)
    guard = chef_run.execute(resource_name).not_if.first.command
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'checks'), checks)
      File.write(File.join(dir, 'rendered'), rendered)
      %w(iptables ip6tables).each do |bin|
        File.write(File.join(dir, bin), <<~SH)
          #!/bin/sh
          if [ "$1" = -C ]; then shift; grep -qxF -- "$*" '#{dir}/checks'; else cat '#{dir}/rendered'; fi
        SH
        File.write(File.join(dir, "#{bin}-save"), "#!/bin/sh\ncat '#{dir}/rendered'\n")
        [bin, "#{bin}-save"].each { |b| File.chmod(0o755, File.join(dir, b)) }
      end
      _out, status = Open3.capture2e({ 'PATH' => "#{dir}:/usr/bin:/bin" }, '/bin/sh', '-c', guard)
      status.success?
    end
  end

  context 'port guards match only the exact TCP accept' do
    let(:chef_run) { converge }

    { 22 => 'ssh', 80 => 'tcp-80', 443 => 'tcp-443' }.each do |port, suffix|
      %w(iptables ip6tables).each do |family|
        name = "#{family}-allow-#{suffix}"
        src = family == 'iptables' ? '192.0.2.0/24' : '2001:db8::/32'
        lookalikes = {
          'a look-alike port' => ["INPUT -p tcp --dport #{port}0 -j ACCEPT", "-A INPUT -p tcp -m tcp --dport #{port}0 -j ACCEPT"],
          'a UDP rule for the port' => ["INPUT -p udp --dport #{port} -j ACCEPT", "-A INPUT -p udp -m udp --dport #{port} -j ACCEPT"],
          'a source-restricted rule for the port' => ["INPUT -s #{src} -p tcp --dport #{port} -j ACCEPT",
                                                      "-A INPUT -s #{src} -p tcp -m tcp --dport #{port} -j ACCEPT"],
        }

        lookalikes.each do |label, (check, rendered)|
          it "#{name}: #{label} does not suppress it" do
            expect(guard_holds?(chef_run, name, "#{check}\n", "-P INPUT DROP\n#{rendered}\n")).to be(false)
          end
        end

        it "#{name}: its own rule does" do
          expect(guard_holds?(chef_run, name, "INPUT -p tcp --dport #{port} -j ACCEPT\n",
                              "-P INPUT DROP\n-A INPUT -p tcp -m tcp --dport #{port} -j ACCEPT\n")).to be(true)
        end
      end
    end
  end

  # Every v6 accept, and every v4 port accept, is guarded by `-C` with exactly
  # the arguments its command inserts — nothing narrower or different can
  # satisfy it.
  it 'guards each v6 accept and each v4 port accept with -C on its own arguments' do
    executes = converge.resource_collection.all_resources.select { |r| r.declared_type.to_s == 'execute' }
    checked = executes.select do |r|
      r.command.to_s.start_with?('ip6tables -A INPUT', 'ip6tables -I INPUT') ||
        r.command.to_s.match?(/\Aiptables -A INPUT -p tcp --dport \d+ -j ACCEPT\z/)
    end
    expect(checked.size).to eq(11)
    checked.each do |r|
      expected = r.command.sub(/\A(ip6?tables) -[AI] INPUT (\d+ )?/, '\1 -C INPUT ')
      expect(r.not_if.map(&:command)).to eq([expected]), r.to_s
    end
  end

  context 'v6 policy guards match the whole -P line' do
    let(:chef_run) { converge }
    comment = "-A INPUT -m comment --comment \"-P INPUT DROP -P OUTPUT ACCEPT\" -j ACCEPT\n"

    it 'a rule whose comment spells the policy does not suppress it' do
      expect(guard_holds?(chef_run, 'ip6tables-default-drop-input', '', "-P INPUT ACCEPT\n#{comment}")).to be(false)
      expect(guard_holds?(chef_run, 'ip6tables-default-accept-output', '', "-P OUTPUT DROP\n#{comment}")).to be(false)
    end

    it 'the policy line does' do
      expect(guard_holds?(chef_run, 'ip6tables-default-drop-input', '', "-P INPUT DROP\n")).to be(true)
      expect(guard_holds?(chef_run, 'ip6tables-default-accept-output', '', "-P OUTPUT ACCEPT\n")).to be(true)
    end
  end
end
