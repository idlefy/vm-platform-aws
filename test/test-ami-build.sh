#!/usr/bin/env bash
# scripts/ami-build.sh against shimmed terraform/packer/make/policy-publish.
# Nothing here touches AWS and nothing runs a real `packer build`.
#
# Each scenario runs the script in a throwaway tenant tree whose
# vms/.terraform/modules/ec2/image holds the REAL template and the REAL scrub,
# as `terraform init` would have fetched them from the pinned commit.
#
# The terraform shim answers `console` with a jsonencode() result built from
# the environment — a JSON string, double-encoded exactly as the real console
# prints it — and `output -json bootstrap_user_data` with a two-region map.
# policy-publish.sh's `show` is tested against real envelopes in
# test-policy-publish.sh; what is tested here is what ami-build makes of each
# answer.
#
# The last section renders the module's real bootstrap script through
# `terraform console` and checks that it, with the scrub appended, still fits
# EC2's 16 KB of user data. It prints SKIP when the module is not initialised.

# The checks read `[ … ]; echo $?` and `run_ami; check … "$?"` on purpose: the
# status of that condition, or of that run, is the thing being checked.
# shellcheck disable=SC2181,SC2319

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
IMG="$T/vms/.terraform/modules/ec2/image"
mkdir -p "$T/bin" "$IMG/files" "$T/cinc/policyfiles" "$T/scripts"
cp "$ROOT/scripts/ami-build.sh" "$T/scripts/ami-build.sh" 2>/dev/null
cp "$ROOT/image/dev-vm.pkr.hcl" "$IMG/dev-vm.pkr.hcl"
cp "$ROOT/image/files/dev-vm-image-scrub" "$IMG/files/dev-vm-image-scrub"

REV=$(printf 'rev' | sha256sum | cut -d' ' -f1)
OTHERREV=$(printf 'other' | sha256sum | cut -d' ' -f1)
SIG=$(printf 'signers' | sha256sum | cut -d' ' -f1)
PIN_SHA=$(printf 'pin' | sha1sum | cut -d' ' -f1)
SIGNER='ops namespaces="dev-vm-policy-staging,dev-vm-policy-production" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOps'
echo "default_source :supermarket" > "$T/cinc/policyfiles/dev-vm.rb"
lock() { printf '{"name":"dev-vm","revision_id":"%s","cookbook_locks":{"base":{"version":"2.1.0"}}}' "$1" \
           > "$T/cinc/policyfiles/dev-vm.lock.json"; }
lock "$REV"

cat > "$T/bin/terraform" <<'SH'
#!/usr/bin/env bash
chdir=""
if [[ ${1:-} == -chdir=* ]]; then chdir=${1#-chdir=}; shift; fi
case "${1:-}" in
  console)
    cat > "$TF_CONSOLE_IN"
    python3 - <<'PY'
import json, os
inner = json.dumps({
    "profile": "p", "bucket": "t-policies", "owner": "111122223333",
    "region": os.environ.get("BUCKET_REGION", "eu-central-1"),
    "prefix": "dev-vm-policies", "kms": os.environ.get("KMS") or None,
    "signers": [os.environ["SIGNER"]],
    "regions": ["eu-central-1", "us-east-1"],
    "pin_sha": os.environ["PIN_SHA"],
    "volumes": json.loads(os.environ.get("VOLUMES") or '{"eu-central-1/a":20,"us-east-1/b":50}'),
})
print(json.dumps(inner))
PY
    ;;
  output)
    echo "$chdir $*" >> "$TF_OUTPUT_LOG"
    [ "$*" = "output -json bootstrap_user_data" ] || exit 1
    if [ -n "${NO_OUTPUT:-}" ]; then
      echo 'Error: Output "bootstrap_user_data" not found' >&2; exit 1
    fi
    cat "$BOOT_JSON" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/bin/packer" <<'SH'
#!/usr/bin/env bash
echo "packer $1" >> "$ORDER_LOG"
echo "$*" >> "$PACKER_LOG"
[ "$1" = build ] || exit 0
for a in "$@"; do
  case "$a" in user_data_file=*) cp "${a#user_data_file=}" "$UD_COPY" ;; esac
done
echo '1697000000,,ui,say,==> amazon-ebs.dev_vm: Waiting for the instance to power off...'
echo '1697000001,amazon-ebs.dev_vm,artifact,0,id,eu-central-1:ami-0aaa%!(PACKER_COMMA)us-east-1:ami-0bbb'
exit "${PACKER_RC:-0}"
SH
cat > "$T/bin/make" <<'SH'
#!/usr/bin/env bash
echo "make $*" >> "$ORDER_LOG"
echo "$*" >> "$MAKE_LOG"
exit "${PIN_RC:-0}"
SH
cat > "$T/scripts/policy-publish.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] || exit 9
env | grep -E '^(POLICY_|AWS_PROFILE=)' | sort > "$SHOW_ENV"
cp "$POLICY_SIGNERS_FILE" "$SHOW_ENV.signers"
echo "$2" > "$SHOW_ENV.arg"
printf 'staging ok 9 %s %s\n%s\n' "$REV" "$SIG" "$SHOW_PRODUCTION"
SH
chmod +x "$T/bin/"* "$T/scripts/policy-publish.sh"

BOOT_DEFAULT="$T/boot.json"
printf '%s' '{"eu-central-1":"#!/bin/bash\necho boot\n","us-east-1":"#!/bin/bash\necho boot\n"}' > "$BOOT_DEFAULT"

# run_ami — runs the script from cinc/, as `make ami` does; returns its status.
run_ami() {
  local show="${SHOW_PRODUCTION:-production ok 7 $REV $SIG}"
  : > "$T/packer.log"; : > "$T/make.log"; : > "$T/order.log"; : > "$T/tfout.log"; rm -f "$T/ud.gz" "$T/show.env"*
  ( cd "$T/cinc" && PATH="$T/bin:$PATH" TF_CONSOLE_IN="$T/console.in" TF_OUTPUT_LOG="$T/tfout.log" \
      PACKER_LOG="$T/packer.log" UD_COPY="$T/ud.gz" MAKE_LOG="$T/make.log" ORDER_LOG="$T/order.log" SHOW_ENV="$T/show.env" \
      BOOT_JSON="${BOOT_JSON:-$BOOT_DEFAULT}" SIGNER="$SIGNER" PIN_SHA="$PIN_SHA" REV="$REV" SIG="$SIG" \
      SHOW_PRODUCTION="$show" \
      "$T/scripts/ami-build.sh" > "$T/out" 2>&1 )
}

echo "== a promoted revision builds =="
SHOW_PRODUCTION="production ok 7 $REV $SIG" run_ami; check "exits 0" "$?"
check "pin-check ran before packer" "$(head -1 "$T/order.log" | grep -q '^make .*pin-check' && grep -q '^packer build' "$T/order.log"; echo $?)"
check "pin-check checked this policy's files" \
  "$(grep -qF 'pin-check POLICYFILE=cinc/policyfiles/dev-vm.rb LOCKFILE=cinc/policyfiles/dev-vm.lock.json' "$T/make.log"; echo $?)"
check "the console expression is one line" "$([ "$(wc -l < "$T/console.in")" = 1 ]; echo $?)"
check "the volumes come from var.instances" "$(grep -q 'var.instances' "$T/console.in"; echo $?)"
check "packer init ran on the pinned image" "$(grep -qx "init $IMG" "$T/packer.log"; echo $?)"
check "packer got the revision" "$(grep -q "revision_id=$REV" "$T/packer.log"; echo $?)"
check "packer got every region" "$(grep -q 'ami_regions=\["eu-central-1","us-east-1"\]' "$T/packer.log"; echo $?)"
check "packer builds in the bucket's region" "$(grep -q 'build_region=eu-central-1 ' "$T/packer.log"; echo $?)"
check "packer got the policy name" "$(grep -q 'policy_name=dev-vm ' "$T/packer.log"; echo $?)"
check "packer got the platform sha" "$(grep -q "platform_sha=$PIN_SHA " "$T/packer.log"; echo $?)"
check "packer got the cookbook version from the lock" "$(grep -q 'cookbook_version=2.1.0 ' "$T/packer.log"; echo $?)"
check "packer got the bucket and prefix" "$(grep -q 'policy_bucket=t-policies .*policy_prefix=dev-vm-policies ' "$T/packer.log"; echo $?)"
check "an unset KMS key is passed as empty" "$(grep -q 'policy_kms_key_arn= ' "$T/packer.log"; echo $?)"
check "packer got the profile" "$(grep -q 'aws_profile=p ' "$T/packer.log"; echo $?)"
check "volume defaults to 20" "$(grep -q 'volume_size_gb=20 ' "$T/packer.log"; echo $?)"
check "packer is machine-readable" "$(grep -q '^build -machine-readable ' "$T/packer.log"; echo $?)"
check "user data is gzip" "$(gzip -t "$T/ud.gz"; echo $?)"
check "user data = bootstrap, then the scrub, called with the revision" \
  "$(zcat "$T/ud.gz" | { read -r l1; [ "$l1" = '#!/bin/bash' ] && grep -q 'echo boot' && true; } && zcat "$T/ud.gz" | tail -1 | grep -qx "/usr/local/sbin/dev-vm-image-scrub $REV"; echo $?)"
check "the scrub is installed 0700 root before it runs" "$(zcat "$T/ud.gz" | grep -q "install -m 0700 /dev/null /usr/local/sbin/dev-vm-image-scrub"; echo $?)"
check "the embedded scrub is the pinned checkout's, byte for byte" \
  "$(zcat "$T/ud.gz" | sed -n "/^cat > \/usr\/local\/sbin\/dev-vm-image-scrub <<'DEV_VM_IMAGE_SCRUB'\$/,/^DEV_VM_IMAGE_SCRUB\$/p" | sed '1d;$d' | cmp -s - "$IMG/files/dev-vm-image-scrub"; echo $?)"
check "user data fits EC2's 16 KB" "$([ "$(stat -c %s "$T/ud.gz")" -le 16384 ]; echo $?)"
check "show read the production policyfile" "$(grep -q 'cinc/policyfiles/dev-vm.rb$' "$T/show.env.arg"; echo $?)"
check "show got the bucket from vms/" "$(grep -qx 'POLICY_BUCKET=t-policies' "$T/show.env"; echo $?)"
check "...and var.policy_signers" "$(grep -qxF "$SIGNER" "$T/show.env.signers"; echo $?)"
check "prints one line per region" \
  "$(grep -qx 'eu-central-1 ami-0aaa' "$T/out" && grep -qx 'us-east-1 ami-0bbb' "$T/out"; echo $?)"
check "prints the tfvars to set" \
  "$(grep -qE 'ami_owners +=  *\["self"\]' "$T/out" && grep -qE 'ami_name_pattern +=  *"dev-vm-dev-vm-\*"' "$T/out"; echo $?)"
check "the user data temp file is gone" "$(! grep -o 'user_data_file=[^ ]*' "$T/packer.log" | cut -d= -f2 | xargs -r ls 2>/dev/null | grep -q .; echo $?)"

echo "== inputs passed through =="
KMS=arn:aws:kms:eu-central-1:111122223333:key/k VOLUME=18 run_ami; check "exits 0" "$?"
check "the KMS key reaches packer" "$(grep -q 'policy_kms_key_arn=arn:aws:kms:eu-central-1:111122223333:key/k ' "$T/packer.log"; echo $?)"
check "VOLUME reaches packer" "$(grep -q 'volume_size_gb=18' "$T/packer.log"; echo $?)"
BUCKET_REGION=eu-west-1 run_ami; check "bucket region has no VMs: exits 0" "$?"
check "...builds in the first region" "$(grep -q 'build_region=eu-central-1 ' "$T/packer.log"; echo $?)"
BUCKET_REGION=us-east-1 run_ami; check "bucket region us-east-1: exits 0" "$?"
check "...builds there" "$(grep -q 'build_region=us-east-1 ' "$T/packer.log"; echo $?)"

echo "== refusals =="
SHOW_PRODUCTION="production missing" run_ami; check "no production.json → refuses" "$([ $? -ne 0 ] && grep -q 'promote' "$T/out"; echo $?)"
check "...and packer never runs" "$([ ! -s "$T/packer.log" ]; echo $?)"
SHOW_PRODUCTION="production invalid" run_ami; check "invalid envelope → refuses" "$([ $? -ne 0 ]; echo $?)"
check "...and packer never runs" "$([ ! -s "$T/packer.log" ]; echo $?)"
SHOW_PRODUCTION="production ok 7 $OTHERREV $SIG" run_ami
check "production is not the lock → refuses (the tags would lie)" "$([ $? -ne 0 ] && grep -q "${OTHERREV:0:12}" "$T/out"; echo $?)"
PIN_CHECK=skip run_ami; check "PIN_CHECK=skip → refuses, packer never runs" "$([ $? -ne 0 ] && grep -q 'pin must verify' "$T/out" && [ ! -s "$T/packer.log" ]; echo $?)"
check "...and pin-check is not even asked" "$([ ! -s "$T/make.log" ]; echo $?)"
PIN_RC=1 run_ami;                             check "pin-check fails → refuses, packer never runs" "$([ $? -ne 0 ] && [ ! -s "$T/packer.log" ]; echo $?)"
VOLUMES='{"eu-central-1/tiny":16,"us-east-1/b":50}' run_ami
check "a VM smaller than the image → refuses, names it" "$([ $? -ne 0 ] && grep -q 'eu-central-1/tiny' "$T/out" && grep -q '16' "$T/out"; echo $?)"
check "...and packer never runs" "$([ ! -s "$T/packer.log" ]; echo $?)"
VOLUMES='{"eu-central-1/tiny":16,"us-east-1/b":50}' VOLUME=16 run_ami; check "...unless VOLUME fits it" "$?"
VOLUMES='{}' run_ami; check "no VM yet → no volume check, builds" "$?"
VOLUME=abc run_ami; check "a VOLUME that is not a number → refuses" "$([ $? -ne 0 ] && [ ! -s "$T/packer.log" ]; echo $?)"
NO_OUTPUT=1 run_ami;                           check "no bootstrap_user_data in state → says apply v2.1.0 first" "$([ $? -ne 0 ] && grep -q 'terraform apply' "$T/out"; echo $?)"
cp "$ROOT/image/files/dev-vm-image-scrub" "$T/scrub.orig"
printf '#!/bin/bash\n%s\n' "$(head -c 15000 /dev/urandom | base64 -w0)" \
  | python3 -I -c 'import json,sys; s=sys.stdin.read(); json.dump({"eu-central-1": s, "us-east-1": s}, sys.stdout)' > "$T/big.json"
BOOT_JSON="$T/big.json" run_ami
check "user data over 16 KB gzipped → refuses, says 16384, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '16384' "$T/out" && [ ! -s "$T/packer.log" ]; echo $?)"
cp "$T/cinc/policyfiles/dev-vm.rb" "$T/cinc/policyfiles/dev-vm2.rb"
cp "$T/cinc/policyfiles/dev-vm.lock.json" "$T/cinc/policyfiles/dev-vm2.lock.json"
POLICY=dev-vm2 run_ami; check "POLICY=dev-vm2 builds" "$?"
check "...and pin-check checked dev-vm2's files" \
  "$(grep -qF 'pin-check POLICYFILE=cinc/policyfiles/dev-vm2.rb LOCKFILE=cinc/policyfiles/dev-vm2.lock.json' "$T/make.log"; echo $?)"
check "...and names the AMI after it" "$(grep -q 'policy_name=dev-vm2 ' "$T/packer.log"; echo $?)"
rm -f "$T/cinc/policyfiles/dev-vm2."*
{ cat "$T/scrub.orig"; echo 'DEV_VM_IMAGE_SCRUB'; echo 'true'; } > "$IMG/files/dev-vm-image-scrub"
run_ami; check "a scrub holding its own heredoc terminator → refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q 'terminator' "$T/out" && [ ! -s "$T/packer.log" ]; echo $?)"
{ cat "$T/scrub.orig"; printf 'true'; } > "$IMG/files/dev-vm-image-scrub"
run_ami; check "a scrub with no trailing newline → refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q 'newline' "$T/out" && [ ! -s "$T/packer.log" ]; echo $?)"
cp "$T/scrub.orig" "$IMG/files/dev-vm-image-scrub"
POLICY=nope run_ami; check "a policy with no policyfile → refuses" "$([ $? -ne 0 ] && grep -q 'nope' "$T/out"; echo $?)"
POLICY='../x' run_ami; check "a malformed policy name → refuses" "$([ $? -ne 0 ] && [ ! -s "$T/packer.log" ]; echo $?)"
PACKER_RC=1 run_ami; check "packer fails → fails" "$([ $? -ne 0 ]; echo $?)"
mv "$IMG/files/dev-vm-image-scrub" "$T/scrub.bak"
run_ami; check "no scrub in the pinned checkout → refuses, names init" "$([ $? -ne 0 ] && grep -q 'terraform init' "$T/out"; echo $?)"
mv "$T/scrub.bak" "$IMG/files/dev-vm-image-scrub"

echo "== the real script, with the scrub, fits in 16 KB =="
MOD="$ROOT/vms/modules/ec2"
cat > "$T/mock.tfvars" <<'EOF'
environment          = "test"
aws_region           = "eu-central-1"
default_az           = "eu-central-1a"
network_config       = { vpc_cidr = "10.8.0.0/16", public_subnets = { "eu-central-1a" = { cidr_block = "10.8.1.0/24", az = "eu-central-1a" } } }
security_group_rules = {}
route53_zone_id      = "Z00000000000000000TEST"
policy_bucket        = "tenant-policies"
policy_bucket_owner  = "123456789012"
policy_bucket_region = "eu-central-1"
policy_signers = [
  "ops namespaces=\"dev-vm-policy-staging,dev-vm-policy-production\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMkEu+CUWYGvccB0PoBw6SX1d6kJOSy2vALB7cAntO+E",
  "ci namespaces=\"dev-vm-policy-staging\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMkEu+CUWYGvccB0PoBw6SX1d6kJOSy2vALB7cAntO+F",
]
EOF
if [ -d "$MOD/.terraform" ] \
   && RAW="$(echo 'jsonencode(local.user_data_script)' \
             | terraform -chdir="$MOD" console -var-file="$T/mock.tfvars" 2>/dev/null | tail -1)" \
   && python3 -I -c 'import json,sys; s=json.loads(json.loads(sys.argv[1])); assert s.startswith("#!/bin/bash"); json.dump({"eu-central-1": s, "us-east-1": s}, open(sys.argv[2], "w"))' \
        "$RAW" "$T/real-boot.json" 2>/dev/null; then
  BOOT_JSON="$T/real-boot.json" run_ami; check "the real bootstrap builds" "$?"
  size=$(stat -c %s "$T/ud.gz")
  echo "       real bootstrap + scrub, gzip -9: $size bytes (EC2 takes 16384)"
  check "the real user data fits EC2's 16 KB" "$([ "$size" -le 16384 ]; echo $?)"
  check "...and it is the module's script" "$(zcat "$T/ud.gz" | grep -q 'DEV_VM_POLICY_FETCH'; echo $?)"
elif [ -n "${CI:-}" ]; then
  # CI's terraform job runs `terraform init` in vms/modules/ec2 before the
  # script tests; a SKIP there means the measurement silently stopped.
  check "the real-size check runs in CI ($MOD initialised)" 1
else
  echo "  SKIP the real-size check: $MOD is not initialised (terraform init there first)"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
