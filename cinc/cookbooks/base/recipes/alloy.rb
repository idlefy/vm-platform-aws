# Grafana Alloy — ships this VM's systemd journal to Grafana Cloud Loki.
#
# See docs/design/log-shipping.md for why this
# exists, why the label set is exactly five entries, and why nothing is dropped
# by priority.
#
# Two branches on node['base']['loki']['enabled'] (attributes/default.rb).
#
# Off is a teardown, not a skip. A recipe that merely stopped installing would
# leave an already-converged VM shipping on the last token it fetched while the
# tenant believes it is off — dev-vm-loki-token keeps an existing token when
# the fetch is denied, by design. So: stop, purge, delete the credential and
# the WAL, drop the apt source, remove the account. Every resource here is a
# no-op on a VM that never had Alloy.
#
# Nothing in this branch may `notifies` a resource declared below the `return`:
# the target is never added to the collection, Chef raises ResourceNotFound at
# the end of compile, and every VM with shipping off fails every converge.
# That is why deleting grafana.list carries no apt-get update — deleting the
# list file is what stops apt polling apt.grafana.com; the next update from any
# recipe drops the cached index.
unless node['base']['loki']['enabled']
  # No unit-file guard: the systemd provider already makes stop/disable a no-op
  # when the unit does not exist, and cookstyle 9 (CI) rejects such a guard as
  # Chef/RedundantCode/ServiceGuardOnStopDisable.
  service 'alloy' do
    action [:stop, :disable]
  end

  package 'alloy' do
    action :purge
  end

  # config.alloy AND loki-token. Purge handles conffiles its own way; the
  # credential is deleted explicitly, always.
  directory '/etc/alloy' do
    recursive true
    action :delete
  end

  # The WAL (postinst creates /var/lib/alloy/data 0770 alloy:alloy). It holds
  # buffered journal lines that were never delivered — log data, on a VM whose
  # tenant said it does not want log shipping.
  directory '/var/lib/alloy' do
    recursive true
    action :delete
  end

  file '/usr/local/sbin/dev-vm-loki-token' do
    action :delete
  end

  file '/etc/apt/sources.list.d/grafana.list' do
    action :delete
  end

  # /etc/apt/keyrings itself stays: nothing else in the cookbook uses it (every
  # other recipe keys into /usr/share/keyrings) and the enabled branch
  # recreates it.
  file '/etc/apt/keyrings/grafana.asc' do
    action :delete
  end

  # Measured 2026-09-05 against alloy-1.18.0-1.amd64.deb: the package ships no
  # postrm at all, and nothing in its maintainer scripts removes the user or
  # group its postinst creates (`groupadd -r alloy`, `useradd -m -r -g alloy`).
  # Without these two resources an "unmonitored" VM keeps an account in
  # systemd-journal and adm — journal read rights with no purpose. userdel
  # drops the group memberships with the account, so the group resources in
  # the enabled branch need no counterpart; the primary group is removed
  # explicitly rather than relying on USERGROUPS_ENAB.
  user 'alloy' do
    action :remove
  end

  group 'alloy' do
    action :remove
  end

  return
end

# On, so the tenant attributes must be real. The skeleton ships url and
# username as the literal 'REPLACE_ME'. Measured 2026-09-05 with the pinned
# 1.18.0 binary: `alloy validate` returns 0 for url = "", for "REPLACE_ME" and
# for a real URL alike, so the template's verify guard catches neither bad
# value — this raise is the only check there is.
#
# A ruby_block, not a bare raise: a raise in the recipe body fires at compile,
# before ANY resource of ANY recipe has converged, and would leave a tenant
# still carrying the placeholders with a public VM that has no firewall, no
# SSH hardening and no Falco. base::alloy is last in base::default, so failing
# here at converge keeps every hardening recipe applied and still ends the run
# failed, with the attribute named, in the converge log the tenant is already
# reading. A tenant that does not want shipping sets enabled = false instead.
ruby_block 'base::alloy: refuse placeholder loki attributes' do
  block do
    %w(url username).each do |attr|
      value = node['base']['loki'][attr].to_s
      next unless value.empty? || value == 'REPLACE_ME'
      raise ArgumentError,
            "base::alloy: node['base']['loki']['#{attr}'] is '#{value}'; " \
            "set it in the tenant policyfile or set node['base']['loki']['enabled'] = false"
    end
  end
end

directory '/etc/apt/keyrings' do
  mode '0755'
end

# This resembles base::gh's apt pattern but is NOT a copy of it. gh.rb fetches a
# BINARY keyring; Grafana publishes an ASCII-armored key, and apt's handling of
# armored signed-by files depends on the file extension. Hence the .asc name.
#
# KEY ROTATION: like gh.rb, the guard is "does the file exist", so the key is
# fetched once and never refreshed. Grafana last rotated its signing key in 2023.
# When it happens again, apt starts failing with NO_PUBKEY — which also silently
# stops the unattended-upgrades path this recipe wires up, so Alloy would stop
# receiving security updates. The fix is to delete /etc/apt/keyrings/grafana.asc;
# the next converge re-fetches it. That is a manual step by design: silently
# re-pulling a signing key on every converge would mean a compromised apt.grafana.com
# could rotate us onto its own key without anyone noticing.
execute 'alloy-gpg-key' do
  command 'curl -fsSL https://apt.grafana.com/gpg-full.key ' \
          '-o /etc/apt/keyrings/grafana.asc && chmod 644 /etc/apt/keyrings/grafana.asc'
  not_if { ::File.exist?('/etc/apt/keyrings/grafana.asc') }
end

# No arch= here, unlike gh.rb. That is hygiene rather than Graviton support:
# user_data.tf installs an x86_64 AWS CLI and an amd64 CINC package, so an arm64
# VM cannot converge at all today. This just avoids adding a fourth amd64
# assumption to the pile.
file '/etc/apt/sources.list.d/grafana.list' do
  content "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main\n"
  mode '0644'
  notifies :run, 'execute[apt-update-alloy]', :immediately
end

execute 'apt-update-alloy' do
  command 'apt-get update -qq'
  action :nothing
end

# PINNED, and it has to be. Two reasons, and neither is caution for its own sake.
#
# The config template below is written against a specific set of Alloy stages —
# stage.structured_metadata, and stage.limit with by_label_name. River/Alloy
# config has broken across releases before. An unpinned `package 'alloy'` means
# a VM created tomorrow gets whatever apt.grafana.com serves tomorrow, and the
# failure mode is the one this recipe already warns about below: alloy starts,
# the unit is green, and nothing is collected.
#
# Second, unattended_upgrades.rb lists `site=apt.grafana.com` in
# Origins-Pattern, which matches every pocket from that repo rather than only
# security — so without this pin a *running* VM would also be moved onto new
# majors overnight. That recipe blacklists `alloy` for exactly this reason; the
# pin and the blacklist are one change and neither works alone (pin without
# blacklist flaps the package daily: unattended raises it at night, the converge
# lowers it in the morning).
#
# Bumping is therefore a deliberate one-line edit that rides the normal
# push -> staging -> promote flow. Before bumping, re-check the template's stages
# against the new release's config reference — a green unit proves nothing here.
package 'alloy' do
  version '1.18.0-1'
  options '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
end

# systemd-journal is what actually grants journal read; adm is the Debian/Ubuntu
# convention for log access and is added for consistency with the distro.
#
# The failure mode is why this is worth a comment: with neither group,
# loki.source.journal starts WITHOUT error and silently collects nothing. A green
# unit proves nothing here, which is why acceptance checks that lines arrive in
# Loki rather than that the service is running.
group 'systemd-journal' do
  members ['alloy']
  append true
  action :modify
end

group 'adm' do
  members ['alloy']
  append true
  action :modify
end

# Region resolution. Ohai's ec2 plugin first, IMDSv2 curl as a fallback — the
# same order and the same reasoning as base::aws_access, which documents it at
# length. This copy is deliberately shorter because the stakes look lower but
# are not: alloy_region is also the region argument passed to
# dev-vm-loki-token below, so an unresolved region makes that SSM fetch fail
# with exit 10 and no token is ever published — nothing ships at all, which is
# a broken feature, not a wrong label.
#
# Reachable at all only because cinc-client runs as root; imds.rb blocks IMDS for
# every other uid.
#
# Region via the shared hardened lookup (libraries/imds.rb) — same source as
# base::aws_access, one implementation instead of two drifting copies. The -f
# and timeout reasoning that used to live here verbatim is in the library.
alloy_region = DevVm::Imds.region(node)

alloy_region = 'unknown' if alloy_region.empty?

# Public IP, for the public_ip label. Same ohai-then-IMDSv2 order as the region
# above, and reachable for the same reason: cinc-client runs as root and imds.rb
# blocks IMDS for every other uid.
#
# Unlike the region this is NOT given an 'unknown' sentinel. A VM with no public
# address is a legitimate configuration, and labelling it public_ip="unknown"
# would put a value into Loki's index that means "no such thing" — then
# {public_ip="unknown"} silently matches every private VM in the fleet as if they
# were one host. The template omits the label instead when this is nil.
#
# Terraform allocates an aws_eip per VM, so the value is stable for the life of
# the instance rather than changing on stop/start the way a default public IP
# would. It is not eternal: destroying and recreating a VM yields a new address,
# and a released EIP can later be allocated to a DIFFERENT VM — so a query by
# public_ip over a long window can span two machines. Correlate by instance when
# that matters; public_ip is for getting from an external report, which only ever
# knows the address, to the right VM's logs.
#
# A changed EIP is picked up on the next converge (<=30 min), because the value is
# baked into the rendered config rather than read at runtime. Within that window
# the label is stale. That is inherent to putting an address in a label: any
# snapshot has it, and reading it at runtime is not something loki.source.journal's
# `labels` argument can do.
#
# There is a first-boot race in the same shape. network.tf sets
# map_public_ip_on_launch = true, so an instance gets an ephemeral Amazon address
# at launch and Terraform's aws_eip_association then replaces it. If a converge
# ran between those two events it would bake the ephemeral address. It does not in
# practice — user_data spends around two minutes installing before cinc-client
# first runs, and the association lands within seconds of the instance — and even
# if it did, the label would be *correct for that window* and self-corrects on the
# next converge. Do not add a wait loop for this; it would buy nothing and would
# block the first converge on IMDS.
alloy_public_ip =
  if node.attribute?('ec2') && !node['ec2']['public_ipv4'].to_s.empty?
    node['ec2']['public_ipv4'].to_s.strip
  else
    # Bounded for the same reason as the region lookup above.
    token = shell_out(
      'curl -fsS --connect-timeout 2 --max-time 5 ' \
      '-X PUT http://169.254.169.254/latest/api/token ' \
      '-H "X-aws-ec2-metadata-token-ttl-seconds: 60"'
    ).stdout.strip
    if token.empty?
      ''
    else
      # A VM with no public address returns 404 here, not an empty 200, so the
      # body would be an HTML error page. Anything that is not an IPv4 literal
      # is treated as "no public IP" rather than trusted into a label.
      body = shell_out(
        'curl -fsS --connect-timeout 2 --max-time 5 ' \
        "-H 'X-aws-ec2-metadata-token: #{token}' " \
        'http://169.254.169.254/latest/meta-data/public-ipv4'
      ).stdout.strip
      body =~ /\A\d{1,3}(\.\d{1,3}){3}\z/ ? body : ''
    end
  end

directory '/etc/alloy' do
  owner 'root'
  group 'alloy'
  mode '0750'
end

cookbook_file '/usr/local/sbin/dev-vm-loki-token' do
  source 'dev-vm-loki-token'
  owner 'root'
  group 'root'
  mode '0700'
end

# returns [0, 10] — 10 means "SSM was unreachable, the old token still stands".
# Letting that fail the converge would skip the remaining resources in this
# recipe — the config template and service[alloy] — for a problem that fixes
# itself in 30 minutes, and the node would report a failed converge every time
# until it does. (include_recipe 'base::alloy' is currently the last line of
# default.rb, so no later recipe pays that cost today — but that is incidental
# placement, not a guarantee, so this reasoning still holds if one is added
# after it.)
#
# live_stream is what makes that survivable. Chef does not surface a *successful*
# command's stderr, and returns [0, 10] declares failure to be success — so
# without this the script's WARN line goes nowhere and a fleet whose token fetch
# has been failing every converge for a week produces no observable warning
# anywhere. Safe to stream because the script never writes the token to stdout or
# stderr, and the test suite asserts that on every path.
#
# This resource has no guard, so every converge reports it as updated — about 48
# times a day, forever. traefik.rb records the house objection to a permanently
# non-clean converge, so this is a deliberate exception rather than an oversight:
# the spec requires the token be re-fetched every converge precisely so that
# rotation needs nothing but a new value in SSM. Driving it from a systemd timer
# like aws-vm-credentials would keep the run clean but move rotation latency off
# the converge cycle and add a second unit to reason about.
execute 'dev-vm-loki-token' do
  command "/usr/local/sbin/dev-vm-loki-token #{alloy_region} " \
          "#{node['base']['loki']['ssm_parameter_name']}"
  returns [0, 10]
  live_stream true
end

template '/etc/alloy/config.alloy' do
  source 'alloy-config.alloy.erb'
  owner 'root'
  group 'alloy'
  mode '0640'
  variables(
    vm_name: node.name,
    region: alloy_region,
    public_ip: alloy_public_ip,
    loki_url: node['base']['loki']['url'],
    loki_user: node['base']['loki']['username']
  )
  # Without this guard a bad config is installed and nobody is told, because
  # every alert has noDataState: OK. It fails two different ways:
  #   - broken syntax    -> alloy refuses to start, dead unit, zero lines
  #   - bad component arg -> the unit comes up and the component does not load:
  #                          GREEN unit, zero lines. This is the worse of the two
  #                          and it is the documented Alloy-pin trap in CLAUDE.md.
  #
  # `validate`, not `fmt`, because only one of them catches the second case.
  # Measured as root on a live VM 2026-08-12 against this very config: both
  # subcommands exist on the pinned 1.18.0 and both reject broken syntax
  # (exit 1), but a block carrying an argument the binary does not accept passes
  # `fmt` (exit 0) and fails `validate` (exit 1). `fmt` is a formatter, so that
  # is its designed behaviour rather than a bug — it is simply the wrong tool for
  # this job.
  #
  # Both rendered branches of the template were validated on that VM (exit 0
  # each): with a public_ip label and without one. The second is the branch a
  # first converge takes when IMDS has not yet yielded an address, and it is the
  # one place a false rejection would be unrecoverable — there is no previously
  # installed config to keep shipping. To re-run it after editing the template,
  # render it three times with public_ip set to an address, to '' and to nil —
  # the last two render identically — and run `alloy validate` on each.
  verify '/usr/bin/alloy validate %{path} > /dev/null'
  notifies :restart, 'service[alloy]', :delayed
end

service 'alloy' do
  action [:enable, :start]
end
