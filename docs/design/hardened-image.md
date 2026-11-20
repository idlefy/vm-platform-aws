# Hardened image for AI agents — a public AMI Idlefy publishes

> Design record. *Measured* at the end is filled in after the first private
> build has been inspected, before the first public one.

**Date:** 2026-11-20
**Status:** implemented; a run from `v2.2.1` built and registered the image
and was then refused at CopyImage (fixed in the publisher role, not yet
proven by a real copy); `v2.2.2` builds on a 9 GiB root volume
**Ships as:** `v2.2.0`, with the cookbook it converges at `base-2.2.0`;
`v2.2.1` and `v2.2.2` change the build only (the cookbook stays
`base-2.2.0`).

| Need | Where |
|---|---|
| Publish a build | Actions → `publish-hardened-image`, run on a `vX.Y.Z` **tag** |
| Retire or yank a build | Actions → `retire-hardened-image` (dispatch only) |
| Driver, guard, retention | `scripts/hardened-image-build.sh`, `scripts/hardened-guard-check.sh`, `scripts/hardened-image-retire.sh` (headers state the env contract and exit codes) |
| Template and regions | `image/hardened/hardened.pkr.hcl`, `image/hardened/regions` |
| Build user data and scrub | `image/files/bootstrap-solo`, `image/files/dev-vm-image-scrub`, `image/files/dev-vm-image-scrub-solo` |
| What the image converges | `cinc/policyfiles/solo.rb`, `base::solo` (changelog `2.2.0`) |
| Release records | `hardened-ami-YYYYMMDD-NN.json` assets on each `v` release |

## The request

Idlefy's Dev Boxes need an image on which an AI agent (Claude Code
preinstalled, Codex alongside) works as `ubuntu`, with no sudo, behind the
base cookbook's firewall and IMDS rules — usable the moment it boots, in any
customer's account, with no fleet behind it. The tenant-built image
([Prebuilt image](ami-image.md)) does not fit: it caches a fleet converge, its
VMs keep fetching signed policy, and it is private to one tenant's account.

So Idlefy publishes one image itself, from its own publisher account,
public in every default region:
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
   `nvidia_docker`) plus `hardened_firstboot`, `share_helper` and
   `no_ssm_agent`. Every hardening fix lands in both products at once, and
   chefspec covers both run lists.

2. **Public and unencrypted.** AWS refuses to share an encrypted AMI publicly,
   so the root snapshot is unencrypted (`encrypt_boot = false`, and the guard
   refuses a region where EBS encryption by default is on, because the copy
   there would come out encrypted). A consumer encrypts the disk when it
   launches the image.

3. **The build holds no credential.** The build instance has no instance
   profile, the publisher role is denied `iam:PassRole`, the policy archive is
   fetched from a public release asset over HTTPS, and its sha256 is pinned in
   the user data before the instance exists. A compromised build instance can
   reach nothing of Idlefy's. The guard checks that SSM's Default Host
   Management Configuration is unset in every region (G2b), since it would
   hand an instance a role without any instance profile.

4. **The policy archive is a release asset, and its bytes are what the sha
   names.** The driver exports the committed solo lock as
   `solo-<platform tag>.tgz` (for example `solo-v2.2.0.tgz`) and stores it
   once on that tag's release. On a later
   build it downloads the stored asset and compares its contents with a fresh
   export; a stored asset that differs is never used and never replaced — the
   build stops and names it (the same rule as AGENTS.md trap 9).

5. **The scrub has two measured lists: the fleet's and the solo one.**
   `image/files/dev-vm-image-scrub` keeps the fleet lists
   (`test/fixtures/image-scrub-paths`). In solo mode it sources its sibling
   `image/files/dev-vm-image-scrub-solo`, which swaps in the solo lists
   (`test/fixtures/image-scrub-paths-solo`) and adds three hooks. The sibling
   is a separate file because the scrub rides in every fleet VM's user data,
   which EC2 caps at 16 KB gzipped; only the solo build's user data embeds
   it. The driver writes both files side by side, then appends
   `exec dev-vm-image-scrub --profile solo <sha256>` as the user data's last
   line; just before it the user data switches its output to the console,
   because the scrub deletes `/var/log/user-data.log`, and a file still held
   open is freed only at power-off, after the zero-fill. `exec` does the same
   for the script itself: bash holds cloud-init's copy of it (`part-001`,
   which `cloud-init clean` deletes) open close-on-exec, and exec drops that
   hold. Nothing else changes: the bootstrap's ERR trap is already cleared
   before these lines, the scrub's exit status is the script's, and a
   refusal leaves the instance running as before. A refusal is therefore read on the serial console
   of an instance nobody can log into.
   `test/test-image-scrub.sh` holds each list equal to its fixture.

6. **The trust anchor is the consumer's pinned AMI id list.** Idlefy's
   costpilot side launches only ids it has pinned from a release record; a
   name pattern or an owner id alone is never enough. The account-side fence
   is hygiene: the deny policy `deny-idlefy-published-image-mutation`
   (every mutation of an image or snapshot tagged
   `IdlefyPublishedImage=true`) is attached by the account's Terraform
   (`idlefy/infra`, `terraform/aws/account`) to **every** IAM user and role
   except the publisher role and AWS service-linked (`/aws-service-role/`)
   roles. The guard (G3) passes a principal only when every simulated
   decision is `explicitDeny` — top level and every per-resource result, for
   every fenced action, on one resource ARN per listed region. `implicitDeny`
   fails like `allowed`. The reason is that simulation cannot decide a
   conditional Allow: run against the real account, `MissingContextValues`
   listed every condition key found anywhere in a principal's policies (S3-only
   users reported `s3:prefix` for `ec2:` actions), so it cannot tell a
   related condition from an unrelated one. The only decidable rule is that
   each principal carries the deny itself (ruling 2026-11-20, reversing the
   earlier "an implicit deny passes"). Consequences: a role created after
   the last `terraform apply` blocks publishing until the next apply, and a
   CloudFormation stack whose role carries the deny needs the attachment
   removed before the stack can be deleted. The simulation says MFA is
   present (`aws:MultiFactorAuthPresent=true`): an account's "require MFA"
   deny would otherwise read as `explicitDeny` and hide a principal that
   lacks the fence deny — measured on the account, the owner's user simulated
   `explicitDeny` only because of such a policy. For the same reason an
   `explicitDeny` counts only when the fence policy itself
   (`deny-idlefy-published-image-mutation`, overridable as
   `HARDENED_DENY_POLICY_NAME`) is among the decision's `MatchedStatements`
   (`SourcePolicyId` names an attached managed policy by its name): a deny
   from any other policy can be removed without touching the fence, and
   fails as `explicitDeny (other policy)`. The report is one line per
   failing principal (how many decisions were not `explicitDeny`, the worst,
   three `action@region` examples) and one hint to apply the Terraform;
   passing principals are only counted. The
   guard is read-only and reports every failure, not the first; roles under
   `/aws-reserved/` (Identity Center) cannot be simulated usefully, so they
   are skipped and listed for a manual check. For the public-AMI quota (G2c)
   it falls back to AWS's default value only when the account has no applied
   one (`NoSuchResourceException`); any other failed read, such as
   `AccessDenied`, is a failure.

7. **The name pattern is an assert, not a fence.** The template refuses any
   name but `idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN`, and the
   retention script ignores — and doubts the region of — anything else. Anyone
   can register an image with that name in their own account, which is why
   decision 6 pins ids and owner, never names.

8. **Regions are an explicit list, one copy each.** `image/hardened/regions`
   lists the 17 default-enabled commercial regions; the first is the build
   region. The driver refuses a record that does not name exactly those
   regions. Opt-in regions wait for the owner to enable each one on the
   account; adding a region is a line here and the same line in the
   consumer's copy.

9. **Retention: the newest two public builds are kept; nothing runs
   unattended.** Per region, over images tagged `IdlefyPublishedImage=true`:
   - **keep** the two newest public builds that are not deprecated, whatever
     their age — the consumer pins exactly these two. A build is deprecated
     once its `DeprecationTime` has **passed**: AWS gives every public image a
     default deprecation date two years after creation, and a future date is
     not a deprecation;
   - **deprecate** another public build once the newest is 7 days old, and a
     private build once it is itself 7 days old (set 600 s ahead, since AWS
     refuses a time in the past; AWS rounds the date up to the minute, so a
     date up to 660 s ahead is read as an earlier run's pending deprecation
     and left be);
   - **deregister** a build deprecated 7 or more days ago, or disabled, 7 or
     more days old and not one of the two newest builds ever published; then
     delete its snapshots. A snapshot AWS still reports in use
     (`InvalidSnapshot.InUse`) is tried 6 times in all, 10 s apart (5
     retries, about 50 s); the other
     snapshots are still deleted, and every one left is named and the run
     exits 1. Each deprecation time is computed right before its call;
   - **ever published** is read from the image's `Description`, which the
     template sets on the image and on every copy, in the same step that
     shares it: `Idlefy hardened image for AI agents; visibility=public` or
     `…private`, from the build's `public` input; the release record carries
     the same string. `Public` cannot tell: a disabled image is private
     whether it was yanked or never public. A yanked public build still
     counts; **a private build never does — it is never kept, never one of
     the two newest, and is retired by its own age**;
   - **safety net:** a build among the two newest ever published is never
     deregistered. If one of them has passed its deprecation date (the
     two-year default, should publishing stop), the region is reported,
     nothing is done in it, and the script exits 1;
   - only images in state `available` or `disabled` are acted on. A
     `deregistered` image, which AWS lists for a while after a
     deregistration, is ignored. Any other state (`pending`, `failed`, …) is
     ignored unless the image would be one of the two newest published
     builds, or fewer than two exist — then it is a doubt;
   - a region the script is unsure of — a name outside the pattern, a name
     twice, a date, snapshot, block-device mapping, state or `Description` it
     cannot read, a public image whose `Description` says private, a
     not-disabled private image whose `Description` says public, or a
     pending or failed image among the two newest — is left alone, named, and the
     run exits 1. The retire workflow prints the plan into the job summary and
     fails visibly; it never hides a doubt behind a green run.

   The workflow is dispatch-only: every mutation waits for the owner's click
   and the environment approval. Run it with `apply=false` first, and with
   `apply=true` only after the costpilot pin PR for the superseding build has
   shipped. **Yank** = the consumer removes the id first, then
   `disable_name=<name>` runs `--disable` alone (no retention in the same
   run) in every region; a later retention run deregisters it once it is 7
   days old and two newer builds exist.

10. **The release record.** Each build uploads
    `hardened-ami-YYYYMMDD-NN.json` to the tag's release and appends a table
    of its AMIs to the release notes; the publish workflow also prints the
    record into its job summary. A tag workflow cannot commit to `main`, so
    the release — not `docs/changelog.md` — is where builds are recorded.
    Costpilot's Dev Boxes read it (by URL,
    `https://github.com/idlefy/vm-platform-aws/releases/download/<tag>/hardened-ami-<date>-<nn>.json`)
    to pin ids; nothing else consumes it. Format 1:

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
    `cloud-init clean` and never powers off, so no AMI is registered; the
    driver's console watcher sees the refusal and interrupts Packer (see "A
    build whose bootstrap or scrub failed"). As implemented in
    `dev-vm-image-scrub-solo`:
    - `solo_dir`, before `image-revision` is written: `/etc/dev-vm` is a
      directory;
    - `solo_prep`, before the removals: `apt-get purge cinc` succeeds, and
      `/opt/cinc/bin/cinc-client` is gone afterwards; the `amazon-ssm-agent`
      snap is neither listed by `snap` nor on disk
      (`/snap/amazon-ssm-agent`, `/var/lib/snapd/snaps/amazon-ssm-agent_*.snap`)
      — both checked here, because the solo list then removes `/opt/cinc`,
      `/snap` and `/var/lib/snapd`, and an absence would prove nothing after
      it; then snapd's device key files
      (`/var/lib/snapd/device/private-keys-v1/*`) are overwritten in place
      and removed (`shred -u` — a second defence for the one identity known
      to have reached the disk; best effort, a missing directory or a failed
      shred is a console note, never a refusal), and `apt-get purge snapd` and
      `apt-get clean` succeed. **snapd
      leaves the image** (ruling 2026-11-20): the hand-built image carried
      the build instance's snapd device identity —
      `/var/lib/snapd/device/private-keys-v1/<key>` and a serial that
      `snap model --serial` printed — which every box from a public image
      would share. `ubuntu` has no sudo, so only the admin could use snap at
      all; purging it is a smaller surface than editing `state.json`. The
      cost if wrong: the admin runs `apt install snapd` to use a snap.
      `apt-get clean` drops the package cache (321 MB on that image); the
      lists stay. The solo list removes what a purge can leave:
      `/var/lib/snapd`, `/snap`, `/var/snap`, `/var/cache/snapd`,
      `/root/snap`, `/home/*/snap`, and snap-confine's compiled AppArmor
      profiles `/var/cache/apparmor/*/snap-confine*` (measured left by the
      purge on the hand-built image);
    - `solo_check`, immediately before `cloud-init clean`:
      1. `idlefy-hardened-firstboot.service` is enabled **and** its
         `multi-user.target.wants` symlink exists on disk (`enabled-runtime`
         lives in `/run`, not in the image);
      2. `/etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg`,
         `/etc/sudoers.d/50-tailscale-login`, `/etc/sudoers.d/51-idlefy-share`
         and `/usr/local/sbin/idlefy-share` exist; the helper is mode `755`
         and `root:root` (sudoers grants it with `*`, so whoever can write it
         is root);
      3. `visudo -c` accepts the sudoers files;
      4. `/etc/sudoers.d/90-cloud-init-users` is absent;
      5. `ubuntu` is in none of `sudo`, `admin`, `adm`, `lxd` (whole words);
      6. `/etc/iptables/rules.v4` and `/etc/iptables/rules.v6` exist, and in
         each a `*filter` table **closed by its `COMMIT`** holds the
         `:INPUT DROP` policy (`base::firewall`'s `iptables -P INPUT DROP` /
         `ip6tables -P INPUT DROP`) and `base::imds`'s metadata drop exactly as
         `iptables-save` writes it: `-A OUTPUT -d 169.254.169.254/32 -j DROP`
         in rules.v4 (from `iptables -I OUTPUT <n> -d 169.254.169.254 -j DROP`,
         `<n>` right after the last owner allow — `libraries/imds_firewall.rb`)
         and `-A OUTPUT -d fd00:ec2::254/128 -j DROP` in rules.v6. A truncated
         file, a missing one, or the rule in another table or chain refuses.
         Before that drop an **allowlist** holds: every OUTPUT line there must
         be exactly `-A OUTPUT -d <addr>/<prefix> -m owner --uid-owner 0 -j ACCEPT`
         or the same with the uid of `ec2-instance-connect` read from the
         image's own `/etc/passwd` (no such user → root's line only). Anything
         else refuses — another uid, a uid range, `!`, `--gid-owner`, a wider
         destination, a protocol accept, `RETURN`, a jump to another chain, a
         counter-prefixed `[n:m] -A …` line — and so does an unreadable file.
         The check reads only what precedes the drop, never its index; lines
         after it are not restricted. No other recipe of the solo run list
         puts a filter `OUTPUT` line ahead of the drop: Docker is rootless
         (the system daemon is stopped, and dockerd's own OUTPUT jump is in
         `*nat`), and Tailscale's chains hang off `INPUT` and `FORWARD`;
      7. dpkg's database shows `dpkg` itself installed — an empty or
         missing database answers "no packages found" for everything, which
         would read as absence — then dpkg knows neither `snapd` nor an
         `amazon-ssm-agent` package, or knows it as `not-installed`; any
         other answer, including a `dpkg-query` error, refuses.
         `/var/lib/snapd`, `/snap`, `/usr/bin/snap` and `/usr/lib/snapd/snapd`
         are gone. **No unit-shaped file or link** named `snap*.service`,
         `snap*.socket`, `snap*.mount`, `snap*.timer`, `snap*.target`,
         `snap*.path`, `snap*.slice` (snapd writes `snap.<group>.slice` for
         quota groups), `snap*.scope` or `amazon-ssm-agent*` is left **anywhere on the root
         filesystem**: one `find / -xdev` over files and links, not a list
         of unit directories — three reviews each found another directory
         systemd reads units from (`/usr/local/lib`, `~/.config`,
         `~/.local/share`, `/etc/xdg`, `/usr/share/systemd/user`, …), so the
         scan stopped enumerating them. `-xdev` keeps it on the filesystem the
         snapshot images: `/proc`, `/sys`, `/dev` and `/run` are other
         filesystems on the instance (procfs, sysfs, devtmpfs, tmpfs), and
         `/boot` and `/boot/efi` are other partitions that systemd reads no
         units from; nothing is excluded by name. Links are matched as links
         and never followed: a unit behind a linked directory is found at the
         path it really has on this filesystem, and a link to a directory on
         another filesystem points at nothing the image keeps. Any hit
         refuses, and so does a `find` error. Measured on the real image: the
         exact scan returns nothing (rootless Docker's `docker.service`
         included). With the snap check in `solo_prep`, no SSM agent can be
         on the image;
      8. dpkg reports `cinc` as unknown or not installed, by the same strict
         rule;
      9. `/etc/dev-vm` — checked by `solo_dir` above;
      10. last:
          - `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`
            are truncated: cloud-init holds both open (its log handler, its
            output `tee`), so deleting them frees nothing until power-off,
            while truncating frees their blocks now;
          - `cloud-init clean --logs --machine-id`, so that what it deletes
            is overwritten by the fill; the shared scrub's own clean after
            this hook then finds nothing left to delete;
          - **no process holds a deleted regular file of non-zero size on
            `/`** (`/proc/[0-9]*/fd/*`, compared by device with `/`): such a
            file's blocks are freed only at power-off, after the fill. Any
            hit refuses, naming the file, its size and the holder. Strict on
            purpose — the build is the place to find a new holder;
          - a **zero-fill of `/`'s free space**: `sync`; ext4's
            `reserved_clusters` for the root device (found through
            `mountpoint -d /` and `/sys/dev/block`) is read, set to 0 and
            put back afterwards — that reserve (min(2 %, 4096 clusters), up
            to 16 MiB) is withheld even from root, and a refusal from here on
            puts it back too; `dd if=/dev/zero oflag=direct` into one file,
            1 MiB writes and then 4 KiB writes for the last partial MiB, each
            pass ending on "No space left on device"; while the file exists,
            at most `ZERO_FILL_MAX_FREE` (1 MiB) of `/` may be free
            (`stat -f`, free blocks × block size); `sync FILE` (an fsync
            whose error is reported — a bare `sync` reports none); remove
            the file; `sync`; the file must be gone. `O_DIRECT` makes ext4
            allocate the blocks and the file's extent tree at write time, so
            the full filesystem is reported to `dd` instead of failing a
            delayed allocation at writeback with the reserve at 0. The 1 MiB
            bound: after the 4 KiB pass only what ext4 keeps for the file's
            own extent tree should be free, a few 4 KiB blocks; 256 blocks is
            generous for that and 16 times below the reserve.
          A refusal from here on comes after the clean. What the fill covers
          and what it does not: "Freed blocks" in Security notes.

13. **The publisher role is scoped to the build's own tags and a fixed,
    no-ingress security group.** The account also runs the dev organization's
    live Dev Boxes, so the role may only run, stop and terminate instances and
    volumes tagged `Name=idlefy-hardened-image-build`, and passes the fixed
    group `HARDENED_BUILD_SG_ID` rather than letting Packer create one. The
    role itself is applied by Terraform outside this repository. Measured on
    the first run: for Canonical's source image the `ec2:Owner` condition key
    is the owner **alias** `amazon` (DescribeImages `ImageOwnerAlias`), not
    the account id (`<canonical-account-id>`), so a RunInstances condition on the id
    alone refuses the launch. Packer's temporary `packer_*` key pair carries
    the same `Name` tag (it is created with the run tags), so the role may
    delete exactly those key pairs and terminate exactly those instances —
    which the workflow's `leftovers` step does after a killed run.
    Beyond what Packer needs, this repository's scripts use, under that role:
    `GetConsoleOutput` on the build instance (the console watcher),
    `DescribeInstances` and `DescribeKeyPairs` (the leftovers listing),
    `TerminateInstances` and `DeleteKeyPair` (`--clean-build`), and
    `DescribeImages`. If the role's `ec2:Describe*` is ever narrowed to
    single actions, keep `DescribeInstances`, `DescribeKeyPairs` and
    `DescribeImages`: without them a killed run's instance is neither listed
    nor removed, and the watcher's instance is the one Packer names, so it
    needs no describe at all.

    **CreateImage** (measured 2026-11-20, run from `v2.2.1`): the role had a
    Deny on `CreateImage` when the request names an existing snapshot
    (`CreateImageOnlyNewSnapshots`). EC2 fills `ec2:SnapshotID` for the
    snapshot an ordinary CreateImage creates, so that Deny refused every
    image; it was removed. **What this gives up:** a run that already
    controls the publisher role could add any unencrypted snapshot it can
    read in the build region — one the publisher account owns, or one
    another account shared with it — to the build's image through an extra
    block-device mapping, and publish it. G4 refuses to publish while the
    account **owns** an unencrypted snapshot that is not a published one; it
    does not see snapshots shared in, and a run that controls the role need
    not pass the guard. Not yet tried: a Deny keyed on the new snapshot's
    `ec2:VolumeSize`. It must be measured first: if EC2 does not present the
    key, such a Deny would refuse every build, as the removed one did.

    **CopyImage — owner ruling 2026-11-20.** The role denied any request tag
    on a copy. With `CopyImageTags=true` EC2 presents the source image's
    tags as request tags (`aws:TagKeys` is set), so every copy was refused,
    in all 16 regions (measured). The role now requires the build's name on
    the copy — Deny unless `aws:RequestTag/Name` equals
    `idlefy-hardened-image-build` — **on the image resource only**, and
    keeps the Deny on any other tag key on both the image and the snapshot:
    `CopyImageTags` tags the AMI, and whether EC2 evaluates the copy's
    snapshot with those tags is not measured. **What this gives up:** any
    unencrypted image the account can launch — its own, in any region, or
    one shared with it — could be copied under the build's name by a run
    that already controls the role, and then published. G4 covers only
    images the account owns, in the listed regions. A dedicated publishing
    account, holding nothing but this image, was the alternative and was
    not chosen. Applied in the role; **not yet proven by a real copy**.

    **Both residuals above need a run that already controls the role**: a
    `v*` tag, which only repository admins can create, plus the
    `hardened-publish` environment approval. Such a run can already publish
    arbitrary content through the build instance's user data; the residuals
    add another way, not a new class of access.

14. **How the release gets created.** `make release TAG=vX.Y.Z` cuts and the
    owner pushes only the git **tag**; nothing in this repository creates a
    GitHub release. The release flow is: push the tag, then create the
    release from the changelog section by hand
    (`gh release create vX.Y.Z --verify-tag --notes-file <section>`) **before**
    the first publish run on that tag. If the release is missing, the driver
    creates it itself with `--title <tag> --notes ""` so that the archive and
    the record have a home; that release becomes the repository's "Latest"
    with only the hardened-image table in its notes, and the owner edits the
    notes afterwards. The driver never deletes or recreates a release.

### The guard

`scripts/hardened-guard-check.sh`, read-only, run by the publish job before
any build and by hand after any change to the account. It lists every failure,
not the first, and a denied or unreadable read is a failure, never a pass.

| Check | Refuses when |
|---|---|
| G1 | the caller is not in the publisher account (nothing else is called) |
| G2 | in a region of `image/hardened/regions`: EBS encryption by default is on (the copy would be encrypted and could not be public); the region is not enabled; for a **public** build only, image block public access is not `unblocked` |
| G2b | SSM Default Host Management Configuration is set in a region (it would hand the build instance a role) |
| G2c | a region has no room under the public-AMI quota `L-0E3CBAB9` for one more public image (deprecated public images count; the AWS default applies only when no value was applied — any other failed read fails) |
| G3 | an IAM user or role other than the publish role and service-linked roles gets any simulated decision other than `explicitDeny` — top level or per resource, any fenced action on an image or snapshot tagged `IdlefyPublishedImage=true`, any listed region — or its simulation fails or answers short. `implicitDeny` fails like `allowed`; an `explicitDeny` whose `MatchedStatements` do not include the fence policy fails as `explicitDeny (other policy)`. Policy simulation with the fence tag and `aws:MultiFactorAuthPresent=true`, one resource ARN per region (at most 10 per call). One line per failing principal plus the Terraform hint; passing ones are counted. `/aws-reserved/` roles are skipped and listed for a manual check |
| G4 | a region holds a self-owned unencrypted snapshot, or a self-owned image with an unencrypted snapshot, not tagged `IdlefyPublishedImage=true` — each named with its region |

G4 exists because the publisher role can copy images inside the account, and
an unencrypted private disk is the only thing a compromised run could make
public. G4 sees only what the account **owns** in the listed regions: an
unencrypted snapshot or image shared into the account, or one in a region
not on the list, is not checked. The CreateImage and CopyImage residuals of
decision 13 (an extra block-device mapping; a copy under the build's name)
reach exactly those, and a run that controls the publisher role need not
pass the guard at all; both are given up there, not covered here.

G2's block-public-access check follows `HARDENED_PUBLIC` (the publish job
passes the build's value; unset means `true`, anything but `true`/`false` is
refused). A private build does not need it lifted, and with it on nothing can
become public even through a bug — so it stays on until the first public
build, and the guard says so instead of failing.

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

Packer registers the image in the build region, then copies it to every other
region; the record is written only after all of that. A failure anywhere from
`packer build` until the record is on the release — a failed copy, an
artifact that does not name exactly the listed regions, a failed record
upload, an interrupted run — can leave images named `$AMI_NAME` in some
regions, **public if the build was**, that no release record names. The
driver writes the name to `dist/hardened-ami-name` before `packer build`,
and on a failure, INT or TERM it runs `scripts/hardened-image-leftovers.sh`
(read-only `describe-images` by exact name, in every listed region: id,
state, `Public`, and whether the fence tag is set; a failed describe is
printed, never hidden) and keeps the failure's exit status (143 on TERM).
A cancelled or timed-out Actions run is listed by the workflow's `leftovers`
step instead (`if: failure() || cancelled()`), which reads that file and runs
the same script into the job summary: the runner may kill the driver before
it can list anything itself. The consumer never pins them, but they are
public until removed, and
the next build's NN skips their number (NN is one past the highest same-day
number in **any** listed region). Clean-up of images is manual and comes
before any retention run or new build — `docs/runbook.md`, "A hardened build
that failed after its images". Once the record is uploaded, the driver
removes `dist/hardened-ami-name`, so a later failure (the notes edit) lists
no images, neither in the driver nor in the workflow's step: the record
names them.

The same script also lists, in the build region, every instance tagged
`Name=idlefy-hardened-image-build` that is not terminated or shutting down
and every `packer_*` key pair with that tag; with `--clean-build` it
terminates those instances and deletes those key pairs, and nothing else.
With `--clean-build`, an empty instance listing is asked again — 3 listings
10 s apart (`CLEAN_TRIES`, `CLEAN_PAUSE`; `HARDENED_LEFTOVERS_PAUSE` for
the tests) — because EC2 may accept a launch just before the runner kills
Packer and a new instance can take a moment to be listable; anything listed
is acted on at once, and a plain listing asks once.
It does this **first**, before the image listing across every region: the
instance is what costs money, and the workflow's step may run close to the
job's deadline.
Measured on the second run: an Actions cancel kills the runner before Packer
cleans up, so the build instance kept running and the key pair stayed. The
workflow's `leftovers` step runs `--clean-build`, **whether or not a name
file exists**: only build resources carry that tag, the publisher role may
touch nothing else, and the concurrency group lets no other publish run be
live, so there is nothing else it could remove — while a leftover from an
earlier killed run would otherwise survive. Images are never removed by it.
Before any terminate or delete, `--clean-build` checks that
`sts get-caller-identity` names the publisher account — the id it reads from
`scripts/hardened-guard-check.sh` (G1's `ACCOUNT_ID`), not a copy of its own;
a different account or an unreadable identity stops it with nothing listed or
removed. When the job's credentials step never succeeded, the step only says
"No AWS credentials were configured: nothing could have been launched." and
exits 0 (the step reads that step's outcome through `env:`).

### A build whose bootstrap or scrub failed

`bootstrap-solo` fails closed and leaves the instance **running**, so its
serial console keeps the log; the scrub's refusal does the same. Packer, with
`communicator = "none"`, only waits for the instance to stop — measured on
the second run, it would have waited its whole budget (480 × 15 s = 2 h)
after a bootstrap that failed in 28 s. So while `packer build` runs, the
driver reads the console of the instance Packer names (`Instance ID: i-…` in
its own log, never another run's) every 30 s with
`get-console-output --latest`. Only Nitro instance types serve `--latest`:
a non-Nitro type loses this fast failure path (Packer's own 2 h stop
timeout remains); the publisher role allows exactly `c7a.xlarge`, so only a
hand run with other credentials could pick another type. A poll of zero, in
any decimal form, is refused (the watcher would spin). The markers are **whole lines** (a trailing
carriage return allowed), so a console that merely quotes one inside another
line is not a failure — with one allowance: a marker may follow a getty
prompt left unterminated on the console (`<host> login: `, seen on the real
console followed by other text). `bootstrap-solo`'s banner and the solo
scrub's refusals print a newline first; the shared scrub's own refusals
(it rides in every fleet VM and is not changed) do not, hence the
allowance:

- `BOOTSTRAP FAILED: no image will be taken. Log follows.` — the bootstrap's
  banner, exactly as `bootstrap-solo` prints it (a test pins the two equal);
- a line starting `dev-vm-image-scrub: internal error` or
  `dev-vm-image-scrub: refusing` — every exit-70 message either scrub logs,
  including the three early ones that do not say "no image will be taken"
  (a test holds every `log` call of both scrubs to those prefixes or
  `note:`). The fleet scrub's wording is matched, not changed.

On a marker it prints the console's tail into the job log, sends SIGINT to
Packer's process group — Packer then terminates the instance and deletes its
key pair — and
fails with "the bootstrap failed on the build instance" (or "the image scrub
refused the image …") **whatever Packer's own exit status**: a Packer that
took the interrupt and still reported an artifact writes no record. A console
that cannot be read is noted once and is not a failure. A good build shows
nothing: a stopped instance's console reads empty (measured).

The watcher's lifetime: it runs in the background and is stopped and reaped
on every way out of the driver — after `packer build` returns, and in the
EXIT trap on a failure, INT or TERM, before the temporary directory is
removed; its TERM trap kills every job it has running (`jobs -p`: the
pending sleep or in-flight console read, with no window where one is not yet
recorded) and reaps them, so no orphan holds the job's output open. As a
backstop it returns on its own once that directory or the driver's process
is gone.

**How Packer is interrupted.** Packer 1.11.2 runs under panicwrap v1.0.0: the
`packer` process re-executes itself as a worker and only watches it. Packer's
`main.go` sets `wrapConfig.ForwardSignals = []os.Signal{syscall.SIGTERM}` and
no `IgnoreSignals`, so panicwrap defaults that to `os.Interrupt` and the
wrapper catches SIGINT and drops it (`case <-sigCh:` does nothing), on the
assumption that a terminal's Ctrl-C reaches the worker through the process
group anyway. A SIGINT to the wrapper's pid alone is therefore lost, and the
worker — whose `handleTermInterrupt` cancels the build on SIGINT or SIGTERM
and cleans up — never hears it. So:

- `packer build` starts in a session of its own (`setsid`, through a small
  launcher that also resets SIGINT and SIGTERM to their defaults, since a
  background job inherits SIGINT ignored) and writes its pid — its process
  group — to a file;
- the watcher sends SIGINT to that **group**, so wrapper and worker both get
  it; the wrapper drops its copy, the worker cancels;
- the driver waits for the pipeline in the background (`wait` returns to a
  trap at once; a foreground pipeline would hold the trap until Packer ended
  by itself). Its EXIT path — reached on INT, TERM or any failure — stops
  the watcher, then sends SIGINT to Packer's group and **waits** for Packer
  to finish its clean-up before listing leftovers. Its first act is to
  ignore INT and TERM and keep the first exit status: an Actions cancel
  sends INT, then TERM 7.5 s later, and the second signal used to cut short
  the wait, the leftovers listing and the clean-up. The wait for Packer's
  pid file has no cap (it ends when the file holds a pid or the pipeline
  ends); a signal between starting the pipeline and recording its pid is
  covered by taking the one job left. The SIGINT is repeated every 10 s
  while Packer's group lives: the worker takes the first and drops the rest
  (its handler reads one signal), the plugins discard every interrupt
  (packer-plugin-sdk v0.5.4, `plugin/server.go`: "Eat the interrupts"), and
  a repeat covers the instant after start-up when only the wrapper exists.
  There is no escalation to SIGKILL: Packer's clean-up is what removes the
  instance and the key pair; a runner that will not wait kills the job
  itself, and the workflow's `leftovers` step removes what is left. On a
  local run nothing would end a Packer or plugin stalled in its clean-up,
  so the wait (for the pid file, then for Packer's group) has a **grace
  period**: `PACKER_GRACE_DEFAULT=900` s (15 minutes;
  `HARDENED_PACKER_GRACE` overrides it, validated like the poll). When it
  runs out the driver stops waiting — still no KILL — prints that Packer's
  clean-up was **not** confirmed and that the build instance and key pair
  may still exist, pointing at `hardened-image-leftovers.sh --clean-build`,
  keeps the first exit status and still lists leftovers and cleans up. A
  Packer that exits within the grace period sees no change;
- the rest of the pipeline (its subshell, `tee`, `awk`) stays in the
  driver's group but ignores INT and TERM and ends when Packer closes its
  output. A cancel that signals the driver's group must not end the `wait`
  early, nor break the pipe Packer writes its clean-up to — a write to a
  broken stdout would kill it with SIGPIPE mid-clean-up (a test caught
  exactly that under SIGTERM).

The tests stand in for Packer with a wrapper that swallows SIGINT and
forwards only SIGTERM, plus a worker: a marker, and SIGINT or SIGTERM to the
driver's session (with the watcher in a long sleep, or in a hung console
read), each reach the worker; its clean-up ends before the leftovers are
listed; wrapper, worker and every process of the driver's session are gone
when the driver returns, checked at once.

**Nothing the bootstrap or the converge prints may be a secret**: a failure's
console tail — up to 80 lines, the last 56 kB of the bootstrap's log behind
the banner — lands in the job log, which everyone who can read the
repository's Actions can read. The build holds no credential (decision 3);
keep it so, and keep secrets out of the converge's output.

### Workflows

`publish-hardened-image` (dispatch on a tag, or monthly on the 1st at 03:00
UTC):

- `resolve` (no AWS, no environment, `contents: read`): a dispatch must run on
  a `vX.Y.Z` tag ref, else it fails with "run this on a vX.Y.Z tag"; the
  schedule takes the newest `vX.Y.Z` tag on origin, peeled to its commit.
- `publish` (`environment: hardened-publish`, 240 minutes; its `build` step
  180): checkout of the
  tag with `persist-credentials: false`, Packer 1.11.2, Cinc Workstation,
  OIDC credentials for `HARDENED_PUBLISH_ROLE_ARN` (4 hours), then the guard,
  then the build. One approval covers both. `HARDENED_PUBLIC` is set once,
  in the job's `env:`, so the guard and the build cannot drift. After a
  failed, cancelled or timed-out build the `leftovers` step lists any image
  of the chosen name into the job summary (without a name file it says the
  build chose no name, or its record was uploaded, and lists no images),
  terminates the build instance and deletes Packer's key pair if a killed
  run left them, and the `record` step prints any record written. The build
  step's own `timeout-minutes: 180` starts counting only after the steps
  before it, so the job's last 60 minutes are split: up to 45 for checkout,
  the Packer and Cinc setup, credentials and the guard (a few minutes in
  practice), and at least 15 for those two steps. Setup and guard would
  have to take over 45 minutes to eat that reserve; no file bounds them, so
  that part is not asserted. The role session (`role-duration-seconds:
  14400`, the job's 240 minutes) outlives every step, so the leftovers step
  still has credentials after a build timeout. A test pins job ≥ build + 45
  + 15, the session length, the steps' order and their exact `if:`
  (`failure() || cancelled()` for leftovers, `always()` for the record).
  On a cancel or a step timeout the runner signals the driver, which passes
  SIGINT to Packer, but kills the job's processes seconds later — usually
  before Packer's clean-up ends; the leftovers step is what removes the
  instance and key pair then.
- `permissions: {}` at workflow level; `resolve` gets `contents: read`, and
  only the `publish` job gets `contents: write, id-token: write`. The retire
  workflow is the same: nothing at workflow level, its job `contents: read,
  id-token: write`;
  `concurrency: hardened-publish` without cancel. A third queued run replaces
  a pending one, as GitHub concurrency does. The retire workflow has its own
  group, `hardened-retire`, so a publish waiting for approval never blocks a
  yank and a queued publish never replaces a pending retire. A retention that
  runs during a build does not see it: Packer adds the fence tag
  `IdlefyPublishedImage=true` in its last step, after the copies and the
  sharing, and retention lists only tagged images, so it plans as if the
  build had not started.
- The first scheduled run after this workflow reaches `main` builds the
  newest existing `v*` tag, whichever that is.
- `public` is a boolean input, default `true`; the schedule always builds
  public. The expression is
  `github.event_name == 'schedule' && 'true' || inputs.public` — never
  `inputs.public || 'true'`, which turns a `false` into `'true'`.
- The driver refuses a checkout that is not exactly the tag: `HEAD` must be
  `PLATFORM_SHA`, no tracked file may be modified or staged, and no untracked
  file may sit under `image/`, `scripts/` or `cinc/` (ignored ones included);
  `dist/` is the build's own output.
- The driver's test hooks `HARDENED_SKIP_TAG_CHECK` (which also skips the
  clean-tree check) and `HARDENED_TODAY` are never set by a workflow. The driver refuses `HARDENED_TODAY` unless
  `HARDENED_SKIP_TAG_CHECK=1` is set too: a forward-dated name would stay the
  "newest" build for retention forever.
- A scheduled run also waits for the environment approval; an unapproved one
  expires. GitHub disables schedules in a repository without activity for 60
  days.

`retire-hardened-image` (dispatch only): inputs `apply` (boolean, default
`false`) and `disable_name` (string, default empty) reach the script only
through `env:`. The output goes to the job summary whatever the exit code, and
the job fails with the script's exit code.

Every third-party action is pinned to a full commit SHA with its version in a
trailing comment. No input or ref name is interpolated into a `run:` script.

## Security notes

- **Law A1 and the build's lack of credentials** are decisions 3 and 12; the
  residuals below are what they leave.
- **The publisher role's residuals** (decision 13), each needing a run that
  already controls the role — a `v*` tag only repository admins can create,
  plus the environment approval — which could already publish arbitrary
  content through the build instance's user data:
  - CreateImage: any unencrypted snapshot the role can read in the build
    region, owned or shared in, added to the image through an extra
    block-device mapping and published; G4 sees only owned snapshots;
  - CopyImage: any unencrypted image the account can launch, owned in any
    region or shared in, copied under the build's name and published; G4
    sees only owned images in the listed regions.
- **Freed blocks of a public snapshot are readable.** Anyone can copy a public
  snapshot and read every block, including blocks a deleted file used to
  occupy. **The first line of defence stays the law that nothing secret is
  written to the build disk**: the converge state stays on tmpfs
  (`/run/dev-vm/solo`), no credential ever reaches the instance, and the
  scrub list names nothing secret — only per-instance identity (host keys,
  machine id, engine ids) that must differ between clones. snapd's device
  key broke that law (the scrub now removes snapd and shreds the key first),
  so the solo image also **zero-fills its free space** (decision 12, check
  10). **The fill is defence in depth, not the guarantee**: it removes what
  it can reach, and what it cannot reach is listed below. The guarantee is
  still that nothing secret is written to the build disk.
  - Trimming does not help: EBS root volumes accept no discard (measured on a
    c7a.xlarge with a gp3 root: "fstrim: /: the discard operation is not
    supported"). The fleet scrub's `fstrim -av || true` has always been a
    no-op there, and freed blocks have always reached the fleet's private
    snapshots; the fleet is unchanged.
  - The fill covers every data block of `/` that is free when it runs:
    everything the scrub lists remove, the CINC and snapd purges,
    `apt-get clean`, the bootstrap's log (closed before its removal: the
    user data's output goes to the console first), whatever the converge
    deleted, cloud-init's state, its copy of the user data and its logs (the
    solo hook truncates the two open logs and runs `cloud-init clean` before
    the fill), and the ext4 reserve (set to 0 for the fill). Files still
    held open after deletion would escape it; the scrub refuses if any is
    left through an open file descriptor (check 10), and `exec` drops bash's
    hold on its own script. Deleted files held only through a memory mapping
    are **not** checked — libraries apt replaced during the converge, still
    mapped by running processes: they hold public package contents.
  - It does **not** cover:
    - the slack at the end of a file's last block (a live file's own block,
      not a free one);
    - directory entries that still name deleted files, inode tables and
      other metadata blocks;
    - the ext4 journal, which may hold recent metadata and, for data written
      through it, data;
    - up to `ZERO_FILL_MAX_FREE` (1 MiB) that may stay free after the fill;
    - the other partitions of the volume, which the snapshot also images:
      `/boot` (ext4; old kernels and initrds that apt removed) and
      `/boot/efi` (vfat);
    - what happens after it: the shared scrub's second `cloud-init clean`
      (nothing left to delete; it rewrites `/etc/machine-id`), its no-op
      `fstrim`, and what shutdown and cloud-init's final modules write
      (written, not freed — for example the instance-id directory below).
  - The cost: a snapshot of the zero-filled volume stores **every block**
    (measured 2026-11-20 through the EBS direct API: an 8 GiB volume gave
    16384 blocks × 512 KiB), so the stored size is the whole volume, in
    each of the 17 regions. That is why the image is built on a small root
    volume (owner decision 2026-11-20; it was 20). Measured by hand on
    **8 GiB** with the `v2.2.1` files: the build fits (3.9 GB used at the
    end), takes about 3.5 minutes instead of 5.5, and the snapshot about 6.5
    minutes instead of 10–17; a box launched from that image on a 40 GiB
    disk grows its root filesystem to 38G at first boot, and rootless
    Docker, the agent CLIs and the sudo fence work. **9 GiB** was chosen,
    not 8: the publisher role's fence for tagging copied snapshots uses
    `ec2:VolumeSize` as one of its discriminators, and 8 GiB is the default
    root size of stock Ubuntu images, so 8 would match ordinary snapshots;
    9 is unusual and stores about 12 % more than 8. The role's
    `ec2:VolumeSize` fence is 9 (`hardened_volume_gib` in idlefy/infra
    `terraform/aws/account/github_hardened_image.tf`; it changes with
    `VOLUME_GIB` in the driver).
- **The build instance's id directory.** `/var/lib/cloud/instances/<id>`
  (three semaphore files) stays in the image: cloud-init's final modules write
  it after the scrub returns. It names a terminated instance and nothing
  else; accepted as a residual.
- **Packer's temporary key pair.** The template uses `communicator = "none"`,
  so Packer never connects. If the plugin still registers a temporary key
  pair, its public half lands in `authorized_keys` through cloud-init — the
  solo list removes both copies — and its private half lives only on the
  runner for the build's duration. A freed block may still hold the public
  half (above), which grants nothing.
- **The first-boot window on the build instance.** Until `base::ssh` and
  `base::sudoers` converge, the stock image has its default sudo rule. Nobody
  but the runner holds the key, and the fixed security group has no ingress
  at all, so nothing can reach SSH in that window.
- **SSM Default Host Management Configuration** would attach a role to the
  build instance without an instance profile and register it with SSM. The
  guard refuses to publish while it is set in any region (G2b), and
  `bootstrap-solo` stops the stock SSM agent before anything reaches the
  network; the scrub removes the agent's registration, refuses an image
  that still has the snap, and then purges snapd itself.
- **The workflow's credentials — owner prerequisites.** These live outside
  the repository, and the workflows are only as safe as they are:
  - the publisher role trusts only this repository's `hardened-publish`
    environment (`repo:idlefy/vm-platform-aws:environment:hardened-publish`),
    and its `MaxSessionDuration` is at least 14400 s — the publish job asks
    for a 4-hour session;
  - the environment has a required reviewer and its deployment refs are
    restricted to `main` and `v*` tags, so a branch cannot assume the role
    with its own workflow file;
  - a tag ruleset restricts creation, update and deletion of `v*` and
    `base-*` tags to repository admins. A tag is what the publish job builds
    and what a tenant pins; without the ruleset, anyone with write access
    could point one at an ungated commit.
- **Read what you approve.** A scheduled run's approval screen shows `main`,
  not the tag it will build. Before approving any run, open its `resolve` job
  and read the `building <tag> at <sha>` line.
- **Network-fetched tooling in a job that holds the OIDC token.** The publish
  job pipes the Cinc Workstation installer from `omnitruck.cinc.sh` into
  `sudo bash`, pinned to a major version only, and the driver runs
  `packer init`, which downloads the Amazon plugin under `~> 1.3`. Both run in
  the job that can mint the environment's OIDC token and so assume the
  publisher role. A compromise of either source is a compromise of a publish
  run; the role's scope (decision 13), the guard (G4) and the consumer's
  pinned ids (decision 6) bound what such a run could do. Accepted, not
  defended: ci.yml installs the same way.

## Candidates for later hardening

Recorded, not planned; one line each.

- G4 also checks images and snapshots shared into the account, and every
  enabled region rather than only the listed ones.
- The fence policy protects only resources that already carry
  `IdlefyPublishedImage=true`; another principal could add that tag to a
  private image.

## Testing

- `test/test-hardened-template.sh` — `packer fmt`/`validate` with dummy
  inputs, and the decisions the template must not drift from: unencrypted and
  public, no instance profile, a fixed security group, never connecting,
  IMDSv2 without tag reading, the fence tag, one template per directory.
- `test/test-hardened-build.sh` — the driver against shimmed `chef`, `gh`,
  `aws` and `packer`: the account check, the stored-asset comparison, the
  release created when missing, the record, NN across every region, the
  leftover listing after a failure past `packer build`, the console watcher
  (a failure marker interrupts Packer and prints the tail, also after a
  login prompt; no marker, an empty console or a read error changes
  nothing), Packer's interrupt through a panicwrap-like wrapper on a marker,
  INT, TERM, and INT then TERM during a slow clean-up, the leftovers
  script's build-instance and key-pair listing and `--clean-build` (removal
  before the image listing), the user data's `exec` last line, and the real
  solo user data measured against EC2's 16 KB.
- `test/test-hardened-guard.sh` — G1–G4 against a shimmed `aws`, including
  the default-quota fallback, the listed `/aws-reserved/` roles, implicit
  denies passing and allows failing, a "require MFA" deny that must not mask
  an allow, block public access by `HARDENED_PUBLIC`, and stray unencrypted
  snapshots and images, fenced or not.
- `test/test-hardened-retire.sh` — retention, the safety net, doubts and
  `--disable` against a shimmed `aws` and a fixed clock.
- The solo section of `test/test-image-scrub.sh` — the solo lists against
  their fixture, the CINC and snapd purges (the device key shredded first),
  `apt-get clean`, the bootstrap's `apt-get update` before the converge and
  its banner after an unterminated login prompt, and the invariants of
  decision 12 refusing on a fake root: the whole-filesystem unit scan (hits
  in `~/.local/share`, `/etc/xdg`, `/usr/share/systemd/user`, behind a
  linked directory), an empty dpkg database, a deleted file held open, and
  every way the zero-fill can fail (each pass, the fsync, the free-space
  bound, the ext4 reserve). The `dd` shim checks, at the moment the fill
  begins, that nothing on the removal list is left. Shims stand in for `dd`,
  `stat -f`, `mountpoint`, `find` and the ext4 sysfs entry.
- The workflows have no local test, and no automated check validates the
  workflow files today: they were checked by a YAML parse and by reading.
  The first private build is their test.

## To verify on the first private build

Status 2026-11-20: a run from `v2.2.1` built the image and registered it,
then was refused at CopyImage (decision 13). What it proved moved to
"Measured" below; what is left is at the end of this section.

Status after the first two runs and one hand-built image (2026-11-20). The
hand test rendered the same user data (with `apt-get update`), launched it by
hand in the publisher account, made a private image from the stopped
instance by hand and inspected a box from it as `ubuntu` and as the admin; it
proves the converge and the scrub, not what Packer does around them.

Measured on the hand-built image — clean:

- converge and scrub succeed; the instance powers itself off about 2.5 min
  after launch;
- `ubuntu`'s sudo is only `tailscale login` and `idlefy-share *`; IMDS is
  blocked for `ubuntu` and from a rootless container;
- `INPUT DROP` on v4 and v6 with only 22 open (plus `lo`, `tailscale0`,
  ICMPv6, DHCPv6); `rules.v4` and `rules.v6` as decision 12 checks them
  (uid 0 and Instance Connect's uid allowed to IMDS, then the drop);
- no CINC, no SSM snap, no user-data or CINC logs, no shell histories, no
  password hashes; host keys and `machine-id` regenerated at boot;
  `authorized_keys` holds only the launch key; no `/var/log/audit`;
- the agent CLI directories (`/home/ubuntu/.codex`, `/home/ubuntu/.claude`)
  hold no credential; Tailscale holds no node key; rootless Docker works;
  Claude Code, Codex and Node run; no file outside `/home/ubuntu` is
  writable by `ubuntu`; `idlefy-share` refuses without a tailnet and
  validates its argument.

Found and fixed in `v2.2.1`:

- **snapd's device identity** was in the image
  (`/var/lib/snapd/device/private-keys-v1/<key>`, and `snap model --serial`
  printed a serial) → the scrub purges snapd (decision 12);
- 321 MB in `/var/cache/apt` → `apt-get clean`;
- no apt lists on a stock image, so the converge's first package had no
  candidate (run 2) → `bootstrap-solo` runs `apt-get update` first;
- Packer waited 2 h after a failed bootstrap, and a cancel left the build
  instance and key pair → the console watcher and `--clean-build`.

Harmless, left as is: the scrub scripts stay in `/usr/local/sbin`; the build
instance's id directory under `/var/lib/cloud/instances` (three semaphore
files) — cloud-init's final modules write it after the scrub returns, so the
scrub cannot remove it (Security notes).

Still to verify on the next run, before any public build:

- **A real copy under the new CopyImage rule** (decision 13): CopyImage to
  every region succeeds with the copy's tags exactly
  `Name=idlefy-hardened-image-build`;
- **Tags on the copies and their snapshots**: every copy and its snapshot
  carries `IdlefyPublishedImage=true` and the rest of the template's
  `snapshot_tags` — the tag fingerprint the fence and G4 depend on;
- **The Description on every copy**: the image in every region reads
  `Idlefy hardened image for AI agents; visibility=private`, set by
  `ModifyImageAttribute` on the copies (so the publisher role needs that
  action for a private build too), and a retire dry run plans the region
  without a doubt;
- **StepCreateTags in every region**: Packer's last step tags the image and
  its snapshot in each of the 17 regions under the role;
- **The exact `ec2:Describe*` list from CloudTrail**: which describe calls a
  whole build makes under the role, to narrow `ec2:Describe*` (decision 13)
  — pending, since no build has yet run to the end;
- **The 9 GiB build under Packer**: the same as the 8 GiB hand test below,
  through the workflow, with the role's `ec2:VolumeSize` fence at 9.

## Measured

- RunInstances under the publisher role passes with Packer's empty
  instance-profile name: the role's `ec2:InstanceProfile` null condition
  holds (run from `v2.2.1`, 2026-11-20).
- Run from `v2.2.1` through the workflow (2026-11-20): the guard passes
  (every G1–G4 read under the role); bootstrap and scrub run under Packer,
  the console watcher stays silent, and the instance stops itself about 6
  minutes after launch; **CreateImage** succeeds once the role's
  `CreateImageOnlyNewSnapshots` Deny was removed (decision 13); **CopyImage**
  was then refused in all 16 regions by the role's Deny on any request tag
  (decision 13's ruling). After each failure Packer removed the instance,
  the key pair and, on the copy failure, the image itself; nothing was left,
  and the workflow's `leftovers` step confirmed it.
- A snapshot of the zero-filled volume stores every block: an 8 GiB volume
  gave 16384 blocks × 512 KiB through the EBS direct API (2026-11-20).
- An 8 GiB root (hand test with the `v2.2.1` files, 2026-11-20; the image
  ships on 9 GiB for the role's fence, decision 13 and Security notes): the build
  fits with 3.9 GB used at the end, takes about 3.5 minutes (5.5 on 20 GiB),
  the snapshot about 6.5 minutes (10–17 on 20 GiB); a box from the image on
  a 40 GiB disk grows its root filesystem to 38G at first boot, and rootless
  Docker, the agent CLIs and the sudo fence work.

- EBS root volumes accept no discard: `fstrim: /: the discard operation is
  not supported` (c7a.xlarge, gp3 root, a real build instance on
  `f713504`, whose strict trim therefore refused every build; everything
  before it — the snapd purge and every other check — passed).
- The zero-fill (hand test of `1d6180e` on a real instance): the build
  passed in about 5.5 minutes, 2.5 of them before the fill; the snapshot
  then took 10–17 minutes instead of under 2 (the whole disk was written);
  a box from the image was healthy, the fill file gone, 15 of 19 GB free.
  The purge left `/var/cache/apparmor/*/snap-confine*` (now on the list).
  The whole-filesystem unit scan (`find / -xdev`, the names of check 7)
  returned nothing on that image, rootless Docker included.
- The scrub of `a47a083` — the `O_DIRECT` fill with the ext4 reserve at 0,
  the deleted-but-open check, the whole-filesystem unit scan, the exec'd
  scrub — passed every check on a real instance on 2026-11-20; it powered
  off about 5.5 minutes after launch.

- `ec2:Owner` for Canonical's images is the alias `amazon`, not the account
  id (run 1, a refused RunInstances).
- A stock noble image has no apt lists (run 2: `apt_package[ripgrep]: No
  candidate version`, 28 s after launch).
- An Actions cancel leaves Packer's build instance running and its key pair
  in place (run 2).
- A stopped instance's console output reads empty; only a running instance's
  is readable (hand test).
- The hand-built image: see the list above. The inspection of the first
  Packer-built image's restored snapshot against every line of
  `test/fixtures/image-scrub-paths-solo` is still to be added here.
