# Fleet image

Follow this when the operator wants to build a prebuilt AMI for the fleet, or
refresh the one they have. It builds an image and shows a plan; it never
applies one.

A prebuilt image is the platform's first converge done once, ahead of time: new
VMs boot already converged and finish their first run in minutes instead of
the better part of an hour. It changes how fast a VM becomes ready and nothing
about what it trusts: the VM still fetches, verifies and converges the signed
envelope for its group. The design, its measurements and its threat model are
in the pinned upstream, `docs/design/ami-image.md`.

**Trust point.** With `ami_owners = ["self"]`, anyone in the account who can
register an image matching `ami_name_pattern` chooses what new VMs boot. The
VM permissions boundary denies every such route to a developer's VM on
purpose. Operators with image rights are therefore trusted like signers: grant
them as carefully, and never share an image outside the account.

## 1. Already on an image?

```bash
test -f vms/tenant.auto.tfvars || echo "MISSING vms/tenant.auto.tfvars"
grep -n 'ami_owners\|ami_name_pattern' vms/tenant.auto.tfvars
```

`MISSING` → this tenant is not configured; follow [`SETUP.md`](SETUP.md)
first, then come back.

`ami_owners = ["self"]` is set → the fleet is on an image already. The request
is a rebuild: skip step 5 and start at step 2. Otherwise (the default
`099720109477`, Canonical) → continue; step 5 is what switches the fleet over.

## 2. Prerequisites

Check each one and report what is missing; do not work around it.

```bash
packer version                    # 1.11 or newer
cd cinc && make preflight         # the policy line must read: production ok
```

- A promoted production revision. The image is built only from
  `production.json`, because one image feeds both groups and a staging build
  would put unpromoted content on production VMs. `make ami` refuses when
  production is missing, does not verify, or names a different revision than
  the committed lock.
- `vms/` initialised on `v2.1.0` or later (`terraform init`), so the pinned
  platform checkout holds `image/`.
- `terraform apply` has been run once on `v2.1.0` or later by the operator.
  The first-boot script the image bakes is read from Terraform **state**
  (`terraform output bootstrap_user_data`); a state without that output is
  refused with a message saying so.
- Every VM's `volume_size_gb` in `vms/instances.auto.tfvars` is at least the
  image's volume (default 20). A smaller VM is refused; pass `VOLUME=<n>` to
  match the smallest one.
- The operator's own credentials (the profile in `tenant.auto.tfvars`), not a
  VM's, must allow: `ec2:RunInstances`, `TerminateInstances`, `CreateImage`,
  `CopyImage`, `RegisterImage`, `CreateTags`, `Describe*`, `CreateKeyPair`,
  `DeleteKeyPair`, `CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`,
  `DeleteSecurityGroup`, and `iam:CreateRole`, `PutRolePolicy`,
  `CreateInstanceProfile`, `AddRoleToInstanceProfile`, `PassRole` with their
  deletes. Packer creates a key pair and a security group even though it never
  connects, and a temporary instance profile for the build instance. The VM
  boundary denies the image routes on purpose; this is the operator's role.
- A VPC with egress in the build region, or `SUBNET=subnet-…` naming a subnet
  that has it.

## 3. Build

```bash
cd cinc && make ami
```

Optional knobs: `POLICY=<name>` (default `dev-vm`), `VOLUME=<gb>` (default
20), `SUBNET=<subnet-id>`, `INSTANCE_TYPE=<type>` (default `t3.large`).

`make ami` refuses, with a message that names the cause, when:

- `PIN_CHECK` is set (the image feeds every VM, so the pin must verify);
- `pin-check` fails;
- production is not the lock's revision;
- a VM's volume is smaller than the image;
- the gzipped user data exceeds 16 KB;
- `vms/` state has no `bootstrap_user_data`.

Expect 15 to 30 minutes. It reads the build inputs from `vms/`, launches one
instance that converges the production revision through the signed path and
scrubs itself, snapshots it, and copies the image to every region the tenant
configures. On success it prints one `<region> <ami-id>` line per region and
the two `tfvars` lines for step 5.

If it times out, no image was registered and Packer has cleaned up. The
build instance's serial console holds the bootstrap log:

```bash
aws ec2 get-console-output --instance-id <build-instance-id> --latest --region <region> --output text
```

The scrub refuses to power off a VM whose last converge was not this revision,
so a failed converge shows up as a timeout, never as a bad image.

**Known limitation.** The bootstrap that `make ami` bakes comes from Terraform
state, not from the working tree. After a platform pin bump, run
`terraform apply` (the operator's step, after the plan is approved) before
`make ami`; otherwise the image boots the previous pin's bootstrap while its
`PlatformSha` tag names the new one.

## 4. Check

```bash
aws ec2 describe-images --owners self --filters 'Name=name,Values=dev-vm-*' \
  --query 'sort_by(Images,&CreationDate)[-1].Tags' --region <region>
```

`RevisionId` must equal the production revision `make preflight` printed, and
`CookbookVersion` must equal `cookbook_locks.base.version` in
`cinc/policyfiles/dev-vm.lock.json`. Anything else → stop and report it; do not
switch the fleet to that image. Check every region the build reported.

## 5. Switch

Edit `vms/tenant.auto.tfvars`:

```hcl
ami_owners       = ["self"]
ami_name_pattern = "dev-vm-dev-vm-*"   # dev-vm-<POLICY>-*
```

Then:

```bash
cd vms && terraform plan
```

Expect **no replacement of running VMs**: the module ignores AMI changes on
existing instances, so the switch decides only what *new* VMs launch with. A
plan that replaces an instance is not this change; stop and report it. A
`no matching AMI` failure means a region has no image; the build copies to
every configured region, so check step 4 there. Show the plan. The operator
applies it.

## 6. Test VM

Create one staging VM as `AGENTS.md` describes (*Create a VM*, with
`policy_group = "staging"`). Its first converge is short because the image is
already converged. Over EC2 Instance Connect, `sudo systemctl status
cinc-client` shows green. Tear the test VM down afterwards if it was only for
this; remember step 3 of *Delete a VM* if anyone logged it into the tailnet.

## 7. Rebuild

Rebuild after each promote of a new `base-` release, and at least monthly, so
new VMs do not start on old packages. `cd cinc && make preflight` warns at 35
days. A rebuilt image changes nothing for running VMs; they converge from
the signed envelope as always.

## 8. Clean up

Keep the newest two images. List them per region, then deregister the older
ones and delete their snapshots, in every region:

```bash
aws ec2 describe-images --owners self --filters 'Name=name,Values=dev-vm-*' --region <region> \
  --query 'sort_by(Images,&CreationDate)[].[ImageId,Name,CreationDate,BlockDeviceMappings[0].Ebs.SnapshotId]' \
  --output text
aws ec2 deregister-image --image-id <old-ami> --region <region>
aws ec2 delete-snapshot --snapshot-id <old-snapshot> --region <region>
```

Never deregister an image a pinned `ami_id` names:

```bash
grep -n 'ami_id' vms/instances.auto.tfvars
```

Show the operator the list before deleting; deregistering cannot be undone.

## Hard limits

- Never `terraform apply`. Show the plan; the operator applies.
- Never build from staging, and never edit the template's `PolicyGroup`: one
  image feeds both groups, so it is built from production only.
- Never share an image outside the account (no launch permissions, no
  public flag).
- Never run Packer by hand. `make ami` is the only path; it carries the gates
  a hand-written invocation skips.
- Never print a secret's value; report exit status.
