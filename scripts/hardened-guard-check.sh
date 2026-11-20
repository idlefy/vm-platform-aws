#!/usr/bin/env bash
# hardened-guard-check.sh — is the publishing account still safe to publish
# Idlefy's hardened image from? The publish job runs it before any build; an
# operator runs it by hand after changing the account. Read-only: it calls
# get-*, list-*, describe-* and simulate-* and nothing else.
#
#   HARDENED_CI_ROLE_ARN=arn:aws:iam::995603458290:role/<publish role> \
#   [HARDENED_PUBLIC=true|false] scripts/hardened-guard-check.sh
#
# HARDENED_PUBLIC (default true; anything but true or false is refused) says
# whether the build about to run is public; it decides one check of G2.
#
# Exit 0 = safe to publish. Otherwise exit 1 and every failure is listed, not
# only the first. Checks:
#   G1  the caller is in account 995603458290 — nothing else is called if not;
#   G2  every region of image/hardened/regions: EBS encryption by default is
#       off (a copy would be encrypted and could not be public), the region is
#       enabled, and — for a public build only — image block public access is
#       unblocked. With HARDENED_PUBLIC=false that one check is skipped: block
#       public access may stay on for a private build, and then nothing can
#       become public even by a bug;
#   G2b SSM Default Host Management Configuration is unset in each region —
#       otherwise SSM hands the build instance a role although the build gives
#       it no instance profile (the build holds no credential);
#   G2c each region has room under the public-AMI quota (L-0E3CBAB9) for one
#       more public image; deprecated public images count against it. Only
#       NoSuchResourceException (no applied value) falls back to the AWS
#       default quota; any other failed read is a failure;
#   G3  every IAM user and role other than the publish role and AWS
#       service-linked (/aws-service-role/) roles is EXPLICITLY denied every
#       mutation of an image or snapshot tagged IdlefyPublishedImage=true:
#       every simulated decision — top level and per resource, every fenced
#       action, one resource ARN per region — is explicitDeny, and the deny
#       policy itself ($HARDENED_DENY_POLICY_NAME, default
#       deny-idlefy-published-image-mutation) is among its matched statements;
#       a deny from another policy fails. implicitDeny
#       fails like allowed: simulation cannot decide a conditional Allow, so
#       the only decidable rule is that each principal carries the deny
#       policy, which the account's Terraform attaches to every principal.
#       MFA is simulated present, so a "require MFA" deny cannot stand in for
#       the missing fence deny. A missing or short answer, or a failed
#       simulation, fails. One line per failing principal; passing ones are
#       counted. Roles under /aws-reserved/ (Identity Center) cannot be
#       simulated usefully here and are listed for a manual check;
#   G4  every region of image/hardened/regions holds no unencrypted snapshot
#       and no image with an unencrypted snapshot that this account owns and
#       that is not tagged IdlefyPublishedImage=true. The publisher role can
#       copy images inside the account, and an unencrypted private disk is
#       the only thing a compromised run could make public; while none
#       exists, nothing can leak. Each offender is named with its region.
#
# The consumer's pinned AMI ids are the trust anchor; this deny is hygiene, and
# this guard refuses a publish when it has regressed. Prints no secret.
# A read that is denied or unreadable is a failure, never a pass.
# Design: docs/design/hardened-image.md.

set -euo pipefail
export AWS_PAGER=""

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGIONS_FILE="$ROOT/image/hardened/regions"
ACCOUNT_ID=995603458290
FENCE_KEY=IdlefyPublishedImage
# The managed policy that carries the fence deny. In a simulation result its
# statements are matched by SourcePolicyId, which for an attached managed
# policy is the policy's name.
DENY_POLICY="${HARDENED_DENY_POLICY_NAME:-deny-idlefy-published-image-mutation}"
QUOTA_CODE=L-0E3CBAB9
DHMC_SETTING=/ssm/managed-instance/default-ec2-instance-management-role
IMAGE_ACTIONS=(ec2:DeregisterImage ec2:ModifyImageAttribute ec2:ResetImageAttribute
  ec2:EnableImageDeprecation ec2:DisableImageDeprecation ec2:DisableImage ec2:EnableImage
  ec2:CreateTags ec2:DeleteTags
  ec2:EnableImageDeregistrationProtection ec2:DisableImageDeregistrationProtection
  ec2:AttachImageWatermark ec2:DetachImageWatermark ec2:ReplaceImageInstanceTypeSpecification)
SNAP_ACTIONS=(ec2:DeleteSnapshot ec2:ModifySnapshotAttribute ec2:ResetSnapshotAttribute
  ec2:CreateTags ec2:DeleteTags ec2:LockSnapshot ec2:UnlockSnapshot ec2:ModifySnapshotTier)
# Simulation needs a concrete resource; the deny is keyed on the tag, not the id.
SIM_IMAGE_ID=ami-00000000000000000
SIM_SNAP_ID=snap-00000000000000000

die() { echo "✗ hardened-guard-check: $*" >&2; exit 1; }

for c in aws python3; do command -v "$c" >/dev/null || die "$c is not on PATH"; done
HARDENED_CI_ROLE_ARN="${HARDENED_CI_ROLE_ARN:-}"
[[ $HARDENED_CI_ROLE_ARN =~ ^arn:aws:iam::$ACCOUNT_ID:role/([A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]+$ ]] \
  || die "HARDENED_CI_ROLE_ARN='$HARDENED_CI_ROLE_ARN' is not a role ARN in account $ACCOUNT_ID — set it to the publish role"
HARDENED_PUBLIC="${HARDENED_PUBLIC-true}"
[[ $HARDENED_PUBLIC =~ ^(true|false)$ ]] \
  || die "HARDENED_PUBLIC='$HARDENED_PUBLIC' must be true or false (unset means true)"

TMPS=()
# shellcheck disable=SC2317  # reached only through the traps below
cleanup() { [ ${#TMPS[@]} -eq 0 ] || rm -rf "${TMPS[@]}"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
W="$(mktemp -d)"; TMPS+=("$W")

# ---- regions -------------------------------------------------------------------
# The same parse as scripts/hardened-image-build.sh: '#' lines and blank lines
# are comments; every other line is exactly a region, none repeated.
REGIONS="$(python3 -I - "$REGIONS_FILE" <<'PY'
import re, sys
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError as e:
    sys.exit("cannot read %s: %s" % (sys.argv[1], e.strerror))
regions = []
for n, line in enumerate(lines, 1):
    if line.strip() == "" or line.lstrip().startswith("#"):
        continue
    if not re.fullmatch(r"[a-z]{2}-[a-z]+-[0-9]", line):
        sys.exit("line %d is not a region: %r" % (n, line))
    if line in regions:
        sys.exit("line %d repeats %s" % (n, line))
    regions.append(line)
if not regions:
    sys.exit("it lists no region")
print(" ".join(regions))
PY
)" || die "image/hardened/regions: see above — fix the file"
read -r BUILD_REGION _ <<< "$REGIONS"

FAILS=()
fail() { FAILS+=("$*"); }

# awscall OUT DESC aws-args… — runs aws with --output json into OUT. On failure
# records DESC with the first line AWS printed (an error message, never a
# credential) and returns 1.
awscall() {
  local out=$1 desc=$2; shift 2
  if aws "$@" --output json > "$out" 2> "$W/err" < /dev/null; then return 0; fi
  fail "$desc: the call failed: $(head -n1 "$W/err")"
  return 1
}
# jfield FILE KEY… — the value at that key path of a JSON file; a last key of
# '#len' gives a list's length, '#int' a number as an integer. Booleans print as
# true/false. Fails, printing nothing, when the path is not there.
jfield() {
  python3 -I - "$@" 2>/dev/null <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    if k == "#len":
        v = len(v)
    elif k == "#int":
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != int(v):
            sys.exit(1)
        v = int(v)
    else:
        v = v[k]
if v is None or isinstance(v, (dict, list)):
    sys.exit(1)
print(json.dumps(v) if isinstance(v, bool) else v)
PY
}

# ---- G1 the account --------------------------------------------------------------
awscall "$W/id.json" "sts get-caller-identity" sts get-caller-identity \
  || die "${FAILS[0]} — refusing before any region is checked"
acct="$(jfield "$W/id.json" Account)" || die "sts get-caller-identity returned no Account — refusing before any region is checked"
[ "$acct" = "$ACCOUNT_ID" ] \
  || die "these credentials are for account $acct, not $ACCOUNT_ID — refusing before any region is checked"
echo "Account $ACCOUNT_ID"
if [ "$HARDENED_PUBLIC" = false ]; then
  echo "Private build (HARDENED_PUBLIC=false): image block public access is not checked and may stay on."
fi
echo

# ---- G2 the regions --------------------------------------------------------------
printf '%-16s %-11s %-18s %-20s %-8s %s\n' REGION ENCRYPTION BLOCK-PUBLIC OPT-IN DHMC PUBLIC-AMIS
for r in $REGIONS; do
  enc="?" bpa="?" opt="?" dhmc="?" quota_col="?"
  if awscall "$W/enc.json" "$r: ec2 get-ebs-encryption-by-default" ec2 get-ebs-encryption-by-default --region "$r"; then
    enc="$(jfield "$W/enc.json" EbsEncryptionByDefault)" || enc="?"
    case "$enc" in
      false) ;;
      true) fail "$r: EBS encryption-by-default is on — the copy there would be encrypted and cannot be public; turn it off in $r" ;;
      *) enc="?"; fail "$r: get-ebs-encryption-by-default returned no EbsEncryptionByDefault" ;;
    esac
  fi
  if awscall "$W/bpa.json" "$r: ec2 get-image-block-public-access-state" ec2 get-image-block-public-access-state --region "$r"; then
    bpa="$(jfield "$W/bpa.json" ImageBlockPublicAccessState)" || bpa="?"
    # Only a public build needs it lifted; a private one is safer with it on.
    if [ "$HARDENED_PUBLIC" = true ]; then
      [ "$bpa" = unblocked ] \
        || fail "$r: image block public access is '$bpa' (block-new-sharing refuses a public image) — set it to unblocked in $r"
    fi
  fi
  if awscall "$W/opt.json" "$r: account get-region-opt-status" account get-region-opt-status --region-name "$r"; then
    opt="$(jfield "$W/opt.json" RegionOptStatus)" || opt="?"
    [[ $opt =~ ^(ENABLED|ENABLED_BY_DEFAULT)$ ]] \
      || fail "$r: the region's opt-in status is '$opt', not ENABLED or ENABLED_BY_DEFAULT — enable it or drop it from image/hardened/regions"
  fi
  if awscall "$W/dhmc.json" "$r: ssm get-service-setting $DHMC_SETTING" \
       ssm get-service-setting --setting-id "$DHMC_SETTING" --region "$r"; then
    if dhmc="$(jfield "$W/dhmc.json" ServiceSetting SettingValue)"; then
      if [ -z "$dhmc" ] || [ "$dhmc" = '$None' ]; then dhmc=unset
      else
        fail "$r: SSM Default Host Management Configuration is set (default-ec2-instance-management-role = $dhmc) — it would give the build instance a role; reset it in $r"
        dhmc=SET
      fi
    else
      dhmc="?"; fail "$r: ssm get-service-setting returned no SettingValue"
    fi
  fi
  # G2c. GetServiceQuota has no applied value for a quota nobody raised; the
  # AWS default is then the quota.
  # Only NoSuchResourceException means "no applied value"; any other failure
  # (AccessDenied, throttling) is a failure, never a reason to fall back.
  quota="" count="" qok=0
  if aws service-quotas get-service-quota --service-code ec2 --quota-code "$QUOTA_CODE" --region "$r" \
       --output json > "$W/quota.json" 2> "$W/err" < /dev/null; then
    qok=1
  elif grep -q 'NoSuchResourceException' "$W/err"; then
    awscall "$W/quota.json" "$r: service-quotas get-aws-default-service-quota $QUOTA_CODE" \
      service-quotas get-aws-default-service-quota --service-code ec2 --quota-code "$QUOTA_CODE" --region "$r" \
      && qok=1
  else
    fail "$r: service-quotas get-service-quota $QUOTA_CODE: the call failed: $(head -n1 "$W/err")"
  fi
  if [ "$qok" = 1 ]; then
    quota="$(jfield "$W/quota.json" Quota Value '#int')" \
      || { quota=""; fail "$r: the public AMI quota $QUOTA_CODE came back without a whole Value"; }
  fi
  if awscall "$W/pub.json" "$r: ec2 describe-images (public images of this account)" \
       ec2 describe-images --region "$r" --owners self --include-deprecated --filters Name=is-public,Values=true; then
    count="$(jfield "$W/pub.json" Images '#len')" \
      || { count=""; fail "$r: describe-images returned no Images list"; }
  fi
  if [ -n "$quota" ] && [ -n "$count" ]; then
    quota_col="$count/$quota"
    [ $((quota - count)) -ge 1 ] \
      || fail "$r: public AMI quota $QUOTA_CODE is $quota and $count public images exist (deprecated ones count) — a new public build would exceed it; retire one or raise the quota"
  fi
  printf '%-16s %-11s %-18s %-20s %-8s %s\n' "$r" "$enc" "$bpa" "$opt" "$dhmc" "$quota_col"
done
echo

# ---- G3 the deny ---------------------------------------------------------------------
# A principal passes only when EVERY simulated decision is explicitDeny: the
# top level and every per-resource result, for every fenced action, on one
# resource ARN per region. implicitDeny fails like allowed — simulation
# cannot decide a conditional Allow (MissingContextValues names every
# condition key anywhere in a principal's policies, related or not), so the
# only decidable rule is that every principal but the publish role and
# service-linked roles carries the deny policy itself.
#
# "explicitDeny" counts only when $DENY_POLICY is among the decision's
# MatchedStatements (SourcePolicyId): a deny from any other policy (an SCP-like
# boundary, a stray inline deny) can be removed without touching the fence and
# fails as "explicitDeny (other policy)".
#
# The context says MFA is present on purpose: an account's "require MFA"
# deny would otherwise read as explicitDeny and hide a principal that lacks
# the fence deny. With MFA present only the fence deny can produce it.
#
# simulate ARN KIND RESOURCE ACTIONS… — simulates ARN on KIND's RESOURCE (e.g.
# image/ami-0…) in every region, at most SIM_BATCH resource ARNs per call, and
# appends one "<decision>\t<action>@<region>" line to $W/bad for every
# decision that is not explicitDeny: allowed, implicitDeny, unreadable (a
# missing or short answer) or error (a failed call — every action × resource
# of that call). Not called in $(…): the file is the result.
SIM_BATCH=10
simulate() {
  local arn=$1 kind=$2 res=$3; shift 3
  local r a i batch=()
  local regions=($REGIONS)
  for ((i = 0; i < ${#regions[@]}; i += SIM_BATCH)); do
    batch=()
    for r in "${regions[@]:i:SIM_BATCH}"; do batch+=("arn:aws:ec2:$r::$res"); done
    if ! aws iam simulate-principal-policy --policy-source-arn "$arn" --action-names "$@" \
           --resource-arns "${batch[@]}" \
           --context-entries "ContextKeyName=ec2:ResourceTag/$FENCE_KEY,ContextKeyValues=true,ContextKeyType=string" \
                             "ContextKeyName=aws:MultiFactorAuthPresent,ContextKeyValues=true,ContextKeyType=boolean" \
           --output json > "$W/sim.json" 2> "$W/err" < /dev/null; then
      for a in "$@"; do
        for r in "${regions[@]:i:SIM_BATCH}"; do printf 'error\t%s@%s\n' "$a" "$r" >> "$W/bad"; done
      done
      SIM_ERRORS+=("$arn ($kind): $(head -n1 "$W/err")")
      continue
    fi
    python3 -I - "$W/sim.json" "$DENY_POLICY" "$(IFS=,; echo "${batch[*]}")" "$@" >> "$W/bad" <<'PY'
import json, sys
fence, arns, want = sys.argv[2], sys.argv[3].split(","), sys.argv[4:]
def region(arn):
    parts = arn.split(":")
    return parts[3] if len(parts) > 3 and parts[3] else "all"
# verdict(decision, matched) — None when the decision is an explicitDeny that
# the fence policy itself matched; otherwise what to report.
def verdict(d, matched):
    if d in ("allowed", "implicitDeny"):
        return d
    if d != "explicitDeny":
        return "unreadable"
    ids = [m.get("SourcePolicyId") for m in (matched or []) if isinstance(m, dict)]
    return None if fence in ids else "explicitDeny (other policy)"
try:
    res = {r["EvalActionName"]: r for r in json.load(open(sys.argv[1]))["EvaluationResults"]}
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    res = {}
for a in want:
    r = res.get(a)
    if not isinstance(r, dict):
        for x in arns:
            print("unreadable\t%s@%s" % (a, region(x)))
        continue
    per = r.get("ResourceSpecificResults") or []
    if not per and len(arns) == 1 and r.get("EvalResourceName") == arns[0]:
        per = [{"EvalResourceName": arns[0], "EvalResourceDecision": r.get("EvalDecision"),
                "MatchedStatements": r.get("MatchedStatements")}]
    got = {}
    for p in per:
        if isinstance(p, dict):
            got[p.get("EvalResourceName")] = verdict(p.get("EvalResourceDecision"), p.get("MatchedStatements"))
    for x in arns:
        if x not in got:
            print("unreadable\t%s@%s" % (a, region(x)))
        elif got[x] is not None:
            print("%s\t%s@%s" % (got[x], a, region(x)))
    top = verdict(r.get("EvalDecision"), r.get("MatchedStatements"))
    if top is not None and all(x in got and got[x] is None for x in arns):
        print("%s\t%s@all" % (top, a))
PY
  done
}

# summarize ARN TOTAL — one line for a principal whose $W/bad is not empty.
summarize() {
  python3 -I - "$W/bad" "$1" "$2" <<'PY'
import sys
lines = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1]) if "\t" in l]
order = ["allowed", "implicitDeny", "explicitDeny (other policy)", "error", "unreadable"]
worst = min((d for d, _ in lines), key=lambda d: order.index(d) if d in order else len(order))
examples = []
for d, where in lines:
    if d == worst and where not in examples:
        examples.append(where)
    if len(examples) == 3:
        break
print("%s: %d of %s decisions not explicitDeny (worst: %s), e.g. %s"
      % (sys.argv[2], len(lines), sys.argv[3], worst, ", ".join(examples)))
PY
}

G3_PASS=0 G3_FAIL=0 SIM_ERRORS=()
nregions=$(wc -w <<< "$REGIONS")
total=$(( (${#IMAGE_ACTIONS[@]} + ${#SNAP_ACTIONS[@]}) * nregions ))
principals_ok=1
awscall "$W/roles.json" "iam list-roles" iam list-roles || principals_ok=0
awscall "$W/users.json" "iam list-users" iam list-users || principals_ok=0
if [ "$principals_ok" = 1 ]; then
  if python3 -I - "$W/roles.json" "$W/users.json" "$HARDENED_CI_ROLE_ARN" > "$W/principals" <<'PY'
import json, sys
roles = json.load(open(sys.argv[1]))["Roles"]
users = json.load(open(sys.argv[2]))["Users"]
ci = sys.argv[3]
found = False
for p in roles + users:
    arn, path = p["Arn"], p.get("Path", "/")
    if arn == ci:
        found = True
        print("ci", arn)
    elif path.startswith("/aws-service-role/"):
        continue
    elif path.startswith("/aws-reserved/"):
        print("reserved", arn)
    else:
        print("check", arn)
if not found:
    print("missing", ci)
PY
  then
    while read -r what arn; do
      case "$what" in
        ci) echo "publish role $arn — not checked" ;;
        missing) fail "$arn: the publish role HARDENED_CI_ROLE_ARN names does not exist in this account" ;;
        reserved) echo "skipped: $arn — AWS-reserved (Identity Center) role; its permission set must carry the deny; check by hand" ;;
        check)
          : > "$W/bad"
          simulate "$arn" image "image/$SIM_IMAGE_ID" "${IMAGE_ACTIONS[@]}"
          simulate "$arn" snapshot "snapshot/$SIM_SNAP_ID" "${SNAP_ACTIONS[@]}"
          if [ -s "$W/bad" ]; then
            G3_FAIL=$((G3_FAIL + 1))
            fail "$(summarize "$arn" "$total")"
          else
            G3_PASS=$((G3_PASS + 1))
          fi ;;
      esac
    done < "$W/principals"
    echo "G3: $G3_PASS principals carry the deny everywhere; $G3_FAIL do not ($total decisions each)"
    for e in "${SIM_ERRORS[@]}"; do echo "   simulation failed: $e"; done
  else
    fail "iam list-roles / list-users returned something unreadable"
  fi
fi
echo

# ---- G4 no other unencrypted disk ---------------------------------------------------
# strays SNAPS IMAGES — one "snapshot <id>" / "image <id>" line per self-owned
# unencrypted disk without the fence tag; exit 1 on an answer it cannot read.
strays() {
  python3 -I - "$1" "$2" "$FENCE_KEY" <<'PY'
import json, sys
fence = sys.argv[3]
def fenced(o):
    return any(isinstance(t, dict) and t.get("Key") == fence and t.get("Value") == "true"
               for t in (o.get("Tags") or []))
try:
    snaps = json.load(open(sys.argv[1]))["Snapshots"]
    images = json.load(open(sys.argv[2]))["Images"]
    for s in snaps:
        if not isinstance(s["Encrypted"], bool):
            raise TypeError
        if not s["Encrypted"] and not fenced(s):
            print("snapshot", s["SnapshotId"])
    for i in images:
        plain = [m["Ebs"]["Encrypted"] is False for m in i.get("BlockDeviceMappings") or [] if "Ebs" in m]
        if any(plain) and not fenced(i):
            print("image", i["ImageId"])
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
}
printf '%-16s %s\n' REGION UNENCRYPTED-UNFENCED
for r in $REGIONS; do
  col="?"
  if awscall "$W/snaps.json" "$r: ec2 describe-snapshots (unencrypted, this account)" \
       ec2 describe-snapshots --region "$r" --owner-ids self --filters Name=encrypted,Values=false \
     && awscall "$W/own.json" "$r: ec2 describe-images (this account)" \
       ec2 describe-images --region "$r" --owners self --include-deprecated --include-disabled; then
    if strays "$W/snaps.json" "$W/own.json" > "$W/strays"; then
      col=$(wc -l < "$W/strays")
      while read -r kind id; do
        fail "$r: $kind $id is unencrypted and not tagged $FENCE_KEY=true — a compromised run could make it public; encrypt or delete it"
      done < "$W/strays"
    else
      fail "$r: describe-snapshots / describe-images returned something unreadable"
    fi
  fi
  printf '%-16s %s\n' "$r" "$col"
done
echo

# ---- verdict -----------------------------------------------------------------------
if [ ${#FAILS[@]} -gt 0 ]; then
  n=${#FAILS[@]}
  [ "$n" -eq 1 ] && word=failure || word=failures
  {
    echo "✗ hardened-guard-check: $n $word — do not publish from this account until they are fixed:"
    printf '  - %s\n' "${FAILS[@]}"
    if [ "${G3_FAIL:-0}" -gt 0 ]; then
      echo "attach $DENY_POLICY to these principals (terraform apply in idlefy/infra, terraform/aws/account)"
    fi
  } >&2
  exit 1
fi
echo "✓ hardened-guard-check: account $ACCOUNT_ID is safe to publish from ($(wc -w <<< "$REGIONS") regions)"
