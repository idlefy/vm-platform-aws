#!/usr/bin/env bash
# Tests for scripts/placeholder-check.sh — the one spelling of "does this tree
# still carry placeholders?", and its three-state exit contract.
#
# The third state is the point. A two-state helper makes "no placeholders" and
# "the check could not run" the same exit code, and the Makefile's warn branch
# and the tenant-setup skill would then read a broken check as a pinned tree —
# the original defect, relocated into the fix.

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
  mkdir -p "$TEN/vms" "$TEN/scripts" "$TEN/cinc/policyfiles"
  cp "$ROOT/scripts/placeholder-check.sh" "$TEN/scripts/"
  # A filled-in policyfile by default, so the --pins cases below assert on the
  # pin surface alone and a --config regression cannot pass by accident.
  printf "cookbook 'base', tag: 'base-1.0.0'\n" > "$TEN/cinc/policyfiles/dev-vm.rb"
}

teardown() { rm -rf "$TMP"; }

echo "== placeholders found: exit 0 and the file list =="
setup
printf 'sha = "__PLATFORM_SHA__"\n' > "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && ./scripts/placeholder-check.sh )
check "exit 0" "$?"
check "names the file" "$(echo "$OUT" | grep -q 'vms/main.tf' && echo 0 || echo 1)"
teardown

echo "== a pinned tree: exit 1 =="
setup
printf 'sha = "0000000000000000000000000000000000000000"\n' > "$TEN/vms/main.tf"
( cd "$TEN" && ./scripts/placeholder-check.sh >/dev/null 2>&1 )
check "exit 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"
teardown

echo "== placeholders under vms/.terraform are cache, not tree =="
# After `terraform init` the module cache holds this whole repository,
# tenant-skeleton and its unresolved main.tf included — measured to false-warn
# on every correctly pinned tenant before --exclude-dir.
setup
printf 'sha = "0000000000000000000000000000000000000000"\n' > "$TEN/vms/main.tf"
mkdir -p "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms"
printf 'sha = "__PLATFORM_SHA__"\n' \
  > "$TEN/vms/.terraform/modules/ec2/tenant-skeleton/vms/main.tf"
( cd "$TEN" && ./scripts/placeholder-check.sh >/dev/null 2>&1 )
check "exit 1 — cache ignored" "$([ $? -eq 1 ] && echo 0 || echo 1)"
teardown

echo "== no vms/ directory: exit 2, never 'resolved' =="
setup
rm -rf "$TEN/vms"
( cd "$TEN" && ./scripts/placeholder-check.sh >/dev/null 2>&1 )
check "exit 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
teardown

echo "== works outside a git repository =="
# The fixtures above are already non-repos; this makes the property explicit
# against a future git-grep rewrite. test-resolve-pin.sh's fixture and smoke's
# throwaway copy are not git repositories either.
setup
printf 'sha = "__PLATFORM_SHA__"\n' > "$TEN/vms/main.tf"
( cd "$TEN" && git rev-parse --git-dir >/dev/null 2>&1 )
check "fixture is not a repo" "$([ $? -ne 0 ] && echo 0 || echo 1)"
( cd "$TEN" && ./scripts/placeholder-check.sh >/dev/null 2>&1 )
check "still finds the placeholder" "$?"
teardown

echo "== --config: a REPLACE_ME in the policyfile is found =="
# base::traefik interpolates acme_email and domain_root unguarded, so a tenant
# that leaves them converges green and asks Let's Encrypt for a certificate for
# a name containing REPLACE_ME. Nothing else in the toolchain says so.
setup
printf 'sha = "0000000000000000000000000000000000000000"\n' > "$TEN/vms/main.tf"
cat > "$TEN/cinc/policyfiles/dev-vm.rb" <<'RB'
cookbook 'base', git: 'https://example.invalid/p.git', tag: 'base-1.0.0'
default['base']['traefik']['acme_email']  = 'REPLACE_ME'
default['base']['traefik']['domain_root'] = 'REPLACE_ME'
RB
OUT=$( cd "$TEN" && ./scripts/placeholder-check.sh --config )
check "exit 0" "$?"
check "names the policyfile" "$(echo "$OUT" | grep -q 'cinc/policyfiles/dev-vm.rb' && echo 0 || echo 1)"
check "does not name vms/main.tf" "$(echo "$OUT" | grep -q 'vms/main.tf' && echo 1 || echo 0)"
teardown

echo "== --config: a filled-in policyfile is exit 1 =="
setup
printf 'sha = "0000000000000000000000000000000000000000"\n' > "$TEN/vms/main.tf"
cat > "$TEN/cinc/policyfiles/dev-vm.rb" <<'RB'
cookbook 'base', git: 'https://example.invalid/p.git', tag: 'base-1.0.0'
default['base']['traefik']['acme_email']  = 'ops@example.com'
default['base']['traefik']['domain_root'] = 'example.com'
RB
( cd "$TEN" && ./scripts/placeholder-check.sh --config >/dev/null 2>&1 )
check "exit 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"
teardown

echo "== --pins ignores the policyfile: the rewrite list stays a rewrite list =="
# resolve-pin.sh and pin-to-worktree.sh sed every file this mode names. A
# policyfile in that list would be handed to a substitution that cannot fix it.
setup
printf 'sha = "__PLATFORM_SHA__"\n' > "$TEN/vms/main.tf"
printf "tag: 'base-REPLACE_ME'\n" > "$TEN/cinc/policyfiles/dev-vm.rb"
OUT=$( cd "$TEN" && ./scripts/placeholder-check.sh )
check "exit 0" "$?"
check "names vms/main.tf" "$(echo "$OUT" | grep -q 'vms/main.tf' && echo 0 || echo 1)"
check "does not name the policyfile" "$(echo "$OUT" | grep -q 'policyfiles' && echo 1 || echo 0)"
teardown

echo "== --all reports both surfaces =="
setup
printf 'sha = "__PLATFORM_SHA__"\n' > "$TEN/vms/main.tf"
printf "tag: 'base-REPLACE_ME'\n" > "$TEN/cinc/policyfiles/dev-vm.rb"
OUT=$( cd "$TEN" && ./scripts/placeholder-check.sh --all )
check "exit 0" "$?"
check "names vms/main.tf" "$(echo "$OUT" | grep -q 'vms/main.tf' && echo 0 || echo 1)"
check "names the policyfile" "$(echo "$OUT" | grep -q 'cinc/policyfiles/dev-vm.rb' && echo 0 || echo 1)"
teardown

echo "== --all: only one surface dirty is still exit 0 =="
setup
printf 'sha = "0000000000000000000000000000000000000000"\n' > "$TEN/vms/main.tf"
printf "tag: 'base-REPLACE_ME'\n" > "$TEN/cinc/policyfiles/dev-vm.rb"
( cd "$TEN" && ./scripts/placeholder-check.sh --all >/dev/null 2>&1 )
check "exit 0" "$?"
teardown

echo "== --config with no cinc/policyfiles: exit 2, never 'filled in' =="
setup
rm -rf "$TEN/cinc"
( cd "$TEN" && ./scripts/placeholder-check.sh --config >/dev/null 2>&1 )
check "exit 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
teardown

echo "== --config with an empty cinc/policyfiles: exit 2 =="
# An empty directory is "could not check", not "nothing to fill in". The glob
# would otherwise expand to a literal that grep reports as a missing file.
setup
rm -f "$TEN"/cinc/policyfiles/*.rb
( cd "$TEN" && ./scripts/placeholder-check.sh --config >/dev/null 2>&1 )
check "exit 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
teardown

echo "== an unknown option is exit 2, not a silent default =="
setup
( cd "$TEN" && ./scripts/placeholder-check.sh --pin >/dev/null 2>&1 )
check "exit 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
teardown

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
