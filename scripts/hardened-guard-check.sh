#!/usr/bin/env bash
# hardened-guard-check.sh — is the publishing account still safe to publish
# Idlefy's hardened image from? The publish job runs it before any build; an
# operator runs it by hand after changing the account. Read-only: it calls
# get-*, list-*, describe-* and simulate-* and nothing else.
#
#   HARDENED_CI_ROLE_ARN=arn:aws:iam::995603458290:role/<publish role> \
#     scripts/hardened-guard-check.sh
#
# Exit 0 = safe to publish. Otherwise exit 1 and every failure is listed, not
# only the first. Checks:
#   G1  the caller is in account 995603458290 — nothing else is called if not;
#   G2  every region of image/hardened/regions: EBS encryption by default is
#       off (a copy would be encrypted and could not be public), image block
#       public access is unblocked, and the region is enabled;
#   G2b SSM Default Host Management Configuration is unset in each region —
#       otherwise SSM hands the build instance a role although the build gives
#       it no instance profile (the build holds no credential);
#   G2c each region has room under the public-AMI quota (L-0E3CBAB9) for one
#       more public image; deprecated public images count against it;
#   G3  every IAM user and role other than the publish role and AWS
#       service-linked roles is explicitly denied every mutation of an image or
#       snapshot tagged IdlefyPublishedImage=true (IAM policy simulation). Roles
#       under /aws-reserved/ (Identity Center) cannot be simulated usefully
#       here and are listed for a manual check.
#
# The consumer's pinned AMI ids are the trust anchor; this deny is hygiene, and
# this guard refuses a publish when it has regressed. Prints no secret.

set -euo pipefail
export AWS_PAGER=""

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGIONS_FILE="$ROOT/image/hardened/regions"
ACCOUNT_ID=995603458290
FENCE_KEY=IdlefyPublishedImage
QUOTA_CODE=L-0E3CBAB9
DHMC_SETTING=/ssm/managed-instance/default-ec2-instance-management-role
IMAGE_ACTIONS=(ec2:DeregisterImage ec2:ModifyImageAttribute ec2:ResetImageAttribute
  ec2:EnableImageDeprecation ec2:DisableImageDeprecation ec2:DisableImage ec2:EnableImage
  ec2:CreateTags ec2:DeleteTags)
SNAP_ACTIONS=(ec2:DeleteSnapshot ec2:ModifySnapshotAttribute ec2:ResetSnapshotAttribute
  ec2:CreateTags ec2:DeleteTags)
# Simulation needs a concrete resource; the deny is keyed on the tag, not the id.
SIM_IMAGE_ID=ami-00000000000000000
SIM_SNAP_ID=snap-00000000000000000

die() { echo "✗ hardened-guard-check: $*" >&2; exit 1; }

for c in aws python3; do command -v "$c" >/dev/null || die "$c is not on PATH"; done
HARDENED_CI_ROLE_ARN="${HARDENED_CI_ROLE_ARN:-}"
[[ $HARDENED_CI_ROLE_ARN =~ ^arn:aws:iam::$ACCOUNT_ID:role/([A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]+$ ]] \
  || die "HARDENED_CI_ROLE_ARN='$HARDENED_CI_ROLE_ARN' is not a role ARN in account $ACCOUNT_ID — set it to the publish role"

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
    [ "$bpa" = unblocked ] \
      || fail "$r: image block public access is '$bpa' (block-new-sharing refuses a public image) — set it to unblocked in $r"
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
  quota="" count=""
  if aws service-quotas get-service-quota --service-code ec2 --quota-code "$QUOTA_CODE" --region "$r" \
       --output json > "$W/quota.json" 2> "$W/err" < /dev/null \
     || awscall "$W/quota.json" "$r: service-quotas get-service-quota / get-aws-default-service-quota $QUOTA_CODE" \
          service-quotas get-aws-default-service-quota --service-code ec2 --quota-code "$QUOTA_CODE" --region "$r"; then
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
# simulate VAR ARN KIND RESOURCE ACTIONS… — sets VAR to the decision summary of
# one simulation; records a failure unless every action is explicitDeny. Not
# called in $(…): a subshell would lose the failure.
simulate() {
  local var=$1 arn=$2 kind=$3 res=$4; shift 4
  if ! awscall "$W/sim.json" "$arn: iam simulate-principal-policy ($kind)" \
         iam simulate-principal-policy --policy-source-arn "$arn" --action-names "$@" \
         --resource-arns "$res" \
         --context-entries "ContextKeyName=ec2:ResourceTag/$FENCE_KEY,ContextKeyValues=true,ContextKeyType=string"; then
    printf -v "$var" '%s' error; return
  fi
  local verdict
  verdict="$(python3 -I - "$W/sim.json" "$@" <<'PY'
import json, sys
want = sys.argv[2:]
try:
    res = json.load(open(sys.argv[1]))["EvaluationResults"]
    got = {r["EvalActionName"]: r["EvalDecision"] for r in res}
except (OSError, ValueError, KeyError, TypeError):
    print("FAIL unreadable simulation result")
    sys.exit()
bad = ["%s=%s" % (a, got.get(a, "missing")) for a in want if got.get(a) != "explicitDeny"]
print("FAIL " + " ".join(bad) if bad else "explicitDeny")
PY
)"
  if [ "$verdict" = explicitDeny ]; then printf -v "$var" '%s' explicitDeny; return; fi
  fail "$arn: not explicitly denied on a $FENCE_KEY=true $kind: ${verdict#FAIL }"
  case "$verdict" in
    *=allowed*) printf -v "$var" '%s' allowed ;;
    *implicitDeny*) printf -v "$var" '%s' implicitDeny ;;
    *) printf -v "$var" '%s' unreadable ;;
  esac
}

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
    printf '%-72s %-13s %s\n' PRINCIPAL IMAGE SNAPSHOT
    while read -r what arn; do
      case "$what" in
        ci) printf '%-72s %s\n' "$arn" "publish role — not checked" ;;
        missing) fail "$arn: the publish role HARDENED_CI_ROLE_ARN names does not exist in this account" ;;
        reserved) printf '%-72s %s\n' "$arn" "skipped: AWS-reserved (Identity Center) role — its permission set must carry the deny; check by hand" ;;
        check)
          simulate img "$arn" image "arn:aws:ec2:$BUILD_REGION::image/$SIM_IMAGE_ID" "${IMAGE_ACTIONS[@]}"
          simulate snap "$arn" snapshot "arn:aws:ec2:$BUILD_REGION::snapshot/$SIM_SNAP_ID" "${SNAP_ACTIONS[@]}"
          printf '%-72s %-13s %s\n' "$arn" "$img" "$snap" ;;
      esac
    done < "$W/principals"
  else
    fail "iam list-roles / list-users returned something unreadable"
  fi
fi
echo

# ---- verdict -----------------------------------------------------------------------
if [ ${#FAILS[@]} -gt 0 ]; then
  n=${#FAILS[@]}
  [ "$n" -eq 1 ] && word=failure || word=failures
  {
    echo "✗ hardened-guard-check: $n $word — do not publish from this account until they are fixed:"
    printf '  - %s\n' "${FAILS[@]}"
  } >&2
  exit 1
fi
echo "✓ hardened-guard-check: account $ACCOUNT_ID is safe to publish from ($(wc -w <<< "$REGIONS") regions)"
