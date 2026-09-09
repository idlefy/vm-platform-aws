# Sudo audit alerting — kernel-sourced trust, journald as a tripwire

> Design record, written during development; identifiers anonymised. Numbers are as measured.

**Date:** 2026-08-12
**Status:** design, approved to implement
**Supersedes:** an earlier draft that proposed moving the trust boundary to
journald's `_EXE`. That approach was measured and refuted; see *What was tried*.

## The defect

The security alerting on the dev VMs decides whether a journal line is genuine
by reading fields of the line. Every such field is controlled by whoever sent
the line, so an unprivileged developer can fabricate any of these events.

Measured 2026-08-11/12:

- **Three of the six alerts are forgeable with one command.** Alerts 2
  (`dev-vm: converge failed`) and 3 (`dev-vm: SSH authentication anomaly`) match
  **only the line body** with no identifier at all, so
  `logger 'cinc-client.service: Failed with result'` and `logger 'Failed
  password'` raise them. Alert 4 (`dev-vm: Loki push failed`, severity
  **critical**) selects `syslog_identifier="alloy"`, which `logger -t alloy`
  sets.
- **Alert 1 (`dev-vm: escalation refused`, the fleet's only paging alert)
  selects `syslog_identifier="sudo"`**, likewise set by `logger -t sudo` —
  already recorded in CLAUDE.md.
- **`_COMM` is not a fix, contrary to what this repo states in four places.** An
  unprivileged user sets their own `/proc/PID/comm` by exec'ing through a symlink
  of the desired name, or by `prctl(PR_SET_NAME)`. Both verified.
- **No journald field is a sound anchor for sudo.** A full forgery was
  constructed that matches a genuine sudo record on `_EXE`, `_COMM`, `_UID`,
  `_GID`, `_AUDIT_LOGINUID`, `_AUDIT_SESSION`, `_CAP_EFFECTIVE` and
  `_SYSTEMD_UNIT` simultaneously. Two techniques combine: the sender wins
  journald's `/proc` race by not exiting after sending, and an unprivileged
  user+mount namespace (`unshare -rm`, available because these VMs run rootless
  Docker) bind-mounts an attacker binary over the victim path, so journald —
  reading from the host namespace — attributes the line to the victim path.

The cause is structural: journald derives every `_`-prefixed field from the
sending process, and the sending process belongs to the attacker.

### What this does and does not cost us

**It does not hide events.** The suppression hole closed in base 0.6.0 stays
closed: a forged flood skips the limiter, but so does the genuine verdict, so the
audit trail survives. The damage is fabricated alerts, a polluted trail, and
ingest budget. The path from there to real blindness is alert fatigue — a pager
anyone can spam gets ignored — which is why this is worth fixing, and why it is
not an emergency.

## Decisions

### 1. One trustworthy escalation detector, sourced from the kernel: Falco

Falco is already deployed on these VMs with a modern eBPF probe, already ships
three custom rules, and already reaches Telegram through alert 6. Its events come
from syscalls observed in the kernel, so there is no sender to lie. The existing
rules already use exactly the fields needed — `proc.exepath`, `user.uid`,
`user.loginuid`, `proc.cmdline`, `proc.pname`.

Add one rule: **`ubuntu` executed sudo.** That is the event alert 1 exists to
catch, and from the kernel it cannot be fabricated. The verdict (granted vs
refused) is not in the syscall stream, but it is derivable — with one permitted
command in sudoers, any other argv was refused.

This is a rule added to a working file, not a new subsystem. `auditd` is
therefore not needed and stays uninstalled.

**Interaction with the Tailscale design:** once `sudo tailscale login` is
permitted, exclude that exact argv from the rule, or every legitimate login pages
someone. See an unpublished design record.

### 2. Harden the journald alerts where a *measured* unforgeable anchor exists

Not every alert needs Falco. Three have an anchor that a developer cannot set,
because it comes from the kernel or from journald's view of the sender's cgroup —
and each was verified to cost nothing over 30 days of live data:

| Alert | Add | Lines matched before → after |
|---|---|---|
| 2 `converge failed` | `\| uid="0"` | 3 → 3 |
| 3 `SSH authentication anomaly` | `\| uid="0"` | 73 → 73 |
| 4 `Loki push failed` | `unit="alloy.service"` in the stream selector | 1349 → 1349 |

`_UID` comes from `SCM_CREDENTIALS`, which the kernel fills; a developer's line
carries their own uid. `unit` is derived by journald from the sender's cgroup; a
forged line lands in the developer's `session-N.scope`.

This is not a contradiction of *The defect* above, which lists `_SYSTEMD_UNIT`
among the fields the full forgery matched. Both are true, and the reconciling
fact is where the genuine event lives: a real sudo verdict is itself journaled
under the developer's own `session-N.scope`, so the forgery matched
`_SYSTEMD_UNIT` for free by landing in that same scope alongside it — it did
not need to escape into a unit it does not own. What a sender still cannot do
is place itself in a **root-owned unit's** cgroup, which is exactly what makes
`unit="alloy.service"` on alert 4 a real anchor: Alloy runs as a system unit,
not a developer session. `unit` anchors trust only against a root-owned unit;
it establishes nothing for an event that is itself session-scoped, as sudo's
is — which is the other half of why alert 1 stays a tripwire rather than being
hardened the same way.

**Do not use `uid="0"` on alert 4** — Alloy logs through stdout as uid **999**,
so that filter returns zero. Measured; this is the trap that makes "apply the
same filter everywhere" wrong.

**Do not use `uid="0"` on alert 1 either.** sudo is setuid and journald records
the *real* uid: over 30 days, `syslog_identifier="sudo" | uid="0"` returns **0**
lines and `| uid="1000"` returns **251**. That is why alert 1 goes to Falco
instead of being patched.

### 3. Alert 1 stays, relabelled as a tripwire

Keep it — it is cheap and it still catches the careless case — but stop treating
it as authoritative, in the alert's own `description` and in `grafana/README.md`.
Falco becomes the control; this stays a hint. Retiring it would remove the only
signal for accounts other than `ubuntu`: `user NOT in sudoers` is printed only
when the user has no sudoers entry at all, so that branch keeps its meaning for
service accounts and anything an attacker creates.

### 4. Ship `exe`, for visibility only

Add `exe = "_EXE"` to `stage.json` and `exe = ""` to `stage.structured_metadata`.
Keep `comm`. **Do not key any selector on either.** The pair is how a responder
*sees* a forgery in a panel: a line claiming to be sudo whose `exe` is absent or
points somewhere else. Additive, so there is no window where a selector matches
nothing.

**Explicitly rejected: converting the limiter bypass to `_EXE`.** It would mean
eleven absolute paths in place of eleven process names, and:

- two of them would have been wrong in the draft — `gpasswd` and `passwd` live in
  `/usr/bin`, not `/usr/sbin`, and a wrong literal silently removes a SUID
  binary's bypass;
- it carries two release mines — on 26.04 sudo resolves to
  `/usr/lib/cargo/bin/sudo`, and with openssh ≥9.8 the session is logged by
  `/usr/lib/openssh/sshd-session`, so an AMI bump breaks sudo and sshd at once;
- and the userns forgery defeats it anyway.

The bypass keeps selecting on `comm`. Its comment must stop claiming that field
is unforgeable and state what it actually buys: keeping audit processes off the
limiter, on a best-effort basis.

### 5. Validate the Alloy config

`alloy.rb`'s `template` notifies a restart with no `verify`, and no Makefile
target checks the config. A malformed selector means Alloy does not start, the VM
ships **nothing**, and `noDataState: OK` guarantees nobody is told. Add a
`verify` to the template resource, and a verification step that lines still
arrive after converge. Found while reviewing this change; independent of it.

### 6. Correct the false claim wherever it is stated

The "`_COMM` cannot be spoofed by the sender" claim is load-bearing in four
places and is wrong. It has already caused one wrong design (this spec's own
first draft), so it gets corrected everywhere, with both forgery mechanisms
named.

## Files to change

| File | Change |
|---|---|
| `cinc/cookbooks/base/files/default/falco-dev-vm-rules.yaml` | new rule: `ubuntu` executed sudo. Exclude the permitted Tailscale argv when that ships. |
| `cinc/cookbooks/base/templates/alloy-config.alloy.erb` | `exe = "_EXE"` in `stage.json`, `exe = ""` in `stage.structured_metadata`; keep `comm` and the `comm`-based bypass; **rewrite the comment** that calls `_COMM` unspoofable, naming the symlink and `prctl` mechanisms. |
| `cinc/cookbooks/base/recipes/alloy.rb` | `verify` on the config template. |
| `cinc/cookbooks/base/recipes/falco.rb` | the comment at ~249 cites "the same trust boundary as `_COMM` versus `SYSLOG_IDENTIFIER`" as justification for `proc.exepath`. The analogy now reads the other way: Falco is trustworthy because the *kernel* is the source, not because a field name starts with an underscore. |
| `cinc/Makefile` | a lint/validate target for the rendered Alloy config, if one can be run without a VM; otherwise say why not. |
| `grafana/alerts/dev-vm-security.yaml` | alerts 2 and 3 gain `\| uid="0"`; alert 4 gains `unit="alloy.service"`; alert 1's `description` relabelled as a tripwire; the header guidance at 26–29 ("filter processes on `syslog_identifier`") corrected; a rule for the new Falco detection if it does not fold into alert 6. |
| `grafana/dashboards/dev-vm-audit.json` | show `exe` alongside `comm` on the investigative panels so a forgery is visible. **Keep filtering on `syslog_identifier`** — history holds no `exe`, and a pre-change line cannot be made trustworthy retroactively; filtering would silently zero a panel for a past incident. Panel 784's description repeats the corrected guidance. |
| `grafana/README.md` | the Traps section, the "three affected queries" note, and the six-rules count. |
| `docs/design/log-shipping.md` | the section heading "The bypass must key on `_COMM`, never on `SYSLOG_IDENTIFIER`" is now false; also lines ~372–381 (including the advice to "add `\| comm="sudo"`", now an anti-recommendation), the structured-metadata inventory, acceptance criterion 9, the "filter on `syslog_identifier`" rule, and two alert-table rows. |
| an unpublished design record | it currently prescribes `exe="/usr/bin/sudo"` as a hardcoded literal and describes `comm` as the anchor. Rewrite its alerting section to point at Falco. |
| `CLAUDE.md` | correct the `_COMM` claim in the rate-limiter trap; add that no journald field anchors sudo and why. |
| an unpublished design record | contains a copy of the two Alloy stages. If it is a frozen artefact, say so in place rather than leaving a silent third copy. |
| `cinc/cookbooks/base/metadata.rb` | version bump; `cinc/policyfiles/dev-vm.lock.json` regenerated by `make push`. |

## Rollout order

Grafana-side and CINC-side changes must not be interleaved carelessly: the
template ships through converge (30 minutes, and longer for VMs Idlefy has
stopped) while alerts apply immediately. Because nothing here moves a selector
onto a newly-shipped field, there is no blindness window — but the order still
matters.

1. **Doc corrections** (item 6) — no runtime effect, and they stop the false
   claim propagating into the next change. Ship first.
2. **Alert hardening** (item 2) — Grafana-only, immediate, verified free against
   30 days of data. Safe before any converge.
3. **Alloy `exe` + comment + `verify`** (items 4, 5) — `make lint`, `make push`,
   converge a staging VM. Gate: Alloy is active **and lines are still arriving**,
   and `exe` is visible in Loki. Only then `make promote`.
4. **Falco rule** (item 1) — after 3, so `exe` is available for cross-checking.
   `make push`, converge staging, confirm the rule fires on a real `sudo` and
   stays silent otherwise, then `make promote`.
5. **Dashboard** (`exe` column) last, once the field exists fleet-wide.

Wait on a condition, not a timer, before `promote`: compare the `instance` label
values against `count by (instance) (count_over_time({job="dev-vm"} | exe!="" [1h]))`
and chase the VMs Idlefy kept stopped.

## Verification

On a **throwaway staging VM** (`policy_group = "staging"`) — not on a
developer's machine: the flood and forgery tests pollute a real audit trail and
count against the free tier. Delete it with all three steps, including
`make node-delete`.

1. **Alloy survives.** After converge, Alloy is active and lines keep arriving.
   This is the failure that hides itself; check it first.
2. **`exe` arrives** and carries the literal value for real sudo lines on 24.04
   — record it, do not assume `/usr/bin/sudo`.
3. **Falco fires on a real sudo** by `ubuntu`, and the event reaches Loki, not
   just the VM's journal.
4. **Falco does not fire on the three forgeries**: `logger -t sudo '<line>'`,
   exec through a symlink named `sudo`, and a lingering sender in an
   `unshare -rm` namespace bind-mounted over the sudo path. These are the
   attacks that beat every journald field; the point of Falco is that they are
   invisible to it.
5. **Hardened alerts still fire on real events** — a genuine converge failure and
   a genuine SSH auth failure — and **no longer fire** on
   `logger 'cinc-client.service: Failed with result'` or `logger 'Failed
   password'` from `ubuntu`.
6. **The 0.6.0 A/B still holds:** with an ~11,500-line flood in the developer's
   own session scope, a real sudo verdict still reaches Loki.
7. **Falco's silence baseline** is unchanged for ordinary work (the existing
   measurement covered idle, npm, docker build, `make -j4`, apt, logrotate).

Verify in **Loki**, not `journalctl`: the VM proves the event happened, only Loki
proves the alert can see it.

## Out of scope

- **Absence detection for silent VMs.** Every alert has `noDataState: OK`, so a
  VM that goes dark raises nothing, and Idlefy makes silence routine — a real
  gap, a different problem.
- **Unprivileged user namespaces.** Whether `ubuntu` can run `unshare -rm` on
  these VMs is unmeasured (the test VM was deleted, and the cookbook does not
  touch userns, so the 24.04 default applies). It decides how easy the
  full-fidelity forgery is, but not the design: Falco is the anchor either way.
  Worth measuring on the staging VM used for verification, and worth its own
  decision if the answer is yes.
- **Ingest metering.** Even after this, a developer can burn budget by looping a
  real `sudo -n true`: genuine lines, each taking the bypass. Bounding that is a
  separate question.

## What was tried

The first draft moved the trust boundary from `_COMM` to `_EXE`. Two independent
reviews killed it: the forgery above matches `_EXE` too, and the conversion would
have cost eleven brittle path literals with two of them wrong and two release
mines. Recorded here so the next reader does not re-derive it — the appeal of
"just use the underscore-prefixed field" is strong and wrong.
