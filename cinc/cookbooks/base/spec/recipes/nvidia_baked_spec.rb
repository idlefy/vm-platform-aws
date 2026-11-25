# cinc/cookbooks/base/spec/recipes/nvidia_baked_spec.rb
#
# base::nvidia_baked bakes the NVIDIA driver and Container Toolkit into the
# solo image on a build host without a GPU. It pins the package names, the
# drop-in that skips the CDI refresh without an NVIDIA device and its place
# before every NVIDIA package, the boot-time /run/cdi, and what the recipe
# must not do: generate a CDI spec or configure the rootful runtime.
require 'chefspec'
require_relative '../support/home_boundary'

NVIDIA_DROPIN = '/etc/systemd/system/nvidia-cdi-refresh.service.d/20-idlefy-gpu-present.conf'.freeze
NVIDIA_CONDITION = "ExecCondition=/bin/sh -c 'grep -qsx 0x10de /sys/bus/pci/devices/*/vendor'".freeze
NVIDIA_KEYRING = '/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'.freeze
NVIDIA_SOURCE = '/etc/apt/sources.list.d/nvidia-container-toolkit.list'.freeze
NVIDIA_SOURCE_LINE = "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n".freeze

describe 'base::nvidia_baked' do
  before do
    allow(::File).to receive(:exist?).and_call_original
    # The key is absent on a fresh build host; do not depend on this one.
    allow(::File).to receive(:exist?).with(NVIDIA_KEYRING).and_return(false)
    stub_command(/.*/).and_return(false)
  end

  let(:chef_run) { ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04').converge(described_recipe) }
  let(:resources) { chef_run.resource_collection.all_resources }

  def index_of(type, name)
    resources.index { |r| r.declared_type.to_s == type && r.name == name }
  end

  def resource_text(r)
    %i(command content code).map { |m| r.respond_to?(m) ? r.public_send(m).to_s : '' }.join("\n")
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  it 'defaults the driver branch to 580-server-open' do
    expect(chef_run.node['base']['nvidia']['driver_branch']).to eq('580-server-open')
  end

  it 'writes the drop-in root-owned with the NVIDIA PCI condition' do
    expect(chef_run).to create_file(NVIDIA_DROPIN).with(owner: 'root', group: 'root', mode: '0644')
    expect(chef_run).to(render_file(NVIDIA_DROPIN).with_content do |c|
      expect(c.lines.map(&:chomp)).to include('[Service]', NVIDIA_CONDITION, '[Unit]', 'Before=user@1000.service',
                                              'TimeoutStartSec=120')
    end)
  end

  it 'reloads systemd as soon as the drop-in changes' do
    expect(chef_run.file(NVIDIA_DROPIN)).to notify('execute[nvidia-baked-daemon-reload]').to(:run).immediately
    reload = chef_run.execute('nvidia-baked-daemon-reload')
    expect(reload.action).to eq([:nothing])
    expect(reload.command).to eq('systemctl daemon-reload')
  end

  it 'declares the drop-in before every NVIDIA package' do
    dropin = index_of('file', NVIDIA_DROPIN)
    driver = index_of('package', 'nvidia-driver')
    toolkit = index_of('package', 'nvidia-container-toolkit')
    expect([dropin, driver, toolkit]).to all(be_an(Integer))
    expect(dropin).to be < driver
    expect(dropin).to be < toolkit
  end

  it 'creates /run/cdi at boot through tmpfiles' do
    expect(chef_run).to create_file('/etc/tmpfiles.d/idlefy-cdi.conf')
      .with(content: "d /run/cdi 0755 root root -\n", owner: 'root', group: 'root', mode: '0644')
  end

  it 'installs the driver for the default branch' do
    expect(chef_run).to install_package('nvidia-driver').with(
      package_name: %w(linux-modules-nvidia-580-server-open-aws nvidia-headless-no-dkms-580-server-open nvidia-utils-580-server)
    )
  end

  context 'with driver_branch 590-server' do
    let(:chef_run) do
      ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
        node.override['base']['nvidia']['driver_branch'] = '590-server'
      end.converge(described_recipe)
    end

    it 'derives every name from the branch' do
      expect(chef_run).to install_package('nvidia-driver').with(
        package_name: %w(linux-modules-nvidia-590-server-aws nvidia-headless-no-dkms-590-server nvidia-utils-590-server)
      )
    end
  end

  it "adds the toolkit source with the fleet's lines" do
    expect(chef_run).to create_file(NVIDIA_SOURCE).with(content: NVIDIA_SOURCE_LINE, mode: '0644')
    expect(chef_run.file(NVIDIA_SOURCE)).to notify('execute[nvidia-baked-apt-update]').to(:run).immediately
    expect(chef_run).to run_execute('nvidia-baked-toolkit-gpg')
  end

  it 'installs the toolkit without a GPU on the host' do
    expect(chef_run).to install_package('nvidia-container-toolkit')
  end

  it 'sets no-cgroups in the nvidia-container-cli table' do
    expect(chef_run).to run_execute('nvidia-baked-no-cgroups')
      .with(command: 'nvidia-ctk config --set nvidia-container-cli.no-cgroups=true --in-place')
  end

  it 'makes no CDI spec and configures no rootful runtime' do
    offenders = resources.select { |r| resource_text(r).match?(%r{cdi generate|runtime configure|/etc/cdi}) }
    expect(offenders.map(&:to_s)).to eq([])
  end

  it 'declares no service, unit or timer' do
    offenders = resources.select do |r|
      %w(service systemd_unit).include?(r.declared_type.to_s) || r.name.to_s.end_with?('.timer')
    end
    expect(offenders.map(&:to_s)).to eq([])
  end
end
