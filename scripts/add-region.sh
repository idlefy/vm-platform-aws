#!/usr/bin/env bash
# Wizard: wire a new AWS region into the developer-VM deployment.
#
# Since main.tf became a single `for_each` over local.regions, adding a region is
# one entry in one file. That makes most of this wizard's value the *checks* rather
# than the writing: whether the account can use the region at all (an SCP can deny
# it while opt-in status says otherwise), which AZs exist, and whether the AMI
# pattern resolves there. Getting those wrong produces HCL that plans and then
# fails on every call.
#
# It does NOT create anything in AWS and does not apply. The result is a diff for
# you to read.
#
# Usage:  scripts/add-region.sh [region]        (or: cd cinc && make add-region)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMS="$ROOT/vms"
TARGETS=(config.tf)

c_b=$'\033[1m'; c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_0=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$c_b" "$*" "$c_0"; }
ok()   { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

command -v terraform >/dev/null || die "terraform is not on PATH"
command -v python3   >/dev/null || die "python3 is not on PATH"

# ---------------------------------------------------------------------------
# The output is a diff, so the diff has to be readable: refuse to start on top of
# unrelated uncommitted edits to the files we are about to rewrite. Restoring on
# failure would otherwise throw away work that was never ours.
# ---------------------------------------------------------------------------
step "Checking the working tree"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  DIRTY=""
  for f in "${TARGETS[@]}"; do
    # `diff HEAD`, not bare `diff`: the latter compares the working tree against
    # the INDEX, so a staged-but-uncommitted edit produces no diff and the guard
    # passes. cleanup_restore then copies the pre-wizard backup over the file and
    # the staged edit is gone from the working tree — the exact loss this guard
    # exists to prevent.
    git -C "$ROOT" diff --quiet HEAD -- "vms/$f" 2>/dev/null || DIRTY="$DIRTY vms/$f"
  done
  [ -z "$DIRTY" ] || die "uncommitted changes in:$DIRTY
Commit or stash them first — this wizard rewrites those files and restores them
from backup if a check fails, which would discard your edits."
  ok "no uncommitted changes in the files this touches"
else
  warn "not a git repository — you will have no diff to review"
fi

# ---------------------------------------------------------------------------
step "Region"
REGION="${1:-}"
if [ -z "$REGION" ]; then
  read -r -p "  AWS region code (e.g. eu-west-1): " REGION
fi
[[ "$REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "'$REGION' does not look like a region code"

grep -qE "^\s*\"$REGION\"\s*=\s*\{" "$VMS/config.tf" \
  && die "$REGION is already in vms/config.tf's local.regions"
ok "$REGION is new"

# Everything below needs AWS only to *check* things. Without it the wizard still
# writes correct HCL — it just cannot tell you the region or the AMI is real.
AWS_OK=0
PROFILE="$(sed -n 's/^\s*aws_profile\s*=\s*"\([^"]*\)".*/\1/p' "$VMS/tenant.auto.tfvars" 2>/dev/null | head -1)"
if command -v aws >/dev/null && [ -n "$PROFILE" ]; then
  export AWS_PROFILE="$PROFILE"
  aws sts get-caller-identity >/dev/null 2>&1 && AWS_OK=1
fi
if [ "$AWS_OK" -eq 1 ]; then
  ok "AWS reachable with profile '$PROFILE' — will verify the region and the AMI"
  if ! aws ec2 describe-regions --region us-east-1 --all-regions \
        --query 'Regions[].RegionName' --output text 2>/dev/null | tr '\t' '\n' | grep -qx "$REGION"; then
    die "AWS does not know a region called '$REGION'"
  fi
  ENABLED="$(aws ec2 describe-regions --region us-east-1 --region-names "$REGION" \
              --query 'Regions[0].OptInStatus' --output text 2>/dev/null)"
  [ "$ENABLED" = "not-opted-in" ] \
    && die "$REGION exists but this account has not opted in. Enable it in the console first."
  ok "region exists (opt-in status: $ENABLED)"
else
  warn "AWS not reachable — skipping the region/AZ/AMI checks, HCL will still be written"
fi

# ---------------------------------------------------------------------------
# One EC2 read in the target region does double duty: it lists the AZs and it
# proves the region is actually usable.
#
# Opt-in status is NOT that proof. This account sits under an organisation whose
# service control policy allowlists regions, and a denied region reports
# "opt-in-not-required" while every EC2 call in it fails. Distinguishing the
# three outcomes matters: an SCP denial needs whoever owns the SCP, missing IAM
# permissions need a policy change, and a genuinely empty result needs neither.
# Collapsing them — which this script did at first, by discarding stderr — turned
# an org-level regional block into a misleading "no matching AMI".
# ---------------------------------------------------------------------------
step "Availability zones"
AZS=()
if [ "$AWS_OK" -eq 1 ]; then
  AZ_ERR="$(mktemp)"
  AZ_OUT="$(aws ec2 describe-availability-zones --region "$REGION" \
              --query 'AvailabilityZones[?State==`available`].ZoneName' \
              --output text 2>"$AZ_ERR")"
  if grep -q 'service_control_policy' "$AZ_ERR"; then
    SCP="$(sed -n 's|.*policy/\([^ ]*\).*|\1|p' "$AZ_ERR" | head -1)"
    rm -f "$AZ_ERR"
    die "$REGION is blocked by an organisation service control policy.

  EC2 is explicitly denied there${SCP:+ by $SCP}, so no VM can ever launch in it —
  opt-in status says nothing about this. Adding the HCL would produce a region
  that plans and then fails on every call.

  Ask whoever owns the SCP to allow the region, or pick one that is already
  permitted. To find out which are, run:

    for r in \$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
      aws ec2 describe-availability-zones --region \"\$r\" >/dev/null 2>&1 \\
        && echo \"\$r allowed\"
    done"
  elif grep -q 'UnauthorizedOperation\|AccessDenied' "$AZ_ERR"; then
    rm -f "$AZ_ERR"
    die "not authorised to run ec2:DescribeAvailabilityZones in $REGION.
This is an IAM problem on profile '$PROFILE', not a problem with the region."
  elif [ -s "$AZ_ERR" ]; then
    warn "could not list AZs: $(head -1 "$AZ_ERR" | cut -c1-90)"
  fi
  rm -f "$AZ_ERR"
  [ -n "$AZ_OUT" ] && mapfile -t AZS < <(tr '\t' '\n' <<<"$AZ_OUT" | sort)
fi
if [ "${#AZS[@]}" -eq 0 ]; then
  warn "assuming ${REGION}a and ${REGION}b"
  AZS=("${REGION}a" "${REGION}b")
else
  ok "available: ${AZS[*]}"
fi

DEFAULT_N=2
[ "${#AZS[@]}" -lt 2 ] && DEFAULT_N="${#AZS[@]}"
read -r -p "  How many AZs to create subnets in? [$DEFAULT_N] " N
N="${N:-$DEFAULT_N}"
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le "${#AZS[@]}" ] \
  || die "expected a number between 1 and ${#AZS[@]}"
USE_AZS=("${AZS[@]:0:$N}")
DEFAULT_AZ="${USE_AZS[0]}"
ok "subnets in: ${USE_AZS[*]}   default_az: $DEFAULT_AZ"

# ---------------------------------------------------------------------------
step "Addressing"
say "  Every existing region reuses 10.8.0.0/16 with the same subnet CIDRs. That is"
say "  deliberate: these VPCs are independent and never peered, and the VMs are"
say "  public. Keeping it identical also means peering or a transit gateway between"
say "  regions would need renumbering first — pick something unique now if you"
say "  think you will ever want that."
read -r -p "  VPC CIDR [10.8.0.0/16]: " VPC_CIDR
VPC_CIDR="${VPC_CIDR:-10.8.0.0/16}"
[[ "$VPC_CIDR" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.0\.0/16$ ]] \
  || die "expected a /16 of the form A.B.0.0/16 (subnet CIDRs are derived as A.B.N.0/24)"
OCT1="${BASH_REMATCH[1]}"; OCT2="${BASH_REMATCH[2]}"
# {1,3} matches the shape, not the range, so 999.999.0.0/16 gets this far. 10# is
# needed because a leading zero would otherwise be read as octal — 010 is 8, and
# 08 is not a number at all.
(( 10#$OCT1 <= 255 && 10#$OCT2 <= 255 )) \
  || die "CIDR octets must be 0-255; got $OCT1.$OCT2. Terraform would reject the generated config later, with an error pointing at config.tf rather than at this answer."
ok "VPC $VPC_CIDR, subnets $OCT1.$OCT2.1.0/24 .. $OCT1.$OCT2.$N.0/24"

# ---------------------------------------------------------------------------
if [ "$AWS_OK" -eq 1 ]; then
  step "AMI"
  # The tenant's own variables, not the module's. A thin tenant has no
  # vms/modules/ on disk — the module arrives through .terraform/modules at
  # plan time — so the previous form returned empty here and the check below
  # degraded to "skipped" on every run, in a script whose own docstring says
  # the checks are most of its value.
  # Every owner, not the first. ami_owners is list(string): a sed pulling one
  # 12-digit id silently drops the rest, and if the intended image belongs to a
  # later owner the call returns nothing — which this script then reports as
  # "no AMI in <region> matches <pattern>" and treats as a hard stop. A false
  # stop on correct configuration, from a check whose whole point is to be
  # trusted. The block may also be written across lines, which the sed missed.
  # One value per line, into an array. `read -r PATTERN OWNERS` packed both into
  # one line, which truncates ami_name_pattern at its first space — it is a
  # configurable string — and left $OWNERS to be word-split and glob-expanded on
  # the command line below.
  mapfile -t AMI_VALUES < <(python3 - "$VMS/variables.tf" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()


def default_of(name):
    m = re.search(r'variable\s+"%s"\s*\{' % re.escape(name), src)
    if not m:
        return ""
    depth, i = 0, m.end() - 1
    while i < len(src):                      # find the variable block's extent
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = src[m.end() - 1:i]
    d = re.search(r'default\s*=\s*(\[.*?\]|"[^"]*")', block, re.S)
    return d.group(1) if d else ""


print(default_of("ami_name_pattern").strip('"'))
for owner in re.findall(r'"([^"]+)"', default_of("ami_owners")):
    print(owner)
PYEOF
)
  PATTERN="${AMI_VALUES[0]:-}"
  OWNER_ARGS=("${AMI_VALUES[@]:1}")
  if [ -n "$PATTERN" ] && [ "${#OWNER_ARGS[@]}" -gt 0 ]; then
    AMI_ERR="$(mktemp)"
    AMI="$(aws ec2 describe-images --region "$REGION" --owners "${OWNER_ARGS[@]}" \
             --filters "Name=name,Values=$PATTERN" \
             --query 'reverse(sort_by(Images,&CreationDate))[0].Name' \
             --output text 2>"$AMI_ERR")"
    if [ -s "$AMI_ERR" ]; then
      # An error here is not "no such image" — say which it is.
      warn "could not check: $(head -1 "$AMI_ERR" | cut -c1-90)"
      rm -f "$AMI_ERR"
    else
      rm -f "$AMI_ERR"
      case "$AMI" in
        ""|None) die "no AMI in $REGION matches '$PATTERN'.
The call succeeded and returned nothing, so this really is a pattern/region
mismatch rather than a permissions problem. A VM there would fail at plan.
Check the pattern in vms/variables.tf." ;;
        *)       ok "resolves to $AMI" ;;
      esac
    fi
  else
        die "could not read ami_name_pattern / ami_owners from vms/variables.tf.
This check is why the script exists: without it, a region that carries no
matching image is written into config.tf and fails at apply, in a place that
looks like an SCP denial. Fix the variables before adding a region."
  fi
fi

# ---------------------------------------------------------------------------
step "Summary"
say "  region        $REGION"
say "  module        module.ec2[\"$REGION\"]"
say "  subnets       ${USE_AZS[*]}"
say "  default_az    $DEFAULT_AZ"
say "  vpc_cidr      $VPC_CIDR"
say ""
say "  will edit     vms/config.tf — one entry in local.regions, nothing else."
say "                main.tf drives regions with for_each, so there is no"
say "                provider, module, output or test fixture to add."
say "  will NOT      create anything in AWS, or run apply"
say ""
read -r -p "  Proceed? [y/N] " GO
case "$GO" in y|Y|yes) ;; *) say "Aborted."; exit 0 ;; esac

# ---------------------------------------------------------------------------
# Back up first, so a failed check below leaves nothing half-written.
# ---------------------------------------------------------------------------
BACKUP="$(mktemp -d)"
cleanup_restore() {
  say ""
  warn "restoring the original files from backup"
  for f in "${TARGETS[@]}"; do
    [ -f "$BACKUP/$(basename "$f")" ] && cp "$BACKUP/$(basename "$f")" "$VMS/$f"
  done
  rm -rf "$BACKUP"
}
for f in "${TARGETS[@]}"; do cp "$VMS/$f" "$BACKUP/$(basename "$f")"; done

step "Writing HCL"

# --- config.tf: an entry inside local.regions ------------------------------
SUBNETS=""
for i in "${!USE_AZS[@]}"; do
  SUBNETS="$SUBNETS          \"${USE_AZS[$i]}\" = {
            cidr_block = \"$OCT1.$OCT2.$((i + 1)).0/24\"
            az         = \"${USE_AZS[$i]}\"
          }
"
done
REGION_ENTRY="
    # ==================== $REGION ====================
    \"$REGION\" = {
      network_config = {
        vpc_cidr = \"$VPC_CIDR\"
        public_subnets = {
$SUBNETS        }
      }

      default_az = \"$DEFAULT_AZ\"
    }
"
python3 - "$VMS/config.tf" "$REGION_ENTRY" <<'PY' || { cleanup_restore; die "config.tf edit failed"; }
import sys, re
path, entry = sys.argv[1], sys.argv[2]
src = open(path).read()
m = re.search(r'^  regions = \{$', src, re.M)
if not m:
    sys.exit("could not find 'regions = {' in config.tf")
# Walk to the matching close: nested closes are indented deeper than two spaces.
i, depth = m.end(), 1
while i < len(src) and depth:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
if depth:
    sys.exit("unbalanced braces in local.regions")
close = src.rfind('\n', 0, i - 1) + 1   # start of the line holding the final '}'
open(path, 'w').write(src[:close] + entry.lstrip('\n') + src[close:])
PY
ok "config.tf — local.regions[\"$REGION\"]"
say "      that is the whole edit: main.tf's for_each picks it up, and there is no"
say "      provider, module, output or test fixture to add."

# ---------------------------------------------------------------------------
step "Verifying"
( cd "$VMS" && terraform fmt ) >/dev/null 2>&1 && ok "terraform fmt" \
  || { cleanup_restore; die "terraform fmt failed"; }

# No new module *block* is added any more, so "Module not installed" cannot occur —
# but a fresh module instance still needs the provider cache present, and running
# init keeps this working if someone clones and runs the wizard before any other
# command. `-backend=false` skips backend setup: verified to leave
# .terraform/terraform.tfstate byte-identical, so a later `plan` still reaches the
# real remote state.
if ! ( cd "$VMS" && terraform init -backend=false -input=false -no-color >/dev/null 2>&1 ); then
  ( cd "$VMS" && terraform init -backend=false -input=false -no-color ) 2>&1 | tail -12 | sed 's/^/      /'
  cleanup_restore; die "terraform init failed — nothing was kept"
fi
ok "terraform init (backend untouched)"

if ! ( cd "$VMS" && terraform validate -no-color >/dev/null 2>&1 ); then
  ( cd "$VMS" && terraform validate -no-color ) 2>&1 | sed 's/^/      /'
  cleanup_restore; die "terraform validate failed — nothing was kept"
fi
ok "terraform validate"

# The tests need no per-region fixtures any more, so this is a regression check on
# the region entry itself rather than on generated test scaffolding.
TEST_FILES=$(find "$VMS/tests" -name '*.tftest.hcl' -type f 2>/dev/null | wc -l)
if [ "$TEST_FILES" -eq 0 ]; then
  # Not a failure: a thin tenant may legitimately carry no test file, and the
  # module interface is gated upstream by `make release`. What must not happen
  # is a checkmark. `terraform test` with zero test files prints
  # "Success! 0 passed, 0 failed." and exits 0 — measured — so reading only $?
  # here would print "✓ terraform test" having run nothing.
  warn "no local tests under vms/tests — the module interface is gated upstream"
elif ! ( cd "$VMS" && terraform test -no-color >/dev/null 2>&1 ); then
  ( cd "$VMS" && terraform test -no-color ) 2>&1 | tail -25 | sed 's/^/      /'
  cleanup_restore; die "terraform test failed — nothing was kept"
else
  ok "terraform test ($TEST_FILES file(s))"
fi
rm -rf "$BACKUP"

# ---------------------------------------------------------------------------
step "Done — $REGION is wired. Nothing exists in AWS yet."
say ""
say "  1. Read the diff:            git -C $ROOT diff vms/config.tf"
say "  2. Place two secrets in $REGION, by hand, as SecureString on the default"
say "     alias/aws/ssm key (a CMK needs a kms:Decrypt grant that does not exist):"
say "       - the CINC validator key   (vms/README.md in the platform repo, or"
say "                                    .terraform/modules/ec2/vms/README.md here)"
say "       - the Grafana Loki token   (docs/runbook.md §7 in the platform repo, or"
say "                                    CLAUDE.md §Per-region secrets here;"
say "                                    skip if log_shipping = false)"
say "     Terraform never creates these; it only grants access to the name."
say "  3. Prove it:                 cd cinc && make preflight"
say "     It reads the region list from local.regions, so $REGION is now checked"
say "     automatically — including that the Loki token authenticates there."
say "  4. Add a VM under \"$REGION\" in vms/instances.auto.tfvars, plus its key in"
say "     ssh_key_pairs, then: cd vms && terraform plan"
say ""
say "  Note that the next apply creates ~12 resources for $REGION even with no VMs"
say "  in it — the network baseline is per-region and not conditional on instances:"
say "  a VPC, one subnet per AZ, an internet gateway, a route table with its"
say "  associations, and the security group with its three rules. That is expected,"
say "  not a bug in this wizard."
say ""
warn "Do not apply before step 3 passes: a missing parameter applies cleanly and"
warn "then produces a VM that converges green and ships no logs."
