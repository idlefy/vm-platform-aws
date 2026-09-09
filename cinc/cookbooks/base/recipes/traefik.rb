# Traefik reverse proxy for services a developer chooses to publish.
#
# The platform owns the proxy; the developer owns the routes. Routes come from
# docker labels on the developer's own containers, so no vhost ever enters this
# cookbook and there is nothing for each developer to configure differently.
#
# Runs in the developer's ROOTLESS docker as a systemd *user* unit. Chef's
# `service` resource drives system systemd and cannot manage a user unit, so
# every start/restart here goes through `su -l ubuntu -c 'systemctl --user …'`.
#
# The design record for this recipe is not published; the comments below carry
# the decisions that matter.

ubuntu_uid  = shell_out('id -u ubuntu').stdout.strip
runtime_dir = "/run/user/#{ubuntu_uid}"
docker_env  = "XDG_RUNTIME_DIR=#{runtime_dir} DOCKER_HOST=unix://#{runtime_dir}/docker.sock"

# Pinned by tag AND digest. Bump both together; verify a new digest against the
# registry with `docker buildx imagetools inspect traefik:<tag>` rather than
# trusting a tag, which is mutable.
traefik_image = 'traefik:v3.7.9@sha256:652929a140a32d7cafafb13c6cdfab5376cfeff800f51397b87b524501ed02a8'

# Rootless docker publishes host ports through rootlesskit, which is an
# unprivileged process and so cannot bind below 1024 by default.
#
# setcap on rootlesskit rather than lowering net.ipv4.ip_unprivileged_port_start:
# the sysctl would let EVERY unprivileged process on the machine take 80/443,
# including anything a compromised developer process spawns. The capability is
# granted to the port forwarder alone.
#
# This is NOT a one-time install step. unattended_upgrades.rb carries
# "origin=Docker" in Origins-Pattern, so docker-ce-rootless-extras is upgraded
# nightly and unattended. An upgrade replaces the rootlesskit binary, and file
# capabilities live in the binary's xattrs — so the capability is destroyed by
# routine maintenance, not by an edge case. Check and reapply on every converge.
# Setting the capability is not enough on its own: capabilities are read at
# exec, and the rootless daemon started at boot — before this recipe ran — so
# the running rootlesskit has no capability no matter what its binary now says.
# The symptom is an honest one for once, in `journalctl --user -u traefik`:
#
#   cannot expose privileged port 80 ... or set CAP_NET_BIND_SERVICE on
#   rootlesskit binary ... bind: permission denied
#
# while `getcap` shows the capability present. So the daemon has to be restarted
# whenever the capability is (re)applied — including after each nightly docker
# upgrade, which strips it. Immediate, not delayed: `enable-traefik` further
# down starts Traefik in this same run and needs a capable rootlesskit by then.
#
# The cost is that the developer's containers go down when this fires — and
# "bounce" would be the wrong word: docker only restores containers that
# declared a restart policy, so anything started without one stays Exited.
# Verified on a live VM. That is acceptable because it only fires when the
# capability was missing, and the docker upgrade that removes it has already
# restarted the daemon — so those containers were already down before this ran.
# The developer-facing readme tells people to set `restart: unless-stopped`,
# which they need anyway: Idlefy stops these VMs nightly.
execute 'setcap-rootlesskit' do
  command 'setcap cap_net_bind_service=ep "$(command -v rootlesskit)"'
  not_if  'getcap "$(command -v rootlesskit)" 2>/dev/null | grep -q cap_net_bind_service'
  only_if 'command -v rootlesskit >/dev/null'
  notifies :run, 'execute[restart-user-docker]', :immediately
  notifies :run, 'execute[restart-traefik]', :delayed
end

execute 'restart-user-docker' do
  command "su -l ubuntu -c '#{docker_env} systemctl --user restart docker.service'"
  action :nothing
  only_if { ::File.exist?('/home/ubuntu/.config/systemd/user/docker.service') }
end

# ACME storage. Traefik requires acme.json at 0600 and must be able to write it.
# If this directory were root-owned the certificate could not be persisted, so
# every restart would re-issue instead of reuse — and Idlefy stops and starts
# these VMs daily, which would silently turn "one certificate per VM" into a
# race with Let's Encrypt's 50-per-week limit while appearing to work.
#
# All four directories are created as ubuntu: root never writes under
# /home/ubuntu (docs/design/first-external-review.md §1). ACME storage is 0700
# for the reason in the comment above; the rest are 0755.
execute 'ubuntu-traefik-dirs' do
  command 'install -d -m 0755 /home/ubuntu/.config/traefik /home/ubuntu/.config/traefik/dynamic /home/ubuntu/.config/systemd/user && ' \
          'install -d -m 0700 /home/ubuntu/.local/share/traefik'
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -d /home/ubuntu/.config/traefik/dynamic && test -d /home/ubuntu/.config/systemd/user && test -d /home/ubuntu/.local/share/traefik', user: 'ubuntu'
end

# One resource, one guard, both files.
#
# The hash and the plaintext are two artifacts of a single secret, so they are
# written together from one generated value. Two independently guarded resources
# could be interrupted between them — a killed cinc-client run — and leave a
# password file that no longer authenticates against the users file, with
# nothing anywhere reporting it: the developer would simply get 401s from a
# password the platform told them was correct.
#
# Guarded on existence, so it runs once in the life of the VM. That is the same
# shape as the `creates:`-guarded task removed from the CINC server role in
# upstream PR #6, and here it is correct: that task declared a VERSION, which
# state had to converge to, while this declares that A PASSWORD EXISTS.
# Re-running it every 30 minutes would rotate the developer's password twice an
# hour. Do not "fix" it by analogy.
#
# The guard is only safe because the unit mounts the configuration DIRECTORY —
# see the comment in traefik.service.erb before changing that.
#
# One resource is not by itself enough, because the guard file is also written
# by this script. Writing `users` in place and chowning it afterwards leaves a
# window — small, but permanent if it is hit — where a killed converge has
# produced a root-owned `users` that the guard will then skip forever, and that
# Traefik, running as ubuntu, cannot read. So both files are built under
# temporary names, given their final owner and mode there, and moved into place
# by rename, with the guard file moved LAST. Every intermediate state is then
# one the next converge repairs: no `users` means regenerate both.
#
# -C 12 is deliberate: htpasswd's default bcrypt cost for -B is 5.
#
# Runs as ubuntu: root never writes under /home/ubuntu, and neither openssl
# nor htpasswd needs it.
execute 'generate-traefik-password' do
  command <<~SH
    set -e
    umask 077
    d=/home/ubuntu/.config/traefik
    rm -f "$d/.password.tmp" "$d/.users.tmp"
    pw="$(openssl rand -base64 24)"
    printf '%s\\n' "$pw" > "$d/.password.tmp"
    htpasswd -nbB -C 12 dev "$pw" > "$d/.users.tmp"
    chmod 0600 "$d/.password.tmp" "$d/.users.tmp"
    mv "$d/.password.tmp" "$d/password"
    mv "$d/.users.tmp" "$d/users"
  SH
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if 'test -e /home/ubuntu/.config/traefik/users', user: 'ubuntu'
  notifies :run, 'execute[restart-traefik]', :delayed
end

# Traefik reaches target containers over a network they both join. Creating it
# here means the developer only has to attach to it, never to create it.
execute 'create-traefik-network' do
  command "su -l ubuntu -c '#{docker_env} docker network create web'"
  not_if  "su -l ubuntu -c '#{docker_env} docker network inspect web >/dev/null 2>&1'"
end

# Rendered by root into the staging tree, copied by ubuntu. The staged copies
# carry no secret: traefik.yml has the ACME e-mail, auth.yml names the users
# file, the unit names the image, the readme names the password's PATH.
staged = '/usr/share/dev-vm/home'

%W(#{staged}/.config/traefik/dynamic #{staged}/.config/systemd/user).each do |dir|
  directory dir do
    owner 'root'
    group 'root'
    mode '0755'
    recursive true
  end
end

template "#{staged}/.config/traefik/traefik.yml" do
  source 'traefik.yml.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(acme_email: node['base']['traefik']['acme_email'])
end

execute 'ubuntu-traefik-yml' do
  command "install -m 0644 #{staged}/.config/traefik/traefik.yml /home/ubuntu/.config/traefik/traefik.yml"
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if "cmp -s #{staged}/.config/traefik/traefik.yml /home/ubuntu/.config/traefik/traefik.yml", user: 'ubuntu'
  notifies :run, 'execute[restart-traefik]', :delayed
end

template "#{staged}/.config/traefik/dynamic/auth.yml" do
  source 'traefik-auth.yml.erb'
  owner 'root'
  group 'root'
  mode '0644'
end

# No notifies: providers.file names this file with watch: true, so Traefik picks
# dynamic configuration up by itself. Copy through a temp file and rename so the
# watcher never sees a truncated auth.yml mid-write.
execute 'ubuntu-traefik-auth' do
  command "install -m 0644 #{staged}/.config/traefik/dynamic/auth.yml /home/ubuntu/.config/traefik/.auth.yml.tmp && mv -f /home/ubuntu/.config/traefik/.auth.yml.tmp /home/ubuntu/.config/traefik/dynamic/auth.yml"
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if "cmp -s #{staged}/.config/traefik/dynamic/auth.yml /home/ubuntu/.config/traefik/dynamic/auth.yml", user: 'ubuntu'
end

template "#{staged}/.config/systemd/user/traefik.service" do
  source 'traefik.service.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(image: traefik_image)
end

execute 'ubuntu-traefik-unit' do
  command "install -m 0644 #{staged}/.config/systemd/user/traefik.service /home/ubuntu/.config/systemd/user/traefik.service"
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if "cmp -s #{staged}/.config/systemd/user/traefik.service /home/ubuntu/.config/systemd/user/traefik.service", user: 'ubuntu'
  notifies :run, 'execute[systemd-user-reload]', :immediately
  notifies :run, 'execute[restart-traefik]', :delayed
end

execute 'systemd-user-reload' do
  command "su -l ubuntu -c '#{docker_env} systemctl --user daemon-reload'"
  action :nothing
end

execute 'restart-traefik' do
  command "su -l ubuntu -c '#{docker_env} systemctl --user restart traefik.service'"
  action :nothing
end

# base::docker gets away without an equivalent because
# dockerd-rootless-setuptool.sh enables and starts docker.service itself.
# Nothing does that favour for a unit we render, so without this resource
# Traefik would never run anywhere.
#
# The guard asserts both halves of what the command does. `is-active` alone
# would skip a unit that is running but not enabled — which is the state after
# anyone runs `systemctl --user disable traefik`, and it survives every converge
# until the VM reboots and Traefik does not come back. Idlefy stops and starts
# these VMs daily, so "until the next reboot" means tomorrow.
traefik_up = 'systemctl --user is-enabled traefik.service >/dev/null && ' \
             'systemctl --user is-active traefik.service >/dev/null'

execute 'enable-traefik' do
  command "su -l ubuntu -c '#{docker_env} systemctl --user enable --now traefik.service'"
  not_if  "su -l ubuntu -c 'export #{docker_env}; #{traefik_up}'"
end

# Region via ohai, matching the shape aws_access.rb already uses. Deliberately
# not fatal when unavailable: this value only enriches a readme, and a
# compile-time raise would abort the whole run before firewall or ssh
# converge — see the long comment in aws_access.rb for why that matters here.
# The fallback string is rendered verbatim into the readme when the region is
# unknown, so the template needs no conditional — every other template in this
# cookbook is substitution-only, and this one stays that way.
domain_root = node['base']['traefik']['domain_root']
region      = node.dig('ec2', 'placement_availability_zone')&.sub(/[a-z]$/, '')
fqdn        = if region
                "#{node['hostname']}.ec2.#{region}.#{domain_root}"
              else
                "<this VM's name>.ec2.<region>.#{domain_root}"
              end

# Carries the path to the password, never the password: this is a document
# people forward without reading. Nothing in it may be non-deterministic either,
# or every converge would report it as updated and the team would learn to
# ignore a permanently non-zero run.
template "#{staged}/traefik-readme.md" do
  source 'traefik-readme.md.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(fqdn: fqdn)
end

execute 'ubuntu-traefik-readme' do
  command "install -m 0644 #{staged}/traefik-readme.md /home/ubuntu/traefik-readme.md"
  user 'ubuntu'
  group 'ubuntu'
  environment('HOME' => '/home/ubuntu')
  not_if "cmp -s #{staged}/traefik-readme.md /home/ubuntu/traefik-readme.md", user: 'ubuntu'
end
