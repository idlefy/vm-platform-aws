---
name: tenant-setup
description: Use when this repository has just been cloned and its tenant configuration is not yet filled in — walks through collecting values, materialising config, resolving the platform pin, and verifying, without deploying anything.
---

# Tenant setup

Take a fresh clone to "deployable in two `terraform apply`s". You write config
and verify it. You do **not** create AWS resources, push CINC policies, or run
Ansible — those are the operator's calls after review.

## First: is this repository already configured?

```bash
for f in vms/tenant.auto.tfvars vms/backend.hcl infra/tenant.auto.tfvars \
         infra/backend.hcl infra/ansible/group_vars/all/tenant.yml \
         cinc/.chef/knife.rb; do
  test -f "$f" && echo "OK      $f" || echo "MISSING $f"
done
./scripts/placeholder-check.sh >/dev/null 2>&1
case $? in
  0) echo "PIN     unresolved" ;;
  1) echo "PIN     resolved" ;;
  *) echo "PIN     could not be checked — stop and investigate before going on" ;;
esac
./scripts/placeholder-check.sh --config >/dev/null 2>&1
case $? in
  0) echo "POLICY  cinc/policyfiles/dev-vm.rb still has REPLACE_ME" ;;
  1) echo "POLICY  filled in" ;;
  *) echo "POLICY  could not be checked — stop and investigate before going on" ;;
esac
```

All `OK`, `PIN resolved` and `POLICY filled in` → this repository is
configured. Stop and say so; the operator wants day-to-day work, which
`CLAUDE.md` covers.

`PIN could not be checked` is neither of those: do not proceed to setup and do
not re-run `make prepare PLATFORM_TAG=…` — report it. Re-running setup against
a tree whose state is unknown is how a live tenant gets its pin rewritten.

Anything else → continue.

## Collect the values

Ask one at a time. Do not accept a blank.

| Key | Example | Notes |
|---|---|---|
| `aws_profile` | `platform-dev` | Must exist in `~/.aws/config`. |
| `aws_region` | `us-east-1` | Terraform state and the provider's own endpoint. |
| `route53_zone_id` | `Z01234567ABCDEFGHIJKL` | An existing zone the tenant owns. |
| `domain_root` | `infra.example.com` | Matches the zone. |
| `cinc_server_fqdn` | `cinc.<domain_root>` | Suggest this; allow an override. |
| `cinc_org_slug` | `platform` | Lowercase, alnum and hyphen. |
| `admin_email` | `ops@example.com` | Let's Encrypt registration and the CINC org admin. |
| `state_bucket` | `platform-tf-state` | Must already exist. |
| `admin_ssh_keys` | `ssh-ed25519 AAAA… name@host` | At least one. |
| `platform_tag` | `v1.0.0` | The Terraform release. You took this skeleton at that tag. |
| `cookbook_tag` | `base-1.0.0` | The cookbook release. |
| `ships_logs` | `yes` | Whether this tenant ships journals to Grafana Cloud Loki. `no` sets both halves of the switch off. |
| `loki_url` | `https://logs-prod-000.grafana.net/loki/api/v1/push` | Only if `ships_logs`. The stack's "Send Logs" panel. Not secret. |
| `loki_username` | `000000` | Only if `ships_logs`. The numeric stack user ID from the same panel — not an e-mail address. |

Derived, do not ask: `cinc_server_url` = `https://{cinc_server_fqdn}/organizations/{cinc_org_slug}`;
`cinc_ssm_parameter_name` = `/developer-vms/cinc/{cinc_org_slug}-validator-key`.
Write that derived value into **both** `vms/tenant.auto.tfvars` and, for the
Loki twin, keep `loki_ssm_parameter_name` there byte-identical to
`default['base']['loki']['ssm_parameter_name']` in the policyfile — `make
preflight` compares them and a mismatch is a green converge that ships nothing.

## Materialise and pin

```bash
make prepare PLATFORM_TAG=<platform_tag>
```

Then substitute the collected values into the six created files. `prepare` never
overwrites, so a re-run is safe.

`cinc/policyfiles/dev-vm.rb` is a **seventh** file to fill in, and `prepare`
cannot touch it — it is checked into the skeleton, not materialised from an
`.example`. It carries five `REPLACE_ME`s:

| Attribute | Value | If it is left as it is |
|---|---|---|
| the `cookbook 'base'` `tag:` | `<cookbook_tag>` — set it with `make bump-cookbook`, never by hand | `chef install` cannot resolve the cookbook |
| `default['base']['loki']['url']` | `<loki_url>`, or delete the line and set `enabled = false` | `base::alloy` fails the converge, naming the attribute |
| `default['base']['loki']['username']` | `<loki_username>`, likewise | same |
| `default['base']['traefik']['acme_email']` | `<admin_email>` | **nothing catches it.** Let's Encrypt is asked to register `REPLACE_ME` |
| `default['base']['traefik']['domain_root']` | `<domain_root>` — `base::traefik` composes `<vm>.ec2.<region>.<domain_root>`, which must be exactly the `fqdn` you give each VM in `vms/instances.auto.tfvars`, inside the Route53 zone | **nothing catches it.** Every published hostname becomes `<vm>.ec2.<region>.REPLACE_ME`, a name ACME cannot resolve and no certificate is issued for |

The two `traefik` rows are the dangerous ones: `base::traefik` interpolates both
unguarded, so a tenant that leaves them converges green. `./scripts/placeholder-check.sh
--config` is what says so; run it again after editing.

If `ships_logs` is `no`: set `default['base']['loki']['enabled'] = false`,
delete the three `loki` lines below it, and set `log_shipping = false` and
`loki_ssm_parameter_name = null` in `vms/tenant.auto.tfvars`. Both halves or
neither — `make preflight` fails if they disagree.

Pin the cookbook:

```bash
make bump-cookbook TAG=<cookbook_tag>
```

## Verify — and never deploy

```bash
./scripts/placeholder-check.sh --all   # must exit 1: nothing left to fill in
make pin-check
( cd vms && terraform init -backend-config=backend.hcl && terraform validate )
( cd vms && terraform fmt -check )
( cd vms && terraform test )
```

`terraform test` needs Terraform ≥ 1.7 for `mock_provider`. `plan` and `apply`
work on the declared `>= 1.5.0` floor, so an older Terraform can deploy this
repository but not test it — say so rather than skipping the check silently.

`terraform init` fails if the state bucket does not exist, or if the SSH agent
holds no key for the upstream repository. Both are real errors, not noise: the
platform modules are fetched from upstream at `init` time.

**Never run `terraform plan` against a bucket you have not confirmed, never
`apply`, never `make push`, never `make promote`.** Hand off instead:

> Tenant config written and verified. To deploy:
> 1. `aws sts get-caller-identity --profile <profile>`
> 2. `cd infra && terraform plan` → review → `terraform apply`
> 3. `cd infra/ansible && ansible-playbook -i inventory.yml playbooks/cinc-server.yml`
> 4. `cd cinc && make push` — then converge a `policy_group = "staging"` VM
>    and confirm it came up on that revision, and run `make preflight`. Only
>    then `make promote`: it runs preflight itself, refuses unless staging
>    already carries the committed lock's revision, and still asks for a typed
>    confirmation.
> 5. Add your first VM to `vms/instances.auto.tfvars`, then `cd vms && terraform plan`.
