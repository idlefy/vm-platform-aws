sysctl_params = {
  # Network performance
  'net.core.somaxconn' => 1024,
  'net.core.netdev_max_backlog' => 5000,
  'net.ipv4.tcp_max_syn_backlog' => 8096,
  'net.ipv4.tcp_slow_start_after_idle' => 0,

  # Memory
  'vm.swappiness' => 10,

  # File descriptors
  'fs.file-max' => 2097152,

  # Security
  'net.ipv4.conf.all.rp_filter' => 1,
  'net.ipv4.conf.default.rp_filter' => 1,
  'net.ipv4.conf.all.accept_redirects' => 0,
  'net.ipv4.conf.all.send_redirects' => 0,
  'net.ipv4.conf.all.accept_source_route' => 0,
  'net.ipv4.icmp_echo_ignore_broadcasts' => 1,
}

file '/etc/sysctl.d/99-base.conf' do
  content sysctl_params.map { |k, v| "#{k} = #{v}" }.join("\n") + "\n"
  mode '0644'
  notifies :run, 'execute[sysctl-reload]'
end

execute 'sysctl-reload' do
  command 'sysctl --system'
  action :nothing
end
