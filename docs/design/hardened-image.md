# Hardened image for AI agents — a public AMI Idlefy publishes

> Design record.

**Status:** implemented. **Ships as:** `v2.2.0`, with the cookbook it
converges at `base-2.2.0`; GPU sizes from `v2.3.0` and `base-2.3.0`
(decision 15).

| Need | Where |
|---|---|
| Publish a build | Actions → `publish-hardened-image`, run on a `vX.Y.Z` **tag** |
| Retire or yank a build | Actions → `retire-hardened-image` (dispatch only) |
| Driver, guard, retention | `scripts/hardened-image-build.sh`, `scripts/hardened-guard-check.sh`, `scripts/hardened-image-retire.sh` (headers state the env contract and exit codes) |
| Template and regions | `image/hardened/hardened.pkr.hcl`, `image/hardened/regions` |
| Build user data and scrub | `image/files/bootstrap-solo`, `image/files/dev-vm-image-scrub`, `image/files/dev-vm-image-scrub-solo` |
| What the image converges | `cinc/policyfiles/solo.rb`, `base::solo` (changelog `2.2.0`, `2.3.0`) |
| Release records | `hardened-ami-YYYYMMDD-NN.json` assets on each `v` release |

## The request

Idlefy's Dev Boxes need an image on which an AI agent (Claude Code
preinstalled, Codex alongside) works as `ubuntu`, with no sudo, behind the
base cookbook's firewall and IMDS rules — usable the moment it boots, in any
customer's account, with no fleet behind it. The tenant-built image
([Prebuilt image](ami-image.md)) does not fit: it caches a fleet converge, its
VMs keep fetching signed policy, and it is private to one tenant's account.

So Idlefy publishes one image itself, from its own publisher account, public
in the regions of `image/hardened/regions`:
`idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN`.

**The publisher account is `995603458290`.** This id is public by design: it
is the owner id of the published images, which every consumer filters on.
This is the one place the docs name it; elsewhere they say "the publisher
account" (the scripts pin it as `ACCOUNT_ID`).

**Law A1.** Nothing baked into this image takes instructions from Idlefy
after launch. No policy fetch, no credential broker, no SSM agent, no CINC, no
log shipper, no Falco. Once a customer launches it, the box is theirs; Idlefy
reaches it only through what the customer's own account does to the instance
(start, stop, terminate), never through anything inside it.

## Decisions

1. **One cookbook, a second Policyfile — no fork.** `cinc/policyfiles/solo.rb`
   runs `base::solo`: `base::default` without the fleet recipes
   (`cinc_client`, `aws_access`, `traefik`, `falco`, `alloy`,
   `nvidia_docker`) plus `nvidia_baked`, `hardened_firstboot`,
   `share_helper` and `no_ssm_agent`. `nvidia_baked` stands in for
   `nvidia_docker`, which needs a GPU on the host it converges (decision
   15). Every hardening fix lands in both products at once, and
   chefspec covers both run lists.

2. **Public and unencrypted.** AWS refuses to share an encrypted AMI publicly,
   so the root snapshot is unencrypted (`encrypt_boot = false`, and the guard
   refuses a region where EBS encryption by default is on, because the copy
   there would come out encrypted). A consumer encrypts the disk when it
   launches the image. The root volume is 9 GiB (`VOLUME_GIB` in the driver;
   the template's default matches it). A box grows its root filesystem to
   its own disk size at first boot.

3. **The build holds no credential.** The build instance has no instance
   profile, the policy archive is fetched from a public release asset over
   HTTPS, and its sha256 is pinned in the user data before the instance
   exists. The guard checks that SSM's Default Host Management Configuration
   is unset in every listed region (G2b), since it would hand an instance a
   role without any instance profile.

4. **The policy archive is a release asset, and its bytes are what the sha
   names.** The driver exports the committed solo lock as
   `solo-<platform tag>.tgz` and stores it once on that tag's release. On a
   later build it downloads the stored asset and compares its contents with a
   fresh export; a stored asset that differs is never used and never
   replaced — the build stops and names it.

5. **The scrub has two lists: the fleet's and the solo one.**
   `image/files/dev-vm-image-scrub` keeps the fleet lists
   (`test/fixtures/image-scrub-paths`). In solo mode it sources its sibling
   `image/files/dev-vm-image-scrub-solo`, which swaps in the solo lists
   (`test/fixtures/image-scrub-paths-solo`) and adds three hooks. The sibling
   is a separate file because the scrub rides in every fleet VM's user data,
   which EC2 caps at 16 KB gzipped; only the solo build's user data embeds
   it. The user data ends with `exec dev-vm-image-scrub --profile solo
   <sha256>`, its output switched to the serial console just before: the
   scrub deletes the bootstrap's log, and neither that log nor the script
   itself may still be held open when the free space is zero-filled. A
   refusal is read on the serial console of an instance nobody can log into.
   `test/test-image-scrub.sh` holds each list equal to its fixture.

6. **The trust anchor is the consumer's pinned AMI id list.** Idlefy's
   consumer launches only ids it has pinned from a release record; a name
   pattern or an owner id alone is never enough. A user checks that an image
   is Idlefy's by its owner id (`995603458290`) and by finding its id in the
   release record of a `v` tag of this repository. The account-side fence is
   hygiene: the deny policy `deny-idlefy-published-image-mutation` (every
   mutation of an image or snapshot tagged `IdlefyPublishedImage=true`) is
   attached by the account's Terraform to **every** IAM user and role except
   the publisher role and AWS service-linked roles. The guard (G3) passes a
   principal only when every simulated decision is an `explicitDeny` from
   that policy itself — top level and every per-resource result, for every
   fenced action, on one resource ARN per listed region. `implicitDeny`
   fails like `allowed`, because simulation cannot decide a conditional
   Allow; a deny from another policy fails as `explicitDeny (other policy)`,
   since it can be removed without touching the fence. The simulation says
   MFA is present (`aws:MultiFactorAuthPresent=true`), so a "require MFA"
   deny cannot stand in for the fence. A role created after the last
   `terraform apply` therefore blocks publishing until the next apply. Roles
   under `/aws-reserved/` (Identity Center) cannot be simulated usefully and
   are listed for a manual check.

7. **The name pattern is an assert, not a fence.** The template refuses any
   name but `idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN`, and the
   retention script ignores — and doubts the region of — anything else.
   Anyone can register an image with that name in their own account, which
   is why decision 6 pins ids and owner, never names.

8. **Regions are an explicit list, one copy each.** `image/hardened/regions`
   lists the regions the image is built in and copied to: `us-east-1`, the
   build region, first, then the other published regions. The driver refuses
   a record that does not name exactly the listed regions, and the guard,
   the leftovers listing and retention read the same file. Adding a region
   is a line here and the same line in the consumer's copy; an opt-in
   region must first be enabled on the account.

9. **Retention: the newest two public builds are kept; nothing runs
   unattended.** Per region, over images tagged `IdlefyPublishedImage=true`:
   - **keep** the two newest public builds that are not deprecated, whatever
     their age — the consumer pins exactly these two. A consumer may pin
     only the newest build for one cycle, when the builds before it lack
     something it needs (builds before `v2.3.0` have no GPU driver), and
     returns to two with the next build. Retention does not change. A build
     is deprecated
     once its `DeprecationTime` has **passed** (AWS gives every public image
     a default deprecation date two years ahead; a future date is not a
     deprecation);
   - **deprecate** another public build once the newest is 7 days old, and a
     private build once it is itself 7 days old (set 600 s ahead; a date up
     to 660 s ahead is read as an earlier run's pending deprecation);
   - **deregister** a build deprecated 7 or more days ago, or disabled, 7 or
     more days old and not one of the two newest builds ever published; then
     delete its snapshots. A snapshot still in use is tried 6 times, 10 s
     apart; every one left is named and the run exits 1;
   - **ever published** is read from the image's `Description`, which the
     template sets on the image and every copy: `Idlefy hardened image for AI
     agents; visibility=public` or `…private`. A yanked public build still
     counts; **a private build never does — it is never kept, never one of
     the two newest, and is retired by its own age**;
   - **safety net:** a build among the two newest ever published is never
     deregistered. If one of them has passed its deprecation date, the
     region is reported, nothing is done in it, and the script exits 1;
   - only images in state `available` or `disabled` are acted on; a
     `deregistered` one is ignored, and any other state is a doubt when the
     image would be one of the two newest published builds;
   - a region the script is unsure of — a name outside the pattern, a name
     twice, a date, snapshot, block-device mapping, state or `Description` it
     cannot read, or a visibility that contradicts the `Description` — is
     left alone, named, and the run exits 1.

   The workflow is dispatch-only: every mutation waits for a click and the
   environment approval. Run it with `apply=false` first, and with
   `apply=true` only after the consumer has pinned the superseding build.
   **Yank** = the consumer removes the id first, then `disable_name=<name>`
   runs `--disable` alone in every region; a later retention run deregisters
   it once it is 7 days old and two newer builds exist.

10. **The release record.** Each build uploads
    `hardened-ami-YYYYMMDD-NN.json` to the tag's release and appends a table
    of its AMIs to the release notes; the publish workflow also prints the
    record into its job summary. Consumers read it by URL,
    `https://github.com/idlefy/vm-platform-aws/releases/download/<tag>/hardened-ami-<date>-<nn>.json`.
    Format 1:

    ```json
    {
      "amis": { "<region>": "ami-…", "…": "…" },
      "archive_sha256": "<64 hex>",
      "archive_url": "https://github.com/idlefy/vm-platform-aws/releases/download/<tag>/solo-<tag>.tgz",
      "architecture": "x86_64",
      "base_tag": "base-X.Y.Z",
      "built_at": "YYYY-MM-DDTHH:MM:SSZ",
      "description": "Idlefy hardened image for AI agents; visibility=public",
      "format": 1,
      "image": "ubuntu-24.04-hardened",
      "login_user": "ubuntu",
      "name": "idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN",
      "owner_id": "<publisher account id>",
      "platform_sha": "<40 hex>",
      "platform_tag": "vX.Y.Z",
      "public": true,
      "root_volume_gib": 9
    }
    ```

    `amis` names every region of `image/hardened/regions` and no other.
    `public: false` marks an inspection build that must never be pinned.

11. **`IdlefyAttached` exists only for Idlefy's own account.** When the
    repository variable `HARDENED_DEV_ORG_ID` is set, the AMI carries
    `IdlefyAttached=<org uuid>` so Idlefy's dev organization can launch it in
    the publishing account under its own stack. It grants nothing to anyone
    else and is not part of the trust anchor.

12. **The solo scrub fails closed.** Every invariant the cookbook bakes and
    the first boot relies on is checked on the disk about to be snapshotted;
    a build that lost one exits 70, names the reason on the console, skips
    `cloud-init clean` and never powers off, so no AMI is registered, and the
    driver's console watcher interrupts Packer. As implemented in
    `dev-vm-image-scrub-solo`:
    - `solo_dir`: `/etc/dev-vm` is a directory;
    - `solo_prep`, before the removals: `apt-get purge cinc` succeeds and
      `/opt/cinc/bin/cinc-client` is gone; the `amazon-ssm-agent` snap is
      neither listed by `snap` nor on disk; snapd's device key files are
      overwritten and removed (`shred -u`, best effort); `apt-get purge
      snapd` and `apt-get clean` succeed. snapd leaves the image because its
      state holds a device identity every box would share; `ubuntu` has no
      sudo, so only the admin could use snap, and can install it. The solo
      list removes what the purges leave;
    - `solo_check`, immediately before `cloud-init clean`:
      1. `idlefy-hardened-firstboot.service` is enabled **and** its
         `multi-user.target.wants` symlink exists on disk;
      2. `/etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg`,
         `/etc/sudoers.d/50-tailscale-login`, `/etc/sudoers.d/51-idlefy-share`
         and `/usr/local/sbin/idlefy-share` exist; the helper is mode `755`
         and `root:root`;
      3. `visudo -c` accepts the sudoers files;
      4. `/etc/sudoers.d/90-cloud-init-users` is absent;
      5. `ubuntu` is in none of `sudo`, `admin`, `adm`, `lxd` (whole words);
      6. `/etc/iptables/rules.v4` and `rules.v6` each hold, in a `*filter`
         table closed by its `COMMIT`, the `:INPUT DROP` policy and the
         metadata drop (`-A OUTPUT -d 169.254.169.254/32 -j DROP`,
         `-A OUTPUT -d fd00:ec2::254/128 -j DROP`), and before that drop only
         root's and Instance Connect's owner allows (an allowlist; anything
         else, or an unreadable file, refuses);
      7. dpkg's database shows `dpkg` itself installed, and knows neither
         `snapd` nor an `amazon-ssm-agent` package, or knows it as
         `not-installed`; any other answer refuses. `/var/lib/snapd`,
         `/snap`, `/usr/bin/snap` and `/usr/lib/snapd/snapd` are gone, and no
         file or link named `snap*.service`, `.socket`, `.mount`, `.timer`,
         `.target`, `.path`, `.slice`, `.scope` or `amazon-ssm-agent*` is
         left anywhere on the root filesystem (one `find / -xdev`, links
         matched and never followed; a `find` error refuses);
      8. dpkg reports `cinc` as unknown or not installed, by the same rule;
      9. the GPU support of decision 15: dpkg reports
         `linux-modules-nvidia-580-server-open-aws`,
         `nvidia-headless-no-dkms-580-server-open`, `nvidia-utils-580-server`
         and `nvidia-container-toolkit` installed (the branch is the scrub's
         `NVIDIA_BRANCH`, which the test holds equal to the cookbook's
         default); the newest kernel under `/boot` (`vmlinuz-*`, version
         order) has an `nvidia.ko*` under `/lib/modules`; the drop-in holds
         its `ExecCondition` line and its `Before=user@1000.service` line,
         and systemd names it among the service's
         drop-ins; `nvidia-cdi-refresh.service` and `.path` are enabled, each
         with its `multi-user.target.wants` symlink on disk, and the service
         has not failed; `/etc/tmpfiles.d/idlefy-cdi.conf` holds exactly
         `d /run/cdi 0755 root root -`; `/etc/cdi/nvidia.yaml`,
         `/var/run/cdi/nvidia.yaml` and `/run/cdi/nvidia.yaml` are absent;
         and
         `/etc/nvidia-container-runtime/config.toml` sets `no-cgroups = true`
         in its `[nvidia-container-cli]` table;
      10. last: cloud-init's two open logs are truncated, `cloud-init clean`
          runs, no process may hold a deleted non-empty file on `/`, and the
          free space of `/` is zero-filled (below). Each step that cannot be
          confirmed refuses.

    **The zero-fill.** A public snapshot's freed blocks are readable, and EBS
    root volumes accept no discard, so the solo scrub overwrites the free
    space of `/` with zeros: ext4's reserved clusters are set to 0 for the
    fill and put back after; `dd oflag=direct` writes 1 MiB, then 4 KiB
    blocks, each pass ending on "No space left on device"; at most
    `ZERO_FILL_MAX_FREE` (1 MiB) may stay free; the file is fsynced with its
    error checked, then removed. It is defence in depth: the guarantee is
    that nothing secret is written to the build disk (the converge state
    lives on tmpfs, and the scrub lists name only per-instance identity). The
    fill does not reach the slack of a file's last block, directory entries
    and other metadata, the ext4 journal, or the `/boot` and `/boot/efi`
    partitions. A snapshot of the filled volume stores every block, which is
    why the root volume is small.

13. **Publishing runs through a narrowly scoped OIDC role.** The publish and
    retire workflows assume one IAM role, trusted only by this repository's
    `hardened-publish` environment, scoped to the build's own tags and a
    fixed, no-ingress security group (`HARDENED_BUILD_SG_ID`). Its policy is
    not part of this repository. Beyond what Packer needs, the scripts use
    `GetConsoleOutput` on the build instance (the console watcher),
    `DescribeInstances` and `DescribeKeyPairs` (the leftovers listing),
    `TerminateInstances` and `DeleteKeyPair` (`--clean-build`), and
    `DescribeImages`.

14. **How the release gets created.** `make release TAG=vX.Y.Z` cuts and the
    owner pushes only the git **tag**. The release is created from the
    changelog section by hand (`gh release create vX.Y.Z --verify-tag
    --notes-file <section>`) before the first publish run on that tag. If it
    is missing, the driver creates it with an empty body, so that the
    archive and the record have a home. The driver never deletes or
    recreates a release.

    **Test builds use pre-release tags.** `make release TAG=vX.Y.Z-rc.N`
    cuts a pre-release of `vX.Y.Z` (the changelog must already hold the
    `vX.Y.Z` entry), and a build from it is private only: the workflow and
    the driver both refuse a public one, the driver before any cloud call. A
    release the driver creates for it is a pre-release, never Latest, so
    test iterations never appear as releases; `vX.Y.Z` itself is tagged once
    the test has passed. A pre-release tag's GitHub release is left to the
    driver: one created by hand without `--prerelease` could become Latest.
    `make release` refuses an rc of a version already tagged.

15. **GPU sizes.** The image carries the NVIDIA driver and the NVIDIA
    Container Toolkit for NVIDIA GPU sizes; one image serves every size.
    `base::nvidia_baked` (solo only; the fleet's `nvidia_docker` is
    unchanged) bakes:
    - the driver from Ubuntu's archive, branch `580-server-open`
      (`node['base']['nvidia']['driver_branch']`):
      `linux-modules-nvidia-580-server-open-aws`, prebuilt and signed for the
      AWS kernel, with `nvidia-headless-no-dkms-580-server-open` and
      `nvidia-utils-580-server`. No DKMS and no compiler. These are NVIDIA's
      open kernel modules, which do not cover NVIDIA GPUs older than the
      Turing generation (on AWS, the P3 and G3 families);
    - the NVIDIA Container Toolkit, from the source `nvidia_docker` uses,
      with `no-cgroups = true` in its `[nvidia-container-cli]` table for
      rootless Docker (`nvidia-ctk config --set
      nvidia-container-cli.no-cgroups=true --in-place`).

    How updates are configured: the kernel meta package and the modules meta
    package both come from Ubuntu's `-updates` and `-security` pockets, which
    unattended-upgrades already allows, so a new kernel and its modules are
    both eligible for the same unattended run. A driver update that lands
    while the old module is loaded needs a restart of the box: until then
    the new libraries and the loaded module differ, and new GPU work can
    fail. The toolkit's source is not
    in `Origins-Pattern`, as on the fleet, so the toolkit does not update
    unattended.

    Measured on 2026-11-24 on a stock Ubuntu 24.04 `t3.large` with kernel
    `7.0.0-1018-aws`: the prebuilt module package matches the running
    kernel, so one kernel is installed; the driver (branch 580, open kernel
    modules, `580.178.04`) adds twelve packages and needs no compiler, no
    DKMS and no `binutils`; no new setuid binary appears, with or without the
    toolkit; `nvidia-persistenced` is not enabled; driver and toolkit add
    about 0.6 GB (2.0 GB to 2.6 GB used). The root volume stays 9 GiB.

    The CDI spec is made on the box, never baked. The toolkit (1.20.2 when
    measured) ships `nvidia-cdi-refresh.service` and `.path`, both enabled by
    its package, which write the spec to `/var/run/cdi/nvidia.yaml`, on
    tmpfs, so a box moved to a size without a GPU keeps no stale spec. The
    service's own condition passes on any machine that has the module
    installed. Measured on 2026-11-24 on a stock Ubuntu 24.04 instance
    without a GPU: the service failed and restarted until its start limit. A
    drop-in, `nvidia-cdi-refresh.service.d/20-idlefy-gpu-present.conf`, adds
    an `ExecCondition` that passes only when a PCI device of vendor `0x10de`
    exists; a failed condition skips the unit without marking it failed.
    Measured the same day on the same kind of instance, with the drop-in: the
    unit is skipped with result `exec-condition`, and no unit has failed. The
    drop-in is written before any NVIDIA package is installed, because the
    build host has no GPU either. Nothing runs `nvidia-ctk cdi generate` or
    `nvidia-ctk runtime configure` at converge time. Law A1 holds: the
    refresh unit reads only local files and hardware.

    Rootless Docker reads the spec without any daemon configuration.
    Measured on 2026-11-24 on the published image (rootless Docker 29.10.0):
    `docker info` lists `/etc/cdi` and `/var/run/cdi` as CDI spec
    directories. RootlessKit copies up `/run` when the rootless daemon
    starts, so a `/run/cdi` created after that is not visible to the daemon.
    `/etc/tmpfiles.d/idlefy-cdi.conf` (`d /run/cdi 0755 root root -`)
    therefore creates the directory at boot. With it in place, a spec written
    after the daemon started was used at once (checked with a test spec, not
    with a GPU).

    The drop-in also orders the refresh before `user@1000.service`, where
    rootless Docker starts, and gives it `TimeoutStartSec=120`. Measured on
    2026-11-25 on a `g4dn.xlarge` (Tesla T4), on the published `v2.2.1`
    image with the packages, the drop-in and the tmpfiles entry applied by
    hand in the recipe's order: without the ordering, on the first boot the
    spec appeared about 15 s after the rootless daemon had started, the
    daemon logged `permission denied` for it and
    `--device nvidia.com/gpu=all` failed until the directory next changed;
    regenerating the spec later did not reproduce it. With the ordering, a
    reboot and a stop and start were both clean; the refresh took about
    8.5 s of the boot. A refresh that hangs delays the user manager by at
    most that timeout: measured on the image's systemd 255 with a stand-in
    unit, the unit ordered after it starts when the first attempt times
    out, while the unit itself goes on restarting.

    Measured in the same run, as `ubuntu`, which still has no sudo:
    `nvidia-smi` reports the GPU with driver `580.178.04`; containers
    started with `--device nvidia.com/gpu=all` and with `--gpus all` see it;
    a PyTorch CUDA image computes on it; a container started without either
    flag has no NVIDIA device. The spec names `/dev/nvidia0`, `nvidiactl`,
    `nvidia-uvm`, `nvidia-uvm-tools` and `nvidia-modeset`; no unit failed.
    The same instance switched to a `t3.large`: the refresh is skipped
    (`exec-condition`), no spec exists, the module is not loaded, no unit
    failed, `cloud-init status` is `done`, and containers run as before.

### The guard

`scripts/hardened-guard-check.sh`, read-only, run by the publish job before
any build and by hand after any change to the account. It reads the regions
of `image/hardened/regions`, lists every failure, not the first, and treats a
denied or unreadable read as a failure, never a pass.

| Check | Refuses when |
|---|---|
| G1 | the caller is not in the publisher account (nothing else is called) |
| G2 | in a listed region: EBS encryption by default is on; the region is not enabled; for a **public** build only, image block public access is not `unblocked` |
| G2b | SSM Default Host Management Configuration is set in a listed region |
| G2c | a listed region has no room under the public-AMI quota `L-0E3CBAB9` for one more public image (the AWS default applies only when no value was applied — any other failed read fails) |
| G3 | an IAM user or role other than the publish role and service-linked roles gets any simulated decision other than the fence policy's `explicitDeny`, for any fenced action, in any listed region — or its simulation fails or answers short |
| G4 | a listed region holds a self-owned unencrypted snapshot, or a self-owned image with an unencrypted snapshot, not tagged `IdlefyPublishedImage=true` — each named with its region |

G2's block-public-access check follows `HARDENED_PUBLIC`: a private build
does not need it lifted, so it stays on until the first public build, and the
guard says so instead of failing.

G3's fenced actions — image: `DeregisterImage`, `ModifyImageAttribute`,
`ResetImageAttribute`, `EnableImageDeprecation`, `DisableImageDeprecation`,
`DisableImage`, `EnableImage`, `CreateTags`, `DeleteTags`,
`EnableImageDeregistrationProtection`, `DisableImageDeregistrationProtection`,
`AttachImageWatermark`, `DetachImageWatermark`,
`ReplaceImageInstanceTypeSpecification`; snapshot: `DeleteSnapshot`,
`ModifySnapshotAttribute`, `ResetSnapshotAttribute`, `CreateTags`,
`DeleteTags`, `LockSnapshot`, `UnlockSnapshot`, `ModifySnapshotTier` (all
`ec2:`). The account's deny policy covers the same list.

### A build that failed after its images

Packer registers the image in the build region, then copies it to the other
listed regions; the record is written only after all of that. A failure in
between — a failed copy, an artifact that does not name exactly the listed
regions, a failed record upload, an interrupted run — can leave images named
`$AMI_NAME`, **public if the build was**, that no release record names. The
driver writes the name to `dist/hardened-ami-name` before `packer build`, and
on a failure, INT or TERM runs `scripts/hardened-image-leftovers.sh`
(read-only, by exact name, in every listed region: id, state, `Public`, and
whether the fence tag is set) and keeps the failure's exit status. A
cancelled or timed-out Actions run is listed by the workflow's `leftovers`
step instead, which reads that file. The next build's NN skips their number.
Images and their snapshots are never removed automatically; they are
removed by hand, before any retention run or new build (`docs/runbook.md`).

The same script lists, in the build region, every live instance tagged
`Name=idlefy-hardened-image-build` and every `packer_*` key pair with that
tag; with `--clean-build` it first checks that the credentials are the
publisher account's, then terminates those instances and deletes those key
pairs — and nothing else — before the image listing. An empty instance
listing is asked again (3 listings, 10 s apart), since a just-launched
instance can take a moment to be listable. The workflow's `leftovers` step
runs `--clean-build` after every failed or cancelled run.

### A build whose bootstrap or scrub failed

`bootstrap-solo` fails closed and leaves the instance **running**, so its
serial console keeps the log; the scrub's refusal does the same. Packer, with
`communicator = "none"`, only waits for the instance to stop, so while
`packer build` runs the driver reads the console of the instance Packer names
every 30 s (`get-console-output --latest`, which Nitro types serve). On a
whole line — optionally after an unterminated getty prompt — of
`BOOTSTRAP FAILED: no image will be taken. Log follows.` or a scrub refusal
(`dev-vm-image-scrub: internal error…` / `…: refusing…`), it prints the
console's tail into the job log, interrupts Packer — which terminates the
instance and deletes its key pair — and fails with the reason, whatever
Packer reports. A console that cannot be read is noted once and is not a
failure.

Packer runs in a process group of its own and is interrupted as a group (its
panicwrap wrapper drops a SIGINT sent to it alone). On INT, TERM or any
failure the driver ignores further signals, stops the watcher, sends SIGINT to
Packer's group (again every 10 s) and waits for its clean-up, up to a grace
period of 15 minutes (`HARDENED_PACKER_GRACE`); it never sends SIGKILL. If the
grace runs out it says the clean-up was not confirmed and points at
`--clean-build`. The rest of the pipeline ignores INT and TERM, so a cancel
does not break the pipe Packer logs to.

**Nothing the bootstrap or the converge prints may be a secret**: a failure's
console tail lands in the job log, which everyone who can read the
repository's Actions can read.

### Workflows

`publish-hardened-image` (dispatch on a tag, or monthly on the 1st at 03:00
UTC):

- `resolve` (no AWS, `contents: read`): a dispatch must run on a `vX.Y.Z`
  or `vX.Y.Z-rc.N` tag ref; the schedule takes the newest `vX.Y.Z` tag on
  origin, peeled to its commit, and never a pre-release tag.
- `publish` (`environment: hardened-publish`, 240 minutes; its `build` step
  180): checkout of the tag, Packer 1.11.2, Cinc Workstation, OIDC
  credentials for `HARDENED_PUBLISH_ROLE_ARN`, then the guard, then the
  build. `HARDENED_PUBLIC` is set once, in the job's `env:`
  (`github.event_name == 'schedule' && 'true' || inputs.public`). After a
  failed, cancelled or timed-out build the `leftovers` step removes the
  build instance and key pair and lists any image of the chosen name into the
  job summary, and the `record` step prints any record written. The build
  step's timeout leaves the job at least 15 minutes for those two steps.
- `permissions: {}` at workflow level; only the `publish` job gets
  `contents: write, id-token: write`. `concurrency: hardened-publish`
  without cancel; the retire workflow has its own group.
- The driver refuses a checkout that is not exactly the tag: `HEAD` must be
  `PLATFORM_SHA`, no tracked file may be modified or staged, and no untracked
  file may sit under `image/`, `scripts/` or `cinc/`.
- Its test hooks `HARDENED_SKIP_TAG_CHECK` and `HARDENED_TODAY` are never
  set by a workflow; `HARDENED_TODAY` is refused without the other.

`retire-hardened-image` (dispatch only): inputs `apply` (default `false`) and
`disable_name` reach the script only through `env:`; the output goes to the
job summary whatever the exit code.

Every third-party action is pinned to a full commit SHA. No input or ref name
is interpolated into a `run:` script.

## Security notes

- **Law A1 and the build's lack of credentials** are decisions 3 and 12.
- **The build instance's id directory.** `/var/lib/cloud/instances/<id>`
  stays in the image: cloud-init's final modules write it after the scrub
  returns. It names a terminated instance and nothing else.
- **Packer's temporary key pair.** The template never connects. If the
  plugin registers a temporary key pair, its public half lands in
  `authorized_keys` through cloud-init — the solo list removes both copies —
  and its private half lives only on the runner for the build's duration.
- **The first-boot window on the build instance.** Until `base::ssh` and
  `base::sudoers` converge, the stock image has its default sudo rule; the
  fixed security group has no ingress at all.
- **SSM.** `bootstrap-solo` stops the stock SSM agent before anything reaches
  the network; the scrub removes its registration and refuses an image that
  still has the snap.
- **Prerequisites outside the repository.** The role trusts only the
  `hardened-publish` environment; the environment has a required reviewer and
  is restricted to `main` and `v*` tags; a tag ruleset restricts creating,
  updating and deleting `v*` and `base-*` tags to repository admins. A
  scheduled run's approval screen shows `main`: read the `resolve` job's
  `building <tag> at <sha>` line before approving.

## Testing

- `test/test-hardened-template.sh` — `packer fmt`/`validate`, and the
  decisions the template must not drift from: unencrypted, no instance
  profile, a fixed security group, never connecting, IMDSv2 without tag
  reading, the fence tag, the volume size.
- `test/test-hardened-build.sh` — the driver against shimmed `chef`, `gh`,
  `aws` and `packer`: the account and tag checks, the stored-asset
  comparison, the record, NN across regions, the leftovers listing and
  `--clean-build`, the console watcher, Packer's interrupt and grace period,
  the workflow's timeouts, and the solo user data against EC2's 16 KB.
- `test/test-hardened-guard.sh` — G1–G4 against a shimmed `aws`.
- `test/test-hardened-retire.sh` — retention, the safety net, doubts and
  `--disable` against a shimmed `aws` and a fixed clock.
- The solo section of `test/test-image-scrub.sh` — the solo lists against
  their fixture, the purges, and every invariant of decision 12 refusing on a
  fake root, the zero-fill's failures included.
