#!/usr/bin/env bash
# ami-build.sh — build the fleet image from the promoted production revision.
#
#   cd cinc && make ami [POLICY=dev-vm] [VOLUME=20] [SUBNET=subnet-…] [INSTANCE_TYPE=c7a.xlarge]
#
# One converge of the revision production.json names, through the same signed
# path and the same first-boot script every VM runs, then the scrub, then a
# snapshot. Production only: one image feeds both groups, so a staging build
# would put unpromoted content on production VMs. Design: the platform's
# docs/design/ami-image.md.
#
# Every input comes from vms/ — the variables through `terraform console`, the
# rendered first-boot script through `terraform output` — and the Packer
# template and the scrub from the pinned platform checkout that `terraform
# init` fetched, never from this tree. The scrub refuses to touch a VM whose
# last converge was not this revision, so a build that went wrong never
# powers off, and Packer times out with no AMI.
#
# Talks to AWS (EC2, and IAM for Packer's temporary instance profile). Reads no
# SSM parameter and prints nothing secret.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS="$ROOT/vms"
IMG="$VMS/.terraform/modules/ec2/image"
POLICY="${POLICY:-dev-vm}"
VOLUME="${VOLUME:-20}"
POLICYFILE="$ROOT/cinc/policyfiles/$POLICY.rb"
LOCKFILE="$ROOT/cinc/policyfiles/$POLICY.lock.json"

die() { echo "✗ make ami: $*" >&2; exit 1; }

for c in terraform packer python3 gzip; do
  command -v "$c" >/dev/null || die "$c is not on PATH"
done
# The same shape the bootstrap accepts for the PolicyName tag; it also lands in
# the AMI's name.
[[ $POLICY =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "POLICY='$POLICY' is not a policy name"
[[ $VOLUME =~ ^[1-9][0-9]{0,4}$ ]] || die "VOLUME='$VOLUME' is not a size in GB"
if [ ! -f "$POLICYFILE" ] || [ ! -f "$LOCKFILE" ]; then
  die "no cinc/policyfiles/$POLICY.rb with its lock — POLICY names a policyfile in this tenant"
fi

# The scrub and the template come from the commit vms/ is pinned to. pin-check
# is what says that commit is the one the lock and the sources agree on, for
# the policy being built. Its offline escape hatch is not honoured here: one
# image feeds every VM, new and replaced, in both groups.
if [ -n "${PIN_CHECK:-}" ]; then
  die "PIN_CHECK=$PIN_CHECK is not accepted: the image feeds every VM, so the pin must verify — unset PIN_CHECK and retry"
fi
make -C "$ROOT" pin-check POLICYFILE="cinc/policyfiles/$POLICY.rb" LOCKFILE="cinc/policyfiles/$POLICY.lock.json" \
  || die "pin-check failed — the image is built only from a verified pin"
[ -f "$IMG/dev-vm.pkr.hcl" ] || die "the pinned platform checkout has no image/ — run 'cd vms && terraform init' on v2.1.0 or later"
[ -f "$IMG/files/dev-vm-image-scrub" ] || die "the pinned platform checkout has no image/ — run 'cd vms && terraform init' on v2.1.0 or later"

TMPS=()
# shellcheck disable=SC2317  # reached only through the traps below
cleanup() { [ ${#TMPS[@]} -eq 0 ] || rm -f "${TMPS[@]}"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
# tmp VAR — a fresh 0600 file in VAR, removed on exit. Not $(…): a subshell
# would lose the registration.
tmp() { local f; f="$(mktemp)"; TMPS+=("$f"); printf -v "$1" '%s' "$f"; }
tmp SIGNERS_FILE; tmp BOOT_FILE; tmp UD

# ---- inputs ------------------------------------------------------------------
# Must stay on ONE line: `terraform console` evaluates its input line by line.
# The VMs are var.instances (region → name → object); local.regions holds the
# networks, and its keys are every region this tenant configures.
# shellcheck disable=SC2016  # HCL interpolation, not shell
CONSOLE_EXPR='jsonencode({profile = var.aws_profile, bucket = var.policy_bucket, owner = var.policy_bucket_owner, region = var.policy_bucket_region, prefix = var.policy_prefix, kms = var.policy_kms_key_arn, signers = var.policy_signers, regions = keys(local.regions), pin_sha = local.platform_pin.sha, volumes = merge([for r, vms in var.instances : {for k, v in vms : "${r}/${k}" => v.volume_size_gb}]...)})'
RAW="$(cd "$VMS" && echo "$CONSOLE_EXPR" | terraform console 2>/dev/null | tail -1)" \
  || die "could not read the configuration via 'terraform console' in vms/ — is it initialised?"
# console prints the jsonencode() result as a quoted JSON string: decode twice.
# All or nothing, as in preflight.
VARS="$(python3 -I - "$RAW" "$SIGNERS_FILE" "$VOLUME" 2>/dev/null <<'PY'
import json, shlex, sys
try:
    c = json.loads(json.loads(sys.argv[1]))
    open(sys.argv[2], "w").write("".join(l + "\n" for l in c["signers"]))
    out = {
        "PROFILE": c["profile"], "POLICY_BUCKET": c["bucket"],
        "POLICY_BUCKET_OWNER": c["owner"], "POLICY_BUCKET_REGION": c["region"],
        "POLICY_PREFIX": c["prefix"], "POLICY_KMS_KEY": c["kms"] or "",
        "PIN_SHA": c["pin_sha"], "REGIONS": " ".join(c["regions"]),
        "AMI_REGIONS": json.dumps(c["regions"], separators=(",", ":")),
        "SMALL_VM": "",
    }
    # No VM yet: nothing to compare the image with.
    if c["volumes"]:
        vm = min(sorted(c["volumes"]), key=lambda k: c["volumes"][k])
        if c["volumes"][vm] < int(sys.argv[3]):
            out["SMALL_VM"] = "%s %d" % (vm, c["volumes"][vm])
    print("\n".join("%s=%s" % (k, shlex.quote(str(v))) for k, v in out.items()))
except Exception:
    sys.exit(1)
PY
)" || die "could not decode the configuration read from vms/"
eval "$VARS"
[ -n "$REGIONS" ] || die "vms/ configures no region"

# A VM launched from the image cannot have a smaller root volume than its
# snapshot; EC2 refuses the launch, at apply time, for that one VM.
if [ -n "$SMALL_VM" ]; then
  read -r vm size <<<"$SMALL_VM"
  die "VM $vm has volume_size_gb = $size; the image is $VOLUME GB — raise it or pass VOLUME=$size"
fi

export AWS_PROFILE="$PROFILE"

# ---- the first-boot script ---------------------------------------------------
# From state, not re-rendered here: the image boots exactly what the module
# renders, one renderer and no second copy. Every region's is the same script
# (what differs per VM travels as tags); the build runs in the bucket's region
# when it is a configured one, so it reads the policy without crossing regions.
OUT="$(terraform -chdir="$VMS" output -json bootstrap_user_data 2>/dev/null)" \
  || die "vms/ state has no bootstrap_user_data output — run \`terraform apply\` on v2.1.0 once (it adds an output, nothing else), then retry"
BUILD_REGION="$(python3 -I - "$OUT" "$POLICY_BUCKET_REGION" "$BOOT_FILE" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
    r = sys.argv[2] if sys.argv[2] in d else sorted(d)[0]
    s = d[r]
    assert isinstance(s, str) and s.startswith("#!/bin/bash")
    open(sys.argv[3], "w").write(s)
    print(r)
except Exception:
    sys.exit(1)
PY
)" || die "bootstrap_user_data in vms/ state is empty or not a script — run \`terraform apply\` on v2.1.0 once, then retry"

# ---- the revision --------------------------------------------------------------
# What production.json names, verified against var.policy_signers by the same
# code that signs it.
SHOW="$(POLICY_BUCKET="$POLICY_BUCKET" POLICY_BUCKET_OWNER="$POLICY_BUCKET_OWNER" \
        POLICY_BUCKET_REGION="$POLICY_BUCKET_REGION" POLICY_PREFIX="$POLICY_PREFIX" \
        POLICY_SIGNERS_FILE="$SIGNERS_FILE" \
        "$ROOT/scripts/policy-publish.sh" show "$POLICYFILE" 2>&1)" \
  || die "could not read the envelopes: $(tail -1 <<<"$SHOW")"
REV=""
while read -r group state _ rev _; do
  [ "$group" = production ] || continue
  case "$state" in
    ok)      REV="$rev" ;;
    missing) die "promote first: the image is built only from production.json, and $POLICY has none" ;;
    *)       die "production.json for $POLICY does not verify against var.policy_signers — no image is built from it" ;;
  esac
done <<<"$SHOW"
[[ $REV =~ ^[0-9a-f]{64}$ ]] || die "policy-publish.sh show printed no production revision for $POLICY"

# The image's tags name the cookbook version, read from the lock. That is true
# only when the lock is what production carries.
read -r LOCK_REV COOKBOOK_VERSION < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["revision_id"], d["cookbook_locks"]["base"]["version"])' "$LOCKFILE" 2>/dev/null) \
  || die "cannot read revision_id and cookbook_locks.base.version from $LOCKFILE"
[ "$LOCK_REV" = "$REV" ] \
  || die "production carries ${REV:0:12}, the lock names ${LOCK_REV:0:12} — build from the commit production was promoted from, or promote the lock first"

# ---- the user data -------------------------------------------------------------
SCRUB="$IMG/files/dev-vm-image-scrub"
! grep -qx 'DEV_VM_IMAGE_SCRUB' "$SCRUB" || die "the scrub contains its own heredoc terminator"
[ "$(tail -c1 "$SCRUB" | od -An -c | tr -d ' ')" = '\n' ] || die "the scrub does not end in a newline"
{
  cat "$BOOT_FILE"
  printf '\n# ---- image build: scrub and power off (appended by make ami) ----\n'
  printf "install -m 0700 /dev/null /usr/local/sbin/dev-vm-image-scrub\n"
  printf "cat > /usr/local/sbin/dev-vm-image-scrub <<'DEV_VM_IMAGE_SCRUB'\n"
  cat "$SCRUB"
  printf 'DEV_VM_IMAGE_SCRUB\n'
  printf '/usr/local/sbin/dev-vm-image-scrub %s\n' "$REV"
} | gzip -9 > "$UD"
[ "$(stat -c %s "$UD")" -le 16384 ] \
  || die "user data is $(stat -c %s "$UD") bytes gzipped; EC2 takes 16384"

# ---- build ---------------------------------------------------------------------
echo "Building $POLICY at ${REV:0:12} (cookbook $COOKBOOK_VERSION, platform ${PIN_SHA:0:12}) in $BUILD_REGION for: $REGIONS"
packer init "$IMG" >/dev/null || die "packer init failed"
tmp PKLOG
# -machine-readable: the artifact line is the only reliable source of the AMI
# ids. The ui lines are echoed as they come, so the operator sees progress.
packer build -machine-readable \
  -var "aws_profile=$PROFILE" \
  -var "build_region=$BUILD_REGION" \
  -var "ami_regions=$AMI_REGIONS" \
  -var "user_data_file=$UD" \
  -var "policy_bucket=$POLICY_BUCKET" \
  -var "policy_prefix=$POLICY_PREFIX" \
  -var "policy_kms_key_arn=$POLICY_KMS_KEY" \
  -var "policy_name=$POLICY" \
  -var "revision_id=$REV" \
  -var "platform_sha=$PIN_SHA" \
  -var "cookbook_version=$COOKBOOK_VERSION" \
  -var "subnet_id=${SUBNET:-}" \
  -var "instance_type=${INSTANCE_TYPE:-c7a.xlarge}" \
  -var "volume_size_gb=$VOLUME" \
  "$IMG" \
  | tee "$PKLOG" \
  | awk -F, '$3 == "ui" { m = $5; for (i = 6; i <= NF; i++) m = m "," $i; gsub(/%!\(PACKER_COMMA\)/, ",", m); gsub(/\\n/, "\n", m); print m; fflush() }' \
  || die "packer build failed — no image was registered; the instance's serial console holds the bootstrap log"

# "<region>:<ami>,<region>:<ami>", commas escaped as %!(PACKER_COMMA).
AMIS="$(awk -F, '$3 == "artifact" && $4 == "0" && $5 == "id" { print $6 }' "$PKLOG" \
        | sed 's/%!(PACKER_COMMA)/,/g' | tr ',' '\n' | sed -n 's/^\([a-z0-9-]*\):\(ami-[0-9a-f]*\)$/\1 \2/p')"
[ -n "$AMIS" ] || die "packer finished but reported no AMI"

echo
echo "$AMIS"
echo
echo "To launch VMs from it, set in vms/tenant.auto.tfvars:"
echo '  ami_owners       = ["self"]'
echo "  ami_name_pattern = \"dev-vm-$POLICY-2*\""
