# Runbook: from a fresh tenant repository to a running fleet

This is the operator's path from a fresh tenant repository to running VMs.
The tenant repository is generated from `tenant-skeleton/` (the `get-started`
skill or the manual steps in the README do that); everything below happens
inside it. Nothing in it is a copy of the platform: the CINC cookbook and the
two Terraform modules are pinned artifacts fetched from their tags, so the only
files you edit are configuration.

Tenant-specific values live in gitignored files with checked-in `.example`
templates, plus two files you create yourself and one that is already in git.
Sections 1–5 are the deploy path, in order. Section 7 is the Grafana Cloud
token; a tenant that does not ship logs skips it entirely, and §4 is where that
decision is made.

## Prerequisites

- AWS account with permissions for EC2, VPC, IAM, Route53, SSM, S3
- AWS CLI profile configured locally (any name — you reference it below)
- Route53 hosted zone you control (e.g., `infra.example.com`)
- Workstation tools: Terraform ≥1.5 (≥1.7 to run `terraform test`, which needs
  `mock_provider`), CINC Workstation, Ansible, AWS CLI v2, `python3`, `curl`.
  `scripts/preflight.sh` and both Makefiles shell out to `python3`; the CINC
  Workstation package supplies `chef`, `knife` and `cinc-client`. The version
  this was built against is pinned in
  [`cinc/README.md` § Prerequisites](https://github.com/idlefy/vm-platform-aws/blob/main/cinc/README.md#prerequisites).
- A GNU userland: the Makefiles and `scripts/` use `sed -i` without a suffix
  argument, and §5 uses `shred`, which macOS lacks. On macOS install
  `coreutils` and `gnu-sed` and put their `gnubin` directories first on `PATH`.

## 1. Create the Terraform state bucket

One-time, outside of Terraform. Pick any name; you reference it in the backend
configs. Create it in the region your `backend.hcl` names — the bucket holds
state, not VMs, and need not be a region you deploy into.

```bash
PROFILE=<your-aws-cli-profile>
BUCKET=<your-team>-tf-state
REGION=<the region in backend.hcl>

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --profile "$PROFILE"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled --profile "$PROFILE"
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
  --profile "$PROFILE"
```

Outside `us-east-1`, `create-bucket` also needs
`--create-bucket-configuration LocationConstraint="$REGION"`; the API rejects
the call without it.

## 2. Fill in the tenant files

`make prepare` copies six `.example` files to their real names. It never
overwrites, so a re-run after adding a template is safe:

```bash
make prepare PLATFORM_TAG=vX.Y.Z
```

| File | Where it comes from | What it holds |
|---|---|---|
| `vms/tenant.auto.tfvars` | `make prepare` | AWS profile, Route53 zone, CINC server URL, SSM parameter names, `log_shipping`, `idlefy_managed` |
| `vms/backend.hcl` | `make prepare` | S3 bucket / key / profile for the `vms` Terraform state |
| `infra/tenant.auto.tfvars` | `make prepare` | AWS profile, account name, Route53 zone, CINC FQDN, SSH keys |
| `infra/backend.hcl` | `make prepare` | S3 bucket / key / profile for the `infra` Terraform state |
| `infra/ansible/group_vars/all/tenant.yml` | `make prepare` | CINC org name, admin e-mail, server FQDN (Ansible-side) |
| `cinc/.chef/knife.rb` | `make prepare` | Knife identity: `chef_server_url`, `node_name`, path to the admin client key |
| `infra/ansible/group_vars/all/vault.yml` | **by hand**, from its `.example` — below | `vault_cinc_admin_password`, encrypted with `ansible-vault` |
| `~/.vault_pass` | **by hand** — below | The password that opens `vault.yml`. `infra/ansible/ansible.cfg` names this path in `vault_password_file`; every playbook run reads it |
| `infra/ansible/inventory.yml` | **by hand**, from `inventory.yml.tpl` — §5 step 2 | The CINC server's address. It cannot exist until Terraform has created the server |
| `cinc/.chef/admin.pem` | **fetched from the CINC server** — §5 step 4 | The knife admin client key |
| `cinc/policyfiles/dev-vm.rb` | **already in git** — §4 | The cookbook pin and this tenant's cookbook attributes |

Only the first six are `cp`-and-edit; each has inline comments explaining its
values. The rest are covered where they become possible — the two vault files
now, the inventory and `admin.pem` in §5, the policyfile in §4.

Create the vault files now, since §5 cannot run without them:

```bash
cp infra/ansible/group_vars/all/vault.yml.example \
   infra/ansible/group_vars/all/vault.yml

printf '%s' '<a strong vault password>' > ~/.vault_pass && chmod 600 ~/.vault_pass

# Encrypt the CINC admin password and paste the block it prints over the
# vault_cinc_admin_password: line in vault.yml.
echo -n '<a strong CINC admin password>' | ansible-vault encrypt_string \
  --stdin-name 'vault_cinc_admin_password'
```

Both are gitignored — `vault.yml` too, even though it is encrypted, because an
in-place `ansible-vault decrypt` would otherwise make the cleartext
committable. Confirm with
`git check-ignore infra/ansible/group_vars/all/vault.yml`.

## 3. Per-developer VM definitions

Edit `vms/instances.auto.tfvars` — this file is in git, since it tracks who has
VMs across your team. It starts empty (`{}` per region).

- Add an entry per developer with `fqdn`, `instance_type`, `volume_size_gb`,
  `key_name`, `tags`
- Add the developer's SSH public key under `ssh_key_pairs.<region>.<key_name>`

Each `fqdn` becomes an A-record in your Route53 zone, and its shape matters
beyond DNS: `base::traefik` composes every VM's published hostname as
`<vm>.ec2.<region>.<domain_root>` from the policyfile attribute in §4. The two
must agree, or Let's Encrypt is asked for a certificate for a name that does not
resolve.

`vms/access_bundles.auto.tfvars` is also in git and also starts empty
(`access_bundles = {}`). It is the catalog of named AWS permission bundles a VM
can be granted via `aws_access`, and the only place external policy ARNs appear.
Nothing needs to go in it to deploy — a VM with no bundles gets its own IAM
identity with no permissions, which is the intended starting point. See
[`vms/README.md`](https://github.com/idlefy/vm-platform-aws/blob/main/vms/README.md#scoped-aws-access-from-the-vm).

## 4. Fill in the policyfile

`cinc/policyfiles/dev-vm.rb` is checked into the skeleton rather than
materialised from an `.example`, so `make prepare` cannot fill it in. It carries
five `REPLACE_ME` values, and they are not equally forgiving:

| What | How to set it | If you leave it |
|---|---|---|
| the `cookbook 'base'` `tag:` | `make bump-cookbook TAG=base-X.Y.Z` — never by hand, because the lock has to move with it | `chef install` cannot resolve the cookbook |
| `default['base']['loki']['url']` | the push URL from the stack's *Send Logs* panel (§7), or turn shipping off below | `base::alloy` ends the converge failed, with a message naming the attribute |
| `default['base']['loki']['username']` | the numeric stack user ID from the same panel — not an e-mail address | same |
| `default['base']['traefik']['acme_email']` | the address Let's Encrypt registers for expiry notices | **nothing catches it.** The VM registers `REPLACE_ME` with Let's Encrypt |
| `default['base']['traefik']['domain_root']` | the DNS suffix of the `fqdn`s you wrote in §3 | **nothing catches it.** Every published hostname becomes `<vm>.ec2.<region>.REPLACE_ME`, and no certificate is ever issued |

The two Traefik rows are the dangerous ones. `base::alloy` refuses an empty or
`REPLACE_ME` `url`/`username` at converge, but `base::traefik` interpolates its
pair unguarded — so a tenant that leaves them converges green and fails only
where the value is finally used, which is the shape of failure this whole
document exists to prevent.

```bash
$EDITOR cinc/policyfiles/dev-vm.rb        # the four attributes
make bump-cookbook TAG=base-X.Y.Z         # sets the tag and re-locks, both at once
./scripts/placeholder-check.sh --config   # must exit 1 — nothing left to fill in
```

**Edit the attributes before you run `make bump-cookbook`, not after.** The lock
records the policyfile as it stood when it was written, and `make push` runs
`pin-check`, which compares the two: an attribute changed after the bump makes
it refuse with "policyfile has changes not in the lock", because `chef install`
honours the lock and would upload the previous content. One `bump-cookbook` in
this order covers both the tag and the attributes. (If you do edit an attribute
later — a new Loki URL, a moved domain — re-lock **before `make push`** with a
bare `make bump-cookbook`, no `TAG`, which re-resolves at the current pin.)

**Not shipping logs to Grafana Cloud?** Decide it here, before §5. Set
`default['base']['loki']['enabled'] = false` and delete the three `loki` lines
below it; set `log_shipping = false` and `loki_ssm_parameter_name = null` in
`vms/tenant.auto.tfvars`. Both halves or neither: `cd cinc && make preflight`
fails if the two disagree. With shipping off, Alloy is not installed at all, §7
does not apply, and preflight skips every Loki check — which is how `make
promote` runs on a tenant that has no Loki token and never will.

Nothing else needs editing. The cookbook and the Terraform modules are pinned
artifacts, not copies: `cinc/cookbooks/`, `cinc/README.md` and `vms/README.md`
live in the platform repository, not here.

## 5. Deploy

Ten steps, in this order. Steps 4 and 5 are the two Terraform cannot do for you
and that nothing downstream will remind you about.

```bash
# 1. Shared infra: the CINC server
cd infra
terraform init -backend-config=backend.hcl
terraform plan && terraform apply
```

```bash
# 2. Write the Ansible inventory from the address Terraform just printed
terraform output -json security_vms          # note the CINC server's address
cd ansible
cp inventory.yml.tpl inventory.yml
$EDITOR inventory.yml                        # replace <CINC_IP>
```

```bash
# 3. Build the CINC server. -i is required: ansible.cfg sets no inventory
#    and the play targets `hosts: cinc`.
ansible-playbook -i inventory.yml playbooks/cinc-server.yml
cd ../..
```

The role asserts `vault_cinc_admin_password` on its first task, so a missing
`vault.yml` or `~/.vault_pass` fails immediately rather than halfway through a
server build. It finishes by printing the paths of the two keys it created:
`/etc/cinc-project/admin.pem` and `/etc/cinc-project/<org>-validator.pem`.

```bash
# 4. Fetch the knife admin key from the server (it is root-owned, mode 0600).
#    Create the destination 0600 first: a redirect under umask 022 would
#    otherwise create it world-readable for the instant before chmod.
install -m 0600 /dev/null cinc/.chef/admin.pem
ssh ubuntu@<CINC_IP> 'sudo cat /etc/cinc-project/admin.pem' > cinc/.chef/admin.pem
```

```bash
# 5. Put the CINC validator key in SSM — ONCE PER REGION you deploy into.
#    SSM is region-scoped, and Terraform never creates this parameter: it
#    manages only the IAM grant that names it.
f="$(mktemp)"                      # 0600 already, unpredictable name
ssh ubuntu@<CINC_IP> 'sudo cat /etc/cinc-project/<org>-validator.pem' > "$f"

aws ssm put-parameter \
  --name "<cinc_ssm_parameter_name from vms/tenant.auto.tfvars>" \
  --type SecureString \
  --value "file://$f" \
  --region <region> \
  --profile <profile>

shred -u "$f"
```

Full reference, including what the IAM grant does and does not cover:
[`vms/README.md` § "CINC validation key in SSM"](https://github.com/idlefy/vm-platform-aws/blob/main/vms/README.md#cinc-validation-key-in-ssm).
Skip a region here and every VM in it boots, fails to fetch the key and never
converges — three minutes after `apply` reported success.

```bash
# 6. If this tenant ships logs: do §7 steps 1-4 now (the Grafana Cloud token).
#    make promote in step 9 runs preflight, which fails without it.
```

```bash
# 7. Push the policy to the staging policy group
cd cinc && make push
cd ..
```

```bash
# 8. Create one staging VM and let it converge.
#    Add an entry to vms/instances.auto.tfvars with policy_group = "staging".
cd vms
terraform init -backend-config=backend.hcl
terraform plan && terraform apply
# wait ~3 minutes, then SSH in via EC2 Instance Connect and confirm the converge
cd ..
```

```bash
# 9. Promote to production
cd cinc && make preflight && make promote
cd ..
```

```bash
# 10. Add the rest of the fleet to vms/instances.auto.tfvars
cd vms && terraform plan && terraform apply
```

Each VM auto-bootstraps in ~3 minutes after `apply`: installs CINC, fetches the
validation key from SSM, registers with the CINC server, runs the first
converge.

A VM that has not registered with the CINC server five minutes after `apply`
failed its bootstrap. It fails **closed**: the cloud image's `NOPASSWD` grant
for `ubuntu` is removed first and is never restored, so the developer can
still SSH in as `ubuntu`, but without sudo nobody can read
`/var/log/user-data.log` — it is root-owned and `0600`. The bootstrap writes
that log to the serial console instead. Pass `--latest`: on Nitro instance
types, the call without it returns the early-boot snapshot, not the log —
and `tail` alone would show the post-boot SSH banner and login prompt rather
than the bootstrap failure, so grab everything from the `BOOTSTRAP FAILED`
marker on:

```bash
aws ec2 get-console-output --latest --instance-id <id> --region <region> --profile <profile> --output text | sed -n '/BOOTSTRAP FAILED/,$p'
```

If the console output ends with "first converge failed" and no error
underneath, the failure is in `cinc-client`'s own converge log
(`/var/log/cinc-first-run.log` on the instance), which is deliberately not
mirrored to the console — reading it needs sudo, which is gone, so treat
the instance as unrecoverable and replace it.

Fix the cause (a validator key missing in that region, a policy group that does
not exist, a network that cannot reach the CINC server) and replace the
instance — the bootstrap only runs on first boot:

```bash
cd vms && terraform apply -replace='module.ec2["<region>"].aws_instance.this["<vm>"]'
```

Steps 6–9 are in that order, rather than one `make push && make promote`,
because `promote` enforces three things and each of them can stop you. It runs
`preflight` first, which fails on a Loki parameter missing in any region. It
then refuses unless the staging policy group already carries the revision in
the committed lock — which is what step 8 is for. Finally it asks for a typed
`yes`. `make promote PREFLIGHT=skip` bypasses the first check only, and prints
what it is giving up; `pin-check` and the revision check still run and still
refuse. Use it when you know why preflight is failing and have decided to
proceed anyway — not to get past a missing token, which is the failure it exists
to catch.

If you are not shipping logs at all, you set both halves of the switch off in
§4, preflight skips every Loki check, and step 6 does not apply.

## 6. Scrub your own names before sharing the repository

Your tenant repository is private by design, but the moment you add
collaborators, hand it to a contractor, or lift a snippet out of it for an
upstream issue, the names in it travel. Grep it for your own — the account name,
the domain, the CINC organisation slug, people's logins — and make sure each one
appears only where you put it on purpose (`tenant.auto.tfvars`,
`instances.auto.tfvars`, the policyfile). Anywhere else means a value was pasted
into a comment or a default:

```bash
# Substitute your real values for the three below. As written this pattern
# finds nothing and tells you nothing.
grep -rn 'acme-corp\|acme.example.com\|acme-platform' . \
  --exclude-dir=.git --exclude-dir=.terraform
```

Empty output, apart from the files you expect, is clean.

That grep only knows the names you put into it, so it cannot catch a bucket
name, an S3 prefix or a team handle spelled differently — and a comment is
exactly where such a value survives, because nothing executes it and nothing
reviews it. Before contributing a change back, skim the comments in committed
files as well.

## 7. Grafana Cloud Loki token (out-of-band, human step)

This section applies only when this tenant ships logs. The decision, and the
four settings that turn shipping off, are in §4; `cd cinc && make preflight`
fails if the two halves disagree.

Terraform grants the VM's IAM role read access to a specific SSM parameter
*name* (`vms/modules/ec2/iam.tf`, via `loki_ssm_parameter_name`), but — exactly
like the CINC validator key, hand-created per region in §5 step 5 and described
in
[`vms/README.md` § "CINC validation key in SSM"](https://github.com/idlefy/vm-platform-aws/blob/main/vms/README.md#cinc-validation-key-in-ssm) —
it does not create the parameter or put a value into it. A Grafana Cloud push
token is a secret, and a secret Terraform creates is a secret that lands in
Terraform state. This step is therefore manual, every time, including on
rotation.

1. Create a Grafana Cloud stack (or reuse an existing one).
2. Create an access policy scoped to `logs:write` only — push, never read —
   and generate a token under it.
3. Put the token in SSM **as a SecureString, encrypted with the default
   `alias/aws/ssm` key**:

   ```bash
   # The token goes through a 0600 file, never through --value. An argument is
   # world-readable in `ps` for as long as the call runs, and it lands in your
   # shell history besides. Same reasoning as scripts/preflight.sh, which passes
   # the token to curl through a config file rather than -u.
   TOKEN_FILE="$(mktemp)"                     # 0600, unpredictable name
   trap 'rm -f "$TOKEN_FILE"' EXIT
   read -rs -p 'Grafana token: ' TOKEN; echo   # typed, never on a command line
   printf '%s' "$TOKEN" > "$TOKEN_FILE"; unset TOKEN

   aws ssm put-parameter \
     --name "<loki_ssm_parameter_name from tenant.auto.tfvars>" \
     --type SecureString \
     --value "file://$TOKEN_FILE" \
     --overwrite \
     --region <region> \
     --profile <profile>
   ```

   `--overwrite` is required from the second run onward — the first
   `put-parameter` for a name creates it, and every one after that (i.e.
   every rotation, see below) is against a parameter that already exists;
   without the flag it fails with `ParameterAlreadyExists` instead of
   updating the value.

   `file://` is expanded by the AWS CLI itself, so the value never becomes an
   argument. It stores the file's bytes verbatim, which is why the write above
   uses `printf '%s'` rather than `echo`: a trailing newline becomes part of the
   stored token, and Grafana then rejects it. That failure is invisible from
   here — the converge publishes the token file happily and only the push 401s —
   so verify with `cd cinc && make preflight`, which authenticates the stored
   value per region.

   Do not pass `--key-id` to select a customer-managed key. The VM's bootstrap
   role is granted `ssm:GetParameter` on this one parameter and nothing more —
   no `kms:Decrypt` grant exists for any CMK, because there was never a reason
   to add one. A parameter encrypted under a CMK instead of the default key
   still creates cleanly and still plans clean in Terraform; it only fails when
   a VM actually tries to fetch it, as `AccessDenied`, which by then is days
   after whoever set it up has moved on.
4. Repeat step 3 **in every region you operate** — check `vms/config.tf`'s
   `regions` map for the current list; the skeleton ships three, and the count
   is not fixed. `terraform plan` cannot catch a region you skip: it only
   manages the IAM grant that *names* the parameter, never the parameter's
   value, so a missing region applies clean and then fails silently as
   `ParameterNotFound` the first time that region's `dev-vm-loki-token` script
   runs.
5. Set the three `loki` attributes in `cinc/policyfiles/dev-vm.rb` — §4 lists
   all five values that file needs. The cookbook's `attributes/default.rb`
   defaults only the on/off switch (`enabled = true`), so the policyfile is the
   only place these three live:
   - `default['base']['loki']['url']` — the push URL, from the stack's "Send
     Logs" panel. Not secret.
   - `default['base']['loki']['username']` — the numeric user ID, same panel.
     Not secret.
   - `default['base']['loki']['ssm_parameter_name']` — the parameter name
     `alloy.rb` hands to the fetch script. **Must match
     `loki_ssm_parameter_name` in `vms/tenant.auto.tfvars` byte for byte** —
     the policyfile's own comment says so, and it is worth repeating here: if
     you rename the parameter in `tenant.auto.tfvars` per step 3 without also
     updating this attribute, the IAM grant ends up naming one parameter
     while the script requests another. That plans clean, promotes clean, and
     surfaces on the VM as `AccessDenied` → exit 10 → a green converge with no
     logs — the exact silent failure this whole section exists to prevent.

   Set all three, re-lock with a bare `make bump-cookbook`, then `cd cinc && make push && make promote`. The token
   itself never goes in this file — only these three identifiers do.
6. Create the security alerts and the audit dashboard. Shipping logs nobody is
   alerted on is only half the system: the **six Grafana alert rules**, the
   three audit feeds they read, and which one deserves a human are listed under
   *Security alerting* in [the design record](design/log-shipping.md). (Six
   *alert* rules, in Grafana. The four *Falco* rules are a separate set that runs
   on the VM; their detections are what alert rule 6 fires on.)

   This step creates folder **Developer VMs**, rule group `dev-vm-security` and
   dashboard *Developer VMs — audit trail* in your Grafana stack. The `curl`
   sequence that applies the checked-in definitions is in
   [`grafana/README.md` § Applying](https://github.com/idlefy/vm-platform-aws/blob/main/grafana/README.md#applying).

   This needs a **second, different credential**: a Grafana *service account*
   token with alert-rule write scope. The `logs:write` token from step 2 cannot
   create alert rules, and neither can a `logs:read` one — the Loki data-plane
   endpoint and the Grafana control plane are separate APIs with separate auth.

   **Then create a contact point and point the default notification policy at
   it.** A stack with no contact point routes to a receiver that does not exist,
   so the rules evaluate and fire and nothing is ever delivered — a failure that
   looks exactly like "no alerts have fired". Do this in the UI: alert-rule write
   scope does not carry notification write scope, and the API returns 403 for
   contact points even on an otherwise-admin credential.

   Note that there is deliberately **no alert for a VM that stops shipping.**
   Idlefy stops these VMs when developers finish work, so silence is the normal
   overnight state of the fleet and an absence alert would fire across most of
   it every evening. The consequence, accepted knowingly: a VM whose token is
   wrong in one region ships nothing and nothing announces it at runtime.
7. Run the preflight check, which is what stands in for that missing runtime
   detector:

   ```bash
   cd cinc && make preflight
   ```

   It verifies the parameter exists as a `SecureString` in every region in
   `local.regions`, that its name matches byte for byte between
   `tenant.auto.tfvars` and the policyfile, and that the token **actually
   authenticates against Loki in each region** — which is the only thing that
   catches a rotation that skipped one. Authentication is proven with an empty
   request body (good credentials give `400`; `401` or `403` is a bad token;
   anything else — unreachable, a redirect, a server error — also fails,
   because none of those proves the token), so nothing is ingested and no
   stream is created. It also resolves every `policy_arns` entry
   in `access_bundles.auto.tfvars`, a typo in which is otherwise invisible until
   a VM gets `AccessDenied` days later.

   Run it after step 3 and after every rotation. It is read-only and needs no
   confirmation.

Rotating the token later is steps 2–4 again, for every region — miss one and
that region's VMs get `401`s from Loki indefinitely, since a converge cannot
repair a value it deliberately never manages. `make preflight` is how you find
out immediately instead.

### Turning shipping off on a fleet that is already running

The order matters, and it is not the one that looks natural. `preflight` runs
inside `make promote` and refuses when the policyfile and `tenant.auto.tfvars`
disagree, so the two are edited together and *applied* apart:

1. In `cinc/policyfiles/dev-vm.rb` set `default['base']['loki']['enabled'] = false`.
2. `make bump-cookbook` (bare — re-locks at the current tag; the lock covers
   attributes, and `make push` refuses a lock that does not match).
3. `cd cinc && make push`.
4. In `vms/tenant.auto.tfvars` set `log_shipping = false` and
   `loki_ssm_parameter_name = null`, but **do not apply yet**.
5. `cd cinc && make promote`. Preflight now sees both halves agree.
6. Wait until every VM has converged past the teardown (`knife status`, or the
   Alloy unit gone on each VM), then `cd vms && terraform apply`.

Applying Terraform before step 6 removes the IAM grant while Alloy is still
installed; the token script leaves an existing token untouched when its fetch
is denied, so the fleet keeps shipping on its last token while the tenant
believes shipping is off. Turning it on is the mirror: Terraform first, then
steps 1–3 with `enabled = true`.

## Defaults you may want to change

These are the template's starting values, not leftovers. Each is a deliberate
default a tenant is expected to review:

- **SSM parameter convention** — `/developer-vms/cinc/...` and
  `/developer-vms/observability/...` in the `.example` files, and the derived
  form the `tenant-setup` skill generates. Change it in `tenant.auto.tfvars` to
  whatever naming scheme you prefer; the Loki one must stay byte-identical to
  the policyfile attribute.
- **VPC CIDR `10.8.0.0/16`** in `vms/config.tf` — change if you peer with
  existing networks; otherwise leave as-is.
- **`environment = "dev"`** in `vms/config.tf` and `infra/config.tf` — single
  environment by design; promote to a variable if you need multiple.
- **Region list** in `vms/config.tf` — the skeleton ships three (`us-east-1`,
  `eu-north-1`, `eu-central-1`), and `vms/instances.auto.tfvars` starts with
  entries for the first two. Add one with `cd cinc && make add-region
  REGION=<region>`, which writes the HCL and reminds you of the two per-region
  SSM secrets; remove one by deleting its entry from `local.regions`. There is
  a single unaliased provider driven by one `for_each`, so there are no provider
  or module blocks to add. Note that an organisation may allowlist regions with
  an SCP, and a denied region reports `opt-in-not-required` exactly like an
  enabled one.
