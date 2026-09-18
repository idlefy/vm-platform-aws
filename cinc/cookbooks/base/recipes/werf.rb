# Install werf v2 for ubuntu user
# Skip docker group prompt (rootless Docker, no sudo)

execute 'install-werf' do
  command <<~SH
    curl -sSL https://werf.io/install.sh -o /tmp/werf-install.sh && \
    printf '\\n\\n\\ns\\n' | bash /tmp/werf-install.sh --version 2 --channel stable && \
    rm -f /tmp/werf-install.sh
  SH
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  # werf.io/install.sh does not install a `werf` binary: it installs *trdl* to
  # ~/bin and registers the werf TUF repo, and the shell activates a version on
  # login via the `trdl use werf` line it appends to ~/.zshrc and ~/.zprofile.
  # So /home/ubuntu/bin/werf never exists — the old guard could not match and the
  # installer re-ran on every converge. werf itself was fine throughout (it
  # resolves to ~/.trdl/repositories/werf/releases/<v>/linux-amd64/bin/werf);
  # only the guard was wrong. Test for what the installer actually leaves behind.
  not_if 'test -d /home/ubuntu/.trdl/repositories/werf', user: 'ubuntu'
end

# werf is installed but invisible to the shells that automate it.
#
# werf.io/install.sh appends its `trdl use werf` activation to ~/.zshrc and
# ~/.zprofile, which zsh reads only for interactive and login shells. A
# non-interactive `zsh -c 'werf ...'` — an ssh command, a CI step, an agent's
# shell tool — reads neither, so werf resolves to nothing for exactly the
# callers that script it. Measured on a staging VM 2026-09-18: with the
# activation only in ~/.zshrc, `zsh -c 'whence -p werf'` printed nothing while
# an interactive shell resolved it to
# ~/.trdl/repositories/werf/releases/2.76.0/linux-amd64/bin/werf.
#
# Fixed the way this cookbook already fixes this class of problem (see
# base::docker and base::aws_access): a root-owned gated file under
# /etc/dev-vm that the shells' *system* rc files source — /etc/zsh/zshenv for
# zsh (the line lives in base::shell_default, which owns that file) and
# /etc/profile.d for bash and sh login shells.
#
# Not ~/.zshenv, which was the first shape tried. Root cannot write there, so
# it needs the stage-and-copy dance; the copy has to be create-once or it
# clobbers a developer's own file, which means a developer who already has a
# ~/.zshenv never gets the fix and a deleted one is never restored; and
# measured on the same VM, `zsh -f -c` skips ~/.zshenv while still running
# /etc/zsh/zshenv. The system file is the one that cannot be opted out of.
#
# POSIX sh, not the zsh spelling (`[[ ]]`, `whence -p`) this started as,
# because /etc/profile.d sources it into bash and sh as well.
directory '/etc/dev-vm' do
  owner 'root'
  group 'root'
  mode '0755'
end

file '/etc/dev-vm/werf-env.sh' do
  # Non-interpolating heredoc: the body is shell, full of $HOME and $(...),
  # and Ruby must not touch any of it.
  content <<~'SH'
    # Managed by CINC base::werf — do not edit.
    # Sourced from /etc/profile.d/dev-vm-werf.sh and /etc/zsh/zshenv.
    #
    # The trdl guard is what keeps this per-user: root and admin have no
    # ~/bin/trdl, so for them the whole stanza is one failed test. The second
    # clause re-activates unless werf already resolves to a trdl release, so a
    # shell nested inside an activated one does no work.
    if [ -x "$HOME/bin/trdl" ] && ! { command -v werf >/dev/null 2>&1 && command -v werf | grep -qs "^$HOME/\.trdl/"; }; then
      . "$("$HOME/bin/trdl" use werf "2" "stable")" >/dev/null 2>&1
    fi
  SH
  owner 'root'
  group 'root'
  mode '0644'
end

file '/etc/profile.d/dev-vm-werf.sh' do
  content <<~'SH'
    # Managed by CINC base::werf — do not edit.
    [ -r /etc/dev-vm/werf-env.sh ] && . /etc/dev-vm/werf-env.sh
  SH
  owner 'root'
  group 'root'
  mode '0644'
end
