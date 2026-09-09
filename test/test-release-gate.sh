#!/usr/bin/env bash
# Gate tests for `make release`, run against throwaway git repos.
#
# The gate exists because the checks run against the WORKING TREE while a tag
# names a COMMIT. An operator who edits a file to fix a failing check, re-runs
# release, and sees green has tagged a commit without the fix — and tenants then
# pin an artifact that never passed. Every assertion below is about that gap.
#
# Run via `make test-release-gate` from the repo root.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi
}

# A throwaway repo that mimics the template's shape: a root Makefile, a
# metadata.rb, and a stubbed cinc/Makefile so the gate's `lint`/`test` calls are cheap.
#
# It needs a real upstream. The gate refuses a HEAD that is not an ancestor of
# the tracked branch, so a sandbox with no remote makes EVERY release refuse —
# and then every "exit non-zero" assertion below passes for the wrong reason,
# reporting green while testing nothing. The bare repo lives OUTSIDE the working
# tree: inside it, `git status --porcelain` would see it and the dirty-tree gate
# would fire instead.
setup() {
  TMP=$(mktemp -d)
  WORK="$TMP/repo"; ORIGIN="$TMP/origin.git"
  mkdir -p "$WORK/cinc/cookbooks/base" "$WORK/test"
  mkdir -p "$WORK/scripts"
  mkdir -p "$WORK/vms/modules/ec2" "$WORK/tenant-skeleton/vms"
  printf 'resource "null_resource" "a" {}\n' > "$WORK/vms/modules/ec2/main.tf"
  cat > "$WORK/scripts/boundary-check.sh" <<'STUB'
#!/bin/sh
echo "boundary stub"
STUB
  cat > "$WORK/scripts/smoke.sh" <<'STUB'
#!/bin/sh
echo "smoke stub"
STUB
  cat > "$WORK/test/test-skeleton-sync.sh" <<'STUB'
#!/bin/sh
echo "skeleton-sync stub"
STUB
  chmod +x "$WORK/test/test-skeleton-sync.sh"
  chmod +x "$WORK/scripts/boundary-check.sh" "$WORK/scripts/smoke.sh"
  cp "$ROOT/Makefile" "$WORK/Makefile"
  printf "version         '%s'\n" "${1:-0.11.0}" > "$WORK/cinc/cookbooks/base/metadata.rb"
  cat > "$WORK/cinc/Makefile" <<'STUB'
lint:
	@echo "lint stub"
test:
	@echo "chefspec stub"
test-broker:
	@true
test-loki-token:
	@true
STUB
  git init -q --bare "$ORIGIN"
  ( cd "$WORK" && git init -q -b main && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm init \
      && git remote add origin "$ORIGIN" \
      && git push -q origin main \
      && git branch -q --set-upstream-to=origin/main main )
}

teardown() { rm -rf "$TMP"; }

echo "== a clean tree at a matching version cuts the tag =="
setup 0.11.0
( cd "$WORK" && make release TAG=base-0.11.0 >/dev/null 2>&1 )
check "exit 0" "$?"
check "tag exists" "$(git -C "$WORK" rev-parse -q --verify base-0.11.0 >/dev/null && echo 0 || echo 1)"
check "tag is on HEAD" "$([ "$(git -C "$WORK" rev-parse base-0.11.0)" = "$(git -C "$WORK" rev-parse HEAD)" ] && echo 0 || echo 1)"
check "tag is lightweight" "$([ "$(git -C "$WORK" cat-file -t base-0.11.0)" = "commit" ] && echo 0 || echo 1)"
teardown

echo "== a dirty tree is refused, and no tag is left behind =="
setup 0.11.0
echo "uncommitted" >> "$WORK/cinc/cookbooks/base/metadata.rb"
( cd "$WORK" && make release TAG=base-0.11.0 >/dev/null 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "no tag created" "$(git -C "$WORK" rev-parse -q --verify base-0.11.0 >/dev/null && echo 1 || echo 0)"
teardown

echo "== a version that disagrees with the tag is refused =="
# Assert the MESSAGE, not just the exit code. A gate that refuses for an earlier,
# unrelated reason also exits non-zero, and this assertion is exactly where that
# false pass hid once already.
setup 0.11.0
OUT=$( cd "$WORK" && make release TAG=base-0.12.0 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the disagreement" "$(echo "$OUT" | grep -q "says '0.11.0'" && echo 0 || echo 1)"
check "no tag created" "$(git -C "$WORK" rev-parse -q --verify base-0.12.0 >/dev/null && echo 1 || echo 0)"
teardown

echo "== a commit that is not on the tracked branch is refused =="
# The tagged commit must be reachable for consumers. A local-only commit is not,
# and a tenant that pins it gets "couldn't find remote ref" on the next resolve.
setup 0.11.0
( cd "$WORK" && echo local-only > x && git add x \
    && git -c user.email=t@t -c user.name=t commit -qm unpushed )
OUT=$( cd "$WORK" && make release TAG=base-0.11.0 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says HEAD is not an ancestor" "$(echo "$OUT" | grep -qi 'not an ancestor' && echo 0 || echo 1)"
check "no tag created" "$(git -C "$WORK" rev-parse -q --verify base-0.11.0 >/dev/null && echo 1 || echo 0)"
teardown


echo "== a malformed base- tag is refused, even when metadata agrees =="
# base-* accepted anything after the hyphen, and the version check below only
# compares the suffix to metadata.rb — so a typo present in BOTH passes. It is
# not caught downstream either: measured, `chef install` on a four-segment
# version fails with InvalidCookbookVersion, so the tag would be published and
# unusable; and cookstyle's own Chef/Correctness/InvalidVersionMetadata rule is
# severity R, which exits 0, so `make lint` reports success on it.
setup 0.11.0.1
OUT=$( cd "$WORK" && make release TAG=base-0.11.0.1 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the required format" "$(echo "$OUT" | grep -q 'base-X.Y.Z' && echo 0 || echo 1)"
check "no tag created" "$(git -C "$WORK" rev-parse -q --verify base-0.11.0.1 >/dev/null && echo 1 || echo 0)"
teardown

echo "== an existing tag is never moved =="
setup 0.11.0
( cd "$WORK" && make release TAG=base-0.11.0 >/dev/null 2>&1 )
FIRST=$(git -C "$WORK" rev-parse base-0.11.0 2>/dev/null)
# Guard the guard: if the first release did not cut a tag, FIRST is empty and the
# comparison below succeeds by comparing two empty strings.
check "first release actually tagged" "$([ -n "$FIRST" ] && echo 0 || echo 1)"
( cd "$WORK" && echo x > x && git add x \
    && git -c user.email=t@t -c user.name=t commit -qm second )
( cd "$WORK" && make release TAG=base-0.11.0 >/dev/null 2>&1 )
check "exit non-zero on re-release" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "tag still on the first commit" "$([ -n "$FIRST" ] && [ "$(git -C "$WORK" rev-parse base-0.11.0)" = "$FIRST" ] && echo 0 || echo 1)"
teardown

echo "== the gate prints the SHA it is about to tag =="
setup 0.11.0
OUT=$( cd "$WORK" && make release TAG=base-0.11.0 2>&1 )
check "SHA appears in output" "$(echo "$OUT" | grep -qF "$(git -C "$WORK" rev-parse HEAD)" && echo 0 || echo 1)"
teardown

echo "== a v tag runs the Terraform gates and cuts the tag =="
setup 0.11.0
OUT=$( cd "$WORK" && make release TAG=v9.0.0 2>&1 )
check "exit 0" "$?"
check "ran the boundary guard" "$(echo "$OUT" | grep -q 'boundary stub' && echo 0 || echo 1)"
check "ran the smoke gate" "$(echo "$OUT" | grep -q 'smoke stub' && echo 0 || echo 1)"
check "ran the skeleton-sync guard" "$(echo "$OUT" | grep -q 'skeleton-sync stub' && echo 0 || echo 1)"
check "no chefspec on the v path" "$(echo "$OUT" | grep -q 'chefspec stub' && echo 1 || echo 0)"
check "tag exists on HEAD" "$([ "$(git -C "$WORK" rev-parse v9.0.0 2>/dev/null)" = "$(git -C "$WORK" rev-parse HEAD)" ] && echo 0 || echo 1)"
teardown

echo "== a v tag does NOT check metadata.rb =="
# The cookbook version is 0.11.0 and the tag says 9.0.0. On the cookbook path
# that is a refusal; on the Terraform path it is irrelevant, and a gate that
# conflated them would make every Terraform release wait on a cookbook bump.
setup 0.11.0
( cd "$WORK" && make release TAG=v9.0.0 >/dev/null 2>&1 )
check "exit 0 despite the version gap" "$?"
teardown

echo "== a base tag does NOT run the Terraform gates =="
setup 0.11.0
OUT=$( cd "$WORK" && make release TAG=base-0.11.0 2>&1 )
check "exit 0" "$?"
check "no boundary guard on the cookbook path" "$(echo "$OUT" | grep -q 'boundary stub' && echo 1 || echo 0)"
check "no smoke gate on the cookbook path" "$(echo "$OUT" | grep -q 'smoke stub' && echo 1 || echo 0)"
check "no skeleton-sync guard on the cookbook path" "$(echo "$OUT" | grep -q 'skeleton-sync stub' && echo 1 || echo 0)"
check "ran the cookstyle gate" "$(echo "$OUT" | grep -q 'lint stub' && echo 0 || echo 1)"
check "ran the chefspec gate" "$(echo "$OUT" | grep -q 'chefspec stub' && echo 0 || echo 1)"
teardown

echo "== a tag in neither stream is refused =="
setup 0.11.0
OUT=$( cd "$WORK" && make release TAG=3.1.0 2>&1 )
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names both streams" "$(echo "$OUT" | grep -q 'base-X.Y.Z' && echo "$OUT" | grep -q 'vX.Y.Z' && echo 0 || echo 1)"
check "no tag created" "$(git -C "$WORK" rev-parse -q --verify 3.1.0 >/dev/null && echo 1 || echo 0)"
teardown

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
