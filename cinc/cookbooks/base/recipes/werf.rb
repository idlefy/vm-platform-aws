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
