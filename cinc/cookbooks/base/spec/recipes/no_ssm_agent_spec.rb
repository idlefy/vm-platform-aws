# cinc/cookbooks/base/spec/recipes/no_ssm_agent_spec.rb
#
# base::no_ssm_agent removes the amazon-ssm-agent snap (law A1: no in-guest
# channel for Idlefy after launch). Included only by base::solo.
require 'chefspec'
require 'mixlib/shellout'
require_relative '../../libraries/snap'
require_relative '../support/home_boundary'

describe 'base::no_ssm_agent' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  context 'when the snap is installed' do
    before { allow(DevVm::Snap).to receive(:installed?).with('amazon-ssm-agent').and_return(true) }

    it_behaves_like 'root never writes under /home/ubuntu'

    it 'purges the snap, then asserts it is gone' do
      expect(chef_run).to run_execute('remove-amazon-ssm-agent-snap')
        .with(command: 'snap remove --purge amazon-ssm-agent')
      expect(chef_run.execute('remove-amazon-ssm-agent-snap'))
        .to notify('ruby_block[assert-amazon-ssm-agent-removed]').to(:run).immediately
      expect(chef_run.ruby_block('assert-amazon-ssm-agent-removed').action).to eq([:nothing])
    end

    it 'the assertion fails the converge while snapd still lists the snap' do
      block = chef_run.ruby_block('assert-amazon-ssm-agent-removed').block
      expect { block.call }.to raise_error(RuntimeError, /still installed/)
      allow(DevVm::Snap).to receive(:installed?).with('amazon-ssm-agent').and_return(false)
      expect { block.call }.not_to raise_error
    end
  end

  context 'when the snap is absent' do
    before { allow(DevVm::Snap).to receive(:installed?).with('amazon-ssm-agent').and_return(false) }

    it 'does nothing' do
      expect(chef_run).not_to run_execute('remove-amazon-ssm-agent-snap')
    end
  end

  # A shell guard read "snapd failed" as "absent" and skipped the removal; the
  # guard is now Ruby, and its exception fails the converge.
  context 'when snapd cannot be asked' do
    before do
      allow(DevVm::Snap).to receive(:installed?).and_raise(Mixlib::ShellOut::ShellCommandFailed, 'error: cannot communicate with server')
    end

    it 'fails the converge instead of skipping the removal' do
      expect { chef_run }.to raise_error(Mixlib::ShellOut::ShellCommandFailed, /cannot communicate/)
    end
  end
end

describe DevVm::Snap do
  let(:listing) do
    <<~OUT
      Name              Version   Rev    Tracking         Publisher    Notes
      amazon-ssm-agent  3.3.0.0   9881   latest/stable/…  aws✓         classic
      core22            20260909  2987   latest/stable    canonical✓   base
    OUT
  end

  def failed(cmd)
    Mixlib::ShellOut::ShellCommandFailed.new("Expected process to exit with [0], but received '1' -- #{cmd}")
  end

  it 'waits for seeding, bounded by timeout 600, before listing' do
    calls = []
    allow(described_class).to receive(:run!) do |*argv|
      calls << argv
      argv.include?('list') ? listing : ''
    end
    expect(described_class.installed?('amazon-ssm-agent')).to be(true)
    expect(calls).to eq([%w(timeout 600 snap wait system seed.loaded), %w(snap list)])
  end

  it 'is false only for a successful listing without the snap (including no snaps at all)' do
    expect(described_class.installed_in?(listing, 'core22')).to be(true)
    expect(described_class.installed_in?(listing, 'lxd')).to be(false)
    expect(described_class.installed_in?('', 'amazon-ssm-agent')).to be(false)
    expect(described_class.installed_in?(listing, 'Name')).to be(false)
  end

  it 'raises when the seeding wait fails or times out' do
    allow(described_class).to receive(:run!).with('timeout', '600', 'snap', 'wait', 'system', 'seed.loaded').and_raise(failed('snap wait'))
    expect { described_class.installed?('amazon-ssm-agent') }.to raise_error(Mixlib::ShellOut::ShellCommandFailed)
  end

  it 'raises when snap list fails, rather than answering "not installed"' do
    allow(described_class).to receive(:run!).with('timeout', '600', 'snap', 'wait', 'system', 'seed.loaded').and_return('')
    allow(described_class).to receive(:run!).with('snap', 'list').and_raise(failed('snap list'))
    expect { described_class.installed?('amazon-ssm-agent') }.to raise_error(Mixlib::ShellOut::ShellCommandFailed)
  end

  it 'run! raises on a non-zero exit with the command named' do
    expect { described_class.run!('false') }.to raise_error(Mixlib::ShellOut::ShellCommandFailed)
    expect(described_class.run!('echo', 'ok')).to eq("ok\n")
  end
end
