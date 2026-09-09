# Scoped AWS credentials for the developer user.
#
# A root systemd timer assumes this VM's identity role and publishes a
# short-lived credential file into /dev/shm/dev-vm-aws (tmpfs). The developer can
# read that directory but not write to it — that is what stops a symlink attack on
# the root writer, so the 0750 root:ubuntu mode below is a security boundary,
# not a preference.
#
# /dev/shm rather than /run: rootless Docker is started by RootlessKit with
# copy-up=/run, so the daemon has a private tmpfs at /run and a bind mount of
# /run/aws-vm into a container resolves to an empty directory. Rootless containers
# cannot reach IMDS either, so that combination left them with no credentials at
# all — which is one of the two reasons this broker exists. /dev/shm is also
# tmpfs, so credentials still never touch disk, and it is not copied up.
#
# Unlike /run, /dev/shm is mode 1777, so the developer can create entries there.
# The broker therefore verifies the directory's owner and mode before publishing
# rather than trusting it; see aws-vm-credentials.
#
# The shell exports that point AWS_SHARED_CREDENTIALS_FILE at the file live in
# /etc/dev-vm/shell-env.sh, written here and sourced from two places:
#   * /etc/profile.d/dev-vm.sh  — written here, for bash and sh login shells
#   * /etc/zsh/zshenv           — written by base::shell_default, because zsh is
#                                 the default shell for ubuntu and Ubuntu's
#                                 /etc/zsh/zprofile does NOT source /etc/profile
# If you change the gate, change it in shell-env.sh only — the other two files
# just source it.
#
# See docs/design/per-vm-aws-access.md

ubuntu_uid = shell_out('id -u ubuntu').stdout.strip
ubuntu_gid = shell_out('id -g ubuntu').stdout.strip

# Region resolution, in order of preference.
#
# Ohai's ec2 plugin is first: it is populated at compile time, speaks IMDSv2
# (mandatory here — main.tf:92 sets http_tokens = "required"), and needs no
# subprocess. The IMDSv2 curl is a fallback for the case where the plugin did
# not run. Note this recipe can reach IMDS at all only because it runs as root;
# imds.rb blocks every other uid.
#
# The region cannot come from the SSM access parameter, because a region is
# needed to read that parameter in the first place.
#
# Deliberately NOT a `raise`: this code runs at compile time, so raising would
# abort the whole chef run before ANY recipe converges — no firewall, no ssh
# hardening. A region lookup that fails must disable one feature, not
# the entire node. Note also that shell_out without .error! returns empty stdout
# on failure rather than raising, so an empty result is the expected shape here.
# Region via the shared hardened lookup (libraries/imds.rb): ohai first,
# -f/timeout-bounded IMDSv2 curls second, shape-validated always — nothing
# unshaped reaches aws-access.env, which the root broker sources. Empty means
# "could not resolve", handled below by warn-and-skip; that this cannot hang
# or abort the compile is the library's contract.
region = DevVm::Imds.region(node)

if region.empty? || ubuntu_uid.empty? || ubuntu_gid.empty?
  # Log loudly and manage nothing. An empty uid would render a gate that can
  # never match, silently denying credentials to everyone; an empty gid would
  # fail the broker's chown at runtime instead of here.
  log 'aws-access-unresolved' do
    message 'base::aws_access: could not resolve region or the ubuntu uid/gid; ' \
            'skipping scoped AWS credential setup this run'
    level :warn
  end
  return
end

directory '/etc/dev-vm' do
  owner 'root'
  group 'root'
  mode '0755'
end

template '/etc/dev-vm/aws-access.env' do
  source 'aws-access.env.erb'
  owner 'root'
  group 'root'
  mode '0600'
  variables(
    vm_name: node.name,
    region: region,
    ubuntu_gid: ubuntu_gid
  )
  notifies :run, 'execute[aws-vm-credentials-refresh]', :delayed
end

cookbook_file '/usr/local/sbin/aws-vm-credentials' do
  source 'aws-vm-credentials'
  owner 'root'
  group 'root'
  mode '0700'
  notifies :run, 'execute[aws-vm-credentials-refresh]', :delayed
end

# root:ubuntu 0750 — developer reads and traverses, cannot create or unlink.
# Declared via tmpfiles so the directory reappears after a reboot without
# waiting for a converge, and so it is created early in boot — before the
# developer's session could create it first in world-writable /dev/shm.
file '/etc/tmpfiles.d/aws-vm.conf' do
  content "d /dev/shm/dev-vm-aws 0750 root ubuntu -\n"
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, 'execute[systemd-tmpfiles-aws-vm]', :immediately
end

# Clean up the original location. Machines that converged against the staging
# revision that used /run/aws-vm still have a credentials file sitting there; it
# expires within the hour and the tmpfs is cleared on reboot, but leaving a stale
# credentials file in a path nothing manages any more is how it gets found later
# by someone who assumes it is live.
directory '/run/aws-vm' do
  recursive true
  action :delete
end

execute 'systemd-tmpfiles-aws-vm' do
  command 'systemd-tmpfiles --create /etc/tmpfiles.d/aws-vm.conf'
  action :nothing
end

file '/etc/systemd/system/aws-vm-credentials.service' do
  content <<~UNIT
    # Managed by CINC base::aws_access — do not edit.
    [Unit]
    Description=Refresh scoped AWS credentials for the developer user
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/aws-vm-credentials
    # Worst case is ~55s of retry sleeps plus five CLI calls, which can exceed
    # systemd's default TimeoutStartSec=90 on a network-flaky boot. bash does not
    # run EXIT traps on an untrapped SIGTERM, so a timeout kill would leak a
    # .credentials.* temp file into the output directory.
    TimeoutStartSec=180
  UNIT
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, 'execute[aws-vm-systemd-reload]', :immediately
end

# No Persistent=true: it only affects OnCalendar= timers and would be
# misleading on a monotonic one. network-online ordering matters because at
# OnBootSec=30s the STS call can otherwise precede a working default route.
file '/etc/systemd/system/aws-vm-credentials.timer' do
  content <<~UNIT
    # Managed by CINC base::aws_access — do not edit.
    [Unit]
    Description=Refresh scoped AWS credentials every 15 minutes

    [Timer]
    OnBootSec=30s
    OnUnitActiveSec=15min
    AccuracySec=30s

    [Install]
    WantedBy=timers.target
  UNIT
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, 'execute[aws-vm-systemd-reload]', :immediately
end

execute 'aws-vm-systemd-reload' do
  command 'systemctl daemon-reload'
  action :nothing
end

service 'aws-vm-credentials.timer' do
  action [:enable, :start]
end

# ignore_failure is load-bearing. `systemctl start` on a Type=oneshot unit blocks
# and propagates the exit status, so without it a broker failure fails the whole
# converge — and since the notification is :delayed, it fails AFTER every other
# resource succeeded, marking a perfectly healthy node as failed. A VM whose
# Terraform state lags (new region not yet applied, mid-rollback) would then
# report a failed converge every 30 minutes indefinitely. The timer retries every
# 15 minutes regardless, so failing the converge buys nothing; the journal and
# the credentials-file mtime are the real signal.
#
# cookstyle's ServiceResource rule wants `service` here (9.x matches
# `systemctl start`, 8.x does not); excluded for this file in cinc/.rubocop.yml.
# A `service` resource cannot carry this semantics: this is a one-shot kick, not
# a state to converge to.
execute 'aws-vm-credentials-refresh' do
  command 'systemctl start aws-vm-credentials.service'
  action :nothing
  ignore_failure true
end

# Single source of truth for the env vars. POSIX sh, so zsh can source it too.
# ${EUID:-$(id -u)} costs no subprocess under zsh (EUID is a zsh builtin) and
# still works under dash, which does not define EUID at all.
#
# The gate is required because both consumers are system-wide: without it the
# admin user's own login shell would inherit AWS_SHARED_CREDENTIALS_FILE pointing
# at a file its uid cannot read, so every aws call as admin would fail on an
# unreadable credentials file instead of failing on IMDS — the wrong error for
# the wrong reason.
#
# It is NOT about sudo. Ubuntu's /etc/sudoers ships `Defaults env_reset` and this
# cookbook adds no env_keep (ssh.rb:22 grants NOPASSWD only), so the variable does
# not survive sudo either way.
#
# There is deliberately no test for the file's existence. Environment is fixed
# at shell start, so gating on "does the file exist right now" would leave a
# session opened during the boot window without credentials for its entire life,
# while the credentials file sits there valid. Exporting a path to a
# not-yet-existing file behaves exactly like not setting it.
file '/etc/dev-vm/shell-env.sh' do
  content <<~SH
    # Managed by CINC base::aws_access — do not edit.
    # Sourced from /etc/profile.d/dev-vm.sh and from /etc/zsh/zshenv.
    _dev_vm_uid=${EUID:-$(id -u)}
    if [ "$_dev_vm_uid" = "#{ubuntu_uid}" ]; then
      AWS_SHARED_CREDENTIALS_FILE=/dev/shm/dev-vm-aws/credentials
      # Both spellings: the AWS CLI and boto3 read AWS_DEFAULT_REGION, while the
      # Go SDK v2 and JS SDK v3 read only AWS_REGION.
      AWS_DEFAULT_REGION=#{region}
      AWS_REGION=#{region}
      export AWS_SHARED_CREDENTIALS_FILE AWS_DEFAULT_REGION AWS_REGION
    fi
    unset _dev_vm_uid
  SH
  owner 'root'
  group 'root'
  mode '0644'
end

file '/etc/profile.d/dev-vm.sh' do
  content <<~SH
    # Managed by CINC base::aws_access — do not edit.
    [ -r /etc/dev-vm/shell-env.sh ] && . /etc/dev-vm/shell-env.sh
  SH
  owner 'root'
  group 'root'
  mode '0644'
end
