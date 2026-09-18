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
# On 24.04 that profile ships *unloaded*, as
# /usr/share/apparmor/extra-profiles/bwrap-userns-restrict from
# apparmor-profiles — installing the package is not enough, the file has to
# land in /etc/apparmor.d and be parsed. Read off the noble source package:
# d/apparmor-profiles.install ships it there, and d/apparmor.maintscript
# carries `rm_conffile /etc/apparmor.d/bwrap-userns-restrict`, because Ubuntu
# enabled it by default once, broke saving files in Flatpak apps with it
# (LP: #2072811) and reverted. So loading it is the supported way to turn it
# on, not a workaround — and it is a second reason to use remote_file rather
# than a copy-once execute: if a maintainer script ever removes the file
# again, the next converge puts it back.
#
# What the profile actually does is narrower than its name suggests, and the
# accurate version matters if you ever weigh it. Its own header says it
# "allows almost everything": /usr/bin/bwrap gets `allow capability`,
# `allow file rwlkm /{**,}`, network, ptrace, mount, pivot_root and `allow
# userns`. That is not a loss of confinement — bwrap was unconfined before —
# it is the price of granting userns through AppArmor at all. The part that
# holds is the stack: children go to `px /** -> bwrap//&unpriv_bwrap`, and
# unpriv_bwrap carries `audit deny capability`. So bwrap can build a sandbox
# but cannot be turned into a general-purpose way around the userns
# restriction.
#
# Setting the sysctl to 0 would lift that restriction fleet-wide for anything
# that asks, which is the opposite of what this VM is for — so this recipe
# does not, and spec/recipes/codex_spec.rb fails a change that does.
#
# The header also warns the profile "can break some use cases". Those are
# flatpak and snap confinement corner cases; neither is on these VMs, where
# bwrap has exactly one caller.

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
#
# Deliberately unpinned, and a review has already asked. The installer honours
# CODEX_RELEASE, but the not_if below makes this resource run once per VM ever,
# so a pin would fix only the version a VM is born with: the developer's own
# `codex update` moves it afterwards, and bumping the pin would reach no
# existing VM because the guard blocks the re-run. The string would go stale
# while looking authoritative. Integrity is covered without it — the installer
# verifies the release archive against its SHA-256 metadata, over TLS. Same
# shape as base::claude_code's `bash -s stable`. If reproducible versions are
# ever wanted here, the honest change is a pinned tarball with a checksum in
# the uv.rb/yq.rb shape, not an environment variable behind a once-only guard.
execute 'install-codex' do
  command 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -x /home/ubuntu/.local/bin/codex', user: 'ubuntu'
end
