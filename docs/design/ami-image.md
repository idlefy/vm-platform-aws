# Prebuilt image — a tenant-built AMI that caches one converge

> Design record, written before implementation and revised after an
> architecture review the same day. *Measured* at the end records the live
> builds that checked it, in the test account, before release.

**Date:** 2026-10-16
**Status:** implemented and measured on live builds (2026-10-16)
**Ships as:** `v2.1.0`. The `CLAUDE.md` → `AGENTS.md` change (decision 11)
ships first, in its own PR, as `base-2.0.1` + `v2.0.1`, because it touches
cookbook files.

## The request

A VM built from the stock Ubuntu image spends its first boot installing
everything the cookbook asks for: CINC, Docker, Falco, Alloy, Node, Claude
Code, Codex, Tailscale and the rest. Tenants want a VM that is usable minutes
sooner, and an image they can inspect before a fleet runs it.

The image is built **by the tenant, in the tenant's account, from the tenant's
own signed production revision**. A shared, platform-built image was considered
and rejected: it would carry the platform's revision instead of the tenant's,
and it is the first step towards a Marketplace listing, which is a separate
piece of work (a CloudFormation product).

## Decisions

1. **The image makes the first converge faster. It does not decide policy, but
   it is not neutral either.** A VM from the image boots the way a VM from
   stock Ubuntu does: `user_data` writes its own `policy.conf` and signers,
   fetches its group's envelope, verifies it and converges. The signature
   check, the serial floor and the signers twins are unchanged. But a converge
   is additive. A package, a sudoers fragment or a unit that the build's
   revision installed and a later revision no longer declares stays on every
   VM built from that image. So what the image was built from matters, and two
   rules follow from it:
   - **Images are built only from `production.json`.** `ami_name_pattern` is
     module-wide while the policy group is per VM, so one image feeds both
     groups. A staging build would put unpromoted content on production VMs.
     A staging VM booted from a production image converges staging on top,
     which is the same path every staging VM takes after a promote.
   - **The image records its revision** in the `RevisionId` tag and in
     `/etc/dev-vm/image-revision`, so a leftover can be traced back to the
     revision that left it.
2. **The build converges through the same path a VM uses.** The build instance
   runs the module's own bootstrap script, unchanged. It therefore runs
   `dev-vm-policy-fetch` with its signature check, so an image cannot carry an
   unsigned or unpromoted revision.
3. **Packer does not render the bootstrap. Terraform does.** The plain script
   is already over EC2's 16 KB user-data limit (`user_data.tf:4-8`, which is
   why `main.tf` ships it with `base64gzip`), and Packer has no gzip function.
   The module gains an output, `bootstrap_user_data`: the plain script, exactly
   as `local.user_data_script` renders it. The skeleton passes it through as a
   root output. `make ami` reads that output, appends the scrub call, gzips the
   result and hands Packer the file through `user_data_file`. There is one
   renderer, and the script stays in its heredoc.
4. **The scrub is the last line of the same script, not a second cloud-init
   part.** Cloud-init runs every script part even when an earlier one fails, so
   a two-part document would scrub and snapshot a failed build. In one
   `set -euo pipefail` script, the bootstrap's own failure paths
   (`bootstrap_failed; exit 1`, the ERR trap) mean the scrub line is reached
   only after a green first converge. As a second check, the scrub refuses to
   run unless `$STATE/status` reports success for the expected revision. A
   build that never reaches the scrub never powers off, and Packer times out
   without registering an AMI.
5. **No credential that outlives the build is ever written to its disk.** The
   build's temporary instance profile can only read the policy bucket, plus
   `kms:Decrypt` when `policy_kms_key_arn` is set (`iam.tf:113-117`). It
   cannot reach SSM. `dev-vm-loki-token` exits 10, which the converge accepts
   (`returns [0, 10]`, `alloy.rb:304`). The credential broker finds no access
   parameter, and its start is `ignore_failure`. The build does write secrets
   that are valid only on the build instance: SSH host keys, and Traefik's
   basic-auth password (`traefik.rb:121-137`). The scrub deletes them, and
   every VM generates its own. Their freed blocks may survive into the
   snapshot. That is acceptable only because those secrets authenticate
   nothing after the build is terminated, and this rule is what makes it so.
6. **The scrub list is measured, not written from memory.** Before the scrub
   is implemented, a stock VM is converged once. A `find / -xdev` taken before
   and after that converge, filtered to what differs per instance, becomes the
   list. The scrub's test is driven by that list, which is checked into
   `test/fixtures/image-scrub-paths`.
7. **Units that act on boot are disabled in the image and re-enabled by the
   first converge.** `cinc-client.timer` (`cinc_client.rb:127`),
   `aws-vm-credentials.timer` (`aws_access.rb:174`, `OnBootSec=30s`) and
   `alloy` (`alloy.rb:346`) are all declared `[:enable, :start]`. On a new VM
   they would otherwise start before cloud-init has written `policy.conf`. The
   policy timer would exit 70 and fire the `for: 0s` converge alert on every
   first boot. The broker would query the build's SSM key, and Alloy would ship
   under the build's name. The converge enables them again, so nothing in the
   cookbook changes.
8. **Packer does not connect to the build instance.** `communicator = "none"`
   and `disable_stop_instance = true`: Packer launches the instance, waits for
   it to stop on its own, and snapshots it. The scrub's last step is
   `poweroff`. `aws_polling` is set explicitly, because a full converge outlasts
   the default wait. An SSH communicator would not work anyway: `base::sudoers`
   takes away `ubuntu`'s sudo partway through the converge, and `base::ssh`
   restarts sshd.
9. **Every region of the fleet gets the image.** `ami_owners = ["self"]` finds
   nothing in a region the AMI was never copied to, and `data.aws_ami.latest`
   then fails the plan. `make ami` passes every region in `local.regions` to
   Packer's `ami_regions`.
10. **The bootstrap becomes idempotent where the image changes its starting
    state.**
    - CINC is downloaded only when `dpkg-query -W -f='${Version}' cinc` is not
      `${CINC_VERSION}-1`. The AWS CLI is already skipped when present.
    - The three IMDS `iptables -A` rules become `iptables -C … || iptables -A
      …`. `imds.rb` persists them to `/etc/iptables/rules.v4`, so a VM from the
      image boots with them already in place.

    On stock Ubuntu nothing changes.
11. **Agent instructions are one file per repository, and skills are plain
    files in the root.** `CLAUDE.md` becomes `AGENTS.md` in this repository and
    in `tenant-skeleton/`, with the text unchanged. Claude Code reads
    `AGENTS.md` when there is no `CLAUDE.md` (code.claude.com/docs/en/memory),
    and Codex reads it natively. The skills move out of `.claude/skills/`:
    - `get-started` becomes `GET-STARTED.md` here;
    - `tenant-setup` becomes `SETUP.md` in the skeleton;
    - the new image wizard is `IMAGE.md` in the skeleton.

    Each `AGENTS.md` names its files, one line each ("when X, read Y"). Every
    reference moves too. 35 files name `CLAUDE.md` or `.claude/skills`, among
    them five cookbook files, three scripts with skeleton twins, `ci.yml`,
    `.coderabbit.yaml` and tests. The cookbook files make this a `base-`
    release, so it ships first, in its own PR.

## Components

### Platform: `image/`

`image/dev-vm.pkr.hcl` is part of the `vX.Y.Z` stream. `terraform init` places
this whole repository, at the pinned SHA, in the tenant's
`vms/.terraform/modules/ec2/`, so the tenant runs Packer from there. There is
no copy and nothing to drift.

Inputs, all supplied by `make ami`:

| Variable | Source |
|---|---|
| `user_data_file` | the gzipped bootstrap + scrub call, built by `make ami` |
| `build_region` | `var.policy_bucket_region` |
| `ami_regions` | every key of `local.regions` |
| `policy_bucket`, `policy_prefix`, `policy_kms_key_arn` | `var.policy_*` (for the temporary profile only) |
| `policy_name` | the operator's choice; default `dev-vm` |
| `revision_id` | the `production ok` line of `scripts/policy-publish.sh show <policyfile>`, which verifies the envelope |
| `subnet_id` | optional; empty means the default VPC |
| `platform_sha`, `cookbook_version` | `local.platform_pin.sha`; the lock |

Source: `amazon-ebs`, with `source_ami_filter` on the module's default owner
and name pattern (Canonical, noble).

- Run tags: `Name = dev-vm-image-build`, `PolicyName`,
  `PolicyGroup = production`.
- Metadata options: `instance_metadata_tags = "enabled"` and
  `http_tokens = "required"`.
- The temporary instance profile allows `s3:GetObject` on
  `<bucket>/<prefix>/*`, plus `kms:Decrypt` when a key is set.

AMI name: `dev-vm-<policy>-<timestamp>`. Tags: `PolicyName`, `RevisionId`,
`PlatformSha`, `CookbookVersion`, `BuiltBy = packer`.

The `RevisionId` tag is read before the build, so a `promote` that lands
during the build could make it lie. The scrub catches that: it compares
`$STATE/status` with the expected revision, refuses on a mismatch, and the
build times out.

`image/files/dev-vm-image-scrub` runs as root, as the last line of the build's
user data:

1. Asserts that `$STATE/status` reports success for the expected revision.
2. Writes `/etc/dev-vm/image-revision`.
3. Stops `cinc-client.timer` and `aws-vm-credentials.timer`, then the
   services they start, then disables both timers and `alloy`. The order
   matters: the bootstrap's converge starts `cinc-client.timer`, which is past
   its `OnBootSec` by then and queues a second converge behind the lock (see
   *Measured*, item 3). A unit the policy never installed is skipped
   (`log_shipping = false` purges Alloy). If `last-serial` moved while that
   converge ran, it fetched a newer envelope, and the scrub refuses.
4. Stops the services that write state: `user@1000.service` (Docker and
   Traefik are rootless user units), the root daemons, `syslog.socket` before
   `rsyslog`, and `systemd-update-utmp` and `systemd-random-seed`, which write
   on stop. Moves journald to `/run` with `journalctl --relinquish-var`.
5. Removes the measured list.
6. Refuses, with no poweroff, if any of the three units is enabled again.
   Every refusal, and any unexpected failure, is written to the serial
   console, the one place a terminated build's operator can read.
7. Runs `cloud-init clean --logs --machine-id`.
8. Runs `poweroff`.

`DEV_VM_IMAGE_ROOT` points the script at a fake root for its test.

### Scrub list

The list is `test/fixtures/image-scrub-paths`, measured as decision 6 says
(*Measured*, item 1), one line per path with its reason. The script carries
its `remove` and `empty` lines verbatim and the test fails if they drift. In
short, it removes:

- per-instance identity: host keys, the SSM agent's registration, Docker,
  containerd, buildkit and Claude Code ids, Alloy's seed, the RNG seed, the
  DHCP lease, pollinate's marker;
- the build's keys and secrets: Packer's `authorized_keys`, the Traefik
  password, `users` and `acme.json`, any Loki token, AWS CLI and gpg state,
  Tailscale state;
- policy delivery state: `policy.conf`, `policy-signers`, `aws-access.env`
  and `$STATE/{lock,last-serial,previous-revision,delivery-failures,status}`,
  and Alloy's journal positions;
- logs and scratch: the journal, `/var/log` (removed or truncated), `/tmp`
  and `/var/tmp`.

It empties `/etc/machine-id`; `cloud-init clean --machine-id` then writes
`uninitialized` into it, which is systemd's first-boot marker.

Kept:

- `$STATE/archives` and `$STATE/revisions`. Every fetch re-verifies the
  archive's hash against the envelope.
- `/usr/share/dev-vm/home` and the rootless Docker state, including the `web`
  network. Neither identifies the instance.
- `/etc/iptables/rules.v4` (decision 10).

Rewritten by the first converge on each VM, after the bootstrap:
`/etc/alloy/config.alloy`, `/etc/hostname`, `/etc/hosts` and the Traefik
readme.

### Tenant side

`make ami [POLICY=dev-vm]`:

1. Runs `pin-check`.
2. Reads `bootstrap_user_data` and the inputs with `terraform output` and
   `terraform console`. The tenant must have applied `v2.1.0` once, so that
   the output exists in state.
3. Reads the production revision through `policy-publish.sh show`.
4. Runs `packer init` and `packer build`.
5. Prints the AMI id for each region.

`IMAGE.md` is the wizard. It covers:

- prerequisites: Packer installed, a VPC with egress, a promoted envelope, and
  the operator's IAM rights for Packer's temporary role, profile, security
  group and key pair;
- the first build;
- checking the AMI tags against the lock;
- switching `ami_owners = ["self"]` and `ami_name_pattern = "dev-vm-<policy>-2*"`;
- a test VM;
- when to rebuild: after each promote of a new cookbook release, and at least
  monthly for OS updates;
- deregistering old AMIs and their snapshots in every region.

`IMAGE.md` never runs `terraform apply`.

`make preflight` warns when the newest AMI matching `ami_name_pattern` is
older than 35 days.

## Security notes

- **The AMI and its snapshots are a new asset.** The permissions boundary
  already denies `ebs:*`, `ec2:CreateImage`, `ec2:ModifyImageAttribute` and
  `ec2:ModifySnapshotAttribute` (`iam.tf:355-370`). A boundary test will name
  the image and snapshot routes explicitly, `ec2:CopyImage` included, so a
  later edit cannot drop one quietly. AMIs stay private to the account.
- **A rogue image wins `most_recent`.** With `ami_owners = ["self"]`, a
  principal in the account that can register or copy an image matching
  `ami_name_pattern` decides what the next VM boots. A VM whose identity role
  holds an `ec2` bundle is such a principal unless the boundary denies it.
  The boundary therefore denies every route that creates or removes an image
  or its snapshot: `RegisterImage`, `CopyImage`, `ImportImage`,
  `CreateRestoreImageTask`, `DeregisterImage`, `EnableImage`,
  `ImportSnapshot` and `DeleteSnapshot`, on top of those already listed. It
  also denies the routes that change which image `most_recent` resolves to
  without creating one: `DisableImage`, `EnableImageDeprecation` (the data
  source skips deprecated images), and `RestoreImageFromRecycleBin` /
  `RestoreSnapshotFromRecycleBin`. Finally, it denies the routes that read
  one out: `CreateStoreImageTask` and `ExportImage`. Image Builder reaches
  the same images through its own service role, without `iam:PassRole`, so
  its `Create*`, `Update*`, `Start*`, `Import*` and `Put*` are denied too.
  Operators who can register images in the account are
  trusted the same way as those who can sign policy.
- **The first-boot window.** A VM from the image boots with the IMDS rules
  restored from `rules.v4`, and the cookbook's sudoers is already in place.
  Cloud-init's NOPASSWD grant is recreated on a new instance either way, and
  the bootstrap removes it first, as before. Measured (item 6): at the first
  SSH answer, sudo was already refused and IMDS already dropped on both the
  stock image and the prebuilt one. The prebuilt image does not depend on
  that ordering for IMDS: `netfilter-persistent` restores `rules.v4` before
  `sshd` starts.
- **Stale packages.** The first converge runs `unattended-upgrades` as on any
  VM. Rebuilding is what keeps that converge short, and the preflight warning
  is what keeps rebuilding from being forgotten.

## Testing

- `packer fmt -check` and `packer validate` with dummy inputs on `image/`. They
  run in CI and in the `v*` release gate. Packer is installed in the CI job.
- `test/test-image-scrub.sh`, driven by `test/fixtures/image-scrub-paths`.
- `terraform test` in `vms/modules/ec2`:
  - `bootstrap_user_data` equals `local.user_data_script`;
  - the CINC step and the IMDS rules are guarded;
  - the boundary names the image and snapshot routes.
- `test/test-skeleton-sync.sh` checks that `SETUP.md` and `IMAGE.md` exist and
  that `AGENTS.md` names them.
- `boundary-check` and the release gate list learn about `image/`. The three
  verify lists (`AGENTS.md`, README, `ci.yml`) stay in step.

## Measured

2026-10-16, on a throwaway tenant in the test account (two regions,
`eu-central-1` and `eu-north-1`), torn down afterwards. VMs were `c7a.large`
unless stated.

1. **The scrub list.** `find / -xdev` on a stock noble instance, diffed with
   the same VM after one green converge: 34,670 paths differed. Package
   payload is what the image caches. The rest, with a reason per line, is
   `test/fixtures/image-scrub-paths`.
2. **A build.** `make ami` registered an AMI in both regions, tagged with the
   revision in the lock and in `production.json`, and with the cookbook
   version from the lock. On `t3.large` the build instance spent about 10
   minutes converging (credit throttling); on `c7a.xlarge`, now the default,
   it launched at 14:14:22 and the AMI was registered at 14:18:13. The whole
   build took 17 minutes; the rest is the first snapshot and the copy to the
   second region.
3. **The scrub held — after one fix.** Each image was checked by restoring
   its snapshot to a volume and mounting it read-only on another VM.
   - The first image still had both timers enabled. The bootstrap's converge
     starts `cinc-client.timer`, already past its `OnBootSec`, so a second
     converge queues behind the lock and runs the moment it frees: it
     re-enabled both timers 13 s into the scrub. It also carried files written
     after the scrub, on the way down: the journal, `syslog`, `auth.log` and
     `kern.log` (`syslog.socket` re-activated `rsyslog`), a `wtmp` shutdown
     record and a new random seed. The scrub now stops the timers, then their
     services, then disables, and refuses to power off if any is enabled
     again. It stops the shutdown writers before removing what they wrote.
   - The second image: every `remove` path absent and every `empty` path
     empty, the three units disabled, no Loki token. What remains:
     `/etc/machine-id` holds `uninitialized` (written by `cloud-init clean`,
     systemd's first-boot marker); `/home/ubuntu/.ssh/authorized_keys` exists
     empty, recreated during shutdown by a writer not identified, and filled
     by cloud-init on the new VM; `wtmp` holds two DEAD_PROCESS records for
     the `ttyS0` and `tty1` gettys, with no user and no host.
   - The token: the raw restored device, all 20 GiB including free blocks,
     had no match for the Loki token's shape (`glc_` and 20+ base64
     characters). The same pattern matched once in `/etc/alloy/loki-token`
     on a VM from the image, as a positive control. Counts only; no value was
     printed. Reading the restored volume reads the same blocks
     `ebs:GetSnapshotBlock` would.
4. **A VM from the AMI**, launched through `ami_owners = ["self"]`: first
   converge green on its own envelope, its own `last-serial`, a Traefik
   `users` file generated on its first boot, its own hostname, its own
   journal only. `iptables -S OUTPUT` matched the stock VM's rule for rule
   (root, `ec2-instance-connect`, then DROP) with no duplicates. Timers and
   Alloy enabled, Alloy, Falco and the rootless Traefik active, the Loki token
   fetched from SSM by the VM itself. Until cloud-init sets the hostname, the
   first ~20 s of its journal carry the build's name, `dev-vm-image-build`.
5. **Speed**, same size, same revision:

   | | stock | image |
   |---|---|---|
   | first converge | 161/228 resources updated, 2m09s | 19/205 updated, 1m12s |
   | `cloud-final` | 2m59s | 1m43s |
   | userspace boot | 3m19s | 2m17s |

   The image VM's 19 updates are what belongs to it: the policy fetcher, the
   timers, `aws-access.env`, the Traefik password, the Loki token, Alloy's
   config and restarts. The rest of its converge is a no-op pass over the run
   list.
6. **The first-boot window.** At the first SSH answer — 24 s of uptime on a
   stock VM, 45 s on an image VM — `sudo -n true` was refused and the IMDS
   token request dropped on both. On the image, `netfilter-persistent`
   restored `rules.v4` 19 s before `sshd` started.
7. **Failure paths.**
   - `make ami` for a policy pushed to staging and never promoted refused
     before Packer: "promote first: the image is built only from
     production.json".
   - A revision mismatch, forced with a scratch copy of the build that passes
     the scrub a wrong revision: the scrub refused, the build never powered
     off, Packer timed out and terminated it, and no AMI was registered. The
     first run showed nothing on the serial console but cloud-final's failure;
     the scrub now writes its refusals there too, and the re-run printed
     `refusing: status is 'ok <rev>', expected 'ok <other>'; no image will be
     taken`.
8. **Agents.** In the tenant, asked which guide covers a prebuilt image,
   `claude -p` and `codex exec` each answered `IMAGE.md`, by way of
   `AGENTS.md`.
