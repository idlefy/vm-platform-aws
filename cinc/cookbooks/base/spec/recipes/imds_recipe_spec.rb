# cinc/cookbooks/base/spec/recipes/imds_recipe_spec.rb
require 'chefspec'
require 'open3'
require 'tmpdir'
require_relative '../../libraries/imds_firewall'

IMDS_FAMILIES = {
  'iptables' => { addr: '169.254.169.254', cidr: '169.254.169.254/32', prefix: 32 },
  'ip6tables' => { addr: 'fd00:ec2::254', cidr: 'fd00:ec2::254/128', prefix: 128 },
}.freeze

# `<bin> -S OUTPUT` as the real tools render it, for the allows in `uids`.
def imds_output_rules(cidr, uids)
  (['-P OUTPUT ACCEPT'] + uids.map { |u| "-A OUTPUT -d #{cidr} -m owner --uid-owner #{u} -j ACCEPT" }).join("\n") + "\n"
end

describe 'base::imds' do
  let(:chef_run) { ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe) }
  before do
    stub_command(/.*/).and_return(false)
    # A normal host when the DROP is computed: root and Instance Connect allowed.
    allow(DevVm::ImdsFirewall).to receive(:list_output) { |bin| imds_output_rules(IMDS_FAMILIES[bin][:cidr], [0, 1001]) }
  end

  it 'blocks the IPv6 IMDS endpoint for everyone but root and the EIC uid, and persists rules.v6' do
    expect(chef_run).to run_execute('ip6tables-imds-allow-root').with(command: 'ip6tables -I OUTPUT 1 -d fd00:ec2::254 -m owner --uid-owner 0 -j ACCEPT')
    expect(chef_run.execute('ip6tables-imds-allow-eic').command).to match(/\Aip6tables -I OUTPUT 2 -d fd00:ec2::254 -m owner --uid-owner \d* -j ACCEPT\z/)
    expect(chef_run).to run_execute('ip6tables-imds-deny-all').with(command: 'ip6tables -I OUTPUT 3 -d fd00:ec2::254 -j DROP')
    expect(chef_run.execute('ip6tables-imds-deny-all')).to notify('execute[save-ip6tables-rules]').to(:run).immediately
    expect(chef_run.execute('save-ip6tables-rules').command).to eq('mkdir -p /etc/iptables && ip6tables-save > /etc/iptables/rules.v6')
  end

  # On a normal host (both allows present) the computed DROP command is the
  # one the fleet has always run.
  it 'keeps the v4 commands byte for byte on a normal host' do
    expect(chef_run).to run_execute('iptables-imds-allow-root').with(command: 'iptables -I OUTPUT 1 -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT')
    expect(chef_run).to run_execute('iptables-imds-deny-all').with(command: 'iptables -I OUTPUT 3 -d 169.254.169.254 -j DROP')
    expect(chef_run.execute('save-iptables-rules').command).to eq('mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4')
  end

  IMDS_FAMILIES.each do |bin, f|
    context "#{bin}: the DROP lands after every allow present" do
      # A chain model with the kernel's one positional rule: -I N needs
      # N <= length + 1 ("Index of insertion too big" otherwise).
      def insert(chain, pos, rule)
        raise ArgumentError, "Index of insertion too big (#{pos} into #{chain.size})" if pos > chain.size + 1
        chain.insert(pos - 1, rule)
      end

      def render(chain)
        "-P OUTPUT ACCEPT\n" + chain.map { |r| "-A OUTPUT #{r}\n" }.join
      end

      { 'Instance Connect user present' => [0, 1001], 'Instance Connect user missing' => [0] }.each do |label, uids|
        it "#{label}: every allow precedes the DROP" do
          chain = []
          insert(chain, 1, "-d #{f[:cidr]} -m owner --uid-owner 0 -j ACCEPT")
          insert(chain, 2, "-d #{f[:cidr]} -m owner --uid-owner 1001 -j ACCEPT") if uids.include?(1001)
          pos = DevVm::ImdsFirewall.drop_position(render(chain), f[:cidr])
          insert(chain, pos, "-d #{f[:cidr]} -j DROP")
          drop = chain.index("-d #{f[:cidr]} -j DROP")
          allows = chain.each_index.select { |i| chain[i].include?('--uid-owner') }
          expect(allows.size).to eq(uids.size)
          expect(allows.max).to be < drop
        end
      end

      it 'Instance Connect user missing: the old fixed position 3 cannot be inserted' do
        chain = ["-d #{f[:cidr]} -m owner --uid-owner 0 -j ACCEPT"]
        expect { insert(chain, 3, "-d #{f[:cidr]} -j DROP") }.to raise_error(ArgumentError, /too big/)
      end

      it 'the recipe inserts the DROP at 2 when only the root allow is present' do
        allow(DevVm::ImdsFirewall).to receive(:list_output).with(bin).and_return(imds_output_rules(f[:cidr], [0]))
        expect(chef_run.execute("#{bin}-imds-deny-all").command).to eq("#{bin} -I OUTPUT 2 -d #{f[:addr]} -j DROP")
      end

      it 'ignores other rules: the DROP follows the last IMDS owner-allow' do
        rules = imds_output_rules(f[:cidr], [0, 1001]) + "-A OUTPUT -d #{f[:cidr]} -j LOG\n-A OUTPUT -j ACCEPT\n"
        expect(DevVm::ImdsFirewall.drop_position(rules, f[:cidr])).to eq(3)
        expect(DevVm::ImdsFirewall.drop_position("-P OUTPUT ACCEPT\n-A OUTPUT -j ts-output\n" + rules.lines.drop(1).join, f[:cidr])).to eq(4)
      end

      it 'with no allow at all, the DROP goes first (fail closed)' do
        expect(DevVm::ImdsFirewall.drop_position("-P OUTPUT ACCEPT\n", f[:cidr])).to eq(1)
      end
    end
  end

  # Each string guard runs for real against a fake iptables/ip6tables:
  # `-C` succeeds only for an exact argument list in `checks` (as the kernel
  # matches a rule), while `-S` and `*-save` print `rendered`. The old guards
  # grepped all of `*-save`, so a DROP for the IMDS address in FORWARD (or any
  # other chain or table) skipped the OUTPUT DROP.
  context 'guards check the OUTPUT chain only' do
    def guard_holds?(resource_name, checks, rendered)
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

    IMDS_FAMILIES.each do |bin, f|
      it "#{bin}-imds-deny-all: a DROP in FORWARD does not suppress it" do
        expect(guard_holds?("#{bin}-imds-deny-all", "FORWARD -d #{f[:addr]} -j DROP\n",
                            "-A FORWARD -d #{f[:cidr]} -j DROP\n")).to be(false)
      end

      it "#{bin}-imds-deny-all: its own OUTPUT DROP does" do
        expect(guard_holds?("#{bin}-imds-deny-all", "OUTPUT -d #{f[:addr]} -j DROP\n",
                            "-A OUTPUT -d #{f[:cidr]} -j DROP\n")).to be(true)
      end

      it "#{bin}-imds-allow-root: an allow outside OUTPUT does not suppress it" do
        expect(guard_holds?("#{bin}-imds-allow-root", "POSTROUTING -d #{f[:addr]} -m owner --uid-owner 0 -j ACCEPT\n",
                            "-A POSTROUTING -d #{f[:cidr]} -m owner --uid-owner 0 -j ACCEPT\n")).to be(false)
      end

      it "#{bin}: each guard checks exactly the rule its command inserts" do
        root = chef_run.execute("#{bin}-imds-allow-root")
        expect(root.not_if.first.command).to eq(root.command.sub(/\A#{bin} -I OUTPUT 1 /, "#{bin} -C OUTPUT "))
        deny = chef_run.execute("#{bin}-imds-deny-all")
        expect(deny.not_if.first.command).to eq(deny.command.sub(/\A#{bin} -I OUTPUT \d+ /, "#{bin} -C OUTPUT "))
      end
    end
  end
end
