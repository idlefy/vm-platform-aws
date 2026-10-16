locals {
  # One script for every instance in the region; what differs per VM travels
  # as EC2 tags (Name, PolicyName, PolicyGroup) and is read here, once.
  #
  # main.tf ships it gzip-compressed (base64gzip), and cloud-init decompresses
  # it. Plain, it no longer fits EC2's 16 KB user-data limit: it carries
  # dev-vm-policy-fetch, which must be on disk before the first converge can
  # deliver anything. The tests assert on this plain form.
  user_data_script = <<-EOF
#!/bin/bash
set -euo pipefail

# The log is born 0600: it will hold this script's output and the converge log
# path below — and sudoers.rb strips ubuntu from adm precisely so converge
# output is not developer-readable. A 0644 copy in /var/log walks around that.
install -m 0600 /dev/null /var/log/user-data.log
exec > /var/log/user-data.log 2>&1

# ---- close the first-boot window --------------------------------------------
# Until base::sudoers and base::imds first converge, the cloud image grants
# ubuntu NOPASSWD sudo and leaves IMDS open — and the developer holds this
# VM's key pair. So the grant goes first, and it never comes back: a failed
# bootstrap FAILS CLOSED. Restoring it "for diagnosis" (what this script did
# before the first external review) handed the developer root, and root
# reaches IMDS, and IMDS carries the bootstrap role, which reads the Loki
# token and this VM's access config — the instance profile is a secret from
# the first second, so there is no stage at which a restore is safe. Diagnosis
# goes through the serial console instead: the handler below copies this log
# there, and the operator reads it with `aws ec2 get-console-output --latest`
# and replaces the instance.

bootstrap_failed() {
  {
    echo "BOOTSTRAP FAILED: developer sudo stays revoked. Log follows."
    tail -c 56000 /var/log/user-data.log
  } > /dev/console 2>/dev/null || true
}
trap bootstrap_failed ERR

# 1. Drop cloud-init's sudo grant. The missing-file case is expected (a re-run
#    after a successful bootstrap already removed it, or base::sudoers owns the
#    path now).
rm -f /etc/sudoers.d/90-cloud-init-users

# 2. Block IMDS for everyone but root (and EIC when present): the same three
#    rules base::imds installs, spelled so its iptables-save guards recognise
#    them and do not duplicate. Appends, in order, onto the OUTPUT chain
#    (boot-empty on stock Ubuntu) — positional -I would fail when the EIC rule
#    is skipped. This
#    script's own IMDS calls run as root, which stays allowed.
#
#    Each append is guarded by -C: a prebuilt image carries base::imds's
#    rules.v4, netfilter-persistent restores it before this runs, and a bare -A
#    would stack a second copy of every rule on every boot from that image.
imds_rule() { iptables -C OUTPUT "$@" 2>/dev/null || iptables -A OUTPUT "$@"; }
imds_rule -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT
eic_uid=$(id -u ec2-instance-connect 2>/dev/null || true)
if [ -n "$eic_uid" ]; then
  imds_rule -d 169.254.169.254 -m owner --uid-owner "$eic_uid" -j ACCEPT
else
  echo "WARNING: no ec2-instance-connect user in this image; EIC admin SSH waits for the first converge"
fi
imds_rule -d 169.254.169.254 -j DROP

# 3. Everything this script downloads goes here, never /tmp. The developer can
#    SSH in during first boot, and a predictable /tmp path is one they can
#    swap between a check and its use — a sha256-checked .deb replaced before
#    dpkg -i, or an unzipped installer replaced before it runs as root.
install -d -m 0700 /run/dev-vm
STAGE=$(mktemp -d /run/dev-vm/bootstrap.XXXXXX)

# Get instance metadata from EC2 tags.
#
# --max-time on every call: IMDS is link-local and normally answers instantly,
# but there is no timeout by default, so a request that hangs hangs cloud-init
# with it — and a VM stuck here looks identical to one still booting.
TOKEN=$(curl -sf --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
INSTANCE_NAME=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/tags/instance/Name" || true)
POLICY_NAME=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/tags/instance/PolicyName" || true)
POLICY_GROUP=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/tags/instance/PolicyGroup" || true)

# -f turns an IMDS 404/401 into an empty string instead of an HTTP error body
# with exit 0. The `|| true` keeps set -e from dying INSIDE the assignment —
# the diagnostics below are the useful failure, not a silent exit at the curl.
#
# These are the tags' only reading, ever: they land in policy.conf below and
# nothing re-reads them, so ec2:CreateTags cannot move a running VM between
# policy groups. Each is held to the exact shape dev-vm-policy-fetch accepts —
# they end up in S3 keys and in a double-quoted Ruby string in the client
# config — and anything else aborts here, by name.
#
# An explicit exit does not fire the ERR trap, so every deliberate abort
# between `trap ... ERR` and `trap - ERR` calls bootstrap_failed itself.
if ! [[ $INSTANCE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
  echo "FATAL: could not read the Name tag from IMDS (got: '$INSTANCE_NAME')"
  bootstrap_failed; exit 1
fi
if ! [[ $POLICY_NAME =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
  echo "FATAL: could not read the PolicyName tag from IMDS (got: '$POLICY_NAME')"
  bootstrap_failed; exit 1
fi
# Fail closed. This used to fall back to production, which turned a
# mistyped staging VM into a production one.
case "$POLICY_GROUP" in
  staging|production) ;;
  *)
    echo "FATAL: the PolicyGroup tag must be staging or production (got: '$POLICY_GROUP')"
    bootstrap_failed; exit 1 ;;
esac

# Set hostname
hostnamectl set-hostname "$INSTANCE_NAME"

# Install AWS CLI v2 (skip if already installed — survives cloud-init re-runs)
if ! command -v aws >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq unzip
  curl -fsS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$STAGE/awscliv2.zip"
  unzip -q "$STAGE/awscliv2.zip" -d "$STAGE"
  "$STAGE/aws/install"
fi

# Install CINC agent (pinned version with SHA256 verification)
#
# The `ubuntu/24.04` path matches the VM's own release (see `ami_name_pattern`
# in ../variables.tf) — CINC publishes a native build for it, so there is no
# version skew here. It was not always so: the VMs ran 26.04 until 2026-08-05
# and installed this same 24.04 package because CINC publishes no 26.04 build at
# all (checked through 19.3.14). If you ever move the AMI forward again, check
# https://downloads.cinc.sh/files/stable/cinc/ first — a release with no build
# there produces a 404 here and a VM that never converges.
#
# SHA256 comes from the .deb.metadata.json sidecar next to the package.
CINC_VERSION="19.3.14"
CINC_SHA256="c710cc8bf953fa56b7a4b0b726d9fcb9cb5bad2dc8caec4eaa439c4626f9aebf"
# Skipped when the pinned version is already installed: an image built from this
# script has it baked in, and a VM launched from that image should not need the
# download (or the network path to it) to boot.
# Status-Abbrev is three characters ("ii "), so "ii" plus the separator is two
# spaces: a half-installed package is not "already installed".
if [ "$(dpkg-query -W -f='$${db:Status-Abbrev} $${Version}' cinc 2>/dev/null || true)" = "ii  $${CINC_VERSION}-1" ]; then
  echo "cinc $${CINC_VERSION} already installed (prebuilt image)"
else
  curl -fsSL "https://downloads.cinc.sh/files/stable/cinc/$${CINC_VERSION}/ubuntu/24.04/cinc_$${CINC_VERSION}-1_amd64.deb" \
    -o "$STAGE/cinc.deb"
  echo "$${CINC_SHA256}  $STAGE/cinc.deb" | sha256sum -c -
  dpkg -i "$STAGE/cinc.deb"
fi

# ---- policy delivery ----------------------------------------------------------
# No CINC server: dev-vm-policy-fetch reads a signed envelope from the tenant's
# bucket, verifies it against the signers below, and converges in local mode.
# Design: docs/design/serverless-policy-delivery.md.
install -d -m 0755 /etc/dev-vm

# Written once, here; nothing rewrites it. Values from Terraform are held to
# their shapes by ../variables.tf, the tag values by the checks above.
install -m 0644 /dev/null /etc/dev-vm/policy.conf
cat > /etc/dev-vm/policy.conf <<POLICY_CONF
POLICY_BUCKET=${var.policy_bucket}
POLICY_BUCKET_OWNER=${var.policy_bucket_owner}
POLICY_BUCKET_REGION=${var.policy_bucket_region}
POLICY_PREFIX=${var.policy_prefix}
FLEET_ID=${var.policy_bucket}/${var.policy_prefix}
POLICY_NAME=$POLICY_NAME
POLICY_GROUP=$POLICY_GROUP
NODE_NAME=$INSTANCE_NAME
POLICY_MIN_SERIAL=${var.policy_min_serial}
POLICY_CONF

# The first trust set. From the first converge on, base::cinc_client owns this
# file and writes the policyfile's base.policy.signers into it.
install -m 0644 /dev/null /etc/dev-vm/policy-signers
cat > /etc/dev-vm/policy-signers <<'POLICY_SIGNERS'
${join("\n", var.policy_signers)}
POLICY_SIGNERS

# The delivery script — byte-identical to the cookbook's copy
# (test/test-fetch-sync.sh) — and the launcher, which only this script writes.
install -m 0700 /dev/null /usr/local/sbin/dev-vm-policy-fetch
cat > /usr/local/sbin/dev-vm-policy-fetch <<'DEV_VM_POLICY_FETCH'
${file("${path.module}/files/dev-vm-policy-fetch")}
DEV_VM_POLICY_FETCH
install -m 0700 /dev/null /usr/local/sbin/dev-vm-policy-run
cat > /usr/local/sbin/dev-vm-policy-run <<'DEV_VM_POLICY_RUN'
${file("${path.module}/files/dev-vm-policy-run")}
DEV_VM_POLICY_RUN

# Run the first converge. Exit 0 is the only success: a rejected envelope (12)
# or a failed converge (13) leaves the VM without its hardening, so it fails
# closed at once.
#
# 14 — nothing delivered and nothing to fall back to — is retried. IAM's data
# plane is eventually consistent: depends_on in main.tf orders the role
# policy's creation, but the bootstrap role's s3:GetObject can still be denied
# for up to about a minute on first boot. The script's own retries cover
# seconds, not that.
install -m 0600 /dev/null /var/log/cinc-first-run.log
attempt=0
until /usr/local/sbin/dev-vm-policy-run >> /var/log/cinc-first-run.log 2>&1; do
  rc=$?
  attempt=$((attempt + 1))
  if [ "$rc" != 14 ] || [ "$attempt" -ge 6 ]; then
    echo "FATAL: first converge failed (exit $rc, attempt $attempt); its last 40 lines follow, the rest is /var/log/cinc-first-run.log on the instance"
    tail -n 40 /var/log/cinc-first-run.log
    bootstrap_failed; exit 1
  fi
  delay=$((1 << attempt))   # 2 4 8 16 32
  echo "WARNING: nothing delivered yet (IAM propagation?); retry $attempt in $${delay}s"
  sleep "$delay"
done

rm -rf "$STAGE"
trap - ERR

echo "Policy bootstrap complete for $INSTANCE_NAME ($POLICY_NAME@$POLICY_GROUP)"
EOF
}
