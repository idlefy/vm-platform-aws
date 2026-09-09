# Remove sudo privileges from ubuntu user
# Admin access via 'admin' user (EC2 Instance Connect + sudo)
# Developer workflow (Docker, werf) is fully rootless

# Remove ubuntu from sudo and admin groups
execute 'remove-ubuntu-from-sudo' do
  command 'gpasswd -d ubuntu sudo'
  only_if 'id -nG ubuntu | grep -qw sudo'
end

execute 'remove-ubuntu-from-admin' do
  command 'gpasswd -d ubuntu admin'
  only_if 'id -nG ubuntu | grep -qw admin'
end

# Remove ubuntu from adm — log read, NOT privilege escalation.
#
# This block looks misplaced in a recipe named sudoers.rb, so: adm is the group
# that grants read access to the system journal and to /var/log on Ubuntu. It is
# here because this recipe is where the developer's inherited default privileges
# are stripped, and because the reason is the same — developers get no access to
# the OS beyond running their own containers.
#
# What this costs the developer: `journalctl` across the system, /var/log/syslog
# and auth.log. What it does not touch: `journalctl --user` for their own units,
# and rootless-Docker container logs, which live in the user's own data directory
# and are served by the user's own daemon. `docker compose logs` never reads the
# system journal, so the normal workflow is unaffected.
#
# It also closes a real hole: cinc-client's output goes to the journal, so an
# adm-capable developer could read anything a converge printed — including a
# secret printed by a resource without `sensitive true`. base::alloy relies on
# that door being shut, but does not rely on it alone.
execute 'remove-ubuntu-from-adm' do
  command 'gpasswd -d ubuntu adm'
  only_if 'id -nG ubuntu | grep -qw adm'
end

# Drop any lingering sudoers fragments for ubuntu
file '/etc/sudoers.d/90-cloud-init-users' do
  action :delete
end

file '/etc/sudoers.d/ubuntu' do
  action :delete
end

file '/etc/sudoers.d/ubuntu-debug' do
  action :delete
end

# The one grant: `tailscale login`, and nothing else.
#
# `!authenticate` is not a convenience. Once ubuntu matches ANY UserSpec, sudo
# authenticates *before* reporting a policy refusal, and `def_authenticate` is
# cleared only by a *matching* NOPASSWD entry. Without this line `sudo apt install
# foo` stops refusing immediately and instead prompts three times for a password
# the cloud-image ubuntu does not have (locked), then prints "command not allowed".
# The prompt could never succeed, so it buys nothing and costs a confusing day-one
# experience plus a permanent stream of pam_unix(sudo:auth) failures that no alert
# or panel matches.
#
# It does not widen this grant — authorisation is a separate decision from
# authentication, and the one permitted command is NOPASSWD already. But it is
# user-scoped, not command-scoped: any FUTURE sudoers entry for ubuntu written with
# PASSWD would silently become passwordless. Adding a second entry for ubuntu means
# revisiting this line.
#
# The narrowness of the command spec rests on three distro defaults. Record them,
# because the guarantee dies if they change: `env_reset` (re-initialises HOME,
# SHELL, LOGNAME, USER; TMPDIR/XDG_*/BROWSER are not in env_keep), `secure_path`
# (overrides PATH, so a planted `tailscale` cannot match the rule), and `use_pty`.
# `tailscale login` on Linux prints the URL rather than opening a browser, so there
# is no BROWSER/DISPLAY execution vector. Arguments must match exactly, and since
# the command is not ALL, SETENV is not implied — `sudo -E tailscale login` and
# `sudo VAR=x tailscale login` are both refused.
#
# NOTE FOR base::falco: this grant makes the Falco rule "Developer user invoked
# sudo" fire on legitimate use. The rule carries a full-cmdline-equality exclusion
# for exactly the permitted spellings. The two are one change — never ship this
# file without that exclusion already in place, or every login pages someone.
#
# Shipping them together, as this change did, leaves one converge's worth of
# window and cannot do better: base::falco's rules file notifies a :delayed
# restart, so the new ruleset loads at the end of the run however early the
# recipe is included, while this resource has already written the grant. Moving
# either recipe buys nothing; :immediately risks the Falco crash loop. See the
# ship-ordering trap in CLAUDE.md before repeating the pattern.
file '/etc/sudoers.d/50-tailscale-login' do
  content <<~SUDOERS
    # Managed by CINC — base::sudoers. Do not edit on the VM.
    Defaults:ubuntu !authenticate
    ubuntu ALL=(root) NOPASSWD: /usr/bin/tailscale login
  SUDOERS
  owner 'root'
  group 'root'
  mode '0440'
  verify 'visudo -cf %{path}'
end

# The lxd group is an Ubuntu cloud-image default and is root-equivalent the moment
# a daemon exists: membership lets you attach a host-root filesystem to a container
# you control. Today the path is dead — lxd is not installed, /usr/sbin/lxc is the
# lxd-installer shim, the daemon is inactive and there is no socket — but "dead
# because the package is absent" is not a control, and a developer who runs `lxc`
# gets prompted to install it.
#
# grep -w is WRONG here: `-` is not a word character, so `grep -qw lxd` also matches
# `lxd-installer` in the group list and the guard would never fire once that name
# appeared. Split on whitespace and match the whole line instead.
execute 'remove-ubuntu-from-lxd' do
  command 'gpasswd -d ubuntu lxd'
  only_if "id -nG ubuntu | tr ' ' '\\n' | grep -qx lxd"
end

# Purge the shim as well, so nothing can quietly install the daemon later. Removing
# the group membership alone would leave `lxc` offering to undo this decision.
package 'lxd-installer' do
  action :purge
end

# Caveat worth knowing when you verify the two resources above: supplementary
# groups are fixed at session creation, and base::docker enables lingering — so
# user@1000.service and the rootless dockerd keep gid 105 until a reboot. `id
# ubuntu` shows the removal immediately while the property is not yet true for
# already-running processes. Check /proc/<pid>/status of a live dockerd, not just
# `id`.
#
# Docker itself is rootless here, so `ubuntu` reaching docker.sock is NOT an
# escalation and is deliberately left alone.
