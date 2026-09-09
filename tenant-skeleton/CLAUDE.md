# vm-platform-aws tenant — agent guide

This repository deploys developer VMs on AWS. The CINC cookbook and the two
Terraform modules are **pinned artifacts published elsewhere** — there is no
copy of either here, and a change to them is not made in this repository.

The mechanisms and the evidence behind them live in the pinned upstream
checkout, which `terraform init` has already placed at
`.terraform/modules/ec2/` — the whole repository, at exactly the commit
`local.platform_pin.sha` names. When something below says *why*, that is
where the long form is.

---

## Hard rules

Never override without explicit user instruction in the current conversation.

1. **Never `terraform apply` without showing the plan first** and getting explicit user approval. Same for `terraform destroy`.
2. **Never run `make promote` without `make push` + staging verification first.**
3. **Never manual-ops on VMs** (`apt-get`, `systemctl`, file edits). If something's wrong, fix the CINC recipe and re-converge. Manual edits get reverted on the next 30-min run anyway.
4. **Never read `infra/ansible/group_vars/all/vault.yml` contents.** It's encrypted with `ansible-vault` — even decrypted, the contents are secrets that should not appear in conversation history.
5. **Never use `git push --force` on `main`** without the user explicitly saying "force push".
6. **Use the Makefile, not raw `chef` / `knife` commands.** The Makefile encodes the lint + install + push flow correctly.
7. **Run `terraform plan` before recommending anything destructive** — your model of state may be stale.
8. **Never echo a secret's value.** The CINC validator key is reachable via
   `aws ssm get-parameter --with-decryption` from a workstation holding these
   credentials. Report exit status; never the value. Rule 4 covers `vault.yml`;
   this covers SSM, which is not encrypted at rest from your point of view.

---

### Create a VM

1. Edit `vms/instances.auto.tfvars`: add an entry under the region, plus the developer's SSH key. Optionally set `aws_access = ["<bundle>", …]` to grant AWS permissions — bundle names must already exist in `vms/access_bundles.auto.tfvars`.
2. Run `cd vms && terraform plan` and show the user the plan.
3. Only `apply` after the user approves.
4. The VM auto-bootstraps via `user_data` — wait ~3 minutes, then SSH via EC2 Instance Connect to verify CINC ran.

Every VM is tagged `idlefy = "enabled"` by default (`idlefy_managed` in
`vms/tenant.auto.tfvars`), which is what lets Idlefy find it and stop/start it.
A VM that Idlefy must never touch — a long-running build box, a demo host —
gets `tags = { idlefy = "disabled" }` in its `instances.auto.tfvars` entry; the
per-VM tag wins over the flag. Do not spell the key `Idlefy`: only lowercase
`idlefy` matches Idlefy's IAM condition, and a VM with the wrong key looks
managed in the console and is not.

Adding a *new* bundle (rather than reusing an existing one) means filling in its
`allowed_actions`. Read the policy document to get them — `aws iam
get-policy-version` — and take the service namespaces from the policy's own
statements, not from its description or its name. The description is prose and is
routinely stale; `allowed_actions` is the ceiling the VM's permissions boundary
enforces, so a namespace missing from it turns into an `AccessDenied` on the VM,
and a namespace wrongly added to it silently widens the ceiling.

### Delete a VM

All three steps are required — Terraform doesn't know about CINC state:

1. Remove the entry from `vms/instances.auto.tfvars`.
2. `cd vms && terraform plan` (verify only the target VM is destroyed) → `terraform apply`.
3. `cd cinc && make node-delete NODE=<name>` — removes the node and its client from CINC.
4. **If the developer ever ran `sudo tailscale login` on it, remove the node from
   the tailnet too.** Terraform does not know about it and `make node-delete` does
   not touch it, so `terraform destroy` leaves an authorised node registered under
   a named person until its key expires. VM names are reused by convention here,
   so the next VM with the same hostname joins as `<name>-1` while the stale one
   still holds the original name. Removal is done by the device's owner or a
   tailnet admin, in the Tailscale admin console — not from this repo.

No manual AWS cleanup is needed: the VM's two IAM roles, its permissions boundary
and its `/developer-vms/access/<vm>` SSM parameter are all Terraform resources and
are destroyed in step 2. But note that the identity role ARN is retired with it —
recreating a VM with the same name later produces a role with the same ARN but a
**new unique ID**, so any grant a resource owner made against the old role (an
`aws:PrincipalArn` condition is fine; a trust policy or a resource policy that
captured the old role's unique ID is not) stops matching and has to be reissued.
---

### The policyfile's tenant values

`cinc/policyfiles/dev-vm.rb` is the only cookbook file in this repository, and
it carries every value the cookbook needs from this tenant:

| Attribute | What it is | What checks it |
|---|---|---|
| the `cookbook 'base'` `tag:` | the published cookbook release | `make pin-check`; set it only with `make bump-cookbook` |
| `default['base']['loki']['enabled']` | the recipe half of the log-shipping switch | `make preflight`, against `log_shipping` in `vms/tenant.auto.tfvars` |
| `default['base']['loki']['ssm_parameter_name']` | the SSM parameter `alloy.rb` fetches the token from | `make preflight`, byte for byte against `loki_ssm_parameter_name` |
| `default['base']['loki']['url']` | the Grafana Cloud push URL. Not secret | `base::alloy` fails the converge on empty or `REPLACE_ME` |
| `default['base']['loki']['username']` | the numeric stack user ID. Not secret | same |
| `default['base']['traefik']['acme_email']` | the address Let's Encrypt registers | **nothing** |
| `default['base']['traefik']['domain_root']` | the DNS suffix of each VM's `fqdn`; `base::traefik` composes `<vm>.ec2.<region>.<domain_root>` | **nothing** |

The last two rows are the trap: `base::traefik` interpolates both unguarded, so
a `REPLACE_ME` left there converges green and then asks Let's Encrypt for a
certificate for a name that does not resolve. `./scripts/placeholder-check.sh
--config` is the only thing that says so — run it after editing the policyfile,
and expect exit 1.

The token itself never goes in this file. It lives in SSM, per region, placed by
hand; see *Per-region secrets* below.

### Deploy a cookbook change

The cookbook is not here. To adopt a published release:

```bash
make bump-cookbook TAG=base-X.Y.Z   # rewrites the policyfile pin and the lock
git diff                            # review both files before committing
cd cinc
make push       # → staging policy group (gated by pin-check)
# wait for a staging VM to converge, or `sudo cinc-client` on it
make promote    # → production
```

`make promote` requires interactive `yes`; don't bypass it.

### Deploy a Terraform platform change

Raising the platform pin is **three edits in one commit**: `local.platform_pin`
in `vms/main.tf`, and the `?ref=` on **both** module `source` lines. A module
source is a literal — Terraform will not interpolate the pin into it — so
nothing but `make pin-check` keeps the three together, and two module calls at
different commits plan cleanly while building the fleet from two revisions.

```bash
$EDITOR vms/main.tf      # local.platform_pin.tag, .sha, and both source lines
make pin-check
cd vms && terraform init -upgrade && terraform plan
```

`terraform init` without `-upgrade` does **zero** work for a module whose SHA
changed in a file it has already cached — measured. The plan you review would
be against the old content.

### Verify your own edits

None of this needs an AWS account, so there is no excuse for skipping it:

```bash
cd vms && terraform fmt -check && terraform init -backend=false && terraform validate && terraform test
make pin-check
```

`terraform test` needs Terraform **≥ 1.7** for `mock_provider`; `plan` and
`apply` work on the declared `>= 1.5.0` floor, so a version that can deploy this
repository can fail to run its tests. `vms/tests/skeleton.tftest.hcl` gates the
wiring — that this root passes the right things to the right modules and that
both fleet guards can still fire. The modules themselves are gated upstream.

Then, before an `apply` or a `promote` that touches deployed config:

```bash
cd cinc && make preflight     # needs AWS; read-only, ingests nothing
```

---

## Traps

Every one of these has actually happened. They share a shape: the command exits
0 and the damage surfaces somewhere else, later.

**Adding a region is one entry in `local.regions`, and the region may not be
allowed.** `vms/main.tf` drives regions with a single `for_each` over
`local.regions` against one unaliased provider, so there is no provider, module,
output or test fixture to add. Use `cd cinc && make add-region REGION=<region>`.

The trap is not the HCL, it is the account: **an organisation may allowlist
regions with an SCP, and opt-in status does not reveal it.** A denied region
reports `opt-in-not-required` — the same as a normally-enabled one — and then
fails every EC2 call with `UnauthorizedOperation … explicit deny in a service
control policy`. Measured on the original deployment, whose SCP allowed four of
every region AWS reported as enabled. If this account has such a policy, record
the allowed list here for the next agent; the absence of a note is not evidence
there is none. Do not diagnose it from an AWS CLI call whose stderr you
discarded — an SCP denial then looks like "no matching AMI".

**Do not restore per-region provider aliases**, and do not drop the AWS provider
below `~> 6.0`. Per-resource `region` is a v6 feature; on v5 every resource
silently lands in `local.provider_region` — one region for the whole fleet, with
a clean plan and no warning.


**Do not move the AMI to 26.04. It was rolled back on 2026-08-05, on purpose.**
`ami_name_pattern` in `vms/variables.tf` names 24.04 (noble) and the newer
release is not an upgrade waiting to be applied: `sudo-rs` writes **no record of
a denied escalation attempt**, `rust-coreutils` changes the `stat` output the
credential broker parses, and CINC publishes no 26.04 build. The full evidence
is in that variable's own comment and in the pinned upstream. If a future
release has to be adopted, the gate is a live VM — not a changelog.


**`key_name` and `az` are ForceNew, and the root volume is deleted with the
instance.** Rotating a developer's SSH key or moving their AZ replaces the
instance, and `delete_on_termination` is at its default — so a routine-looking
edit deletes the developer's entire working disk. Nothing in the module
distinguishes this from a safe change; the plan does. Read it for
`must be replaced` before every apply, and snapshot the volume first if the
disk matters. (Decision recorded 2026-08-24: behaviour deliberately unchanged —
document, not `delete_on_termination=false`.)


**A converge that restarts Falco can leave it crash-looping, and the unit hides
why.** `falco-modern-bpf.service` is `Restart=on-failure` with
`StandardOutput=null`, so a restart landing while the eBPF probe is still
opening dies and re-dies every fifteen seconds while `systemctl is-active`
reports `active` — and the reason never reaches journald. It reads exactly like
a bad new rule: zero detections, a green unit, `schema validation: ok`.

Two things say it is this: alert 6 fires on Falco's own `Falco internal: hot
restart failure`, and `sudo journalctl -u falco-modern-bpf` shows startups ~15s
apart, each stopping at `Trying to open the right engine!`. Clear it with
`systemctl reset-failed falco-modern-bpf` and one `start`; diagnose by running
`sudo /usr/bin/falco -o engine.kind=modern_ebpf` in the foreground, where stdout
is not discarded. Before blaming a rule for zero detections, fire an event a
known-good rule catches — reading `/etc/sudoers` trips `Read sensitive file
untrusted`.


**A test VM is not cleaned up by `terraform destroy` alone.** Follow all four
steps in *Delete a VM*, including `make node-delete`, or the CINC node lingers
and the next VM reusing that name inherits stale registration. A VM that was ever
logged into the tailnet needs step 4 as well.


**Every `tailscale login` discards the current profile before contacting the
control plane.** The CLI calls `SwitchToEmptyProfile` first, so a *re*-login takes
the VM off the tailnet the moment the command starts, before any browser step. If
the developer abandons it there, the VM stays off and the old profile is
unreachable, because `switch` and `up` are both denied to them — the only recovery
is completing a fresh login. Any pref an admin set is also silently reset by the
next developer login. This is CLI behaviour, not something the recipe can fix;
document it, do not try to work around it.

---


**A cookbook pin bump is two files, and `make bump-cookbook` is the only way to
make them agree.** The policyfile records the tag; the lock records the commit
that tag named at resolve time. Editing the policyfile by hand leaves the lock
on the old revision, and `make push` then uploads the old cookbook while every
diff says otherwise. `make pin-check` is what catches it.

---

**The two spellings of the log-shipping switch are one change, and
`make preflight` is the check.** `log_shipping` in `vms/tenant.auto.tfvars`
controls the IAM grant; `default['base']['loki']['enabled']` in the policyfile
controls the recipe. Drift in the recipe-on / Terraform-off direction is the
bad one: `dev-vm-loki-token` exits 10 every converge **and Alloy keeps shipping
with the last token it fetched** — the script leaves an existing token untouched
on failure — so the VM reports off and is not. Turning off: policyfile first,
wait for every VM to converge past the teardown, then Terraform. Turning on:
Terraform first, then the policyfile.

Bumping the pin adds `terraform_data.assert_log_shipping_inputs` once per
region; that is the module's input guard for `log_shipping` /
`loki_ssm_parameter_name`, not drift.

---

## Per-region secrets

Two SSM parameters must exist as `SecureString` in **every** region
`config.tf` configures, and Terraform manages neither — it manages only the IAM
grant that *names* them, so a missing or misnamed parameter applies clean and
fails later, at first boot or at first log push:

| Parameter | Created by | Failure if absent |
|---|---|---|
| `cinc_ssm_parameter_name` | by hand, from `/etc/cinc-project/<org>-validator.pem` on the CINC server (the Ansible role creates it there) | the VM never converges, three minutes after apply reported success |
| `loki_ssm_parameter_name` | by hand, from the Grafana Cloud token — only when `log_shipping = true` | the VM converges and ships no logs while reporting healthy |

The region count is not fixed: adding a region means creating both parameters in
it. `cd cinc && make preflight` is what proves they exist, that the Loki token
still authenticates, and that every `policy_arns` entry resolves — read-only,
and it ingests nothing.

Never print either value. Report exit status instead.

---

## When upstream is unreachable

A fresh clone cannot `terraform init`, therefore cannot `plan`, therefore cannot
`destroy` a compromised VM. That is the cost of pinning, and the way out is
local:

```bash
git clone https://github.com/idlefy/vm-platform-aws.git /tmp/platform
git -C /tmp/platform checkout <local.platform_pin.sha>
```

For the cookbook, point `cinc/policyfiles/dev-vm.rb` at it with
`path: '/tmp/platform/cinc/cookbooks/base'`, then `make bump-cookbook && make
push`. For Terraform, point both `source` lines at
`/tmp/platform/vms/modules/<name>`.

Both are **temporary**: the tree is then unpublishable and `make pin-check`
refuses it. Open the upstream fix immediately, and revert to a real pin as soon
as there is one.
