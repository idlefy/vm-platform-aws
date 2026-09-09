# NVIDIA Container Toolkit + CDI for rootless Docker
# Only runs if NVIDIA GPU is detected on the host

return unless ::File.exist?('/dev/nvidia0')

# Add NVIDIA Container Toolkit repo
execute 'nvidia-container-toolkit-gpg' do
  command <<~SH
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  SH
  not_if { ::File.exist?('/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg') }
end

file '/etc/apt/sources.list.d/nvidia-container-toolkit.list' do
  content "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n"
  mode '0644'
  notifies :run, 'execute[apt-update-nvidia]', :immediately
end

execute 'apt-update-nvidia' do
  command 'apt-get update -qq'
  action :nothing
end

package 'nvidia-container-toolkit'

# Configure for rootless (no-cgroups required)
execute 'nvidia-ctk-config-rootless' do
  command 'nvidia-ctk runtime configure --runtime=docker && nvidia-ctk config --set no-cgroups=true --in-place'
  not_if 'grep -q "no-cgroups = true" /etc/nvidia-container-runtime/config.toml 2>/dev/null'
end

# CDI spec directory
directory '/etc/cdi' do
  mode '0755'
end

# Generate the CDI spec — and REGENERATE when the driver version changes. The
# old guard was file existence, which generated once, forever: after a driver
# upgrade the stale spec names the previous driver's device nodes and GPU
# containers fail at runtime under a green converge. The guard now keys on the
# recorded driver version. Fail-safe when nvidia-smi cannot answer: leave
# whatever spec exists alone — an unreadable version must not become a
# regenerate-and-fail loop inside every converge.
driver_version_cmd = 'nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1'

execute 'nvidia-cdi-generate' do
  command "nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml && (#{driver_version_cmd}) > /etc/cdi/.driver-version"
  not_if <<~SH
    current="$(#{driver_version_cmd})"
    if [ -z "$current" ]; then [ -f /etc/cdi/nvidia.yaml ]; exit $?; fi
    [ -f /etc/cdi/nvidia.yaml ] && [ -f /etc/cdi/.driver-version ] \
      && [ "$current" = "$(cat /etc/cdi/.driver-version)" ]
  SH
end
