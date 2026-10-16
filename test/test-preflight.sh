#!/usr/bin/env bash
# scripts/preflight.sh against shimmed terraform/aws/curl. Nothing here
# touches AWS. Each scenario builds a throwaway tenant tree (vms/ + the
# policyfile), points PATH at the shims, runs preflight, and greps its output.
#
# The terraform shim answers `console` with a canned jsonencode() result — a
# JSON string, double-encoded exactly as the real console prints it.
#
# policy-publish.sh is a shim too: its `show` mode is tested against real
# envelopes in test-policy-publish.sh, and what is tested here is what
# preflight makes of each answer.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/vms/.terraform" "$T/cinc/policyfiles" "$T/scripts"
cp "$ROOT/scripts/preflight.sh" "$T/scripts/preflight.sh"
# The migrated-root marker preflight looks for before blaming the configuration.
printf 'variable "log_shipping" { type = bool }\n' > "$T/vms/variables.tf"
# The wiring line preflight greps for in vms/main.tf. Every scenario below
# needs this present to reach the checks it's testing for — the one scenario
# testing its absence writes its own main.tf and restores this afterward.
wired_main_tf() {
  printf 'module "ec2" {\n  log_shipping = var.log_shipping\n}\n' > "$T/vms/main.tf"
}
wired_main_tf

cat > "$T/bin/terraform" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  console)   cat >/dev/null; cat "$PREFLIGHT_FIXTURE" ;;
  providers) exit 0 ;;
  *)         exit 1 ;;
esac
SH
cat > "$T/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$AWS_LOG"
case "$1 $2" in
  "sts get-caller-identity")  echo 111122223333 ;;
  "s3api head-bucket")        [ -z "${HEAD_BUCKET_ERR:-}" ] || { echo "$HEAD_BUCKET_ERR" >&2; exit 254; } ;;
  "ssm describe-parameters")  echo SecureString ;;
  "ssm get-parameter")        echo not-a-real-token ;;
  "iam get-policy")           exit 0 ;;
  "ec2 describe-images")      [ -n "${IMAGE_ERR:-}" ] && { echo "$IMAGE_ERR" >&2; exit 254; }
                              echo "${IMAGE_DATE:-}" ;;
  *)                          exit 1 ;;
esac
SH
cat > "$T/bin/curl"  <<'SH'
#!/usr/bin/env bash
echo 400
SH
cat > "$T/scripts/policy-publish.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] || exit 9
env | grep -E '^(POLICY_|AWS_PROFILE=)' | sort > "$SHOW_ENV"
cp "$POLICY_SIGNERS_FILE" "$SHOW_ENV.signers"
printf '%s\n%s\n' "$SHOW_STAGING" "$SHOW_PRODUCTION"
exit "${SHOW_RC:-0}"
SH
chmod +x "$T/bin/"* "$T/scripts/policy-publish.sh"

SIGNER='ops namespaces="dev-vm-policy-staging,dev-vm-policy-production" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOps'
SIGNERS_SHA=$(printf '%s\n' "$SIGNER" | sha256sum | cut -d' ' -f1)
LOCKREV=$(printf 'lock' | sha256sum | cut -d' ' -f1)
OTHERREV=$(printf 'other' | sha256sum | cut -d' ' -f1)
printf '{"name": "dev-vm", "revision_id": "%s"}' "$LOCKREV" > "$T/cinc/policyfiles/dev-vm.lock.json"
# show_answers <staging line> <production line> — what the shim prints
show_answers() { SHOW_STAGING=$1 SHOW_PRODUCTION=$2; }
agreeing() { show_answers "staging ok 1 $LOCKREV $SIGNERS_SHA" "production ok 1 $LOCKREV $SIGNERS_SHA"; }
agreeing

# fixture <shipping:true|false> <loki:name|null> [owner] [kms] [ami_owners JSON] [ami_pattern]
# → writes the console answer. AMI owners default to Canonical, which skips the image check.
fixture() {
  python3 - "$1" "$2" "${3:-111122223333}" "${4:-}" "$SIGNER" "${5:-[\"099720109477\"]}" "${6:-ubuntu-*}" > "$T/fixture.json" <<'PY'
import json, sys
shipping = sys.argv[1] == "true"
loki = None if sys.argv[2] == "null" else sys.argv[2]
inner = json.dumps({"regions": ["eu-central-1"], "loki": loki, "shipping": shipping,
                    "profile": "p", "bundles": {},
                    "bucket": "t-policies", "owner": sys.argv[3], "bucket_region": "eu-west-1",
                    "prefix": "dev-vm-policies", "kms": sys.argv[4] or None,
                    "signers": [sys.argv[5]],
                    "ami_owners": json.loads(sys.argv[6]), "ami_pattern": sys.argv[7]})
print(json.dumps(inner))
PY
}

run_preflight() {
  : > "$T/aws.log"
  PATH="$T/bin:$PATH" PREFLIGHT_FIXTURE="$T/fixture.json" AWS_LOG="$T/aws.log" \
    SHOW_ENV="$T/show.env" SHOW_STAGING="$SHOW_STAGING" SHOW_PRODUCTION="$SHOW_PRODUCTION" \
    "$T/scripts/preflight.sh" > "$T/out" 2>&1
  echo $?
}

PF="$T/cinc/policyfiles/dev-vm.rb"

echo "== half-migrated root: main.tf never passes log_shipping to the module =="
# vms/variables.tf was copied from the new skeleton (console reads
# var.log_shipping fine) but vms/main.tf was not — the module never receives
# the flag, so it runs its own default (true) no matter what the root reports.
# console succeeding is exactly the false-green this check exists to catch.
fixture true /t/loki
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
printf 'module "ec2" {\n  # log_shipping missing — half-migrated root\n}\n' > "$T/vms/main.tf"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names vms/main.tf" "$(grep -q 'vms/main.tf does not pass log_shipping' "$T/out"; echo $?)"
wired_main_tf

echo "== the pass-through outside module \"ec2\" does not count =="
# A file-wide match would accept this: the assignment exists, but in `locals`,
# and module "ec2" still runs its own default (true).
fixture false ""
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = false
RB
printf 'locals {\n  log_shipping = var.log_shipping\n}\nmodule "ec2" {\n  environment = "x"\n}\n' > "$T/vms/main.tf"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names vms/main.tf" "$(grep -q 'vms/main.tf does not pass log_shipping' "$T/out"; echo $?)"
wired_main_tf

echo "== both on and agreeing =="
fixture true /t/loki
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "flag section says both say true" "$(grep -q 'both say true' "$T/out"; echo $?)"
check "parameter names agree" "$(grep -q "both name '/t/loki'" "$T/out"; echo $?)"
check "loki token was checked" "$(grep -q 'ssm get-parameter' "$T/aws.log"; echo $?)"

echo "== policyfile omits enabled: cookbook default applies =="
sed -i '/enabled/d' "$PF"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "says the cookbook default applies" "$(grep -q 'cookbook default true applies' "$T/out"; echo $?)"

echo "== a commented-out enabled line is not a setting =="
printf '# default[%s][%s][%s] = false\n' "'base'" "'loki'" "'enabled'" >> "$PF"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "still the cookbook default" "$(grep -q 'cookbook default true applies' "$T/out"; echo $?)"

echo "== terraform on, policyfile off: mismatch fails =="
cat > "$PF" <<'RB'
default['base']['loki']['enabled'] = false
RB
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names both values" "$(grep -q 'log_shipping=true.*enabled=false' "$T/out"; echo $?)"

echo "== both off: loki checks are skipped, and no SSM call is left =="
fixture false null
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "three skipped lines" "$([ "$(grep -c 'log shipping disabled — skipped' "$T/out")" = 3 ]; echo $?)"
check "no loki parameter lookup" "$(! grep -q 'Values=/t/loki' "$T/aws.log"; echo $?)"
check "no token fetch" "$(! grep -q 'ssm get-parameter' "$T/aws.log"; echo $?)"
check "no SSM call at all (there is no validator key)" "$(! grep -q '^ssm ' "$T/aws.log"; echo $?)"

echo "== both off but the policyfile still carries loki lines: warn, not fail =="
cat > "$PF" <<'RB'
default['base']['loki']['enabled']  = false
default['base']['loki']['url']      = 'https://l.example.com/push'
default['base']['loki']['username'] = '1'
RB
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "warns naming url" "$(grep -q 'leftover.*url' "$T/out"; echo $?)"
check "warns naming username" "$(grep -q 'leftover.*username' "$T/out"; echo $?)"

echo "== terraform off, policyfile on: reverse mismatch names the empty parameter, never calls aws for it =="
fixture false ""
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names MISMATCH" "$(grep -q 'MISMATCH' "$T/out"; echo $?)"
check "names the missing parameter" "$(grep -q 'MISSING (no loki_ssm_parameter_name' "$T/out"; echo $?)"
check "no get-parameter call for the empty name" "$(! grep -q 'ssm get-parameter' "$T/aws.log"; echo $?)"

echo "== missing policyfile is a named failure =="
fixture true /t/loki
rm -f "$PF"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names the policyfile path" "$(grep -q "$PF" "$T/out"; echo $?)"
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB

echo "== unparseable console output is a named failure, not set -u =="
echo '"{\"regions\":[\"eu-central-1\"]' > "$T/fixture.json"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "no unbound variable" "$(! grep -q 'unbound variable' "$T/out"; echo $?)"
check "blames the configuration" "$(grep -q 'configuration itself is at fault' "$T/out"; echo $?)"

echo "== a root that does not declare log_shipping is told so =="
rm "$T/vms/variables.tf"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names the skeleton" "$(grep -q 'does not declare log_shipping' "$T/out"; echo $?)"
printf 'variable "log_shipping" { type = bool }\n' > "$T/vms/variables.tf"

echo "== loki unreachable (curl 000) fails preflight =="
fixture true /t/loki
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
wired_main_tf
printf '#!/usr/bin/env bash\necho 000\nexit 28\n' > "$T/bin/curl"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names the unreachable URL" "$(grep -q 'could not reach' "$T/out"; echo $?)"

echo "== loki redirect (302) fails preflight =="
printf '#!/usr/bin/env bash\necho 302\n' > "$T/bin/curl"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names http 302" "$(grep -q 'http 302' "$T/out"; echo $?)"

echo "== loki server error (500) fails preflight =="
printf '#!/usr/bin/env bash\necho 500\n' > "$T/bin/curl"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names http 500" "$(grep -q 'http 500' "$T/out"; echo $?)"

echo "== loki 400 still passes =="
printf '#!/usr/bin/env bash\necho 400\n' > "$T/bin/curl"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "credentials accepted" "$(grep -q 'credentials accepted' "$T/out"; echo $?)"

echo "== policy delivery: everything agrees =="
fixture true /t/loki
agreeing
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "bucket checked in its own region, pinned to its owner" \
  "$(grep -q 's3api head-bucket --bucket t-policies --expected-bucket-owner 111122223333 --region eu-west-1' "$T/aws.log"; echo $?)"
check "show got the bucket from vms/" "$(grep -qx 'POLICY_BUCKET=t-policies' "$T/show.env"; echo $?)"
check "...the region" "$(grep -qx 'POLICY_BUCKET_REGION=eu-west-1' "$T/show.env"; echo $?)"
check "...and var.policy_signers" "$(grep -qxF "$SIGNER" "$T/show.env.signers"; echo $?)"
check "both groups on the lock's revision" "$(grep -q "staging and production both on ${LOCKREV:0:12}" "$T/out"; echo $?)"
check "signers agree" "$(grep -q 'var.policy_signers is the set production installs' "$T/out"; echo $?)"
check "no warnings" "$(grep -q '0 warning' "$T/out"; echo $?)"

echo "== policy delivery: promote pending =="
show_answers "staging ok 2 $LOCKREV $SIGNERS_SHA" "production ok 1 $OTHERREV $SIGNERS_SHA"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "says promote is pending" "$(grep -q "make promote' pending" "$T/out"; echo $?)"

echo "== policy delivery: production matches the lock, staging is stale =="
show_answers "staging ok 2 $OTHERREV $SIGNERS_SHA" "production ok 1 $LOCKREV $SIGNERS_SHA"
rc=$(run_preflight)
check "says do NOT promote" "$(grep -q 'do NOT promote' "$T/out"; echo $?)"

echo "== policy delivery: nothing published yet =="
show_answers "staging missing" "production missing"
rc=$(run_preflight)
check "exit 0 (a first promote must get through its own preflight)" "$([ "$rc" = 0 ]; echo $?)"
check "warns a production VM would fail closed" "$(grep -q 'production.json.*fails closed' "$T/out"; echo $?)"
check "says to push" "$(grep -q 'staging.json.*make push' "$T/out"; echo $?)"

echo "== policy delivery: an envelope that does not verify =="
show_answers "staging invalid" "production ok 1 $LOCKREV $SIGNERS_SHA"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "says it does not verify" "$(grep -q 'staging.json does not verify' "$T/out"; echo $?)"

echo "== policy delivery: a rotation in progress =="
show_answers "staging ok 2 $LOCKREV $SIGNERS_SHA" "production ok 1 $LOCKREV $(printf x | sha256sum | cut -d' ' -f1)"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "warns that a new VM fails closed until they agree" "$(grep -q 'var.policy_signers differs.*fails closed' "$T/out"; echo $?)"

echo "== policy delivery: the bucket cannot be reached =="
agreeing
rc=$(HEAD_BUCKET_ERR='An error occurred (403) when calling the HeadBucket operation: Forbidden' run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names the bucket" "$(grep -q 't-policies.*not reachable' "$T/out"; echo $?)"
rc=$(HEAD_BUCKET_ERR='An error occurred (AccessDenied) ... with an explicit deny in a service control policy' run_preflight)
check "an SCP denial names the region allowlist" "$(grep -q 'SCP.*eu-west-1' "$T/out"; echo $?)"

echo "== policy delivery: show itself fails =="
rc=$(SHOW_RC=1 run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "says it could not read the envelopes" "$(grep -q 'could not read the envelopes' "$T/out"; echo $?)"

echo "== policy delivery: a cross-account bucket or a KMS key =="
fixture true /t/loki 444455556666
rc=$(run_preflight)
check "cross-account: exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "cross-account: points at the runbook's bucket policy" "$(grep -q 'bucket policy.*runbook' "$T/out"; echo $?)"
fixture true /t/loki 111122223333 arn:aws:kms:eu-west-1:111122223333:key/k
rc=$(run_preflight)
check "kms: points at the runbook's key policy" "$(grep -q 'key policy.*runbook' "$T/out"; echo $?)"
fixture true /t/loki

echo "== fleet image: owners = self =="
fixture true /t/loki 111122223333 "" '["self"]' 'dev-vm-dev-vm-*'
agreeing
old=$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%S.000Z)
new=$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%S.000Z)
rc=$(IMAGE_DATE=$old run_preflight)
check "old image: exit 0 (a warning, not a failure)" "$([ "$rc" = 0 ]; echo $?)"
check "old image: warns older than 35 days" "$(grep -q 'older than 35 days' "$T/out"; echo $?)"
check "queried the owner self with the pattern and Terraform's HVM filter" \
  "$(grep -q 'ec2 describe-images --region eu-central-1 --owners self --filters Name=name,Values=dev-vm-dev-vm-\* Name=virtualization-type,Values=hvm' "$T/aws.log"; echo $?)"
rc=$(IMAGE_DATE=$new run_preflight)
check "fresh image: exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "fresh image: no age warning" "$(! grep -q 'older than 35 days' "$T/out"; echo $?)"
check "fresh image: says so" "$(grep -q 'eu-central-1 — image from' "$T/out"; echo $?)"
rc=$(IMAGE_DATE=None run_preflight)
check "no image: exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "no image: names the region and the plan failure" \
  "$(grep -q 'eu-central-1 — no image matches dev-vm-dev-vm-\*.*terraform plan will fail' "$T/out"; echo $?)"
rc=$(IMAGE_DATE= run_preflight)
check "empty answer is also no image" "$([ "$rc" = 1 ]; echo $?)"
rc=$(IMAGE_ERR="An error occurred (UnauthorizedOperation) when calling the DescribeImages operation" run_preflight)
check "query error: exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "query error: says the query failed, with AWS's reason" \
  "$(grep -q 'eu-central-1 — could not query images.*UnauthorizedOperation' "$T/out"; echo $?)"
check "query error: does not claim there is no image" "$(! grep -q 'no image matches' "$T/out"; echo $?)"

echo "== fleet image: self among other owners queries the whole owner set =="
fixture true /t/loki 111122223333 "" '["self", "123456789012"]' 'dev-vm-dev-vm-*'
agreeing
: > "$T/aws.log"
rc=$(IMAGE_DATE=$new run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "queried the same owners Terraform searches" \
  "$(grep -q 'ec2 describe-images --region eu-central-1 --owners self 123456789012 ' "$T/aws.log"; echo $?)"

echo "== fleet image: Canonical owner makes no describe-images call =="
fixture true /t/loki 111122223333 "" '["099720109477"]' 'dev-vm-dev-vm-*'
rc=$(IMAGE_DATE=$old run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "no describe-images call" "$(! grep -q 'describe-images' "$T/aws.log"; echo $?)"
fixture true /t/loki

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
