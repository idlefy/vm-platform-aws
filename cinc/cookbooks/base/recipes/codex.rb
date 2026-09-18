# OpenAI Codex CLI — per-user install for ubuntu, plus the bubblewrap its
# sandbox actually uses.
#
# Two halves, and they are one change. The CLI without a usable bwrap runs
# every command it is given unsandboxed after printing one warning, and the
# bwrap without the AppArmor profile below cannot create a user namespace at
# all. Either half alone converges green and leaves the sandbox off, which is
# why `bubblewrap` is declared here rather than in base::packages: the package
# and the reason for it stay in one file.
#
# 1. The CLI itself, via the official installer, exactly as base::claude_code
#    does — per-user under /home/ubuntu/.local/bin, owned and updated by the
#    developer (`codex update`). Not an apt repo, so unattended-upgrades does
#    not apply to it.
#
# 2. bubblewrap. Codex sandboxes on Linux with bwrap and takes the FIRST bwrap
#    on PATH, falling back to a copy it bundles at
#    ~/.codex/versions/<v>/codex-resources/bwrap only when none is found. On
#    24.04 that fallback is a dead end: kernel.apparmor_restrict_unprivileged_userns
#    is 1 and the bundled binary sits at a path no AppArmor profile attaches
#    to, so unshare(CLONE_NEWUSER) returns EPERM. Installing /usr/bin/bwrap
#    moves Codex onto a path Ubuntu's own bwrap-userns-restrict profile covers.
#
# On 24.04 that profile ships *unloaded*, in apparmor-profiles' extra-profiles
# directory — installing the package is not enough, the file has to land in
# /etc/apparmor.d and be parsed. It grants userns to /usr/bin/bwrap alone;
# processes inside the sandbox stay restricted, and so does every other binary
# on the VM. Setting the sysctl to 0 would lift the restriction fleet-wide for
# anything that asks, which is the opposite of what this VM is for — so this
# recipe does not, and spec/recipes/codex_spec.rb fails a change that does.

%w(bubblewrap apparmor-profiles).each do |pkg|
  package pkg
end

bwrap_profile_src = '/usr/share/apparmor/extra-profiles/bwrap-userns-restrict'
bwrap_profile_dst = '/etc/apparmor.d/bwrap-userns-restrict'

# remote_file over a copy-once execute: it compares content, so an upstream
# revision of the profile lands on the next converge, and apparmor_parser runs
# only when something actually changed.
remote_file bwrap_profile_dst do
  source "file://#{bwrap_profile_src}"
  owner 'root'
  group 'root'
  mode '0644'
  only_if { ::File.exist?(bwrap_profile_src) }
  notifies :run, 'execute[apparmor-reload-bwrap]', :immediately
end

execute 'apparmor-reload-bwrap' do
  command "apparmor_parser -r #{bwrap_profile_dst}"
  action :nothing
end

# A missing source is not worth failing every converge on the fleet over, but
# it is worth seeing: silence here is a sandbox that is off. The warning goes
# to the journal, which base::alloy ships to Loki.
log 'codex-bwrap-userns-profile-missing' do
  message "#{bwrap_profile_src} is absent — /usr/bin/bwrap cannot create a user " \
          'namespace and the Codex sandbox will not start. Check that the ' \
          'apparmor-profiles package installed.'
  level :warn
  not_if { ::File.exist?(bwrap_profile_src) }
end

# Root never writes under /home/ubuntu — see base::claude_code and
# spec/support/home_boundary.rb. The installer also appends a PATH line to the
# developer's shell profile; ~/.local/bin is already on PATH via the
# /etc/zsh/zshenv that base::shell_default writes, so that is redundant here
# rather than load-bearing.
execute 'install-codex' do
  command 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -x /home/ubuntu/.local/bin/codex', user: 'ubuntu'
end
