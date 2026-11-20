# cinc/cookbooks/base/spec/recipes/hardened_firstboot_spec.rb
#
# base::hardened_firstboot keeps ubuntu sudo-less on every NEW instance from
# the image: a cloud.cfg.d override so cloud-init never re-grants the default
# user's sudo rule, plus a root oneshot that strips anything that slips past.
# The script's behaviour on a real user is checked by hand in a container; here
# we pin the files, the unit and the script's no-fail-before-rm ordering.
require 'chefspec'
require_relative '../support/home_boundary'

describe 'base::hardened_firstboot' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe)
  end

  let(:cfg) { '/etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg' }
  let(:script_source) do
    ::File.read(::File.expand_path('../../files/default/idlefy-hardened-firstboot', __dir__))
  end
  let(:unit) { chef_run.systemd_unit('idlefy-hardened-firstboot.service') }

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'writes the cloud-init override root-owned' do
    expect(chef_run).to create_file(cfg).with(owner: 'root', group: 'root', mode: '0644')
  end

  it 'makes the default user ubuntu, locked and sudo-less' do
    expect(chef_run).to render_file(cfg).with_content { |content|
      expect(content).to match(/^\s+sudo: null$/)
      expect(content).to match(/^\s+name: ubuntu$/)
      expect(content).to match(/^\s+lock_passwd: true$/)
    }
  end

  it 'grants no sudo rule and none of the adm/lxd groups' do
    expect(chef_run).to render_file(cfg).with_content { |content|
      expect(content).not_to match(/sudo\b.*ALL/)
      expect(content).not_to match(/\badm\b/)
      expect(content).not_to match(/\blxd\b/)
    }
  end

  # A root script on every boot takes nothing from its environment: a fixed
  # interpreter path, and PATH pinned before any command runs.
  it 'runs under /bin/bash with PATH pinned at the top' do
    lines = script_source.lines.map(&:chomp)
    expect(lines.first).to eq('#!/bin/bash')
    first = lines.drop(1).find { |l| !l.strip.empty? && !l.start_with?('#') }
    expect(first).to eq('export PATH=/usr/sbin:/usr/bin:/sbin:/bin')
  end

  it 'installs the firstboot script root-owned and executable' do
    expect(chef_run).to create_cookbook_file('/usr/local/sbin/idlefy-hardened-firstboot')
      .with(source: 'idlefy-hardened-firstboot', owner: 'root', group: 'root', mode: '0755')
  end

  # Under `set -e` anything that fails before the rm would leave the
  # cloud-init sudo fragment in place. The rm comes first, unconditionally.
  it 'removes the sudoers fragments before anything that can fail' do
    lines = script_source.lines.map(&:strip)
    set_at = lines.index('set -euo pipefail')
    expect(set_at).not_to be_nil
    first = lines[(set_at + 1)..].find { |l| !l.empty? && !l.start_with?('#') }
    expect(first).to start_with('rm -f /etc/sudoers.d/90-cloud-init-users')
  end

  # `id | tr | grep -q` dies with SIGPIPE under pipefail (exit 141).
  it 'uses no early-closing pipeline' do
    expect(script_source).not_to include('grep -q')
    expect(script_source).not_to include('| tr ')
  end

  it 'creates and enables the oneshot unit' do
    expect(chef_run).to create_systemd_unit('idlefy-hardened-firstboot.service')
    expect(chef_run).to enable_systemd_unit('idlefy-hardened-firstboot.service')
  end

  it 'orders the unit after cloud-init and before ssh logins' do
    content = unit.content
    expect(content).to be_a(String)
    expect(content).to include('After=cloud-init.service cloud-init-network.service')
    expect(content).to include('Before=ssh.service systemd-user-sessions.service')
    expect(content).to include('Before=shutdown.target')
    expect(content).to include('Type=oneshot')
    expect(content).to include('RemainAfterExit=yes')
    expect(content).to include('ExecStart=/usr/local/sbin/idlefy-hardened-firstboot')
  end

  # Law A1: nothing on the box runs on a schedule that could take instructions
  # from Idlefy after launch.
  it 'declares no timer' do
    timers = chef_run.resource_collection.all_resources.select { |r| r.name.to_s.end_with?('.timer') }
    expect(timers.map(&:to_s)).to eq([])
  end
end
