#!/usr/bin/env bash
# Tests for `make pin-check`, against a local bare git repo — no network, no
# CINC server, and no tag on any shared remote is touched.
#
# Each case below is a way the pin can silently stop meaning what it says:
#   - the policyfile is edited and the lock is not (chef install would push the
#     OLD content: measured, it prints "Installing cookbooks from lock", exits 0,
#     and leaves attributes untouched)
#   - the tag moves upstream (re-locking here would ADOPT the moved content)
#   - the check's own resolve fails (a version that seeds the lock would pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi
}

# A bare repo holding a minimal cookbook at cinc/cookbooks/base, plus a tenant
# working copy whose policyfile pins it by tag.
setup() {
  WORK=$(mktemp -d)
  SRC="$WORK/src"; BARE="$WORK/upstream.git"; TEN="$WORK/tenant"
  mkdir -p "$SRC/cinc/cookbooks/base/recipes"
  printf "name 'base'\nversion '0.11.0'\n" > "$SRC/cinc/cookbooks/base/metadata.rb"
  printf "# v1\n" > "$SRC/cinc/cookbooks/base/recipes/default.rb"
  ( cd "$SRC" && git init -q && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm one \
      && git tag base-0.11.0 )
  git clone -q --bare "$SRC" "$BARE"

  mkdir -p "$TEN/cinc/policyfiles" "$TEN/test"
  cp "$ROOT/Makefile" "$TEN/Makefile"
  # pin-check lives in scripts/, and derives its own root from its location —
  # copying the Makefile alone gives "No such file or directory" from the recipe.
  cp -r "$ROOT/scripts" "$TEN/scripts"
  cat > "$TEN/cinc/policyfiles/dev-vm.rb" <<POLICY
name 'dev-vm'
run_list 'base::default'
cookbook 'base', git: '$BARE', tag: 'base-0.11.0', rel: 'cinc/cookbooks/base'
default['base']['loki']['username'] = '1707832'
POLICY
  mkdir -p "$TEN/vms"
  ( cd "$SRC" && git tag v9.0.0 )
  ( cd "$BARE" && git fetch -q --tags "$SRC" 'refs/tags/*:refs/tags/*' )
  SHA=$(git -C "$SRC" rev-parse 'v9.0.0^{}')
  cat > "$TEN/vms/main.tf" <<TF
locals {
  platform_pin = {
    tag = "v9.0.0"
    sha = "$SHA"
  }
}

module "ec2" {
  source = "git::file://$BARE//vms/modules/ec2?ref=$SHA" # v9.0.0
}

module "fleet_guards" {
  source = "git::file://$BARE//vms/modules/fleet-guards?ref=$SHA" # v9.0.0
}
TF
  # Same squelch pin-check.sh sets for itself: filter-branch's 10s warning sleep
  # would otherwise be paid once more per case here.
  ( cd "$TEN/cinc/policyfiles" && FILTER_BRANCH_SQUELCH_WARNING=1 chef install dev-vm.rb >/dev/null 2>&1 )
  ( cd "$TEN" && git init -q && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm init )
}

teardown() { rm -rf "$WORK"; }

echo "== a matching lock passes =="
setup
( cd "$TEN" && make pin-check >/dev/null 2>&1 )
check "exit 0" "$?"
teardown

echo "== an attribute edit with a stale lock is caught =="
# This is the mirror hazard: chef install honours the lock, so without this gate
# the tenant's most common edit of all pushes the previous value.
setup
printf "default['base']['loki']['url'] = 'https://CHANGED/loki/api/v1/push'\n" \
  >> "$TEN/cinc/policyfiles/dev-vm.rb"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says the lock is stale" "$(echo "$OUT" | grep -qi 'not in the lock' && echo 0 || echo 1)"
check "does NOT say the tag moved" "$(echo "$OUT" | grep -qi 'moved upstream' && echo 1 || echo 0)"
teardown

echo "== a moved tag is caught, and reported as a different problem =="
setup
printf "# v2 — different content\n" >> "$SRC/cinc/cookbooks/base/recipes/default.rb"
( cd "$SRC" && git add -A && git -c user.email=t@t -c user.name=t commit -qm two \
    && git tag -f base-0.11.0 >/dev/null 2>&1 )
( cd "$BARE" && git fetch -q --tags --force "$SRC" 'refs/tags/*:refs/tags/*' )
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says the tag moved" "$(echo "$OUT" | grep -qi 'moved upstream' && echo 0 || echo 1)"
check "warns against bumping" "$(echo "$OUT" | grep -qi 'do NOT bump' && echo 0 || echo 1)"
teardown

echo "== an unresolvable source fails, and does not report success =="
setup
rm -rf "$BARE"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says it could not resolve" "$(echo "$OUT" | grep -qi 'could not resolve' && echo 0 || echo 1)"
teardown

echo "== the committed lock is never modified by the check =="
setup
BEFORE=$(md5sum < "$TEN/cinc/policyfiles/dev-vm.lock.json")
printf "default['base']['x'] = 'y'\n" >> "$TEN/cinc/policyfiles/dev-vm.rb"
( cd "$TEN" && make pin-check >/dev/null 2>&1 )
AFTER=$(md5sum < "$TEN/cinc/policyfiles/dev-vm.lock.json")
check "lock untouched" "$([ "$BEFORE" = "$AFTER" ] && echo 0 || echo 1)"
teardown

echo "== PIN_CHECK=skip bypasses loudly =="
setup
printf "default['base']['x'] = 'y'\n" >> "$TEN/cinc/policyfiles/dev-vm.rb"
OUT=$( cd "$TEN" && PIN_CHECK=skip make pin-check 2>&1 )
check "exit 0" "$?"
check "announces the bypass" "$(echo "$OUT" | grep -qi 'skipping' && echo 0 || echo 1)"
teardown

echo "== agreeing pins pass =="
setup
( cd "$TEN" && make pin-check >/dev/null 2>&1 )
check "exit 0" "$?"
teardown

echo "== two module calls at different commits are caught =="
setup
OTHER=$(git -C "$SRC" rev-parse HEAD~0)
sed -i "0,/ref=$SHA/{s/ref=$SHA/ref=0000000000000000000000000000000000000000/}" "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the disagreement" "$(echo "$OUT" | grep -qi 'disagree' && echo 0 || echo 1)"
# ec2 is the first module block in the fixture, so the sed above (which
# rewrites only the first ref= occurrence in the file) always lands on it.
# pin-check now reports per module block rather than per source line, so the
# offending module's name is what identifies the problem, not a filename.
check "names the offending module" "$(echo "$OUT" | grep -q 'module "ec2"' && echo 0 || echo 1)"
teardown

echo "== a source that disagrees with local.platform_pin is caught =="
setup
sed -i "s/sha = \"$SHA\"/sha = \"1111111111111111111111111111111111111111\"/" "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names platform_pin" "$(echo "$OUT" | grep -qi 'platform_pin' && echo 0 || echo 1)"
teardown

echo "== a tag that no longer names the pinned commit is caught =="
# v9.0.0 moves; base-0.11.0 does not, so stage 1 stays green and stage 3 is the
# code under test.
setup
printf "# moved\n" >> "$SRC/cinc/cookbooks/base/recipes/default.rb"
( cd "$SRC" && git add -A && git -c user.email=t@t -c user.name=t commit -qm moved \
    && git tag -f v9.0.0 >/dev/null 2>&1 )
( cd "$BARE" && git fetch -q --tags --force "$SRC" 'refs/tags/*:refs/tags/*' )
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says the tag no longer names it" "$(echo "$OUT" | grep -qi 'no longer names' && echo 0 || echo 1)"
check "does NOT claim the pin moved" "$(echo "$OUT" | grep -qi 'your pin moved' && echo 1 || echo 0)"
teardown

echo "== a deleted tag is reported as a reachability risk =="
# Note the assertion greps for 'reachab' AND for the stage-3 wording. Stage 1's
# cookbook message also contains "unreachable", so the loose grep alone passes
# without stage 3 ever running.
setup
( cd "$BARE" && git tag -d v9.0.0 >/dev/null 2>&1 )
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "warns about reachability" "$(echo "$OUT" | grep -q 'reachability risk' && echo 0 || echo 1)"
check "it is the Terraform stage, not the cookbook one" "$(echo "$OUT" | grep -q 'v9.0.0' && echo 0 || echo 1)"
teardown

echo "== a crashed stage-2 comparison is a failure, not a pass =="
# The fresh resolve is of the CURRENT policyfile; point it at a cookbook named
# 'other' and the fresh lock has no cookbook_locks['base'] — the committed lock
# still does, stage 1 still passes, and the comparison heredoc raises KeyError.
# Unfixed, the empty $diff prints "ok lock matches the policyfile" and the run
# ends "✓ pin-check passed" having compared nothing.
setup
mkdir -p "$SRC/cinc/cookbooks/other/recipes"
printf "name 'other'\nversion '0.1.0'\n" > "$SRC/cinc/cookbooks/other/metadata.rb"
printf "# other\n" > "$SRC/cinc/cookbooks/other/recipes/default.rb"
( cd "$SRC" && git add -A && git -c user.email=t@t -c user.name=t commit -qm other \
    && git tag other-1.0.0 )
( cd "$BARE" && git fetch -q --tags "$SRC" 'refs/tags/*:refs/tags/*' )
cat > "$TEN/cinc/policyfiles/dev-vm.rb" <<POLICY
name 'dev-vm'
run_list 'other::default'
cookbook 'other', git: '$BARE', tag: 'other-1.0.0', rel: 'cinc/cookbooks/other'
POLICY
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says nothing was verified" "$(echo "$OUT" | grep -qi 'nothing was verified' && echo 0 || echo 1)"
check "does NOT report a pass" "$(echo "$OUT" | grep -q 'pin-check passed' && echo 1 || echo 0)"
teardown

echo "== the same tag from a different remote is caught =="
# A mirror resolves the same tag to the same SHA, so a tag+revision comparison
# alone passes while `make push` installs from a remote nobody reviewed. This
# pins the source_options loop: reverting it to compare only tag and revision
# must turn this case red.
setup
MIRROR="$WORK/mirror.git"
git clone -q --bare "$BARE" "$MIRROR"
sed -i "s|git: '$BARE'|git: '$MIRROR'|" "$TEN/cinc/policyfiles/dev-vm.rb"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names source_options.git" "$(echo "$OUT" | grep -q 'source_options.git' && echo 0 || echo 1)"
teardown

echo "== an offline-recovery tree does not pass as pinned =="
# tenant CLAUDE.md promises a tree on local module paths is unpublishable and
# pin-check refuses it. Unfixed, the '# was:' comments satisfy the ref= grep,
# seen=2, bad=0, and the gate passes with zero live git-pinned sources.
setup
python3 - "$TEN/vms/main.tf" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'^(\s*)source = "(git::[^"]*)"(.*)$',
           r'\1# was: source = "\2"\3\n\1source = "/tmp/platform/vms/modules/x"',
           s, flags=re.M)
open(p, 'w').write(s)
PY
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
# Both module blocks keep a (non-git) source line here, so per-module checking
# counts them as "seen" and reports the disagreement rather than the
# zero-blocks-found message — the tree is still refused, just under the more
# specific per-module report, which names both modules on local paths.
check "flags ec2 as unpinned" "$(echo "$OUT" | grep -q 'module "ec2"' && echo 0 || echo 1)"
check "flags fleet_guards as unpinned" "$(echo "$OUT" | grep -q 'module "fleet_guards"' && echo 0 || echo 1)"
teardown

echo "== a commented-out old source next to a correct live one still passes =="
# The mirror direction: a pin bump that kept the old line as a comment must not
# hard-fail a correct tree by extracting ref=OLDSHA out of the comment.
setup
sed -i "s|^module \"ec2\" {|module \"ec2\" {\n  # was: source = \"git::file://old//vms/modules/ec2?ref=0000000000000000000000000000000000000000\" # v8.0.0|" \
  "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit 0" "$?"
teardown

echo "== a renamed root file fails loudly instead of skipping stage 3 =="
# Terraform is filename-agnostic, so vms/platform.tf still inits and plans —
# and unfixed, pin-check runs stages 1-2 only and reports overall success while
# the poisoned source below goes unexamined forever.
setup
mv "$TEN/vms/main.tf" "$TEN/vms/platform.tf"
sed -i "s/ref=$SHA/ref=1111111111111111111111111111111111111111/" "$TEN/vms/platform.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the stray file" "$(echo "$OUT" | grep -q 'vms/platform.tf' && echo 0 || echo 1)"
teardown

echo "== a platform-shaped tree (no top-level vms/*.tf) still skips stage 3 =="
setup
rm "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit 0" "$?"
teardown

echo "== one pinned module and one local-path module are caught =="
setup
sed -i "/^module \"fleet_guards\"/,/^}/ s|source = .*|source = \"../modules/fleet-guards\"|" "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names fleet_guards" "$(echo "$OUT" | grep -q 'fleet_guards' && echo 0 || echo 1)"
check "does not claim every source is pinned" "$(echo "$OUT" | grep -q 'every module source names' && echo 1 || echo 0)"
teardown

echo "== a ref that only starts with the pin is refused =="
# A trailing wildcard on the case pattern would accept any ref that merely
# STARTS with the pin — ?ref=<pin_sha>deadbeef is not the pinned commit.
setup
sed -i "s/ref=$SHA/ref=${SHA}deadbeef/g" "$TEN/vms/main.tf"
OUT=$( cd "$TEN" && make pin-check 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names a module" "$(echo "$OUT" | grep -Eq 'module "(ec2|fleet_guards)"' && echo 0 || echo 1)"
check "says the ref differs" "$(echo "$OUT" | grep -q "found ref=${SHA}deadbeef" && echo 0 || echo 1)"
teardown

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
