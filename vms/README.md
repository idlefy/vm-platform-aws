# Developer VMs

Terraform module for managing developer EC2 instances across multiple AWS regions with CINC (Chef) configuration management.

> Repo overview: [`../README.md`](../README.md) • Runbook: [`../docs/runbook.md`](../docs/runbook.md)

## Architecture

- Multi-region: us-east-1 (4 AZs), eu-north-1 (2 AZs) — change in `config.tf`
- Each region gets: VPC, public subnets per AZ, IGW, security group, EC2 instances
- Instances bootstrap with CINC agent on first boot
- CINC validation key stored in AWS SSM Parameter Store (SecureString)
- State: S3, configured via `backend.hcl` (per-tenant, gitignored)

## Configuration files

| File                          | In git? | Purpose                                                                   |
|-------------------------------|---------|---------------------------------------------------------------------------|
| `variables.tf`                | yes     | Variable declarations                                                     |
| `config.tf`                   | yes     | Locals: regions, VPC CIDRs, security group rules                          |
| `main.tf` / `outputs.tf`      | yes     | Provider, module wiring, outputs                                          |
| `instances.auto.tfvars`       | yes     | Per-developer VM definitions + SSH public keys (team's running ledger)    |
| `access_bundles.auto.tfvars`  | yes     | Named AWS permission bundles — the only place external policy ARNs appear |
| `tenant.auto.tfvars`          | **no**  | AWS profile, Route53 zone, CINC URL, SSM paths (copy from `.example`)     |
| `backend.hcl`                 | **no**  | S3 backend config (copy from `.example`)                                  |

## Prerequisites

### CINC validation key in SSM

Each region must have the CINC validation key in SSM Parameter Store. One-time per region:

```bash
# Replace <param-name> with cinc_ssm_parameter_name from your tenant.auto.tfvars.
# The key goes through a 0600 file, never through --value "$(cat …)": an argument
# is readable in `ps` for as long as the call runs.
aws ssm put-parameter \
  --name "<param-name>" \
  --type SecureString \
  --value "file://<path to your-org-validator.pem>" \
  --region <region> \
  --profile <your-aws-profile>
```

Get `<your-org>-validator.pem` from the CINC server at `/etc/cinc-project/<your-org>-validator.pem` (created by `infra/ansible/roles/cinc-server`).

### Grafana Cloud Loki token in SSM

This section applies when `log_shipping` is true in `vms/tenant.auto.tfvars`;
with it false the bootstrap role gets no grant and no parameter is needed.

Each region must also have a Grafana Cloud Loki push token in SSM Parameter
Store, hand-created the same way as the CINC validation key above — as a
SecureString, encrypted with the default `alias/aws/ssm` key, named to match
`loki_ssm_parameter_name` in `vms/tenant.auto.tfvars`. Terraform grants the
VM's bootstrap role read access to that parameter *name*; it does not create
the parameter or set its value, and a missing or misnamed one fails silently
on the VM rather than at `terraform plan` or `apply` time. See
[the runbook, §7](../docs/runbook.md#7-grafana-cloud-loki-token-out-of-band-human-step)
for the full procedure, including rotation.

## Usage

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

## Adding a New VM

Edit `instances.auto.tfvars` and add an entry under the appropriate region:

```hcl
"my_vm" = {
  instance_type  = "t3.large"
  volume_size_gb = 50
  az             = "us-east-1a"   # optional, defaults to region's default_az
  fqdn           = "my-vm.ec2.us-east-1.<your-domain>"
  key_name       = "developer-name"
  tags = {
    Purpose = "Development"
    Owner   = "developer-name"
    # idlefy = "disabled"   # opt this one VM out of Idlefy (see below)
  }
}
```

Then add the developer's SSH public key under `ssh_key_pairs.<region>.<key_name>` in the same file, and `terraform apply`.

Two lifecycle notes on running VMs:

- **Bootstrap-script changes reach new instances only.** `user_data` is in
  `ignore_changes` (like `ami`): cloud-init runs it once, at first boot, and
  rewriting it on a live instance would stop/start every VM in the region for
  nothing. To re-bootstrap a VM, recreate it deliberately.
- **`key_name` and `az` are ForceNew — and the root volume dies with the
  instance.** Changing either replaces the instance; `delete_on_termination`
  is at its default, so the replacement **deletes the developer's root
  volume**. Read the plan for `must be replaced` before applying; snapshot
  first if the disk matters.

**Idlefy.** Every instance is tagged `idlefy = "enabled"` by default, which is
how Idlefy discovers it and how Idlefy's own IAM role is allowed to stop, start
and reboot it (`ec2:ResourceTag/idlefy = enabled`). The tag is a label; this
module grants Idlefy nothing. `idlefy_managed = false` on the module stops it
adding the tag; an explicit `idlefy` entry in `tags` still applies, and a
per-VM `tags = { idlefy = "disabled" }` overrides the flag for that VM,
because the flag's map is merged first. (A
direct consumer of the module can also pass the module's `tags` with the same
entry; the tenant root does not expose that variable.) The key is lowercase
and the value is exactly `enabled`; any other spelling is invisible to Idlefy.
The per-VM `tags` also land on that VM's Elastic IP, as they always have; Idlefy
reads instances only, so the EIP copy is inert.

## Scoped AWS access from the VM

Every VM gets two IAM roles, named after the VM and its region:

| Role | Who uses it | What it is for |
|---|---|---|
| `dev-vm-boot-<vm>-<region>` | root only | On the instance profile. Reads the two bootstrap secrets and assumes the identity role. Not reachable by the developer — `base::imds` blocks IMDS for every uid except root. |
| `dev-vm-id-<vm>-<region>`   | the developer | The developer-facing identity. Carries whatever the VM's bundles grant, capped by its own permissions boundary. **This is the ARN you hand to a resource owner when requesting access.** |

A root systemd timer (`aws-vm-credentials.timer`, every 15 minutes) assumes the
identity role and publishes short-lived credentials to
`/dev/shm/dev-vm-aws/credentials` as `root:ubuntu 0640`, inside a `root:ubuntu
0750` directory. The `ubuntu` user reads them; it cannot write there, which is
what stops a symlink attack on the root writer. So as `ubuntu`, this just works
with no configuration:

```bash
aws sts get-caller-identity     # → .../dev-vm-id-<vm>-<region>/<vm>
aws s3 ls s3://some-bucket/
```

Get the ARNs from Terraform. Outputs are keyed by region under a single `regions`
output (they used to be one output per region, named `eu_central_1` and so on):

```bash
terraform output -json regions | jq -r '.["eu-central-1"].identity_role_arns'

# every VM's instance id, across all regions, by name
terraform output -json instance_ids | jq
```

### Granting access

1. Ask the resource owner for a **same-account** managed policy ARN. Cross-account
   access does not work in phase A — a managed policy cannot be attached across
   accounts.
2. Add a bundle to `access_bundles.auto.tfvars`.
3. List the bundle name in that VM's `aws_access` in `instances.auto.tfvars`.
4. `terraform plan`, review, `terraform apply`. The VM picks it up on its next
   converge, or immediately with `sudo cinc-client`.

### `allowed_actions` — the ceiling, not the grant

Each bundle must declare `allowed_actions`. It grants nothing. It is the set of
service namespaces the VM's permissions boundary will allow, and a VM's boundary
allows only the union across the bundles granted to it. Anything a policy reaches
for outside that union is denied — including a grant the policy's owner added
without telling us.

Declare services, not exact actions: `["s3:*"]` is the right entry for a bundle
whose policy grants three S3 actions on one prefix. The policy is still what
decides what you can do; `allowed_actions` only decides what it is *allowed to
decide*. Because widening it is a security change, it belongs in a reviewed diff
— which is why it is written here by hand rather than inferred from the policy.

**The limit of this protection, stated plainly:** the allow list only makes an
*undeclared* service safe. A bundle declaring `ec2:*` or `ssm:*` raises the
ceiling to a service that contains root-equivalent actions (rewriting a VM's user
data, remote command execution), and there the boundary's deny list is the only
remaining control. Those bundles are a security review, not a config change.
`iam`, `sts`, `organizations` and `ec2-instance-connect` cannot be declared at
all — `terraform plan` refuses them.

### Containers: mount the directory, don't override the group

```bash
docker run --rm \
  -v /dev/shm/dev-vm-aws:/aws:ro \
  -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials \
  -e AWS_REGION=eu-central-1 \
  -e AWS_DEFAULT_REGION=eu-central-1 \
  amazon/aws-cli sts get-caller-identity
```

Same three things in `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - /dev/shm/dev-vm-aws:/aws:ro
    environment:
      AWS_SHARED_CREDENTIALS_FILE: /aws/credentials
      AWS_REGION: eu-central-1
      AWS_DEFAULT_REGION: eu-central-1
```

No `--user` is needed. What makes this work is the **group**, and the default is
already correct — so the one way to break it is to override the group yourself.

Inside the container the file appears as `65534:0` with mode `0640`. Docker here
is rootless: the host's `root` is outside the uid mapping and shows up as the
overflow uid, so the owner bits are unreachable, while the host group `ubuntu` —
the user running the daemon — maps to container **gid 0**. Access therefore comes
entirely from the group read bit, and any container process whose gid is 0 gets it.

| `--user` | uid:gid inside | Can read |
|---|---|---|
| omitted | `0:0` | yes |
| `--user 0` | `0:0` | yes |
| `--user 1234` | `1234:0` | yes — gid still defaults to 0 |
| `--user 1234:1234` | `1234:1234` | **no** |
| `--user 1234:0` | `1234:0` | yes |

So run the container as whatever uid you like; just don't set an explicit group.
If your image needs a non-root user, `--user 1234` is fine — `--user 1234:1234`
is what fails, with `EACCES` on the credentials file.

**Mount the directory, never the file.** `-v /dev/shm/dev-vm-aws:/aws:ro`, not
`-v /dev/shm/dev-vm-aws/credentials:/aws/credentials`. Publishing is a `rename(2)`
over the target, so a file bind-mount pins the container to the original inode: it
works for an hour and then expires permanently.

**Why `/dev/shm` and not `/run`.** Rootless Docker is started by RootlessKit with
`copy-up=/run`, which gives the daemon a private tmpfs at `/run` inside its mount
namespace. Bind-mounting `/run/anything` into a container therefore yields an
empty directory, and since rootless containers cannot reach IMDS either, they
would have no credentials at all. `/dev/shm` is also tmpfs — credentials never
touch disk — and is not copied up, so containers see it live. If you are looking
for `/run/aws-vm` because an older doc or an older converge mentioned it, it is
gone.

### Things that will otherwise cost you an afternoon

- **Credentials do not refresh inside a process that is already running.** The
  CLI never notices, because each invocation re-reads the file. An SDK resolves
  the shared-credentials file once and treats the result as static — botocore and
  the Go v2 SDK both do — so a Python worker, a notebook kernel or a
  `docker run -d` started at 10:00 begins failing with `ExpiredToken` at 11:00
  and never recovers, while `aws sts get-caller-identity` in the next terminal
  works and the timer, the journal and the file mtime all look healthy. Restart
  the process or re-create the client. The durable fix is `credential_process`,
  which SDKs re-invoke on expiry; that is phase B, because it is a profile
  setting and arrives with the `AWS_CONFIG_FILE` question phase B already owns.
- **`AWS_SHARED_CREDENTIALS_FILE` hides your own `~/.aws/credentials`.** The file
  is not overwritten — no root process touches it — but it stops being consulted.
  Escape hatch: `unset AWS_SHARED_CREDENTIALS_FILE` in your shell. `~/.aws/config`
  is *not* affected: phase A deliberately does not set `AWS_CONFIG_FILE`, so
  profiles, regions and SSO sessions defined there keep working.
- **`make ssh` logs in as `admin` unless told otherwise.** `cinc/Makefile`'s
  `ssh` target reads `USER` only when it is given on the command line
  (`make ssh INSTANCE=… USER=ubuntu`); the environment's `$USER` is ignored on
  purpose, so omitting it never tries your local username.

### Troubleshooting

| Symptom | Cause |
|---|---|
| `AccessDenied` naming a service the bundle did not declare — classically `kms` on an SSE-KMS bucket read | `allowed_actions` is missing that namespace. The grant is fine; the ceiling is too low. Add the namespace to the bundle. |
| `Unable to locate credentials` as `ubuntu` | The timer has not published yet, or `/etc/dev-vm/shell-env.sh` was not sourced. Check `systemctl status aws-vm-credentials.timer` and `sudo ls -l /dev/shm/dev-vm-aws/`. |
| `ExpiredToken` in a long-running process only | See the refresh note above. Restart it. |
| Nothing in `/dev/shm/dev-vm-aws` and the journal says `cannot read /developer-vms/access/<vm>` | `terraform apply` has not run for this VM yet. Not an error on the VM's side. |
| Journal says `refusing to publish` about the output directory | Something else owns `/dev/shm/dev-vm-aws` or made it group-writable. `/dev/shm` is world-writable, so the broker verifies the directory rather than trusting it. Remove the directory as root and let tmpfiles recreate it: `sudo rm -rf /dev/shm/dev-vm-aws && sudo systemd-tmpfiles --create /etc/tmpfiles.d/aws-vm.conf`. |
| A new VM never registers with the CINC server, and `ssh` as `ubuntu` has no `sudo` | The bootstrap failed and failed closed. Read `aws ec2 get-console-output` for the log, fix the cause, and `terraform apply -replace=` the instance. |

### Tests

```bash
cd vms/modules/ec2
terraform init -backend=false   # no bucket, no profile, no tenant.auto.tfvars needed
terraform test
```

26 runs over the plan-time guards, in three files. `validation.tftest.hcl`
(16, fixture with no instances): every `allowed_actions` rule, both VM-name
limits, both SSM parameter-name shapes, the unknown-bundle-name and
fleet-wide unique-name preconditions, and the shapes that must be *accepted* —
an empty catalog, a VM with a real bundle, two distinctly-named VMs in
different regions, a one-character parameter path. `hardening.tftest.hcl`
(8, fixture with one VM): the user_data and permissions-boundary pins, the
`log_shipping` grant on/off/inconsistent, and the `idlefy` tag default, off
and override. `unknown_bundle.tftest.hcl` (2). Each guard is paired with a
negative control deliberately: a precondition that rejected everything would
satisfy the failure cases on its own.

The AWS provider is mocked with a single unaliased `mock_provider`, matching
`main.tf`'s one-provider-plus-`for_each` shape, so nothing reaches AWS and no
credentials are required. Run these before any change to `variables.tf` or
`modules/ec2/access.tf`.

The credential broker has its own test, which does not need Terraform at all:

```bash
cd cinc && make test-broker
```

## Adding a New Region

```bash
cd cinc && make add-region REGION=eu-west-1
```

The wizard (`scripts/add-region.sh`) writes all the HCL, then proves it with
`terraform fmt`, `init`, `validate` and `test`; if any of those fail it restores
every file it touched, so a failed run leaves nothing behind. It creates nothing
in AWS and never applies — the result is a diff to read. It refuses to start if
those files have uncommitted changes, since the diff is the whole point.

**First: not every region is available.** An organisation may allowlist regions
with a service control policy, and a denied one is not detectable from opt-in
status — it reports `opt-in-not-required` while every EC2 call in it fails with
`UnauthorizedOperation ... explicit deny in a service control policy`. The
wizard probes for this and stops with the policy id. Measured on the original
deployment, whose SCP allowed `us-east-1`, `eu-central-1`, `eu-north-1` and
`us-west-2`, and denied `eu-west-1` and `ap-south-1` — your organisation may have
a different allowed set, or none at all. To check yours:

```bash
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  aws ec2 describe-availability-zones --region "$r" >/dev/null 2>&1 && echo "$r allowed"
done
```

**The HCL is one entry in one file.** `main.tf` instantiates `modules/ec2` with a
single `for_each` over `local.regions` against one unaliased provider, so all the
wizard writes is:

1. `config.tf` — the `local.regions` entry (`network_config`, `public_subnets`,
   `default_az`). Subnet CIDRs are derived from the VPC CIDR as `A.B.N.0/24`.

There is deliberately nothing else. No provider block, no module block, no output,
no test fixture. This used to be a five-file edit with eight separate places to
touch in the test file; see the *for_each* note below if you are wondering where
the provider aliases went.

Then, by hand, because Terraform manages the IAM grant that *names* each secret
and never its value:

2. Put the **CINC validation key** and the **Grafana Loki token** in SSM in the
   new region, as `SecureString` on the default `alias/aws/ssm` key — see
   *Prerequisites* above and the runbook §7. A CMK would need a `kms:Decrypt`
   grant that does not exist.
3. `cd cinc && make preflight`. It reads the region list from `local.regions`, so
   the new region is checked automatically, including that the Loki token
   actually authenticates there. Do this before `apply`: a missing parameter
   applies cleanly and then produces a VM that converges green and ships no logs.

### Why one provider and `for_each`

Terraform cannot generate `provider` blocks, and `providers = {}` in a module call
cannot be dynamic, so aliased providers force one hand-written provider + module +
output trio per region. AWS provider v6 added a `region` argument on individual
resources; `modules/ec2` sets `region = var.aws_region` on each of its regional
resources, which frees the root module to use one provider and `for_each`. Global
resources (all IAM, `aws_route53_record`) have no `region` and take none.

Two consequences worth knowing:

- **The `~> 6.0` provider pin is load-bearing.** On v5 there is no per-resource
  `region`, and every resource would quietly be created in `local.provider_region`.
- **A region key in `instances` that matches no configured region is caught at
  plan time** by `terraform_data.validate_region_keys`. The module call uses
  `lookup(var.instances, each.key, {})` so that a region with no VMs is legal —
  without that guard, a typo'd region key would build nothing and say nothing.

Expect the first `apply` to create about a dozen resources for the region even
with no VMs in it. The network baseline is per-region and not conditional on
instances: a VPC, a subnet per AZ, an internet gateway, a route table with its
associations, and the security group with its three rules.

## CINC Bootstrap

On first boot, each VM:
1. Sets hostname from EC2 metadata
2. Installs CINC agent via omnitruck.cinc.sh (pinned version + SHA256 check)
3. Fetches validation key from SSM Parameter Store
4. Writes `/etc/cinc/client.rb` pointing to `var.cinc_server_url`
5. Runs `cinc-client --once` in background
6. Deletes the validation key (no longer needed after registration)

Bootstrap log: `/var/log/cinc-first-run.log`
