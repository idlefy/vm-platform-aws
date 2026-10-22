#!/usr/bin/env bash
# Functional test for idlefy-share, the one extra command ubuntu may run as root
# on a solo VM (sudoers grants it with `*`, so the script's own argument check
# is the whole control).
#
# Runs with no tailnet: the script's single `TAILSCALE=/usr/bin/tailscale` line
# is the only seam (the script reads no environment), so the copy under test has
# that line rewritten to a stub that logs its argv.
# Run via `make test-share-helper` from the cinc/ directory.
#
# Not covered here (needs root and a real VM): the sudoers grant itself and
# Tailscale's own Funnel behaviour.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cookbooks/base/files/default/idlefy-share"
PASS=0
FAIL=0

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$3', got '$2')"; FAIL=$((FAIL + 1))
  fi
}

if [ ! -f "$SCRIPT" ]; then
  echo "  FAIL: $SCRIPT does not exist"
  echo ""
  echo "passed: 0   failed: 1"
  exit 1
fi

setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tailscale" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo "stub: $*"
if [ "${1:-} ${2:-}" = "funnel reset" ]; then
  exit "${STUB_RESET_RC:-0}"
fi
exit "${STUB_RC:-0}"
STUBEOF
  chmod +x "$WORK/bin/tailscale"
  sed "s|^TAILSCALE=/usr/bin/tailscale\$|TAILSCALE=$WORK/bin/tailscale|" "$SCRIPT" > "$WORK/idlefy-share"
  chmod +x "$WORK/idlefy-share"
  export STUB_CALLS="$WORK/calls"
  unset STUB_RC STUB_RESET_RC
}

teardown() { rm -rf "$WORK"; }

# run <args...> — runs the copy, sets rc; stdout/stderr land in $WORK/out, $WORK/err.
run() {
  "$WORK/idlefy-share" "$@" >"$WORK/out" 2>"$WORK/err"; rc=$?
}

calls() { if [ -e "$WORK/calls" ]; then tr '\n' '|' < "$WORK/calls"; fi; }

echo "--- the seam ---"
check "exactly one TAILSCALE=/usr/bin/tailscale line" "$(grep -cx 'TAILSCALE=/usr/bin/tailscale' "$SCRIPT")" "1"
setup
check "the copy points at the stub" "$(grep -cx "TAILSCALE=$WORK/bin/tailscale" "$WORK/idlefy-share")" "1"
teardown

echo "--- share a port ---"
setup
run 3000
check "exit code" "$rc" "0"
check "reset, then funnel --bg to loopback" "$(calls)" "funnel reset|funnel --bg http://127.0.0.1:3000|"
check "funnel's stdout reaches the caller" "$(grep -c '^stub: funnel --bg http://127.0.0.1:3000$' "$WORK/out")" "1"
check "reset's output is not shown" "$(grep -c 'stub: funnel reset' "$WORK/out")" "0"
check "nothing on stderr" "$(wc -c < "$WORK/err")" "0"
teardown

echo "--- a failing reset does not stop the share ---"
setup
STUB_RESET_RC=1 run 3000
check "exit code" "$rc" "0"
check "still proceeds to funnel --bg" "$(calls)" "funnel reset|funnel --bg http://127.0.0.1:3000|"
teardown

echo "--- funnel failure passes through ---"
setup
STUB_RC=1 run 3000
check "exit code is funnel's" "$rc" "1"
check "funnel's message reached the caller" "$(grep -c '^stub: funnel --bg http://127.0.0.1:3000$' "$WORK/out")" "1"
teardown

echo "--- bounds accepted ---"
for p in 65535 1024; do
  setup
  run "$p"
  check "$p: exit code" "$rc" "0"
  check "$p: calls" "$(calls)" "funnel reset|funnel --bg http://127.0.0.1:$p|"
  teardown
done

echo "--- refused arguments ---"
refuse() {
  local label="$1"; shift
  setup
  run "$@"
  check "$label: exit 64" "$rc" "64"
  check "$label: no tailscale call" "$(calls)" ""
  check "$label: usage on stderr" "$(grep -c 'usage: idlefy-share' "$WORK/err")" "1"
  check "$label: nothing on stdout" "$(wc -c < "$WORK/out")" "0"
  teardown
}
for a in 1023 65536 99999 080 0 3000x -h /etc/shadow localhost:3000 '3000 ; id' OFF; do
  refuse "'$a'" "$a"
done
refuse "empty string" ""
refuse "no argument"
refuse "two arguments" 3000 4000
refuse "off plus a port" off 3000

echo "--- off ---"
setup
run off
check "exit code" "$rc" "0"
check "calls are exactly funnel reset" "$(calls)" "funnel reset|"
teardown

echo "--- off passes reset's failure through ---"
setup
STUB_RESET_RC=1 run off
check "exit code is reset's" "$rc" "1"
teardown

echo "--- source shape ---"
check "shebang" "$(head -1 "$SCRIPT")" "#!/bin/bash"
check "set -euo pipefail" "$(grep -cx 'set -euo pipefail' "$SCRIPT")" "1"
check "export LC_ALL=C" "$(grep -cx 'export LC_ALL=C' "$SCRIPT")" "1"
check "PATH is pinned" "$(grep -cx 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$SCRIPT")" "1"
check "no eval" "$(grep -cw 'eval' "$SCRIPT")" "0"
# Every named parameter expansion must be on the allowlist: the script reads no
# environment, so a new variable it did not declare is a new input.
check "only allowlisted variables are expanded" \
  "$(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' "$SCRIPT" | tr -d '${' | sort -u \
     | grep -vxE 'TAILSCALE|PATH|LC_ALL|port' | tr '\n' ' ')" ""
check "positional parameters are only \$1 and \$#" \
  "$(grep -oE '\$\{?[0-9@*#]' "$SCRIPT" | tr -d '${' | sort -u | grep -vxE '1|#' | tr '\n' ' ')" ""

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
