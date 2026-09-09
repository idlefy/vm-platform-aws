# First external review — design

> Design record, written during development; identifiers anonymised. Numbers are as measured.

**Date:** 2026-09-09
**Status:** approved by the maintainer (fix everything the review found, or refute it with a measurement). Implemented as two pull requests, one per tag stream.
**Input:** an independent review of `v1.0.0` / `base-1.0.0` by a third-party model with shell access. It ran every offline gate (all green), generated a tenant, walked the runbook, and reported nine findings plus seven open questions. Every finding was re-verified against the code before this record was written; one was reproduced locally. None was false.

## What the review found, and the ruling on each

| # | Finding | Ruling | Stream |
|---|---|---|---|
| C1 | CINC root resources under `/home/ubuntu` follow a developer-planted symlink; `directory` never checks, `file`/`template` check only the leaf. Root then `chown`s a root-owned directory (`/etc/dev-vm`) to the developer, who replaces `aws-access.env`, which the root broker sources before it verifies anything. | **Fix.** Reproduced: `cinc-apply` with `directory '<symlink>' mode '0755'` changed the *target* from 0700 to 0755. | base |
| C2 | `bootstrap_failed` in `user_data.tf` restores `ubuntu ALL=(ALL) NOPASSWD:ALL` on any failure, including a failed first converge. Root reaches IMDS, IMDS carries the bootstrap role, the role reads the validator key. | **Fix.** The in-code claim "everything here runs before any secret exists on the box" is wrong at every stage: the instance profile *is* the secret. | v |
| H1 | EBS direct APIs (`ebs:ListSnapshotBlocks`, `ebs:ListChangedBlocks`, `ebs:GetSnapshotBlock`) are not in the boundary's deny list; a bundle declaring `ebs:*` reads snapshot blocks without any denied `ec2:` call. | **Fix.** Same shape as the `StopInstances → DetachVolume → AttachVolume` trap. | v |
| H2 | Network mutation (`ec2:*NetworkAcl*`, `*Route*`, `*SecurityGroup*`) and `ec2:TerminateInstances` are not denied; a bundle declaring `ec2:*` can black-hole the fleet's Loki egress or terminate other VMs. | **Fix.** | v |
| M1 | `preflight` records Loki `000`, `302`, `5xx` as `warn` and exits 0, so `make promote` proceeds without a proven token. | **Fix.** Only `400` is a pass; everything else is `bad`. | v |
| M2 | `pin-check` stage 3 filters `vms/*.tf` sources to `git::` lines and fails only when *zero* remain; one pinned module hides an unpinned one. | **Fix.** Require both named module blocks (`ec2`, `fleet_guards`) individually. | v |
| M3 | `make release` tests reachability against the cached `@{u}` ref; a stale or wrong upstream passes. | **Fix.** `git fetch` the upstream's remote first. | v |
| M4 | Secret-handling examples: `--value "$(cat key.pem)"` puts the key in argv; `ssh … > file; chmod 600 file` creates the file world-readable under umask 022; `printf '<token>' > file` lands in shell history; the suggested `read -rs > "$TOKEN_FILE"` writes a zero-byte file. | **Fix.** Documentation only. | v |
| M5 | Runbook "turning shipping off on a running fleet" omits the re-lock and describes a policyfile/tfvars mismatch that `preflight` refuses; §7 attribute edits omit the re-lock too. | **Fix.** Documentation only. | v |

Open questions from the review that need a live VM are in §7. Two items were declined: BSD `sed -i` portability (the prerequisites now state a GNU userland instead) and shipping `LICENSE`/`NOTICE` into generated tenants (a tenant is a private configuration repository; the copied scripts carry their SPDX header).

## 1. Cookbook: root never writes under `/home/ubuntu` (C1)

**Principle.** A resource-level symlink guard cannot close this: Chef's `directory` provider has no symlink handling at all, `file`/`template`/`cookbook_file` inspect only the last path component (a symlinked *parent* is followed silently), and every check is a `lstat` followed later by a path-based `chown` — a TOCTOU the developer can win with a loop. The only boundary that holds is *privilege*: whatever must exist under the developer's home is created **by the developer's uid**. A symlink then confers nothing the developer did not already have.

**Mechanism.** Two halves per file:

1. Root stages the content under `/usr/share/dev-vm/home/` (root:root, directories `0755`, files `0644`), using the ordinary `cookbook_file`/`template`/`file` resources. Nothing staged is secret; the tree mirrors the layout under the home directory (`/usr/share/dev-vm/home/.claude/settings.json` and so on).
2. An `execute` resource with `user 'ubuntu'`, `group 'ubuntu'`, `environment 'HOME' => '/home/ubuntu'` copies it into place with `install -D -m <mode> <staged> <target>`. Idempotence: `not_if "cmp -s <staged> <target>"` for files the cookbook keeps in sync, `not_if "test -e <target>"` for the ones that are `create_if_missing` today (`statusline-command.sh`, `settings.json`). Directories: `install -d -m <mode> <dir>` guarded by `not_if "test -d <dir>"`.

Chef's `execute` with `user`/`group` sets uid and gid only; it does not touch supplementary groups, which are inherited from the parent (root) unless `login true` is set, and this cookbook does not set it. The boundary therefore rests on uid/gid alone, not on group membership — which is sufficient here because the cookbook creates nothing group-writable, so root's inherited supplementary groups reach nothing regardless of which ones ride along. `install` then runs as that uid/gid, and its own `-D` creates parents as that user, so a symlink anywhere in the path resolves with the developer's permissions, not root's. A future `execute` that runs as ubuntu but needs a supplementary group — the `docker` group, say — would have to set `login true` to get it.

**Resources that move** (every root resource naming `/home/ubuntu` today):

| Recipe | Today | After |
|---|---|---|
| `claude_code.rb` | `directory ~/.claude`; `cookbook_file ~/.claude/statusline-command.sh` (create_if_missing); `file ~/.claude/settings.json` (create_if_missing) | staged under `/usr/share/dev-vm/home/.claude/`; three `execute` copies as ubuntu |
| `docker.rb` | `file ~/.docker-env` | staged `/usr/share/dev-vm/home/.docker-env`; `execute` copy, `cmp`-guarded |
| `traefik.rb` | three `directory` in a loop; `directory ~/.local/share/traefik` 0700; `execute generate-traefik-password` as root under `~/.config/traefik`; `template` × 4 (`traefik.yml`, `dynamic/auth.yml`, `systemd/user/traefik.service`, `traefik-readme.md`) | directories via `install -d` as ubuntu; the password script runs with `user 'ubuntu'` unchanged otherwise (`openssl` and `htpasswd` need no root, and its rename-last ordering stays); the four templates staged and copied |

Notifications survive the move: the `execute` copies carry the `notifies` the templates carried (`restart-traefik`, `systemd-user-reload`), and the staged template notifies nothing. The `traefik-readme.md` determinism rule (no non-deterministic content, or every converge reports a change) still applies to the staged file.

**Broker (`aws-vm-credentials`).** Before `. "$ENV_FILE"`: refuse unless the file is a regular file (not a symlink), owned by uid 0, and not group- or other-writable; the check uses `stat -c '%u %a'` on `"$ENV_FILE"` after `[ -L ]`. Same shape and wording as the existing `OUT_DIR` guard, so the two read as one rule. Under the unprivileged test harness the owner check compares against `$(id -u)`, exactly as the output-directory guard does. This is defence in depth once §1 lands; it costs one `stat`.

**Tests.**
- ChefSpec, one per touched recipe, on the converged resource collection: no `directory`, `file`, `template`, `cookbook_file`, `link` or `remote_file` resource has a `path` under `/home/ubuntu/`; every `execute` whose `command` mentions `/home/ubuntu` has `user 'ubuntu'`. This is the regression guard for the principle, and it is what a future recipe fails.
- `test-aws-vm-credentials.sh`: four new cases — `ENV_FILE` is a symlink → exit 1, nothing published; `ENV_FILE` is group-writable → exit 1; `ENV_FILE` is not a regular file → exit 1; `ENV_FILE` is owned by a different uid → exit 1, stderr names the refusal. The existing 28 cases keep passing.
- Live (§7): the review's exploit, before and after.

**Not changed.** Root still reads under `/home/ubuntu` in guards (`not_if 'grep -q docker-env /home/ubuntu/.bashrc'`); a read follows a symlink to a root-readable file, which discloses nothing the developer cannot read. The `add-docker-env-to-bashrc` append already runs as ubuntu. `admin`'s home is not in scope: `admin` is the operator.

`metadata.rb` → `1.1.0`.

## 2. Bootstrap failure fails closed (C2)

`bootstrap_failed` keeps removing `/etc/cinc/validation.pem` and stops restoring `/etc/sudoers.d/90-cloud-init-users`. The backup copy is no longer taken, so nothing on disk holds the grant. Instead it writes the bootstrap log to the serial console:

```bash
bootstrap_failed() {
  rm -f /etc/cinc/validation.pem
  echo "BOOTSTRAP FAILED: validation key removed; developer sudo stays revoked. Log follows." > /dev/console
  cat /var/log/user-data.log > /dev/console
}
```

The operator reads it with `aws ec2 get-console-output --instance-id … --output text` and replaces the instance (`terraform apply -replace=…`), which the runbook already names as the recovery for a VM that failed to bootstrap. The converge log (`/var/log/cinc-first-run.log`) is **not** mirrored: it can name attribute values, and the failing step for a converge failure is visible from the CINC server's node run list. The `user-data.log` never contains the validator key (it is redirected straight to a 0600 file) or any credential.

`ec2:GetConsoleOutput` and `ec2:GetConsoleScreenshot` join the deny list (§3) so a developer with an `ec2:*` bundle cannot read other VMs' bootstrap logs.

**Tests.** `hardening.tftest.hcl`: the rendered user-data does not contain `90-cloud-init-users.bak` or `install -m 0440`; it does contain `> /dev/console`. Live (§7): a deliberately bad policy tag on a staging VM ends with no sudo for `ubuntu` and the log in `get-console-output`.

## 3. Permissions boundary: two more asset routes (H1, H2)

Additions to `DenyEscalationAndBootstrapSecrets` in `vms/modules/ec2/iam.tf`:

| Group | Actions | Route it closes |
|---|---|---|
| Snapshot content without EC2 calls | `ebs:ListSnapshotBlocks`, `ebs:ListChangedBlocks`, `ebs:GetSnapshotBlock`, `ebs:StartSnapshot`, `ebs:PutSnapshotBlock`, `ebs:CompleteSnapshot` | read or forge another VM's root volume through the EBS direct API |
| Fleet network | `ec2:CreateNetworkAclEntry`, `ec2:ReplaceNetworkAclEntry`, `ec2:DeleteNetworkAclEntry`, `ec2:ReplaceNetworkAclAssociation`, `ec2:CreateRoute`, `ec2:ReplaceRoute`, `ec2:DeleteRoute`, `ec2:ReplaceRouteTableAssociation`, `ec2:DisassociateRouteTable`, `ec2:AuthorizeSecurityGroupEgress`, `ec2:RevokeSecurityGroupEgress`, `ec2:ModifySecurityGroupRules`, `ec2:ModifyInstanceAttribute` (already present) | black-hole Loki egress for the fleet; the "no logs from a VM" alert cannot fire over a transport that is itself cut |
| Other instances' availability | `ec2:TerminateInstances`, `ec2:RebootInstances` (`StopInstances` already present) | destroy a peer's VM |
| Bootstrap logs | `ec2:GetConsoleOutput`, `ec2:GetConsoleScreenshot` | read §2's failure log from another VM |

Security-group *ingress* is left alone on purpose: a developer opening a port on their own VM is the existing, documented self-service, and the boundary is `Resource = "*"` — a per-instance condition would be new design. Egress and ACLs are denied because they are the fleet's shared audit path.

The Traps entry on "every route to the asset" gets the EBS direct API as its fourth found omission. `validation.tftest.hcl` gains one assertion per group (the rendered boundary contains the action). `docs/design/per-vm-aws-access.md` lists the additions in its boundary table.

## 4. Gates (M1–M3)

- **`preflight.sh` Loki probe:** `400` → `ok`; `401|403` → `bad` (unchanged); everything else, including `000`, `2xx`, `3xx`, `5xx` → `bad` with the code in the message. A tenant that legitimately cannot reach Loki from the workstation uses `PREFLIGHT=skip`, which already exists and is already documented as the only bypass. `test-preflight.sh` gains cases for `000`, `302`, `500`.
- **`pin-check.sh` stage 3:** for each of `module "ec2"` and `module "fleet_guards"` in `vms/main.tf`, extract that block's `source` and require `git::<repo>//vms/modules/<name>?ref=<pin_sha>` with `<pin_sha>` the pinned SHA. The repository half is not checked — the test harness pins to a local bare repository, and the SHA plus module subdirectory are what a tenant can get wrong. A missing block, a local path, a different subdirectory, or a different SHA is `bad`, naming the module. The zero-`git::` message stays for the case where neither block is a git source. `test-pin-check.sh` gains the mixed case (one pinned, one local → fail).
- **`Makefile` release gate:** before `merge-base --is-ancestor`, `git fetch --quiet "$${up%%/*}"`; the comparison then runs against fresh refs. `test-release-gate.sh` gains the case the review built: local `origin/main` ahead of an empty remote → refused.

The tenant mirrors under `tenant-skeleton/scripts/` move with `scripts/`; `test-skeleton-sync.sh` enforces that.

## 5. Documentation (M4, M5, prerequisites)

- `vms/README.md` validator upload: `--value file://<path>` (never `$(cat …)`); fetch with `install -m 0600 /dev/null "$f"` first, then `ssh … > "$f"`; `f="$(mktemp)"`, never `/tmp/validator.pem`.
- `docs/runbook.md` §5 key fetches: same `install -m 0600 /dev/null` before the redirect; Loki token: `read -rs TOKEN; printf '%s' "$TOKEN" > "$TOKEN_FILE"; unset TOKEN` (no literal in the command line, no `read` into a redirect).
- `docs/runbook.md` "turning shipping off on a running fleet": (1) policyfile `enabled = false`, (2) `make bump-cookbook` (bare, re-locks at the current tag), (3) `make push`, (4) set `log_shipping = false` and `loki_ssm_parameter_name = null` in tfvars **without applying**, so `preflight` sees the two agree, (5) `make promote`, (6) after every VM has converged past the teardown, `terraform apply`. §7 attribute edits: add "then `make bump-cookbook` to re-lock" wherever an attribute edit is described.
- `docs/index.md` / `README.md` prerequisites: "GNU userland (`sed -i`, `grep -P`); on macOS install `coreutils`/`gnu-sed` and put them first on `PATH`".
- `vms/README.md` line 253 "`make ssh` needs `USER=admin` spelled out": verify against the tenant Makefile's `ssh` target and fix whichever is wrong.
- `docs/changelog.md`: `1.1.0` entries for both streams, naming the review.

## 6. Pull requests and release

| PR | Branch | Contents | Gates | Tag |
|---|---|---|---|---|
| A | `fix/review-cookbook` | §1 | `cookstyle`, ChefSpec, `test-broker`, `test-loki-token` | `base-1.1.0` |
| B | `fix/review-modules-gates-docs` | §2 §3 §4 §5 | `boundary-check`, `terraform test` ×2, `smoke`, `test/*.sh`, `mkdocs build --strict` | `v1.1.0` |

Both through CI on GitHub; merge with rebase; `make release` for each tag; `git push origin <tag>`. Then the tenant migration in §7.

## 7. Live verification on the `moments` staging VM

The tenant is re-pinned to `v1.1.0` / `base-1.1.0` on the public repository (its first move off the private origin), pushed to the `staging` policy group, and one throwaway VM is created with `policy_group = "staging"`. On it:

1. **C1 exploit, expected to fail.** As `ubuntu`: `mv ~/.claude ~/.claude.bak; ln -s /etc/dev-vm ~/.claude`; trigger a converge; `stat -c '%U %a' /etc/dev-vm` stays `root 755`; the converge reports the `install` step failing with `EACCES` or creating nothing, and `/etc/dev-vm/aws-access.env` is untouched. Before the fix the same steps on a `base-1.0.0` VM are expected to hand `/etc/dev-vm` to `ubuntu` — measured once for the record, on the throwaway VM, before the cookbook bump.
2. **C2 path.** A second throwaway VM with a policy group that does not exist: after cloud-init finishes, `sudo -n true` as `ubuntu` fails, `/etc/sudoers.d/90-cloud-init-users` is absent, and `aws ec2 get-console-output` carries the `BOOTSTRAP FAILED` line and the log.
3. **Falco limiter bucket (review open question).** Falco is not in the `stage.match` bypass, so all of its detections share one `unit`-keyed bucket at rate 20 / burst 200. A/B: generate >1 000 credential-store denials in 10 s from a developer shell while issuing one `sudo` that the Falco rule detects; count detections emitted (`journalctl -u falco-modern-bpf`) against arrivals in Loki. If the sudo detection is dropped, `falco-modern-bpf.service` joins the bypass selector in a follow-up `base-1.1.1`; if not, the design record states the measured margin.
4. **Tailscale exclusion spelling (review open question).** From a uid-1000 SSH session, `ln -s /usr/bin/sudo ~/"sudo tailscale"; ~/"sudo tailscale" login`. Record `proc.cmdline`, `proc.exepath` and whether the exclusion matched. Sudoers refuses the command either way (`tailscale` is not on the grant as a bare word), so the question is only whether the *tripwire* stays quiet; a quiet tripwire on a refused command is the documented "probing that sudoers itself refuses" case and would tighten the exclusion to `proc.args` equality.

Both throwaway VMs and their CINC nodes are destroyed afterwards; the measurements go into this record's *Measured* section and, where they change guidance, into `CLAUDE.md` Traps.

## Measured

_Filled in after §7._

- ChefSpec: 59 examples, 0 failures.
