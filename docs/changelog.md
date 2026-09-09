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
  directory carried gid 0.

(The `v1.1.0` entries are added by PR B.)

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
