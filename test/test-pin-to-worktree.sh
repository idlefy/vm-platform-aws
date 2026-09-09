#!/usr/bin/env bash
# Tests for scripts/pin-to-worktree.sh — the smoke gate's module redirector.
# Its one hard rule: never print success over a tree it did not fully rewrite.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi
}

setup() {
  TMP=$(mktemp -d)
  TEN="$TMP/tenant"; MODS="$TMP/modules"
  mkdir -p "$TEN/vms" "$TEN/scripts" "$MODS/ec2" "$MODS/fleet-guards"
  cp "$ROOT/scripts/pin-to-worktree.sh" "$ROOT/scripts/placeholder-check.sh" "$TEN/scripts/"
  cat > "$TEN/vms/main.tf" <<'TF'
locals {
  platform_pin = {
    tag = "__PLATFORM_TAG__"
    sha = "__PLATFORM_SHA__"
  }
}

module "ec2" {
  source = "git::ssh://git@example.invalid/x.git//vms/modules/ec2?ref=__PLATFORM_SHA__" # __PLATFORM_TAG__
}

module "fleet_guards" {
  source = "git::ssh://git@example.invalid/x.git//vms/modules/fleet-guards?ref=__PLATFORM_SHA__" # __PLATFORM_TAG__
}
TF
}

teardown() { rm -rf "$TMP"; }

run_pin() { ( cd "$TEN" && ./scripts/pin-to-worktree.sh "$MODS" 2>&1 ); }

echo "== the happy path redirects both sources =="
setup
OUT=$(run_pin)
check "exit 0" "$?"
check "both sources point at the worktree" "$([ "$(grep -c "$MODS" "$TEN/vms/main.tf")" = "2" ] && echo 0 || echo 1)"
check "no placeholder survives" "$(grep -q '__PLATFORM_' "$TEN/vms/main.tf" && echo 1 || echo 0)"
teardown

echo "== a source line the rewriter does not recognise is a failure, not a success =="
# Drop the trailing '# __PLATFORM_TAG__' comment from one source: the rewrite
# regex requires it, n==0 for that file, and the embedded python refuses with
# sys.exit — which the unfixed shell swallowed, printing '✓ modules resolved'
# over a half-pinned tree.
setup
sed -i 's|?ref=__PLATFORM_SHA__" # __PLATFORM_TAG__$|?ref=__PLATFORM_SHA__"|' "$TEN/vms/main.tf"
OUT=$(run_pin)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "does not claim success" "$(echo "$OUT" | grep -q 'modules resolved' && echo 1 || echo 0)"
teardown

echo "== an already-pinned tree is refused =="
setup
run_pin >/dev/null 2>&1
OUT=$(run_pin)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says already pinned" "$(echo "$OUT" | grep -qi 'already pinned' && echo 0 || echo 1)"
teardown

echo "== a seeded module cache neither bypasses the refusal nor gets rewritten =="
setup
run_pin >/dev/null 2>&1
mkdir -p "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms"
printf 'sha = "__PLATFORM_SHA__"\n' \
  > "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf"
OUT=$(run_pin)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "cache untouched" "$(grep -q '__PLATFORM_SHA__' "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf" && echo 0 || echo 1)"
teardown

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
