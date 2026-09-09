#!/usr/bin/env bash
# Functional test for dev-vm-loki-token.
#
# Runs with no AWS account: `aws` and `systemctl` are stubbed on PATH.
# Run via `make test-loki-token` from the cinc/ directory.
#
# Not covered here (needs root, verified on a real VM in Task 7): the chown to
# root:alloy. The script skips chown when not running as uid 0, so the mode
# assertions below still hold unprivileged.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cookbooks/base/files/default/dev-vm-loki-token"
PASS=0
FAIL=0

setup() {
  WORK=$(mktemp -d)
  STUB="$WORK/bin"
  mkdir -p "$STUB"
  DEST="$WORK/loki-token"
  SYSTEMCTL_LOG="$WORK/systemctl.log"

  cat > "$STUB/aws" <<'STUBEOF'
#!/usr/bin/env bash
# Record the full argv of every call. Without this the suite passes even if a
# future edit drops --with-decryption, which on a SecureString returns the KMS
# ciphertext: the script would publish ciphertext as the token, and Alloy would
# 401 forever. Nothing detects that from outside — the VM's own 401s cannot be
# shipped, and absence alerting is deliberately absent (Idlefy makes a silent VM
# normal; see the spec). This suite is the only guard. Same for a wrong --name or
# --region. All three are invisible to assertions on artefacts alone, which is
# why test-aws-vm-credentials.sh records argv too.
printf '%s\n' "$*" >> "${LOKI_STUB_ARGS:-/dev/null}"
if [ -n "${STUB_SSM_FAIL:-}" ]; then
  echo "ParameterNotFound" >&2; exit 254
fi
printf '%s\n' "${STUB_TOKEN_VALUE:-}"
STUBEOF

  cat > "$STUB/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
STUBEOF

  chmod +x "$STUB/aws" "$STUB/systemctl"
  STUB_ARGS="$WORK/stub-args"
  export SYSTEMCTL_LOG
  export LOKI_STUB_ARGS="$STUB_ARGS"
  : > "$SYSTEMCTL_LOG"
  : > "$STUB_ARGS"
  PATH="$STUB:$PATH"
}

teardown() { rm -rf "$WORK"; }

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    echo "  PASS: $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"; FAIL=$((FAIL + 1))
  fi
}

run() { LOKI_TOKEN_DEST="$DEST" "$SCRIPT" us-east-1 /developer-vms/observability/loki-token; }

echo "== writes the token at 0640 =="
setup
STUB_TOKEN_VALUE="glc_secret_one" run >"$WORK/out" 2>"$WORK/err"
check "exit 0" "$([ $? -eq 0 ] && echo 0 || echo 1)"
check "content matches" "$([ "$(cat "$DEST")" = "glc_secret_one" ] && echo 0 || echo 1)"
check "mode 0640" "$([ "$(stat -c '%a' "$DEST")" = "640" ] && echo 0 || echo 1)"
check "restart requested" "$(grep -q 'try-restart alloy.service' "$SYSTEMCTL_LOG" && echo 0 || echo 1)"
check "token not on stdout" "$([ ! -s "$WORK/out" ] && echo 0 || echo 1)"
check "token not on stderr" "$(! grep -q 'glc_secret_one' "$WORK/err" && echo 0 || echo 1)"
check "asks for decryption" "$(grep -q -- '--with-decryption' "$STUB_ARGS" && echo 0 || echo 1)"
check "asks for the right parameter" "$(grep -q -- '--name /developer-vms/observability/loki-token' "$STUB_ARGS" && echo 0 || echo 1)"
check "asks in the right region" "$(grep -q -- '--region us-east-1' "$STUB_ARGS" && echo 0 || echo 1)"
teardown

echo "== unchanged value does not restart alloy =="
setup
STUB_TOKEN_VALUE="glc_secret_one" run >/dev/null 2>&1
: > "$SYSTEMCTL_LOG"
# An admin (or a stray process) could chmod this file between converges; no Chef
# resource manages it, so the script itself is the only thing that can put the
# mode back. Without this mutation the "re-assert mode on the unchanged path"
# branch in the script is exercised but never actually checked.
chmod 0644 "$DEST"
STUB_TOKEN_VALUE="glc_secret_one" run >/dev/null 2>&1
check "no restart on second run" "$([ ! -s "$SYSTEMCTL_LOG" ] && echo 0 || echo 1)"
check "mode restored to 0640" "$([ "$(stat -c '%a' "$DEST")" = "640" ] && echo 0 || echo 1)"
teardown

echo "== rotated value rewrites and restarts =="
setup
STUB_TOKEN_VALUE="glc_secret_one" run >/dev/null 2>&1
: > "$SYSTEMCTL_LOG"
STUB_TOKEN_VALUE="glc_secret_two" run >/dev/null 2>&1
check "content rotated" "$([ "$(cat "$DEST")" = "glc_secret_two" ] && echo 0 || echo 1)"
check "restart requested" "$(grep -q 'try-restart alloy.service' "$SYSTEMCTL_LOG" && echo 0 || echo 1)"
teardown

echo "== fetch failure preserves the existing token =="
setup
STUB_TOKEN_VALUE="glc_secret_one" run >/dev/null 2>&1
: > "$SYSTEMCTL_LOG"
STUB_SSM_FAIL=1 run >"$WORK/out" 2>"$WORK/err"
check "exit 10" "$([ $? -eq 10 ] && echo 0 || echo 1)"
check "existing token intact" "$([ "$(cat "$DEST")" = "glc_secret_one" ] && echo 0 || echo 1)"
check "no restart" "$([ ! -s "$SYSTEMCTL_LOG" ] && echo 0 || echo 1)"
check "warns on stderr" "$(grep -qi 'warn' "$WORK/err" && echo 0 || echo 1)"
check "no temp files" "$([ "$(find "$WORK" -maxdepth 1 -name '.loki-token*' | wc -l)" -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== fetch failure with no existing token does not create one =="
setup
STUB_SSM_FAIL=1 run >/dev/null 2>"$WORK/err"
check "exit 10" "$([ $? -eq 10 ] && echo 0 || echo 1)"
check "no file created" "$([ ! -e "$DEST" ] && echo 0 || echo 1)"
check "no temp files" "$([ "$(find "$WORK" -maxdepth 1 -name '.loki-token*' | wc -l)" -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== empty parameter value is a failure, not a valid token =="
setup
STUB_TOKEN_VALUE="" run >/dev/null 2>"$WORK/err"
check "exit 10" "$([ $? -eq 10 ] && echo 0 || echo 1)"
check "no file created" "$([ ! -e "$DEST" ] && echo 0 || echo 1)"
check "no temp files" "$([ "$(find "$WORK" -maxdepth 1 -name '.loki-token*' | wc -l)" -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== no temp files left behind =="
setup
STUB_TOKEN_VALUE="glc_secret_one" run >/dev/null 2>&1
LEFTOVER=$(find "$WORK" -maxdepth 1 -name '.loki-token*' | wc -l)
check "no temp files" "$([ "$LEFTOVER" -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== default destination path matches what Task 5's config reads =="
# Every test above overrides LOKI_TOKEN_DEST, so a typo in the script's own
# default (e.g. a wrong directory or filename) would never surface here even
# though Task 5's `password_file` has to match it literally.
check "default is /etc/alloy/loki-token" "$(grep -qF 'LOKI_TOKEN_DEST:-/etc/alloy/loki-token' "$SCRIPT" && echo 0 || echo 1)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
