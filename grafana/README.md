# Grafana configuration

What watches the fleet, kept in the repo rather than only in the Grafana UI.

| path | what |
|------|------|
| `alerts/dev-vm-security.yaml` | The six alert rules. Folder **Developer VMs**, rule group `dev-vm-security`. |
| `dashboards/dev-vm-audit.json` | The *Developer VMs — audit trail* dashboard: 22 panels in five rows — Fleet, Who did what, Anomalies, Pipeline health, Runtime detection. |

The queries in these files carry real, expensively-acquired knowledge — two of
the original seven matched nothing because they keyed on wording that never
reaches the journal. Before editing an `expr`, read *Two wordings, and only one
reaches the journal* and *There is no drop to alert on* in
[the design record](../docs/design/log-shipping.md).

## Applying

Both files reference the Loki datasource by uid `grafanacloud-logs`, which is the
default uid of the Loki datasource on a Grafana Cloud stack. On a stack where it
was renamed, or on self-hosted Grafana, replace that uid (`grep -rn
grafanacloud-logs .`) with your datasource's before applying.

These are **not** applied by Terraform, on purpose. The `vms/` and `infra/`
roots use one AWS credential each; wiring Grafana into them would put a Grafana
admin token into Terraform state, which is stored in S3 and read by everyone who
can plan. Apply them with a short-lived token instead:

```bash
export GRAFANA_URL=https://<stack>.grafana.net
export GRAFANA_TOKEN=<service account token, alert-rule write scope>

# Alert rules. Note the methods: the provisioning API answers GET on the export
# endpoint and PUT on a rule group, and returns 404 — not 405 — for anything
# else, so a POST here fails in a way that reads like a wrong URL or a bad token.
curl -sf "$GRAFANA_URL/api/v1/provisioning/alert-rules/export" \
     -H "Authorization: Bearer $GRAFANA_TOKEN" >/dev/null   # sanity-check auth
curl -sf -X PUT "$GRAFANA_URL/api/v1/provisioning/folder/dev-vm-security/rule-groups/dev-vm-security" \
     -H "Authorization: Bearer $GRAFANA_TOKEN" \
     -H "Content-Type: application/yaml" \
     --data-binary @alerts/dev-vm-security.yaml

# Dashboard
curl -sf -X POST "$GRAFANA_URL/api/dashboards/db" \
     -H "Authorization: Bearer $GRAFANA_TOKEN" \
     -H "Content-Type: application/json" \
     --data @dashboards/dev-vm-audit.json
```

The folder itself (`dev-vm-security`, titled *Developer VMs*) must exist first —
the rule group import does not create it.

## Traps

Each of these produced a panel or a rule that ran without error and showed
nothing — the failure mode this whole directory is fighting. **Render a panel and
look at it before believing it**; the query results alone hid every one of them.

**`{{.__line__}}` is silently empty; the working form is `{{ __line__ }}`.** With
the dot, `line_format` emits everything else and drops the message body, so three
anomaly panels rendered timestamps and hostnames with no log text at all. Parsed
and structured-metadata labels *do* take the dot (`{{.actor}}`,
`{{.audit_loginuid}}`) — the original line is the exception.

**A refused `sudo` also carries `COMMAND=`.** So `|= "COMMAND="` counts denials as
executed root commands, and the *Root commands by actor* table credited `ubuntu`
with three of them on each VM — a user holding no sudo at all. It was invisible
until two VMs with real activity were on screen: with one VM and only `admin`
active, the wrong rows simply were not there to see. The three affected queries
now carry `!~ "NOT in sudoers|command not allowed"`, the same two verdicts alert 1
matches; change one and change both. All three still key on `syslog_identifier`
— see the next trap for what that field is and is not worth trusting.

**The journald sudo queries do not prove the escalation happened — they prove a
line that says so arrived.** That is alert 1 and the three dashboard panels
above. It is **not** true of alert 6, which reads Falco's stream rather than
sudo's own log line, and that difference is the whole reason alert 6 exists —
see *Falco* below. Keep the two apart when editing: this paragraph used to open
"None of the alert queries", which swept alert 6 in and read as though the
kernel-level detector were as forgeable as a log line — the opposite of what the
*Falco* section says.

`syslog_identifier=sudo` is trivially forged from an
unprivileged shell: `logger -t sudo "anything"` produces exactly that field,
measured as `syslog_identifier=sudo, comm=logger, uid=1000`. The pipeline keys
its rate-limiter bypass on `comm` instead, which raises the bar — but `comm` is
also set by the sender, via exec through a symlink named `sudo` or
`prctl(PR_SET_NAME, "sudo")`, both verified 2026-08-11. No journald field
authenticates a *sudo event*. Be precise about why, because two fields are
still worth anchoring on: every journald field describes the sending process,
and most are also set by it — but `uid` is filled in by the kernel from
SCM_CREDENTIALS and `unit` is derived from the sender's cgroup, so neither can
carry a value its sender does not already have. They constrain provenance
without proving what happened, which is why the hardened queries use them and
sudo still needs Falco. These queries stay useful as
tripwires — a developer can manufacture a false alert but not erase a real one
— but the authoritative escalation detector is a Falco rule reading the
kernel's own view of the syscall, not a line a process asked to have logged.
See
[the sudo-audit-alerting design](../docs/design/sudo-audit-alerting.md).

**`legendFormat` does not name a Loki field.** In a table, the value column is
`Value #A` regardless — even for a single query. So `renameByName`, `sortBy` and
every override that matched a friendly name silently did nothing. Match on
`Value #A`, `Value #B`, … and rename there.

**`topk(N)` does not cap the series count in a range query.** It takes the top N
at each instant, so the union over a range is far larger: `topk(10, …)` by unit
produced twenty-odd series and cycled colours past the palette. If you want one
line, aggregate to one line (`max(...)`), not a top-N.

**Alloy's severity is invisible to journald.** Alloy writes to stdout, so every
line it produces — errors included — is stamped priority `info`. A filter on the
journal `level` label finds no Alloy error ever. Severity lives only in Alloy's
own `level=` field inside the message text. And do not match the bare word
`error`: case-insensitively that scored 90 hits on our logs, 88 of them Alloy's
normal `node exited without error`.

**`status-history` refuses to render past ~1000 points.** `$__interval` over 12
hours yields 1441, and the panel shows "Too many points" instead of data. Cap it
with a panel-level `maxDataPoints` — the target-level field is ignored.

**Grafana's own export writes `folder: ""`.** Re-exporting over
`alerts/dev-vm-security.yaml` produces a file that fails to import. If you round-trip
through the UI, put `folder: Developer VMs` back.

**Rules can evaluate, fire, and deliver nothing.** A stack with no contact point
routes to a receiver named `empty` that does not exist. That state looks
identical to "no alerts have fired". Check
`Alerting → Notification policies` shows a real receiver before trusting silence.

Creating a contact point needs *notification* write scope, which an alert-rule
token does not carry — and on Grafana Cloud 13 the API returns 403 for contact
points even on an otherwise-admin credential. Create it in the UI.

## Falco

`base::falco` ships runtime syscall detections through the same journal, so they
arrive in Loki as `unit="falco-modern-bpf.service"`, one JSON object per line,
which `| json | __error__=""` parses into `rule`, `priority` and a flattened
`output_fields_*` label set. The `__error__` guard is load-bearing: Falco's
startup banner goes through the same channel and is *not* JSON — without the
guard it poisons every query on this stream, on every Falco restart.

The *Runtime detection* dashboard row (stat, by-rule timeseries, recent
detections) and alert rule 6 query this stream. Rule 6 has **no threshold** — the
ruleset was measured silent on this platform, so any event is worth a human.

These panels have a verification problem the others do not: their correct reading
on a healthy fleet is **zero**, which is also what a broken query returns. They
were built against a window in which each rule had deliberately been made to fire
— a credential write, an IMDS attempt, a denied access in the credential store —
and rendered there, per the first trap above. Do the same before trusting your
own: provoke each rule on a staging VM, confirm the panels light up, and only
then read a later zero as "nothing happened" instead of "nothing arrives".

## What is deliberately absent

No alert on a VM that stops shipping logs. Idlefy stops these VMs when
developers finish work, so silence is the normal overnight state of the fleet and
an absence alert would fire across most of it every evening. The accepted cost —
a region whose token was never rotated ships nothing and nothing announces it at
runtime — is covered at deploy time by `cd cinc && make preflight`, not at
runtime.
