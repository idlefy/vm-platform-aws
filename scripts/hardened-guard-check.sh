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
#       more public image; deprecated public images count against it;
#   G3  no IAM user or role other than the publish role and AWS service-linked
#       roles is ALLOWED any mutation of an image or snapshot tagged
#       IdlefyPublishedImage=true (IAM policy simulation, with MFA present so
#       an account's "require MFA" deny cannot mask a principal that is
#       otherwise allowed), on one resource ARN per region of the regions
#       file. Every per-resource result must be a deny. A plain implicitDeny
#       passes like explicitDeny: a principal that cannot act needs no
#       explicit deny, and attaching the deny to CloudFormation-created roles
#       makes their stacks undeletable; this check runs again on every
#       publish. An implicitDeny that names MissingContextValues fails — an
#       Allow conditioned on a key the simulation cannot supply (aws:SourceIp,
#       aws:PrincipalTag, …) is checked by hand and then given the explicit
#       deny. A failed simulation is a failure.
#       Roles under /aws-reserved/ (Identity Center) cannot be simulated
#       usefully here and are listed for a manual check;
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
# simulate VAR ARN KIND RESOURCE ACTIONS… — simulates ARN on KIND's RESOURCE
# (e.g. image/ami-0…) in every region of the regions file, at most
# SIM_BATCH resource ARNs per call, and sets VAR to the worst result:
#   explicitDeny  every action on every resource is explicitly denied;
#   implicitDeny  every one is denied, some only implicitly, with no context
#                 key missing;
#   conditional   an implicitDeny names MissingContextValues: an Allow that
#                 holds under a key the simulation did not supply (aws:SourceIp,
#                 aws:PrincipalTag, …) — a failure, to check by hand;
#   allowed / unreadable / error — failures.
# Every per-resource result (ResourceSpecificResults) must be a deny, not only
# the top-level decision: an Allow scoped to one region's ARNs shows there.
# MFA is simulated as present, so a "require MFA" deny cannot mask an allow.
# Not called in $(…): a subshell would lose the failure.
SIM_BATCH=10
simulate() {
  local var=$1 arn=$2 kind=$3 res=$4; shift 4
  local worst=explicitDeny verdict r batch=() tab=$'\t'
  rank() { case "$1" in explicitDeny) echo 0 ;; implicitDeny) echo 1 ;; conditional) echo 2 ;; allowed) echo 3 ;; *) echo 4 ;; esac; }
  local regions=($REGIONS) i
  for ((i = 0; i < ${#regions[@]}; i += SIM_BATCH)); do
    batch=()
    for r in "${regions[@]:i:SIM_BATCH}"; do batch+=("arn:aws:ec2:$r::$res"); done
    if ! awscall "$W/sim.json" "$arn: iam simulate-principal-policy ($kind)" \
           iam simulate-principal-policy --policy-source-arn "$arn" --action-names "$@" \
           --resource-arns "${batch[@]}" \
           --context-entries "ContextKeyName=ec2:ResourceTag/$FENCE_KEY,ContextKeyValues=true,ContextKeyType=string" \
                             "ContextKeyName=aws:MultiFactorAuthPresent,ContextKeyValues=true,ContextKeyType=boolean"; then
      verdict=error
    else
      verdict="$(python3 -I - "$W/sim.json" "$(IFS=,; echo "${batch[*]}")" "$@" <<'PY'
import json, sys
arns, want = sys.argv[2].split(","), sys.argv[3:]
DENY = ("explicitDeny", "implicitDeny")
bad, implicit = [], False
try:
    res = {r["EvalActionName"]: r for r in json.load(open(sys.argv[1]))["EvaluationResults"]}
    for a in want:
        r = res.get(a)
        if r is None:
            bad.append(("unreadable", "%s: no result" % a))
            continue
        per = r.get("ResourceSpecificResults")
        if not per:
            # One resource: AWS may answer at the top level only.
            if len(arns) == 1 and r.get("EvalResourceName") == arns[0]:
                per = [{"EvalResourceName": arns[0], "EvalResourceDecision": r["EvalDecision"],
                        "MissingContextValues": r.get("MissingContextValues") or []}]
            else:
                bad.append(("unreadable", "%s: no per-resource results" % a))
                continue
        seen = set()
        for p in [{"EvalResourceName": "(top level)", "EvalResourceDecision": r["EvalDecision"],
                   "MissingContextValues": r.get("MissingContextValues") or []}] + per:
            name, d = p["EvalResourceName"], p["EvalResourceDecision"]
            missing = p.get("MissingContextValues") or []
            seen.add(name)
            if d == "explicitDeny":
                continue
            if d == "implicitDeny" and not missing:
                implicit = True
                continue
            if d == "implicitDeny":
                bad.append(("conditional", "%s on %s: implicitDeny with missing context keys %s"
                            % (a, name, " ".join(missing))))
            elif d == "allowed":
                bad.append(("allowed", "%s=allowed on %s" % (a, name)))
            else:
                bad.append(("unreadable", "%s=%s on %s" % (a, d, name)))
        for x in arns:
            if x not in seen:
                bad.append(("unreadable", "%s: no result for %s" % (a, x)))
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    print("unreadable\tunreadable simulation result")
    sys.exit()
order = ["unreadable", "allowed", "conditional"]
if bad:
    worst = min((b[0] for b in bad), key=order.index)
    print("%s\t%s" % (worst, "; ".join(b[1] for b in bad)))
else:
    print("implicitDeny" if implicit else "explicitDeny")
PY
)"
      case "$verdict" in
        explicitDeny|implicitDeny) ;;
        conditional*) fail "$arn: ${verdict#*"$tab"} on a $FENCE_KEY=true $kind — an Allow under a condition the simulation cannot supply; check by hand, then attach the deny"
                      verdict=conditional ;;
        *) fail "$arn: allowed, or not readably denied, on a $FENCE_KEY=true $kind: ${verdict#*"$tab"}"
           verdict=${verdict%%"$tab"*} ;;
      esac
    fi
    [ "$(rank "$verdict")" -le "$(rank "$worst")" ] || worst=$verdict
  done
  printf -v "$var" '%s' "$worst"
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
        reserved) printf '%-72s %s\n' "$arn" "skipped: AWS-reserved (Identity Center) role — its permission set must not allow these actions; check by hand" ;;
        check)
          simulate img "$arn" image "image/$SIM_IMAGE_ID" "${IMAGE_ACTIONS[@]}"
          simulate snap "$arn" snapshot "snapshot/$SIM_SNAP_ID" "${SNAP_ACTIONS[@]}"
          printf '%-72s %-13s %s\n' "$arn" "$img" "$snap" ;;
      esac
    done < "$W/principals"
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
  } >&2
  exit 1
fi
echo "✓ hardened-guard-check: account $ACCOUNT_ID is safe to publish from ($(wc -w <<< "$REGIONS") regions)"
