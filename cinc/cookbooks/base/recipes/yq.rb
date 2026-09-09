# Mike Farah Go yq from upstream GitHub Release.
#
# WHY not apt: Ubuntu universe ships `yq` 3.1.0-3 which is the Python yq —
# a jq wrapper with an incompatible CLI. Mike Farah Go yq v4 is the standard
# tool everyone (Claude Code, k8s docs, helm/argo workflows) expects.
#
# Pinned version + SHA256 mirrors the CINC .deb install pattern in
# vms/modules/ec2/user_data.tf. Bump both yq_version and yq_sha256 together.
#
# Chef's remote_file with `checksum` re-downloads automatically when the
# on-disk file's SHA256 does not match the declared value — so version bumps
# trigger upgrade on the next converge without extra logic.

yq_version = 'v4.53.3'
yq_sha256  = 'fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4'

remote_file '/usr/local/bin/yq' do
  source "https://github.com/mikefarah/yq/releases/download/#{yq_version}/yq_linux_amd64"
  checksum yq_sha256
  owner 'root'
  group 'root'
  mode '0755'
end
