# Developer VM log shipping — design

> Design record, written during development; identifiers anonymised. Numbers are as measured.

**Status:** approved for planning (revised after architecture review)
**Date:** 2026-08-04
**Replaces:** the Wazuh agent removed before the first public release
**See also:** `docs/design/optional-log-shipping.md` — shipping is per-tenant optional since `base-0.13.0`; read "every VM ships" below with that qualifier.

## Problem

The fleet has no audit trail. Wazuh was removed on 2026-08-04 because it cost an
m7a.xlarge to deliver one custom rule and an agent keepalive; nothing replaced
it. The fleet is about to grow from zero to ~20 VMs, and to ~50 after that.

The need is **forensics and audit**, not real-time detection: after an incident —
or when someone asks who reached a machine and when — there must be a searchable
record that survives the machine it came from. Detection (Falco, GuardDuty
Runtime Monitoring) is a separate decision, deliberately deferred.

Journald on the VM does not satisfy this. It is local to a host that is itself
the untrusted object, it is lost when the instance is destroyed, and it cannot
be queried across a fleet.

## Goal

Ship each developer VM's systemd journal to Grafana Cloud Loki, continuously and
tamper-resistantly, via a CINC recipe. No new servers, no network-reachable
ports.

## Non-goals

Explicitly out of scope. Each is a separate decision with its own cost, to be
made when a question demands it — not bundled in because the agent supports it:

- **Metrics and traces.** Alloy ships both; we send neither.
- **`auditd` / `execve` logging.** Multiplies volume by an order of magnitude on
  machines that compile code. Revisit only with a stated requirement.
- **Falco or any runtime detection.** Next conversation. It will attach to this
  pipeline as another source rather than needing its own transport.
- **Grafana Cloud Fleet Management.** See *Rejected alternatives*.
- **Custom dashboards.** Grafana Cloud's built-in log exploration is enough for
  a demo. Dashboards are cheap to add later and expensive to maintain early.

Alerting **on the contents of the logs** — a failed converge, a refused login,
an escalation attempt — is in scope and specified under *Security alerting*.
Alerting on the *absence* of logs is explicitly out of scope, and the reason is
Idlefy; see *Delivery guarantees and detection*.

## Decisions

### Destination: Grafana Cloud Loki (free tier, US stack, 14-day retention)

This is **the deployment it was measured on**, not a permanent production
stack. Production will run on the organisation's own Grafana Cloud account.
That constraint drives the most important design rule below: the destination is
a parameter, never a fact baked into the recipe.

Free tier gives 50 GB/month ingest and 14-day retention. At ~20 VMs producing
20–40 MB/day of journal each, that is ~20 GB/month — comfortable. At 50 VMs it
is ~45–60 GB/month, i.e. at the edge; Pro costs $19/month plus $0.45/GB over the
allowance. Fourteen days is short for audit — an incident is often discovered a
month later — and is accepted only because this is a demo.

The cap is not only a pricing fact. What happens at runtime when it is reached
is specified under *Delivery guarantees and detection*.

### Rejected alternatives

**Self-hosted Loki on a third `infra/` VM.** Keeps logs in-account with no
per-GB fee, but adds a stateful service to patch, upgrade, back up and give TLS
to — and `nginx-certbot` was deleted alongside Wazuh, so it would have to come
back. This is precisely the shape that made Wazuh expensive: a box that must be
operated, holding data read once a quarter.

**CloudWatch Logs.** The one option requiring no secret on the VM — the agent
authenticates with the instance role. Genuinely attractive at 50 machines where
the machine is the untrusted object, and the strength of that argument is
visible in how much of this spec is spent containing a secret. Rejected because
Logs Insights is a materially worse query surface than LogQL, three regions
become three disconnected log groups, and Grafana would still be wanted on top,
paying twice.

**GuardDuty Runtime Monitoring.** Answers a different question — detection, not
audit — which is why it is not this spec's job either way.

It also had a hard blocker when this spec was written: Ubuntu 26.04 was not on
AWS's verified OS list. **That blocker is gone.** The fleet moved back to 24.04
on 2026-08-05 (see `ami_name_pattern` in `vms/modules/ec2/variables.tf` for the
full reasoning, of which this was one of four strands), and 24.04 *is* verified.
So Runtime Monitoring is now a live option for the detection job whenever that
job is picked up — it is out of scope here because this spec chose audit first,
not because the platform cannot run it. GuardDuty is currently not enabled in
any of the three regions; enabling the *base* detector is worth considering
separately and is unrelated to this spec.

**Grafana Cloud Fleet Management.** GA since July 2026; lets Grafana Cloud push
collector configuration to agents remotely via a `remotecfg` block. Rejected on
two grounds. First, it is a second control plane able to deliver arbitrary
collector configuration to every VM, with its credentials held by a SaaS
provider. Second, and decisive: this platform's model is that configuration
lives in git, converges every 30 minutes, and manual changes are reverted. A
remote configuration CINC does not know about is exactly the drift the platform
exists to prevent. Recorded here so a future reader knows it was considered.

## Architecture

One new CINC recipe, `base::alloy`. Nothing else is added anywhere: no
instances, no network-reachable ports, no firewall rules (`firewall.rb` already
sets `OUTPUT ACCEPT`).

```
journald ──► loki.source.journal ──► loki.process ──────────► loki.write ──► Grafana Cloud
             format_as_json = true   stage.static_labels ► job HTTPS + basic auth
             labels: instance, region  stage.json
             relabel_rules ──► unit    stage.structured_metadata
                               level   stage.limit
                                       stage.output
```

Two mechanisms, each used for what it is good at, and they compose cleanly
inside one `loki.source.journal` component:

- **`relabel_rules`** produces the only two labels derived from journal fields,
  `unit` and `level`. Both are wanted as labels, so promoting them is the point
  and nothing needs dropping afterwards. This also avoids reimplementing
  systemd's priority mapping by hand: the component emits
  `__journal_priority_keyword` (`error`, `warning`, …) alongside the numeric
  `__journal_priority`, whereas the JSON body carries only the raw number.
- **`format_as_json` + `stage.json`** populates the extracted map, from which
  `stage.structured_metadata` promotes the remaining fields. These never become
  labels at any point.

`instance` and `region` are static per machine and are set by the source
component's `labels` argument, rendered by the recipe. `job` is deliberately
**not** set there: it is set by `stage.static_labels` inside `loki.process`
instead, because Alloy's `main` branch already contains
`labelMap["job"] = opts.id`, applied after a source's own labels are copied
in — not yet released, but this fleet auto-updates Alloy
(`unattended_upgrades.rb` watches `apt.grafana.com`), so it can land under us.
If `job` were set at the source, that change would silently overwrite it
fleet-wide with `loki.source.journal.journal`, `service_name` would follow it,
and every query anchored on `{job="dev-vm"}` — which is all of *Security
alerting* — would go quiet while every VM kept shipping. Setting it in
`loki.process` survives that: nothing after that stage touches `job` again.

**Package.** Alloy from Grafana's apt repository. This resembles the `gh.rb`
pattern but must not be copied from it verbatim: `gh.rb` fetches a *binary*
keyring, whereas `https://apt.grafana.com/gpg-full.key` is ASCII-armored.
Follow Grafana's own documented form — store it as
`/etc/apt/keyrings/grafana.asc` with the `.asc` extension, or `gpg --dearmor`
it — because apt's tolerance of armored `signed-by` files depends on the
extension and version, and getting this wrong surfaces as `NO_PUBKEY` at the
notified `apt-get update`.

`gh.rb`'s `not_if { File.exist? }` guard also means a key is fetched once and
never refreshed. Grafana has rotated its signing key before (2023), and a stale
keyring would break the very `unattended-upgrades` path this spec wires up. The
recipe should either re-fetch when the key changes or document that a rotation
requires deleting the keyring file.

`site=apt.grafana.com` is added to `Origins-Pattern` in
`unattended_upgrades.rb`, so the agent receives security updates automatically
like Docker, NodeSource, GitHub CLI and Kubernetes do today.

The sources line should not hardcode `arch=amd64`. Note that this is hygiene,
not Graviton support: `user_data.tf:43` installs the x86_64 AWS CLI and
`user_data.tf:61` the `amd64` CINC package, so an arm64 VM cannot converge at
all today. Arch-agnosticism costs nothing and avoids adding a fourth amd64
assumption; actual Graviton support is out of scope.

**Process identity.** Alloy runs as the `alloy` user created by the package,
added to `systemd-journal` — which is what actually grants journal read — and to
`adm`, which is the Debian/Ubuntu convention for log access and is added for
consistency. The failure mode is what matters: with neither group the component
starts without error and silently collects nothing, so a green unit proves
nothing. The recipe must verify that entries actually flow.

**Local control server.** Alloy's Debian package runs an HTTP server on
`127.0.0.1:12345` serving the UI, `/metrics` and `/-/reload`. It is loopback
only and `firewall.rb`'s `INPUT DROP` keeps it off the network, but it *is* a
listening socket reachable by any local user including `ubuntu`. Secret-typed
values are redacted in the UI, and `/-/reload` only re-reads the root-owned
config file, so neither exposes the token or permits reconfiguration. This is
recorded so that `ss -ltn` on a converged VM does not appear to contradict the
spec. The recipe may bind it away or disable it; if it does, say so.

**Alloy version.** `apt.grafana.com stable` installs whatever Grafana has most
recently released — **v1.18.0** at the time of writing, not v1.12 as an
earlier draft of this spec claimed. The reasoning below is real but was
checked only against changes through v1.11 and does not extend to v1.18.0:
recent breaking changes up to v1.11 are entirely Prometheus-side — regex
newline matching, `enable_http2` default, histogram label normalisation — and
cannot affect a logs-only deployment, but that is a claim about v1.11, not a
claim that **no** breaking change has landed in the `loki.*` components since.
In particular, the journald component was substantially rewritten somewhere
in the releases between v1.12 and v1.18.0, and nobody has reviewed that
changelog range for `loki.source.journal` / `loki.process` breakage. Confirm
the pipeline's stage-by-stage behaviour against the actually-installed v1.18.0
during implementation rather than assuming this section already covers it.

Promtail reached end-of-life on 2026-03-02, so Alloy is the only supported
agent, not a preference.

## Label and structured-metadata model

Loki 3.0's structured metadata is the mechanism that makes this cheap: fields
become searchable without creating a stream. The rule is a small static label
set, everything else as structured metadata.

**Labels — five set by us, plus one Loki adds:**

| Label          | Journal field / source        | Cardinality    |
|----------------|-------------------------------|----------------|
| `job`          | constant `dev-vm`             | 1              |
| `instance`     | VM name                       | ~50            |
| `region`       | AWS region                    | 3              |
| `unit`         | `_SYSTEMD_UNIT`               | ~25 active     |
| `level`        | `PRIORITY`, mapped to keyword | ~4 in practice |
| `service_name` | *derived by Loki, see below*  | 1              |

50 × 25 × 4 ≈ **5,000 streams**. Loki degrades in the hundreds of thousands, so
there is ample headroom. The arithmetic is stated so that whoever proposes a
seventh label can see what they are multiplying.

`service_name` is not ours. Loki 3.x's `discover_service_name` is enabled on
Grafana Cloud and derives it when absent, taking it from `job` — so every stream
arrives carrying `service_name="dev-vm"`, and no agent-side configuration
removes it. It is listed here so nobody spends an afternoon "fixing" it.

`unit` is absent on entries with no `_SYSTEMD_UNIT` — kernel messages in
particular. That is correct behaviour, not a pipeline fault.

**Structured metadata:** `boot_id`, `transport`, `pid`, `syslog_identifier`,
`comm`, `uid`, `audit_loginuid`, `exe` (added in base 0.9.0 — display-only, and
never selected on; see *The bypass keys on `_COMM`* below for why).

None of these fields authenticates a sudo event, and the reason needs stating
precisely rather than as a blanket. Every one of them describes the sending
process, and most are also *set* by it. `_UID` is the exception — the kernel
fills it from `SCM_CREDENTIALS` — and so is the unit label, which journald
derives from the sender's cgroup; neither can carry a value its sender does not
already have, so both constrain provenance and are used as anchors elsewhere.
What none of them can do is prove what happened —
see *The bypass keys on `_COMM` over `SYSLOG_IDENTIFIER`* below for what that
means for `comm` specifically.

`audit_loginuid` survives `sudo` and `su`, so it answers "who was this actually"
rather than "who were they at that moment". Its value here is narrower than it
first appears and should not be oversold: every developer logs in as `ubuntu`,
so their loginuid is uniformly 1000 and the field does not distinguish between
them — developer attribution comes from the SSH key fingerprint in the sshd
message body. Where `audit_loginuid` earns its place is the **admin** path: an
operator arriving via EC2 Instance Connect and escalating with `sudo` stays
attributable across the transition.

`boot_id` deserves specific note. Grafana Cloud's own Linux Server integration
puts it in **labels**. That is wrong for this fleet: Idlefy reboots idle VMs, so
a new `boot_id` appears on every machine nearly daily, and each one multiplies
into new streams across every unit and level. Their integration does not assume
daily reboots; ours must. `transport` moves to structured metadata for the same
reason — up to six values multiplying every stream, for little query value.

### Mechanism, and the trap in it

`stage.structured_metadata` reads from the pipeline's extracted map, while
journal fields arrive as `__journal_*` labels. These are different places.

The widely-circulated forum recipe — `loki.relabel` with `labelmap` to strip the
`__` prefix, then `stage.structured_metadata` — omits `stage.label_drop`. The
field therefore remains a label *as well*, and cardinality does not fall at all.
The configuration is valid, the agent is healthy, and the intended benefit is
silently absent.

The design therefore avoids `labelmap` entirely. Fields destined for structured
metadata take the unambiguous route: `format_as_json = true` makes the whole
entry a JSON line, `stage.json` populates the extracted map explicitly,
`stage.structured_metadata` promotes the chosen fields, and `stage.output`
restores a readable line from `MESSAGE`. These fields never become labels, so
there is nothing to drop.

`relabel_rules` is used only for `unit` and `level` — fields that are *supposed*
to be labels. The distinction is the whole point: relabelling is correct when
you want a label and a trap when you want structured metadata.

## Volume control

**No drop rules at launch, beyond at most a couple of known-loud units.**

The standard recipe found in every published example drops `DEBUG`, `INFO` and
`NOTICE`. For this system that is destructive: `sshd` logs "Accepted publickey"
at INFO and `sudo` logs at NOTICE. The popular configuration would delete
precisely the audit trail being built. Best practice from a different context,
applied here, breaks the requirement.

Ship broadly, watch real volume by `unit` in Grafana for two weeks, then add
drop rules with evidence.

**Rate limit as the budget guard, scoped per unit.** `stage.limit` with
`drop = true`, and **`by_label_name = "unit"`**.

Scoping matters more than the numbers, because a global limiter is an
audit-suppression primitive handed to the developer. Journald accepts syslog
writes from any uid, so `ubuntu` can run `logger` in a loop, exceed a global
rate, and cause concurrent `sshd` and `sudo` lines to be dropped along with the
flood — defeating the system's primary requirement with no privileges at all.
Per-unit scoping confines a flooding user session to its own bucket while
`ssh.service` keeps shipping. Set `max_distinct_labels` above the expected unit
count, and confirm Alloy's behaviour for entries with no `unit` label (kernel
transport) during implementation.

> **Per-unit scoping does NOT protect the `sudo` audit line, and this is the one
> that matters most. Measured on the live fleet on 2026-08-05.**
>
> An interactive `sudo` is journaled under the invoking shell's **login session
> scope** — `session-N.scope`, a unit the developer owns — not under a distinct
> system unit. A developer's own `logger` flood lands in that *same* scope. So
> the limiter buckets the flood and the escalation-refused verdict together, and
> `drop = true` discards the verdict along with the noise. The confinement the
> paragraph above relies on is real, but the thing being protected is *inside*
> the confined bucket.
>
> Proof (logstat-a, same command `sudo /bin/true`, minutes apart):
> - **No flood** (`session-42.scope`): 1 verdict emitted on the VM → **1 reached
>   Loki.**
> - **~11 500-line `logger` flood in the same scope** (`session-38.scope`): 3
>   verdicts emitted on the VM → **0 reached Loki.** Alert 1 (*escalation
>   refused*, the one that goes to a human) therefore returned zero on a real
>   escalation attempt.
> - The saturation proxy (alert 5) did **not** compensate: it counts *arrived*
>   lines, and the limiter caps the arrived per-scope rate below the 1000/min it
>   watches for — evaluated mid-flood it read 1, against a threshold of 1000.
>
> This is the "an alert can be wrong in a way that returns zero" failure class,
> weaponised. `sshd` survives the same attack only because `ssh.service` is a
> distinct unit; `sudo` does not.
>
> **Fixed in base 0.6.0** by routing the audit-critical processes around
> `stage.limit` — a `stage.match` with a negated selector, so only bulk traffic
> is throttled and the audit trail is structurally un-throttleable. A developer
> can still burn budget with a flood, which is what the limiter is for; they can
> no longer make their own escalation attempt disappear.
>
> **Verified on a staging VM 2026-08-06**, same A/B, same load that defeated
> 0.5.0 the day before:
>
> | | emitted on the VM | reached Loki |
> |---|---|---|
> | control, no flood | 1 verdict | 1 |
> | 3 verdicts under an 11,561-line flood in the same scope | 3 | **3** |
> | the flood itself | 11,561 | 1,166 |
>
> So the audit trail passes at 100% while bulk traffic is still cut to ~10%,
> which is exactly the split the limiter is supposed to produce. Alert 1 went to
> `firing` on that VM, closing the chain end to end: attempt → survives the
> flood → reaches Loki → alerts. `audit_src` does not appear in
> `list_loki_label_names` afterwards, so the scratch label is dropped as
> intended and costs no cardinality.

### The limiter leaks under load, and always did

Of the 11,561 flood lines above, 727 arrived carrying `unit=session-N.scope`
and **439 arrived with no `unit` label at all** — some with no `_COMM` either,
though `logger` set both on the rest. Under sustained load journald does not
always attach `_SYSTEMD_UNIT` to a syslog entry, and `stage.limit` does not
throttle an entry whose `by_label_name` field is absent (`limit.go`'s
`shouldThrottle` returns false), so those bypass the limiter entirely.

That is roughly 4% of a flood escaping unmetered. It is a **budget** leak, not
an audit one — it lets more through, never less — and it predates the 0.6.0
change rather than being introduced by it. It is recorded because the limiter's
guarantee is therefore best-effort under exactly the conditions it exists for,
which matters if the free-tier cap is ever the binding constraint. The unit-less
bypass is deliberate for kernel-transport lines (see the template comment); that
it also catches user lines under load was not previously known.

### The bypass keys on `_COMM` over `SYSLOG_IDENTIFIER`, but neither is a trust boundary

`SYSLOG_IDENTIFIER` is supplied by the client. `logger -t sudo "anything"` from
an unprivileged shell produces a journal entry whose identifier reads `sudo` —
verified on a live VM 2026-08-05, landing in Loki as
`syslog_identifier=sudo, comm=logger, uid=1000`. A limiter bypass keyed on that
field would therefore hand every developer an unmetered ingest channel and let
them forge audit verdicts at will, which is a worse hole than the one being
closed.

`_COMM` is set by journald from `/proc/PID/comm` of the sending process, which
raises the bar — but it is **not unforgeable, and an earlier version of this
spec said it was.** The sender owns `/proc/PID/comm`: exec through a symlink
named `sudo` sets it (the kernel takes comm from the exec path's basename), and
`prctl(PR_SET_NAME, "sudo")` sets it at runtime. Both verified 2026-08-11. No
journald field authenticates a sudo event — narrower than "no field anchors
trust", which would contradict the `uid` and `unit` anchors this spec's own alert
table relies on. Every `_`-prefixed field describes the sending process and most
are set by it; `uid` (kernel, from `SCM_CREDENTIALS`) and `unit` (journald, from
the sender's cgroup) are not, so they pin provenance without proving what
happened. Real audit
lines carry `comm=sudo` and `comm=sshd`, so the bypass keys on `comm` because
that is the harder field to forge, not because it is safe to trust; it loses
nothing relative to `syslog_identifier` and costs a genuine attacker more
effort, which is what "best-effort" means here.

The same reasoning applies to the **alert queries**, which still filter on
`syslog_identifier`. A developer can manufacture *false* escalation-refused
alerts by forging the identifier, and — contrary to what an earlier version of
this spec claimed — could also forge a real-looking verdict on `comm` given
enough control over the sending process, so switching the queries to
`| comm="sudo"` would raise the same bar without closing it. Neither field
anchors trust, so this spec's alert queries are tripwires, not the
authoritative detector; that role belongs to a Falco rule, whose events come
from the kernel observing the syscall rather than from a line a process asked
to have logged. See
`docs/design/sudo-audit-alerting.md`.

Sizing: `rate = 20`, `burst = 200` per unit. Note that `by_label_name =
"instance"` would be pointless — each VM's Alloy sees only its own instance, so
that dimension is already implicit.

`drop = true` loses lines silently, which is a real cost in an audit system. The
alternative, `drop = false`, applies backpressure and lets one broken unit stall
everything else. Protecting the budget wins; the resulting blindness is closed
by the alerting below.

## Delivery guarantees and detection

**The guarantee is at-most-once.** `loki.write` retries a failed batch with
bounded backoff and then discards it; its write-ahead log is off by default and
this design does not enable it. Say this plainly rather than implying
durability: three ordinary events all end in permanently lost audit data.

- **Free-tier cap reached.** Grafana Cloud rejects pushes; retries exhaust;
  batches are discarded. The whole fleet stops being audited until the month
  rolls over. The spec's own arithmetic puts 50 VMs at the edge of the cap, so
  this is a foreseeable operating condition, not an edge case.
- **Loki outage or network partition.** Same mechanism. The only backstop is
  whatever journald still holds locally, bounded by its own retention.
- **Token rotation missing a region.** The token is hand-placed per region.
  Rotate and miss one, and that region's VMs get 401s indefinitely. Converge
  cannot repair it, because the recipe deliberately does not know the value.

None of these announce themselves, and, as measured earlier, a failed converge is
already invisible on an OSS CINC server, so "the recipe will notice" is not
available as an answer.

**Rejected: a dead-man's switch on per-instance ingest.** The obvious answer is
an alert that fires when a VM's ingest drops to zero for longer than a converge
cycle. It does not work on this fleet, and the reason is not subtle: **Idlefy
stops these VMs when developers finish work** — nightly, and for whole weekends.
Absence of logs is the *normal* state of a developer VM, not a fault. Such an
alert would fire across most of the fleet every evening, and an alert that cries
wolf nightly is muted within a week, which is worse than not having it.

Decided by the platform owner on 2026-08-05: developer VMs do not need a
dead-man's switch at all. A VM being off is fine and needs no announcement.

The deeper point, for anyone tempted to reintroduce it: **from logs alone,
"stopped by Idlefy" and "broken" are indistinguishable.** Any absence-based
alert here would need the EC2 instance state as a second, non-log input — a
CloudWatch metric or an equivalent — to tell the two apart. That is a real
option, but it is a metrics pipeline this demo does not have, and it should not
be added on the strength of an alert nobody asked for. Note that
`absent_over_time({job="dev-vm", instance="<name>"}[w])` *does* correctly report
a stream that never existed (verified against the live stack on 2026-08-05,
returning `1` for an instance with no data ever, where
`sum by (instance) (count_over_time(...))` cannot mention it at all) — the
mechanism was never the problem; the false-positive rate under Idlefy was.

**What is wanted instead: security alerts.** Events where something went wrong
and a human should look. These are *presence* alerts on specific log lines, so
Idlefy costs them nothing — a stopped VM simply produces no events. See
*Security alerting* below.

**Accepted blind spot, and what covers most of it.** Dropping absence detection
means the three failures above (cap reached, Loki outage, a region whose token
was never rotated) are not announced at runtime. Two of them are visible from the
Grafana Cloud usage page, and the third surfaces as `401` in a VM's own `alloy`
journal — which cannot be shipped precisely when it matters.

The token case, which is the one under our control, is covered at deploy time
instead of at runtime: `make preflight` (`scripts/preflight.sh`) fetches the
parameter in **every** region in `local.regions` and checks that it actually
authenticates against Loki, so a rotation that skipped a region fails the check
immediately rather than silently. It also catches the byte-for-byte mismatch
between `tenant.auto.tfvars` and the policyfile that `docs/runbook.md` §7 warns about.
Authentication is proven with an empty request body — good credentials return
`400`, bad ones `401` — so the check ingests nothing and creates no stream.

That leaves genuinely runtime-only causes (the cap, an outage) unannounced, which
is an accepted cost of a demo rather than an oversight; production should revisit
it with the organisation's own stack, where per-tenant usage alerting exists.

## Secret handling

Grafana Cloud Loki uses basic auth: a numeric user ID (not secret) and a token
(secret). The token is created under an access policy scoped to `logs:write`
only — push, never read.

The token lives in SSM as a SecureString and is **created by hand, not by
Terraform**, exactly as the CINC validator key is, so its value never enters
Terraform state. Terraform manages only the IAM grant.

On every converge, the root-owned recipe fetches the parameter, compares against
the on-disk file and rewrites only on difference, notifying a service restart.
Rotation is therefore just a new value in SSM: machines pick it up within 30
minutes with nothing recreated — **in every region**, which is a step in the
runbook below and not an inference.

The file is `/etc/alloy/loki-token`, mode `0640`, owner `root:alloy`.

### Mandated handling — not left to the implementer

The file's mode is the least interesting part of protecting this token. Every
rule below is required, because the cookbook contains no `sensitive` usage
anywhere today, so there is no house pattern to copy and the default behaviour
leaks:

1. **Any Chef resource whose content is or contains the token sets
   `sensitive true`.** Otherwise Chef prints the content diff on change.
2. **The token never appears in an `execute` command line or environment.** It
   would be visible in `ps` to every local user for the duration of the run.
   Fetch it with a redirect inside a root-owned shell
   (`aws ssm get-parameter … --output text > file`) or write it from a
   `ruby_block` with `File.write`.
3. **`cinc-client` output goes to the journal** — `cinc-client.service.erb` sets
   no `StandardOutput` — and this system then ships the journal to a third
   party. A token echoed during converge is therefore not merely exposed
   locally; it is exported and retained off-site. Treat any converge-time
   printing of the token as a disclosure.

### Why this holds against the developer, and where it does not

`ubuntu` has no sudo and is not in group `alloy`, so it can neither read the
token file nor stop or replace the agent. IMDS is blocked for non-root by
`imds.rb`, and that works in our favour: root fetches the token during converge,
and Alloy itself never needs instance metadata, so no existing barrier is
weakened.

**The gap the file mode does not cover.** Until this change, `sudoers.rb`
removed `ubuntu` from `sudo` and `admin` but **not from `adm`** — and on Ubuntu
the journal is readable by `adm`. So `ubuntu` could read root's converge output,
and any token reaching the journal was readable by exactly the person the file
mode excludes. This design closes that door as well (see *Resolved: `ubuntu` is
removed from `adm`*).

The secret-handling rules above nevertheless remain **mandatory, not
belt-and-braces**, and acceptance still greps the journal rather than only
stat-ing the file. Two reasons. The `adm` removal is enforced by a converge that
can fail or be reverted, so it is a control with a failure mode, not an
invariant. And a token in the journal is still shipped to Loki and retained
there — the disclosure escapes the machine whether or not a local user can read
it.

**Residual risk, accepted.** If a VM is compromised at root, the attacker gains
the ability to **write** to the shared stream — to pollute it and burn quota —
but not to read other machines' logs. And an unprivileged user can flood their
own units; per-unit rate limiting confines the damage but a determined flood
still costs quota. The property that matters for forensics survives both: logs
have already **left the machine**, so once the host is untrusted its local
journal is worthless and the copy in Loki is out of reach.

### Failure of the fetch

If the SSM call fails — throttling, partition, a missing parameter — the recipe
must **warn and continue**, following `aws_access.rb:70-80`, which logs at
`:warn` and returns rather than raising. It must not overwrite an existing token
file, so a transient API error cannot stop collection fleet-wide; and it must
not abort the converge, because every recipe ordered after `alloy` in
`default.rb` would be skipped for that cycle.

This applies equally to the **first** converge, when no token file exists yet:
Alloy installs and idles, and the next converge fixes it. It does not wedge the
run.

## Change set

**New**

- `cinc/cookbooks/base/recipes/alloy.rb`
- `cinc/cookbooks/base/templates/alloy-config.alloy.erb`

**Modified**

- `cinc/cookbooks/base/recipes/default.rb` — `include_recipe 'base::alloy'`
- `cinc/cookbooks/base/recipes/sudoers.rb` — remove `ubuntu` from `adm`, per
  *Resolved: `ubuntu` is removed from `adm`*
- `cinc/cookbooks/base/recipes/unattended_upgrades.rb` — add
  `site=apt.grafana.com`
- `cinc/cookbooks/base/metadata.rb` — version bump
- `cinc/policyfiles/dev-vm.rb` — three attributes: Loki push URL, numeric user
  ID, SSM parameter name
- `vms/modules/ec2/iam.tf` — add the token parameter's ARN to the existing
  `ReadBootstrapSecretsAndOwnAccessConfig` statement (`iam.tf:49`)
- `vms/variables.tf`, `vms/main.tf` (all three module calls),
  `vms/tenant.auto.tfvars` and `.example` — the parameter name as a variable,
  following `cinc_ssm_parameter_name`

**Docs**

- `cinc/README.md` — recipe reference and security model
- `README.md` — the log-shipping line in "What you get"
- `docs/runbook.md` — the out-of-band steps below

### One name, three places

The SSM parameter name appears in Terraform (`vms/variables.tf`, reaching the
IAM grant in `iam.tf`), in `cinc/policyfiles/dev-vm.rb` (what the recipe
fetches), and in the hand-created parameter itself — in each of three regions. A
mismatch plans clean, promotes clean, and surfaces as `AccessDenied` at converge
days later: the same shape as the `policy_arns` typo trap documented in
`CLAUDE.md`. The existing `cinc_ssm_parameter_name` escapes this only because
Terraform templates it into user_data; this one is not templated.

These strings must match, and acceptance criterion 7 is what proves it — per
region, not once.

## Out-of-band setup (not Terraform, not CINC)

1. Create the Grafana Cloud stack (US region).
2. Create an access policy scoped to `logs:write`; generate a token.
3. Put the token in SSM as a SecureString **in each of the three regions**
   (us-east-1, eu-central-1, eu-north-1), under the agreed parameter name.
4. Record the Loki push URL and numeric user ID in `cinc/policyfiles/dev-vm.rb`.
5. Create the alerts listed under *Security alerting*. This needs a Grafana
   service account token with alert-rule write scope — the `logs:write` token
   the VMs use cannot manage alert rules, and neither can a `logs:read` one.

Rotation repeats steps 2 and 3, and step 3 is done for **all three regions** or
the missed region silently stops shipping.

## Acceptance criteria

Most failure modes here are silent, so acceptance is heavier than usual. Every
item below requires a live VM; `cookstyle` and `terraform
fmt`/`validate`/`test` do not cover any of them and must not be mistaken for
coverage.

1. `ubuntu` cannot read `/etc/alloy/loki-token` — an explicit negative check,
   not an inspection of the mode bits.
2. `ubuntu` is in neither `adm` nor `systemd-journal`, and `journalctl` as
   `ubuntu` returns no system entries — while `journalctl --user` and
   `docker compose logs` still work, so the developer's own workflow is intact.
3. **After a converge that rotated the token**, the token appears nowhere in the
   journal (grepping a known prefix of the value as root, since `ubuntu` can no
   longer read it) and nowhere in Loki. This is the check that catches a leak
   the file mode cannot prevent; without it, criterion 1 can pass while the
   secret is exported to a third party.
4. The `alloy` user is in `systemd-journal`, **and log lines actually arrive in
   Loki**. A running unit is not evidence.
5. The stream's label set contains nothing outside
   {`job`, `instance`, `region`, `public_ip`, `unit`, `level`, `service_name`},
   and `boot_id` and `transport` are absent from labels. Two of these are
   conditionally absent and that is correct: `unit` on kernel-transport streams,
   and `public_ip` on a VM that has no public address. `service_name` is derived
   by Loki and is expected.

   **The test for whether a label is affordable is cardinality, not usefulness.**
   `public_ip` was added on 2026-08-05 and is free by that test: its value is a
   function of `instance`, so it creates no stream combination `instance` did not
   already create. A label that varies *independently* of the existing ones
   multiplies streams and does not belong here however useful it looks — which is
   why `pid`, `comm` and `syslog_identifier` are structured metadata.

   `public_ip` earns its place by pointing the other way to every other label:
   external reports — an abuse notice, a firewall log, someone else's alert — know
   an address and not a VM name, and this is what gets from one to the other. Note
   that it is stable but not eternal: Terraform allocates an `aws_eip` per VM, so
   it survives stop/start, but recreating a VM yields a new address and a released
   EIP can later be allocated to a **different** VM. A query by `public_ip` across
   a long window can therefore span two machines; correlate by `instance` when
   that matters. It is also baked into the rendered config rather than read at
   runtime, so a changed EIP is stale in the label for up to one converge cycle.
6. **Primary test, in two parts:**
   - **6a.** Log in as a developer, then find the `sshd` "Accepted publickey"
     line in Loki, including its key fingerprint. Proves the audit path works
     end-to-end and that INFO-level lines are not being dropped.
   - **6b.** Connect over EC2 Instance Connect as `admin` and run a `sudo`
     command; find that line in Loki with `audit_loginuid` equal to admin's uid.
     Proves the structured-metadata path and the survives-escalation property.

   These are separate because the "Accepted publickey" entry does **not** carry
   `_AUDIT_LOGINUID`: `pam_loginuid` sets it during session setup, after
   authentication. Testing both properties on one line fails on a correctly
   working system, and the natural response — adjusting the pipeline until it
   passes — would make things worse.
7. Changing the SSM value causes the VM to pick up the new token within 30
   minutes, with no instance recreation. Run **per region** — this is also what
   proves the parameter name matches in all three places.
8. Each query under *Security alerting* returns the event it claims to detect,
   **checked against Loki**, not against `journalctl` on the VM. The distinction
   is not pedantic: the first pass of this criterion was signed off from
   `journalctl` output, and two of the seven queries turned out not to match
   anything once run through Loki — see *Two wordings* and *There is no drop*.
   A query verified on the VM proves the event happened, not that the alert sees
   it.

   Three of them cannot be checked by waiting and must be provoked. Done on
   `alerttest` on 2026-08-05, all three confirmed in Loki:

   - **Refused escalation** — `sudo` as `ubuntu`, which has none. Not optional
     and not a formality: on Ubuntu 26.04 this **failed**, because `sudo-rs`
     records nothing at all when it refuses, and that is what moved the fleet
     back to 24.04 (see `ami_name_pattern`). Re-run it on any future release
     before trusting the alert. Use an interactive path — `sudo -n` alone logs
     nothing on classic sudo either and proves nothing in either direction.
   - **Converge failure** — do *not* use `systemd-run --unit=x /bin/false` as an
     earlier draft of this criterion said: that yields `x.service: Failed with
     result`, and the alert keys on `cinc-client.service`, so it would pass while
     testing nothing. Kill a real converge instead —
     `systemctl start cinc-client.service &` then
     `systemctl kill -s KILL cinc-client.service` within a few seconds — which is
     what the OOM killer does anyway and leaves no state behind. It produces
     result `'signal'` rather than `'exit-code'`; the query matches both.
     Confirmed reaching Loki *and* driving the Grafana rule to `firing`.
   - **Limiter at its ceiling** — flood one unit past 20 lines/s
     (`for i in $(seq 1 3000); do logger …; done` as `ubuntu`). 439 of 3001
     arrived.

9. A query filtering by process name matches. This looks trivial and is not:
   `stage.output` replaces the line with `MESSAGE` alone, so the process name
   lives only in the `syslog_identifier` structured-metadata field. Verified
   on 2026-08-05 — `{job="dev-vm"} |~ "useradd|groupadd"` returns **0** while
   `{job="dev-vm"} | syslog_identifier=~"useradd|groupadd"` returns the
   events. Every alert below that keys on a process depends on this, and the
   wrong form fails silently by matching nothing.

## Security alerting

Decided on 2026-08-05, replacing the rejected dead-man's switch. What is wanted
is notification when **something went wrong and a human should look** — not when
a machine is merely off.

These are all *presence* alerts: they fire on a log line that exists. That is
what makes them compatible with Idlefy. A stopped VM produces no events and so
produces no alerts, which is the correct behaviour rather than a gap to work
around.

Every query below was run against a live VM's logs before being written down.
Two properties of this pipeline shape all of them:

- **Filter processes on `syslog_identifier`, never on the line body.**
  `stage.output` reduces each line to `MESSAGE`, so `journalctl`'s tag is gone
  from the text. `|~ "useradd"` matches nothing; `| syslog_identifier=~"useradd"`
  works. This is acceptance criterion 9.
- **`unit` is absent on kernel-transport streams**, so a `{unit="..."}` matcher
  silently excludes them. Where that matters the queries below match on the
  message instead.
- **`syslog_identifier` is client-supplied and forgeable (`logger -t sudo`), so
  every query below is a tripwire, not a proof of authenticity.** A developer
  can manufacture a false positive; they cannot make a real one vanish, which is
  the property that matters for the escalation-refused alert. The authoritative
  detector for the escalation itself is a Falco rule reading the kernel's own
  view of the syscall — see
  `docs/design/sudo-audit-alerting.md`.

| # | Event | Query | Why it matters |
|---|-------|-------|----------------|
| 1 | Converge failed | `{job="dev-vm"} \|= "cinc-client.service: Failed with result" \| uid="0"` | A failed converge is invisible on an OSS CINC server, so the VM silently stops tracking the cookbook — including its security settings. Keys on systemd's own wording, not Chef's output, so it survives a change of log format. **`\| uid="0"` added 2026-08-12** — `_UID` comes from `SCM_CREDENTIALS`, which the kernel fills and a sender cannot set to someone else's uid; verified free against 30 days of live data (3 → 3 lines). |
| 2 | Escalation refused | `{job="dev-vm"} \| syslog_identifier="sudo" \|~ "NOT in sudoers\|command not allowed"` | Developers have no sudo by design. An attempt is a deliberate act and the single most interesting security event this fleet can produce. Carries `audit_loginuid`. **Requires classic `sudo`; `sudo-rs` on 26.04 logs nothing here.** Match strings taken from `sudoers.so` itself — see *Two wordings, and only one reaches the journal*. **Deliberately carries no `uid="0"` filter, unlike row 1**: sudo is setuid and journald records the *real* invoking uid, not root's — over 30 days, `\| uid="0"` returns **0** lines and `\| uid="1000"` returns **251**. Adding it would silently zero this alert. This is why row 2 stays an unhardened tripwire and the authoritative detector moved to Falco instead — see `docs/design/sudo-audit-alerting.md`. |
| 3 | Privileged command run | `{job="dev-vm"} \| syslog_identifier="sudo" \|= "COMMAND="` | Not a failure — an audit feed. Carries `audit_loginuid`, so every root command is attributable to a named human even though everyone becomes `root`. Route this to a log, not to a pager. |
| 4 | Account or group changed | `{job="dev-vm"} \| syslog_identifier=~"useradd\|usermod\|userdel\|groupadd\|gpasswd\|chpasswd"` | A new user or an added group membership is how access is quietly widened, and it is exactly what a converge is supposed to be the only source of. Expect a burst on first converge (the `alloy` user, `adm`, `systemd-journal`) and tune around it. |
| 5 | SSH login accepted | `{job="dev-vm"} \|= "Accepted publickey"` | The audit baseline: who logged in, from where, with which key fingerprint. A log feed, not a page. |
| 6 | SSH auth anomaly | `{job="dev-vm"} \|~ "Failed password\|Invalid user\|maximum authentication attempts" \| uid="0"` | These VMs are key-only with a public IP. `Failed password` should be structurally impossible, so any occurrence means either an exposure or a broken assumption. Measured baseline on 2026-08-05: **0** over six hours, against 52 successful logins — a clean zero, which is what makes it alertable. **`\| uid="0"` added 2026-08-12**, verified free against 30 days of live data (73 → 73 lines). |
| 7 | Log rate at the limiter's ceiling | `max by (instance, unit) (count_over_time({job="dev-vm"} [1m])) > 1000` | A **saturation proxy**, not a measurement of drops — see *There is no drop to alert on* for why nothing better exists without a metrics pipeline. `stage.limit` allows 20 lines/s = 1200/min per unit, so an arrived rate above 1000/min is within 85% of the ceiling and is almost certainly losing lines. Per *Rate limit as the budget guard*, a developer can trigger this deliberately, which is why it must be visible. |
| 8 | Loki push failed, audit lines dropped | `{job="dev-vm", unit="alloy.service"} \| syslog_identifier="alloy" \|~ "no retries left, dropping data"` | Added 2026-08-05, after this table was first written — see *Provisioned state* below for when and why. Unlike the row-1/row-6 hardening, this one anchors on `unit="alloy.service"` in the **stream selector**, not on `uid="0"`: Alloy logs through stdout as uid **999**, so a `uid="0"` filter would return zero and silently disable the alert — measured 2026-08-12. `unit` is derived by journald from the sender's cgroup, and a forged line lands in the developer's own session scope, not in Alloy's own system unit. |

Alert 2 is the one to wire to a human. 1, 6 and 7 are worth a channel. 3, 4 and
5 are feeds to search after an incident, not notifications — they are permanently
non-zero on a healthy fleet, so making them alert rules would produce four rules
that are always firing. They live on the *Developer VMs — audit trail* dashboard
instead, which is where 1, 2, 6 and 7 exist as Grafana rules.

### Two wordings, and only one reaches the journal

This cost the most important alert in the table. The first draft of alert 2 read
`"NOT in the sudoers|not allowed to execute|incorrect password"`, taken from what
`sudo` prints on the **terminal**. What `sudoers.so` writes to the **journal** is
different text, and none of those three branches matched it. The alert returned
zero — not because nothing happened, but because three real `user NOT in sudoers`
events were sitting in Loki from `logtest24`, one of them from this author's own
earlier acceptance run, and the query could not see them. It was the exact
silent-non-match failure that acceptance criterion 9 exists to catch, in the one
alert that matters most.

The strings below are read out of the shipped `sudoers.so` binary rather than
guessed, and each was then observed as a journal line on a live 24.04 VM:

| in the binary | logged to the journal? | verified |
|---|---|---|
| `user NOT in sudoers` | yes | ✅ `ubuntu : user NOT in sudoers ; TTY=pts/0 ; … COMMAND=/bin/true` |
| `command not allowed` | yes | ✅ `ubuntu : command not allowed ; … COMMAND=list` (this is what `sudo -l` produces) |
| `%s is not allowed to execute` | **no — terminal only** | the journal says `command not allowed` instead |
| `a password is required` | **no — terminal only** | `sudo -n` printed it and wrote nothing at all to the journal |
| `%u incorrect password attempt(s)` | only when attempts are exhausted | admin fat-fingering their own password; noise, deliberately excluded |

The `a password is required` row independently confirms the methodology warning
under `ami_name_pattern`: **non-interactive `sudo -n` writes no journal entry on
classic sudo either.** Re-verified here on 1.9.15p5.

If a future sudo release changes this wording, the alert stops matching in
silence. Re-derive the strings from the binary — `grep -a` works, `strings` is
not installed on the AMI — rather than from documentation or from what the
terminal shows.

### There is no drop to alert on

Alert 7 was originally `| syslog_identifier="alloy" |= "dropped"`. Alloy does log
to the journal, and it logs nothing whatsoever when `stage.limit` discards a
line. Measured on a live VM: **3001 lines emitted from one unit, 439 arrived,
Alloy's own journal completely silent about the 2562 it threw away.** The alert
could never have fired.

The drop is only visible as the Prometheus counter
`loki_process_dropped_lines_total` on Alloy's `127.0.0.1:12345/metrics`, and this
platform ships logs and no metrics, so nothing scrapes it. Rather than add a
metrics pipeline for one counter, alert 7 now keys on what *is* visible: the
arrived rate saturating at the limiter's ceiling. That is a proxy and is labelled
as one in the rule's own description. The 439-of-3001 measurement is also the
first direct confirmation that the limiter works at all.

Adding a metrics pipeline — `prometheus.exporter.self` plus
`prometheus.remote_write` to Grafana Cloud Mimir, with its own token in SSM
alongside the Loki one — would turn this into a real measurement. It is
deliberately not done yet: one counter does not justify a second credential, a
second endpoint and a second per-region rotation path.

One expected `Invalid user` per VM lifetime, which is **not** an attack: EC2
Instance Connect as `admin` before the first converge has created that user
yields `Invalid user admin from <your ip>`. Anyone bringing up a VM and
impatiently trying to log in produces exactly one. Observed on `logtest24` —
from this author, doing precisely that. Worth knowing before reading the first
firing as an intrusion.

**Do not add `AuthorizedKeysCommand.*failed` to alert 6.** It looks like an
authentication failure and is not: EC2 Instance Connect's
`eic_run_authorized_keys` is consulted per candidate key and exits `255` on the
ones that do not match, so the line appears during entirely normal logins —
measured at 15 occurrences against 52 successful logins in the same six-hour
window, with no attack of any kind. It was in the first draft of this table and
was removed after measuring it. Alerting on it would reproduce, in miniature,
the nightly false-positive problem that killed the dead-man's switch.

### Provisioned state

Live in Grafana as of 2026-08-05, folder **Developer VMs** (`dev-vm-security`),
rule group `dev-vm-security`:

| rule | uid | severity | `for` | window |
|---|---|---|---|---|
| `dev-vm: escalation refused` | `ffuahumsc3z0gc` | critical | 0s | 5m |
| `dev-vm: Loki push failed, audit lines dropped` | `dfuan1d6q7jeof` | critical | 0s | 15m |
| `dev-vm: converge failed` | `ffuahvap8m58gc` | warning | 0s | 30m |
| `dev-vm: SSH authentication anomaly` | `cfuah6amothxcb` | warning | 1m | 5m |
| `dev-vm: log rate at limiter ceiling` | `afuahw3yfaxogb` | warning | 1m | 1m |
| `dev-vm: Falco runtime detection` | `ffuafalcodet1` | critical | 0s | 5m |

The Falco row landed on 2026-08-06, after this design was written. It is listed
here so this table, `grafana/README.md` and `grafana/alerts/dev-vm-security.yaml`
all say six; why it carries no threshold is argued in `grafana/README.md`, not
here.

The push-failure rule was added on 2026-08-05, after the audit dashboard turned up
the two lines it keys on sitting in Loki from that day's token test:
`level=error msg="final error sending batch, no retries left, dropping data"` with
`status=401` and `authentication error: invalid token`. That is audit data
destroyed, reported by the only component that can see it, and nothing was
watching for it. It complements rather than replaces the saturation proxy: this
catches a *transient* push failure, whose backlog arrives once the path recovers,
while a permanently wrong token in one region still ships nothing at all and is
still only caught by `make preflight`.

**A note that cost two panels and nearly cost this rule: Alloy's severity is
invisible to journald.** Alloy writes to stdout, so journald stamps every line it
produces — errors included — with priority `info`, and both real occurrences of
the message above carry `level="info"` as a stream label. Any filter built on the
journal-derived `level` label finds no Alloy error, ever. Severity exists only in
Alloy's own `level=` field inside the message text. The neighbouring trap is
matching the bare word `error`: case-insensitively that scored 90 hits against
these logs, 88 of them Alloy's entirely normal `node exited without error`.

Two settings are load-bearing on every rule and must not be "tidied":

- **`noDataState: OK`.** These are presence alerts and the fleet is routinely
  empty — Idlefy stops VMs outside working hours. `NoData → Alerting` would page
  every evening, which is the failure that killed the dead-man's switch.
- **`execErrState: Alerting`.** A detector that cannot run is a security control
  that is off, and this platform has no second path to notice that. The `for`
  values keep a single transient Loki error from paging: with `count_over_time`
  over a window longer than the evaluation interval, a genuine event stays true
  across several evaluations while a one-off error does not.

The converge-failed window is 30m to match the converge timer. A 5m window would
resolve the alert between runs while the VM is still failing to converge.

**Still missing: a contact point.** The stack has none, and its root notification
policy points at a receiver named `empty` that does not exist — so nothing is
deliverable yet, however the rules evaluate. Creating one over the API returned
403 on both `/api/v1/provisioning/contact-points` and the Grafana 13
`notifications.alerting.grafana.app` resource, despite the account holding
`alert.provisioning:write`; rule and dashboard writes on the same credential
succeed. Create it in the UI (Alerting → Contact points), then point the default
policy at it, or re-attempt with a token minted specifically for notification
scopes.

## Migration to production

Moving to the organisation's own Grafana Cloud is: create an access policy with
`logs:write`, put the token in SSM in all three regions, change the URL and user
ID in `dev-vm.rb`, then `make push && make promote`. No code changes. The same
path leads to a self-hosted Loki if per-GB pricing later stops making sense — an
endpoint is an endpoint.

## Resolved: `ubuntu` is removed from `adm`

Decided by the platform owner on 2026-08-04: developers get no privileged access
to the machine, and system-log visibility moves to Grafana.

To be precise about what this changes, because the two are easily conflated:
`adm` is **not** sudo. Developers already have no sudo — `sudoers.rb` strips
`ubuntu` from `sudo` and `admin` and deletes the `sudoers.d` fragments. `adm` is
the log-read group, so removing it withdraws *reading the system journal*, not
privilege.

**Cost: none for the actual workflow.** The developer loses `journalctl`
system-wide and `/var/log/syslog` and `auth.log`. What they keep is everything
they use: `journalctl --user` for their own session units, and all
rootless-Docker logs — which live in the user's own data directory and are
served by the user's own daemon, so `docker compose logs` never touches the
system journal. Developers on this platform run containers; they do not read
the host's OS logs, and are not meant to.

No compensating control is therefore needed. Read-only Grafana access for
developers may be granted for other reasons, but it is not required to make this
removal safe.

Nothing in the cookbooks depends on `adm` (verified by grep across
`cinc/cookbooks/`), so no recipe breaks. The removal follows the existing
`gpasswd -d` pattern in `sudoers.rb` and belongs in that recipe, which is where
the developer's default privileges are stripped — with a comment noting that
`adm` is log access rather than escalation, so a future reader does not "fix"
its apparent misplacement.

Because the fleet is currently empty, no developer loses access they are
presently using.

## Open items for implementation — all closed

Kept as a record of what the answers turned out to be, because two of them cost
real investigation and one of them was a security hole.

- **Alloy's unit, config path and user.** `alloy.service`,
  `/etc/alloy/config.alloy`, package-created user and group `alloy`. As expected.
  The config is `0640 root:alloy` in a `0750` directory so the developer cannot
  read the token file it references.
- **`stage.structured_metadata` argument form.** The map form
  (`values = { boot_id = "" }`) is correct; the list form in community examples
  is not. Confirmed by the fields arriving as structured metadata in Loki rather
  than as labels.
- **`stage.limit` with entries carrying no `unit` label.** They are **not**
  throttled — `limit.go`'s `shouldThrottle` returns false when `by_label_name`
  is absent. Deliberate for kernel-transport lines, but measured on 2026-08-06 to
  also catch user lines under load: 439 of an 11,561-line flood arrived with no
  `unit` at all, so roughly 4% escapes unmetered. `max_distinct_labels` is 10000
  because `limit.go` raises anything lower to that floor itself and warns on
  every start otherwise.
- **Source of the `region` label.** ohai's EC2 data —
  `node['ec2']['placement_availability_zone']` with the trailing AZ letter
  stripped. `cinc-client` runs as root and can reach IMDS. The same recipe reads
  `node['ec2']['public_ipv4']` for `public_ip`, falling back to an IMDSv2 call.
- **The stale `/var/ossec/etc/client.keys` comment** left over from Wazuh: gone.
  No `ossec` or `wazuh` reference remains anywhere in `vms/` or `cinc/`.

The one question the spec did not think to ask, and which mattered most: whether
per-unit scoping actually protects the `sudo` audit line. It did not — see the
rate-limit section above.
