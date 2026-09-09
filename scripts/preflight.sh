#!/usr/bin/env bash
# Preflight: check the invariants that `terraform plan` cannot.
#
# Everything here is a failure that applies clean, promotes clean, and then
# surfaces days later on a VM — usually as AccessDenied, a 401, or simply no
# logs. Each check below corresponds to one such gap already named in the docs —
# CLAUDE.md or the log-shipping spec, and exists because nothing else covers it:
# hand-placed per-region secrets are invisible to Terraform (it manages the IAM
# grant that *names* a parameter, never the value), and external policy ARNs are
# never resolved by any test.
#
# Read-only. Creates no AWS resources and ingests nothing into Loki.
#
# Usage:  cd cinc && make preflight        (or: scripts/preflight.sh)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS="$ROOT/vms"
POLICYFILE="$ROOT/cinc/policyfiles/dev-vm.rb"

PASS=0 FAIL=0 WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v terraform >/dev/null || { echo "terraform not on PATH"; exit 2; }
command -v aws       >/dev/null || { echo "aws not on PATH"; exit 2; }

# ---------------------------------------------------------------------------
# Inputs. Read through `terraform console` rather than grepped out of the HCL:
# the region list lives in a local (`local.regions`) and the parameter names in
# variables, so console is the only source that cannot drift from what Terraform
# actually uses. The region count is not fixed at three; the docs say so.
# ---------------------------------------------------------------------------
head_ "Reading tenant configuration"
# Must stay on ONE line: `terraform console` evaluates input line by line, so a
# pretty-printed expression fails with "Expected the start of an expression, but
# found the end of the file" — which reads like a syntax error in the HCL rather
# than in this script.
CONSOLE_EXPR='jsonencode({regions = keys(local.regions), loki = var.loki_ssm_parameter_name, shipping = var.log_shipping, cinc = var.cinc_ssm_parameter_name, profile = var.aws_profile, bundles = {for k, v in var.access_bundles : k => v.policy_arns}})'

# console prints the jsonencode() result as a quoted JSON *string*, hence the
# double decode below.
RAW="$(cd "$VMS" && echo "$CONSOLE_EXPR" | terraform console 2>/dev/null | tail -1)"
# All-or-nothing. The old version printed line by line and shlex.quote() raised
# TypeError on a null loki name (and on the bool) — after REGIONS= was already
# on stdout. VARS was then non-empty, the guard below did not fire, and the
# script died later at "$PROFILE: unbound variable" with no diagnostic. Now any
# failure prints nothing and the guard names the cause.
VARS="$(python3 - "$RAW" 2>/dev/null <<'PY'
import sys, json, shlex
try:
    c = json.loads(json.loads(sys.argv[1]))
    out = [
        "REGIONS=%s" % shlex.quote(" ".join(c["regions"])),
        "LOKI_PARAM=%s" % shlex.quote(c["loki"] or ""),
        "LOG_SHIPPING=%s" % shlex.quote(str(c["shipping"]).lower()),
        "CINC_PARAM=%s" % shlex.quote(c["cinc"]),
        "PROFILE=%s" % shlex.quote(c["profile"]),
    ]
    arns = sorted({a for v in c["bundles"].values() for a in v})
    out.append("BUNDLE_ARNS=%s" % shlex.quote(" ".join(arns)))
    out.append("BUNDLE_COUNT=%d" % len(c["bundles"]))
    print("\n".join(out))
except Exception:
    sys.exit(1)
PY
)"
if [ -z "${VARS:-}" ]; then
  # Three different causes, and the old single message named none of them.
  # Once module "ec2" is a remote source, `terraform console` cannot evaluate
  # local.regions until init has fetched it — so a missing .terraform/, an
  # expired SSH agent and a genuine HCL error all arrived here looking alike.
  if [ ! -d "$VMS/.terraform" ]; then
    bad "vms/ is not initialised — run 'cd vms && terraform init -backend-config=backend.hcl'.
      The platform modules are remote now, so this needs network access and git
      auth to the upstream repository before any region name can be read."
  elif ! ( cd "$VMS" && terraform providers >/dev/null 2>&1 ); then
    bad "vms/ is initialised but its modules do not resolve — run 'terraform init' again.
      Usually the pinned commit is unreachable (a deleted tag), or the SSH agent
      holds no key for the upstream repository. 'make pin-check' distinguishes them."
  elif ! grep -q 'variable "log_shipping"' "$VMS/variables.tf" 2>/dev/null; then
    bad "vms/variables.tf does not declare log_shipping — this preflight needs the current skeleton.
      Re-materialise vms/variables.tf and vms/main.tf from tenant-skeleton/ at the pinned tag."
  else
    bad "could not read config via 'terraform console' in vms/ — the configuration itself is at fault"
  fi
  # Stop here rather than carrying on with no regions. bad() only counts a
  # failure, so without this the loops below iterate over an empty list and the
  # run prints a page of checks it never performed.
  exit 1
fi
eval "$VARS"

# A tenant that copied the new vms/variables.tf but not the pass-through line
# in vms/main.tf still reads real: `terraform console` happily resolves
# var.log_shipping to the root's own value, and that is not the value the
# module runs on. Un-wired, the module falls back to its own default (true)
# regardless of what the root says — so with log_shipping=false and the SSM
# parameter still in place, plan stays clean, the Loki grant stays live, and
# the section below would report "both say false" and skip every Loki check.
# Scoped to the module "ec2" block: the same line inside `locals` or another
# module would satisfy a file-wide grep while module "ec2" still ran its default.
awk '
  /^[[:space:]]*module[[:space:]]+"ec2"[[:space:]]*\{/ { in_ec2 = 1; next }
  in_ec2 && /^\}/                                      { in_ec2 = 0 }
  in_ec2 && /^[[:space:]]*log_shipping[[:space:]]*=[[:space:]]*var\.log_shipping/ { found = 1 }
  END { exit !found }
' "$VMS/main.tf" 2>/dev/null \
  || { bad "vms/main.tf does not pass log_shipping to module \"ec2\" — the flag preflight reads is the root's, not the module's; re-materialise vms/main.tf from the skeleton"; exit 1; }

export AWS_PROFILE="$PROFILE"
ok "profile=$PROFILE regions=$(echo "$REGIONS" | wc -w | tr -d ' ') bundles=$BUNDLE_COUNT"

aws sts get-caller-identity >/dev/null 2>&1 \
  && ok "AWS credentials for profile '$PROFILE' work" \
  || { bad "AWS credentials for profile '$PROFILE' do not work"; echo; echo "Nothing else can be checked."; exit 1; }

# ---------------------------------------------------------------------------
# The policyfile. Comment lines are stripped first: the previous matcher led
# with `.*` and read a commented-out attribute as live. Both matchers are then
# anchored at the start of the line. ERE, and `\[` / `\]` are literal brackets
# in ERE on GNU and BSD sed alike.
# ---------------------------------------------------------------------------
[ -f "$POLICYFILE" ] || { bad "no $POLICYFILE — nothing to compare the Terraform flags against"; exit 1; }
PF_CLEAN="$(sed '/^[[:space:]]*#/d' "$POLICYFILE")"
pf_attr() {
  printf '%s\n' "$PF_CLEAN" \
    | sed -nE "s/^[[:space:]]*default\['base'\]\['loki'\]\['$1'\][[:space:]]*=[[:space:]]*'([^']*)'.*/\1/p" | head -1
}
PF_ENABLED="$(printf '%s\n' "$PF_CLEAN" \
  | sed -nE "s/^[[:space:]]*default\['base'\]\['loki'\]\['enabled'\][[:space:]]*=[[:space:]]*(true|false).*/\1/p" | head -1)"
PF_PARAM="$(pf_attr ssm_parameter_name)"
LOKI_URL="$(pf_attr url)"
LOKI_USER="$(pf_attr username)"

# ---------------------------------------------------------------------------
# The switch lives on two surfaces that cannot see each other: `log_shipping`
# in tenant.auto.tfvars (the IAM grant) and base.loki.enabled in the policyfile
# (the recipe). Recipe-on / Terraform-off is the bad direction: the token
# script exits 10 every converge and Alloy keeps shipping on the last token it
# fetched, so the tenant believes shipping is off and it is not.
# ---------------------------------------------------------------------------
head_ "Log shipping flag agrees across Terraform and the policyfile"
if [ -z "$PF_ENABLED" ]; then
  PF_ENABLED=true
  ok "policyfile does not set enabled — cookbook default true applies"
fi
if [ "$LOG_SHIPPING" = "$PF_ENABLED" ]; then
  ok "both say $LOG_SHIPPING"
  SHIPPING="$LOG_SHIPPING"
else
  bad "MISMATCH — tenant.auto.tfvars log_shipping=$LOG_SHIPPING   policyfile enabled=$PF_ENABLED"
  # Carry on as if shipping were on, so the sections below show what is missing.
  SHIPPING=true
fi

# ---------------------------------------------------------------------------
# The policyfile side of the byte-for-byte match. If the recipe asks for one
# parameter name while the IAM grant names another, every VM converges green and
# ships nothing. The docs call this out explicitly.
# ---------------------------------------------------------------------------
head_ "Parameter name agrees across Terraform and the policyfile"
if [ "$SHIPPING" = false ]; then
  ok "log shipping disabled — skipped"
  for a in ssm_parameter_name url username; do
    [ -n "$(pf_attr "$a")" ] && warn "leftover: policyfile still sets loki $a — the recipe ignores it while enabled = false; delete the line"
  done
elif [ -z "$PF_PARAM" ]; then
  bad "cinc/policyfiles/dev-vm.rb has no loki ssm_parameter_name"
elif [ "$PF_PARAM" = "$LOKI_PARAM" ]; then
  ok "both name '$LOKI_PARAM'"
else
  bad "MISMATCH — tenant.auto.tfvars: '$LOKI_PARAM'   policyfile: '$PF_PARAM'"
fi
if [ "$SHIPPING" != false ]; then
  [ -n "$LOKI_URL" ]  && ok "loki url set: $LOKI_URL"        || bad "policyfile has no loki url"
  [ -n "$LOKI_USER" ] && ok "loki username set: $LOKI_USER"  || bad "policyfile has no loki username"
fi

# ---------------------------------------------------------------------------
# Hand-placed secrets, per region. Terraform never creates these, so a region
# added later — or a rotation that skipped one — is invisible until a VM there
# fails to fetch. Metadata only; no --with-decryption, so no value is read.
# ---------------------------------------------------------------------------
head_ "Per-region SSM parameters exist"
[ "$SHIPPING" = false ] && ok "log shipping disabled — skipped (loki)"
pairs="cinc:$CINC_PARAM"
[ "$SHIPPING" = false ] || pairs="loki:$LOKI_PARAM $pairs"
for R in $REGIONS; do
  # unquoted on purpose: SSM parameter names cannot contain whitespace, so
  # word-splitting is the iteration
  for pair in $pairs; do
    label="${pair%%:*}"; name="${pair#*:}"
    # SHIPPING can be forced true above (the mismatch carry-on) while
    # LOKI_PARAM is still empty — describe-parameters with an empty Name
    # filter is not "not found", it is a malformed call. Name the real cause
    # instead of making it.
    if [ -z "$name" ]; then
      bad "$R $label — MISSING (no ${label}_ssm_parameter_name in tenant.auto.tfvars)"
      continue
    fi
    TYPE="$(aws ssm describe-parameters --region "$R" \
              --parameter-filters "Key=Name,Values=$name" \
              --query 'Parameters[0].Type' --output text 2>/dev/null)"
    case "$TYPE" in
      SecureString) ok "$R $label — present, SecureString" ;;
      None|"")      bad "$R $label — MISSING ($name)" ;;
      *)            warn "$R $label — present but type is $TYPE, expected SecureString" ;;
    esac
  done
done

# ---------------------------------------------------------------------------
# Does the Loki token actually authenticate, in every region?
#
# This is the check that catches a rotation that missed a region — the one
# failure the design has no runtime detector for, since absence alerting was
# deliberately dropped (Idlefy makes a silent VM normal).
#
# An empty request body returns 400 when the credentials are good and 401 when
# they are not, so authentication is proven WITHOUT ingesting a line or creating
# a stream. The token never reaches a command line: `-u` would put it in argv
# where `ps` exposes it to any local user, so it goes through a 0600 curl config.
# ---------------------------------------------------------------------------
head_ "Loki token authenticates (nothing is ingested)"
if [ "$SHIPPING" = false ]; then
  ok "log shipping disabled — skipped"
elif [ -z "$LOKI_PARAM" ]; then
  bad "no loki_ssm_parameter_name to read the token from"
elif [ -z "$LOKI_URL" ] || [ -z "$LOKI_USER" ]; then
  warn "skipped — policyfile is missing url or username"
else
  # The trap, not just the rm below. TMPC holds the decrypted Loki token in a
  # curl config file; the two rm calls on the normal path do nothing for a ^C or
  # a killed curl, and the plaintext token then stays in TMPDIR. Set once, before
  # the loop, and cleared after it.
  TMPC=""
  # Separate traps, because one combined trap does not stop the script. With a
  # handler installed for INT, bash runs it and then carries on from the next
  # command instead of dying — so a ^C in the middle of this loop removed the
  # token file and then kept querying Loki. The signal handlers exit; the EXIT
  # handler only cleans up.
  trap 'rm -f "$TMPC"' EXIT
  trap 'rm -f "$TMPC"; exit 130' INT
  trap 'rm -f "$TMPC"; exit 143' TERM
  for R in $REGIONS; do
    umask 077
    TMPC="$(mktemp)"
    if ! aws ssm get-parameter --region "$R" --name "$LOKI_PARAM" --with-decryption \
           --query Parameter.Value --output text 2>/dev/null \
         | tr -d '\r\n' | sed "s|^|user = \"$LOKI_USER:|; s|\$|\"|" > "$TMPC" \
       || ! grep -q 'user = ' "$TMPC"; then
      bad "$R — could not fetch the token (see the previous section)"
      rm -f "$TMPC"; continue
    fi
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
              --config "$TMPC" -H 'Content-Type: application/json' \
              -X POST --data-binary '' "$LOKI_URL" 2>/dev/null)"
    rm -f "$TMPC"
    case "$CODE" in
      400)     ok   "$R — credentials accepted" ;;
      401|403) bad  "$R — REJECTED by Loki (http $CODE): wrong token, or wrong username/tenant" ;;
      000)     bad  "$R — could not reach $LOKI_URL (curl got no HTTP status). If this workstation cannot reach Loki, PREFLIGHT=skip is the documented bypass" ;;
      *)       bad  "$R — http $CODE from Loki; only 400 proves the token (an empty body is a bad request from a good credential)" ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# External policy ARNs. CLAUDE.md names this as a gap no test closes: a typo
# plans clean, applies clean, and surfaces as AccessDenied on a VM days later,
# because the ARN belongs to whoever owns the resource and is only referenced.
# ---------------------------------------------------------------------------
head_ "Access-bundle policy ARNs resolve"
if [ "$BUNDLE_COUNT" -eq 0 ]; then
  ok "no bundles defined — nothing to resolve"
else
  for A in $BUNDLE_ARNS; do
    if aws iam get-policy --policy-arn "$A" >/dev/null 2>&1; then
      ok "${A##*/}"
    else
      bad "does not resolve: $A"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Informational: where are the two policy groups relative to this working tree?
#
# A revision_id is a content hash, so two of them carry no order — "differs"
# is all a comparison of the two groups can honestly say. An earlier version of
# this check read a difference as "production is behind staging, promote
# pending". On 2026-08-05 that was backwards: production carried the committed
# lockfile and staging held an older build of one recipe, so following the
# advice would have moved the fleet backwards. The lockfile is the third point
# that gives the other two a direction, which is why it is read here.
# ---------------------------------------------------------------------------
head_ "Policy groups"
grp_rev() {
  ( cd "$ROOT/cinc" && knife raw "/policy_groups/$1" -c ./.chef/knife.rb 2>/dev/null ) \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("policies",{}).get("dev-vm",{}).get("revision_id","")[:12])
except Exception: print("")' 2>/dev/null
}
if command -v knife >/dev/null; then
  S="$(grp_rev staging)"; P="$(grp_rev production)"
  # The lockfile is rewritten by `make push`, so it names the revision the last
  # push published — the only one of the three whose provenance is knowable here.
  L="$(python3 -c 'import json;print(json.load(open("'"$ROOT"'/cinc/policyfiles/dev-vm.lock.json"))["revision_id"][:12])' 2>/dev/null)"
  if [ -z "$S$P" ]; then
    warn "could not reach the CINC server"
  elif [ "$S" = "$P" ]; then
    ok "staging and production both on $S"
    [ -n "$L" ] && [ "$L" != "$S" ] &&
      warn "...but the lockfile names $L — the working tree has not been pushed"
  elif [ -n "$L" ] && [ "$S" = "$L" ]; then
    warn "staging ($S) matches the lockfile, production ($P) does not — 'make promote' pending"
  elif [ -n "$L" ] && [ "$P" = "$L" ]; then
    warn "production ($P) matches the lockfile, staging ($S) is a stale build — 'make push' refreshes it; do NOT promote"
  else
    warn "staging ($S) and production ($P) differ and neither matches the lockfile (${L:-unreadable}) — 'make push' before promoting anything"
  fi
else
  warn "knife not on PATH — skipped"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed, %d warning(s)\033[0m\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -gt 0 ]; then
  echo "Fix the ✗ items before applying or promoting — each one is silent on a live VM."
  exit 1
fi
[ "$WARN" -gt 0 ] && echo "Warnings are not blocking, but read them."
exit 0
