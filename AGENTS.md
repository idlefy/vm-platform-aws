# vm-platform-aws — agent guide

Infrastructure-as-code for hardened developer VMs on AWS (Terraform + CINC).
Human context is in [`README.md`](README.md), the operator path in
[`docs/runbook.md`](docs/runbook.md). This repository is the **template**: it
publishes two artifacts, and nothing deploys from it.

| Artifact | Path | Consumed as |
|---|---|---|
| the CINC cookbook | `cinc/cookbooks/base/**` | a Policyfile `git`+`tag`+`rel` pin |
| the Terraform modules | `vms/modules/**`, `tenant-skeleton/**` | `?ref=<full-sha>` on each module `source` |

A tenant repository is generated from `tenant-skeleton/` and holds its own
configuration and nothing else. Tenant operations — creating a VM, deleting one,
pushing policies — live in `tenant-skeleton/AGENTS.md`, which ships with the
tenant. This file carries the mechanisms and the evidence behind them, which is
what a change to the platform needs.

**Agent guides.** Someone who has just cloned this repository and wants to
start → follow [`GET-STARTED.md`](GET-STARTED.md).

There is no deployable `vms/` root here on purpose: two copies of it would drift
and nothing would catch it. `vms/` holds `modules/` and `README.md`.

There is no CINC server either, here or in a tenant. Policy reaches VMs as
signed archives in a bucket the tenant owns: `scripts/policy-publish.sh` signs
and publishes, `vms/modules/ec2/files/dev-vm-policy-fetch` verifies and
converges. The protocol, its threat model and what was measured on live VMs
are in `docs/design/serverless-policy-delivery.md`.

## Verify your own edits

```bash
make boundary-check                                    # modules stay inside themselves
( cd vms/modules/ec2          && terraform test )      # 53 runs
( cd vms/modules/fleet-guards && terraform test )      # 5 runs
make smoke                                             # the skeleton against this tree
for t in test/test-release-gate.sh test/test-resolve-pin.sh test/test-boundary-check.sh \
         test/test-placeholder-check.sh test/test-prepare.sh test/test-pin-to-worktree.sh \
         test/test-preflight.sh test/test-skeleton-sync.sh test/test-fetch-sync.sh \
         test/test-policy-publish.sh test/test-get-started.sh; do "$t"; done
( cd cinc && make lint && make test && make test-broker && make test-loki-token && make test-policy-fetch )
make test-pin-check                                    # root target; needs chef
mkdocs build --strict
```

`make release` runs the gates for the stream it is cutting; these are what you
run before opening the PR. `.github/workflows/ci.yml` runs the same list on
every pull request and on every push to `main`, split by stream and with no AWS
access. The one exception is `mkdocs build --strict`, which
`.github/workflows/docs.yml` runs instead. Keep all three lists in step — this
one, the README's, and CI's.


## Traps

Every one of these has actually happened. They share a shape: the command exits 0
and the damage surfaces somewhere else, later. A date marks when the claim was
measured on a live VM or fleet; it is provenance, not history, and the way to
challenge one is to reproduce it.

1. Permissions-boundary deny entries must cover every route to an asset.
2. Alloy's version pin and its unattended-upgrades blacklist are one change.
3. The rate limiter can be used to silence a `sudo` audit line — and what
   journald fields can and cannot anchor.
4. `sudo -u` cannot test a loginuid-keyed rule, and why the rule keys on it.
5. The credential broker's modes and uid gate are boundaries, not formatting.
6. Never echo a secret's value — SSM is not encrypted at rest from where you sit.
7. The Falco sudo exclusion and the Tailscale sudoers grant are one change.
8. Root never writes under `/home/ubuntu` — stage under `/usr/share/dev-vm/home`, copy as `ubuntu`.
9. A signature commits to bytes; compare an archive's contents before signing its hash.

**A deny entry in the permissions boundary must cover every route to the asset,
not the API that happens to name it.** The list blocks the snapshot path to a VM's
root volume *and separately* `StopInstances` → `DetachVolume` → `AttachVolume`,
because those three calls reach the same disk and need no `iam:PassRole`. Eight
omissions of exactly this shape were found before serverless delivery, each by a
reviewer rather than by a test — three of them (EBS direct-read of snapshots,
fleet network mutation, console output) by an outside reviewer of `v1.0.0`; see
`docs/design/first-external-review.md` §3. The policy bucket then took four
more review rounds of the same kind (VPC endpoints, IMDS, region-wide egress,
private hosted zones that re-point S3's name) before the deny list gave way to
a structural rule: a bundle naming an infrastructure namespace needs
`infrastructure_access = true`. When you add an entry, enumerate multi-call
paths to the thing you are protecting — including every route that changes
where a name resolves or a packet goes.

**Alloy's version pin and its unattended-upgrades blacklist are one change.**
`base::alloy` pins `alloy` to an exact version and `base::unattended_upgrades`
blacklists it. Remove either and the package flaps daily — unattended raises the
version overnight, the converge lowers it in the morning. The pin exists because
`alloy-config.alloy.erb` is written against specific Alloy stages
(`stage.structured_metadata`, `stage.limit` with `by_label_name`) and a config
the new binary rejects fails the way everything in this pipeline fails: green
unit, zero logs collected. Note that `Origins-Pattern` entries like
`site=apt.grafana.com` match **every** pocket that site publishes, not just
security — a bare third-party `site=` line is a feature-upgrade channel.
Bumping is a deliberate one-line edit; re-read the template's stages against the
new release first.

**The rate limiter's per-unit scoping does not protect the `sudo` audit line —
a developer can silence their own escalation attempt.** Measured on a live
fleet 2026-08-05, and it contradicts what the design spec claimed. An
interactive `sudo` is journaled under the invoking shell's **login session
scope** (`session-N.scope`), a unit the developer owns, not under a distinct
system unit — and their own `logger` flood lands in that same scope. So
`stage.limit` buckets flood and verdict together and `drop = true` discards
both. A/B on one VM, same `sudo` command, minutes apart: no flood → 1 verdict
emitted, 1 reached Loki; with an ~11,500-line flood in the same scope → 3
verdicts emitted, **0 reached Loki**, and alert 1 returned zero on a real
attempt. The saturation proxy does not compensate — it counts *arrived* lines,
which the limiter is holding down by construction; mid-flood it read 1 against
a threshold of 1000. `sshd` survives only because `ssh.service` is its own
unit. **Fixed in the shipped `alloy-config.alloy.erb`**: a `stage.match` with a
negated selector routes the audit processes around `stage.limit`. Re-running the
same A/B on a staging VM after the fix gave 3 verdicts emitted → 3 in Loki under
an 11,561-line flood, with the flood itself still cut to ~10% and alert 1 firing.
Do not reason about this from the config — reproduce it, and check **Loki**,
not the VM's journal. Falco's detections share one `unit` bucket the same way
(measured 2026-09-09: a 1300-line credential-store flood in 3 s dropped 1098
lines from the bucket the sudo detection sits in), so `falco` is on the bypass
selector too.

The selector keys on `_COMM` rather than `SYSLOG_IDENTIFIER`, which raises the
bar — `logger -t sudo` forges the latter trivially (measured:
`syslog_identifier=sudo, comm=logger, uid=1000`). But **`_COMM` is not
unforgeable, and a `_COMM` match is not authentication.** The sender owns
`/proc/PID/comm`: exec through a symlink named `sudo`, or
`prctl(PR_SET_NAME, "sudo")`. Both verified 2026-08-11. No journald field
authenticates a **sudo event** — but the reason is narrower than "every field is
forgeable", and the narrow version is the one to carry. Every `_`-prefixed field
describes the sending process, and most are also *set* by it: `_COMM` and `_EXE`
are. `_UID` is not — the kernel fills it from `SCM_CREDENTIALS` — and `unit`
comes from the sender's cgroup. Neither can be given a value its sender does not
already have, so both constrain provenance without proving what happened. That is
exactly why they anchor the hardened alerts and still cannot anchor sudo: a
genuine sudo verdict carries the developer's own uid and their own session scope,
so a forger claiming both is claiming only what is already true of them. A full
forgery matching `_EXE`, `_COMM`, `_UID`, `_AUDIT_LOGINUID`, `_AUDIT_SESSION`,
`_CAP_EFFECTIVE` and `_SYSTEMD_UNIT` at once was built using a lingering sender
plus an unprivileged mount namespace. The authoritative escalation detector is
therefore a Falco rule; the journald alerts are tripwires. See
`docs/design/sudo-audit-alerting.md`.

`_SYSTEMD_UNIT` matching in that forgery is not a contradiction of alert 4's
`unit="alloy.service"` anchor — the two are compatible and the difference is
where the event lives. A genuine sudo verdict is itself journaled under the
developer's own `session-N.scope`, so the forgery matched `_SYSTEMD_UNIT` for
free by landing in that same scope alongside it. But a sender still cannot
place itself in a **root-owned unit's** cgroup — it can only forge its own
session scope — which is exactly what makes `unit="alloy.service"` on alert 4
a real anchor: Alloy runs as a system unit no developer session can join.
`unit` anchors trust only against a root-owned unit; it says nothing when the
genuine event is itself session-scoped, as sudo's is.

**`sudo -u <user>` does not change `loginuid`, so it cannot test a
loginuid-keyed rule.** `/proc/PID/loginuid` is set by PAM at session start and
sudo does not touch it, so `sudo -u ubuntu ...` from an `admin` session still
carries loginuid 1001. The Falco rule `Developer user invoked sudo` keys on
`user.loginuid = 1000` and correctly did not fire under that test, which reads
as a broken rule and is not. Test it from a real SSH session as the target user.

Why the rule keys on loginuid at all: **`sudo` is setuid, so on the `execve`
exit event Falco already sees the post-exec credentials** — `uid=0`, not the
invoking human. A condition on `user.uid = 1000` matches nothing, ever, and says
nothing when it doesn't. `loginuid` survives the setuid transition and the kernel
refuses an unprivileged rewrite (verified: `echo 0 > /proc/self/loginuid` as
`ubuntu` returns EPERM). The same shape of trap applies to `proc.name`, which is
forgeable exactly as `_COMM` is — a symlink named `sudo` pointing at
`/usr/bin/logger` produced `name=sudo exepath=/usr/bin/logger`. Key on
`proc.exepath`.

**Do not "simplify" the credential broker's modes or its uid gate.**
`/dev/shm/dev-vm-aws` is `root:ubuntu 0750` and the credentials file `0640`
because `/dev/shm` is world-writable and the developer must not be able to
substitute what root published. The broker re-verifies the directory's owner and
mode on every run instead of trusting `systemd-tmpfiles` to have won the boot
race. These are security boundaries with tests attached, not formatting.

**Root never writes under `/home/ubuntu` — stage under `/usr/share/dev-vm/home`
and copy as `ubuntu`.** Chef's `directory` provider does no symlink handling at
all, and `file`/`template`/`cookbook_file` inspect only the last path component,
so `directory '/home/ubuntu/.claude'` against a developer-planted
`~/.claude → /etc/dev-vm` chowned `/etc/dev-vm` to the developer (reproduced
with `cinc-apply` 2026-09-09: the *target* of a symlink went 0700 → 0755). A
resource-level guard cannot close it — a symlinked parent is followed silently,
and the check-then-chown is a race the developer can win in a loop. The
boundary that holds is privilege: the `execute … user 'ubuntu'` copies in
`claude_code.rb`, `docker.rb` and `traefik.rb` are the pattern, and
`spec/recipes/default_spec.rb` fails any recipe that adds a root writer there.

**Never echo a secret's value.** A tenant's Loki token is reachable via
`aws ssm get-parameter --with-decryption` from a workstation holding its
credentials. Report exit status; never the value. SSM is not encrypted at rest
from your point of view. Signing keys never enter this flow as values at all:
`ssh-keygen -Y sign` reads them from disk, the agent or a hardware token, and
nothing here should ever print, copy or `cat` a private key.

**The Falco sudo exclusion and the Tailscale sudoers grant are one change, and
the grant must never ship first.** `base::sudoers` permits `/usr/bin/tailscale
login`; the Falco rule `Developer user invoked sudo` fires on any execve of
`/usr/bin/sudo` under loginuid 1000, and alert 6 is `critical`, `for: 0s`, with no
threshold. So a policy revision carrying the grant without the exclusion pages
someone on the first legitimate login — and on the first acceptance test. The
exclusion is harmless shipped early (it excludes a cmdline that cannot yet occur)
and expensive shipped late, because the fix is a full push/promote cycle away.

Shipping both in one revision narrows that window but does not close it, and no
recipe ordering will. `base::default` runs
`base::sudoers` fifth and `base::falco` second-to-last, so the grant is live
long before the new ruleset is; and moving `base::falco` earlier changes nothing,
because `cookbook_file[/etc/falco/rules.d/50-dev-vm.yaml]` notifies a **`:delayed`**
restart, which runs at the end of the converge wherever the recipe sits. Making it
`:immediately` is not the fix either — see the Falco crash-loop trap in
[`tenant-skeleton/AGENTS.md`](tenant-skeleton/AGENTS.md): a restart landing
while the eBPF probe is still opening dies and re-dies every fifteen seconds
while `systemctl is-active` reports `active`, and `StandardOutput=null` means
the reason never reaches journald. So on the
converge that first delivers this change, a legitimate login between the two still
pages. Only a two-revision rollout removes it. Accepted here as one page on one
converge; if you ship a similar grant/exclusion pair for something a developer
often uses, promote the exclusion on its own first.

The exclusion must be **`proc.args` equality** against measured spellings —
argv without argv[0] — never `contains`/`startswith`/`endswith`, and never
`proc.cmdline`. argv is attacker-chosen: `contains` and `endswith` are satisfied
by wrapping (`sudo sh -c id "tailscale login"`), `startswith` by any trailing
argument, and `proc.cmdline` equality by a symlink named `sudo tailscale`
(measured 2026-09-09: `~/"sudo tailscale" login` has cmdline
`sudo tailscale login`, sudoers refuses it, and the tripwire stayed quiet) — each
silences probing that sudoers itself refuses. Read the exact `proc.args` off a
real detection rather than guessing it here; an exclusion that does not match is
indistinguishable from no exclusion until someone is paged.

**A signature commits to bytes, not to where they came from — compare an
archive's contents before signing its hash.** `make push` stores each archive
once, under its `revision_id`, and that id is in the committed lock, so it is
no secret. The first publisher hashed whatever sat at
`archives/<revision_id>.tgz` and signed the hash. Anyone able to write the
bucket — no signing key needed — could store that object first, with the
genuine lock inside and a recipe of their own, and the next honest push would
have signed it. `promote` had the same hole one step later: a stolen
staging-only key could re-sign staging over such an archive, and the
operator's production key would carry it into production, since revision and
hash both matched. Found by review, 2026-10-15. `policy-publish.sh` now
compares the stored archive's paths, types, file contents and link targets
with a fresh export of the lock before any signature, reading it with
`tarfile` and never extracting it. An export is not byte-reproducible (mtimes
vary), so the hash alone can never be the check. If you touch the publisher,
`plant_archive` in `test/test-policy-publish.sh` is the case that must keep
failing.

## Release

Two tag streams, cut by `make release`, which refuses a dirty tree and a HEAD
that consumers cannot reach:

| Stream | Publishes | Gates | Lockstep |
|---|---|---|---|
| `base-X.Y.Z` | `cinc/cookbooks/base/**` | `cookstyle`, `chefspec`, `test-broker`, `test-loki-token`, `test-policy-fetch`, `test-fetch-sync` | `metadata.rb` must say `X.Y.Z`, byte for byte |
| `vX.Y.Z` | `vms/modules/**` + `tenant-skeleton/**` | `boundary-check`, `test-skeleton-sync`, `test-fetch-sync`, `test-policy-publish`, `smoke` | none — the module carries no version string |

```bash
make release TAG=base-1.0.0
make release TAG=v1.0.0
git push origin <tag>
```

The gates run against the working tree while a tag names a commit, which is why
`release` prints the SHA before it starts and tags that SHA explicitly. Tags are
immutable by convention, and a repository may enforce nothing: check
`gh api repos/idlefy/vm-platform-aws/rulesets` before assuming a tag ruleset
exists. Where none does, a re-created tag is possible and `pin-check` will
report it to every tenant as a documentation mismatch.

**A `metadata.rb` version bump is part of the cookbook change, not a follow-up.**
It is what a tenant reads out of its lock to know what it runs, so a version
that never moves makes every tenant on every tag report the same one.

---

## Hard rules

Never override without explicit user instruction in the current conversation.

1. **Never cut or move a tag by hand.** `make release` is the only path: it
   refuses a dirty tree, refuses a HEAD consumers cannot reach, and tags the SHA
   it printed rather than whatever HEAD becomes. A tag cut around it certifies a
   tree nobody gated.
2. **Never change a published module's inputs without updating
   `tenant-skeleton/` in the same commit.** The interface is a contract now, and
   `make smoke` is what turns that from a hope into a rule.
3. **Never echo a secret's value.** Report exit status instead. A tenant's
   Loki token is reachable via `aws ssm get-parameter --with-decryption` from a
   workstation holding its credentials.
4. **Never use `git push --force` on `main`** without the user explicitly saying
   "force push", and never force-push a tag at all.
5. **Never `terraform apply` from this repository.** There is nothing here to
   apply — if you are holding a tenant's state, you are on the wrong clone.
6. **Use the Makefile, not raw `chef` / `git tag`.** Each target encodes a gate
   that the raw command skips.
