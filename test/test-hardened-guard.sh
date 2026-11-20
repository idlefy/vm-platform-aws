#!/usr/bin/env bash
# scripts/hardened-guard-check.sh against a shimmed `aws`. Nothing here touches
# AWS. The shim answers from the environment and logs every call:
#   sts get-caller-identity                 Account ${GUARD_ACCOUNT:-995603458290}
#   ec2 get-ebs-encryption-by-default       true iff the region is in $ENC_ON
#   ec2 get-image-block-public-access-state block-new-sharing iff in $BPA_ON
#   account get-region-opt-status           ${OPT_STATUS:-ENABLED_BY_DEFAULT}
#   ssm get-service-setting                 SettingValue ${SSM_DHMC:-$None}
#   service-quotas get-service-quota        ${QUOTA:-5}; fails when $QUOTA_APPLIED_MISSING
#   service-quotas get-aws-default-service-quota  ${DEFAULT_QUOTA:-5}
#   ec2 describe-images (public, self)      ${PUBLIC_COUNT:-1} images
#   iam list-roles / list-users             the CI role, a service-linked role,
#                                           an Identity Center role,
#                                           github-cfn-publish; user aleksei
#   iam simulate-principal-policy           explicitDeny for every action, except
#                                           implicitDeny for names in $LEAKY
# Any call whose "service verb" is in $FAIL_CALL exits 254.

# The checks read `[ … ]; echo $?` and `run_guard; check … "$?"` on purpose.
# shellcheck disable=SC2181,SC2319

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/r"
mkdir -p "$T/bin" "$R/scripts" "$R/image/hardened"
cp "$ROOT/scripts/hardened-guard-check.sh" "$R/scripts/" 2>/dev/null
printf '# Regions, one per line; the first is the build region.\n\nus-east-1\neu-central-1\n' > "$R/image/hardened/regions"

ACCT=995603458290
CI_ROLE="arn:aws:iam::$ACCT:role/github-hardened-image-publish"
IMAGE_ACTIONS="ec2:DeregisterImage ec2:ModifyImageAttribute ec2:ResetImageAttribute ec2:EnableImageDeprecation ec2:DisableImageDeprecation ec2:DisableImage ec2:EnableImage ec2:CreateTags ec2:DeleteTags"
SNAP_ACTIONS="ec2:DeleteSnapshot ec2:ModifySnapshotAttribute ec2:ResetSnapshotAttribute ec2:CreateTags ec2:DeleteTags"

cat > "$T/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$AWS_LOG"
region=""; a=("$@")
for ((i = 0; i < ${#a[@]}; i++)); do
  case "${a[i]}" in --region|--region-name) region=${a[i+1]} ;; esac
done
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
if in_list "$1:$2" "${FAIL_CALL:-}"; then echo "An error occurred (AccessDenied) when calling $2" >&2; exit 254; fi
case "$1 $2" in
  "sts get-caller-identity")
    printf '{"UserId":"AIDAEXAMPLE","Account":"%s","Arn":"arn:aws:iam::%s:user/aleksei"}\n' \
      "${GUARD_ACCOUNT:-995603458290}" "${GUARD_ACCOUNT:-995603458290}" ;;
  "ec2 get-ebs-encryption-by-default")
    if in_list "$region" "${ENC_ON:-}"; then v=true; else v=false; fi
    printf '{"EbsEncryptionByDefault": %s, "SseType": "sse-ebs"}\n' "$v" ;;
  "ec2 get-image-block-public-access-state")
    if in_list "$region" "${BPA_ON:-}"; then v=block-new-sharing; else v=unblocked; fi
    printf '{"ImageBlockPublicAccessState": "%s"}\n' "$v" ;;
  "account get-region-opt-status")
    printf '{"RegionName": "%s", "RegionOptStatus": "%s"}\n' "$region" "${OPT_STATUS:-ENABLED_BY_DEFAULT}" ;;
  "ssm get-service-setting")
    printf '{"ServiceSetting": {"SettingId": "/ssm/managed-instance/default-ec2-instance-management-role", "SettingValue": "%s", "Status": "Default"}}\n' \
      "${SSM_DHMC-\$None}" ;;
  "service-quotas get-service-quota")
    if [ -n "${QUOTA_APPLIED_MISSING:-}" ]; then echo "An error occurred (NoSuchResourceException)" >&2; exit 254; fi
    printf '{"Quota": {"QuotaCode": "L-0E3CBAB9", "Value": %s.0}}\n' "${QUOTA:-5}" ;;
  "service-quotas get-aws-default-service-quota")
    printf '{"Quota": {"QuotaCode": "L-0E3CBAB9", "Value": %s.0}}\n' "${DEFAULT_QUOTA:-5}" ;;
  "ec2 describe-images")
    python3 -I -c 'import json, sys
n = int(sys.argv[1])
print(json.dumps({"Images": [{"ImageId": "ami-%017x" % i, "Public": True} for i in range(n)]}))' "${PUBLIC_COUNT:-1}" ;;
  "iam list-roles")
    cat <<JSON
{"Roles": [
  {"Path": "/", "RoleName": "github-hardened-image-publish", "Arn": "arn:aws:iam::995603458290:role/github-hardened-image-publish"},
  {"Path": "/aws-service-role/support.amazonaws.com/", "RoleName": "AWSServiceRoleForSupport", "Arn": "arn:aws:iam::995603458290:role/aws-service-role/support.amazonaws.com/AWSServiceRoleForSupport"},
  {"Path": "/aws-reserved/sso.amazonaws.com/", "RoleName": "AWSReservedSSO_Admin_abc", "Arn": "arn:aws:iam::995603458290:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Admin_abc"},
  {"Path": "/", "RoleName": "github-cfn-publish", "Arn": "arn:aws:iam::995603458290:role/github-cfn-publish"}
]}
JSON
    ;;
  "iam list-users")
    printf '{"Users": [{"Path": "/", "UserName": "aleksei", "Arn": "arn:aws:iam::995603458290:user/aleksei"}]}\n' ;;
  "iam simulate-principal-policy")
    src=""; actions=(); mode=""
    for x in "$@"; do
      case "$x" in
        --policy-source-arn) mode=src ;;
        --action-names) mode=act ;;
        --*) mode="" ;;
        *) case "$mode" in src) src=$x; mode="" ;; act) actions+=("$x") ;; esac ;;
      esac
    done
    if in_list "${src##*/}" "${LEAKY:-}"; then d=implicitDeny; else d=explicitDeny; fi
    python3 -I -c 'import json, sys
d = sys.argv[1]
print(json.dumps({"EvaluationResults": [{"EvalActionName": a, "EvalDecision": d} for a in sys.argv[2:]]}))' "$d" "${actions[@]}" ;;
  *) echo "shim: unexpected aws $*" >&2; exit 9 ;;
esac
SH
chmod +x "$T/bin/aws"

# run_guard — runs the guard with the shim; returns its status.
run_guard() {
  : > "$T/aws.log"
  local e=(PATH="$T/bin:$PATH" AWS_LOG="$T/aws.log")
  [ -n "${NO_CI_ROLE:-}" ] || e+=(HARDENED_CI_ROLE_ARN="${CI_ROLE_ARN:-$CI_ROLE}")
  ( cd "$T" && env -u HARDENED_CI_ROLE_ARN "${e[@]}" "$R/scripts/hardened-guard-check.sh" > "$T/stdout" 2> "$T/stderr" )
}
out() { cat "$T/stdout" "$T/stderr"; }
has() { out | grep -qF -- "$1"; }
calls() { grep -cF -- "$1" "$T/aws.log"; }
# sim_actions ARN KIND — the action list the guard simulated for ARN on KIND (image|snapshot).
sim_actions() {
  grep -F -- "--policy-source-arn $1 " "$T/aws.log" | grep -F -- "::$2/" \
    | sed -e 's/.*--action-names //' -e 's/ --.*//'
}

echo "== everything in order → safe to publish =="
run_guard; check "exit 0" "$?"
for p in user/aleksei role/github-cfn-publish; do
  check "lists $p with explicitDeny" "$(grep -F "arn:aws:iam::$ACCT:$p" "$T/stdout" | grep -q 'explicitDeny'; echo $?)"
done
check "the service-linked role is never simulated" "$([ "$(calls 'AWSServiceRoleForSupport')" = 0 ]; echo $?)"
check "the CI role is never simulated" "$(grep -qF -- "--policy-source-arn $CI_ROLE" "$T/aws.log"; [ $? -ne 0 ]; echo $?)"
check "the Identity Center role is never simulated" "$(grep -qF -- 'AWSReservedSSO_Admin_abc' "$T/aws.log"; [ $? -ne 0 ]; echo $?)"
check "…but it is reported as skipped, by name, for a manual check" \
  "$(grep -F 'AWSReservedSSO_Admin_abc' "$T/stdout" | grep -qF 'skipped: AWS-reserved (Identity Center) role — its permission set must carry the deny; check by hand'; echo $?)"
for p in "user/aleksei" "role/github-cfn-publish"; do
  check "$p: the image actions are exactly the nine" "$([ "$(sim_actions "arn:aws:iam::$ACCT:$p" image)" = "$IMAGE_ACTIONS" ]; echo $?)"
  check "$p: the snapshot actions are exactly the five" "$([ "$(sim_actions "arn:aws:iam::$ACCT:$p" snapshot)" = "$SNAP_ACTIONS" ]; echo $?)"
done
check "two simulations per principal, four in all" "$([ "$(calls 'iam simulate-principal-policy')" = 4 ]; echo $?)"
check "every simulation carries the fence-tag context" \
  "$([ "$(grep -F 'simulate-principal-policy' "$T/aws.log" | grep -cF 'ContextKeyName=ec2:ResourceTag/IdlefyPublishedImage,ContextKeyValues=true,ContextKeyType=string')" = 4 ]; echo $?)"
check "image ARNs are image/ ARNs" "$(grep -F 'simulate-principal-policy' "$T/aws.log" | grep -F 'DeregisterImage' | grep -qE -- '--resource-arns arn:aws:ec2:us-east-1::image/ami-[0-9a-f]+ '; echo $?)"
check "snapshot ARNs are snapshot/ ARNs" "$(grep -F 'simulate-principal-policy' "$T/aws.log" | grep -F 'DeleteSnapshot' | grep -qE -- '--resource-arns arn:aws:ec2:us-east-1::snapshot/snap-[0-9a-f]+ '; echo $?)"
for r in us-east-1 eu-central-1; do
  for c in "ec2 get-ebs-encryption-by-default" "ec2 get-image-block-public-access-state" \
           "ssm get-service-setting" "service-quotas get-service-quota" "ec2 describe-images"; do
    check "$r: $c" "$(grep -F "aws $c" "$T/aws.log" | grep -qF -- "--region $r"; echo $?)"
  done
  check "$r: opt-in status" "$(grep -F 'aws account get-region-opt-status' "$T/aws.log" | grep -qF -- "--region-name $r"; echo $?)"
done
check "the DHMC setting id is the default-ec2-instance-management-role" \
  "$(grep -F 'ssm get-service-setting' "$T/aws.log" | grep -qF -- '--setting-id /ssm/managed-instance/default-ec2-instance-management-role'; echo $?)"
check "the quota is L-0E3CBAB9 of ec2" \
  "$(grep -F 'get-service-quota' "$T/aws.log" | grep -qF -- '--service-code ec2 --quota-code L-0E3CBAB9'; echo $?)"
check "the public count includes deprecated images and only public ones of this account" \
  "$(grep -F 'ec2 describe-images' "$T/aws.log" | grep -F -- '--owners self' | grep -F -- '--include-deprecated' | grep -qF -- 'Name=is-public,Values=true'; echo $?)"
check "read-only: every call is get/list/describe/simulate" \
  "$(awk '{print $3}' "$T/aws.log" | grep -vqE '^(get|list|describe|simulate)-'; [ $? -ne 0 ]; echo $?)"

echo "== a principal without the deny =="
LEAKY=aleksei run_guard; check "exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names arn:…:user/aleksei" "$(grep -F "arn:aws:iam::$ACCT:user/aleksei" "$T/stderr" | grep -q 'implicitDeny'; echo $?)"
check "does not blame github-cfn-publish" "$(grep -qF 'github-cfn-publish' "$T/stderr"; [ $? -ne 0 ]; echo $?)"

echo "== region settings =="
ENC_ON=eu-central-1 run_guard; check "encryption by default in eu-central-1 → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names the region and encryption-by-default" "$(grep -F 'eu-central-1' "$T/stderr" | grep -qF 'encryption-by-default'; echo $?)"
check "does not blame us-east-1" "$(grep -F 'encryption-by-default' "$T/stderr" | grep -qF 'us-east-1'; [ $? -ne 0 ]; echo $?)"
BPA_ON=us-east-1 run_guard; check "image block public access in us-east-1 → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names block-new-sharing and the region" "$(grep -F 'block-new-sharing' "$T/stderr" | grep -qF 'us-east-1'; echo $?)"
OPT_STATUS=DISABLED run_guard; check "a region not enabled → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names the opt-in status" "$(grep -qF 'DISABLED' "$T/stderr"; echo $?)"
SSM_DHMC=service-role/AWSSystemsManagerDefaultEC2InstanceManagementRole run_guard
check "SSM Default Host Management Configuration set → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names default-ec2-instance-management-role and the region" \
  "$(grep -F 'default-ec2-instance-management-role' "$T/stderr" | grep -qF 'eu-central-1'; echo $?)"
SSM_DHMC='' run_guard; check "an empty DHMC value is unset → exit 0" "$?"

echo "== public AMI quota headroom =="
PUBLIC_COUNT=5 QUOTA=5 run_guard; check "5 public of 5 → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names L-0E3CBAB9" "$(grep -qF 'L-0E3CBAB9' "$T/stderr"; echo $?)"
PUBLIC_COUNT=4 QUOTA=5 run_guard; check "4 public of 5 → exit 0" "$?"
PUBLIC_COUNT=6 QUOTA=10 run_guard; check "6 public of a raised 10 → exit 0" "$?"
QUOTA_APPLIED_MISSING=1 PUBLIC_COUNT=4 DEFAULT_QUOTA=5 run_guard
check "no applied quota → the AWS default is used, exit 0" "$?"
check "…and the fallback was read" "$([ "$(calls 'get-aws-default-service-quota')" = 2 ]; echo $?)"
QUOTA_APPLIED_MISSING=1 PUBLIC_COUNT=5 DEFAULT_QUOTA=5 run_guard
check "no applied quota and no headroom under the default → exit 1" "$([ $? -eq 1 ]; echo $?)"

echo "== the wrong account =="
GUARD_ACCOUNT=111111111111 run_guard; check "exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names both account ids" "$(grep -qF '111111111111' "$T/stderr" && grep -qF "$ACCT" "$T/stderr"; echo $?)"
check "no call after sts" "$([ "$(wc -l < "$T/aws.log")" = 1 ] && grep -qF 'aws sts get-caller-identity' "$T/aws.log"; echo $?)"

echo "== every failure is listed, not the first =="
LEAKY="aleksei github-cfn-publish" ENC_ON=us-east-1 BPA_ON=eu-central-1 PUBLIC_COUNT=5 run_guard
check "exit 1" "$([ $? -eq 1 ]; echo $?)"
for s in "user/aleksei" "role/github-cfn-publish" "encryption-by-default" "block-new-sharing" "L-0E3CBAB9"; do
  check "lists $s" "$(grep -qF "$s" "$T/stderr"; echo $?)"
done
check "says how many" "$(grep -qE '^✗ hardened-guard-check: [0-9]+ failures?' "$T/stderr"; echo $?)"

echo "== a failing AWS call is a listed failure, not a pass =="
FAIL_CALL="ec2:get-ebs-encryption-by-default" run_guard; check "exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names the call for both regions" \
  "$([ "$(grep -cF 'get-ebs-encryption-by-default' "$T/stderr")" -ge 2 ]; echo $?)"
check "the other checks still ran" "$([ "$(calls 'iam simulate-principal-policy')" = 4 ]; echo $?)"
FAIL_CALL="iam:simulate-principal-policy" run_guard; check "a failing simulation → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "names the principal" "$(grep -qF "user/aleksei" "$T/stderr"; echo $?)"
FAIL_CALL="iam:list-users" run_guard; check "an unreadable user list → exit 1" "$([ $? -eq 1 ]; echo $?)"
FAIL_CALL="sts:get-caller-identity" run_guard; check "no identity → exit 1, nothing else called" \
  "$([ $? -eq 1 ] && [ "$(wc -l < "$T/aws.log")" = 1 ]; echo $?)"

echo "== the CI role =="
NO_CI_ROLE=1 run_guard; check "unset → exit 1 before any aws call" "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"
CI_ROLE_ARN="arn:aws:iam::111111111111:role/github-hardened-image-publish" run_guard
check "a role in another account → refused before any aws call" "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"
CI_ROLE_ARN="arn:aws:iam::$ACCT:role/not-there" run_guard
check "a role that does not exist → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "…names it" "$(grep -qF 'role/not-there' "$T/stderr"; echo $?)"
check "…and github-hardened-image-publish is then simulated like any other role" \
  "$(grep -qF -- "--policy-source-arn $CI_ROLE " "$T/aws.log"; echo $?)"

echo "== the regions file =="
cp "$R/image/hardened/regions" "$T/regions.orig"
printf 'us-east-1\nus-east-1\n' > "$R/image/hardened/regions"
run_guard; check "a repeated region → refused before any aws call" "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"
printf 'us-east-1 \n' > "$R/image/hardened/regions"
run_guard; check "a line that is not exactly a region → refused" "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"
cp "$T/regions.orig" "$R/image/hardened/regions"

echo "== the real regions file parses =="
cp "$ROOT/image/hardened/regions" "$R/image/hardened/regions"
run_guard; check "exit 0" "$?"
check "every region of it is checked" \
  "$([ "$(calls 'get-ebs-encryption-by-default')" = "$(grep -cv '^[[:space:]]*\(#\|$\)' "$ROOT/image/hardened/regions")" ]; echo $?)"
cp "$T/regions.orig" "$R/image/hardened/regions"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
