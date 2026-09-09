locals {
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
# reaches IMDS, and IMDS carries the bootstrap role, which reads the validator
# key — the instance profile is a secret from the first second, so there is
# no stage at which a restore is safe. Diagnosis goes through the serial
# console instead: the handler below copies this log there, and the operator
# reads it with `aws ec2 get-console-output --latest` and replaces the instance.

bootstrap_failed() {
  rm -f /etc/cinc/validation.pem
  {
    echo "BOOTSTRAP FAILED: validation key removed; developer sudo stays revoked. Log follows."
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
#    them and do not duplicate. Appends, in order, onto the boot-empty OUTPUT
#    chain — positional -I would fail when the EIC rule is skipped. This
#    script's own IMDS calls run as root, which stays allowed.
iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT
eic_uid=$(id -u ec2-instance-connect 2>/dev/null || true)
if [ -n "$eic_uid" ]; then
  iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner "$eic_uid" -j ACCEPT
else
  echo "WARNING: no ec2-instance-connect user in this image; EIC admin SSH waits for the first converge"
fi
iptables -A OUTPUT -d 169.254.169.254 -j DROP

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
# The name checks are permissive on purpose: policy_name has no shape
# validation in variables.tf, so a strict character class here could brick a
# legitimately named VM at first boot. What is rejected is the error-body
# signature — empty, whitespace, or markup — plus the metacharacters of a
# double-quoted Ruby string (" \ #): both values land inside double quotes in
# client.rb below, and a principal holding ec2:CreateTags must not get code
# evaluated by cinc-client as root out of it.
case "$POLICY_GROUP" in
  staging|production) ;;
  *) POLICY_GROUP="production" ;;
esac

case "$INSTANCE_NAME" in
  ''|*[[:space:]]*|*'<'*|*'"'*|*'\'*|*'#'*)
    echo "FATAL: could not read the Name tag from IMDS (got: '$INSTANCE_NAME')"
    echo "A VM with no usable name must not register with the CINC server."
    # An explicit exit does not fire the ERR trap, so any deliberate abort
    # between `trap ... ERR` and `trap - ERR` must call bootstrap_failed itself.
    bootstrap_failed; exit 1 ;;
esac
case "$POLICY_NAME" in
  ''|*[[:space:]]*|*'<'*|*'"'*|*'\'*|*'#'*)
    echo "FATAL: could not read the PolicyName tag from IMDS (got: '$POLICY_NAME')"
    bootstrap_failed; exit 1 ;;
esac

# Set hostname
hostnamectl set-hostname "$INSTANCE_NAME"


# Install AWS CLI v2 (skip if already installed — survives cloud-init re-runs)
if ! command -v aws >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq unzip
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
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
curl -fsSL "https://downloads.cinc.sh/files/stable/cinc/$${CINC_VERSION}/ubuntu/24.04/cinc_$${CINC_VERSION}-1_amd64.deb" \
  -o /tmp/cinc.deb
echo "$${CINC_SHA256}  /tmp/cinc.deb" | sha256sum -c -
dpkg -i /tmp/cinc.deb
rm -f /tmp/cinc.deb

# Fetch CINC validation key from SSM
mkdir -p /etc/cinc

install -m 0600 /dev/null /etc/cinc/validation.pem
# IAM data-plane propagation is eventually consistent: depends_on ordered the
# role policy's creation, but it can still deny for up to ~a minute on first
# boot. Retry the one call that depends on it; every other failure in this
# script still aborts on sight.
attempt=0
until aws ssm get-parameter \
  --name "${var.cinc_ssm_parameter_name}" \
  --with-decryption \
  --region "${var.aws_region}" \
  --cli-connect-timeout 5 \
  --cli-read-timeout 15 \
  --query 'Parameter.Value' \
  --output text > /etc/cinc/validation.pem; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 6 ]; then
    echo "FATAL: could not read the validation key after $attempt attempts"
    bootstrap_failed; exit 1
  fi
  delay=$((1 << attempt))   # 2 4 8 16 32
  echo "WARNING: validation-key read failed; retry $attempt in $${delay}s (IAM propagation)"
  sleep "$delay"
done
chmod 600 /etc/cinc/validation.pem

# Configure CINC client
install -m 0600 /dev/null /etc/cinc/client.rb
cat > /etc/cinc/client.rb << CINC_CONFIG
chef_server_url        "${var.cinc_server_url}"
node_name              "$INSTANCE_NAME"
validation_client_name "${basename(var.cinc_server_url)}-validator"
validation_key         "/etc/cinc/validation.pem"
policy_name            "$POLICY_NAME"
policy_group           "$POLICY_GROUP"
CINC_CONFIG

# Run initial converge
install -m 0600 /dev/null /var/log/cinc-first-run.log
cinc-client --once > /var/log/cinc-first-run.log 2>&1 || { echo "FATAL: first converge failed; the converge log is /var/log/cinc-first-run.log on the instance and is not mirrored to the console"; bootstrap_failed; exit 1; }

# Remove validation key — no longer needed after registration
rm -f /etc/cinc/validation.pem
trap - ERR

echo "CINC agent bootstrap complete for $INSTANCE_NAME"
EOF
}
