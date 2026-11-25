# nvidia_baked: the NVIDIA driver and Container Toolkit, baked into the solo
# image, so the image carries them for NVIDIA GPU sizes. Included only by
# base::solo. The fleet's base::nvidia_docker is a separate recipe: it needs a
# GPU on the host it converges, and the image is built on a host without one.
#
#   - The driver: Ubuntu's prebuilt, signed kernel modules for the AWS kernel.
#     No DKMS and no compiler on the box; a kernel update brings its modules in
#     the same unattended-upgrade run.
#   - The toolkit: from the same apt source as base::nvidia_docker. Its source
#     is not in Origins-Pattern (base::unattended_upgrades), as on the fleet.
#   - No CDI spec here. The toolkit's own nvidia-cdi-refresh.path and .service
#     write it at boot to /var/run/cdi (tmpfs). No `nvidia-ctk runtime
#     configure` either: it writes the rootful daemon's config, which
#     base::docker disables.
#   - /run/cdi is created at boot by tmpfiles. Rootless Docker copies up /run
#     when it starts, so a directory created later is invisible to it.
#
# The refresh unit's own condition passes whenever the module is installed, so
# on a box without a GPU it fails on every boot. The drop-in below adds a
# condition on an NVIDIA PCI device; a failed ExecCondition skips the unit
# without marking it failed. It is written before any NVIDIA package is
# installed, because the build host has no GPU either.
#
# The drop-in also orders the refresh before user@1000.service. Rootless Docker
# starts there, and a spec that first appears while the daemon is already
# running was not always picked up; a spec that exists before the daemon
# starts is.

branch = node['base']['nvidia']['driver_branch']
utils_branch = branch.sub(/-open\z/, '')

directory '/etc/systemd/system/nvidia-cdi-refresh.service.d' do
  owner 'root'
  group 'root'
  mode '0755'
end

file '/etc/systemd/system/nvidia-cdi-refresh.service.d/20-idlefy-gpu-present.conf' do
  content <<~UNIT
    # Managed by CINC — base::nvidia_baked. Do not edit on the VM.
    # Refresh the CDI spec only when an NVIDIA PCI device is present, and
    # finish before the user manager starts rootless Docker.
    [Unit]
    Before=user@1000.service

    [Service]
    ExecCondition=/bin/sh -c 'grep -qsx 0x10de /sys/bus/pci/devices/*/vendor'
    TimeoutStartSec=120
  UNIT
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, 'execute[nvidia-baked-daemon-reload]', :immediately
end

execute 'nvidia-baked-daemon-reload' do
  command 'systemctl daemon-reload'
  action :nothing
end

file '/etc/tmpfiles.d/idlefy-cdi.conf' do
  content "d /run/cdi 0755 root root -\n"
  owner 'root'
  group 'root'
  mode '0644'
end

package 'nvidia-driver' do
  package_name %W(
    linux-modules-nvidia-#{branch}-aws
    nvidia-headless-no-dkms-#{branch}
    nvidia-utils-#{utils_branch}
  )
end

# The same key and source lines as base::nvidia_docker.
execute 'nvidia-baked-toolkit-gpg' do
  command <<~SH
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  SH
  not_if { ::File.exist?('/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg') }
end

file '/etc/apt/sources.list.d/nvidia-container-toolkit.list' do
  content "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n"
  mode '0644'
  notifies :run, 'execute[nvidia-baked-apt-update]', :immediately
end

execute 'nvidia-baked-apt-update' do
  command 'apt-get update -qq'
  action :nothing
end

package 'nvidia-container-toolkit'

# Rootless Docker: nvidia-container-cli must not touch cgroups.
execute 'nvidia-baked-no-cgroups' do
  command 'nvidia-ctk config --set nvidia-container-cli.no-cgroups=true --in-place'
  not_if "grep -Eqx '[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true[[:space:]]*' /etc/nvidia-container-runtime/config.toml"
end
