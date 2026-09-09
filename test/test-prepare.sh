#!/usr/bin/env bash
# Tests for tenant-skeleton's `make prepare` — the target every fresh tenant
# runs first, in exactly the environments make is worst at: not yet a git
# repo, half-copied trees, stale exported variables.

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
  TEN="$TMP/tenant"
  mkdir -p "$TEN"
  cp -r "$ROOT/tenant-skeleton/." "$TEN/"
}

teardown() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }

echo "== the skeleton ships its .gitignore, and the dot-copy carries it =="
setup
check ".gitignore present" "$([ -f "$TEN/.gitignore" ] && echo 0 || echo 1)"
check "it ignores .terraform/" "$(grep -qx '\.terraform/' "$TEN/.gitignore" && echo 0 || echo 1)"
teardown

echo "== bare prepare on a fresh, non-git tree: creates config, warns, no git noise =="
setup
OUT=$( cd "$TEN" && make prepare 2>&1 )
check "exit 0" "$?"
check "created the tfvars" "$([ -f "$TEN/vms/tenant.auto.tfvars" ] && echo 0 || echo 1)"
check "warns about placeholders" "$(echo "$OUT" | grep -q 'still carries pin placeholders' && echo 0 || echo 1)"
check "no 'fatal:' leaks" "$(echo "$OUT" | grep -q 'fatal:' && echo 1 || echo 0)"
teardown

echo "== a pinned tree with a seeded module cache does not warn =="
setup
sed -i -e 's/__PLATFORM_TAG__/v9.9.9/g' \
       -e 's/__PLATFORM_SHA__/1111111111111111111111111111111111111111/g' \
  "$TEN/vms/main.tf"
mkdir -p "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms"
printf 'sha = "__PLATFORM_SHA__"\n' \
  > "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf"
OUT=$( cd "$TEN" && make prepare 2>&1 )
check "exit 0" "$?"
check "no placeholder warning" "$(echo "$OUT" | grep -q 'still carries pin placeholders' && echo 1 || echo 0)"
teardown

echo "== PLATFORM_TAG from the environment is ignored, and said so =="
# A stale `export PLATFORM_TAG` must not turn the documented-safe bare
# `make prepare` into the pin-writing branch.
setup
OUT=$( cd "$TEN" && PLATFORM_TAG=v9.9.9 make prepare 2>&1 )
check "exit 0" "$?"
check "announces the ignored variable" "$(echo "$OUT" | grep -qi 'ignoring PLATFORM_TAG' && echo 0 || echo 1)"
check "did not touch the pin" "$(grep -q '__PLATFORM_TAG__' "$TEN/vms/main.tf" && echo 0 || echo 1)"
teardown

echo "== a failed template copy fails the target =="
setup
chmod a-w "$TEN/vms"
OUT=$( cd "$TEN" && make prepare 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the failed file" "$(echo "$OUT" | grep -qi 'could not create' && echo 0 || echo 1)"
check "does not claim completion" "$(echo "$OUT" | grep -q 'prepare complete' && echo 1 || echo 0)"
teardown

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
