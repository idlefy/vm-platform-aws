# Changelog

## 2.2.1

Fixes from the first builds of Idlefy's hardened image: two Actions runs and
one image built by hand from the same user data. The image's build changes;
the cookbook does not. No base release: the image still converges
`base-2.2.0`. Nothing here touches a tenant fleet or its image. Design record:
[Hardened image for AI agents](design/hardened-image.md).

**`v2.2.1`**

- `bootstrap-solo` runs `apt-get update --error-on=any` before the converge.
  A stock image ships no apt lists, so the first package had no candidate
  version and the bootstrap failed. A list that fails to download fails the
  bootstrap there, with the banner, instead of a warning.
- The solo scrub purges snapd. The hand-built image carried the build
  instance's snapd device key and serial, which every box from a public
  image would have shared. The amazon-ssm-agent snap is now checked before
  the purge. A purge's leftovers (`/var/lib/snapd`, `/snap`, `/var/snap`,
  `/var/cache/snapd`, `/root/snap`, `/home/*/snap`) are removed. The image is
  refused unless snapd, any SSM agent package and every snap or snapd unit
  are gone, including user units, `/usr/bin/snap` and `/usr/lib/snapd/snapd`.
  A `dpkg-query` that cannot answer refuses too. `apt-get clean` drops the
  package cache (321 MB); the apt lists stay. To use a snap, the admin
  installs snapd.
- The solo scrub zero-fills the free space of `/` as its last step, after
  every removal and after `cloud-init clean`: freed blocks of a public
  snapshot are readable, and EBS root volumes accept no discard, so a trim
  frees nothing (measured). The image is refused unless the fill ended on a
  full filesystem and its file is gone. This costs about two minutes of
  build time and roughly 16 GB more snapshot storage per region. The fleet
  scrub is unchanged; its `fstrim` has always been a no-op on EBS.
- The build driver reads the build instance's serial console while Packer
  runs. On the bootstrap's `BOOTSTRAP FAILED` banner or a scrub refusal, as a
  whole line, it prints the console's tail and interrupts Packer, so the
  instance and its key pair are removed. The build then fails with the
  reason, whatever Packer reports. Before this, a build that failed in 28 s
  waited out Packer's 2-hour budget. A console read error is noted, never
  fatal. The watcher never outlives the driver. Packer runs in a process
  group of its own and is interrupted as a group: Packer 1.11.2's panicwrap
  wrapper drops a SIGINT sent to it alone. On INT, TERM or a failure the
  driver passes SIGINT to that group and waits for Packer's clean-up before
  it lists leftovers. A cancel no longer breaks the pipe Packer logs to.
- The publish workflow's `build` step times out at 210 minutes, leaving the
  `leftovers` and `record` steps at least 15 of the job's 240.
- The solo scrub's unit check also covers `/usr/local/lib/systemd/{system,user}`
  and every account's `~/.config/systemd/user` (`/root` and each home found
  under `/home`).
- `scripts/hardened-image-leftovers.sh` also lists the build instance and
  Packer's `packer_*` key pair, and `--clean-build` removes exactly those.
  It refuses unless the credentials are the publisher account's. The
  publish workflow's `leftovers` step runs it after a failed, cancelled or
  timed-out build, with or without an image name, and says so instead when
  the run never got AWS credentials. An Actions cancel had left both
  running. Images are still only listed.
- Measured: for Canonical's source image the IAM condition key `ec2:Owner` is
  the alias `amazon`, not the account id. The publisher role's condition
  (outside this repository) was fixed to match.

## 2.2.0

A second published policy, `solo`: one developer's box with an AI agent
working as `ubuntu`, no fleet behind it — the run list for Idlefy's public
image. Its inclusion rule is that nothing on the box takes instructions from
Idlefy after launch, so it has no policy fetch, no credential broker, no
Traefik, no Falco, no Alloy and no SSM agent. `v2.2.0` builds that image and
publishes it from Idlefy's account; design record:
[Hardened image for AI agents](design/hardened-image.md).

**`base-2.2.0`**

- `policyfiles/solo.rb` and `base::solo`: `base::default` without
  `cinc_client`, `aws_access`, `traefik`, `falco`, `alloy` and
  `nvidia_docker`, plus `hardened_firstboot`, `share_helper` and
  `no_ssm_agent`. The Policyfile sets `base.loki.enabled = false`,
  `base.share_helper.enabled = true` and, as an `override`,
  `base.firewall.public_web_ports = []`. An `override` because Chef unions
  arrays across every default level: a Policyfile `default` of `[]` merged with
  the cookbook's `[80, 443]` is still `[80, 443]` (measured, chef 19.3.14;
  `spec/recipes/solo_spec.rb` keeps the case). It is converged once, during the
  image build, and by no tenant fleet.
- `base::hardened_firstboot`: cloud-init recreates the default user on every
  new instance from an image, sudo rule included, and a solo box has no later
  converge to take it away again. `/etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg`
  makes that user sudo-less at the source with `sudo: null` (not `false`: on
  Noble's cloud-init `false` is deprecated and leaves `cloud-init status`
  degraded), and the `idlefy-hardened-firstboot.service` oneshot, after
  cloud-init and before SSH, removes the cloud-init sudoers fragments and the
  `sudo`/`admin`/`adm`/`lxd` groups from `ubuntu` on every boot.
- `base::share_helper` installs `/usr/local/sbin/idlefy-share`, which publishes
  one `127.0.0.1` port through Tailscale Funnel or turns the share off. A share
  is published only after the previous one was reset; a failed reset publishes
  nothing and exits non-zero. See
  "idlefy-share" in `cinc/README.md`. The grant,
  `/etc/sudoers.d/51-idlefy-share`, is written by `base::sudoers` only when
  `base.share_helper.enabled` is true, and the attribute defaults to `false`.
  Leave it off on any policy that runs `base::falco`: the grant without a
  matching Falco exclusion pages on every legitimate share (the same coupling as
  AGENTS.md trap 7).
- `base::no_ssm_agent` removes the `amazon-ssm-agent` snap Canonical's AMIs
  ship, after waiting (at most 600 s) for snapd to finish seeding. A failed
  wait or a failed `snap list` fails the converge rather than skipping the
  removal, and a snap still listed after the removal fails it too. `solo` only.
- `base.firewall.public_web_ports` (default `[80, 443]`, what the fleet has
  always opened) names the ports opened to the world beyond SSH.
- **Fleet-visible:** `base::firewall` and `base::imds` now do on IPv6 what they
  did on IPv4. A VM that converges this release gains an ip6tables INPUT `DROP`
  policy with the same accepts as v4 (plus ICMPv6 and DHCPv6 replies), and
  `fd00:ec2::254`, IMDS over IPv6, becomes reachable only by root and the
  Instance Connect uid, as `169.254.169.254` already was. Rules are saved to
  `/etc/iptables/rules.v6`. The v6 default policies are set after every v6
  accept, so a converge that fails midway cannot leave v6 at `DROP` without
  them. Every v6 accept is guarded by `ip6tables -C` with its own arguments,
  and the v6 policy guards match the whole `-P` line.
- **Fleet-visible:** the SSH and `public_web_ports` guards, v4 and v6, are
  `-C INPUT -p tcp --dport N -j ACCEPT`: only that exact rule satisfies them.
  The old `dport 22.*ACCEPT` was satisfied by a rule for 2222 (and 80 by
  8080), and a substring match by a UDP or source-restricted rule for the same
  port, each silently skipping the real one. Rules the old guards created are
  that exact rule, so a converged VM adds nothing. Removing a port from
  `public_web_ports` does not close it on a converged VM.
- **Fleet-visible:** `base::imds` guards, v4 and v6, are `-C OUTPUT` checks of
  their own rule, so the same text in another chain or table no longer skips
  the OUTPUT rule. The DROP goes in right after the last owner-allow present:
  `-I OUTPUT 3` on a normal host, as before; on a host without the Instance
  Connect user, where a fixed 3 failed with "Index of insertion too big" and
  aborted the converge before the DROP, it now lands after the root allow.
- New gate: `make test-share-helper` (stubs `tailscale`; no tailnet needed),
  part of the `base` stream.

**`v2.2.0`**

- The solo bootstrap and scrub profile: `image/files/bootstrap-solo`
  converges `base::solo` once in local mode, with its state on tmpfs, and
  `dev-vm-image-scrub --profile solo` sources the new
  `image/files/dev-vm-image-scrub-solo`, which purges CINC, swaps in the solo
  lists (`test/fixtures/image-scrub-paths-solo`) and refuses the image — exit
  70, no power-off — unless every baked invariant holds on disk. The fleet
  profile is unchanged.
- `image/hardened/`: the Packer template of Idlefy's public image
  `idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN` — unencrypted, no
  instance profile, a fixed security group, never connecting — and
  `regions`, the 17 default-enabled regions it is copied to.
- `scripts/hardened-image-build.sh`, the build driver: checks the account and
  the tag — and that the checkout is exactly the tag, with no modified,
  staged or untracked build input — stores the solo policy archive once as a
  release asset and pins its sha256 in the user data, builds, and writes the
  release record. The image's `Description` and the record say
  `visibility=public` or `visibility=private`.
- `scripts/hardened-guard-check.sh`: refuses to publish unless the account is
  still safe to publish from (encryption by default off, public sharing
  unblocked for a public build, SSM Default Host Management unset, quota
  room, every principal but the publisher and service-linked roles
  explicitly denied any change to a published image by the fence policy
  itself, in every region, and no unencrypted snapshot or image outside the
  published ones). A failing principal is reported in one line, with a hint
  to apply the account's Terraform. A quota read that fails for any reason
  but "no applied value" fails the guard.
- `scripts/hardened-image-leftovers.sh` lists, read-only, any image of a
  build's name in every listed region. The driver runs it when a build fails
  or is signalled after `packer build` started, and the publish workflow runs
  it after a failed, cancelled or timed-out build. The driver takes NN from
  every listed region. The solo scrub checks `rules.v4` as it checks
  `rules.v6`, and allows ahead of either metadata drop only root's and
  Instance Connect's owner allows (an allowlist).
- `scripts/hardened-image-retire.sh`: keeps the newest two public builds,
  deprecates and deregisters older ones on a 7-day cadence, never
  deregisters one of the two newest ever published (read from the image's
  `Description`; a private build is retired by its own age), yanks one build
  with `--disable`, and is a dry run unless `--apply`. It leaves a region
  alone on anything it cannot read, and retries a snapshot still in use.
- Two workflows: `publish-hardened-image` (dispatched on a `vX.Y.Z` tag, or
  monthly on the newest one) and `retire-hardened-image` (dispatch only),
  both behind the protected environment `hardened-publish`, with no token
  permission at workflow level and only what each job needs.
- Hardened image builds are recorded on each GitHub release as
  `hardened-ami-<date>-<nn>.json` and in the release notes.
- New gates in the `v` stream: `test-hardened-template`,
  `test-hardened-build`, `test-hardened-guard`, `test-hardened-retire`.

## 2.1.0

A fleet can boot from a prebuilt image: the first converge is done once, ahead
of time. Measured on `c7a.large`, a new VM's first converge updated 19
resources in 1m12s instead of 161 in 2m09s, and its boot finished in 2m17s
instead of 3m19s. Nothing about what a VM trusts
changes; it still verifies and converges its group's signed envelope. Design:
`docs/design/ami-image.md`. No base release.

**`v2.1.0`**

- The ec2 module exposes the rendered first-boot script as the
  `bootstrap_user_data` output, and that script is idempotent, so a booted
  image can run it again.
- The permissions boundary denies every route to the fleet's images (create,
  register, copy, share, deregister, and the disable, deprecate and
  recycle-bin routes) as families, not as single calls. That includes Image
  Builder, which registers AMIs through its own role: a bundle that names
  `imagebuilder` keeps its reads and loses `Create*`, `Update*`, `Start*`,
  `Import*` and `Put*`.
- `image/` holds the Packer template and the scrub, read from the pinned
  checkout.
- `make ami` builds the image from the promoted production revision and copies
  it to every configured region.
- `tenant-skeleton/IMAGE.md` is the guide an agent follows to build or refresh
  the image.
- `make preflight` checks the image's age when `ami_owners` names `self`: a
  warning past 35 days, a failure for a region with no matching image.
- To adopt it: run `terraform apply` once on `v2.1.0` (it adds an output),
  then `make ami`.

## 2.0.1

The agent guide is now `AGENTS.md`, which Claude Code and Codex both read. The
two skills are now plain guides in the repository root: `GET-STARTED.md` in
this repository and `SETUP.md` in a generated tenant. No behaviour changes.

**`base-2.0.1`**

- Comments only. The version moves anyway, because a tenant reads it out of
  its lock.

**`v2.0.1`**

- `tenant-skeleton/` ships `AGENTS.md` and `SETUP.md` in place of `CLAUDE.md`
  and `.claude/skills/tenant-setup/`.
- An existing tenant keeps working as it is. To adopt the change, rename its
  `CLAUDE.md` to `AGENTS.md`.

## 2.0.0

There is no CINC server any more. Policy reaches VMs as signed archives in an
S3 bucket the tenant owns. Design and threat model:
`docs/design/serverless-policy-delivery.md`. 1.x is frozen: a VM built for a
server stays on `base-1.x`, and moving a tenant means recreating its VMs.

**`base-2.0.0`**

- `base::cinc_client` keeps `dev-vm-policy-fetch` current, self-testing each
  new version against a shipped fixture before it replaces the old one. It
  writes `/etc/dev-vm/policy-signers` from `base.policy.signers` and refuses a
  set that drops the key that signed the running revision.
- `cinc-client.service` runs the launcher, which fetches the group's signed
  envelope, verifies it, checks the archive hash, and runs `cinc-client -z`.
  It refuses to converge a VM without `/etc/dev-vm/policy.conf`, so a 1.x VM
  is never half-migrated.

**`v2.0.0`**

- Breaking: `cinc_server_url` and `cinc_ssm_parameter_name` are removed;
  `policy_bucket`, `policy_bucket_owner`, `policy_bucket_region`,
  `policy_prefix`, `policy_kms_key_arn`, `policy_signers` and
  `policy_min_serial` are new. A bundle that names an infrastructure namespace
  needs `infrastructure_access = true`.
- The bootstrap writes the policy settings and the trusted signers and runs
  the first converge from the bucket. It fails closed on any `PolicyGroup`
  other than `staging` or `production`.
- The permissions boundary denies writes anywhere in the policy bucket,
  changes to the bucket and its key, and the routes that redirect where S3's
  name resolves or where traffic leaves the VPC.
- `make push` / `make promote` sign and publish through
  `scripts/policy-publish.sh`. It never signs an archive whose contents differ
  from a fresh export of the lock. `make preflight` checks the bucket and both
  envelopes. `make node-delete` and both `infra/` trees are gone.

## 1.2.1

**`base-1.2.1`**

- werf was installed but invisible to the shells that automate it.
  `werf.io/install.sh` appends its `trdl use werf` activation to `~/.zshrc`
  and `~/.zprofile`, which zsh reads only for interactive and login shells, so
  a non-interactive `zsh -c 'werf ...'` — an ssh command, a CI step, an
  agent's shell tool — resolved nothing. Measured on a staging VM
  2026-09-18: `zsh -c 'whence -p werf'` printed nothing while an interactive
  shell resolved werf to `~/.trdl/repositories/werf/releases/2.76.0/...`.
- Fixed the way this cookbook already fixes this class of problem (see
  `base::docker`, `base::aws_access`): `base::werf` writes a root-owned
  `/etc/dev-vm/werf-env.sh` and `/etc/profile.d/dev-vm-werf.sh`, and
  `base::shell_default` sources it from `/etc/zsh/zshenv`. Not `~/.zshenv` —
  root cannot write there, the copy would have to be create-once (so a
  developer with an existing file never gets the fix, and a deleted one is
  never restored), and measured on the same VM `zsh -f -c` skips `~/.zshenv`
  while still running `/etc/zsh/zshenv`.
- `spec/recipes/shell_default_spec.rb` is new and fails an `/etc/dev-vm`
  drop-in that no line in `/etc/zsh/zshenv` reaches — a failure that is
  otherwise silent.

## 1.2.0

**`base-1.2.0`**

- `base::codex` installs the Codex CLI for `ubuntu` via the official installer,
  the same per-user shape as `base::claude_code`.
- The same recipe installs `bubblewrap` and loads Ubuntu's
  `bwrap-userns-restrict` AppArmor profile, which ships unloaded in
  `apparmor-profiles` on 24.04. Both halves are one change: Codex takes the
  first `bwrap` on `PATH` and falls back to a copy it bundles under `~/.codex`,
  and that copy sits at a path no profile attaches to — so under
  `kernel.apparmor_restrict_unprivileged_userns=1` it cannot create a user
  namespace and Codex runs unsandboxed after one warning. Ubuntu ships that
  profile disabled — `d/apparmor.maintscript` even `rm_conffile`s it out of
  `/etc/apparmor.d` — after enabling it by default once broke Flatpak file
  saving (LP: #2072811), so loading it is the supported way to turn it on.
  It is permissive towards `bwrap` itself; what it buys is the stack into
  `unpriv_bwrap`, which carries `audit deny capability`, so bwrap cannot
  become a general-purpose way around the restriction. The sysctl is left
  at 1.

## 1.1.1

Live verification of the first external review (`docs/design/first-external-review.md`, *Measured*).

**`base-1.1.1`**

- The Falco sudo exclusion compares `proc.args`, not `proc.cmdline`: a symlink
  named `sudo tailscale` gave the excluded cmdline while asking sudo for `login`,
  and the tripwire stayed quiet on a command sudoers refused.
- `falco` joins Alloy's audit bypass. Before: every Falco detection on a VM
  shared one `unit` rate-limit bucket with the sudo detection, and a
  developer-driven flood dropped 1098 of 1301 lines from it. After: Falco
  entries skip `stage.limit` entirely, the same flood reached `loki.write`
  with zero drops.

## 1.1.0

Fixes from the first external review (`docs/design/first-external-review.md`).

**`base-1.1.0`**

- Root never writes under `/home/ubuntu`: files the cookbook places in the
  developer's home are staged under `/usr/share/dev-vm/home/` and copied as
  `ubuntu`; the Traefik password is generated as `ubuntu`. A ChefSpec converge
  of the whole run list enforces it.
- The credential broker refuses to source an environment file that is a
  symlink, owned by another uid, or writable beyond its owner.
- `execute[install-werf]` now runs as `ubuntu:ubuntu`; it ran as `ubuntu:root`
  because the group was never set, so everything trdl created under the home
  directory carried gid 0. `execute[install-claude-code]` had the same
  `ubuntu:root` bug — it installs into `~/.local/bin` — fixed in the same
  release.

**`v1.1.0`**

- A failed bootstrap fails closed: cloud-init's `NOPASSWD` grant is never
  restored; the log goes to the serial console, recovered with
  `aws ec2 get-console-output --latest` and replaced with
  `terraform apply -replace=`. The bootstrap runs once, so re-pinning reaches
  new instances only; a VM that already failed under 1.0.0 keeps its restored
  grant until it is replaced.
- The permissions boundary denies the EBS direct API, fleet network mutation
  (NACL entries, routes, security-group egress, `RevokeSecurityGroupIngress`,
  `ModifyNetworkInterfaceAttribute`), `TerminateInstances`/`RebootInstances`,
  and console output.
- `preflight` passes only on an HTTP `400` from Loki; `pin-check` checks
  `module "ec2"` and `module "fleet_guards"` each by name against an exactly
  anchored SHA; `make release` fetches the upstream before its reachability
  check and re-checks the tag after the fetch.
- Runbook: keys and tokens are created `0600` before they are written and never
  pass through a command line; the shipping-off procedure re-locks and edits
  both halves before promoting; a GNU userland is a stated prerequisite.

## 1.0.0

First public release. Both streams start here: `v1.0.0` (modules and
tenant skeleton) and `base-1.0.0` (cookbook).

- Hardened Ubuntu 24.04 developer VMs: firewall, `sshd` + fail2ban, IMDS
  block, rootless Docker, unattended upgrades, Falco, `sudo` audit path.
- Per-VM IAM identity with a permissions boundary derived from access
  bundles, and a root-owned credential broker in tmpfs.
- Journal shipping to Grafana Cloud Loki with a checked-in dashboard and
  six alert rules; `log_shipping = false` turns the whole path off.
- `idlefy_managed` tags every instance `idlefy = "enabled"` for Idlefy.
- `tenant-skeleton/` with `make prepare`, `pin-check`, `preflight`,
  `add-region`, and the `tenant-setup` skill; a `get-started` skill in this
  repository creates the tenant.
