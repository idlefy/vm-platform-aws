# Falco — runtime detection at the syscall layer, via eBPF.
#
# It feeds the SAME journald -> Alloy -> Loki pipeline base::alloy builds, when
# that pipeline is enabled (node['base']['loki']['enabled']); Falco itself does
# not depend on it and keeps writing to the local journal regardless. Falco
# gets no transport of its own and no network-reachable port: it hands each match
# to journald via syslog(3) as a JSON object, and Alloy already ships the journal.
# This is what the log-shipping spec meant by "it will attach to this pipeline as
# another source rather than needing its own transport".
#
# Two properties of that route are worth knowing before touching it. journald maps
# Falco's severity onto the entry's PRIORITY, so base::alloy's existing
# __journal_priority_keyword relabel gives each detection a real `level` label for
# free. And the entries are attributed to falco-modern-bpf.service, which is a
# unit no developer can write to — so stage.limit buckets Falco's output on its
# own, away from the session scopes that the audit-suppression fix in 0.6.0 exists
# to protect.
#
# Falco does NOT replace the journal pipeline and cannot. It emits a line only
# when a rule matches, so it records behaviour, never state: no rule hit means no
# record. The application-level verdicts the existing alerts are built on — an
# sshd auth outcome, `user NOT in sudoers`, a failed converge — have no syscall
# representation at all. The two sources overlap on approximately nothing, which
# is also why adding this costs almost nothing in Loki.
#
# ---------------------------------------------------------------------------
# IN PRODUCTION as of 2026-08-12 (base 0.9.0). All four rules in rules.d have had
# their upstream-overlap check done; see below for the regression check a Falco
# package upgrade requires.
#
# What IS measured (two staging VMs, 2026-08-06): Falco's `stable` set — 25 rules,
# 17 tagged `host` — is silent on this platform. Zero detections and zero bytes at
# idle, and zero under a workload of npm installs, multi-layer docker builds with a
# compiler inside the container, `make -j4` over 200 shell recipes, tree deletions,
# apt, logrotate and refused sudo. The single exception is handled by the macro
# override below. Six rules were proven to fire by triggering them deliberately.
#
# What IS measured for the first three rules this cookbook adds in
# /etc/falco/rules.d/50-dev-vm.yaml: verified firing on a live VM on 2026-08-06,
# closing the two open questions about Falco field semantics on *failed*
# syscalls — fd.name is populated on an EACCES open, and a connect() whose SYN is
# dropped does yield an exit event with fd.sip set.
#
# What IS measured for the fourth rule ("Developer user invoked sudo"), added
# 2026-08-12: a real refused `sudo` by `ubuntu` produced exactly one detection,
# and it reached Loki, not just the local journal. Three separate forgeries —
# `logger -t sudo`, a symlink named `sudo` pointing at `/usr/bin/logger`, and
# `prctl(PR_SET_NAME)` from a lingering sender — produced zero detections. 3 of 3
# real refused-sudo attempts survived an ~11,500-line flood in the same session
# scope. Ordinary developer work (npm, docker build, make -j4, apt, logrotate)
# produced none.
#
# Overlap for the fourth rule IS measured too (2026-08-12, `falco -L` on a
# converged VM): 29 rules load, and the only stable rules whose condition
# mentions sudo key on *file access* to /etc/sudoers and /etc/sudoers.d, never on
# an execve. So nothing upstream can take this event first. The rules file header
# records the same measurement — keep the two in step, because an operator who
# reads only one of them has to be able to act on it.
#
# What is NOT measured is any FUTURE falco package. `rule_matching: first` plus
# rules.d loading after falco_rules.yaml means a new upstream rule matching sudo
# execve would silently take the event and ours would never fire. So this is a
# regression check to re-run after every upgrade, not a first-time validation:
# `falco -L | grep -i sudo`, then provoke a real refused sudo as `ubuntu` and
# confirm the detection reaches **Loki**. Do not conclude it still holds just
# because the rule fires — a coincidentally-firing upstream rule looks identical
# from Loki alone.
#
# The policy group is the only gate. This recipe is in base::default, so `make push`
# reaches staging VMs and `make promote` reaches the fleet.
# ---------------------------------------------------------------------------

# Falco publishes an ASCII-armored key; dearmor to .gpg under /usr/share/keyrings,
# the same shape base::docker and base::kubernetes use.
#
# KEY ROTATION: the guard is "does the file exist", so the key is fetched once and
# never refreshed. The long note in base::alloy explains why that is deliberate
# rather than lazy and applies here verbatim — silently re-pulling a signing key
# every converge would let a compromised download.falco.org rotate us onto its own
# key unobserved. Note the asymmetry with Alloy though: because Falco is NOT in
# unattended-upgrades' Origins-Pattern (see below), a stale key here breaks the
# next deliberate version bump rather than silently stopping security updates.
execute 'falco-gpg-key' do
  command 'curl -fsSL https://falco.org/repo/falcosecurity-packages.asc | ' \
          'gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg && ' \
          'chmod 644 /usr/share/keyrings/falco-archive-keyring.gpg'
  not_if { ::File.exist?('/usr/share/keyrings/falco-archive-keyring.gpg') }
end

file '/etc/apt/sources.list.d/falcosecurity.list' do
  content 'deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] ' \
          "https://download.falco.org/packages/deb stable main\n"
  mode '0644'
  notifies :run, 'execute[apt-update-falco]', :immediately
end

execute 'apt-update-falco' do
  command 'apt-get update -qq'
  action :nothing
end

# PINNED, for the same reasons base::alloy is pinned, plus one specific to Falco:
# 0.44 removed the legacy eBPF probe and broke driver compatibility with 0.43's
# userspace outright. An unpinned install means a VM created next month gets
# whatever the repo serves then.
#
# Unlike Alloy, download.falco.org is deliberately NOT added to
# unattended-upgrades' Origins-Pattern. Consequence, stated plainly because it is
# an ongoing obligation rather than a detail: **Falco receives no automatic
# security updates on this fleet.** It runs as root with an eBPF probe attached,
# so its CVEs are ours to track, and bumping this string is the only way it moves.
# The Package-Blacklist entry in base::unattended_upgrades is defensive — it costs
# one line and stops a future "let's get Falco's patches automatically" edit from
# turning into the daily version flap CLAUDE.md records for Alloy.
falco_version = '0.44.1'

# Installed with `execute` rather than `package` because the deb's postinst reads
# environment variables that decide things the package resource cannot express:
#
#   FALCO_DRIVER_CHOICE=modern_ebpf — which driver, and therefore which systemd
#     unit gets enabled. Forced rather than left to the interactive default
#     because modern eBPF is the one option with no moving parts: it is CO-RE and
#     compiled INTO the falco binary, so there is no probe to rebuild after a
#     kernel upgrade, no dkms/linux-headers dependency, and 0.44's
#     driver-vs-userspace incompatibility cannot bite because the driver moves
#     with the binary by construction. Needs kernel >= 5.8; noble ships 6.8.
#
#   FALCOCTL_ENABLED=no — do not enable falcoctl's artifact services. A security
#     decision, not tidiness: falcoctl-artifact-follow.service polls an OCI
#     registry and REPLACES the ruleset on a running host. That is precisely the
#     second control plane the log-shipping spec rejected Grafana Cloud Fleet
#     Management for — configuration this platform's git does not know about. Here
#     it would also fight the converge: falcoctl raises a new ruleset, CINC puts
#     the cookbook's back 30 minutes later, forever. Rules come from git or they
#     do not come.
#
#   FALCO_FRONTEND=noninteractive — the postinst otherwise opens a dialog prompt
#     for the driver choice, which hangs the converge rather than failing it.
#
# --allow-downgrades makes the pin authoritative in both directions, matching what
# `package ... version` would do; the dpkg conffile options match base::alloy's so
# a version bump cannot stop on a config prompt.
execute 'install-falco' do
  command "apt-get install -y --allow-downgrades falco=#{falco_version} " \
          '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"'
  environment(
    'FALCO_DRIVER_CHOICE' => 'modern_ebpf',
    'FALCOCTL_ENABLED' => 'no',
    'FALCO_FRONTEND' => 'noninteractive',
    'DEBIAN_FRONTEND' => 'noninteractive'
  )
  not_if "dpkg-query -W -f='${Version}' falco 2>/dev/null | grep -qx '#{falco_version}'"
end

# Belt and braces on FALCOCTL_ENABLED. That variable only affects the install that
# runs it, so a host where Falco arrived before this recipe did — or a future
# postinst that re-enables the units — would keep them. Masking is idempotent,
# survives reinstalls, and is checkable in one command.
#
# `systemctl mask` on a unit that does not exist still succeeds (it symlinks to
# /dev/null), so no existence guard is needed. The guard that matters is the
# not_if: `is-enabled` on a masked unit prints "masked" and exits non-zero, and
# piping to grep makes grep's status the one Chef sees.
%w(falcoctl-artifact-follow.service falcoctl-artifact-install.service).each do |unit|
  execute "mask-#{unit}" do
    command "systemctl mask #{unit}"
    not_if "systemctl is-enabled #{unit} 2>/dev/null | grep -qx masked"
  end
end

# Configuration as a drop-in, not by rewriting /etc/falco/falco.yaml. The package
# owns falco.yaml as a conffile, so editing it in place buys a dpkg conffile
# conflict on every bump; /etc/falco/config.d has been the supported override path
# since 0.38.
#
# Falco's shipped defaults are already right for most of this: `priority: debug`
# loads every rule, and json_include_output_property / json_include_tags_property
# are already true, so `tags` arrives without asking.
#
# What has to be overridden, and the middle one was learned the hard way:
#
#   json_output — ships as false. Without it the output is a prose line, and
#     counting per rule would mean regexing English. With it, the journal message
#     is a complete JSON object, so Alloy's stage.output hands Loki something
#     `| json` parses directly. Verified on a live VM: 3.6 KB, not truncated,
#     rule/priority/tags/output_fields all present.
#
#   syslog_output — ships as **true**, and it must STAY true, because it is the
#     ONLY channel that reaches journald. The upstream unit
#     (/usr/lib/systemd/system/falco-modern-bpf.service) sets
#     `StandardOutput=null`, so everything stdout_output writes goes to /dev/null.
#     Falco's startup banner still appears in the journal — that goes to stderr,
#     which the unit leaves alone — which makes this the platform's signature
#     failure exactly: unit active, health webserver answering {"status": "ok"},
#     25 rules loaded, probe attached with zero drops, and not one detection
#     recorded. It was found by running a second Falco in the foreground with the
#     same config and the same rules and watching IT detect the same events. Do
#     not "de-duplicate" these two channels by turning syslog off; there is no
#     duplicate to remove, and turning it off silently deletes the audit trail.
#
#   stdout_output — set to false to say out loud that it is not the path. Leaving
#     it true would read as "output goes to stdout", which is exactly the wrong
#     mental model for the next person to debug this.
#
#   webserver — ships **enabled on 0.0.0.0:8765**. Nothing here consumes it: it
#     serves /healthz and the k8s audit endpoint. firewall.rb's INPUT policy is
#     DROP with only 22/80/443 open, so it is not reachable from outside — but the
#     log-shipping spec promises this recipe adds "no network-reachable ports",
#     and a promise kept only by a second recipe's iptables rules is not kept by
#     construction. It is also reachable by every local user, including the
#     developer. Off.
#
# Named 90- and not 10-: config.d files are loaded in lexicographic order and later
# files override earlier ones, and the package ships its own drop-ins
# (engine-kind-falcoctl.yaml, falco.container_plugin.yaml) whose names sort after any
# digit. Neither of them sets a key we set today — checked on a live VM — but a
# future package that did would silently win. Ours goes last.
file '/etc/falco/config.d/90-dev-vm.yaml' do
  content <<~YAML
    # Managed by CINC — base::falco. Local edits are reverted within 30 minutes.
    engine:
      kind: modern_ebpf

    json_output: true

    # The unit sets StandardOutput=null, so syslog is the only route to journald.
    # Do not swap these two around without re-reading the note in base::falco.
    syslog_output:
      enabled: true

    stdout_output:
      enabled: false

    webserver:
      enabled: false
  YAML
  owner 'root'
  group 'root'
  mode '0644'
  notifies :restart, 'service[falco-modern-bpf]', :delayed
end

# The same settings lived at 10-dev-vm.yaml until base 0.8.2. Chef does not remove a
# renamed file, and both would be loaded, so it is deleted explicitly. A stale config
# in a path nothing manages any more is how a setting comes back from the dead.
file '/etc/falco/config.d/10-dev-vm.yaml' do
  action :delete
end

# Overrides of UPSTREAM rules live here. New rules of our own live in
# /etc/falco/rules.d/50-dev-vm.yaml below — one file per job, so a diff shows at a
# glance whether it changes Falco's behaviour or ours.
#
# The single override is the one the measurement run earned. Over an hour on two
# staging VMs, `Read sensitive file untrusted` was the only stable rule that fired
# without being deliberately triggered, and 100% of its hits — every one, no
# exceptions — came from /usr/lib/systemd/systemd-executor. systemd 255 splits unit
# execution into a helper, and starting a unit makes that helper read /etc/shadow
# and five files under /etc/pam.d. Measured cost: 12 events, about 43 KB, per login
# by a user without lingering (that is `admin`, i.e. every devops session; `ubuntu`
# has lingering enabled by base::docker so its user manager never restarts and
# developer logins cost nothing).
#
# So this is an exception, not a disable: a genuine read of /etc/shadow by an
# unexpected binary is exactly what the rule is for, and it stays.
#
# user_known_read_sensitive_files_activities is upstream's own hook for this — it
# ships as `(never_true)` precisely so adopters can override it.
#
# Keyed on proc.exepath, and that is load-bearing. The process name here is the
# literal string "9" (systemd passes a file descriptor number as argv[0]), and
# proc.name is whatever a process calls itself — so a rule keyed on the name would
# let any developer exempt themselves from the sensitive-file rule by naming a
# binary `9`. proc.exepath resolves /proc/PID/exe, and Falco reads it from the
# kernel while observing the syscall — not from a line a process asked to have
# logged. That is the distinction that matters, and it is NOT the same as _COMM
# versus SYSLOG_IDENTIFIER in base::alloy: _COMM is also settable by the sender
# (symlink name, or prctl(PR_SET_NAME)), so base::alloy's selector is
# best-effort. This is not. The same mistake — trusting a field because it
# names a process — was available here.
file '/etc/falco/falco_rules.local.yaml' do
  content <<~YAML
    # Managed by CINC — base::falco. Local edits are reverted within 30 minutes.
    #
    # Overrides of UPSTREAM rules and macros only. Our own rules are in
    # /etc/falco/rules.d/50-dev-vm.yaml.

    # Two platform components read sensitive files as part of doing their job, and
    # both are root-owned paths a developer cannot write to — which is what makes
    # exempting them safe. proc.exepath, never proc.name: systemd-executor calls
    # itself "9", and a name is not a trust boundary.
    #
    #   systemd-executor  — starting ANY unit makes it read /etc/shadow and five
    #     files under /etc/pam.d. About 12 events per login by a user without
    #     lingering, i.e. every devops session. Measured 2026-08-06: 36 events from
    #     three admin logins before this exception, 0 after.
    #
    #   cinc's ruby       — the converge reads /etc/shadow and /etc/sudoers.d/admin
    #     and writes the latter through .chef-admin* temp files. 8 events per
    #     converge, so ~380/day/VM at a 30-minute interval. Only visible AFTER the
    #     systemd exception landed, which is the argument for measuring in rounds.
    #
    # If this list ever needs a third entry, re-open the question of whether the rule
    # earns its keep: the developer cannot read /etc/shadow at all (0640 root:shadow),
    # so every hit is by definition a root process, and root processes here are all
    # ours. The rule's value is post-escalation activity, and it is worth keeping only
    # while the allowlist stays short enough to read.
    - macro: user_known_read_sensitive_files_activities
      condition: >
        (proc.exepath in ("/usr/lib/systemd/systemd-executor",
                          "/opt/cinc/embedded/bin/ruby"))
  YAML
  owner 'root'
  group 'root'
  mode '0644'
  notifies :restart, 'service[falco-modern-bpf]', :delayed
end

# Our own rules. Four, and each one exists because this platform makes something
# structurally impossible, so a hit has no legitimate explanation to argue about.
# The file itself records what was considered and rejected, including the two ideas
# that sounded good and do not survive contact with how processes actually inherit
# state. Read it before adding a fifth.
cookbook_file '/etc/falco/rules.d/50-dev-vm.yaml' do
  source 'falco-dev-vm-rules.yaml'
  owner 'root'
  group 'root'
  mode '0644'
  # Same guard, and the same reasoning, as the Alloy config template in
  # base::alloy — and the chain here is worse. A rules file Falco refuses ends:
  # falco exits non-zero, the unit's Restart=on-failure/RestartSec=15s puts it in
  # a 15-second crash loop, StandardOutput=null hides the reason from journald,
  # every detection stops, alert 6 has noDataState: OK, and nobody is told. The
  # fleet's authoritative escalation detector arrives through this resource, so
  # it does not get to be the one path without a syntax gate.
  #
  # Verified on a live VM 2026-08-12 that this is a real gate and not a rubber
  # stamp: exit 0 on the shipped file, exit 1 on an unknown field name, exit 1 on
  # malformed YAML. An unknown field is the failure that matters — it is what a
  # renamed field after a Falco upgrade looks like, and cookstyle cannot see it.
  verify '/usr/bin/falco --validate %{path}'
  notifies :restart, 'service[falco-modern-bpf]', :delayed
end

# The real unit, not the `falco.service` alias the package also creates.
#
# Two reasons to name it explicitly. `systemctl enable` on an alias is ambiguous,
# and — the one that matters downstream — journald attributes these logs to the
# REAL unit, so the Loki label is unit="falco-modern-bpf.service". Notifications,
# queries and the alerts that follow all have to agree on that string.
service 'falco-modern-bpf' do
  action [:enable, :start]
end
