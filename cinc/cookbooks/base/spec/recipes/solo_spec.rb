# cinc/cookbooks/base/spec/recipes/solo_spec.rb
#
# One converge of the solo run list with the attributes policyfiles/solo.rb
# sets. It pins three things: which recipes a solo box gets and which it must
# never get (law A1 — nothing on the box takes instructions from Idlefy after
# launch), the home-directory boundary across all of them, and that the
# Policyfile's attributes actually win at the precedence a Policyfile uses.
require 'chefspec'
require_relative '../../libraries/imds'
require_relative '../../libraries/imds_firewall'
require_relative '../../libraries/snap'
require_relative '../support/home_boundary'

SOLO_RECIPES = %w(
  packages firewall ssh imds sudoers fail2ban unattended_upgrades chrony sysctl
  docker werf kubernetes nodejs claude_code codex gh shell_default yq uv
  tailscale hardened_firstboot share_helper no_ssm_agent
).freeze

SOLO_EXCLUDED = %w(cinc_client aws_access traefik falco alloy nvidia_docker).freeze

SOLO_FORBIDDEN_SERVICES = %w(cinc-client alloy falco-modern-bpf aws-vm-credentials traefik).freeze

SOLO_FORBIDDEN_TEXT = /dev-vm-policy-fetch|cinc-client|--operator/.freeze

def solo_resource_text(r)
  %i(command content code).map { |m| r.respond_to?(m) ? r.public_send(m).to_s : '' }.join("\n")
end

RSpec.shared_examples 'solo: public web ports closed' do
  it 'opens no execute for port 80 or 443' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      r.declared_type.to_s == 'execute' && r.command.to_s.match?(/--dport (80|443)\b/)
    end
    expect(offenders.map(&:to_s)).to eq([])
  end
end

RSpec.shared_examples 'solo: share grant and no Grafana origin' do
  it 'grants ubuntu idlefy-share' do
    expect(chef_run).to create_file('/etc/sudoers.d/51-idlefy-share')
  end

  it 'leaves apt.grafana.com out of the unattended-upgrades overrides' do
    expect(chef_run).to(render_file('/etc/apt/apt.conf.d/52unattended-upgrades-overrides')
      .with_content { |c| expect(c).not_to include('apt.grafana.com') })
  end
end

describe 'base::solo' do
  def stub_world
    allow(DevVm::Imds).to receive(:region).and_return('eu-central-1')
    allow(::File).to receive(:exist?).and_call_original
    # Guards never remove a resource from the collection — they only decide
    # whether its action runs — so one answer for all of them is enough.
    stub_command(/.*/).and_return(false)
    # Except the SSM snap guard: answer "installed", so the removal is in the run.
    allow(DevVm::Snap).to receive(:installed?).with('amazon-ssm-agent').and_return(true)
    # base::imds computes the DROP's position from the live OUTPUT chain.
    allow(DevVm::ImdsFirewall).to receive(:list_output).and_return("-P OUTPUT ACCEPT\n")
  end

  before { stub_world }

  context 'with the Policyfile attributes as overrides' do
    let(:chef_run) do
      ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
        node.override['base']['loki']['enabled']              = false
        node.override['base']['firewall']['public_web_ports'] = []
        node.override['base']['share_helper']['enabled']      = true
        node.automatic['hostname'] = 'devbox'
      end.converge(described_recipe)
    end

    it_behaves_like 'root never writes under /home/ubuntu'
    it_behaves_like 'solo: public web ports closed'
    it_behaves_like 'solo: share grant and no Grafana origin'

    SOLO_RECIPES.each do |r|
      it("includes base::#{r}") { expect(chef_run).to include_recipe("base::#{r}") }
    end

    SOLO_EXCLUDED.each do |r|
      it("does not include base::#{r}") { expect(chef_run).not_to include_recipe("base::#{r}") }
    end

    context 'law A1: nothing takes instructions from Idlefy after launch' do
      let(:resources) { chef_run.resource_collection.all_resources }

      it 'declares no timer' do
        offenders = resources.select do |r|
          [r.name, (r.respond_to?(:path) ? r.path : nil)].compact.any? { |v| v.to_s.end_with?('.timer') }
        end
        expect(offenders.map(&:to_s)).to eq([])
      end

      it 'declares none of the fleet services' do
        offenders = resources.select do |r|
          r.declared_type.to_s == 'service' && SOLO_FORBIDDEN_SERVICES.include?(r.service_name.to_s)
        end
        expect(offenders.map(&:to_s)).to eq([])
      end

      it 'mentions no policy fetch, cinc-client or Tailscale operator in any command, content or code' do
        offenders = resources.select { |r| solo_resource_text(r).match?(SOLO_FORBIDDEN_TEXT) }
        expect(offenders.map(&:to_s)).to eq([])
      end

      # bash/script resources carry their shell in `code`, not `command`.
      it 'scans the code of script resources too' do
        script = Struct.new(:code).new('cinc-client -z')
        expect(solo_resource_text(script)).to match(SOLO_FORBIDDEN_TEXT)
      end
    end

    it 'keeps SSH and blocks IMDS over IPv6' do
      expect(chef_run).to run_execute('ip6tables-allow-ssh')
      expect(chef_run).to run_execute('ip6tables-imds-deny-all')
    end

    it 'installs the share helper' do
      expect(chef_run).to create_cookbook_file('/usr/local/sbin/idlefy-share')
    end

    it 'enables the hardened first-boot unit' do
      expect(chef_run).to enable_systemd_unit('idlefy-hardened-firstboot.service')
    end

    it 'removes the SSM agent snap' do
      expect(chef_run).to run_execute('remove-amazon-ssm-agent-snap')
    end

    it 'keeps the EC2 Instance Connect admin path, the agents and Tailscale' do
      expect(chef_run).to install_package('ec2-instance-connect')
      expect(chef_run).to create_user('admin')
      expect(chef_run).to run_execute('install-claude-code')
      expect(chef_run).to run_execute('install-codex')
      expect(chef_run).to install_package('tailscale')
    end
  end

  # The levels policyfiles/solo.rb really uses. A Policyfile's `default[...]`
  # lands at role_default and its `override[...]` at role_override
  # (Chef::PolicyBuilder::Policyfile#apply_policyfile_attributes). ChefSpec's
  # default_attributes / override_attributes options write those same two
  # levels after the run list is expanded; setting node.role_default in the
  # runner block does not survive, the expansion resets it.
  #
  # public_web_ports is an `override` in the Policyfile, not a `default`: Chef
  # unions arrays across every default level, so a role_default [] merged with
  # the cookbook's [80, 443] is still [80, 443] (measured, chef 19.3.14). The
  # last context below keeps that trap from being "simplified" back.
  context 'with the attributes at the precedence a Policyfile uses' do
    let(:chef_run) do
      ChefSpec::SoloRunner.new(
        platform: 'ubuntu', version: '24.04',
        default_attributes: {
          'base' => {
            'loki' => { 'enabled' => false },
            'share_helper' => { 'enabled' => true },
          },
        },
        override_attributes: {
          'base' => { 'firewall' => { 'public_web_ports' => [] } },
        }
      ) do |node|
        node.automatic['hostname'] = 'devbox'
      end.converge(described_recipe)
    end

    it_behaves_like 'solo: public web ports closed'
    it_behaves_like 'solo: share grant and no Grafana origin'
  end

  context 'with public_web_ports = [] at the default level (the trap)' do
    let(:chef_run) do
      ChefSpec::SoloRunner.new(
        platform: 'ubuntu', version: '24.04',
        default_attributes: { 'base' => { 'firewall' => { 'public_web_ports' => [] } } }
      ) do |node|
        node.automatic['hostname'] = 'devbox'
      end.converge(described_recipe)
    end

    it 'still opens 80 and 443, which is why the Policyfile uses override' do
      expect(chef_run).to run_execute('iptables-allow-tcp-80')
      expect(chef_run).to run_execute('ip6tables-allow-tcp-443')
    end
  end
end
