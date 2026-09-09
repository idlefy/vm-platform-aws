# Changelog

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
