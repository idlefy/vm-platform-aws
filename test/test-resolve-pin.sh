#!/usr/bin/env bash
# Tests for scripts/resolve-pin.sh, against a local bare repo carrying one
# annotated and one lightweight tag.
#
# The peeling is the whole point. Terraform resolves ?ref=<tag> to the COMMIT,
# so a pin taking an annotated tag's object SHA names an object Terraform will
# not check out. Both tag forms turn up in practice, so the resolver must peel.

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
  SRC="$TMP/src"; BARE="$TMP/upstream.git"; TEN="$TMP/tenant"
  mkdir -p "$SRC"
  printf 'one\n' > "$SRC/f"
  ( cd "$SRC" && git init -q -b main && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm one \
      && git tag v9.0.0 )                                    # lightweight
  printf 'two\n' >> "$SRC/f"
  ( cd "$SRC" && git add -A && git -c user.email=t@t -c user.name=t commit -qm two \
      && git -c user.email=t@t -c user.name=t tag -a v9.1.0 -m "annotated" )
  git clone -q --bare "$SRC" "$BARE"

  mkdir -p "$TEN/vms" "$TEN/scripts"
  cp "$ROOT/scripts/resolve-pin.sh" "$ROOT/scripts/placeholder-check.sh" "$TEN/scripts/"
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

run_resolve() { ( cd "$TEN" && PLATFORM_REMOTE="$BARE" ./scripts/resolve-pin.sh "$1" 2>&1 ); }

echo "== a lightweight tag resolves to its commit =="
setup
OUT=$(run_resolve v9.0.0)
check "exit 0" "$?"
WANT=$(git -C "$SRC" rev-parse v9.0.0)
check "pin is the commit" "$(grep -q "$WANT" "$TEN/vms/main.tf" && echo 0 || echo 1)"
# Note the inversion. `grep -c … | grep -qx 0` looks equivalent and is not:
# with `set -o pipefail` above, grep -c's exit 1 on zero matches becomes the
# pipeline's status, and the assertion fails on a correct resolver. Measured.
check "all three placeholders gone" "$(grep -q '__PLATFORM_' "$TEN/vms/main.tf" && echo 1 || echo 0)"
check "tag written into the local" "$(grep -q 'tag = "v9.0.0"' "$TEN/vms/main.tf" && echo 0 || echo 1)"
check "both sources carry the sha" "$([ "$(grep -c "ref=$WANT" "$TEN/vms/main.tf")" = "2" ] && echo 0 || echo 1)"
teardown

echo "== an annotated tag resolves to its COMMIT, not its tag object =="
# This is the assertion that fails if the ^{} is dropped. Without it the pin
# names the tag object, which Terraform cannot check out.
setup
OUT=$(run_resolve v9.1.0)
check "exit 0" "$?"
COMMIT=$(git -C "$SRC" rev-parse 'v9.1.0^{}')
TAGOBJ=$(git -C "$SRC" rev-parse v9.1.0)
check "the two differ (fixture is valid)" "$([ "$COMMIT" != "$TAGOBJ" ] && echo 0 || echo 1)"
check "pin is the commit" "$(grep -q "$COMMIT" "$TEN/vms/main.tf" && echo 0 || echo 1)"
check "pin is NOT the tag object" "$(grep -q "$TAGOBJ" "$TEN/vms/main.tf" && echo 1 || echo 0)"
teardown

echo "== a tag that does not exist is refused, and nothing is written =="
setup
BEFORE=$(md5sum < "$TEN/vms/main.tf")
OUT=$(run_resolve v9.9.9)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the tag" "$(echo "$OUT" | grep -q 'v9.9.9' && echo 0 || echo 1)"
check "file untouched" "$([ "$BEFORE" = "$(md5sum < "$TEN/vms/main.tf")" ] && echo 0 || echo 1)"
teardown

echo "== a second run is refused rather than corrupting a resolved file =="
setup
run_resolve v9.0.0 >/dev/null 2>&1
OUT=$(run_resolve v9.1.0)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says there is nothing to resolve" "$(echo "$OUT" | grep -qi 'no placeholder' && echo 0 || echo 1)"
check "still pinned to the first tag" "$(grep -q 'tag = "v9.0.0"' "$TEN/vms/main.tf" && echo 0 || echo 1)"
teardown

echo "== a seeded module cache does not bypass the already-pinned refusal =="
# After `terraform init` the cache holds the whole platform repo, placeholders
# included. Unfixed, the bare grep matches the cache, skips the refusal, and
# `make prepare PLATFORM_TAG=…` misbehaves on a pinned tenant.
setup
run_resolve v9.0.0 >/dev/null 2>&1
mkdir -p "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms"
printf 'sha = "__PLATFORM_SHA__"\n' \
  > "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf"
BEFORE=$(md5sum < "$TEN/vms/main.tf")
OUT=$(run_resolve v9.1.0)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "refuses as already pinned" "$(echo "$OUT" | grep -qi 'no placeholder' && echo 0 || echo 1)"
check "main.tf untouched" "$([ "$BEFORE" = "$(md5sum < "$TEN/vms/main.tf")" ] && echo 0 || echo 1)"
check "cache untouched" "$(grep -q '__PLATFORM_SHA__' "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf" && echo 0 || echo 1)"
teardown

echo "== an unpinned tree with a seeded cache resolves the tree, not the cache =="
setup
mkdir -p "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms"
printf 'sha = "__PLATFORM_SHA__"\n' \
  > "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf"
OUT=$(run_resolve v9.0.0)
check "exit 0" "$?"
check "tree resolved" "$(grep -q 'tag = "v9.0.0"' "$TEN/vms/main.tf" && echo 0 || echo 1)"
check "cache still carries its placeholder" "$(grep -q '__PLATFORM_SHA__' "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf" && echo 0 || echo 1)"
teardown

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
