# Optional log shipping — design

> Design record, written during development; identifiers anonymised. Numbers are as measured.

**Date:** 2026-09-05
**Status:** approved in conversation (scope, switch shape, off-path behaviour); technical decisions delegated to the implementer; revised after an adversarial architect review (4 blocking, 9 important, 5 minor findings — all incorporated below). Not yet implemented.
**Input:** a tenant may not run Grafana Cloud at all. Today the platform assumes every VM ships its journal to Loki: the cookbook installs Alloy unconditionally, the module grants the Loki SSM parameter unconditionally, `preflight` fails without a token, and `docs/runbook.md §7` is a mandatory step.

## Decisions already taken

- **Scope is log shipping only.** The switch covers `base::alloy`, the Loki token
  on disk, the IAM grant that lets the VM fetch it, and every tenant-side check
  that assumes them. **Falco stays unconditional.** It is a security control,
  it writes to the local journal regardless of Alloy, and `journalctl -u
  falco-modern-bpf` on the VM remains a usable incident trail. A tenant with
  shipping off simply has nothing reading Falco remotely. The Falco / sudoers
  / Tailscale traps in `CLAUDE.md` are untouched.
- **One flag, spelled twice, cross-checked by `preflight`.** A tenant has two
  configuration surfaces that cannot see each other: `vms/tenant.auto.tfvars`
  (Terraform) and `cinc/policyfiles/dev-vm.rb` (node attributes; user_data
  writes only `policy_name`/`policy_group` into `client.rb`, there is no
  first-boot JSON). This is exactly how `loki_ssm_parameter_name` already
  works — named in both files, byte-compared by `preflight` — so the flag
  follows the same pattern rather than inventing a third channel. Rejected:
  implicit "off = attributes absent" (a forgotten value becomes
  indistinguishable from a deliberate choice, and `preflight` loses the check
  it has today), and an instance tag read from IMDS (user_data explicitly
  refuses to let a tag holder influence code paths).
- **The recipe is honest in both directions.** `enabled = false` on a VM that
  already runs Alloy tears it down: stop, disable, purge, delete the token,
  remove the `alloy` account. A switch that only affects fresh VMs would keep
  shipping with the last token it fetched while reporting "off" — the
  CLAUDE.md trap shape (exit 0, damage elsewhere, later). Deleting the token
  matters on its own: an unmonitored VM must not keep a live Grafana Cloud
  write credential on disk that IAM can no longer refresh but nobody revokes.
- **Default is `true` everywhere.** Existing tenants bump the cookbook and the
  module and observe no change. Only the skeleton example files spell the flag
  out, so a new tenant sees it. **Existing tenants need a hand migration to
  be able to flip it** (§E0) — the skeleton is materialised once by
  `make prepare`, and a platform-pin bump touches three lines in `vms/main.tf`
  and nothing else.

## Principles

1. **Fail closed on contradiction.** `log_shipping = false` with a Loki
   parameter name still set, or the two surfaces disagreeing, stops `plan` or
   `preflight` respectively. No guessing which half the tenant meant.
2. **The pair stays a pair.** Anything that exists only because Alloy exists
   (the unattended-upgrades blacklist entry *and* its `Origins-Pattern` line,
   the IAM grant, the SSM checks) reads the same flag. No second predicate.
3. **Tests first, offline, and gating.** Every new branch gets a `terraform
   test` run or a ChefSpec example that runs with `mock_provider` / no AWS, and
   the release gate for the stream runs them (§A6).
4. **Hard rule 2 holds:** module input changes and `tenant-skeleton/` land in
   one commit; `make smoke` gates it.
5. **Claims about system behaviour are measured, not assumed.** Where this
   spec says "measure", the implementer records the result in the code
   comment, the way `CLAUDE.md` does.

---

## A. Cookbook (`base-0.13.0`)

### A1. Attribute

New file `cinc/cookbooks/base/attributes/default.rb`:

```ruby
default['base']['loki']['enabled'] = true
```

with a comment pointing at this spec and at the Terraform twin
(`log_shipping`). The other three `loki` attributes keep living only in the
tenant policyfile, as today; the cookbook does not default them. `docs/runbook.md`
§2 item 5 currently says "there is no `attributes/` directory in this
cookbook" — that sentence is updated in §D.

### A2. `base::alloy` — two branches

```ruby
unless node['base']['loki']['enabled']
  # teardown resources (below)
  return
end
# existing recipe, unchanged, plus the guard in "Enabled branch addition"
```

Teardown, in this order. Every resource is self-contained in the disabled
branch — **nothing in it may `notifies` a resource declared below the
`return`**, because a notification to a resource absent from the collection
raises `ResourceNotFound` at the end of compile and aborts every converge on
every VM with shipping off.

| Resource | Action | Note |
|---|---|---|
| `service 'alloy'` | `[:stop, :disable]`, no guard | the systemd provider already no-ops stop/disable when the unit is absent; a unit-file `only_if` was tried and cookstyle 9.0.0 (CI) rejects it as `Chef/RedundantCode/ServiceGuardOnStopDisable` |
| `package 'alloy'` | `:purge` | binary, unit, conffiles |
| `directory '/etc/alloy'` | `:delete`, `recursive true` | holds `config.alloy` **and `loki-token`** — the credential. Purge may or may not remove it (conffile handling); delete explicitly |
| `directory '/var/lib/alloy'` | `:delete`, `recursive true` | the WAL (`postinst` creates `/var/lib/alloy/data` 0770 `alloy:alloy`): buffered, undelivered journal lines on a VM whose tenant does not want shipping |
| `file '/usr/local/sbin/dev-vm-loki-token'` | `:delete` | the fetch script |
| `file '/etc/apt/sources.list.d/grafana.list'` | `:delete` | **no `apt-get update` notification.** Deleting the list file is what stops apt polling apt.grafana.com; the next `apt-get update` from any recipe or from unattended-upgrades drops the cached index. |
| `file '/etc/apt/keyrings/grafana.asc'` | `:delete` | pairs with the list file |
| `user 'alloy'` | `:remove` | see below |
| `group 'alloy'` | `:remove` | the primary group `postinst` creates with `groupadd -r`; removed explicitly rather than via `USERGROUPS_ENAB` |

**Why `user 'alloy'` is explicit.** Measured 2026-09-05 against
`alloy-1.18.0-1.amd64.deb`: the package ships `conffiles control md5sums
postinst prerm` — **no `postrm` at all** — and nothing in its scripts removes
the user or group `postinst` creates (`groupadd -r alloy`, `useradd -m -r -g
alloy -d /var/lib/alloy`). `alloy.rb:76-86` adds that user to
`systemd-journal` and `adm`, so without this resource the "off" VM keeps an
account with system-journal read rights — the residue the third decision
above promises not to leave. `userdel` drops the group memberships with the
account, so no counterpart to the two `group :modify` resources is needed.

Do not touch `/etc/apt/keyrings` itself. Nothing else in the cookbook uses
that directory (every other recipe keys into `/usr/share/keyrings`); it stays
because deleting it buys nothing and `alloy.rb:7` recreates it on re-enable
anyway.

**Enabled branch addition.** Before the template, raise with a named message
if `node['base']['loki']['url']` or `['username']` is empty **or equals
`REPLACE_ME`**. The skeleton ships both as the literal `'REPLACE_ME'`
(`tenant-skeleton/cinc/policyfiles/dev-vm.rb:7-8`). Measured 2026-09-05 with
the pinned 1.18.0 binary against the rendered template: `alloy validate`
returns 0 for `url = ""`, for `url = "REPLACE_ME"` and for a real URL alike,
so the template's `verify` guard (`alloy.rb:241`) catches neither bad value
and this raise is the only check. The raise lives in a `ruby_block` so it
fires at converge, not at compile: `base::alloy` is last in `base::default`,
so every hardening recipe has already applied when it fails, and a
placeholder tenant is left with a hardened VM and a failed run rather than a
public VM with nothing applied. It is a behaviour change only for a tenant
still carrying the placeholders, who today converges green and ships nothing;
`docs/runbook.md §5` is updated to say so (§D). No working tenant has either value
(§E1).

The trailing comment in `default.rb` about `base::alloy` being last stays
true: the disabled branch has no SSM call, and the enabled branch is
unchanged.

### A3. `base::unattended_upgrades`

Both Grafana lines read the flag: `Package-Blacklist` renders `"alloy";` and
`Origins-Pattern` renders `"site=apt.grafana.com";` only when
`node['base']['loki']['enabled']`. Leaving the origin line unconditional
would be harmless (the source list is gone), but it would leave a
feature-upgrade channel declared for a repo the teardown removed, and the
next reader would "fix" one half and not the other — the exact asymmetry
principle 2 forbids. `"falco";` and Falco's origin stay unconditional. The
long comment above the resource gains one sentence naming the flag.

### A4. Tests (`cd cinc && make test`)

ChefSpec ships with Cinc Workstation 26 (the CI cookbook job asserts it).
`make test` runs `chef exec rspec` from the cookbook directory, rspec's
default pattern picks up `spec/**/*_spec.rb`, and ChefSpec resolves
`cookbook_path` by walking up to `metadata.rb` — so `spec/recipes/` needs no
`spec_helper` and no policyfile resolution. The existing `spec/imds_spec.rb`
is plain rspec against the library; mixing is fine, each file requires what
it needs.

- `spec/recipes/alloy_spec.rb`, `ChefSpec::SoloRunner`, platform ubuntu
  24.04, no `step_into`.
  - `enabled = false`: expects `stop`/`disable` on `service[alloy]`, `purge`
    on `package[alloy]`, `delete` on the directory and the three files,
    `remove` on `user[alloy]`; expects **no** `template[/etc/alloy/config.alloy]`
    and no `execute[dev-vm-loki-token]` in the resource collection.
  - `enabled = true` with url/username set: expects `install` on the package,
    the template, and `enable`/`start` on the service. Region: stub
    `DevVm::Imds.region` (not `Mixlib::ShellOut` — `libraries/imds.rb:57`
    uses it too). Public IP: set `node.automatic['ec2']['public_ipv4']` in
    the runner block; `alloy.rb:140` then takes the Ohai branch and the
    IMDS `shell_out` is never reached, so no recipe refactor is needed.
  - `enabled = true` with `url = ''` and with `url = 'REPLACE_ME'`: expects
    the converge (stepping into `ruby_block`) to raise with the named message.
- `spec/recipes/unattended_upgrades_spec.rb`: the rendered
  `52unattended-upgrades-overrides` content contains `"alloy";` and
  `"site=apt.grafana.com";` when enabled and neither when disabled; contains
  `"falco";` in both.

### A5. Version

`metadata.rb` → `0.13.0`. New attribute with behaviour attached is a minor
bump; `make release TAG=base-0.13.0` refuses anything else.

### A6. Release gate

`make release TAG=base-*` runs `lint`, `test-broker`, `test-loki-token`
(`Makefile:85-87`) — **not `make test`**. CI runs it, so a PR is covered, but
a release is not. Add `$(MAKE) -C cinc test` to that arm, and to the
`CLAUDE.md` "Verify your own edits" line, in the cookbook PR. The
`ci.yml` header says those two lists move together.

---

## B. Terraform (module `ec2` + `tenant-skeleton`, one commit, `v3.3.0`)

### B1. Module inputs

```hcl
variable "log_shipping" {
  description = "Ship the VM journal to Grafana Cloud Loki. Twin of the cookbook attribute base.loki.enabled; preflight checks the two agree."
  type        = bool
  default     = true
}

variable "loki_ssm_parameter_name" {
  type    = string
  default = null
  # existing regex validation stays, guarded: var == null || can(regex(...))
}
```

(`nullable = true` is the default for input variables and is not written.)

The cross-variable rule cannot live in a `validation` block: the module
declares `required_version = ">= 1.5.0"` and cross-object references in
variable validation need 1.9. It lives in a `terraform_data` with a
`precondition`, the shape `tenant-skeleton/vms/main.tf` already uses for its
assert resources:

- `log_shipping && loki_ssm_parameter_name == null` → "log_shipping is true
  but loki_ssm_parameter_name is unset; the VM would converge and ship
  nothing."
- `!log_shipping && loki_ssm_parameter_name != null` → "log_shipping is
  false but loki_ssm_parameter_name is set; pick one — the IAM grant and the
  recipe would disagree."

Preconditions and resource expressions are evaluated in the same graph walk,
so **the IAM expression must be null-safe on its own** (B2); otherwise the
contradictory input surfaces as "Invalid template interpolation value" from
`iam.tf` instead of the message above, and B1 buys nothing.

### B2. IAM

`"${null}"` inside a template is an error in HCL, not an empty string. So:

```hcl
locals {
  loki_parameter_arn = var.loki_ssm_parameter_name == null ? "" : "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.loki_ssm_parameter_name}"
}
# in the bootstrap policy:
Resource = compact([cinc_arn, access_arn, var.log_shipping ? local.loki_parameter_arn : ""])
```

The grant disappears entirely when shipping is off rather than degrading to
`parameter/`. The comment block that lists `/etc/alloy/loki-token` among the
things a snapshot exposes stays: `client.pem` is still there and the
enumeration is still correct when the flag is on.

### B3. Skeleton

- `vms/variables.tf`: `log_shipping` (default `true`) and nullable
  `loki_ssm_parameter_name`, descriptions copied from the module.
- `vms/main.tf`: both passed through.
- `vms/tenant.auto.tfvars.example`: the two lines adjacent, with a comment
  naming the policyfile twin and `make preflight`.
- `cinc/policyfiles/dev-vm.rb`: `default['base']['loki']['enabled'] = true`
  above the three existing `loki` lines, with a comment: "false ⇒ delete the
  three lines below." Nothing in the repo checks the policyfile for a
  leftover `REPLACE_ME` (`placeholder-check.sh` greps `__PLATFORM_*__` under
  `vms/` only); with `enabled = false` the recipe ignores them, and
  `preflight` (C1) prints a `warn` naming the leftover lines.
- `vms/tests/skeleton.tftest.hcl`: the top-level `variables` block gains
  `log_shipping = true`. The file's own header rule requires every variable
  set explicitly, defaults included, so the smoke test never plans against
  production data by omission.
- `scripts/smoke.sh`: `MIN_RUNS` 4 → 5. The floor exists so a deleted run
  cannot leave the gate green; a new run without a raised floor is exactly
  that hole. `smoke.sh` is not in `test-skeleton-sync`'s `SHIPPED` list, so
  no mirror.

### B4. Tests

`vms/modules/ec2/tests/validation.tftest.hcl` (+3 runs):

- `shipping_off_without_a_parameter_plans`
- `shipping_off_with_a_parameter_is_rejected` (`expect_failures` on the
  `terraform_data`)
- `shipping_on_without_a_parameter_is_rejected` — and the assertion must be
  the precondition's message, which is what proves B2's null-safety.

`vms/modules/ec2/tests/hardening.tftest.hcl` (+1 run), **not** validation:
`validation.tftest.hcl` sets `instances = {}`, and
`aws_iam_role_policy.bootstrap` is `for_each = var.instances`, so a grant
assertion there passes vacuously against nothing. `hardening.tftest.hcl`
already carries an instance fixture.

- `shipping_off_drops_the_loki_grant`: asserts
  `aws_iam_role_policy.bootstrap["<fixture>"].policy` does not contain
  `parameter/test/loki` and still contains the CINC parameter ARN. The account
  id comes from the mocked `aws_caller_identity`, known at plan.

Module total 18 → 22. `tenant-skeleton/vms/tests/skeleton.tftest.hcl` (+1 run
→ 5): `a_tenant_with_shipping_off_plans` with `log_shipping = false`,
`loki_ssm_parameter_name = null`.

`CLAUDE.md` "Verify your own edits" gets the new counts.

---

## C. Tenant tooling (`scripts/` mirrored byte-for-byte to `tenant-skeleton/scripts/`; `test-skeleton-sync` enforces it and its `SHIPPED` list already names both files)

### C1. `preflight.sh`

**Reading Terraform.** `CONSOLE_EXPR` gains `shipping = var.log_shipping`.
The Python block today does `shlex.quote(c["loki"])`, which raises
`TypeError` on `None` and on a `bool`. Worse: `REGIONS=` is already on stdout
when it raises, so `VARS` is non-empty, the `[ -z "$VARS" ]` guard does not
fire, and the script dies later at `$PROFILE: unbound variable` under
`set -u` with no diagnostic. Therefore:

- `LOKI_PARAM` from `c["loki"] or ""`; `LOG_SHIPPING` from
  `str(c["shipping"]).lower()`.
- The Python collects all lines in a list and prints them **once**, after
  the last one is built, followed by a sentinel line `PREFLIGHT_VARS_OK=1`.
  The shell checks the sentinel after `eval`, not just non-emptiness, so a
  partial emit is a named failure ("could not read tenant configuration")
  rather than `set -u`.

**Reading the policyfile.** Both matchers run over the file with comment
lines stripped first (`sed '/^[[:space:]]*#/d'`); today's `pf_attr` leads
with `.*` and would read a commented-out line as live. A second matcher
reads the unquoted boolean: `['enabled']\s*=\s*(true|false)`. Absent ⇒
`true`, because that is the cookbook default, and the `ok` line says
"policyfile does not set enabled — cookbook default true applies" rather
than assuming silently.

**New section, before the parameter-name section:** "Log shipping flag agrees
across Terraform and the policyfile". Disagreement is `bad`, both values
printed.

**When both say off:** the parameter-name section, the `loki` half of
"Per-region SSM parameters exist", and "Loki token authenticates" print one
`ok "log shipping disabled — skipped"` each. If the policyfile still carries
`url`, `username` or `ssm_parameter_name`, `warn` naming them (see B3). The
`cinc` half and the bundle-ARN section run as today.

**When both say on:** unchanged.

### C2. `add-region.sh`

The post-run guidance lists the Loki token as a per-region secret. The line
gains "(skip if `log_shipping = false`)". Nothing else in the script reads
the flag; `preflight` proves the region, and it now knows.

### C3. Skeleton `Makefile` / `cinc/Makefile`

No change. `bump-cookbook` is how a tenant re-locks after editing the
policyfile, and that is the path to flip the flag.

---

## D. Documentation

- `docs/runbook.md` (§7 sentence and the `log_shipping` mention in §2 belong to the
  Terraform PR; §5 and the `attributes/` correction belong to the cookbook
  PR): §7 opens with "If this tenant does not use Grafana Cloud, set
  `log_shipping = false` in `vms/tenant.auto.tfvars`, set
  `default['base']['loki']['enabled'] = false` and delete the other three
  `loki` lines in the policyfile, and skip this section." §2 item 5 loses
  "there is no `attributes/` directory in this cookbook" and says instead
  that the cookbook defaults only `enabled`. §5's paragraph on shipping not
  working yet gains "unless `log_shipping = false`, in which case Alloy is
  not installed at all."
- `cinc/README.md`: the recipe list (line 39), the unattended-upgrades table
  row for Grafana (line 111), the "Audit trail (Grafana Alloy)" section
  (126-154) and the `dev-vm` run-list table (481) each get the qualifier
  "when `base.loki.enabled` (default true)"; the audit-trail section gains a
  short paragraph listing what the teardown removes and the measured
  `alloy validate` fact behind the guard.
- `tenant-skeleton/CLAUDE.md` "Per-region secrets": the `loki_ssm_parameter_name`
  row becomes "only when `log_shipping = true`". New **Traps** entry: the two
  spellings of the flag are one change and `make preflight` is the check;
  drift in the recipe-on / Terraform-off direction means `dev-vm-loki-token`
  exits 10 every converge **and Alloy keeps shipping with the last token it
  fetched** (the script leaves an existing token untouched on failure), so
  the VM reports off and is not.
- `vms/README.md` "Grafana Cloud Loki token in SSM": one sentence that the
  section applies when `log_shipping` is true.
- `grafana/README.md`: no change. A tenant with shipping off is not in that
  Grafana. Note for the backlog absence-alert item: it must scope to tenants
  with shipping on.
- `cinc/cookbooks/base/recipes/falco.rb` header: "feeds the same pipeline
  base::alloy builds, when that pipeline is enabled; Falco does not depend
  on it."
- `docs/design/log-shipping.md`: one-line
  pointer at the top to this spec.
- `tenant-skeleton/.claude/skills/tenant-setup/SKILL.md`: verified, no
  Loki mention, no change.

---

## E. Rollout

### E0. Migration for existing tenants (new)

The skeleton is materialised **once** by `make prepare`. Raising the
platform pin is three edits in `vms/main.tf` and nothing else
(`tenant-skeleton/CLAUDE.md:89-91`). After E2 an existing tenant therefore
has a module that accepts `log_shipping`, a root that neither declares nor
passes it, a `preflight.sh` that does not know it, and a policyfile with no
`enabled` line. Setting `log_shipping = false` in tfvars fails with "Value for
undeclared variable". Nothing gates a tenant's copy — `test-skeleton-sync`
proves the *platform's* two copies agree, never a tenant's.

So `tenant-skeleton/CLAUDE.md` gets a section "Adopting v3.3.0" with the hand
edits, and `docs/runbook.md` links to it:

1. `vms/variables.tf`: add the `log_shipping` block and make
   `loki_ssm_parameter_name` `default = null`, copied from the tag.
2. `vms/main.tf`: add `log_shipping = var.log_shipping` to the `module "ec2"`
   block.
3. `scripts/preflight.sh` and `scripts/add-region.sh`: copy from the tag.
4. `cinc/policyfiles/dev-vm.rb`: add the `enabled` line; `make bump-cookbook`.
5. `vms/tests/skeleton.tftest.hcl`, if the tenant kept it: add
   `log_shipping = true` to `variables`.

Tenants that keep shipping on may skip 1–3 indefinitely (defaults hold) but
step 3 matters even for them: an old `preflight.sh` against a new module
still works, but reports nothing about the flag.

### E1. Cookbook PR

A1–A6, cookbook docs. `make release TAG=base-0.13.0`. Default `true`, so
tenants that bump see an identical converge except the new guard on
`url`/`username`, which no working tenant trips.

### E2. Terraform PR

B1–B4, C1–C2, D, E0 docs. `make release TAG=v3.3.0` (minor: new input,
backwards compatible). Tenants that bump the module pin see an empty plan.

### E3. Turning shipping off, per tenant

1. Policyfile: `enabled = false`, delete the three `loki` lines,
   `make bump-cookbook`, `make push` to staging, verify on the staging VM
   that `/etc/alloy` is gone and `id alloy` fails, promote.
2. **Wait until every VM has converged past the teardown** — the timer is 30
   minutes, so up to 30 minutes after promote. Check `/etc/alloy` absent on
   each, or the converge log.
3. Then tfvars: `log_shipping = false`, `loki_ssm_parameter_name = null`;
   `make preflight`; `terraform plan` (one IAM policy update per VM); apply.

Why this order and why the wait: `dev-vm-loki-token` on a denied fetch exits
10 and **leaves the existing token untouched**. Terraform first, or Terraform
before the last VM converged, removes the grant from a VM whose Alloy still
runs — it then ships indefinitely on its last token while the tenant believes
it is off. That is the failure decision 3 exists to prevent, not "harmless
but noisy".

Deleting the SSM parameter itself is the tenant's call and out of scope.

### E4. Turning shipping on

The mirror, Terraform **first**: set `log_shipping = true` and the parameter
name, create the SSM parameter per region (`docs/runbook.md §7`), apply, `make
preflight`. Then the policyfile: `enabled = true`, the three `loki` lines,
`make bump-cookbook`, push, promote. The reverse would have the first
converge fetch a token IAM denies: exit 10, Alloy installed with no token,
green VM, no logs.

## Out of scope (recorded)

- Per-VM granularity. The flag is per tenant; the module already receives the
  flag once, not per instance. A per-VM variant would move `log_shipping` into
  `var.instances` and the recipe would need a per-node attribute source that
  does not exist today (see the IMDS-tag rejection above).
- Making Falco optional. Decided against; revisit only with a concrete tenant
  asking.
- Absence-of-logs alerting. Separate backlog item; must respect this flag.
- A `placeholder-check` for the policyfile. Worth doing, unrelated to this
  flag; the C1 `warn` is the minimum that keeps a leftover visible.
