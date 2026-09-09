# Per-VM scoped AWS access — phase A: per-VM identity and same-account grants

> Design record, written during development; identifiers anonymised. Numbers are as measured.

**Status:** Design — pending user review
**Date:** 2026-07-28
**Scope:** Give each developer VM its own bounded AWS identity, reachable by the developer's shell and by rootless Docker containers without static keys, with permissions declared per VM in `vms/instances.auto.tfvars` and referenced by ARN. Same-account managed policies only. Cross-account role chaining is deferred to phase B (see *Deferred to phase B*).

**Revision note:** this document was rewritten after an architecture review. Findings that changed the design are recorded in *Review corrections* at the end, including two claims in the first draft that were simply wrong.

## Background

Today all developer VMs in a region share one IAM role. `vms/modules/ec2/iam.tf:4` creates `${environment}-${region}-ec2-role` with a single inline policy granting `ssm:GetParameter` on exactly two SecureStrings — the CINC validator key and the Wazuh authd password — and `vms/modules/ec2/main.tf:84` attaches its instance profile to every instance in that region.

Three existing facts constrain any solution:

1. **Developers cannot reach IMDS at all.** `cinc/cookbooks/base/recipes/imds.rb` installs iptables `OUTPUT` rules that `DROP` everything destined for `169.254.169.254` except traffic owned by uid 0 and by the `ec2-instance-connect` user. This is deliberate: the instance role can read both bootstrap secrets, so exposing its credentials to a developer would leak them.
2. **The `ubuntu` user has no sudo.** `cinc/cookbooks/base/recipes/sudoers.rb` removes it from `sudo` and `admin` and deletes its sudoers fragments. Privileged work happens as the separate `admin` user, reachable only via EC2 Instance Connect.
3. **Docker is rootless.** `cinc/cookbooks/base/recipes/docker.rb` disables the system daemon and installs rootless Docker for `ubuntu` with slirp4netns. Container egress is owned by `ubuntu`'s uid, so the IMDS `DROP` rule applies to containers too. Independently, `http_put_response_hop_limit = 1` (`vms/modules/ec2/main.tf:93`) would block IMDS from a bridged container regardless.

Because of (1) the shared role is unusable for developer-facing access, and because of (2) and (3) a developer-facing credential must be produced by a root-owned component and handed to `ubuntu` through the filesystem. Fact (3) is what settles the design: a root-mediated credential file is required by the container requirement no matter what, so opening IMDS buys nothing and would only cost us the protection in (1).

Permissions on the resource side are owned by the teams that own those resources. This repository must not grow copies of them.

## Goal

After this work, granting a developer VM access to an AWS resource in our own account is:

1. Add the bundle to `vms/access_bundles.auto.tfvars` once, if it does not exist yet.
2. Add its name to that VM's `aws_access` list in `vms/instances.auto.tfvars`.
3. `cd vms && terraform plan && terraform apply`.
4. Within one CINC converge (≤30 min, or immediately via `sudo cinc-client` as `admin`), the developer runs `aws s3 ls s3://example-media/dev-prefix/` with no keys, no `aws configure`, and no environment setup.

And these must hold afterwards:

- CloudTrail attributes every call to a specific VM.
- A developer on VM `alice` cannot present themselves as VM `otherdev`.
- A developer still cannot read the CINC validator key or the Wazuh authd password — **and no bundle, however badly authored by its owner, can grant them that.**
- A bundle's reach cannot extend past the AWS services its entry in this repository names, whatever its policy actually contains.
- A developer cannot use the broker to obtain write access anywhere, including inside the broker's own output directory.

## Non-goals

- **Defining the policies referenced by bundles.** Owned by resource teams; we reference ARNs. But their *authority* is capped by us — see *Bounding the identity role*.
- **Cross-account access and role chaining.** Phase B.
- **Per-human attribution.** Attribution is per-VM by design. VMs are named after a person, but not one-per-person — one developer may hold several across regions, and the current fleet already does. Correlating a VM to a human at a point in time is a Wazuh sshd-log query, documented as an incident procedure.
- **Replacing SSH keys with EC2 Instance Connect.** Attractive — `ssh.rb:46` already sets `AuthorizedKeysCommand` generically over `%u`, so EIC works for `ubuntu` today and only `aws_key_pair` keeps static keys alive. But it touches `ssh_keys.tf`, security-group rules, possibly EIC Endpoint and the network design, plus developer-laptop tooling and Cursor/VSCode Remote-SSH compatibility that must be tested rather than assumed. Separate spec.
- **Changing `http_put_response_hop_limit`.** Not needed; containers read a file.

## Architecture

### Two roles per VM

| Role | Attached to | Permissions | Reachable by |
|---|---|---|---|
| `dev-vm-boot-<name>-<region>` | instance profile | `ssm:GetParameter` on the CINC validator key, the Wazuh authd password, and this VM's access parameter; `sts:AssumeRole` + `sts:SetSourceIdentity` on this VM's identity role | root only (uid 0, via `imds.rb`) |
| `dev-vm-id-<name>-<region>` | nothing — assumed by the broker | whatever the VM's bundles declare, capped by a permissions boundary | `ubuntu` and its containers |

The two families get **disjoint name prefixes** (`dev-vm-boot-` / `dev-vm-id-`) so that any future prefix-matching grant cannot accidentally select the root-reachable bootstrap role. Phase B's resource-owner contract depends on this.

The identity role holds no SSM permissions of its own, so handing its credentials to a developer leaks nothing by construction. `max_session_duration = 3600`; using instance-profile credentials to call `AssumeRole` is role chaining, which AWS caps at one hour regardless of this setting.

The bootstrap role becomes **per-VM**, not per-region. To be precise about why, since a shared bootstrap role is not reachable by a developer either: the difference appears when a developer obtains root on their own VM (kernel exploit, rootless-container escape — a narrow path, not a closed one). With a shared bootstrap role they could then assume the identity role of *every* VM in the region. With per-VM roles they can assume only their own, which they already held.

Note the limit of that claim: the **AWS** blast radius stays at one VM, but every per-VM bootstrap role still reads the region-shared CINC validator key and Wazuh authd password, so root on any VM still yields two fleet-scoped enrolment secrets. That residual is pre-existing and out of scope here, but it must not be read as contained.

Per-VM is chosen mainly because it is nearly free: the resources are a `for_each` over the same `var.instances` map the module already iterates, so code size is unchanged and the only cost is the role count.

### Bounding the identity role

The identity role receives managed policies written by other teams, and its credentials are deliberately handed to an unprivileged user. Without a cap, every security property above would be a property of other teams' policy hygiene rather than of this design. Concretely, a well-meaning "read our app config" policy containing `ssm:GetParameter` on `parameter/*` would hand the developer the CINC validator key; `ec2:RunInstances` + `iam:PassRole` would let them boot an instance with the bootstrap profile and read both secrets as root.

So every identity role gets a Terraform-managed `permissions_boundary`, one per VM.

A boundary grants nothing on its own. Effective permissions are **identity policies ∩ permissions boundary ∩ SCP** — the third term belongs in that formula and is invisible from this repository, so a call can be refused by an organization policy that no change here can influence. See the *Error handling* row on SCPs.

A boundary grants nothing. Effective permissions are the intersection of the role's attached policies and the boundary, so the boundary's only job is to define a ceiling — and a role with a wide-open boundary and no attached policies still has no permissions at all. Least privilege for the identity role is delivered by the bundle policies attached to it, which start out as none.

That makes the boundary's shape a question about the *ceiling*, and the ceiling is what limits an externally authored policy that grants more than we expected. So it is a closed-ended allow list: **only the action namespaces this VM's own bundles declare**, plus an explicit deny list as a second layer.

```hcl
Statement = [
  {
    Sid    = "AllowOnlyDeclaredNamespaces"
    Effect = "Allow"
    # union of allowed_actions across this VM's bundles, plus sts:GetCallerIdentity.
    # A VM with aws_access = [] gets only the latter — i.e. no authority at all.
    Action   = ["sts:GetCallerIdentity", "s3:*"]
    Resource = "*"
  },
  {
    Sid    = "DenyEscalationAndBootstrapSecrets"
    Effect = "Deny"
    Action = [
      "iam:*",
      "organizations:*",
      "sts:AssumeRole",
      "ssm:GetParameter*",
      "ssm:StartSession",
      "ssm:SendCommand",
      "ssm:StartAutomationExecution",
      "ssm:PutParameter",
      "ssm:DeleteParameter*",
      "ssm:CreateAssociation",
      "ssm:UpdateAssociation",
      "ec2-instance-connect:*",
      "ec2:GetPasswordData",
      "ec2:RunInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:AssociateIamInstanceProfile",
      "ec2:ReplaceIamInstanceProfileAssociation",
      "ec2:CreateImage",
      "ec2:ModifyImageAttribute",
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:CopySnapshot",
      "ec2:ModifySnapshotAttribute",
      "ec2:CreateVolume",
      "ec2:CreateReplaceRootVolumeTask",
      "ec2:StopInstances",
      "ec2:DetachVolume",
      "ec2:AttachVolume",
      "ebs:ListSnapshotBlocks",
      "ebs:ListChangedBlocks",
      "ebs:GetSnapshotBlock",
      "ebs:StartSnapshot",
      "ebs:PutSnapshotBlock",
      "ebs:CompleteSnapshot",
      "ec2:CreateNetworkAclEntry",
      "ec2:ReplaceNetworkAclEntry",
      "ec2:DeleteNetworkAclEntry",
      "ec2:ReplaceNetworkAclAssociation",
      "ec2:CreateRoute",
      "ec2:ReplaceRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:DisassociateRouteTable",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:TerminateInstances",
      "ec2:RebootInstances",
      "ec2:GetConsoleOutput",
      "ec2:GetConsoleScreenshot",
    ]
    Resource = "*"
  },
]
```

The two statements are not redundant; they defend against different failures.

**The allow list handles what we did not think of.** A bundle's policy is written by someone else and may grant more than its `description` claims — by accident, or because its author widened it for their own consumers. Anything outside the namespaces that bundle declared is denied by omission, without anyone having had to anticipate it. This is the property a deny list structurally cannot have.

`sts:GetCallerIdentity` is in the list only so the document stays valid for a VM with no bundles: an IAM statement needs a non-empty `Action`. It is not a grant — AWS requires no permissions for that call and an explicit deny cannot block it either. So the floor really is zero.

**The explicit deny handles three things the allow list cannot.**

1. **Inside a service the bundle legitimately declared, the allow list is silent.** This is the one that matters most in practice. A bundle declaring `allowed_actions = ["ec2:*"]` raises the ceiling to all of EC2, and from there the escalation paths have to be enumerated — the allow list offers nothing. So the deny list is not a legacy layer; it is the whole control for any bundle that names a service with privileged actions in it. See *Declaring a privileged namespace is a security review* below.
2. **A resource-based policy naming the assumed-role *session* ARN escapes an implicit deny.** AWS's permissions-boundary evaluation rules distinguish the two: a resource policy granting to the *role* ARN **is** limited by an implicit deny in a boundary, but permissions granted directly to a *session* are not. That case is unusually reachable in this design, because the session ARN is fully predictable — `arn:aws:sts::<account>:assumed-role/dev-vm-id-<vm>-<region>/<vm>`, with the session name pinned to the VM name by the trust policy. An explicit `Deny` still applies.
3. **An explicit `Deny` beats every allow anywhere**, which also catches a careless widening on our own side: `allowed_actions = ["iam:*"]` is a visible line in a reviewed file, but it is refused even if the review misses it.

An earlier draft of this section justified the deny layer by claiming that an omission from `Allow` does not cap resource-based policies at all. That is wrong for the role ARN and right only for the session ARN; the layer survives, the reasoning did not. See correction 26.

Every deny entry is a path from "developer holds identity-role credentials" to either root on the VM or the two fleet-scoped bootstrap secrets. The non-obvious ones:

- **`ssm:GetParameter*` is a wildcard, not an enumeration.** It has to cover `GetParameterHistory`, which returns each historical `Value` and honours `--with-decryption` — so it reads the CINC validator key exactly as well as `GetParameter` does. Enumerating three action names, as an earlier draft did, left that open to any bundle carrying a routine `ssm:Get*` for app config. It is denied outright rather than scoped to the two bootstrap paths because the identity role has no legitimate Parameter Store need in phase A, and a blanket deny cannot be defeated by a path-matching mistake.
- **`ec2-instance-connect:*` and `ec2:GetPasswordData`.** `ssh.rb:46` sets `AuthorizedKeysCommand` to the EIC helper over `%u`, and `ssh.rb:22` gives the `admin` user `NOPASSWD:ALL`. So `send-ssh-public-key --instance-os-user admin` followed by `ssh` is root on this VM in two commands, with no `PassRole` anywhere for `iam:*` to catch.
- **`ec2:ModifyInstanceAttribute`** rewrites the user data of an instance that *already* carries a bootstrap instance profile, so it needs no `iam:PassRole` and `ec2:RunInstances` does not cover it. cloud-init's `once-per-instance` semaphore means a plain script is not re-run on stop/start, but a `#cloud-boothook` payload runs on every boot regardless — so a rewrite plus a stop/start is root on the VM with the live bootstrap role.
- **`ec2:CreateImage` and `ec2:ModifyImageAttribute`** reproduce the snapshot path around every snapshot action: `CreateImage` needs only `ec2:CreateImage`, and sharing the resulting AMI to an account the developer controls needs only `ModifyImageAttribute`. Denying `CreateSnapshot` alone was an enumeration mistake of the same kind as the earlier `ssm:GetParameter` one.
- **The snapshot and volume actions.** Snapshot or copy the root volume, share it, mount it on a machine the developer controls, and read `/etc/cinc/client.pem` and `/var/ossec/etc/client.keys` straight off disk — no running process to intercept.
- **`ssm:PutParameter` and `ssm:DeleteParameter*`** are integrity, not confidentiality: overwriting the validator-key parameter does not reveal it but does break enrolment for every VM created afterwards.
- **`ssm:CreateAssociation` and `ssm:UpdateAssociation`** are remote root execution on a managed instance via `AWS-RunShellScript`, in the same class as `SendCommand`. Not exploitable today — the bootstrap role carries no `AmazonSSMManagedInstanceCore`, so the agent is unregistered — but that is a property of a policy that could change, not of this boundary.
- **`sts:AssumeRole`** is denied because phase A has no chaining at all; that also blocks pivoting into another VM's identity role. Phase B replaces it with a deny scoped to `role/dev-vm-*`.
- **EBS direct APIs (`ebs:GetSnapshotBlock` and siblings), fleet network mutation, `TerminateInstances`, and `GetConsoleOutput`** — added after the first external review. The EBS direct API reads a snapshot's blocks without calling any of the denied `ec2:` snapshot actions; network ACL and route changes cut the fleet's Loki egress, which is the one failure the alerts cannot see; the console carries a failed bootstrap's log. Fourth, fifth and sixth omissions of the multi-call-path shape, found by an outside reviewer rather than a test.

A boundary constrains a role's permissions but not its trust policy — fine here, since the identity role's trust names only its own bootstrap role.

If a bundle ever legitimately needs one of the denied actions, the boundary is the thing that must change, deliberately and in review. That is the point.

### Declaring a privileged namespace is a security review

The allow list makes an *undeclared* service safe. It does nothing for a service a bundle declares — inside `ec2:*` or `ssm:*` the deny list is the only control, which is why the list above is long and why it is worth re-reading whenever a bundle names one of those services.

Four namespaces have no legitimate use in a developer bundle in phase A and are rejected outright by a `validation` block on `access_bundles`, so the mistake cannot reach the boundary at all: `iam`, `sts`, `organizations` and `ec2-instance-connect`. Declaring `ec2` or `ssm` is permitted, because `ec2:Describe*` and Session Manager are plausible needs, but it widens the ceiling to a service that contains root-equivalent actions. Those bundles are a security review, not a configuration change, and `vms/README.md` says so.

The boundary is per-VM rather than one shared policy per region, because a shared ceiling is the union of every bundle in the catalog: a VM granted only `s3-media-dev` would be capped at the namespaces *all* bundles declare, and the check would weaken as the catalog grows. Per-VM keeps the ceiling equal to what that VM actually asked for. The cost is one managed policy per VM instead of one per region, which is immaterial against the 1500-policy account quota, and a policy-version wrinkle noted under *Error handling*.

### Bundle catalog

A new committed file `vms/access_bundles.auto.tfvars` is the only place external ARNs appear:

```hcl
access_bundles = {
  "s3-media-dev" = {
    description     = "RW on s3://example-media/dev-prefix/*"
    policy_arns     = ["arn:aws:iam::111122223333:policy/s3-media-dev"]
    allowed_actions = ["s3:*"]
  }

  "observability-ro" = {
    description     = "CloudWatch Logs read-only"
    policy_arns     = ["arn:aws:iam::111122223333:policy/observability-ro"]
    allowed_actions = ["logs:*"]
  }
}
```

`allowed_actions` is the bundle's declaration of the ceiling it needs, and it is required — a bundle that declares nothing grants nothing, which is always a mistake rather than a valid configuration. Three constraints are enforced at plan time: entries must look like `service:Action` (a bare `s3` is a malformed policy document that would otherwise fail late with an opaque `MalformedPolicyDocument`); the literal `"*"` is rejected outright, since it would silently turn the ceiling back into the open-ended shape this design exists to avoid; and the `iam`, `sts`, `organizations` and `ec2-instance-connect` namespaces are rejected, since each is a direct escalation path with no legitimate developer use in phase A.

Note what `allowed_actions` is *not*: it is not a second copy of the policy's grants, and it does not need to be minimal at the action level. `s3:*` is a fine declaration for a bundle whose policy grants three S3 actions on one prefix — the policy is still the thing that decides. The declaration only has to be honest about which services are in play, because that is the axis along which an unexpected grant becomes dangerous.

It does have to name **every** service in play, including the ones the caller never mentions by name. The common case is a KMS-encrypted S3 bucket: `aws s3 cp` needs `kms:Decrypt` on the bucket's key, so a bundle declaring only `s3:*` produces a KMS `AccessDenied` on an object read while `aws s3 ls` works fine. That is the most likely first-day failure of this design, and the reason `allowed_actions` must be derived from reading the policy document rather than from the bundle's description.

IAM groups are not an option for this — groups contain only users, never roles. A managed policy also cannot be attached across accounts, which is why phase A is same-account only and why phase B needs a different mechanism entirely.

### Per-VM attachment

`vms/instances.auto.tfvars` gains one optional field per VM:

```hcl
"alice" = {
  instance_type  = "m7a.xlarge"
  volume_size_gb = 100
  az             = "eu-central-1a"
  fqdn           = "alice.ec2.eu-central-1.example.com"
  key_name       = "alice"
  aws_access     = ["s3-media-dev"]
  tags           = { Owner = "alice", idlefy = "enabled" }
}
```

`aws_access` is `optional(list(string), [])`, so the two existing VM entries need no edit. An empty list yields an identity role with no permissions — still created, so `aws sts get-caller-identity` behaves uniformly on every VM.

A name absent from `access_bundles` fails at `plan` time. Without that check Terraform would build a role with no permissions and the failure would surface later as an opaque `AccessDenied`.

### Handoff from Terraform to the VM

Terraform writes one SSM parameter per VM, `/developer-vms/access/<vm-name>` (Parameter Store is already regional, so the region does not belong in the path):

```json
{
  "identity_role_arn": "arn:aws:iam::111122223333:role/dev-vm-id-alice-eu-central-1",
  "session_name": "alice",
  "region": "eu-central-1"
}
```

Type `String`, not `SecureString`: it holds an ARN and a VM name, no secrets, so the broker needs no `kms:Decrypt`. The VM's bootstrap role gets read access to exactly this parameter.

This reuses the channel the VM already depends on — no new Terraform-to-CINC integration — and stays out of the developer's reach because IMDS does. Instance tags were considered instead, since `instance_metadata_tags` is already enabled and `PolicyName` travels that way; rejected because a tag value caps at 256 characters and phase B's profile list would exceed it.

### Credential broker on the VM

A new recipe `base::aws_access` installs a root-owned script and a systemd timer.

**Output directory ownership is a security boundary, not a convenience.** `/dev/shm/dev-vm-aws` is `root:ubuntu 0750` and its files are `root:ubuntu 0640`. The developer gets read and traverse; they cannot create, rename or unlink entries. Had the directory been `ubuntu`-owned, a developer could pre-place `credentials.tmp` as a symlink to `/etc/sudoers.d/00-pwn` and wait for the root timer to follow it — turning the broker into a root-write primitive and defeating the whole design. Because the directory excludes the developer, staging a temp file inside it and `rename(2)`-ing over the target is safe and atomic.

**The directory is `/dev/shm/dev-vm-aws`, not `/run/aws-vm`, and this is not cosmetic.** Rootless Docker is started by RootlessKit with `copy-up=/run`, which gives the daemon a private tmpfs at `/run` inside its own mount namespace. A bind mount of `/run/aws-vm` into a container therefore resolves to an empty directory. Since rootless containers cannot reach IMDS either, that combination left them with no route to credentials at all — which removes one of the two reasons this broker exists. `/dev/shm` is also tmpfs, so credentials still never touch persistent disk and do not survive a reboot, and it is not copied up, so containers see it live.

**Because `/dev/shm` is mode 1777, the directory must be verified rather than assumed.** Unlike root-owned `/run`, the developer can create entries in `/dev/shm`, so they could in principle create `dev-vm-aws` before `systemd-tmpfiles` does and own it. `systemd-tmpfiles` runs early in boot and wins that race in practice, and `/dev/shm`'s sticky bit then prevents the developer removing or renaming a root-owned directory — but "in practice" is not a security argument, and the failure would be silent. The broker therefore checks, before publishing, that the output directory is a real directory rather than a symlink, is owned by the process doing the writing, and is not writable by anyone else; it refuses and exits non-zero otherwise. Stating the property as "the writer owns it" rather than "root owns it" is deliberate: it is correct under root and it is also assertable by the unprivileged test harness.

Phase A creates no chained sessions, so the AWS CLI's `~/.aws/cli/cache` (which caches `source_profile` assume-role results on disk) never comes into play; phase B must revisit that claim.

**The script**, `/usr/local/sbin/aws-vm-credentials` (root:root 0700). CINC templates in the VM name, region and `ubuntu`'s gid at converge time, resolved the same way `base::docker` already resolves the uid — the broker must not have to guess its own identity from `hostname`, which a later `hostnamectl` would silently break:

```bash
#!/usr/bin/env bash
set -euo pipefail

VM_NAME='<%= @vm_name %>'
REGION='<%= @region %>'
UBUNTU_GID='<%= @ubuntu_gid %>'

PARAM="/developer-vms/access/${VM_NAME}"
OUT_DIR=/dev/shm/dev-vm-aws

umask 027

json=$(aws ssm get-parameter --name "$PARAM" --region "$REGION" \
         --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "access parameter $PARAM not readable — leaving any existing credentials in place"
  exit 0
}

role_arn=$(jq -er '.identity_role_arn' <<<"$json")
session=$(jq -er '.session_name'      <<<"$json")

# A freshly created role is not immediately assumable (IAM is eventually
# consistent), so retry briefly rather than waiting for the next timer tick.
for attempt in 1 2 3 4 5; do
  if creds=$(aws sts assume-role \
      --role-arn "$role_arn" \
      --role-session-name "$session" \
      --source-identity "$session" \
      --duration-seconds 3600 \
      --region "$REGION" \
      --output json 2>&1); then
    break
  fi
  [ "$attempt" = 5 ] && { echo "assume-role failed: $creds" >&2; exit 1; }
  sleep $((attempt * 5))
done

tmp=$(mktemp "$OUT_DIR/.credentials.XXXXXX")
trap 'rm -f "$tmp"' EXIT
chown "root:$UBUNTU_GID" "$tmp"
chmod 0640 "$tmp"

jq -er '
  "[default]",
  "aws_access_key_id = "     + .Credentials.AccessKeyId,
  "aws_secret_access_key = " + .Credentials.SecretAccessKey,
  "aws_session_token = "     + .Credentials.SessionToken
' <<<"$creds" > "$tmp"

mv -f "$tmp" "$OUT_DIR/credentials"
trap - EXIT
```

`jq` needs no new dependency — `base::packages` installs it and runs first in `default.rb`. On any failure the previous file is left intact; a partial or truncated credentials file is impossible because the rename is the only publishing step.

**The units.** `aws-vm-credentials.service`:

```ini
[Unit]
Description=Refresh scoped AWS credentials for the developer user
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aws-vm-credentials
```

`aws-vm-credentials.timer`:

```ini
[Unit]
Description=Refresh scoped AWS credentials every 15 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=15min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

`Persistent=true` is deliberately absent: it only affects `OnCalendar=` timers and would be misleading here. `network-online.target` ordering matters because at `OnBootSec=30s` the STS call can otherwise precede a working default route. The directory itself comes from `systemd-tmpfiles` rather than the recipe, so it exists after a reboot independent of converge order:

```
d /dev/shm/dev-vm-aws 0750 root ubuntu -
```

Sessions last an hour and refresh every 15 minutes, so three consecutive failures pass before a developer sees an expired token. There is no automatic detection of a dead timer; *Verification* includes a staleness check, and a Wazuh rule on the credentials file's mtime is noted as follow-up work rather than designed here.

**A limitation that has to be stated, not discovered:** refresh works for anything that starts a new process, which is why the AWS CLI never sees an expiry — it re-reads the file on every invocation. It does **not** work for a process that is already running. An SDK resolves shared-file credentials once and treats them as static: botocore's and the Go v2 SDK's shared-credentials providers both do, and the Java v2 SDK re-reads the profile only on an explicit opt-in. So a Python worker, a notebook kernel or a `docker run -d` container started at 10:00 begins failing with `ExpiredToken` at 11:00 and never recovers, while `aws sts get-caller-identity` in the shell beside it works and the timer, the journal and the file's mtime all look healthy. That is precisely the "everything looks fine" signature this design worked to eliminate elsewhere, so it belongs in `vms/README.md` with the workaround (restart the process, or re-create the client) rather than in a support conversation.

The durable fix is `credential_process` pointing at a small root-installed helper that prints the current credentials as JSON with an `Expiration` field: SDKs treat that as refreshable and re-invoke it on expiry. It is deferred to phase B because it is a profile setting, so it lands together with the `AWS_CONFIG_FILE` shadowing problem phase B already has to solve. Whether every SDK in use honours it is not asserted here.

### Reaching the credentials

Phase A needs no `AWS_CONFIG_FILE`: there are no profiles to render, only a default credential set and a region. This matters — setting `AWS_CONFIG_FILE` would not overwrite a developer's own `~/.aws/config` but would make it invisible, silently hiding any profile, region or SSO session they maintain there, with no file-mtime evidence that anything happened. Phase B introduces profiles and must solve that explicitly.

Because `zsh` is now the default shell for `ubuntu` while — as `base::shell_default` documents — Ubuntu's `/etc/zsh/zprofile` does **not** source `/etc/profile`, both shells have to be reached. The exports therefore live in **one** file, `/etc/dev-vm/shell-env.sh`, which `/etc/profile.d/dev-vm.sh` and `/etc/zsh/zshenv` each source with a single line:

```sh
_dev_vm_uid=${EUID:-$(id -u)}
if [ "$_dev_vm_uid" = "<ubuntu_uid>" ]; then
  AWS_SHARED_CREDENTIALS_FILE=/dev/shm/dev-vm-aws/credentials
  AWS_DEFAULT_REGION=<region>
  AWS_REGION=<region>
  export AWS_SHARED_CREDENTIALS_FILE AWS_DEFAULT_REGION AWS_REGION
fi
unset _dev_vm_uid
```

One file rather than two copies, because duplicating a security-relevant gate across two recipes at opposite ends of the run list is how it drifts. `${EUID:-$(id -u)}` serves both: zsh sets `EUID` as a builtin so there is no subprocess, and dash — which does **not** define `EUID`, and would therefore have silently skipped a `$EUID`-only gate entirely — falls back to `id -u`.

Both region spellings are exported: the AWS CLI and boto3 read `AWS_DEFAULT_REGION`, while the Go SDK v2 and JS SDK v3 read only `AWS_REGION`.

The file is sourced system-wide, hence the uid gate: `admin`'s own login shell would otherwise inherit `AWS_SHARED_CREDENTIALS_FILE` pointing at a file its uid cannot read, so every `aws` call as `admin` would fail on an unreadable credentials file instead of failing on IMDS — a confusing error in place of the correct one.

An earlier draft justified the gate differently, claiming that without it anything under `sudo` would silently use the identity role and break `base::wazuh_agent`. That is false: Ubuntu's `/etc/sudoers` ships `Defaults env_reset` and this cookbook adds no `env_keep`, so the variable does not survive `sudo` either way. The gate is still correct, for the reason above. See correction 27.

One residual to document for developers: `AWS_SHARED_CREDENTIALS_FILE` does not overwrite a developer's own `~/.aws/credentials` — no root process touches it — but it does stop it being consulted. Much smaller than the `~/.aws/config` case, since a developer on these VMs has no reason to keep their own credentials file, but it needs saying, along with the `unset` escape hatch.

There is deliberately **no test for the file's existence** in the gate. Environment is fixed at shell start, so combining "does the file exist right now" with a static export would make a whole day's session depend on a boot race: a VM restarted by Idlefy whose editor reconnects at boot+20s, before `OnBootSec=30s`, would leave that session and every terminal it forks without credentials while `/dev/shm/dev-vm-aws/credentials` sits there perfectly valid. Exporting a path to a not-yet-existing file behaves exactly like not setting it, so there is nothing to guard against.

The CINC timer is unaffected either way: systemd units source neither file.

### Containers

```bash
docker run --rm \
  -v /dev/shm/dev-vm-aws:/aws:ro \
  -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials \
  -e AWS_DEFAULT_REGION=eu-central-1 \
  amazon/aws-cli sts get-caller-identity
```

Mounting the **directory** rather than the file is also load-bearing. Publishing is a `rename(2)` over the target, so `-v /dev/shm/dev-vm-aws/credentials:/aws/credentials` binds the original inode and the container keeps reading a file nobody updates — it works for an hour and then expires, which is the worst possible failure shape. Mount the directory and let the container resolve the name each time.

**Access is governed by the container's gid, not its uid, and the default is already correct** — so no `--user` is needed and the only way to break it is to set an explicit group. Measured on a real VM: inside the container the file appears as `65534:0` mode `0640`. The host's `root` is outside the rootless uid mapping and surfaces as the overflow uid, making the owner bits unreachable, while the host group `ubuntu` — the user running the daemon — maps to container **gid 0**. Every read therefore comes through the group bit.

| `--user` | uid:gid inside | Can read |
|---|---|---|
| omitted | `0:0` | yes |
| `--user 0` | `0:0` | yes |
| `--user 1234` | `1234:0` | yes — gid still defaults to 0 |
| `--user 1234:1234` | `1234:1234` | **no** |
| `--user 1234:0` | `1234:0` | yes |

So an image running as a non-root uid (`node:*`, distroless `nonroot`, `-u $(id -u)`) still works; what fails is an explicit `uid:gid` pair, and the fix is to drop the group half rather than to force uid 0. An earlier draft of this spec asserted that `--user 0` was a requirement, which would have pushed every compose file on the fleet to run as root for no reason.

Note also that `docker.rb:69-73` appends `DOCKER_HOST` to `~/.bashrc` only, while `shell_default.rb` makes zsh the login shell. Whether `docker` works at all in a fresh zsh session is a pre-existing question this spec does not fix, but *Verification* must not assume it.

### End-to-end flow

1. Operator edits the bundle catalog and/or a VM's `aws_access`, runs `terraform apply`.
2. Terraform creates or updates the two roles, the boundary, the policy attachments and the VM's SSM parameter.
3. The CINC timer fires (≤30 min). `base::aws_access` converges the script, units and environment files.
4. The systemd timer runs as root: read parameter → assume identity role with session name and source identity → publish `/dev/shm/dev-vm-aws/credentials`.
5. Developer runs `aws s3 ls s3://example-media/dev-prefix/`.

## Audit model

Every call made with the identity role appears in CloudTrail as:

```
userIdentity.arn                            = arn:aws:sts::111122223333:assumed-role/dev-vm-id-alice-eu-central-1/alice
userIdentity.sessionContext.sourceIdentity  = alice
```

The field path matters: source identity is at `userIdentity.sessionContext.sourceIdentity` on action events, and at `requestParameters.sourceIdentity` on the `AssumeRole` event itself. There is no `userIdentity.sourceIdentity`, and a query written against that path returns zero rows — which reads exactly like propagation being broken.

`SourceIdentity` is immutable for the life of the session, so it cannot be rewritten by anything the developer does. In phase A both sides of the only hop are ours, so it costs nothing to set. Phase B changes that materially — see below.

Attribution is per-VM, not per-authorization: two VMs granted the same bundle have byte-identical authority. The guarantee is "who made this call", not "who could have".

**Why the SSM parameter can be treated as untrusted input.** The broker reads its role ARN and session name from `/developer-vms/access/<vm>`, which is an odd thing for a security-critical component to trust. It holds up, and it is the trust policy that makes it hold — not the parameter's permissions:

- The identity role's trust policy conditions on `StringEquals { "sts:SourceIdentity" = <vm-name> }`, so a tampered parameter naming a different session identity produces `AccessDenied`, not laundered attribution.
- The bootstrap role's inline policy names a single identity-role ARN as its `Resource`, so a tampered parameter pointing at another VM's role produces `AccessDenied` too.

So the worst a writable parameter buys is denial of service against the VM's own credentials, which its owner can already achieve. This is the real answer to "can a developer present as another VM", and it is structural rather than resting on the verification step that checks it.

## Resolved: the boundary is an allow list

An earlier draft made the boundary `Allow *` plus a deny list, and recorded the shape as an open decision. It is now closed in favour of the allow list described under *Bounding the identity role*, for one reason: a deny list has to anticipate every escalation path, and on this specific list two were missed on the first attempt and found only in review (`ssm:GetParameterHistory`, and EIC-to-`admin`). That is a measured error rate on the exact artefact in question, not a hypothetical. There is no basis for believing a third does not exist, and no way to look for it except to think harder — which is what already failed twice.

The allow list inverts that — but only outside the declared namespaces. An unanticipated path in a service no bundle named is closed because it was never opened, so being wrong about the threat model costs nothing *there*. Inside a service a bundle does name, the deny list is still the only control and the original objection applies in full. That is why the deny list was hardened rather than trimmed, and why declaring `ec2` or `ssm` is treated as a review rather than a config change.

The cost is operational and it is real: a bundle that needs a new AWS service requires an edit to `access_bundles.auto.tfvars` and a `terraform apply` by someone with rights to this repository. That is accepted deliberately. It is also not pure overhead — it is the only point at which anyone in this repository learns that a bundle's reach has changed, which today happens invisibly in someone else's account.

The declaration lives on the bundle rather than in a single hand-maintained list in `iam.tf` so that the widening and the reason for it land in the same diff, and so that removing a bundle removes its ceiling automatically.

## Deferred to phase B

Phase B adds cross-account access via role chaining: `assume_roles` entries in bundles, rendered as named profiles, plus the contract other teams satisfy. It is deferred because all of the counterparty risk and all of the unverified AWS behaviour lives there, and none of it should be able to block phase A.

Phase B must **start** with an experiment against a throwaway role in our own account, because two behaviours the first draft asserted as fact are not safe to assume:

1. **`sts:SetSourceIdentity` is required on every hop, in both the caller's permissions policy and the target role's trust policy, or `AssumeRole` fails outright.** Since the broker sets source identity on hop 1, the label is already on the session, so hop 2 requires that permission in the *resource owner's* trust policy whether or not we mention source identity again. The contract therefore reads `"Action": ["sts:AssumeRole", "sts:SetSourceIdentity"]`, not `sts:AssumeRole` alone — otherwise every chained call returns `AccessDenied` and looks indistinguishable from a missing grant. The decision phase B must make: require that of every resource owner, or stop setting source identity and rest attribution on `RoleSessionName` alone.
2. **`sts:RoleSessionName` as a condition key in an *identity-based* policy is undocumented.** AWS documents it for role trust policies. The request context contains it, so an identity-policy condition ought to work, but "ought to" is not a basis for a control that prevents one developer impersonating another. Test it, and condition on `aws:SourceIdentity` as well so the guarantee does not rest on undocumented behaviour alone.

Phase B also inherits, and must resolve: `AWS_CONFIG_FILE` shadowing the developer's own `~/.aws/config`; the AWS CLI caching chained sessions to `~/.aws/cli/cache` on persistent disk, contradicting phase A's tmpfs property; profile-name collisions between two bundles granted to the same VM (including the reserved name `default`, which would silently replace the identity-role credentials); narrowing the boundary's `sts:AssumeRole` deny to `role/dev-vm-*`; and the resource-owner contract itself, where a prefix grant such as `ArnLike aws:PrincipalArn "…:role/dev-vm-id-*"` avoids per-VM churn but is only as strong as the guarantee that nobody else can create a role with that prefix.

## Changes

### 1. `vms/access_bundles.auto.tfvars` (new, committed)

The catalog. Ships with the bundles the team needs at implementation time.

### 2. `vms/variables.tf`

```hcl
variable "access_bundles" {
  description = "Named permission bundles referenced by instances[*].aws_access."
  type = map(object({
    description     = string
    policy_arns     = optional(list(string), [])
    allowed_actions = list(string)
  }))
  default = {}
}
```

With `validation` blocks rejecting an empty `allowed_actions`, the literal `"*"`, and entries that are not of the form `service:Action`.

Add `aws_access = optional(list(string), [])` to the `instances` object type.

### 3. `vms/modules/ec2/variables.tf`

Mirror both. Add a `validation` block rejecting instance keys that would break downstream constraints: source identity is 2–64 characters from `[\w+=,.@-]` and must not start with `aws:`, and `dev-vm-boot-<name>-<region>` must fit IAM's 64-character role-name limit, which caps `<name>` at about 34 characters for the longest current region name.

### 4. `vms/main.tf`

Pass `access_bundles = var.access_bundles` to all three module invocations.

### 5. `vms/modules/ec2/iam.tf`

Rewrite, `for_each = var.instances` throughout:

- `aws_iam_role.bootstrap` — `dev-vm-boot-<name>-<region>`, trusts `ec2.amazonaws.com`.
- `aws_iam_role_policy.bootstrap` — `ssm:GetParameter` on the CINC key, the Wazuh password and `/developer-vms/access/<name>`; `sts:AssumeRole` + `sts:SetSourceIdentity` on this VM's identity role.
- `aws_iam_instance_profile.bootstrap` — named `dev-vm-boot-<name>-<region>` to match its role, so the two are never confused during the rollout swap.
- `aws_iam_policy.identity_boundary` — one boundary policy per VM, `dev-vm-id-boundary-<name>-<region>`. Its `Allow` is that VM's declared namespaces; its `Deny` is the fixed escalation list.
- `aws_iam_role.identity` — `dev-vm-id-<name>-<region>`, `permissions_boundary` set to its own boundary policy, trusts only this VM's bootstrap role for `sts:AssumeRole` + `sts:SetSourceIdentity`, conditioned on `sts:SourceIdentity` equal to the VM name. `max_session_duration = 3600`.
- `aws_iam_role_policy_attachment.identity` — one per distinct policy ARN across the VM's bundles.

The region-shared `aws_iam_role.ec2`, `aws_iam_role_policy.ssm_read` and `aws_iam_instance_profile.ec2` are removed.

### 6. `vms/modules/ec2/access.tf` (new)

- `locals` resolving each VM's `aws_access` into a flattened, de-duplicated `policy_arns` set and, separately, into its de-duplicated `allowed_actions` union.
- `terraform_data` with a `lifecycle.precondition` rejecting unknown bundle names, listing offenders and valid names. (`terraform_data` rather than variable `validation` because cross-variable validation needs Terraform 1.9+ and `main.tf` pins `>= 1.5.0`.)
- `aws_ssm_parameter.access` — one `String` parameter per VM.

### 7. `vms/modules/ec2/main.tf`

`iam_instance_profile = aws_iam_instance_profile.bootstrap[each.key].name` — an in-place update on existing instances, not a replacement.

Add `depends_on = [aws_ssm_parameter.access, aws_iam_role.identity]`. Without it Terraform may create the instance, and `user_data` may run `cinc-client --once` including the broker, before the parameter or the role exists — reproducing exactly the first-boot race for which the `ec2:SourceInstanceARN` alternative was rejected.

### 8. `vms/outputs.tf`, `vms/modules/ec2/outputs.tf`

Expose per-VM identity role ARNs. Phase B hands this list to resource owners; in phase A it is the diagnostic answer to "which role is this VM".

### 9. `cinc/cookbooks/base/recipes/aws_access.rb` (new)

The templated script, the service and timer units, the `systemd-tmpfiles` fragment and `/etc/profile.d/aws-vm.sh`, all as specified above.

### 10. `cinc/cookbooks/base/recipes/shell_default.rb`

Extend the managed `/etc/zsh/zshenv` with the uid-gated export block, keeping the existing `~/.local/bin` stanza, and resolve `id -u ubuntu` for the gate.

Because the feature is now split across `base::aws_access` and `base::shell_default`, which sit far apart in the run list, the recipes must cross-reference each other in comments so the two halves do not drift.

### 11. `cinc/cookbooks/base/recipes/default.rb`

Add `include_recipe 'base::aws_access'`. The only real ordering constraint is that the AWS CLI already exists, which `user_data` guarantees, so any position after `base::packages` works; placing it next to `base::cinc_client` keeps related concerns together. It does **not** need to precede `base::docker` — that recipe neither reads nor mounts the broker output directory, and credentials are published asynchronously by the timer, not during converge.

### 12. `vms/instances.auto.tfvars`, `vms/README.md`, `CLAUDE.md`, `docs/runbook.md`

Document `aws_access`, the catalog, the container group rule and the boundary's role in reviewing new bundles. `CLAUDE.md` gains `aws_access` in "Create a VM". For "Delete a VM", the SSM parameter needs no manual cleanup — Terraform destroys it in the existing step 2 — but the docs should note that the identity role ARN is retired, and that recreating a VM with the same name produces a new role with a new unique ID, which invalidates any grant an owner made against the old one.

## Error handling

| Condition | Behaviour |
|---|---|
| `aws_access = []` | Identity role exists with no permissions — its boundary allows only `sts:GetCallerIdentity`, which needs no permission anyway. Broker publishes `[default]`. `aws sts get-caller-identity` works; everything else is `AccessDenied`. |
| A bundle's policy grants a service the bundle did not declare | `AccessDenied` by boundary omission, and the mismatch is the signal: either the policy is broader than its `description` says, or `allowed_actions` is stale. Fix by reading the policy, not by widening the declaration reflexively. |
| A declared service depends on an undeclared one | The call fails naming the *other* service — e.g. a KMS `AccessDenied` from `aws s3 cp` on an SSE-KMS bucket when the bundle declared only `s3:*`. Diagnose from the service named in the error, then add that namespace after confirming the policy actually grants it. `aws s3 ls` succeeding while `cp` fails is the signature. |
| A VM's `aws_access` has been changed five times | `terraform apply` may fail with `LimitExceeded` — an IAM managed policy holds at most five versions and each boundary edit creates one. Recover with `aws iam list-policy-versions --policy-arn <boundary-arn>` then `delete-policy-version` on the oldest non-default version, and re-apply. Harmless but not self-healing; whether the provider prunes automatically is not relied on here. |
| `allowed_actions` empty, `"*"`, or not `service:Action` | `terraform plan` fails on the `access_bundles` validation blocks. |
| SSM parameter missing (apply not run yet) | Broker logs and exits 0 without touching the output directory. Never publishes a partial file. |
| Identity role just created, IAM not yet consistent | Broker retries five times with linear backoff before failing, so a new VM does not wait 15 minutes for its first credentials. |
| `AssumeRole` fails for any other reason | Broker logs and exits non-zero; previous credentials stay valid until expiry. |
| Timer stopped ≥1h | `ExpiredToken` from the CLI. Diagnosis: `systemctl status aws-vm-credentials.timer` as `admin`; or compare the credentials file mtime against 35 minutes. |
| A long-running SDK process outlives its session | `ExpiredToken` from that process only, permanently, while the CLI beside it works. The file is re-read per process, not per request, so refresh never reaches an already-resolved client. Restart the process. Documented in `vms/README.md`; `credential_process` is the phase-B fix. |
| Boot race: shell opened before first broker run | Environment is exported regardless, so the session recovers as soon as the file appears. No re-login needed. |
| Container sets an explicit `uid:gid` | `EACCES` reading `/aws/credentials` — the host group `ubuntu` maps to container gid 0, so an overridden group loses the only bit that grants access. Documented: drop the group half. |
| A `policy_arns` entry does not exist or was deleted by its owner | `NoSuchEntity` at apply time; if deleted afterwards, `AccessDenied` at use time with the attachment still present in state. |
| A bundle's policy ARN is silently repointed by its owner | Undetectable from here. The boundary is what limits the damage. |
| An organization SCP denies the call | Indistinguishable at the call site from an allow-list denial — both surface as `AccessDenied` / `UnauthorizedOperation` — but originates in a policy this repository cannot see and `allowed_actions` cannot influence. Widening the bundle will not help and quietly raises that VM's ceiling for nothing. Confirm with `aws iam simulate-principal-policy` or by checking whether the same call fails for an unrelated principal, and take it to whoever owns the organization. Most likely met in a region this repository does not manage: `ec2:DescribeInstances` in `eu-west-1` is denied by SCP today. |
| Unknown bundle name in tfvars | `terraform plan` fails with offenders and valid names. |
| VM name violates IAM or source-identity constraints | `terraform plan` fails on the `validation` block. |
| `AssumeRole` returns a parseable but incomplete credential set | Broker refuses to publish and exits non-zero. Necessary because `jq` treats `"x = " + null` as `"x = "` and exits 0, so an unchecked render would replace working credentials with an empty secret key — and the symptom would be `SignatureDoesNotMatch` while the timer, journal and file mtime all look healthy. |
| Region or `ubuntu` uid/gid cannot be resolved at converge | `base::aws_access` logs a warning and manages nothing this run. Deliberately not a `raise`: the resolution happens at compile time, so raising would abort the entire chef run before any recipe converges — no firewall, no SSH hardening, no Wazuh — to protect one feature. |
| Broker exits non-zero during a converge | The converge is **not** failed (`ignore_failure`). `systemctl start` on a `Type=oneshot` unit propagates the exit status, so without that a lagging VM would report a failed converge every 30 minutes forever while the timer retried successfully every 15. |
| SSM `GetParameter` throttled | Treated as an unreadable parameter: log, exit 0, leave existing credentials. The next tick retries. |
| A VM's bundles exceed the attached-policy quota | `terraform apply` fails with `LimitExceeded` on the attachment. Raise the quota or consolidate policies; see *Quotas and limits*. |

Clock skew is already handled by `base::chrony`.

## Verification

Static, before any apply:

```bash
( cd vms && terraform init -backend-config=backend.hcl && terraform validate )
( cd vms && terraform plan )            # review, do not apply
( cd cinc && make lint )
```

`terraform plan` must show, per VM: two new roles, one new boundary policy, one new instance profile, one new SSM parameter, an in-place update of `iam_instance_profile`; plus destruction of the three region-shared IAM resources. It must show **no instance replacement**.

On a VM after converge, as `ubuntu`:

```bash
aws sts get-caller-identity          # assumed-role/dev-vm-id-<name>-<region>/<name>
aws s3 ls s3://example-media/dev-prefix/   # succeeds for a VM granted s3-media-dev
```

The hardening must hold. As `ubuntu`:

```bash
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/     # must time out
aws ssm get-parameter --name /developer-vms/cinc/validator-key --with-decryption
                                                                  # must be AccessDenied
ls -ld /dev/shm/dev-vm-aws                                                # root:ubuntu drwxr-x---
touch /dev/shm/dev-vm-aws/x                                               # must be Permission denied
```

That last check is the one that matters most: it proves the developer cannot stage a symlink where root writes.

The boundary must hold, in both of its layers. Attach one deliberately over-broad throwaway policy to an identity role, converge, and confirm as `ubuntu` that two calls are still `AccessDenied`: one action in a namespace the VM's bundles never declared (`sqs:ListQueues` — tests the allow list, which blocks by omission) and one on the fixed deny list (`iam:ListRoles` — tests the explicit deny, which is the layer that also overrides resource-based grants). Neither probe leaks anything if its layer fails, which is why the target is not the validator key. Remove the policy afterwards. Without this test the boundary is untested code.

The uid gate must hold. As `admin`:

```bash
env | grep AWS_                      # must be empty
aws sts get-caller-identity          # must fail with a credentials error, NOT return the identity role
                                     # (admin is not uid 0, so imds.rb blocks it — no credentials at all)
sudo aws sts get-caller-identity     # must return dev-vm-boot-<name>-<region>
sudo aws ssm get-parameter --name /developer-vms/wazuh/authd-password --with-decryption >/dev/null
                                     # must succeed — root still uses the instance role
```

Containers, from a fresh login shell so the `DOCKER_HOST`/zsh question surfaces rather than hides:

```bash
docker run --rm -v /dev/shm/dev-vm-aws:/aws:ro \
  -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials \
  -e AWS_DEFAULT_REGION=eu-central-1 \
  amazon/aws-cli sts get-caller-identity
```

Attribution: make one call, then confirm in CloudTrail that `userIdentity.arn` ends in `/<vm-name>` and `userIdentity.sessionContext.sourceIdentity` is the VM name.

Refresh: confirm credentials still work 70 minutes after boot — past the one-hour chained-session cap, which proves refresh works rather than the first session merely being long-lived.

## Quotas and limits

| Limit | Default | Adjustable | Consequence |
|---|---|---|---|
| IAM roles per account | 1000 | Yes, Service Quotas `L-FE177D64` | Two roles per VM → 500 VMs before a request is needed |
| Managed policies attached per role | 10 | Yes, via Service Quotas | One policy per bundle keeps this comfortable. The exact maximum has changed over time and is not asserted here — check the console before designing around a specific ceiling. A permissions boundary is *set*, not attached, so it does not consume a slot. |
| Customer-managed policies per account | 1500 | Yes | One boundary per VM plus the bundle policies. Not a concern at any plausible VM count. |
| Versions per managed policy | 5 | No | Each edit to a VM's `aws_access` rewrites its boundary and creates a version. See *Error handling* for the recovery. |
| Role trust policy length | 2048 chars | To 8192 | Not a concern in phase A (one principal, one condition); worth watching if the trust policy ever grows |
| SSM Parameter Store standard tier | 4 KB per value | Advanced tier | Ample |
| Role chaining session duration | 1 hour | No | Broker refreshes every 15 minutes and must not request more than 3600 seconds |

## Rollout

Additive apart from the IAM rewrite:

1. Apply Terraform with `aws_access` unset everywhere. Both existing VMs swap instance profiles in place; behaviour is unchanged because the new bootstrap role carries the same SSM grants.
2. Push and promote the cookbook (`make lint`, `make push`, verify on one VM, `make promote`). With no bundles the broker publishes a powerless credential set — a full smoke test of the chain, including the ownership and gate checks above.
3. Add the first real bundle to one VM. Run the boundary test. Verify end to end.

### Fleet this applies to, and the fleet it does not

Terraform manages two developer VMs today: `alice` in `eu-central-1` and `bob` in `eu-north-1`. Those are the two that get per-VM roles in step 1.

`eu-north-1` also holds several developer VMs that are **not** in this repository's state — an older generation, created before this configuration existed. They are expected, not a gap: this configuration is the target those VMs are being migrated to, one `instances.auto.tfvars` entry at a time, and the design needs nothing new to absorb them.

Two consequences worth stating, because both would otherwise look alarming when noticed:

- **Step 1 destroys the region-shared `dev-<region>-ec2-role`, its policy and its instance profile.** That is safe only because none of the unmanaged VMs carries an instance profile — verified before applying. Re-verify if this rollout is ever repeated in a region whose fleet has changed.
- **Promoting the cookbook reaches those VMs too**, if they are on the same CINC policy group. They will install the broker and timer, and the broker will log `cannot read /developer-vms/access/<vm>` and exit 0, because Terraform has created no access parameter for them. That is the designed behaviour for a VM whose Terraform state lags, not an error, and it resolves the moment the VM is added to the ledger.
4. Roll out to remaining VMs.

Rollback for step 1 is `terraform apply` of the previous IAM code; for step 2, `make promote` of the previous policy revision. Neither destroys a VM.

## Rejected alternatives

**Open IMDS to `ubuntu`, one role per VM.** Closest to the original mental model and needs no broker. Rejected because rootless Docker containers cannot reach IMDS (owner-matched `DROP`, plus `hop_limit = 1`), so a credential file is required anyway; and because the bootstrap secrets would have to leave SSM, which for the CINC validator key means abandoning self-bootstrap from `user_data` in favour of push-based `knife bootstrap` — the largest and most fragile change available, in the least forgiving place.

**Region-shared bootstrap role scoped by `ec2:SourceInstanceARN`.** Cuts roles to N+1 and does preserve per-VM binding; the key is present whenever the caller signs with EC2 role credentials and is valid in trust policies. Rejected on operational grounds: it puts instance IDs in trust policies, which churn on replacement, and it inverts creation order so a new VM's first broker run can precede its identity role.

**Region-shared bootstrap role with no scoping.** Simplest, and a developer cannot reach it. Rejected because one root compromise would then yield every other VM's AWS access, and `sts:SourceIdentity` would degrade from a guarantee to a convention.

**A localhost credential endpoint (`AWS_CONTAINER_CREDENTIALS_FULL_URI`).** The AWS-blessed pattern, and it avoids credential files entirely. Rejected because rootless Docker with slirp4netns does not reliably expose the host loopback to containers.

**Trusting resource owners' policies without a boundary.** Rejected: it makes every stated security property contingent on teams explicitly out of scope.

**`Allow *` in the boundary plus a deny list.** The first draft's shape. It grants nothing by itself — a boundary is an intersection — so it is not a least-privilege violation in the way it reads. Rejected because it makes the deny list the *only* thing capping an externally authored policy, and a deny list must anticipate every escalation path. Two were missed and caught in review; see *Resolved: the boundary is an allow list*.

**One shared boundary policy per region.** Fewer resources, no policy-version churn per VM. Rejected because a shared ceiling is the union of every bundle in the catalog, so it loosens as the catalog grows and stops reflecting what any individual VM was granted.

**Human identity via SSO or IAM Roles Anywhere.** The right answer if attribution must ever name a person rather than a VM. Rejected for now: interactive login per session, no unattended use, and it does not match "the VM gets an identity automatically". Compatible with adding later — only the component setting `SourceIdentity` changes.

## Review corrections

Recorded so the reasoning is not lost, and because two of these were asserted as fact in the first draft:

1. **`sts:SetSourceIdentity` is required on both sides of every hop.** The first draft claimed source identity "propagates automatically … no dependency on anyone else's trust policy". The value does propagate without re-passing the flag, but the *permission* is evaluated per hop, and without it `AssumeRole` fails. This is what pushed the whole chaining story into phase B.
2. **The managed-policy ceiling was wrong.** The first draft called 20 a hard cap that "no support request raises". The default is 10 and it is adjustable; the maximum has moved and is no longer asserted here.
3. **`0700 ubuntu:ubuntu` on the broker's output directory was a root-write primitive** via symlink pre-placement. Now `root:ubuntu 0750`.
4. **No boundary on the identity role** meant an externally authored policy could grant `ssm:GetParameter` on `*` and hand over the validator key.
5. **A verification step could not pass**: `aws sts get-caller-identity` as `admin` returns no credentials at all, because `imds.rb` allows only uid 0 and `ec2-instance-connect`. It is now `sudo`, with the unprivileged failure kept as its own assertion.
6. **Missing `depends_on`** reproduced the first-boot race used to reject an alternative.
7. **`$EUID` does not exist in dash**, so the `/etc/profile.d` half of the gate would never have fired.
8. **The existence test in the gate** made a session's credentials depend on a boot race; removed.
9. **`Persistent=true` is a no-op for monotonic timers**; removed, and network ordering added.
10. **The CloudTrail field path was wrong** — `userIdentity.sessionContext.sourceIdentity`, not `userIdentity.sourceIdentity`.
11. **Role name prefixes were ambiguous**: `dev-vm-*` matched bootstrap roles too. Now `dev-vm-boot-` and `dev-vm-id-`.
12. **The broker had no defined way to learn its own name and region**; now templated by CINC rather than derived from `hostname`.
13. **Containers running as non-root uid cannot read the file** under rootless Docker's subuid mapping; `--user 0` is now documented as a requirement. *(Superseded by correction 32 — the mapping detail was wrong and `--user 0` is not required.)*
14. **"Blast radius stays at one VM"** overstated the claim — the AWS blast radius does, but fleet-scoped CINC and Wazuh enrolment secrets remain reachable by VM-root.
15. **The recipe-ordering rationale was wrong** — `docker.rb` does not consume broker output, and the timer is asynchronous.

### Second review round (on the implementation plan)

16. **The boundary's `ssm:GetParameter` deny was an enumeration, not the wildcard the prose claimed.** `ssm:GetParameterHistory` returns decrypted historical values and was not covered, so any bundle carrying `ssm:Get*` would have reached the CINC validator key — defeating the stated goal while the boundary test still passed, because it probed `GetParameter`.
17. **The boundary permitted `ec2-instance-connect:*`**, which is a two-command path to root: push a key for the `admin` user (`ssh.rb:46` runs the EIC helper over `%u`), then `ssh` in and use `NOPASSWD:ALL`. Snapshot and volume actions had the same character and were added too.
18. **A compile-time `raise` on region lookup would have aborted every recipe**, not just this feature — turning a transient IMDS failure into a fleet-wide converge outage. Now resolves via ohai with an IMDSv2 fallback, and degrades to a warning.
19. **A broker failure failed the whole converge, permanently.** `systemctl start` on a `Type=oneshot` unit propagates the exit status; `ignore_failure` added.
20. **"Policy changes apply to new sessions, not existing ones" was false** and appeared inside a rollback procedure. Permissions on temporary credentials are evaluated per request; immediate revocation needs an `aws:TokenIssueTime` deny.
21. **The boundary's own test used the real fleet secret as its target**, so a broken boundary would have been demonstrated by granting live access to it. Now probes `iam:ListRoles`.
22. **Attribution was never actually verified** — the CloudTrail query inspected the broker's own hop, which the timer produces unprompted, rather than the developer's action events. Both assertions now exist.
23. **The `jq` render could publish an empty secret key** on a parseable-but-incomplete STS response, because `"x = " + null` is not an error in `jq`. Validated before rendering.

### Third round (boundary shape)

24. **The boundary's `Allow *` was left as an open decision and is now closed.** The clarification that mattered: `Allow *` inside a boundary grants nothing, because effective permissions are the intersection of attached policies and the boundary — so it was not the least-privilege violation it looked like. But the objection landed on the right target anyway. With `Allow *`, the deny list is the only cap on an externally authored policy, and that list had already proved incomplete twice. The boundary is now a per-VM allow list built from `allowed_actions` declared on each bundle, with the deny list kept as a second layer for the one thing an allow list cannot do: an omission from `Allow` does not block access granted by a resource-based policy naming the role, whereas an explicit `Deny` does.
25. **The boundary test only exercised the deny layer.** Probing `iam:ListRoles` alone cannot distinguish a working allow list from a missing one. A second probe in an undeclared namespace (`sqs:ListQueues`) tests blocking-by-omission directly.

### Fourth round (on the allow-list boundary)

26. **The stated reason for keeping the deny layer was wrong.** The claim was that an omission from the boundary's `Allow` does not cap a resource-based policy naming the role. AWS's permissions-boundary evaluation rules say the opposite for a *role* ARN — it is limited by the implicit deny — and the exception is a resource policy naming the assumed-role *session* ARN, whose permissions are granted directly to the session. The layer is retained for three better reasons (privileged declared namespaces, the session-ARN case, and explicit deny beating every allow), and the wrong sentence was removed from the spec, the `iam.tf` comments and the Task 2 commit message before it could be inherited as established fact.
27. **The uid gate's rationale was wrong.** It claimed that without the gate anything under `sudo` would read the credentials file and use the identity role, breaking `base::wazuh_agent`. Ubuntu's sudoers ships `Defaults env_reset` and this cookbook adds no `env_keep`, so `AWS_SHARED_CREDENTIALS_FILE` never survives `sudo`. The gate stays — `admin`'s own login shell would otherwise inherit an unreadable path — and the verification step that "proved" it via `sudo` proves nothing; the `env | grep AWS_` assertion is the one that does.
28. **The deny list missed a second family of escalation paths**, found by exactly the reasoning that found the first two: `ec2:ModifyInstanceAttribute` rewrites user data on an instance already carrying a bootstrap profile (a `#cloud-boothook` payload runs on every boot, so the `once-per-instance` semaphore does not save it), and `ec2:CreateImage` + `ec2:ModifyImageAttribute` reproduces the snapshot path around all four denied snapshot actions. `ssm:PutParameter`, `ssm:DeleteParameter*`, `ssm:CreateAssociation`, `ssm:UpdateAssociation`, `ec2:CopySnapshot` and the two instance-profile association actions were added in the same pass. This is also what forced the honest statement that the allow list protects only against *undeclared* services.
29. **File-based credentials do not refresh inside a running process.** The design's refresh story was written as if the 15-minute timer covered everything; it covers every new process, which is why the CLI never notices, and nothing already running. A long-lived SDK client fails at the one-hour mark permanently while every other indicator looks healthy.
30. **The documented Terraform rollback would have destroyed a live VM.** `vms/instances.auto.tfvars` carried the entire `alice` instance as an uncommitted change, so the commit that adds `aws_access` would have carried the VM's existence with it, and the revert in the rollback procedure would have proposed destroying the instance, its volume, its EIP and its DNS record — under a heading asserting that no VM is destroyed.

### Fifth round (staging verification on a real VM)

Unlike rounds one through four, these were not found by reading. They were found by running the design on `alice` and watching two things fail that the document asserted would work.

31. **`/run/aws-vm` was invisible to rootless Docker, so containers had no route to credentials at all.** RootlessKit starts the rootless daemon with `copy-up=/run`, giving it a private tmpfs at `/run` inside its mount namespace; a bind mount of `/run/aws-vm` into a container resolves to an empty directory. Combined with the fact that rootless containers cannot reach IMDS either — which is one of the two reasons this broker exists — container access was simply absent, while every other indicator looked healthy. A control test isolated the cause: a bind mount from `/home/ubuntu` worked and the uid mapping read a `root:ubuntu 0640` file fine, so only the location was wrong. Output moved to `/dev/shm/dev-vm-aws`, which is also tmpfs and is not copied up. Because `/dev/shm` is mode 1777 rather than root-owned, the broker now verifies its output directory (real directory, not a symlink, owned by the writer, not writable by anyone else) instead of assuming it — a check the design should arguably have had for `/run` too.

32. **`--user 0` was not required, and recommending it was actively harmful.** The claim in correction 13 was that `ubuntu`'s uid maps to container uid 0 and any other uid gets `EACCES`. What actually happens: the host's `root` is outside the rootless uid mapping and surfaces as the overflow uid `65534`, so the file's owner bits are unreachable inside the container, while the host group `ubuntu` maps to container **gid 0** — and every successful read comes through the group bit. Access is therefore governed by the container's gid, whose default is already 0. Measured: `--user 1234` reads the file, `--user 1234:1234` does not. Following the original advice would have pushed every `docker-compose.yml` on the fleet to run as root for no reason. The rule is to leave the group alone, not to force uid 0.

33. **Effective permissions intersect with SCPs too, which this document never mentioned.** Discovered incidentally: an `ec2:DescribeInstances` call in `eu-west-1` returned `UnauthorizedOperation` sourced from an organization SCP, not from anything in this design. So the real evaluation is identity policies ∩ permissions boundary ∩ SCP. This matters operationally rather than architecturally: an SCP denial is indistinguishable at the call site from an allow-list denial, so the first instinct on seeing `AccessDenied` will be to widen `allowed_actions`, which cannot possibly help and quietly loosens a VM's ceiling. Regions outside the ones this repository manages are the likely place to meet it.

34. **A CINC policy-group rollback does not roll the feature back.** Returning `alice` from `staging` to `production` restored the policy group and reverted `/etc/zsh/zshenv` (which the production policy manages), but left the broker, both systemd units and the active timer in place, because the production policy simply does not mention them. The VM kept publishing credentials every 15 minutes while the shell no longer exported the variables. Harmless here, but worth knowing before treating a policy-group switch as a rollback mechanism: it reverts managed files, not previously-created ones.

### Sixth round (adversarial review before submitting upstream)

35. **The deny list missed the short path to the root volume.** It denied the snapshot chain — `CreateSnapshot`, `CreateSnapshots`, `CopySnapshot`, `ModifySnapshotAttribute`, `CreateVolume` — on the stated grounds that it lets a developer mount a VM's root volume elsewhere and read `/etc/cinc/client.pem` and `/var/ossec/etc/client.keys` off disk. But no snapshot is needed: a root volume can be detached once its instance is stopped, so `StopInstances` → `DetachVolume` → `AttachVolume` reaches the identical objective in three calls. None of the three was on the list, and unlike the profile-manipulation entries they need no `iam:PassRole`, so `iam:*` did not incidentally cover them either. Reachable only by a bundle that declares `ec2`, which is exactly the case the deny list exists for — the allow list is silent inside a namespace a bundle legitimately declared. Also added `CreateReplaceRootVolumeTask`, which is `ModifyInstanceAttribute`'s objective by another route: repoint the root volume of an instance already carrying a bootstrap profile at an image the developer controls.

    This is the third enumeration miss in this document's history, after `ssm:GetParameterHistory` and the EIC-to-`admin` path. All three had the same shape: an entry was chosen by naming the attack rather than the capability, and a different API reached the same capability. The pattern is now explicit enough to state as a rule — when adding a deny entry, ask what the *objective* is and enumerate every API that reaches it, then keep going. There is still no basis for believing a fourth does not exist.
