# Astral uv — Python package/project manager and CLI tool installer.
#
# Provides /usr/local/bin/{uv,uvx}. Users install Python CLIs without sudo via
# `uv tool install <pkg>` (ruff, mypy, semgrep, ...) — shims land in
# ~/.local/bin per user, no version conflicts between projects.
#
# Pinned version + SHA256 mirrors the yq/CINC pattern. The SHA256 comes from
# uv-x86_64-unknown-linux-gnu.tar.gz.sha256 on the GitHub release page.
# Bump uv_version and uv_sha256 together.

uv_version = '0.12.0'
uv_sha256  = 'eaf842262aa1c418d8ecc5605f02ee1ebfd369124fa48548e85f9481a47831a9'
uv_tarball = "/tmp/uv-#{uv_version}-x86_64-unknown-linux-gnu.tar.gz"

remote_file uv_tarball do
  source "https://github.com/astral-sh/uv/releases/download/#{uv_version}/uv-x86_64-unknown-linux-gnu.tar.gz"
  checksum uv_sha256
  owner 'root'
  group 'root'
  mode '0644'
end

execute "install-uv-#{uv_version}" do
  command <<~SH
    set -e
    tmp=$(mktemp -d)
    tar -xzf #{uv_tarball} -C "$tmp" --strip-components=1
    install -m 0755 -o root -g root "$tmp/uv"  /usr/local/bin/uv
    install -m 0755 -o root -g root "$tmp/uvx" /usr/local/bin/uvx
    rm -rf "$tmp"
  SH
  # `uv --version` prints "uv 0.12.0 (x86_64-unknown-linux-gnu)", so anchoring the
  # version to end-of-line never matched and uv was reinstalled on every converge.
  not_if "test -x /usr/local/bin/uv && /usr/local/bin/uv --version 2>/dev/null | grep -qE '^uv #{uv_version}( |$)'"
end
