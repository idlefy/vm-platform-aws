# Changelog

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
  `terraform apply -replace=`.
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
