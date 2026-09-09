# Security policy

Report a vulnerability privately to **security@idlefy.com**. Do not open a
public issue or pull request for one — the fix ships as a tag that tenants
adopt on their own schedule, so a public report is live against every deployment
until each of them promotes.

Include what you did, what happened, and what you expected. A reproduction on a
VM converged from this cookbook is worth more than an argument from the source,
because most of what is interesting here fails silently: the shape this platform
keeps hitting is a command that exits 0 while the control it was supposed to
apply is not in effect.

There is no bug bounty. We will acknowledge your report, tell you whether we
consider it in scope and why, and credit you in the release notes if you want
that.

## Supported versions

The most recent `base-X.Y.Z` and `vX.Y.Z` tags. Older tags are not patched —
a tenant moves by bumping its pin, which is one command per stream.

## In scope

The three subsystems below are where a defect is a security defect rather than a
bug, and each has a design record that says what it is trying to guarantee:

- **The IAM permissions boundary** on each VM's identity role — the deny list,
  the actions a bundle can widen, and any path around it. Note the shape of
  failure this list has had three times: a deny entry that names one API while
  another route reaches the same asset (`StopInstances` → `DetachVolume` →
  `AttachVolume` reaches a root volume without ever touching the snapshot APIs
  the list blocks, and needs no `iam:PassRole`). Design record:
  [per-VM AWS access](docs/design/per-vm-aws-access.md).
- **The credential broker** — `/dev/shm/dev-vm-aws`, its `0750` directory and
  `0640` file, the uid gate, and the re-verification of owner and mode on every
  run. `/dev/shm` is world-writable, so anything that lets the developer
  substitute what root published is in scope. Same design record.
- **The sudo audit pipeline** — the journald path, Alloy's rate limiter and the
  `stage.match` that routes audit lines around it, and the Falco rule that is the
  authoritative escalation detector. A way to make a real escalation attempt
  produce no line in Loki is in scope. Design records:
  [sudo audit alerting](docs/design/sudo-audit-alerting.md),
  [log shipping](docs/design/log-shipping.md).

Also in scope: anything that lets a developer read or stop the log shipper,
reach IMDS as a non-root user, or obtain credentials belonging to a principal
the VM's boundary does not constrain.

## Out of scope

- **Known and documented gaps.** The design records and `CLAUDE.md` name several
  deliberately: no alert fires when a VM stops shipping (Idlefy stops these VMs
  overnight, so silence is normal); no journald field authenticates a sudo event,
  which is why the journal alerts are tripwires and Falco is the detector; the
  Falco rule watches `sudo` and not `su`, `pkexec` or `newgrp`; nothing detects a
  *read* of the broker's credential file, because malware inside the developer's
  own tooling shares its uid, authority and tty. A report that re-derives one of
  these is welcome as an issue, but it is not a vulnerability report.
- **A tenant's own configuration.** Wrong values in `tenant.auto.tfvars` or the
  policyfile, a leaked Grafana token, an over-broad access bundle: that is the
  tenant's account, not this template. If the template *makes* the mistake easy
  or silent, that part is in scope and worth reporting.
- **Vulnerabilities in upstream packages** — Falco, Alloy, Docker, Traefik,
  Tailscale, CINC. Report those upstream. What is in scope here is our pinning:
  a pin held past a fixed release, or a package we allow to auto-upgrade that
  should not.
- Anything requiring `admin` or `root` on the VM to begin with. `admin` has full
  `NOPASSWD` sudo by design.
