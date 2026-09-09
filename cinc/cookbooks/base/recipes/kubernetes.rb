# Kubernetes CLI tooling: kubectl + helm
# kubectl: pinned minor via pkgs.k8s.io apt repo (auto-update within minor).
#   Bump kubectl_minor when manager-side cluster is upgraded.
# helm: pinned tarball from get.helm.sh (no apt repo; baltocdn was deprecated).
#   Bump helm_version + helm_sha256 manually when newer v3 patch is desired.
#   Stays on v3 line for chart compatibility — v4 migration is a deliberate choice.

kubectl_minor = '1.36'
helm_version  = '3.21.3'
helm_sha256   = '15e041a93a590dce8100f39385cd98c84a765c9e36aeeb9e2dc6ff9e4769e2e0'

execute 'kubernetes-gpg-key' do
  command "curl -fsSL https://pkgs.k8s.io/core:/stable:/v#{kubectl_minor}/deb/Release.key | gpg --dearmor -o /usr/share/keyrings/kubernetes.gpg && chmod 644 /usr/share/keyrings/kubernetes.gpg"
  not_if { ::File.exist?('/usr/share/keyrings/kubernetes.gpg') }
end

file '/etc/apt/sources.list.d/kubernetes.list' do
  content "deb [signed-by=/usr/share/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v#{kubectl_minor}/deb/ /\n"
  mode '0644'
  notifies :run, 'execute[apt-update-k8s]', :immediately
end

execute 'apt-update-k8s' do
  command 'apt-get update -qq'
  action :nothing
end

# :upgrade, not the default :install — bumping kubectl_minor above only repoints
# the apt repo, and :install is satisfied by *any* installed kubectl, so the
# converge that changes the pin leaves the old binary in place. Verified: right
# after a converge with the repo moved to 1.36, the VM still ran 1.34.10.
# unattended-upgrades does carry `site=pkgs.k8s.io` and would pick it up on its
# next nightly run, but then the bump lands hours later than the converge that
# declared it, and a build that trims Origins-Pattern never gets it at all.
# The pinned repo remains the ceiling, so this cannot wander past kubectl_minor.
package 'kubectl' do
  action :upgrade
  options '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
end

execute 'install-helm' do
  command <<~SH
    set -e
    cd /tmp
    curl -fsSL "https://get.helm.sh/helm-v#{helm_version}-linux-amd64.tar.gz" -o helm.tar.gz
    echo "#{helm_sha256}  helm.tar.gz" | sha256sum -c -
    tar xzf helm.tar.gz
    install -m 0755 linux-amd64/helm /usr/local/bin/helm
    rm -rf helm.tar.gz linux-amd64
  SH
  not_if "test -x /usr/local/bin/helm && /usr/local/bin/helm version --short 2>/dev/null | grep -q 'v#{helm_version}'"
end
