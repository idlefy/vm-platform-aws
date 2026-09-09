#!/usr/bin/env bash
# Functional test for the aws-vm-credentials broker.
#
# Runs with no AWS account: `aws` and `sleep` are stubbed on PATH, `jq` is real.
# Run via `make test-broker` from the cinc/ directory.
#
# Not covered here (needs root, verified on a real VM in the plan's Task 7):
# chown to root:<gid>, and the 0750 root:ubuntu ownership of the output directory.
#
# The output-directory guard IS covered, because it asserts "the writer owns this
# directory and nobody else can write to it" rather than "root owns it" — which
# holds unprivileged with the test user as owner.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cookbooks/base/files/default/aws-vm-credentials"
PASS=0
FAIL=0

setup() {
  WORK=$(mktemp -d)
  STUB="$WORK/bin"
  OUT="$WORK/out"
  mkdir -p "$STUB" "$OUT"
  # Mirror what systemd-tmpfiles creates on the VM (0750). Without this the mode
  # depends on the ambient umask — a umask of 002 yields 0775, which the broker's
  # output-directory guard correctly refuses, and every later test would fail for
  # a reason that has nothing to do with what it is testing.
  chmod 0750 "$OUT"

  cat > "$STUB/aws" <<'STUBEOF'
#!/usr/bin/env bash
# Record the full argv of every call. Without this the suite passes even if a
# future edit drops --source-identity (which the identity role's trust policy
# requires via StringEquals sts:SourceIdentity, so every AssumeRole would fail),
# renames the session (which breaks CloudTrail attribution), or raises
# --duration-seconds above 3600 (which AWS rejects outright under role chaining).
# All three are load-bearing and all three are invisible to a dispatch on "$1 $2".
printf '%s\n' "$*" >> "${AWS_VM_STUB_ARGS:-/dev/null}"
case "$1 $2" in
  "ssm get-parameter")
    if [ -n "${STUB_PARAM_FAIL:-}" ]; then
      echo "ParameterNotFound" >&2; exit 254
    fi
    printf '%s' "$STUB_PARAM_JSON"
    ;;
  "sts assume-role")
    if [ -n "${STUB_ASSUME_FAIL:-}" ]; then
      echo "AccessDenied: not authorized" >&2; exit 254
    fi
    printf '%s' "$STUB_CREDS_JSON"
    ;;
  *)
    echo "unexpected aws call: $*" >&2; exit 99
    ;;
esac
STUBEOF

  # Keeps the retry path from actually sleeping 50 seconds.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sleep"
  chmod +x "$STUB/aws" "$STUB/sleep"

  cat > "$WORK/aws-access.env" <<'ENVEOF'
VM_NAME=devbox
REGION=eu-north-1
UBUNTU_GID=1000
ENVEOF

  export STUB_PARAM_JSON='{"identity_role_arn":"arn:aws:iam::111122223333:role/dev-vm-id-devbox-eu-north-1","session_name":"devbox","region":"eu-north-1"}'
  export STUB_CREDS_JSON='{"Credentials":{"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"secret123","SessionToken":"token456"}}'
  unset STUB_PARAM_FAIL STUB_ASSUME_FAIL
}

teardown() { rm -rf "$WORK"; }

run_broker() {
  # STUB_* are already exported by setup() and by individual tests, so they are
  # inherited. Only PATH and the three override paths need setting here.
  PATH="$STUB:$PATH" \
  AWS_VM_ENV_FILE="$WORK/aws-access.env" \
  AWS_VM_OUT_DIR="$OUT" \
  AWS_VM_STUB_ARGS="$WORK/stub-args" \
  bash "$SCRIPT"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$3', got '$2')"; FAIL=$((FAIL + 1))
  fi
}

echo "== missing env file exits 0 and writes nothing =="
setup
rm -f "$WORK/aws-access.env"
run_broker >/dev/null 2>&1; rc=$?
check "exit code" "$rc" "0"
check "no credentials file" "$([ -e "$OUT/credentials" ] && echo yes || echo no)" "no"
teardown

echo "== unreadable SSM parameter exits 0 and leaves an existing file alone =="
setup
echo "PREVIOUS" > "$OUT/credentials"
export STUB_PARAM_FAIL=1
run_broker >/dev/null 2>&1; rc=$?
check "exit code" "$rc" "0"
check "previous file intact" "$(cat "$OUT/credentials")" "PREVIOUS"
teardown

echo "== happy path publishes a credentials file =="
setup
run_broker >/dev/null 2>&1; rc=$?
check "exit code" "$rc" "0"
check "default profile header" "$(head -1 "$OUT/credentials")" "[default]"
check "access key line" "$(grep -c '^aws_access_key_id = ASIAEXAMPLE$' "$OUT/credentials")" "1"
check "secret line" "$(grep -c '^aws_secret_access_key = secret123$' "$OUT/credentials")" "1"
check "token line" "$(grep -c '^aws_session_token = token456$' "$OUT/credentials")" "1"
check "file mode" "$(stat -c '%a' "$OUT/credentials")" "640"
check "no temp files left" "$(find "$OUT" \( -name '.credentials.*' -o -name '.stderr.*' \) | wc -l)" "0"
# The three AssumeRole arguments the design depends on. Asserted by substring
# rather than by exact argv so adding an unrelated flag does not break the test.
assume_args=$(grep '^sts assume-role' "$WORK/stub-args")
check "source identity is set" "$(printf '%s' "$assume_args" | grep -c -- '--source-identity devbox')" "1"
check "session name is the VM name" "$(printf '%s' "$assume_args" | grep -c -- '--role-session-name devbox')" "1"
check "duration is the chaining cap" "$(printf '%s' "$assume_args" | grep -c -- '--duration-seconds 3600')" "1"
teardown

echo "== assume-role failure exits non-zero and leaves an existing file alone =="
setup
echo "PREVIOUS" > "$OUT/credentials"
export STUB_ASSUME_FAIL=1
run_broker >/dev/null 2>&1; rc=$?
check "exit code is 1" "$rc" "1"
check "previous file intact" "$(cat "$OUT/credentials")" "PREVIOUS"
check "no temp files left" "$(find "$OUT" \( -name '.credentials.*' -o -name '.stderr.*' \) | wc -l)" "0"
teardown

echo "== an incomplete credential set is rejected without clobbering =="
setup
echo "PREVIOUS" > "$OUT/credentials"
# Parses fine, missing SecretAccessKey and SessionToken. jq's `"x = " + null`
# yields "x = " and exits 0, so without an explicit check this would publish a
# file with an empty secret key.
export STUB_CREDS_JSON='{"Credentials":{"AccessKeyId":"ASIAEXAMPLE"}}'
run_broker >/dev/null 2>&1; rc=$?
check "exit code is 1" "$rc" "1"
check "previous file intact" "$(cat "$OUT/credentials")" "PREVIOUS"
check "no temp files left" "$(find "$OUT" \( -name '.credentials.*' -o -name '.stderr.*' \) | wc -l)" "0"
teardown

echo "== a group-writable output directory is refused =="
setup
echo "PREVIOUS" > "$OUT/credentials"
# The /dev/shm boot race: if the developer creates the directory before
# systemd-tmpfiles does, they own it and can swap what root publishes into it.
chmod 0775 "$OUT"
run_broker >/dev/null 2>&1; rc=$?
check "exit code is 1" "$rc" "1"
check "previous file intact" "$(cat "$OUT/credentials")" "PREVIOUS"
check "no aws call was made" "$([ -e "$WORK/stub-args" ] && echo yes || echo no)" "no"
teardown

echo "== a symlinked output directory is refused =="
setup
mkdir -p "$WORK/elsewhere"
rm -rf "$OUT"
ln -s "$WORK/elsewhere" "$OUT"
run_broker >/dev/null 2>&1; rc=$?
check "exit code is 1" "$rc" "1"
check "nothing published through the link" "$([ -e "$WORK/elsewhere/credentials" ] && echo yes || echo no)" "no"
check "no aws call was made" "$([ -e "$WORK/stub-args" ] && echo yes || echo no)" "no"
teardown

echo "== a missing output directory is refused =="
setup
rm -rf "$OUT"
run_broker >/dev/null 2>&1; rc=$?
check "exit code is 1" "$rc" "1"
check "directory not created" "$([ -e "$OUT" ] && echo yes || echo no)" "no"
teardown

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
