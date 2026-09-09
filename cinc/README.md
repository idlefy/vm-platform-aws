# The `base` cookbook

Configuration management for developer VMs via CINC (Chef). This directory holds
the one cookbook this repository publishes and the reference policyfile that
exercises it; a tenant consumes both by tag and edits neither.

> Repo overview: [`../README.md`](../README.md) • Runbook: [`../docs/runbook.md`](../docs/runbook.md)

## Structure

```text
cinc/
  cookbooks/
    base/           # Base cookbook applied to all VMs
      recipes/
        default.rb              # Includes all recipes below
        packages.rb             # make, jq, curl, wget, htop, tmux, git, unzip, vim, ripgrep
        firewall.rb             # iptables (UFW purged): deny incoming, allow 22/80/443
        ssh.rb                  # SSH hardening + EC2 Instance Connect + admin user
        imds.rb                 # Block IMDS for non-root (iptables uid match)
        sudoers.rb              # Strips ubuntu's inherited privileges; grants the one tailscale login
        fail2ban.rb             # SSH brute-force protection (maxretry 5, bantime 3600)
        unattended_upgrades.rb  # Automatic security updates
        chrony.rb               # NTP time sync
        sysctl.rb               # Kernel tuning (network, memory, security)
        cinc_client.rb          # Systemd timer for periodic runs (30min)
        aws_access.rb           # Credential broker: assumes the VM's access role into tmpfs
        docker.rb               # Rootless Docker CE + Compose
        traefik.rb              # Traefik reverse proxy + per-VM basic auth (publishing)
        nvidia_docker.rb        # NVIDIA Container Toolkit + CDI (auto-detect GPU)
        werf.rb                 # werf v2 deployment tool
        kubernetes.rb           # kubectl (apt, pinned minor) + helm (tarball, pinned version)
        nodejs.rb               # Node.js 24 LTS from NodeSource
        claude_code.rb          # Claude Code CLI (claude.ai/install.sh, per-user for ubuntu)
        gh.rb                   # GitHub CLI from cli.github.com
        shell_default.rb        # zsh as the login shell for ubuntu
        yq.rb                   # yq (pinned binary, SHA256-checked)
        uv.rb                   # uv / uvx Python toolchain
        tailscale.rb            # Tailscale package + daemon (the sudo grant lives in sudoers.rb)
        falco.rb                # Falco: runtime syscall detection (modern eBPF) → journal
        alloy.rb                # Grafana Alloy: ships the systemd journal to Grafana Cloud Loki (audit trail). Tears itself down when node['base']['loki']['enabled'] is false
      files/default/
        falco-dev-vm-rules.yaml # Platform-specific Falco rules, and the rejected ideas with reasons
  policyfiles/
    dev-vm.rb       # Policy for developer VMs
```

The recipe list is in `default.rb` order, which is converge order. The last two
entries are ordered deliberately — see the comment above `include_recipe
'base::falco'`.

## Security model

### Access model

| User | Auth method | Sudo | Purpose |
|------|-------------|------|---------|
| **ubuntu** | Static SSH key (AWS key pair) | One command: `/usr/bin/tailscale login` | Developer daily work |
| **admin** | EC2 Instance Connect (ephemeral 60s keys) | Full NOPASSWD | DevOps/lead admin access |
| **root** | SSH disabled (PermitRootLogin no) | N/A | Only via `sudo su -` from admin |

#### Tailscale

`ubuntu`'s one sudo command joins the VM to the tailnet under the developer's own
identity:

```bash
sudo tailscale login
```

It prints a URL. Open it and sign in; the node then appears in the tailnet under
your name — not a machine key, not a shared auth key.

**Type the command exactly as written.** Two spellings are permitted and neither
alerts: `sudo tailscale login` and `sudo /usr/bin/tailscale login` — the exact
strings the `Developer user invoked sudo` Falco rule excludes (see
`recipes/sudoers.rb` and `files/default/falco-dev-vm-rules.yaml`). Everything
else is either refused by sudo — extra flags, any other command — or raises a
security alert that wakes whoever is on call. `sudo -- tailscale login` sits
between those two outcomes: sudoers permits it, but it is deliberately **not**
in the Falco exclusion list, so it still pages someone via alert 6
(critical, `for: 0s`, no threshold) even though it is a legitimate login.

**Running it a second time takes the VM off the tailnet before it does anything
else.** The CLI discards the current profile *before* contacting the control
plane, so if you re-run it and then abandon the browser step, the VM is left
logged out with no way back except finishing a fresh login. Re-run it only when
you intend to complete it.

### IMDS protection

EC2 metadata service (169.254.169.254) is blocked via iptables for all users except:
- **root** (uid 0) — cinc-client, user_data bootstrap, SSM access
- **ec2-instance-connect** — fetches ephemeral SSH keys. `recipes/imds.rb`
  resolves the uid at converge time rather than hard-coding it, because it is
  not fixed across images

This prevents developers/containers from accessing IAM role credentials and SSM secrets.

### Admin SSH access

Admin access uses [EC2 Instance Connect](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-connect-methods.html) — no static keys stored on VM.

```bash
# From a tenant repository — profile and region come from its vms/ root:
cd cinc && make ssh INSTANCE=i-xxxxx

# Or manually (the region must be the one the instance is in):
aws ec2-instance-connect send-ssh-public-key \
  --instance-id i-xxxxx \
  --instance-os-user admin \
  --ssh-public-key file://~/.ssh/id_ed25519.pub \
  --region eu-central-1

ssh -i ~/.ssh/id_ed25519 admin@<ip>
sudo su -   # full root
```

Requires IAM permission `ec2-instance-connect:SendSSHPublicKey`. All access is logged in CloudTrail.

### Docker security

- **Rootless Docker** — no docker group, no privilege escalation
- Container root maps to ubuntu uid on host (user namespaces)
- GPU access via CDI (`--device nvidia.com/gpu=all`), auto-detected by `/dev/nvidia0`
- IMDSv2 hop limit = 1 blocks container IMDS access (defense in depth)

### Developer home directory

Root never writes under `/home/ubuntu`. Chef's `directory` resource follows a
symlink the developer can plant there, and `file`/`template` check only the
last path component, so a root-run resource in the developer's home is a
`chown`/`chmod` of whatever the developer points it at — `/etc/dev-vm`, for
instance, after which the credential broker's environment file is theirs to
replace. Reproduced with `cinc-apply` during the first external review.

The rule the cookbook follows instead: anything that must exist in the home
directory is **staged by root under `/usr/share/dev-vm/home/`** (root-owned,
world-readable, never secret) and **copied into place by `ubuntu`** with
`install`, so a symlink resolves with the developer's privileges and confers
nothing. The Traefik password is generated as `ubuntu` for the same reason.
`spec/recipes/default_spec.rb` (via the shared example in
`spec/support/home_boundary.rb`) converges the whole run list and fails any
recipe that regresses; it runs in the `base-` release gate.

### Automatic updates

Unattended-upgrades runs daily and installs security + non-security patches.
Idlefy stops these VMs when developers finish for the day and starts them again
the next morning, and a stop/start is what puts a new kernel into service — so
kernel updates apply without anyone scheduling a reboot.

| Source | Auto-update | Notes |
|---|---|---|
| Ubuntu `${distro_codename}` (base) | yes | Codename is resolved at runtime, not pinned |
| Ubuntu `${distro_codename}-security` | yes | Security patches |
| Ubuntu `${distro_codename}-updates` | yes | Non-security updates |
| Ubuntu ESM | yes | Requires Ubuntu Pro |
| Docker (download.docker.com) | yes | Patches + minor + major |
| NodeSource (deb.nodesource.com) | yes | Node.js 24.x patches (`node_24.x` repo, locked to major) |
| GitHub CLI (cli.github.com) | yes | `gh` patches + minor + major |
| Kubernetes (pkgs.k8s.io) | yes | `kubectl` patches within a pinned minor — `kubectl_minor` in `kubernetes.rb`, currently `1.36` |
| Helm (get.helm.sh tarball) | no | Pinned tarball with SHA256 — `helm_version` in `kubernetes.rb`, currently `3.21.3`; bump it and `helm_sha256` together |
| Grafana (apt.grafana.com) | repo yes, `alloy` **no** | The site is in `Origins-Pattern`, but `alloy` is in `Package-Blacklist` — its config template is written against specific Alloy stages. Bump in `alloy.rb`. Both Grafana lines are dropped when `base.loki.enabled` is false. |
| Tailscale (pkgs.tailscale.com) | yes | Deliberately unlike Falco, and the reasoning is recorded in `unattended_upgrades.rb`: `tailscaled` also runs as root *and* is invocable by an unprivileged user through a path-matched sudoers rule, so the exposure is larger — but neither of the things that force the Alloy and Falco pins (a version-locked config template, a breaking CLI) applies. Note tailscaled's own c2n `/update` RPC is a second channel that `Package-Blacklist` cannot reach. |
| Falco (download.falco.org) | **no** | The site is deliberately *absent* from `Origins-Pattern`, so unattended cannot see the package at all; `falco` is also blacklisted as belt-and-braces. Bump in `falco.rb`. |
| Claude Code (claude.ai/install.sh) | user-managed | Per-user install via official installer; `claude update` from the user's shell. Not an apt repo; unattended-upgrades does not apply. |

The two `no` rows are not oversights, and both carry a cost worth stating: a
pinned package receives no automatic security patches. For Alloy the pin exists
because a config the new binary rejects fails silently — green unit, zero logs
collected. For Falco it exists for the same reason plus a sharper one: Falco runs
as root with an eBPF probe attached, so a version it cannot load is a detection
gap, not a crash. Bumping either is a deliberate one-line edit, and the rule is
to re-read the config against the new release first. Note that a bare
`site=` entry in `Origins-Pattern` matches **every** pocket that site publishes,
not just its security pocket.

### Audit trail (Grafana Alloy)

`alloy.rb` installs Grafana Alloy from Grafana's own apt repository
(`apt.grafana.com`, wired into `unattended_upgrades.rb` like Docker and
NodeSource) and ships the VM's systemd journal to Grafana Cloud Loki. Every login and `sudo`
invocation is searchable in Loki after the machine that produced it is gone.
`docs/design/log-shipping.md` carries the full reasoning, including why the
Wazuh agent this replaced was removed. That document is a design record written
before this recipe existed, so read it for the argument, not for the current
state.

**Optional per tenant.** `node['base']['loki']['enabled']` (cookbook default
`true`, `attributes/default.rb`) is the switch. `false` is a teardown, not a
skip: the recipe stops and disables the unit, purges the package, deletes
`/etc/alloy` (config and token) and `/var/lib/alloy` (the WAL), the fetch
script, the Grafana apt source and key, and removes the `alloy` user and
group — the deb ships no `postrm`, so nothing else would. The Terraform twin
is `log_shipping` in the tenant's `tenant.auto.tfvars`; `make preflight` in the
tenant checks the two agree. When enabled,
the recipe refuses an empty or `REPLACE_ME` `url`/`username` at converge with
a message naming the attribute: the skeleton ships both as `REPLACE_ME`, and
`alloy validate` (1.18.0, measured) accepts `""` and `REPLACE_ME` as a URL
alike, so nothing downstream would catch either. Design:
`docs/design/optional-log-shipping.md`.

The push token is a Grafana Cloud SecureString kept in SSM — created by hand,
never by Terraform, so its value never enters Terraform state (see
[the runbook](../docs/runbook.md)). Every converge fetches it and publishes it to
`/etc/alloy/loki-token`, mode `0640`, owner `root:alloy`. `ubuntu` has no
sudo and is not in group `alloy`, so it can read neither the token nor
reconfigure or stop the agent.

The fetch script, `dev-vm-loki-token`, exits `10` — not a Chef failure — when
SSM is unreachable, and in that case leaves any existing token file
untouched. The recipe declares `returns [0, 10]` on the resource that runs it,
so this exit code counts as success: the same warn-and-continue shape as
`base::aws_access`. Without that, a transient SSM error would raise and abort
the converge partway through `alloy.rb` itself — skipping the config template
and `service[alloy]`, the two resources still to come in that recipe — and the
node would report a failed converge every 30 minutes until SSM recovered.
(`base::alloy` is last in `default.rb`, and the last two entries are ordered
deliberately — see the comment above `include_recipe 'base::falco'`. So no
*other* recipe is at risk from an abort here. The `returns [0, 10]` is still
what keeps this recipe's own remaining resources from being skipped, which is
what it is for.)

**`ubuntu` can no longer read the system journal.** `sudoers.rb` now also
removes `ubuntu` from the `adm` group — it lives there, not in `alloy.rb`,
because that recipe is already where the developer's default privileges get
stripped. This costs `journalctl` system-wide, `/var/log/syslog` and
`/var/log/auth.log`. It costs nothing else: `journalctl --user` for the
developer's own session units and rootless-Docker's `docker compose logs`
never went through the system journal, so they still work exactly as before.
System-log visibility for developers now lives in Grafana, not on the box.

### Runtime detection (Falco)

> Included in `base::default`, so every tenant gets it on its next `make push &&
> make promote`. Detections feed the *Runtime detection* dashboard row and alert
> rule 6 in `grafana/`. The ruleset below was verified event by event on a live VM
> before being trusted; `docs/design/sudo-audit-alerting.md` is where that bar
> comes from — a rule that loads, validates and never fires is indistinguishable
> from one that works.

`falco.rb` installs Falco from `download.falco.org` and watches syscalls with the
modern eBPF probe (CO-RE, compiled into the binary — no kernel headers, no DKMS).
It answers a question the journal structurally cannot: the journal records what
a program *told* the system it did, Falco records what it *asked the kernel for*.
An `iptables` DROP, for instance, is completely silent in the journal.

Three deployment details are load-bearing, and each one was a bug first:

- **The journal is the only output.** The upstream unit sets
  `StandardOutput=null`, so `stdout_output` goes nowhere; the recipe enables
  `syslog_output` and leaves stdout off. A Falco that is `active`, reports
  `/healthz` ok, loads its rules and drops no events can still emit **zero
  detections** through a disabled channel. Never conclude Falco works from unit
  state — query Loki.
- **The unit is `falco-modern-bpf`, not the `falco.service` alias.** journald
  attributes logs to the real unit, so the alias would break every label.
- **The config drop-in is `90-dev-vm.yaml`.** `/etc/falco/config.d` loads
  lexicographically and later wins; a `10-` prefix sorts *before* the package's
  own drop-ins, which would silently override us. The recipe deletes the old
  `10-` path explicitly.

`falcoctl` is masked (both units) and `webserver` is disabled. falcoctl is a
second control plane that pulls rules from an OCI registry on its own schedule —
which is exactly the authority CINC is supposed to hold here — and the webserver
otherwise listens on `0.0.0.0:8765`.

**Only the `stable` ruleset is loaded, and it is measured silent on this
platform.** Zero detections at idle, and zero under npm installs, multi-layer
container builds with a compiler inside, `make -j4` across 200 recipes, tree
deletions, apt and logrotate. Nine of its 25 rules *cannot* fire: eight are
container-only, and Falco's docker engine watches the rootful socket that
`base::docker` disables, so container processes report `container.id=host`. That
silence is the point — it makes the platform's own rules legible.

Those live in `files/default/falco-dev-vm-rules.yaml`, and each exists because
the platform makes something structurally impossible, so a hit has no legitimate
cause:

| Rule | Fires when | Why it cannot happen legitimately |
|---|---|---|
| AWS credentials file written under a home directory | `~/.aws/credentials` is created, renamed onto, or written | `AWS_SHARED_CREDENTIALS_FILE` points the CLI at the broker's file; a hand-written one is ignored and `aws configure` already fails. Long-lived keys here belong to a principal the VM's permissions boundary does not constrain. |
| Instance metadata service contacted by a non-root process | a non-root, non-`ec2-instance-connect` process connects to `169.254.169.254` | `base::imds` DROPs that address for everyone but uid 0. The attempt is futile *and* invisible today. |
| Denied access to the VM credential store | an `open` in `/dev/shm/dev-vm-aws` returns `EACCES` | Root's broker is the only writer and always succeeds; the developer can read and write nothing. A denial means something is probing or trying to substitute what root published. |
| Developer user invoked sudo | a successful `execve` of `/usr/bin/sudo` under `loginuid` 1000, excluding the two permitted `tailscale login` spellings by full-cmdline equality | `ubuntu` holds sudo on exactly one command. Anything else is refused by sudoers, so the syscall is an escalation attempt whether or not it succeeded. This is the authoritative detector; the journald alerts on the same event are tripwires. |

Two exceptions to the upstream `Read sensitive file untrusted` rule
(`systemd-executor` and cinc's embedded ruby, both by `proc.exepath`) take its
noise from ~44 events per login to zero. Upstream ships `run_by_chef` for the
second case, but it keys on `proc.name=chef-client` — a name CINC renames, and a
name any process can claim, which is why the exception here keys on the path.

Read the rules file before proposing a fifth rule: its header records the ideas
already rejected and why, so they don't get re-derived. The bar is that the rule
must be made to fire on a staging VM before it is believed — and one known gap is
recorded there too: nothing detects a *read* of the broker's credential file,
because malware inside the developer's own tooling shares its uid, its authority
and even its tty.

## Publishing a service

A developer whose only sudo is `tailscale login` cannot edit a vhost. Meanwhile
80/443 are open on every VM with nothing listening behind them. `traefik.rb` fills that gap: the platform
owns one reverse proxy, the developer owns the routes, and a route is declared
by labelling a container rather than by editing anything the cookbook manages.

```text
internet → :80/:443 → traefik (rootless docker, systemd --user)
                        ├── ACME HTTP-01 → Let's Encrypt cert for <vm>.ec2.<region>.<domain>
                        ├── basic auth (middleware auth@file)
                        └── docker labels → the developer's containers on network `web`
```

What each VM gets at first converge, without anyone asking for it:

| Path | Owner/mode | What it is |
|---|---|---|
| `~/.config/traefik/traefik.yml` | `ubuntu` 0644 | Static config. Managed — edits are reverted. |
| `~/.config/traefik/dynamic/auth.yml` | `ubuntu` 0644 | The `auth@file` basic-auth middleware. Managed. |
| `~/.config/traefik/users` | `ubuntu` 0600 | bcrypt hash, cost 12, user `dev`. Generated once. |
| `~/.config/traefik/password` | `ubuntu` 0600 | The plaintext of that same password, for the developer. |
| `~/.local/share/traefik/acme.json` | `ubuntu` 0600 | Issued certificates. Written by Traefik. |
| `~/traefik-readme.md` | `ubuntu` 0644 | The developer-facing version of this section. |

The password is generated **once per VM** and never rotated by a converge —
`generate-traefik-password` is guarded on the users file existing. That guard is
only safe because the unit mounts the configuration *directory*; see the comment
in `templates/traefik.service.erb` before changing either.

An empty VM publishes nothing: `providers.docker.exposedByDefault` is `false`,
the dashboard is off, and an unmatched request gets a 404 behind Traefik's own
self-signed certificate. No certificate is requested until a container claims a
Host rule.

Publishing, from the developer's side:

```yaml
services:
  app:
    image: my-app
    restart: unless-stopped
    networks: [web]
    labels:
      - traefik.enable=true
      - traefik.http.routers.app.rule=Host(`<vm>.ec2.<region>.<domain>`)
      - traefik.http.routers.app.entrypoints=websecure
      - traefik.http.routers.app.tls.certresolver=le
      - traefik.http.routers.app.middlewares=auth@file
      - traefik.http.services.app.loadbalancer.server.port=8080

networks:
  web:
    external: true
```

`restart: unless-stopped` is load-bearing, not boilerplate. Idlefy stops these
VMs when the developer finishes for the day and starts them again the next
morning, and Docker only restores containers that declared a restart policy — so
a published service without one is up until the VM idles out and down every
morning after, with nothing anywhere reporting it. Verified on a live VM: after
a daemon restart the container with a policy is `Up`, the one without is
`Exited (2)`.

Dropping `middlewares=auth@file` publishes the service to the open internet.
That is the developer's call to make, but it is not a quiet one: Let's Encrypt
writes every issued certificate to the public Certificate Transparency logs
within minutes, so the hostname is discoverable the moment a certificate is
issued — scanners read those logs. The readme on each VM leads with this.

Operational notes:

- Rootless docker forwards ports through `rootlesskit`, which cannot bind below
  1024 unprivileged. `traefik.rb` grants `cap_net_bind_service` to that one
  binary — not `net.ipv4.ip_unprivileged_port_start`, which would hand 80/443 to
  every unprivileged process on the machine. Capabilities are read at `exec`, so
  the recipe restarts the rootless daemon whenever it (re)applies the capability.
  The nightly unattended docker upgrade replaces the binary and destroys the
  capability, which is why this is checked on every converge and not at install.
- Traefik is a systemd **user** unit. Chef's `service` resource drives system
  systemd and cannot touch it, so the recipe goes through
  `su -l ubuntu -c 'systemctl --user …'`. Debug the same way:
  `journalctl --user -u traefik -n 50`.
- One name per VM. Wildcard hosts would need DNS-01 and an AWS credential on the
  VM; HTTP-01 needs neither, and the fleet is nowhere near Let's Encrypt's
  50-certificates-per-week limit. Revisit if that changes.

## Prerequisites

Install CINC Workstation (pinned version with SHA256 verification).

The `ubuntu/24.04` path is correct even if your own workstation runs something
newer: the omnibus package carries its own Ruby, so it runs unmodified. It also
matches the VM's release, so the client and the workstation are on the same
build. CINC publishes no build for 26.04 at all.

The version and digest below are the ones this release was built against;
nothing gates them, unlike `metadata.rb`, which `make release` checks. Take a
newer one from downloads.cinc.sh if you want it, and take its digest from the
same place — `.github/workflows/ci.yml` installs the current 26 line, so the
cookbook is exercised on both.

```bash
CINC_WS_VERSION="25.13.7"
CINC_WS_SHA256="c9315a3748b2d5a5754e38b967a58c7ecd3bc30846eb733fc6d580b8df968863"
curl -fsSL "https://downloads.cinc.sh/files/stable/cinc-workstation/${CINC_WS_VERSION}/ubuntu/24.04/cinc-workstation_${CINC_WS_VERSION}-1_amd64.deb" \
  -o /tmp/cinc-workstation.deb
echo "${CINC_WS_SHA256}  /tmp/cinc-workstation.deb" | sha256sum -c -
sudo dpkg -i /tmp/cinc-workstation.deb
rm -f /tmp/cinc-workstation.deb
```

A tenant configures knife at its own `cinc/.chef/knife.rb` — `make prepare`
copies it from the `.example`; substitute the CINC server FQDN and org name:

```ruby
node_name        "admin"
client_key       File.expand_path("../admin.pem", __FILE__)
chef_server_url  "https://<cinc-server-fqdn>/organizations/<org-name>"
```

Place the admin key at `cinc/.chef/admin.pem` (get it from the CINC server:
`/etc/cinc-project/admin.pem`). The key is gitignored — never commit it.

The tenant Makefile defaults `KNIFE_CONFIG` to `./.chef/knife.rb` so `make push`
and `make promote` always talk to *that tenant's* CINC server, even if the
workstation also carries another tenant's `~/.chef/knife.rb`. Override with
`make push KNIFE_CONFIG=<path>` if you need a different config.

Generate an SSH key for EC2 Instance Connect:

```bash
ssh-keygen -t ed25519 -C "admin@<your-org>"
```

## Deployment flow

Nothing is deployed from this repository. A cookbook change ships as a tag,
and a tenant adopts it:

```text
Edit cookbook  →  make release TAG=base-X.Y.Z   (here)
                       ↓
   tenant:  make bump-cookbook TAG=base-X.Y.Z  →  cd cinc && make push
                                                     (staging)
                       ↓
            Test on a staging VM  →  make promote
                                       (production)
```

Both tenant steps are manual — there is no CI/CD pushing policies
automatically — and both are gated: `push` runs `pin-check` and installs from
the committed lock, `promote` runs `preflight` and refuses unless the staging
policy group already carries that revision.

`PREFLIGHT=skip` bypasses only the preflight half of that. The revision check
and `pin-check` still run and still refuse, but nothing then verifies that the
secrets the revision needs exist in every region or that the Loki token still
authenticates — which is how a converge comes up green and ships no logs. The
target says so when you use it.

### Commands

```bash
make help       # Show all available commands
make lint       # Run cookstyle linter
make test       # ChefSpec unit tests
make test-broker      # Credential broker, against a stubbed aws — no AWS needed
make test-loki-token  # Loki token script, likewise stubbed
make install    # Re-resolve policyfiles and rewrite lockfiles (local development)
make clean      # Remove lockfiles
```

Tenant operations — `preflight`, `add-region`, `push`, `promote`, `node-delete`
and `ssh` — live in `tenant-skeleton/cinc/Makefile` and reach a tenant through
`make prepare`. They used to be here as well, back when a fleet was operated
from a copy of this repository; here they could not work at all (no `vms/` root,
no `.chef/knife.rb`, no CINC organisation), so each one now prints where it went
and exits non-zero.

`make preflight`, in a tenant repository, is the odd one out: the `test-*`
targets stub `aws` and assert against artefacts, while preflight talks to the
real AWS and the real Loki. It covers the class of failure `terraform plan`
cannot see by construction — Terraform manages the IAM grant that *names* a
secret, never its value. What it checks and when to run it is in
[the runbook, §7 step 7](../docs/runbook.md#7-grafana-cloud-loki-token-out-of-band-human-step).

One thing about it belongs here rather than there. Its last check compares the
staging and production revisions against the committed lockfile, and when
staging matches and production does not it warns "'make promote' pending" —
correct as a statement of fact, but it cannot know *why* they differ. Whenever
you are deliberately holding a change in staging, that line describes the gap
rather than recommending you close it.

## VM lifecycle

Creating, recreating and deleting a VM are tenant operations and none of them
runs from here. The canonical steps — including the two that Terraform does not
know about, `make node-delete` and removing the node from the tailnet — are in
`tenant-skeleton/CLAUDE.md` (*Create a VM* / *Delete a VM*), which ships with
every tenant. The rest of this section is the model behind them.

Note that Terraform commands run from a tenant's `vms/` root, which has its own
state and backend. Running one from `cinc/` does not fail usefully — there is no
`.tf` file there, so Terraform reports an empty configuration and exits 0.

### Adding a recipe or a policy

A new **recipe** is a change to this cookbook: open a pull request here, and it
reaches tenants as a `base-X.Y.Z` tag they pin. A new **cookbook** is the same
plus a `cookbook` declaration in the policyfile's `run_list` — but note that the
policy pins `base` by tag, so a second cookbook needs its own published source
too; nothing here consumes a cookbook from a tenant's working tree.

A new **policy** is a tenant-side change: create `cinc/policyfiles/<name>.rb`
there with the desired `run_list`, `make push` → converge a staging VM →
`make promote`, then set `policy_name = "<name>"` on the VM's entry in
`vms/instances.auto.tfvars`. That attribute is read once at first boot, so
moving an existing VM to another policy means recreating it.

## Policyfiles vs roles

CINC uses **policyfiles**, not the old Chef roles model:

| | Roles (old) | Policyfiles (this platform) |
|---|---|---|
| Composition | Multiple roles per node | **One policyfile per node** |
| Versioning | Mutable, no lockfile | Immutable lockfile (`*.lock.json`) |
| Reproducibility | Resolved at run time, per node | An immutable lockfile pins every cookbook version, so staging and production run the same bytes |

**One policyfile per VM.** You cannot assign multiple policyfiles to a single
node — this is by design. A policyfile defines the complete run_list and pins
all cookbook versions (like `package-lock.json`). Creating another one, for GPU
workloads or an ML pipeline, is *Adding a recipe or a policy* above.

Published with this cookbook:

| Policy | Run list | Use case |
|--------|----------|----------|
| `dev-vm` | `base::default` (SSH, firewall, sysctl, Docker, GPU auto-detect, credential broker, Falco, Alloy when `base.loki.enabled`) | General developer VM |

## Policy assignment

VMs read their `PolicyName` EC2 tag at boot (via IMDSv2) and set it in `/etc/cinc/client.rb`.
To change a VM's role, update `policy_name` in `vms/instances.auto.tfvars`, apply Terraform, and re-bootstrap (or edit `client.rb` directly and run `cinc-client`).

The policy **group** travels the same way, via the `PolicyGroup` tag. It
defaults to `production`, so an ordinary VM needs nothing set. The staging VM
that `make push` is pushed *for* is made by setting `policy_group = "staging"`
on that VM's entry before it is created — the tag is read once, at first boot,
so switching an existing VM between groups means recreating it. An unknown
value falls back to `production` rather than producing a VM that silently never
converges; `terraform test` covers the plausible typo.
