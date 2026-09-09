package 'fail2ban'

file '/etc/fail2ban/jail.local' do
  content <<~JAIL
    [sshd]
    enabled  = true
    port     = ssh
    maxretry = 5
    bantime  = 3600
    findtime = 600
  JAIL
  mode '0644'
  notifies :restart, 'service[fail2ban]'
end

service 'fail2ban' do
  action [:enable, :start]
end
