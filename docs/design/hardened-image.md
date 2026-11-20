# Hardened image for AI agents — a public AMI Idlefy publishes

> Design record. *Measured* at the end is filled in after the first private
> build has been inspected, before the first public one.

**Date:** 2026-11-20
**Status:** implemented; first build pending
**Ships as:** `v2.2.0`, with the cookbook it converges at `base-2.2.0`.

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

So Idlefy publishes one image itself, from its own account `995603458290`,
public in every default region:
`idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN`.

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
   `solo-<base tag>.tgz` and stores it once on the tag's release. On a later
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
   `dev-vm-image-scrub --profile solo <sha256>` as the user data's last line;
   just before that call the user data switches its output to the console,
   because the scrub deletes `/var/log/user-data.log` while the shell holds
   it open, and anything written to it afterwards would land in freed blocks
   of the public snapshot. A refusal is therefore read on the serial console
   of an instance nobody can log into.
   `test/test-image-scrub.sh` holds each list equal to its fixture.

6. **The trust anchor is the consumer's pinned AMI id list.** Idlefy's
   costpilot side launches only ids it has pinned from a release record; a
   name pattern or an owner id alone is never enough. The account-side deny
   (every principal other than the publisher role and AWS service-linked
   roles is explicitly denied every mutation of an image or snapshot tagged
   `IdlefyPublishedImage=true`) is hygiene. The guard simulates it for every
   IAM user and role (G3) and refuses to publish when it has regressed. The
   guard is read-only and reports every failure, not the first; roles under
   `/aws-reserved/` (Identity Center) cannot be simulated usefully, so they
   are skipped and listed for a manual check. For the public-AMI quota (G2c)
   it falls back to AWS's default value when the account has no applied
   one.

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
     private build once it is itself 7 days old (set 10 minutes ahead, since
     AWS refuses a time in the past);
   - **deregister** a build deprecated 7 or more days ago, or disabled, 7 or
     more days old and not one of the two newest builds ever published; then
     delete its snapshots;
   - **safety net:** a build among the two newest ever published is never
     deregistered. If one of them has passed its deprecation date (the
     two-year default, should publishing stop), the region is reported,
     nothing is done in it, and the script exits 1;
   - a region the script is unsure of — a name outside the pattern, a name
     twice, a date or snapshot it cannot read — is left alone, named, and the
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
      "archive_url": "https://github.com/idlefy/vm-platform-aws/releases/download/<tag>/solo-<base tag>.tgz",
      "architecture": "x86_64",
      "base_tag": "base-X.Y.Z",
      "built_at": "YYYY-MM-DDTHH:MM:SSZ",
      "format": 1,
      "image": "ubuntu-24.04-hardened",
      "login_user": "ubuntu",
      "name": "idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN",
      "owner_id": "995603458290",
      "platform_sha": "<40 hex>",
      "platform_tag": "vX.Y.Z",
      "public": true,
      "root_volume_gib": 20
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
    `cloud-init clean` and never powers off, so Packer times out and no AMI
    is registered. As implemented in `dev-vm-image-scrub-solo`:
    - `solo_dir`, before `image-revision` is written: `/etc/dev-vm` is a
      directory;
    - `solo_prep`, before the removals: `apt-get purge cinc` succeeds, and
      `/opt/cinc/bin/cinc-client` is gone afterwards (checked here, because
      the solo list then removes `/opt/cinc` and its absence would prove
      nothing);
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
      6. `/etc/iptables/rules.v6`'s `*filter` table has an `INPUT DROP`
         policy and the `OUTPUT` drop of `fd00:ec2::254/128` (IMDS over v6);
      7. the `amazon-ssm-agent` snap is neither listed by `snap` nor on disk
         (`/snap/amazon-ssm-agent`, `/var/lib/snapd/snaps/amazon-ssm-agent_*.snap`);
      8. dpkg reports `cinc` as not installed;
      9. `/etc/dev-vm` — checked by `solo_dir` above.

13. **The publisher role is scoped to the build's own tags and a fixed,
    no-ingress security group.** The account also runs the dev organization's
    live Dev Boxes, so the role may only run, stop and terminate instances and
    volumes tagged `Name=idlefy-hardened-image-build`, and passes the fixed
    group `HARDENED_BUILD_SG_ID` rather than letting Packer create one. The
    role itself is applied by Terraform outside this repository.

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

### Workflows

`publish-hardened-image` (dispatch on a tag, or monthly on the 1st at 03:00
UTC):

- `resolve` (no AWS, no environment, `contents: read`): a dispatch must run on
  a `vX.Y.Z` tag ref, else it fails with "run this on a vX.Y.Z tag"; the
  schedule takes the newest `vX.Y.Z` tag on origin, peeled to its commit.
- `publish` (`environment: hardened-publish`, 240 minutes): checkout of the
  tag with `persist-credentials: false`, Packer 1.11.2, Cinc Workstation,
  OIDC credentials for `HARDENED_PUBLISH_ROLE_ARN` (4 hours), then the guard,
  then the build. One approval covers both.
- `permissions: contents: write, id-token: write`, nothing broader;
  `concurrency: hardened-publish` without cancel, shared with the retire
  workflow so a retention never runs during a build. A third queued run
  replaces a pending one, as GitHub concurrency does.
- `public` is a boolean input, default `true`; the schedule always builds
  public. The expression is
  `github.event_name == 'schedule' && 'true' || inputs.public` — never
  `inputs.public || 'true'`, which turns a `false` into `'true'`.
- The driver's test hooks `HARDENED_SKIP_TAG_CHECK` and `HARDENED_TODAY` are
  never set by a workflow.
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
- **Freed blocks of a public snapshot are readable.** Anyone can copy a public
  snapshot and read every block, including blocks a deleted file used to
  occupy. The scrub removes files; it does not wipe free space. What the
  build ever wrote to disk is therefore public: the converge state stays on
  tmpfs (`/run/dev-vm/solo`), no credential ever reaches the instance, and
  the scrub list names nothing secret — only per-instance identity (host keys,
  machine id, engine ids) that must differ between clones.
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
  network; the scrub removes the agent's registration and refuses an image
  that still has the snap.
- **The workflow's credentials.** The publisher role's trust should accept
  only this repository's `hardened-publish` environment
  (`repo:idlefy/vm-platform-aws:environment:hardened-publish`), and the
  environment should be restricted to `main` and `v*` tags with a required
  reviewer. A branch cannot then assume the role with its own workflow file.

## Testing

- `test/test-hardened-template.sh` — `packer fmt`/`validate` with dummy
  inputs, and the decisions the template must not drift from: unencrypted and
  public, no instance profile, a fixed security group, never connecting,
  IMDSv2 without tag reading, the fence tag, one template per directory.
- `test/test-hardened-build.sh` — the driver against shimmed `chef`, `gh`,
  `aws` and `packer`: the account check, the stored-asset comparison, the
  release created when missing, the record, and the real solo user data
  measured against EC2's 16 KB.
- `test/test-hardened-guard.sh` — G1–G3 against a shimmed `aws`, including
  the default-quota fallback and the listed `/aws-reserved/` roles.
- `test/test-hardened-retire.sh` — retention, the safety net, doubts and
  `--disable` against a shimmed `aws` and a fixed clock.
- The solo section of `test/test-image-scrub.sh` — the solo lists against
  their fixture, the CINC purge, and the invariants of decision 12 refusing on
  a fake root.
- The workflows have no local test; `actionlint` (run by CodeRabbit) checks
  them, and the first private build is their test.

## Measured

To be filled in after the first `public=false` build on `v2.2.0`: the
inspection of its restored snapshot against every line of
`test/fixtures/image-scrub-paths-solo`, the diff against a stock noble volume,
and any line added or dropped as a result.
