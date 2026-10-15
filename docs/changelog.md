# Changelog

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
- The permissions boundary denies writes to the policy prefix, changes to the
  bucket and its key, and the routes that redirect where S3's name resolves or
  where traffic leaves the VPC.
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
