# cinc/cookbooks/base/spec/recipes/codex_spec.rb
require 'chefspec'
require_relative '../support/home_boundary'

BWRAP_PROFILE_SRC = '/usr/share/apparmor/extra-profiles/bwrap-userns-restrict'.freeze
BWRAP_PROFILE_DST = '/etc/apparmor.d/bwrap-userns-restrict'.freeze

describe 'base::codex' do
  let(:profile_source_present) { true }

  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  before do
    stub_command('test -x /home/ubuntu/.local/bin/codex').and_return(false)
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with(BWRAP_PROFILE_SRC).and_return(profile_source_present)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'installs the CLI as ubuntu via the official installer, once' do
    expect(chef_run).to run_execute('install-codex').with(
      user: 'ubuntu',
      group: 'ubuntu',
      command: 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
    )
  end

  # Codex prefers the first bwrap on PATH and only falls back to the copy it
  # bundles under ~/.codex when none is found. The package is what moves the
  # sandbox onto a path the AppArmor profile below can reach.
  it 'installs bubblewrap and the package that carries the profile' do
    expect(chef_run).to install_package('bubblewrap')
    expect(chef_run).to install_package('apparmor-profiles')
  end

  it 'loads the bwrap userns profile from the distro copy and reparses it on change' do
    expect(chef_run).to create_remote_file(BWRAP_PROFILE_DST).with(
      source: ["file://#{BWRAP_PROFILE_SRC}"],
      owner: 'root',
      group: 'root',
      mode: '0644'
    )
    expect(chef_run.remote_file(BWRAP_PROFILE_DST))
      .to notify('execute[apparmor-reload-bwrap]').to(:run).immediately
  end

  it 'stays quiet when the profile is in place' do
    expect(chef_run).to_not write_log('codex-bwrap-userns-profile-missing')
  end

  # Setting kernel.apparmor_restrict_unprivileged_userns to 0 lifts the
  # restriction for every binary on the VM, not just bwrap. The profile is the
  # narrow fix; this is what a future "simplification" to the broad one fails.
  it 'does not touch the fleet-wide userns sysctl' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      parts = []
      parts << r.content if r.respond_to?(:content)
      parts << r.command if r.respond_to?(:command)
      parts.compact.join(' ').include?('apparmor_restrict_unprivileged_userns')
    end
    expect(offenders.map(&:to_s)).to eq([])
  end

  context 'when the distro does not ship the profile' do
    let(:profile_source_present) { false }

    it 'skips the copy and warns instead of failing the converge' do
      expect(chef_run).to_not create_remote_file(BWRAP_PROFILE_DST)
      expect(chef_run).to write_log('codex-bwrap-userns-profile-missing').with(level: :warn)
    end
  end
end
