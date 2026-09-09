# 1) Set zsh as default interactive shell for ubuntu — once.
#    Guarded by a marker file under /var/lib/dev-vm-platform/. After the marker
#    exists, CINC respects the user's `chsh` choice. Removing the marker and
#    re-running cinc-client forces the default back to zsh.
#    `chsh` runs as root via the CINC systemd timer — no PAM interaction.
#
# 2) Provide /usr/local/bin/fd → fdfind. Ubuntu's fd-find package ships only
#    /usr/bin/fdfind (symlink to /usr/lib/cargo/bin/fd); it does NOT install
#    /usr/bin/fd or register it via update-alternatives. `fd` is what
#    Claude Code and most documentation expect.
#
# zsh, fd-find, direnv, git-lfs themselves are installed via base::packages.
# yq is installed via base::yq (not apt — Ubuntu universe ships Python yq, not Go yq).

directory '/var/lib/dev-vm-platform' do
  owner 'root'
  group 'root'
  mode '0755'
end

execute 'set-zsh-default-ubuntu' do
  command 'chsh -s /usr/bin/zsh ubuntu && touch /var/lib/dev-vm-platform/.zsh-default-set'
  not_if { ::File.exist?('/var/lib/dev-vm-platform/.zsh-default-set') }
end

link '/usr/local/bin/fd' do
  to '/usr/bin/fdfind'
  only_if { ::File.exist?('/usr/bin/fdfind') }
end

# 3) Make ~/.local/bin discoverable under zsh. Ubuntu's bash convention is
#    that /etc/profile sources /etc/profile.d/* and `~/.profile` prepends
#    ~/.local/bin to PATH — but zsh sources neither. Stock /etc/zsh/zshenv
#    has a PATH stanza gated on an empty PATH check that never fires in
#    practice, and /etc/zsh/zprofile on Ubuntu does NOT source /etc/profile.
#    Result: tools installed to ~/.local/bin (claude, pipx, cargo, …) are
#    invisible to zsh sessions even though bash sees them.
#
#    Taking ownership of /etc/zsh/zshenv from the zsh-common dpkg conffile
#    is acceptable here — the stock content is comments + one dead stanza;
#    unattended-upgrades runs with --force-confold so our version survives.
#
# 4) Source /etc/dev-vm/shell-env.sh, written by base::aws_access. Ubuntu's
#    /etc/zsh/zprofile does not source /etc/profile, so zsh needs this line to
#    see the same environment that /etc/profile.d/dev-vm.sh gives bash.
file '/etc/zsh/zshenv' do
  content <<~ZSHENV
    # /etc/zsh/zshenv: system-wide .zshenv file for zsh(1).
    # Managed by CINC base::shell_default — see recipe for rationale.
    #
    # Sourced for ALL zsh invocations (interactive, login, scripts).
    # Mirrors bash /etc/profile.d/* behaviour of putting ~/.local/bin
    # on PATH so user-installed CLIs are discoverable.

    if [[ -n "$HOME" && -d "$HOME/.local/bin" ]]; then
      path=("$HOME/.local/bin" $path)
    fi

    # Shared env for dev-VM features (currently the scoped AWS credentials from
    # base::aws_access). Kept in one file so bash and zsh cannot drift; see
    # base::aws_access for the uid gate and the rationale.
    [ -r /etc/dev-vm/shell-env.sh ] && . /etc/dev-vm/shell-env.sh

    [ -r /etc/dev-vm/docker-env.sh ] && . /etc/dev-vm/docker-env.sh
  ZSHENV
  owner 'root'
  group 'root'
  mode '0644'
end
